import CoreAudio
import Foundation
import IOKit

// 显示器自己的音量（DDC/CI），和 MonitorControl 用的是同一条路：Apple 芯片的 Mac 上每个外接显示器的
// DCPAVServiceProxy 都能建一个 IOAVService，经它在 I²C 上（地址 0x37）和显示器说 DDC/CI。
// 只用两个 VCP：0x62 扬声器音量（读当前值和最大值），0x8D 静音（1 = 静音，2 = 不静音）。
// Intel 的 Mac 上没有这条路，找不到显示器，照常退回去。

/// 一个 VCP 值：当前值和显示器给的最大值
struct DDCValue: Equatable, Sendable {
    var current: Int
    var max: Int
}

/// 显示器的 DDC。测试换成假的，不碰硬件
protocol DisplayDDC: Sendable {
    /// 读一个 VCP；显示器不回话、不认这个 VCP 时为 nil
    func read(_ code: UInt8) async -> DDCValue?
    /// 写一个 VCP。写没写进去显示器不说，只知道发出去没有
    @discardableResult func write(_ code: UInt8, value: Int) async -> Bool
}

enum VCP {
    static let volume: UInt8 = 0x62
    static let mute: UInt8 = 0x8D
    static let muteOn = 1
    static let muteOff = 2
}

/// DDC/CI 的包：发出去的和读回来的（纯计算，测试直接用）
enum DDCPacket {
    /// 显示器的 I²C 地址（7 位）和主机这边的源地址
    static let address: UInt32 = 0x37
    static let source: UInt8 = 0x51

    /// 读一个 VCP："长度、0x01、VCP、校验"。校验和 MonitorControl、m1ddc 一样只从 0x6E 算起（不带 0x51），
    /// 显示器认的是这个
    static func getRequest(_ code: UInt8) -> [UInt8] {
        let body: [UInt8] = [0x82, 0x01, code]
        return body + [body.reduce(UInt8(0x6E), ^)]
    }

    /// 写一个 VCP："长度、0x03、VCP、高字节、低字节、校验"，校验从 0x6E ^ 0x51 算起
    static func setRequest(_ code: UInt8, value: Int) -> [UInt8] {
        let clamped = UInt16(max(0, min(Int(UInt16.max), value)))
        let body: [UInt8] = [0x84, 0x03, code, UInt8(clamped >> 8), UInt8(clamped & 0xFF)]
        return body + [body.reduce(UInt8(0x6E) ^ source, ^)]
    }

    enum Reply: Equatable {
        case value(DDCValue)
        /// 显示器回话了，但说不认这个 VCP
        case unsupported
        /// 没回话、回的不对或者校验不对：可以再试一次
        case invalid
    }

    /// 读回来的 11 个字节：源地址、长度、0x02、结果、VCP、类型、最大值（2 字节）、当前值（2 字节）、校验（从 0x50 算起）
    static func parse(_ reply: [UInt8], code: UInt8) -> Reply {
        guard reply.count == 11, reply.dropLast().reduce(UInt8(0x50), ^) == reply[10],
              reply[2] == 0x02, reply[4] == code else { return .invalid }
        guard reply[3] == 0 else { return .unsupported }
        return .value(DDCValue(current: Int(reply[8]) << 8 | Int(reply[9]), max: Int(reply[6]) << 8 | Int(reply[7])))
    }
}

/// 音量的折算：显示器自己的值（0…max）和音量条上的 0–100
enum DisplayVolumeScale {
    static func percent(_ raw: Int, max: Int) -> Int {
        guard max > 0 else { return 0 }
        return Swift.max(0, Swift.min(100, Int((Double(raw) * 100 / Double(max)).rounded())))
    }

    static func raw(_ percent: Int, max: Int) -> Int {
        Swift.max(0, Swift.min(max, Int((Double(Swift.max(0, Swift.min(100, percent))) * Double(max) / 100).rounded())))
    }
}

