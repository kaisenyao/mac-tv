import Compression
import Foundation

/// 直播间弹幕的协议（和网页版一样，走 WebSocket）。
///
/// 每个包前面是 16 字节的头：整包长度（4）、头长 16（2）、协议版本（2）、操作码（4）、序号（4），都是大端。
/// 一帧里可能连着好几个包；协议版本 3 的包身是 brotli 压缩过的一串包（版本 2 是 zlib），版本 0、1 的包身就是内容。
/// 操作码：7 进房间（交凭证），8 是它的回答；2 心跳（30 秒一次），3 是它的回答；5 是消息（JSON，cmd 说是什么）
enum BiliLiveDanmakuProtocol {
    struct Packet: Equatable, Sendable {
        var version: UInt16
        var operation: UInt32
        var body: Data
    }

    static let heartbeat: UInt32 = 2, message: UInt32 = 5, enter: UInt32 = 7, enterReply: UInt32 = 8

    /// 一个包：头 + 包身
    static func encode(operation: UInt32, body: Data, version: UInt16 = 1) -> Data {
        var data = Data(capacity: 16 + body.count)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
        append(UInt32(16 + body.count))
        append(UInt16(16))
        append(version)
        append(operation)
        append(UInt32(1))
        data.append(body)
        return data
    }

    /// 进房间的包。uid 是登录的账号（没登录是 0），buvid 是设备标识，key 是 getDanmuInfo 给的凭证
    static func enter(room: Int, uid: Int, buvid: String, key: String) -> Data {
        let body: [String: Any] = ["uid": uid, "roomid": room, "protover": 3, "buvid": buvid, "platform": "web", "type": 2, "key": key]
        return encode(operation: enter, body: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
    }

    /// 一帧拆成一个个包；压缩过的（版本 2、3）解开后接着拆。返回的都是解开以后的
    static func packets(in frame: Data) -> [Packet] {
        unpack(frame, depth: 0)
    }

    private static func unpack(_ frame: Data, depth: Int) -> [Packet] {
        let bytes = [UInt8](frame)
        func number(_ at: Int, _ length: Int) -> Int { (at..<(at + length)).reduce(0) { $0 << 8 | Int(bytes[$1]) } }
        var packets: [Packet] = []
        var offset = 0
        while offset + 16 <= bytes.count {
            let length = number(offset, 4), header = number(offset + 4, 2)
            guard header >= 16, length >= header, offset + length <= bytes.count else { break }   // 坏的：后面的不要了
            let packet = Packet(version: UInt16(number(offset + 6, 2)), operation: UInt32(number(offset + 8, 4)),
                                body: Data(bytes[(offset + header)..<(offset + length)]))
            switch packet.version {
            case 3 where depth == 0: packets += brotli(packet.body).map { unpack($0, depth: 1) } ?? []
            case 2 where depth == 0: packets += zlib(packet.body).map { unpack($0, depth: 1) } ?? []
            default: packets.append(packet)
            }
            offset += length
        }
        return packets
    }

    /// 消息里的一条弹幕（cmd 是 DANMU_MSG 开头的）：只要内容、颜色、怎么走（飘的、顶上的、底下的）。
    /// 别的消息（礼物、进场、人气……）、高级弹幕是 nil。出现的时间先写 time，用的地方按画面的时间排
    static func danmaku(from body: Data, at time: Double = 0) -> BiliDanmaku? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let command = json["cmd"] as? String, command.hasPrefix("DANMU_MSG"),
              let info = json["info"] as? [Any], info.count > 1,
              let meta = info[0] as? [Any], meta.count > 3, let raw = info[1] as? String else { return nil }
        let text = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let kind: BiliDanmaku.Kind
        switch (meta[1] as? NSNumber)?.intValue ?? 1 {   // 和视频弹幕的 mode 一样
        case 1, 2, 3, 6: kind = .scroll
        case 5: kind = .top
        case 4: kind = .bottom
        default: return nil
        }
        let color = UInt32(truncatingIfNeeded: (meta[3] as? NSNumber)?.intValue ?? 0xFFFFFF) & 0xFFFFFF
        return BiliDanmaku(time: time, kind: kind, size: 1, color: color, text: text)
    }

    // MARK: 解压

    /// 解开以后最多这么大（一帧正常只有几 KB；防着坏数据把内存撑爆）
    private static let largest = 4 << 20

    static func brotli(_ data: Data) -> Data? { decompress(data, COMPRESSION_BROTLI) }

    /// zlib：前面两个字节的头去掉，剩下的是 deflate（系统的 COMPRESSION_ZLIB 认的就是这个）
    static func zlib(_ data: Data) -> Data? {
        guard data.count > 2, data[data.startIndex] & 0x0F == 8 else { return nil }
        return decompress(data.dropFirst(2), COMPRESSION_ZLIB)
    }

    private static func decompress(_ data: Data, _ algorithm: compression_algorithm) -> Data? {
        guard !data.isEmpty else { return nil }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(stream) }
        let size = 64 << 10
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        var output = Data()
        return data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Data? in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return nil }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = source.count
            while true {
                let left = stream.pointee.src_size
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = size
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = size - stream.pointee.dst_size
                output.append(buffer, count: produced)
                guard output.count <= largest else { return nil }
                switch status {
                case COMPRESSION_STATUS_END: return output
                case COMPRESSION_STATUS_OK where produced > 0 || stream.pointee.src_size < left: continue
                default: return nil   // 出错了，或者再也走不动（数据不完整）
                }
            }
        }
    }
}

