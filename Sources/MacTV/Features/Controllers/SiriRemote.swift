import Foundation
import IOKit.hid

// Siri Remote（USB-C 那一代，蓝牙 VID 0x004C、PID 0x0316；macOS 27.2.1 起系统才认得它）。
//
// 实测（Mac mini，macOS 27.2.1）：
//   - 按键都在 Consumer 接口（UsagePage 12、Usage 1）的 3 字节报告里，一个键一位，按下 / 松开各一条。
//     按住不会重发，按住和连发要自己用计时器认。
//   - 触控面（整块圆盘，Apple 叫 clickpad）的手指位置，公开接口（HID、GameController、系统事件）都拿不到，
//     只有私有的 MultitouchSupport 给（family 145，6×12 传感器，手指在上面时约 67 帧 / 秒，不碰不发）。
//     这是私有接口，以后的 macOS 可能会变；变了只是转圈、滑动不灵，按键不受影响。
//   - 音量、静音、播放暂停、电源（关屏幕）系统自己也处理：音量 HUD 会弹两次、媒体键会发给别的 App。
//     所以 Mac TV 开着时独占（seize）这个接口，只有 Mac TV 处理；Mac TV 退出，系统自动接回去。
//   - Siri 键系统不处理。

/// One physical button on the Siri Remote.
enum SiriRemoteButton: Hashable, CaseIterable {
    case up, down, left, right, select, back, tv, playPause, volumeUp, volumeDown, mute, siri, power

    /// The button an element of the remote's Consumer interface reports.
    init?(usagePage: UInt32, usage: UInt32) {
        switch (usagePage, usage) {
        case (0x0C, 0x42): self = .up
        case (0x0C, 0x43): self = .down
        case (0x0C, 0x44): self = .left
        case (0x0C, 0x45): self = .right
        case (0x0C, 0x80): self = .select      // 圆盘中间按下去
        case (0x01, 0x86): self = .back        // Generic Desktop · System App Menu
        case (0x0C, 0x60): self = .tv
        case (0x0C, 0xCD): self = .playPause
        case (0x0C, 0xE9): self = .volumeUp
        case (0x0C, 0xEA): self = .volumeDown
        case (0x0C, 0xE2): self = .mute
        case (0x0C, 0x04): self = .siri
        case (0x0C, 0x30): self = .power
        default: return nil
        }
    }

    /// Buttons that are the clickpad itself: pressing one means the finger on it is a click, not a gesture.
    var isClickpad: Bool {
        switch self {
        case .up, .down, .left, .right, .select: true
        default: false
        }
    }
}

/// What the Siri Remote asks Mac TV to do. Presses and swipes use the phone remote's own
/// messages, so the two remotes behave the same (PhonePresses, TrackpadGestures).
enum SiriRemoteAction: Equatable {
    /// 圆盘上下左右、中间、返回、TV 键：和手机遥控器一样报"点了一下 / 按住了 / 还按着 / 松开了"
    case press(PhonePresses.Key, PhonePresses.Phase)
    case playPause
    case volume(Int), mute
    /// 沿外圈转了一格：+1 顺时针，-1 逆时针（一圈 8 格）
    case wheel(Int)
    /// A light tap on the clickpad, without pressing it (see SiriRemoteTouch)
    case tap
    /// 在触控面上滑：和手机遥控器触控板上的双指滑动一样
    /// （phase：began、changed、ended、momentum、momentumEnd；单位是点，手指往左 / 往上为负）
    case swipe(dx: Double, dy: Double, phase: String)
}

// MARK: - Buttons

/// Presses, holds and repeats for the remote's buttons. Time is passed in, so this is plain logic.
///
/// - The clickpad (directions and centre), Back, TV and Power are timed by PressTiming, as every input's are:
///   tap / hold / alive / release (InputTiming). What they mean is PhonePresses' job, the same as the phone's.
/// - Volume acts on press and repeats while held (after 0.45 s, every 0.16 s), like the phone's volume keys.
/// - Play/Pause and Mute act on press. Siri does nothing: no command, no activity, no wake.
struct SiriRemoteButtons {
    static let volumeDelay: TimeInterval = 0.45
    static let volumeInterval: TimeInterval = 0.16

