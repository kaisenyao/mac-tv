import AppKit

/// What a press and a hold of each button mean, the same on every input: the phone (which times its own
/// presses), and the Siri Remote, a game controller and the keyboard (timed by PressTiming, through InputPresses).
/// Each reports tap, hold (InputTiming.hold, directions InputTiming.directionHold), alive (still held) and release.
///
/// | Button | Tap | Hold (acts when the hold time passes; letting go does nothing more) |
/// |---|---|---|
/// | Directions | One step | Steps at the Mac's key repeat rate; in 网易云's and 得到's players Left and Right seek, and letting go plays from there |
/// | Select | Select | The menu where there is one (held again, it closes); elsewhere, one Select on release |
/// | Back | Back (at an app's top level, the Home Screen, with the app kept) | The Home Screen, from anywhere |
/// | TV | The Home Screen; twice, the App Switcher | Control Center (held again, it closes) |
/// | Power | Wakes from TV standby; awake, nothing | TV standby |
///
/// While a button is held, "alive" comes every 0.3 s; with none for 1.2 s (a release lost on the network), it's let go.
@MainActor
final class PhonePresses {
    enum Key: String, CaseIterable {
        case up, down, left, right, select, back, home, power
        var isDirection: Bool { [.up, .down, .left, .right].contains(self) }
    }
    enum Phase: String { case tap, hold, alive, release }

    private weak var tv: TVController?
    /// 正按住的键：按住时在做什么
    private enum Holding { case repeating(Timer), scrubbing, menu, selectOnRelease(Feedback.Source), done }
    private var holding: [Key: Holding] = [:]
    private var watchdogs: [Key: Timer] = [:]

    init(tv: TVController) { self.tv = tv }

    func handle(_ key: Key, _ phase: Phase, from source: Feedback.Source) {
        guard let tv else { return }
        switch phase {
        case .tap:
            release(key)
            switch key {
            case .select: tv.handle(.select, from: source)
            case .back: tv.handle(.back, from: source)
            case .home: tv.handle(.home, from: source)
            case .power: tv.handle(.power(hold: false), from: source)
            default: if let direction = Self.direction(key) { tv.handle(.move(direction), from: source) }
            }
        case .hold:
            release(key)
            begin(key, tv: tv, source: source)
            feed(key)
        case .alive:
            if holding[key] != nil { feed(key) }
        case .release:
            release(key)
        }
    }