/// 所有 DDC 都在这一条队列上排着做：一次一件，读写不会交错
enum DDCQueue {
    static let queue = DispatchQueue(label: "MacTV.ddc", qos: .userInitiated)

    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}

/// 声音输出 → 它所在的显示器
enum DisplayAudioLink {
    /// 一块外接显示器在 IORegistry 里的样子：帧缓冲（AppleCLCD2）上记着它的 EDID UUID 和名字
    struct Candidate: Equatable {
        var edidUUID: String?
        var productName: String?
    }

    /// 显示器的声音（HDMI、DisplayPort 传过去的）才找显示器
    static func isDisplayAudio(_ device: AudioOutputDevice) -> Bool {
        device.transport == kAudioDeviceTransportTypeHDMI || device.transport == kAudioDeviceTransportTypeDisplayPort
    }

    /// 选哪一块：Apple 芯片上，显示器声音的 CoreAudio UID 就是显示器帧缓冲的 EDID UUID，先按这个对；
    /// 对不上再按名字（CoreAudio 里的名字是显示器 EDID 里的名字），名字只认独一个的。
    /// 都对不上就不用：声音可能是经功放出去的，调显示器的音量没用
    static func pick(_ candidates: [Candidate], uid: String, name: String) -> Int? {
        if !uid.isEmpty, let index = candidates.firstIndex(where: { $0.edidUUID?.caseInsensitiveCompare(uid) == .orderedSame }) {
            return index
        }
        let named = candidates.indices.filter { candidates[$0].productName == name && !name.isEmpty }
        return named.count == 1 ? named[0] : nil
    }

    /// 找这个输出所在显示器的 DDC（在 DDC 队列上扫一遍 IORegistry，几毫秒）。找不到、不是 Apple 芯片时为 nil
    static func find(_ device: AudioOutputDevice) async -> (any DisplayDDC)? {
        guard isDisplayAudio(device) else { return nil }
        #if arch(arm64)
        let (uid, name) = (device.uid, device.name)
        return await DDCQueue.run { AVServiceDDC.scan(uid: uid, name: name) }
        #else
        return nil
        #endif
    }
}

#if arch(arm64)
/// IOKit 里不公开的 IOAVService 函数（MonitorControl 用的同一组），运行时找出来
private struct AVServiceI2C: @unchecked Sendable {
    typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias Transfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    let create: Create
    let read: Transfer
    let write: Transfer

    static let shared: AVServiceI2C? = {
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let create = dlsym(iokit, "IOAVServiceCreateWithService"),
              let read = dlsym(iokit, "IOAVServiceReadI2C"),
              let write = dlsym(iokit, "IOAVServiceWriteI2C") else { return nil }
        return AVServiceI2C(create: unsafeBitCast(create, to: Create.self),
                            read: unsafeBitCast(read, to: Transfer.self),
                            write: unsafeBitCast(write, to: Transfer.self))
    }()
}

/// 一块外接显示器的 IOAVService。只在 DDCQueue 上用
final class AVServiceDDC: DisplayDDC, @unchecked Sendable {
    private let service: CFTypeRef
    private let i2c: AVServiceI2C

    private init(service: CFTypeRef, i2c: AVServiceI2C) {
        self.service = service
        self.i2c = i2c
    }

    func read(_ code: UInt8) async -> DDCValue? {
        await DDCQueue.run { self.readNow(code) }
    }

    @discardableResult
    func write(_ code: UInt8, value: Int) async -> Bool {
        guard SystemGuard.allows("write DDC \(code) = \(value)") else { return false }
        return await DDCQueue.run { self.writeNow(code, value: value) }
    }