    private var keys = PressTiming()
    /// Volume buttons held, and when each repeats next; the other buttons that act on press, while down.
    private var volume: [SiriRemoteButton: TimeInterval] = [:]
    private var down: Set<SiriRemoteButton> = []

    var isClickpadDown: Bool { down.contains { $0.isClickpad } }

    /// The next time `advance(to:)` has something to do, if any.
    var nextDeadline: TimeInterval? { ([keys.nextDeadline] + volume.values.map(Optional.some)).compactMap { $0 }.min() }

    mutating func press(_ button: SiriRemoteButton, at time: TimeInterval) -> [SiriRemoteAction] {
        guard down.insert(button).inserted else { return [] }
        if let key = Self.key(button) {
            keys.press(key, at: time)
            return []
        }
        switch button {
        case .volumeUp, .volumeDown:
            volume[button] = time + Self.volumeDelay
            return [Self.volume(button)]
        case .playPause: return [.playPause]
        case .mute: return [.mute]
        default: return []      // Siri: nothing
        }
    }

    mutating func release(_ button: SiriRemoteButton, at time: TimeInterval) -> [SiriRemoteAction] {
        guard down.remove(button) != nil else { return [] }
        volume[button] = nil
        guard let key = Self.key(button), let phase = keys.release(key) else { return [] }
        return [.press(key, phase)]
    }

    /// Fires holds, "still held" and volume repeats that are due. A late timer gives one, not a burst.
    mutating func advance(to time: TimeInterval) -> [SiriRemoteAction] {
        var actions = keys.advance(to: time).map { SiriRemoteAction.press($0.0, $0.1) }
        for button in SiriRemoteButton.allCases {
            guard let next = volume[button], next <= time + 0.001 else { continue }
            actions.append(Self.volume(button))
            volume[button] = time + Self.volumeInterval
        }
        return actions
    }

    /// Lets go of everything, e.g. when the remote disconnects mid-press: holds are released, taps dropped.
    mutating func reset() -> [SiriRemoteAction] {
        down = []
        volume = [:]
        return keys.reset().map { .press($0.0, $0.1) }
    }

    private static func key(_ button: SiriRemoteButton) -> PhonePresses.Key? {
        switch button {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .select: .select
        case .back: .back
        case .tv: .home        // the TV button: the Home Screen; twice, the App Switcher; held, Control Center
        case .power: .power    // pressed, wakes from TV standby; held, TV standby
        default: nil
        }
    }

    private static func volume(_ button: SiriRemoteButton) -> SiriRemoteAction {
        .volume(button == .volumeUp ? 6 : -6)      // 和手机遥控器的音量键一样
    }
}

// MARK: - Touch

/// Turns finger positions on the clickpad into wheel steps (along the outer edge) or swipes.
///
/// Positions are 0–1 with the origin at the bottom left, as MultitouchSupport reports them.
/// The thumb often rests on the clickpad and rolls a little before each click, so a stroke
/// stays undecided (sending nothing) until it is clearly one of:
/// - a turn: the finger stays away from the middle and goes at least 25° around within 0.6 s
///   (a thumb's arc is far from a circle around the middle, so only the angle counts);
/// - a swipe: the finger covers 22% of the pad within a quarter of a second.
/// Anything slower is a resting thumb. A click always wins over both (see SiriRemoteRecognizer).
struct SiriRemoteTouch {
    /// 一格的角度：45 度，一圈 8 格（遥控器的圆盘比手机上的转盘小得多，16 格太灵敏）
    static let wheelUnit = Double.pi / 4
    /// 转了这么多才算"在转"（这一段不算格数，和手机一样）
    static let turnStart = 25 * Double.pi / 180
    /// 转圈时手指一直离圆心至少这么远（半径 0.5）。拇指画的圈不圆，远近变化很大，只看这个下限
    static let ringRadius = 0.22
    /// 滑动：这么短的时间里走过这么远（圆盘直径的比例）
    static let swipeWindow: TimeInterval = 0.25
    static let swipeDistance = 0.22
    /// 还没决定的一段超过这么久就从头算（拇指搭着慢慢挪，不会攒成一次转圈）
    static let undecidedSpan: TimeInterval = 0.6
    /// 离圆心太近时角度乱跳，不算
    static let centerDeadZone = 0.1
    /// 触控面一整个宽度算多少点（和手机触控板上双指滑过的点数差不多）
    static let swipeScale = 500.0
    /// A tap: the finger down and up this quickly, moving this little, with no click. Anything longer is a resting
    /// thumb, which HIG warns isn't a tap.
    static let tapTime: TimeInterval = 0.25
    static let tapTravel = 0.04

