import AVFoundation

/// The assistant's own sounds: listening starts, listening ends, and "not now" (a password field, no key).
enum Chime: CaseIterable {
    case listen, done, unavailable
}

@MainActor
protocol Chiming: AnyObject {
    func play(_ chime: Chime)
}

/// Plays the chimes, made here rather than loaded from files: two soft sine notes going up to listen, down when
/// it's done, and one low note twice for "not now". Its engine runs only while a chime plays, and a few
/// seconds after.
@MainActor
final class Chimes: Chiming {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    private lazy var buffers: [Chime: AVAudioPCMBuffer] = Dictionary(uniqueKeysWithValues: Chime.allCases.compactMap { chime in
        Self.synthesize(chime, format: format).map { (chime, $0) }
    })
    private var idle: Task<Void, Never>?
    /// False in a test run: nothing plays.
    private let allowed: Bool

    init(allowed: Bool) {
        self.allowed = allowed
        guard allowed else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func play(_ chime: Chime) {
        guard allowed, let buffer = buffers[chime] else { return }
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
        player.play()
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        idle?.cancel()
        idle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            self.player.stop()
            self.engine.pause()
        }
    }

    /// Soft notes with a quick attack and a gentle decay, nothing bright.
    static func synthesize(_ chime: Chime, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let notes: [(frequency: Double, start: Double)] = switch chime {
        case .listen: [(659.26, 0), (987.77, 0.085)]       // E5 then B5
        case .done: [(987.77, 0), (659.26, 0.085)]         // B5 then E5
        case .unavailable: [(220, 0), (220, 0.14)]         // A3 twice
        }
        let rate = format.sampleRate, duration = 0.42
        let frames = AVAudioFrameCount(duration * rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        let level: Float = chime == .unavailable ? 0.16 : 0.12
        for frame in 0..<Int(frames) {
            let t = Double(frame) / rate
            var value = 0.0
            for note in notes where t >= note.start {
                let local = t - note.start
                let envelope = min(1, local / 0.006) * exp(-local / 0.11)
                value += sin(2 * .pi * note.frequency * local) * envelope
            }
            samples[frame] = Float(value) * level
        }
        return buffer
    }
}