/// 连着一个直播间的弹幕服务器：收到一条弹幕就交出去。断了 2、4、8 秒后各再连一次，还不行就算了（不打扰人）；
/// 连上过一阵子才断的重新算。不记弹幕内容、发弹幕的人，只记几条、连上没有、为什么断了
actor BiliLiveDanmakuConnection {
    private let room: Int
    private let uid: Int
    private let cookie: String
    private let key: String
    private let deliver: @MainActor @Sendable (BiliDanmaku) -> Void
    private var received = 0
    private var countedSince = Date()

    /// 不存东西、不收发 cookie 的连接（凭证在进房间的包里）
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()

    /// uid、cookie：登录着就是账号的（和取直播流一样），没登录是 0 和空的（会补上匿名的设备标识）；key 是请求签名的密钥
    init(room: Int, uid: Int, cookie: String, key: String, deliver: @escaping @MainActor @Sendable (BiliDanmaku) -> Void) {
        self.room = room
        self.uid = uid
        self.cookie = cookie
        self.key = key
        self.deliver = deliver
    }

    /// 连上、收、断了再连，直到这个任务被取消（离开直播间、关了弹幕）
    func run() async {
        var failures = 0
        while !Task.isCancelled {
            let started = Date()
            let reason = await connectOnce()
            guard !Task.isCancelled else { break }
            if Date().timeIntervalSince(started) > 60 { failures = 0 }
            failures += 1
            guard failures <= 3 else {
                Log.playback.info("bilibili live danmaku \(self.room, privacy: .public): disconnected (\(reason, privacy: .public)), giving up")
                return
            }
            let delay = 1 << failures   // 2、4、8 秒
            Log.playback.info("bilibili live danmaku \(self.room, privacy: .public): disconnected (\(reason, privacy: .public)), again in \(delay, privacy: .public)s")
            try? await Task.sleep(for: .seconds(delay))
        }
        Log.playback.info("bilibili live danmaku \(self.room, privacy: .public): disconnected (left), \(self.received, privacy: .public) in the last minute")
    }

    /// 要一次服务器和凭证，几台服务器挨个试；连上过就不换下一台（交给 run 等一会儿再从头来）
    private func connectOnce() async -> String {
        guard let server = await BiliAPI.liveDanmakuServer(room: room, key: key, cookie: cookie) else { return "no server info" }
        var reason = "no server"
        for host in server.hosts.prefix(3) {
            let socket = Self.session.webSocketTask(with: host)
            socket.resume()
            let result = await withTaskCancellationHandler {
                await talk(socket, server: server)
            } onCancel: {
                socket.cancel(with: .goingAway, reason: nil)
            }
            socket.cancel(with: .goingAway, reason: nil)
            reason = result.reason
            if result.connected || Task.isCancelled { break }
        }
        return reason
    }

    /// 进房间、心跳、收消息，直到断开。返回连上过没有、为什么断了
    private func talk(_ socket: URLSessionWebSocketTask, server: BiliLiveDanmakuServer) async -> (connected: Bool, reason: String) {
        var connected = false
        var heartbeat: Task<Void, Never>?
        defer { heartbeat?.cancel() }
        do {
            try await socket.send(.data(BiliLiveDanmakuProtocol.enter(room: room, uid: uid, buvid: server.buvid, key: server.token)))
            while !Task.isCancelled {
                guard case .data(let frame) = try await socket.receive() else { continue }
                for packet in BiliLiveDanmakuProtocol.packets(in: frame) {
                    switch packet.operation {
                    case BiliLiveDanmakuProtocol.enterReply:
                        let code = (try? JSONSerialization.jsonObject(with: packet.body) as? [String: Any])?["code"] as? Int
                        guard code == 0 else { return (false, "refused \(code ?? -1)") }
                        connected = true
                        countedSince = Date()
                        received = 0
                        Log.playback.info("bilibili live danmaku \(self.room, privacy: .public): connected (\(socket.originalRequest?.url?.host ?? "", privacy: .public))")
                        heartbeat = Task {
                            let ping = BiliLiveDanmakuProtocol.encode(operation: BiliLiveDanmakuProtocol.heartbeat, body: Data())
                            while !Task.isCancelled {
                                try? await socket.send(.data(ping))
                                try? await Task.sleep(for: .seconds(30))
                            }
                        }
                    case BiliLiveDanmakuProtocol.message:
                        guard let item = BiliLiveDanmakuProtocol.danmaku(from: packet.body) else { continue }
                        received += 1
                        await deliver(item)
                    default: break
                    }
                }
                if Date().timeIntervalSince(countedSince) >= 60 {
                    Log.playback.info("bilibili live danmaku \(self.room, privacy: .public): \(self.received, privacy: .public) in the last minute")
                    received = 0
                    countedSince = Date()
                }
            }
            return (connected, "left")
        } catch {
            return (connected, Task.isCancelled ? "left" : "socket closed \((error as? URLError)?.code.rawValue ?? 0)")
        }
    }
}