    struct Point: Equatable {
        var x: Double, y: Double
        var offset: Double { hypot(x - 0.5, y - 0.5) }
        var angle: Double { atan2(y - 0.5, x - 0.5) }
    }

    /// 还没决定的这一段
    private struct Stroke {
        var startedAt: TimeInterval
        var points: [(point: Point, time: TimeInterval)]
        var sweep = 0.0
        var minOffset: Double

        init(_ point: Point, at time: TimeInterval) {
            startedAt = time
            points = [(point, time)]
            minOffset = point.offset
        }

        mutating func add(_ point: Point, at time: TimeInterval) {
            if let last = points.last?.point, point.offset >= centerDeadZone, last.offset >= centerDeadZone {
                sweep += SiriRemoteTouch.turn(from: last, to: point)
            }
            points.append((point, time))
            minOffset = min(minOffset, point.offset)
        }

        /// Going around, not across the middle.
        var turning: Bool { minOffset >= ringRadius && abs(sweep) >= turnStart }
    }

    private enum State {
        case idle
        case undecided(Stroke)
        case turning(last: Point, sum: Double)
        /// 最近的移动（点、毫秒）留着算手指离开时的速度
        case swiping(last: Point, samples: [(dx: Double, dy: Double, ms: Double)])
        /// 这一下是按键，手指抬起来之前什么都不发
        case ignored
    }
    private var state = State.idle
    /// When the finger came down (a tap is the whole touch, not the stroke being decided)
    private var downAt: TimeInterval = 0

    /// 手指离开时的速度（点 / 毫秒）：滑动结束后的惯性从这里开始
    private(set) var releaseVelocity: (x: Double, y: Double)?

    /// One frame from the touch surface: where the finger is, or nil when it lifted.
    mutating func frame(_ point: Point?, at time: TimeInterval) -> [SiriRemoteAction] {
        releaseVelocity = nil
        let ms = time * 1000
        guard let point else {
            defer { state = .idle }
            if case .swiping(_, let samples) = state {
                releaseVelocity = Self.velocity(samples, now: ms)
                return [.swipe(dx: 0, dy: 0, phase: "ended")]
            }
            if case .undecided(let stroke) = state, time - downAt <= Self.tapTime,
               let first = stroke.points.first?.point,
               stroke.points.allSatisfy({ hypot($0.point.x - first.x, $0.point.y - first.y) <= Self.tapTravel }) {
                return [.tap]
            }
            return []
        }
        switch state {
        case .idle:
            state = .undecided(Stroke(point, at: time))
            downAt = time
            return []
        case .ignored:
            return []
        case .undecided(var stroke):
            stroke.add(point, at: time)
            if stroke.turning {
                state = .turning(last: point, sum: 0)
                return []
            }
            // 滑动：最近四分之一秒里走得够远
            if let from = stroke.points.first(where: { time - $0.time <= Self.swipeWindow })?.point,
               hypot(point.x - from.x, point.y - from.y) >= Self.swipeDistance {
                let (dx, dy) = Self.moved(from: from, to: point)
                state = .swiping(last: point, samples: [(dx, dy, ms)])
                return [.swipe(dx: 0, dy: 0, phase: "began"), .swipe(dx: dx, dy: dy, phase: "changed")]
            }
            // 慢慢挪：从这里重新算
            state = .undecided(time - stroke.startedAt > Self.undecidedSpan ? Stroke(point, at: time) : stroke)
            return []
        case .turning(let last, let sum):
            state = .turning(last: point, sum: sum)
            guard point.offset >= Self.centerDeadZone, last.offset >= Self.centerDeadZone else { return [] }
            return wheelSteps(adding: Self.turn(from: last, to: point), at: point)
        case .swiping(let last, var samples):
            let (dx, dy) = Self.moved(from: last, to: point)
            samples.append((dx, dy, ms))
            if samples.count > 12 { samples.removeFirst() }
            state = .swiping(last: point, samples: samples)
            return [.swipe(dx: dx, dy: dy, phase: "changed")]
        }
    }

