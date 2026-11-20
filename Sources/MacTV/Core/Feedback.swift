import AVFoundation
import AppKit
import Combine
import CoreHaptics
import GameController

/// Apple TV's interface feedback: a soft tick as focus moves, a click on select and a lower note
/// going back, with a matching tap on the trackpad or a game controller. The sounds are made here
/// rather than loaded from files, and only play on Mac TV's own screens, never over a show.
@MainActor
final class Feedback: ObservableObject {
    /// move：长条里走一格（轻快的"嗒"）；step：挑选、抽屉、换排走一格（厚一点的"咔"，像拨档位）；
    /// select、back：确认、返回。分类见 TVController.Module
    enum Cue: CaseIterable {
        case move, step, select, back
    }

    /// Where a command came from, so the haptic goes to the thing in the user's hand.
    /// The phone remote vibrates by itself.
    enum Source {
        case keyboard, trackpad, pointer, remote, controller, siriRemote
    }

    static let shared = Feedback()

    /// Sounds and haptics, on unless turned off in Settings.
    var enabled: Bool {
        get { preferences.navigationSounds }
        set { preferences.navigationSounds = newValue }
    }

    /// Volume for navigation sounds (0.0 to 1.0, defaults to 0.70).
    var volume: Float {
        get { preferences.navigationSoundVolume }
        set {
            let clamped = max(0, min(1, newValue))
            preferences.navigationSoundVolume = clamped
            engine.mainMixerNode.outputVolume = clamped
        }
    }

    var isMuted: Bool {
        !enabled
    }

    func toggleMute() {
        enabled.toggle()
        if enabled { play(.select, from: .keyboard) }
    }

    func stepVolume(by delta: Float) {
        let current = Int((volume * 100).rounded())
        let step = Int((delta * 100).rounded())
        let newPercent = max(0, min(100, current + step))
        volume = Float(newPercent) / 100.0
        if !enabled && delta > 0 { enabled = true }
        play(.move, from: .keyboard)
    }

    func setVolumePercent(_ percent: Int) {
        let clamped = max(0, min(100, percent))
        let current = Int((volume * 100).rounded())
        guard clamped != current || !enabled else { return }
        volume = Float(clamped) / 100.0
        if !enabled && clamped > 0 { enabled = true }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastAuditionTime >= 0.08 {
            lastAuditionTime = now
            play(.move, from: .keyboard)
        }
    }

    private var lastAuditionTime: TimeInterval = 0

    /// The engine and its voices for the output in use; replaced whole when the output changes (see outputChanged).
    private(set) var engine = AVAudioEngine()
    private(set) var players: [AVAudioPlayerNode] = []
    private var nextPlayer = 0
    /// When the engine was last started (system uptime); nil while it's stopped or paused.
    private var startedAt: TimeInterval?
    private var configurationObserver: NSObjectProtocol?
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var buffers: [Cue: AVAudioPCMBuffer] = [:]
    private var idleTask: Task<Void, Never>?
    private var controllerEngine: CHHapticEngine?
    private weak var hapticController: GCController?

    private let preferences: Preferences

    init(preferences: Preferences = .shared) {
        self.preferences = preferences
        for cue in Cue.allCases { buffers[cue] = Self.synthesize(cue, format: format) }
        build(engine)
    }

