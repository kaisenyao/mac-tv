import Foundation

/// 遥控器、音量面板上对音量做的一件事
enum VolumeAction: Equatable, Sendable {
    case step(Int)
    case set(Int)
    case toggleMute
    /// 只看一眼（打开音量面板时）
    case refresh
}

/// 显示器的音量，按 Mac TV 这边记着的样子（一连串按键里在本地算，不每次去读显示器）
struct DisplayVolumeModel: Equatable {
    /// 显示器自己的最大值（多是 100）
    var max: Int
    /// 0–100，音量条上的。静音时是静音前的音量
    var level: Int
    var muted: Bool
    /// 显示器认 0x8D 静音；不认时静音 = 把音量写成 0，取消静音再写回 level
    var muteCommand: Bool

    /// 一串按键开头读到的：音量和静音（mute 为 nil = 不认 0x8D）。
    /// 上次是假静音（写了 0）、显示器的音量还是 0：还在静音，记着的音量不丢；别处调过了就照读到的来
    init(volume: DDCValue, mute: DDCValue?, previous: DisplayVolumeModel?) {
        max = Swift.max(1, volume.max)
        let read = DisplayVolumeScale.percent(volume.current, max: max)
        if let mute, mute.current == VCP.muteOn || mute.current == VCP.muteOff {
            muteCommand = true
            muted = mute.current == VCP.muteOn
            level = read
        } else if let previous, previous.muted, !previous.muteCommand, volume.current == 0 {
            muteCommand = false
            muted = true
            level = previous.level
        } else {
            muteCommand = false
            muted = false
            level = read
        }
    }

    /// 和 Mac 的音量键一样：调大顺带取消静音，调小不取消
    mutating func apply(_ action: VolumeAction) {
        switch action {
        case .step(let delta):
            if delta > 0 { muted = false }
            level = Swift.max(0, Swift.min(100, level + delta))
        case .set(let value):
            level = Swift.max(0, Swift.min(100, value))
            muted = false
        case .toggleMute:
            muted.toggle()
        case .refresh:
            break
        }
    }

    /// 显示器认的 0x8D 其实不管用：改成假静音
    mutating func dropMuteCommand() { muteCommand = false }

    /// 要写给显示器的
    var target: DisplayTarget {
        DisplayTarget(raw: muted && !muteCommand ? 0 : DisplayVolumeScale.raw(level, max: max),
                      muted: muteCommand ? muted : nil)
    }

    var volume: VolumeLevel { VolumeLevel(level: level, muted: muted) }
}

/// 写给显示器的值：音量（显示器自己的单位）和 0x8D 静音（nil = 不用 0x8D）
struct DisplayTarget: Equatable, Sendable {
    var raw: Int
    var muted: Bool?
}

/// 只写最新的值：写着的时候来的都合成一个，两次写之间至少隔 interval，最后总是停在最后一个值上
@MainActor
final class LatestValueWriter<Value: Equatable & Sendable> {
    private let interval: Duration
    private let write: @MainActor (Value?, Value) async -> Void
    private(set) var written: Value?
    private var target: Value?
    private var running: Task<Void, Never>?

    init(interval: Duration, write: @escaping @MainActor (_ previous: Value?, _ next: Value) async -> Void) {
        self.interval = interval
        self.write = write
    }

    var isIdle: Bool { running == nil }

    /// 显示器上现在就是这个值（刚读到的）：不用再写
    func reset(to value: Value) {
        written = value
        target = value
    }

    func submit(_ value: Value) {
        target = value
        guard running == nil, value != written else { return }
        running = Task { [weak self] in await self?.drain() }
    }

    /// 等写完（测试用）
    func finish() async { await running?.value }

    private func drain() async {
        let clock = ContinuousClock()
        while let next = target, next != written {
            let started = clock.now
            let previous = written
            written = next
            await write(previous, next)
            try? await clock.sleep(until: started.advanced(by: interval))
        }
        running = nil
    }
}