    /// The clickpad was pressed: the click wins. A swipe in progress ends (without a glide),
    /// a turn stops, and the finger is ignored until it lifts.
    mutating func cancel() -> [SiriRemoteAction] {
        defer { state = .ignored }
        if case .swiping = state { return [.swipe(dx: 0, dy: 0, phase: "ended"), .swipe(dx: 0, dy: 0, phase: "momentumEnd")] }
        return []
    }

    /// Drops the stroke; a swipe in progress ends without inertia.
    mutating func reset() -> [SiriRemoteAction] {
        defer { state = .idle }
        if case .swiping = state { return [.swipe(dx: 0, dy: 0, phase: "ended"), .swipe(dx: 0, dy: 0, phase: "momentumEnd")] }
        return []
    }

    private mutating func wheelSteps(adding angle: Double, at point: Point) -> [SiriRemoteAction] {
        guard case .turning(_, var sum) = state else { return [] }
        // 坐标原点在左下：逆时针角度变大。顺时针（角度变小）是 +1
        sum -= angle
        let steps = Int(sum / Self.wheelUnit)
        sum -= Double(steps) * Self.wheelUnit
        state = .turning(last: point, sum: sum)
        return steps == 0 ? [] : Array(repeating: .wheel(steps > 0 ? 1 : -1), count: abs(steps))
    }

    fileprivate static func turn(from a: Point, to b: Point) -> Double {
        var d = b.angle - a.angle
        if d > .pi { d -= 2 * .pi }
        if d < -.pi { d += 2 * .pi }
        return d
    }

    /// Like the phone's two-finger swipe: the finger moving left or up gives negative values.
    private static func moved(from a: Point, to b: Point) -> (Double, Double) {
        ((b.x - a.x) * swipeScale, -(b.y - a.y) * swipeScale)
    }

    /// 和手机一样：最后 90 毫秒里走了多远 ÷ 用了多久（至少按 16 毫秒算）
    private static func velocity(_ samples: [(dx: Double, dy: Double, ms: Double)], now: Double) -> (x: Double, y: Double)? {
        let recent = samples.filter { now - $0.ms < 90 }
        guard recent.count >= 2, let first = recent.first, let last = recent.last else { return nil }
        let dt = max(16, last.ms - first.ms)
        return (recent.reduce(0) { $0 + $1.dx } / dt, recent.reduce(0) { $0 + $1.dy } / dt)
    }
}

/// The glide after a swipe, the same as the phone remote's: it slows a little every millisecond
/// (like a Mac trackpad) and reports what it moved every 33 ms until it's nearly still.
struct SiriRemoteInertia {
    static let decayPerMs = 0.9965
    static let startSpeed = 0.25     // 点 / 毫秒：比这慢就不甩了
    static let stopSpeed = 0.04
    static let reportInterval = 0.033

    private var velocity: (x: Double, y: Double)
    private var last: TimeInterval
    private var reportedAt: TimeInterval
    private var pending = (x: 0.0, y: 0.0)
    private(set) var nextDeadline: TimeInterval?

    /// nil when the finger left too slowly to glide.
    init?(velocity: (x: Double, y: Double), at time: TimeInterval) {
        guard hypot(velocity.x, velocity.y) >= Self.startSpeed else { return nil }
        self.velocity = velocity
        last = time
        reportedAt = time
        nextDeadline = time + Self.reportInterval
    }