    /// Wires a not-yet-started engine: a few voices (so quick repeats overlap instead of cutting each other off)
    /// at the navigation-sound volume. The next sound starts it.
    private func build(_ engine: AVAudioEngine) {
        engine.mainMixerNode.outputVolume = volume
        players = (0..<3).map { _ in
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            // On an output only Mac TV's own volume can set (see PlaybackVolume), that volume applies here too.
            PlaybackVolume.shared.attach(player)
            return player
        }
        nextPlayer = 0
        startedAt = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        // The output's sample rate or channels changed under the engine (it stops itself): start over on the new one.
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                       object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.outputChanged() }
        }
    }

    /// The sound output changed (Audio Output, or macOS). The old engine was made for the old device: switching
    /// 44.1 kHz speakers to a 48 kHz display stops it, and a restarted one can sit silent while it holds the taps
    /// pressed meanwhile, then play them all at once. So it's dropped with anything still queued, and a fresh
    /// engine starts on the new output at the next sound.
    func outputChanged() {
        idleTask?.cancel()
        players.forEach { $0.stop() }
        engine.stop()
        engine = AVAudioEngine()
        build(engine)
    }

    /// Where the output is: stopped (start it), just started, playing what it's given, or started a while ago
    /// and still silent (stuck after an output change).
    enum OutputState: Equatable { case idle, starting, rendering, stalled }
    static let stallAfter: TimeInterval = 0.3

    /// `runningFor`: seconds since the engine started; `renderAge`: seconds since the output last drew samples.
    static func outputState(running: Bool, runningFor: TimeInterval?, renderAge: TimeInterval?) -> OutputState {
        guard running else { return .idle }
        if let renderAge, renderAge < stallAfter { return .rendering }
        return (runningFor ?? .infinity) < stallAfter ? .starting : .stalled
    }

    private var renderAge: TimeInterval? {
        guard let time = engine.outputNode.lastRenderTime, time.isHostTimeValid else { return nil }
        let now = mach_absolute_time()
        return now > time.hostTime ? AVAudioTime.seconds(forHostTime: now - time.hostTime) : 0
    }

    /// 下一格最早什么时候响（系统开机以来的秒数）
    private var nextMoveAt: TimeInterval = 0
    /// 走一格的两声之间至少隔多久；排在后面等着响的最多能晚多少（再晚就不响了）
    static let moveSpacing: TimeInterval = 0.045
    static let moveBacklog: TimeInterval = 0.06

    func play(_ cue: Cue, from source: Source) {
        guard enabled else { return }
        // 走一格：两声之间至少隔 45 毫秒，像拨滚轮，不糊成一片。一下来了好几格（按住方向键、双指一甩，
        // 或者 App 正忙、几次按键挤在一起才处理）时不是只响第一声，而是一格一声往后排开；
        // 排得太远（按得比 45 毫秒还密）的那一格才不响，免得手停了声音还在响
        var delay: TimeInterval = 0
        if cue == .move || cue == .step {
            let now = ProcessInfo.processInfo.systemUptime
            let at = max(now, nextMoveAt)
            if at - now > Self.moveBacklog { return }
            nextMoveAt = at + Self.moveSpacing
            delay = at - now
        }
        // 声音一律从 Mac 出，不管是键盘、触控板、鼠标、手柄还是手机遥控器，响的都是同一套
        // （手机遥控器自己只震、不出声，和 Apple TV 的遥控器一样）
        sound(cue, after: delay)
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.haptic(cue, from: source) }
        } else {
            haptic(cue, from: source)
        }
    }

    // MARK: Sound

    private func sound(_ cue: Cue, after delay: TimeInterval = 0) {
        guard let buffer = buffers[cue] else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var state = Self.outputState(running: engine.isRunning, runningFor: startedAt.map { now - $0 }, renderAge: renderAge)
        if state == .stalled {
            outputChanged()
            state = .idle
        }
        if state == .idle {
            do { try engine.start() } catch { return }
            startedAt = now
        }
        // Until the output is drawing samples, only the latest tap waits for it: never a pile played at once.
        if state != .rendering { players.forEach { $0.stop() } }
        let player = players[nextPlayer]
        nextPlayer = (nextPlayer + 1) % players.count
        player.play()
        let when = delay > 0 ? AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: delay)) : nil
        player.scheduleBuffer(buffer, at: when, options: .interrupts)
        // An open audio stream keeps the Mac from idling to sleep; close it once things go quiet.
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            engine.pause()
            startedAt = nil
        }
    }

    /// Muted, physical clicks rather than tones: a brief filtered noise transient (the "tick") over a
    /// low, quickly damped body (the "thock"). Move is the tick alone; select and back add a body,
    /// back a little lower and softer. No pitch sweeps, nothing bright.
    static func synthesize(_ cue: Cue, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        // tick: noise decay and low-pass cutoff; body: frequency, decay and gain.
        let (duration, level): (Double, Float)
        let (tickDecay, cutoff): (Double, Double)
        let (bodyFrequency, bodyDecay, bodyGain): (Double, Double, Double)
        switch cue {
        case .move:
            (duration, level) = (0.025, 0.07)
            (tickDecay, cutoff) = (0.0012, 2_600)
            (bodyFrequency, bodyDecay, bodyGain) = (900, 0.002, 0.25)
        case .step:
            // 同一个"嗒"，底下多一点短促的低音：像拨了一下档位，比长条里连着走的那种厚一点
            (duration, level) = (0.045, 0.085)
            (tickDecay, cutoff) = (0.0014, 2_300)
            (bodyFrequency, bodyDecay, bodyGain) = (420, 0.007, 0.55)
        case .select:
            (duration, level) = (0.08, 0.11)
            (tickDecay, cutoff) = (0.0015, 2_200)
            (bodyFrequency, bodyDecay, bodyGain) = (190, 0.016, 0.9)
        case .back:
            (duration, level) = (0.08, 0.09)
            (tickDecay, cutoff) = (0.0015, 1_600)
            (bodyFrequency, bodyDecay, bodyGain) = (150, 0.018, 0.8)
        }
        let frames = AVAudioFrameCount(duration * rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        // The same noise every time, so each cue always sounds the same.
        var seed: UInt32 = 0x9E37_79B9
        let smoothing = 1 - exp(-2 * .pi * cutoff / rate)
        var filtered = 0.0
        var peak: Float = 0
        for frame in 0..<Int(frames) {
            let t = Double(frame) / rate
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Double(seed >> 8) / Double(1 << 24) * 2 - 1
            filtered += smoothing * (noise - filtered)
            let attack = min(1, t / 0.0004)
            let tick = filtered * exp(-t / tickDecay)
            let body = bodyGain * sin(2 * .pi * bodyFrequency * t) * exp(-t / bodyDecay)
            let value = Float(attack * (tick * 1.6 + body))
            samples[frame] = value
            peak = max(peak, abs(value))
        }
        // Same loudness whatever the mix: scale so each cue peaks at its level.
        if peak > 0 { for frame in 0..<Int(frames) { samples[frame] *= level / peak } }
        return buffer
    }

    // MARK: Haptics

    /// 每个声音都带一点触控板震动（手指搭在 Force Touch 触控板上才感觉得到，用键盘时不会打扰）：
    /// 长条走一格轻轻一下，挑选 / 抽屉明显一点，确认、返回一下。鼠标点下去的那一下触控板自己会咔哒，不再叠一下
    private func haptic(_ cue: Cue, from source: Source) {
        switch source {
        case .keyboard, .trackpad, .pointer:
            if source == .pointer, cue == .select || cue == .back { return }
            let pattern: NSHapticFeedbackManager.FeedbackPattern = switch cue {
            case .move: .alignment
            case .step: .levelChange
            case .select, .back: .generic
            }
            NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        case .controller:
            controllerTap(cue)
        case .remote, .siriRemote:
            break   // 手机遥控器自己会震；Siri Remote 没有震动
        }
    }

    private func controllerTap(_ cue: Cue) {
        guard let controller = GCController.current ?? GCController.controllers().first else { return }
        if controller !== hapticController {
            controllerEngine?.stop()
            controllerEngine = controller.haptics?.createEngine(withLocality: .default)
            controllerEngine?.isAutoShutdownEnabled = true
            hapticController = controller
        }
        guard let engine = controllerEngine else { return }
        let (intensity, sharpness): (Float, Float) = switch cue {
        case .move: (0.35, 0.7)
        case .step: (0.5, 0.6)
        case .select: (0.75, 0.5)
        case .back: (0.55, 0.25)
        }
        let event = CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
        ], relativeTime: 0)
        do {
            try engine.start()
            try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: [])).start(atTime: CHHapticTimeImmediate)
        } catch {}
    }
}