/// 一块显示器的音量，经 DDC。一串按键开头读一次显示器（这样不和 MonitorControl、显示器自己的按键打架），
/// 之后在本地一格一格算、马上出音量条；写在后台队列上，合着写、最多每 interval 一次。按键之间什么都不跑
@MainActor
final class DisplayVolumeController {
    private let ddc: any DisplayDDC
    /// 隔这么久没按，下一下算新的一串，重新读显示器
    var burstGap: Duration = .milliseconds(1500)
    private(set) var model: DisplayVolumeModel?
    /// 读过、回过话（之后再读不到多半是显示器重新连过，换一个新的 IOAVService 再试）
    private(set) var answered = false
    var onLevel: (VolumeLevel) -> Void = { _ in }
    /// 显示器不回话：这些按键交回去另想办法
    var onUnavailable: ([VolumeAction]) -> Void = { _ in }

    private var queued: [VolumeAction] = []
    private var reading = false
    private var lastAction: ContinuousClock.Instant?
    /// 认 0x8D 的显示器第一次静音时读回来看一眼：没静下来就改成写 0
    private var muteChecked = false
    private var muteBroken = false
    private var writer: LatestValueWriter<DisplayTarget>!

    init(ddc: any DisplayDDC, writeInterval: Duration = .milliseconds(60)) {
        self.ddc = ddc
        writer = LatestValueWriter(interval: writeInterval) { [weak self] previous, next in
            await self?.send(previous, next)
        }
    }

    func perform(_ action: VolumeAction) {
        queued.append(action)
        guard !reading else { return }
        if model == nil || startsBurst { read() } else { flush() }
    }

    private var startsBurst: Bool {
        guard writer.isIdle else { return false }
        guard let lastAction else { return true }
        return ContinuousClock.now - lastAction > burstGap
    }

    /// 等写完（测试用）
    func finishWriting() async { await writer.finish() }

    private func read() {
        reading = true
        let readMute = !muteBroken
        let ddc = ddc
        Task { [weak self] in
            let volume = await ddc.read(VCP.volume)
            let mute = volume != nil && readMute ? await ddc.read(VCP.mute) : nil
            self?.finishRead(volume: volume, mute: mute)
        }
    }

    private func finishRead(volume: DDCValue?, mute: DDCValue?) {
        reading = false
        guard let volume, volume.max > 0 else {
            let actions = queued
            queued = []
            model = nil
            onUnavailable(actions)
            return
        }
        let fresh = DisplayVolumeModel(volume: volume, mute: muteBroken ? nil : mute, previous: model)
        model = fresh
        answered = true
        writer.reset(to: fresh.target)
        flush()
    }

    private func flush() {
        guard var model else { return }
        for action in queued { model.apply(action) }
        queued = []
        self.model = model
        lastAction = .now
        writer.submit(model.target)
        onLevel(model.volume)
    }

    /// 静音先静再改音量，取消静音先改音量再放出声音：中间不会响一下
    private func send(_ previous: DisplayTarget?, _ next: DisplayTarget) async {
        if next.muted == true, previous?.muted != true {
            await ddc.write(VCP.mute, value: VCP.muteOn)
            if !muteChecked { await checkMute() }
        }
        if next.raw != previous?.raw { await ddc.write(VCP.volume, value: next.raw) }
        if next.muted == false, previous?.muted == true { await ddc.write(VCP.mute, value: VCP.muteOff) }
    }

    /// 有的显示器说认 0x8D，写了却不静音：读回来不是"静音"就改成假静音（写 0），以后都这样。
    /// 也有的其实静了、只是读回来的不对：先写一次"不静音"，不然以后再也不发 0x8D，显示器就一直静着
    private func checkMute() async {
        guard let after = await ddc.read(VCP.mute) else { return }
        muteChecked = true
        guard after.current != VCP.muteOn, model != nil else { return }
        muteBroken = true
        await ddc.write(VCP.mute, value: VCP.muteOff)
        guard var model else { return }   // 写的时候又按过：用最新的
        model.dropMuteCommand()
        self.model = model
        writer.submit(model.target)
    }
}