    /// Glides up to `time`. Returns what to send; `nextDeadline` is nil once it has stopped.
    mutating func advance(to time: TimeInterval) -> [SiriRemoteAction] {
        guard nextDeadline != nil else { return [] }
        var t = last
        while t < time {
            let step = min(0.016, time - t)
            let decay = pow(Self.decayPerMs, step * 1000)
            velocity.x *= decay
            velocity.y *= decay
            pending.x += velocity.x * step * 1000
            pending.y += velocity.y * step * 1000
            t += step
        }
        last = time
        var actions: [SiriRemoteAction] = []
        if time - reportedAt >= Self.reportInterval - 0.001 {
            actions.append(.swipe(dx: pending.x, dy: pending.y, phase: "momentum"))
            pending = (0, 0)
            reportedAt = time
        }
        if hypot(velocity.x, velocity.y) < Self.stopSpeed {
            actions.append(.swipe(dx: 0, dy: 0, phase: "momentumEnd"))
            nextDeadline = nil
        } else {
            nextDeadline = time + Self.reportInterval
        }
        return actions
    }

    /// A finger landed on the surface: the glide stops.
    mutating func stop() -> [SiriRemoteAction] {
        guard nextDeadline != nil else { return [] }
        nextDeadline = nil
        return [.swipe(dx: 0, dy: 0, phase: "momentumEnd")]
    }
}

// MARK: - Recognizer

/// Buttons and touch together. A click on the clickpad always counts and ends the touch stroke
/// under it: with the thumb resting on the pad, the finger always moves a little before a click.
struct SiriRemoteRecognizer {
    private(set) var buttons = SiriRemoteButtons()
    private(set) var touch = SiriRemoteTouch()
    private var inertia: SiriRemoteInertia?

    /// When the one timer should fire next: a hold, a repeat or the next frame of a glide.
    var nextDeadline: TimeInterval? {
        [buttons.nextDeadline, inertia?.nextDeadline].compactMap { $0 }.min()
    }

    mutating func press(_ button: SiriRemoteButton, at time: TimeInterval) -> [SiriRemoteAction] {
        // 按下去是确定的：滑完的惯性停下；按的是圆盘的话，正在滑、正在转也停下，这一下按键照常算
        // （拇指搭着时按之前手指总会挪一点）
        let stopped = stopInertia() + (button.isClickpad ? touch.cancel() : [])
        return stopped + buttons.press(button, at: time)
    }

    mutating func release(_ button: SiriRemoteButton, at time: TimeInterval) -> [SiriRemoteAction] {
        buttons.release(button, at: time)
    }

    mutating func touchFrame(_ point: SiriRemoteTouch.Point?, at time: TimeInterval) -> [SiriRemoteAction] {
        // 手指放上去：正在滑的惯性停下（和触控板一样）
        var actions = point != nil ? stopInertia() : []
        // 按着圆盘时手指当然在上面：那是按键，不是滑动
        if point != nil, buttons.isClickpadDown { return actions + touch.cancel() }
        actions += touch.frame(point, at: time)
        if point == nil, actions.contains(.swipe(dx: 0, dy: 0, phase: "ended")) {
            if let velocity = touch.releaseVelocity, let glide = SiriRemoteInertia(velocity: velocity, at: time) {
                inertia = glide
            } else {
                actions.append(.swipe(dx: 0, dy: 0, phase: "momentumEnd"))
            }
        }
        return actions
    }

    mutating func advance(to time: TimeInterval) -> [SiriRemoteAction] {
        var actions = buttons.advance(to: time)
        if var glide = inertia, let deadline = glide.nextDeadline, deadline <= time + 0.001 {
            actions += glide.advance(to: time)
            inertia = glide.nextDeadline == nil ? nil : glide
        }
        return actions
    }

    /// The remote went away: held buttons are let go, a swipe or glide in progress ends.
    mutating func reset() -> [SiriRemoteAction] {
        return buttons.reset() + stopInertia() + touch.reset()
    }

    private mutating func stopInertia() -> [SiriRemoteAction] {
        guard var glide = inertia else { return [] }
        inertia = nil
        return glide.stop()
    }
}