    private func begin(_ key: Key, tv: TVController, source: Feedback.Source) {
        switch key {
        case .back:
            tv.handle(.goHome, from: source)                    // the Home Screen from anywhere, with the app kept
            holding[key] = .done
        case .home:
            tv.handle(.controlCenter, from: source)             // Control Center; held again, it closes
            holding[key] = .done
        case .power:
            tv.handle(.power(hold: true), from: source)         // TV standby (in standby, it wakes)
            holding[key] = .done
        case .select:
            if tv.holdSelect(from: source) {                    // 菜单开着时再按住是收起（TVController.toggle）
                holding[key] = .menu
            } else {
                holding[key] = .selectOnRelease(source)                 // 没有菜单的地方：松手时是一次普通的确认（和回车一样）
            }
        case .left, .right, .up, .down:
            guard let direction = Self.direction(key) else { return }
            if key == .left || key == .right, tv.mode == .launcher, tv.neteaseOpen, tv.activeSheet == nil,
               tv.neteaseStore.canHoldSeek {
                tv.neteaseStore.beginHold(forward: key == .right)   // 网易云播放界面：按住左右 = 快退 / 快进
                holding[key] = .scrubbing
                return
            }
            if key == .left || key == .right, tv.mode == .launcher, tv.dedaoOpen, tv.activeSheet == nil,
               tv.dedaoStore.canHoldSeek {
                tv.dedaoStore.beginHold(forward: key == .right)     // 得到的播放界面：和网易云一样
                holding[key] = .scrubbing
                return
            }
            // 别的地方：和按住键盘方向键一样，按 Mac 设置里的按键重复速度一直走
            tv.handle(.move(direction), from: source)
            let timer = Timer(timeInterval: InputTiming.directionRepeat, repeats: true) { [weak self, weak tv] _ in
                MainActor.assumeIsolated {
                    guard let self, let tv, case .repeating? = self.holding[key] else { return }
                    tv.handle(.move(direction), from: source)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            holding[key] = .repeating(timer)
        }
    }

    private func release(_ key: Key) {
        watchdogs.removeValue(forKey: key)?.invalidate()
        guard let state = holding.removeValue(forKey: key), let tv else { return }
        switch state {
        case .repeating(let timer): timer.invalidate()
        case .scrubbing: tv.endHoldSeek()
        case .selectOnRelease(let source): tv.handle(.select, from: source)
        case .menu, .done: break
        }
    }

    /// 还按着：重新计时。1.2 秒没收到就当松开了
    private func feed(_ key: Key) {
        watchdogs[key]?.invalidate()
        let timer = Timer(timeInterval: 1.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.release(key) }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdogs[key] = timer
    }

    private static func direction(_ key: Key) -> RemoteCommand.Direction? {
        switch key {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        default: nil
        }
    }
}

/// The keyboard's and a game controller's buttons, pressed and let go: timed by PressTiming (the same rule as the
/// Siri Remote's), then meant by PhonePresses (the same meaning as the phone's). One timer, only while something
/// is held. `reset` lets go of a device's buttons at once: a controller disconnecting, Mac TV losing focus.
@MainActor
final class InputPresses {
    private weak var tv: TVController?
    private var timing: [Feedback.Source: PressTiming] = [:]
    /// The Siri button on inputs that only say down and up: the keyboard's F5 (🎤), a controller's Y (see Jasmine).
    private var siri: [Feedback.Source: SiriPress] = [:]
    private var timer: Timer?
    /// Keys whose release may never arrive as an event (H while ⌘ is held: AppKit doesn't deliver that keyUp).
    /// While one is down its physical state is checked every `watchInterval`, and it's let go as soon as it's up.
    static let watchInterval: TimeInterval = 0.02
    private var watched: [(key: PhonePresses.Key, source: Feedback.Source, isDown: () -> Bool)] = []
    /// The same for the Siri button (fn-F5: AppKit may not deliver F5's keyUp while fn is held).
    private var watchedSiri: [(source: Feedback.Source, isDown: () -> Bool)] = []
    private var watchTimer: Timer?
    /// The clock; tests pass their own times instead.
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    init(tv: TVController) { self.tv = tv }

    /// A button went down. False for one that was already down (a key repeat), which does nothing.
    @discardableResult
    func down(_ key: PhonePresses.Key, from source: Feedback.Source, at time: TimeInterval? = nil) -> Bool {
        guard timing[source, default: PressTiming()].press(key, at: time ?? now()) else { return false }
        schedule()
        return true
    }

    /// A button came up. False when it wasn't down here (so the key isn't this one's).
    @discardableResult
    func up(_ key: PhonePresses.Key, from source: Feedback.Source) -> Bool {
        unwatch { $0.key == key && $0.source == source }
        guard let phase = timing[source]?.release(key) else { return false }
        tv?.handle(.press(key, phase), from: source)
        schedule()
        return true
    }

    /// The Siri button went down: Jasmine hears from now, whether it turns out a press or a hold.
    func siriDown(from source: Feedback.Source, at time: TimeInterval? = nil) {
        let phases = siri[source, default: SiriPress(holdAfter: InputTiming.hold)].press(at: time ?? now())
        for phase in phases { tv?.handle(.siri(phase), from: source) }
        schedule()
    }

    /// The Siri button is down on this input (its release hasn't come).
    func siriIsDown(from source: Feedback.Source) -> Bool { siri[source]?.isDown ?? false }

    /// The Siri button came up. False when it wasn't down here.
    @discardableResult
    func siriUp(from source: Feedback.Source, at time: TimeInterval? = nil) -> Bool {
        unwatchSiri(source)
        guard let phases = siri[source]?.release(at: time ?? now()), !phases.isEmpty else { return false }
        for phase in phases { tv?.handle(.siri(phase), from: source) }
        schedule()
        return true
    }

    /// Holds and "still held" that are due by `time`.
    func advance(to time: TimeInterval) {
        for source in Array(timing.keys) {
            guard let due = timing[source]?.advance(to: time) else { continue }
            for (key, phase) in due { tv?.handle(.press(key, phase), from: source) }
        }
        for source in Array(siri.keys) {
            for phase in siri[source]?.advance(to: time) ?? [] { tv?.handle(.siri(phase), from: source) }
        }
        schedule()
    }

    /// Lets go of a device's buttons (all devices' with nil): a hold ends, a press not yet a tap does nothing.
    func reset(_ source: Feedback.Source? = nil) {
        unwatch { source == nil || $0.source == source }
        for each in Array(timing.keys) where source == nil || each == source {
            let released = timing[each]?.reset() ?? []
            timing[each] = nil
            for (key, phase) in released { tv?.handle(.press(key, phase), from: each) }
        }
        watchedSiri.removeAll { source == nil || $0.source == source }
        stopWatchingIfIdle()
        for each in Array(siri.keys) where source == nil || each == source {
            let cancelled = siri[each]?.reset() ?? []
            siri[each] = nil
            for phase in cancelled { tv?.handle(.siri(phase), from: each) }
        }
        schedule()
    }

    /// Lets `key` go when `isDown` says it's up (checked every `watchInterval` while it's down).
    func watch(_ key: PhonePresses.Key, from source: Feedback.Source, isDown: @escaping () -> Bool) {
        unwatch { $0.key == key && $0.source == source }
        watched.append((key, source, isDown))
        startWatching()
    }

    /// Lets the Siri button go when `isDown` says it's up (checked every `watchInterval` while it's down).
    func watchSiri(from source: Feedback.Source, isDown: @escaping () -> Bool) {
        unwatchSiri(source)
        watchedSiri.append((source, isDown))
        startWatching()
    }

    private func unwatchSiri(_ source: Feedback.Source) {
        watchedSiri.removeAll { $0.source == source }
        stopWatchingIfIdle()
    }

    private func startWatching() {
        guard watchTimer == nil else { return }
        let timer = Timer(timeInterval: Self.watchInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkWatched() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchTimer = timer
    }

    /// The watched keys, checked now: one that's up is let go (a tap, or the end of a hold).
    func checkWatched() {
        for entry in watched where !entry.isDown() { up(entry.key, from: entry.source) }
        for entry in watchedSiri where !entry.isDown() { siriUp(from: entry.source) }
    }

    private func unwatch(_ matching: (_ entry: (key: PhonePresses.Key, source: Feedback.Source, isDown: () -> Bool)) -> Bool) {
        watched.removeAll(where: matching)
        stopWatchingIfIdle()
    }

    private func stopWatchingIfIdle() {
        guard watched.isEmpty, watchedSiri.isEmpty else { return }
        watchTimer?.invalidate()
        watchTimer = nil
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard let next = (timing.values.map(\.nextDeadline) + siri.values.map(\.nextDeadline)).compactMap({ $0 }).min() else { return }
        let timer = Timer(timeInterval: max(0, next - now()), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.advance(to: self.now()) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