    /// 时间和 MonitorControl 一样：发之前等 10 毫秒，发完等 50 毫秒再读；不对就隔 20 毫秒再来，最多 4 次
    private func readNow(_ code: UInt8) -> DDCValue? {
        for _ in 0..<4 {
            var request = DDCPacket.getRequest(code)
            usleep(10_000)
            if i2c.write(service, DDCPacket.address, UInt32(DDCPacket.source), &request, UInt32(request.count)) == kIOReturnSuccess {
                usleep(50_000)
                var reply = [UInt8](repeating: 0, count: 11)
                if i2c.read(service, DDCPacket.address, 0, &reply, UInt32(reply.count)) == kIOReturnSuccess {
                    switch DDCPacket.parse(reply, code: code) {
                    case .value(let value): return value
                    case .unsupported: return nil
                    case .invalid: break
                    }
                }
            }
            usleep(20_000)
        }
        return nil
    }

    /// 和 MonitorControl 一样发两遍（有的显示器会丢一遍）；发完静 50 毫秒，DDC/CI 要求下一句之前等这么久
    private func writeNow(_ code: UInt8, value: Int) -> Bool {
        var sent = false
        for _ in 0..<2 {
            var request = DDCPacket.setRequest(code, value: value)
            usleep(10_000)
            if i2c.write(service, DDCPacket.address, UInt32(DDCPacket.source), &request, UInt32(request.count)) == kIOReturnSuccess {
                sent = true
            }
        }
        usleep(50_000)
        if !sent { Log.audio.error("Couldn't send the display volume over DDC") }
        return sent
    }

    /// 扫一遍 IORegistry：外接显示器的帧缓冲（AppleCLCD2 / IOMobileFramebufferShim）和它的
    /// DCPAVServiceProxy（Location = External）配成对，再按 UID / 名字挑出这个输出的那一块。
    /// 配对先看名字的前缀（dispext0@… 的帧缓冲配 dispext0:dcpav-service-epic 下的那个），
    /// 没有前缀时按 MonitorControl 的办法：配前面最近的一个帧缓冲
    static func scan(uid: String, name: String) -> AVServiceDDC? {
        guard let i2c = AVServiceI2C.shared else { return nil }
        var iterator = io_iterator_t()
        guard IORegistryEntryCreateIterator(IORegistryGetRootEntry(kIOMainPortDefault), kIOServicePlane,
                                            IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var framebuffers: [(candidate: DisplayAudioLink.Candidate, prefix: String?)] = []
        var proxies: [(entry: io_service_t, prefix: String?, previous: Int?)] = []
        defer { for proxy in proxies { IOObjectRelease(proxy.entry) } }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            let entryName = registryName(entry)
            if entryName.contains("AppleCLCD2") || entryName.contains("IOMobileFramebufferShim") {
                let attributes = property(entry, "DisplayAttributes") as? [String: Any]
                let product = attributes?["ProductAttributes"] as? [String: Any]
                framebuffers.append((DisplayAudioLink.Candidate(edidUUID: property(entry, "EDID UUID") as? String,
                                                                productName: product?["ProductName"] as? String),
                                     parentName(entry).flatMap { $0.split(separator: "@").first.map(String.init) }))
            } else if entryName == "DCPAVServiceProxy", property(entry, "Location") as? String == "External" {
                IOObjectRetain(entry)
                proxies.append((entry, parentName(entry).flatMap { $0.split(separator: ":").first.map(String.init) },
                                framebuffers.indices.last))
            }
            IOObjectRelease(entry)
        }

        let paired: [(candidate: DisplayAudioLink.Candidate, entry: io_service_t)] = proxies.compactMap { proxy in
            let index = framebuffers.firstIndex { $0.prefix != nil && $0.prefix == proxy.prefix } ?? proxy.previous
            return index.map { (framebuffers[$0].candidate, proxy.entry) }
        }
        guard let chosen = DisplayAudioLink.pick(paired.map(\.candidate), uid: uid, name: name),
              let service = i2c.create(kCFAllocatorDefault, paired[chosen].entry)?.takeRetainedValue() else { return nil }
        return AVServiceDDC(service: service, i2c: i2c)
    }

    private static func registryName(_ entry: io_registry_entry_t) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(entry, &buffer)
        return String(cBuffer: buffer)
    }

    private static func parentName(_ entry: io_registry_entry_t) -> String? {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(parent) }
        return registryName(parent)
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
#endif