// MARK: - Input

/// Reads the Siri Remote: buttons through IOHID (seized, so macOS doesn't act on them too) and
/// the touch surface through MultitouchSupport. Everything is event-driven: one one-shot timer
/// exists only while a button is held, and touch frames arrive only while a finger is down.
@MainActor
final class SiriRemoteInput {
    private let sink: (SiriRemoteAction) -> Void
    private var recognizer = SiriRemoteRecognizer()
    private var manager: IOHIDManager?
    private var timer: Timer?
    private let touch = SiriRemoteTouchSource()
    /// 调试用：`defaults write local.couch.tv SiriRemoteDebug -bool true` 以后，
    /// 每一下按键、每一帧触摸、认成了什么都写进 ~/Library/Logs/Mac TV/siri-remote.log
    private let debug = SiriRemoteDebugLog.openIfEnabled()
    /// The one live instance, for the C callbacks.
    fileprivate static weak var current: SiriRemoteInput?

    /// Called when the remote connects (or wakes and reconnects).
    var onConnect: (() -> Void)?

    init(sink: @escaping (SiriRemoteAction) -> Void) {
        self.sink = sink
    }

    func start() {
        guard manager == nil else { return }
        Self.current = self
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: 0x004C, kIOHIDProductIDKey: 0x0316,
            kIOHIDPrimaryUsagePageKey: 0x0C, kIOHIDPrimaryUsageKey: 0x01,
        ] as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { _, _, _, _ in
            MainActor.assumeIsolated { SiriRemoteInput.current?.remoteConnected() }
        }, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { _, _, _, _ in
            MainActor.assumeIsolated { SiriRemoteInput.current?.remoteDisconnected() }
        }, nil)
        IOHIDManagerRegisterInputValueCallback(manager, { _, _, _, value in
            let element = IOHIDValueGetElement(value)
            guard let button = SiriRemoteButton(usagePage: IOHIDElementGetUsagePage(element), usage: IOHIDElementGetUsage(element))
            else { return }
            let pressed = IOHIDValueGetIntegerValue(value) != 0
            MainActor.assumeIsolated { SiriRemoteInput.current?.button(button, pressed: pressed) }
        }, nil)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        // 独占：Mac TV 开着时系统不再处理这些键（不然音量 HUD 弹两次、播放暂停发给别的 App、电源键关两次屏幕）
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        if result != kIOReturnSuccess {
            Log.app.error("Siri Remote: couldn't take the buttons (\(String(format: "0x%x", result), privacy: .public)); needs Input Monitoring")
        }
        self.manager = manager
        touch.onFrame = { [weak self] point, time in self?.touchFrame(point, at: time) }
        // 启动时已经连着的遥控器：马上就知道（配对页要不要弹出来，看的就是这个）
        if let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !devices.isEmpty {
            SiriRemoteStatus.shared.connected = true
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        touch.stop()
        if let manager { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        manager = nil
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func remoteConnected() {
        Log.app.notice("Siri Remote connected")
        SiriRemoteStatus.shared.connected = true
        onConnect?()
        // 遥控器睡醒重连后，触控面是一个新设备，要重新挂上
        touch.start()
    }

    private func remoteDisconnected() {
        Log.app.notice("Siri Remote disconnected")
        SiriRemoteStatus.shared.connected = false
        emit(recognizer.reset())
        touch.stop()
    }

    private func button(_ button: SiriRemoteButton, pressed: Bool) {
        debug?.write("B \(button) \(pressed ? "down" : "up")", at: now)
        emit(pressed ? recognizer.press(button, at: now) : recognizer.release(button, at: now))
    }

    private func touchFrame(_ point: SiriRemoteTouch.Point?, at time: TimeInterval) {
        debug?.write(point.map { String(format: "T %.3f %.3f", $0.x, $0.y) } ?? "T lift", at: time)
        emit(recognizer.touchFrame(point, at: time))
    }

    private func emit(_ actions: [SiriRemoteAction]) {
        for action in actions { debug?.write("A \(action)", at: now) }
        actions.forEach(sink)
        schedule()
    }

    /// One one-shot timer for the next hold or repeat, only while a button is down.
    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard let deadline = recognizer.nextDeadline else { return }
        timer = Timer.scheduledTimer(withTimeInterval: max(0, deadline - now), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.emit(self.recognizer.advance(to: self.now))
            }
        }
        timer?.tolerance = 0.005
    }
}

// MARK: - MultitouchSupport

/// The Siri Remote's touch surface, through the private MultitouchSupport framework (loaded at
/// run time; if it's missing or changes, the remote's buttons still work).
@MainActor
private final class SiriRemoteTouchSource {
    /// MultitouchSupport's family ID for the Siri Remote's clickpad (6 × 12 sensor), seen on macOS 27.2.1.
    static let familyID: Int32 = 145

    var onFrame: ((SiriRemoteTouch.Point?, TimeInterval) -> Void)?
    private var devices: [MTDevice] = []
    fileprivate static weak var current: SiriRemoteTouchSource?

    func start() {
        stop()
        guard let api = MT.api else { return }
        Self.current = self
        let list = api.createList().takeRetainedValue() as [AnyObject]
        for device in list {
            let pointer = Unmanaged.passUnretained(device).toOpaque()
            var family: Int32 = 0
            _ = api.familyID(pointer, &family)
            guard family == Self.familyID else { continue }
            api.register(pointer, siriRemoteContactFrame)
            _ = api.start(pointer, 0)
            devices.append(MTDevice(object: device))
        }
        if devices.isEmpty { Log.app.notice("Siri Remote: touch surface not found") }
    }

    func stop() {
        guard let api = MT.api else { return }
        for device in devices {
            let pointer = Unmanaged.passUnretained(device.object).toOpaque()
            api.unregister(pointer, siriRemoteContactFrame)
            _ = api.stop(pointer)
        }
        devices = []
    }

    fileprivate func deliver(_ point: SiriRemoteTouch.Point?, at time: TimeInterval) { onFrame?(point, time) }

    private struct MTDevice { let object: AnyObject }
}

/// MultitouchSupport's per-finger record (96 bytes). Only the first fields are read.
private struct MTFinger {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var unknown1: Int32
    var unknown2: Int32
    var x: Float, y: Float, vx: Float, vy: Float
    var size: Float
    var unknown3: Int32
    var angle: Float, majorAxis: Float, minorAxis: Float
    var mm: (Float, Float, Float, Float)
    var unknown4: (Int32, Int32)
    var unknown5: Float
}

private typealias MTFrameCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32

/// Called on MultitouchSupport's thread, only while a finger is on the surface (and once when it lifts).
private let siriRemoteContactFrame: MTFrameCallback = { _, fingers, count, _, _ in
    var point: SiriRemoteTouch.Point?
    if count > 0, let fingers, MemoryLayout<MTFinger>.size == 96 {
        let finger = fingers.assumingMemoryBound(to: MTFinger.self).pointee
        point = SiriRemoteTouch.Point(x: Double(finger.x), y: Double(finger.y))
    }
    let time = ProcessInfo.processInfo.systemUptime
    let delivered = point
    DispatchQueue.main.async {
        MainActor.assumeIsolated { SiriRemoteTouchSource.current?.deliver(delivered, at: time) }
    }
    return 0
}

private enum MT {
    struct API {
        let createList: @convention(c) () -> Unmanaged<CFArray>
        let register: @convention(c) (UnsafeMutableRawPointer, MTFrameCallback) -> Void
        let unregister: @convention(c) (UnsafeMutableRawPointer, MTFrameCallback) -> Void
        let start: @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
        let stop: @convention(c) (UnsafeMutableRawPointer) -> Int32
        let familyID: @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>) -> Int32
    }

    static let api: API? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
        else { return nil }
        func symbol<T>(_ name: String, as: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let createList = symbol("MTDeviceCreateList", as: (@convention(c) () -> Unmanaged<CFArray>).self),
              let register = symbol("MTRegisterContactFrameCallback", as: (@convention(c) (UnsafeMutableRawPointer, MTFrameCallback) -> Void).self),
              let unregister = symbol("MTUnregisterContactFrameCallback", as: (@convention(c) (UnsafeMutableRawPointer, MTFrameCallback) -> Void).self),
              let start = symbol("MTDeviceStart", as: (@convention(c) (UnsafeMutableRawPointer, Int32) -> Int32).self),
              let stop = symbol("MTDeviceStop", as: (@convention(c) (UnsafeMutableRawPointer) -> Int32).self),
              let familyID = symbol("MTDeviceGetFamilyID", as: (@convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>) -> Int32).self)
        else {
            Log.app.notice("Siri Remote: MultitouchSupport unavailable; turning and swiping are off")
            return nil
        }
        return API(createList: createList, register: register, unregister: unregister, start: start, stop: stop, familyID: familyID)
    }()
}

// MARK: - Mac TV

extension SiriRemoteInput {
    /// The running reader; kept here so TVController needs only one line to start it.
    static var shared: SiriRemoteInput?
}

/// Whether a Siri Remote is connected, for the pairing sheet and Setup.
@MainActor
final class SiriRemoteStatus: ObservableObject {
    static let shared = SiriRemoteStatus()
    @Published var connected = false
}

extension TVController {
    /// Starts reading the Siri Remote, alongside the game controllers.
    func startSiriRemote() {
        let input = SiriRemoteInput { [weak self] action in self?.siriRemote(action) }
        input.onConnect = { [weak self] in self?.noteOtherRemote() }
        SiriRemoteInput.shared = input
        input.start()
    }

    /// A Siri Remote or game controller is connected: there's already a remote, so the pairing
    /// sheet needn't come up at launch.
    var otherRemoteConnected: Bool { SiriRemoteStatus.shared.connected || controller != nil }

    /// A Siri Remote or game controller connected or was used: the pairing sheet shown at launch
    /// goes away (as it does when the phone connects), and Setup's remote step shows it connected.
    /// A Siri Remote connecting is when Mac TV asks to read its buttons (Input Monitoring).
    func noteOtherRemote() {
        remoteCoordinator.noteOtherRemote()
        notePhoneDuringSetup()
        if SiriRemoteStatus.shared.connected { askForInputMonitoring() }
    }

    /// Everything goes the way the phone remote's does, so both remotes feel the same.
    func siriRemote(_ action: SiriRemoteAction) {
        noteOtherRemote()
        switch action {
        case .press(let key, let phase): handle(.press(key, phase), from: .siriRemote)
        case .playPause: handle(.playPause, from: .siriRemote)
        case .volume(let delta): handle(.volume(delta), from: .siriRemote)
        case .mute: handle(.mute, from: .siriRemote)
        case .wheel(let step): handle(.wheel(step), from: .siriRemote)
        case .tap: handle(.touchTap, from: .siriRemote)
        // 和手机点按区上的滑动一样交给 TrackpadGestures：焦点跟着手指走（像 Apple TV），弹出的面板里也是那里管（一次滑动走一格）
        case .swipe(let dx, let dy, let phase):
            handle(.swipe(dx: dx, dy: dy, phase: phase, focusFollowsFinger: true), from: .siriRemote)
        }
    }
}

// MARK: - Debug log

/// Off unless turned on with `defaults write local.couch.tv SiriRemoteDebug -bool true`.
/// One line per button, touch frame and action, with the time in seconds since startup.
@MainActor
private final class SiriRemoteDebugLog {
    private let handle: FileHandle

    static func openIfEnabled() -> SiriRemoteDebugLog? {
        guard UserDefaults.standard.bool(forKey: "SiriRemoteDebug") else { return nil }
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Mac TV")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("siri-remote.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        handle.seekToEndOfFile()
        Log.app.notice("Siri Remote debug log: \(url.path, privacy: .public)")
        return SiriRemoteDebugLog(handle: handle)
    }

    private init(handle: FileHandle) { self.handle = handle }

    func write(_ line: String, at time: TimeInterval) {
        handle.write(Data((String(format: "%.3f ", time) + line + "\n").utf8))
    }
}
