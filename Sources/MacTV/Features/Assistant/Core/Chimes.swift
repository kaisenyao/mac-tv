import AVFoundation

/// The assistant's own sounds: listening starts, listening ends, and "not now" (a password field, no key).
enum Chime: CaseIterable {
    case listen, done, unavailable

    /// PianaSoul's start and end sounds (its web/cue-active.mp3 and cue-end.mp3), in the package's Sounds folder.
    /// "Not now" has none there: it's made here.
    var file: String? {
        switch self {
        case .listen: "cue-active.mp3"
        case .done: "cue-end.mp3"
        case .unavailable: nil
        }
    }
}

@MainActor
protocol Chiming: AnyObject {
    func play(_ chime: Chime)
}

/// Plays the chimes: PianaSoul's two sounds when listening starts and ends, and one low note twice, made here, for
/// "not now". The sounds are read away from the main thread when Chimes is made; its engine runs only while a chime
/// plays, and a few seconds after.
@MainActor
final class Chimes: Chiming {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// PianaSoul's sounds are 48 kHz stereo; the note is made the same.
    nonisolated static let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private var buffers: [Chime: AVAudioPCMBuffer] = [:]
    private var loading: Task<Void, Never>?
    private var idle: Task<Void, Never>?
    /// False in a test run: nothing plays (or is read).
    private let allowed: Bool

    init(allowed: Bool) {
        self.allowed = allowed
        guard allowed else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: Self.format)
        loading = Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) { Loaded(Self.load()) }.value
            guard let self else { return }
            self.buffers.merge(loaded.buffers) { mine, _ in mine }
        }
    }

    /// The buffers, carried from the thread that read them (made there, never touched again until played here).
    private struct Loaded: @unchecked Sendable {
        let buffers: [Chime: AVAudioPCMBuffer]
        init(_ buffers: [Chime: AVAudioPCMBuffer]) { self.buffers = buffers }
    }

    func play(_ chime: Chime) {
        guard allowed else { return }
        // A chime asked for before the sounds were read (at once after launch): this one, read now.
        if buffers[chime] == nil, let buffer = Self.buffer(chime) { buffers[chime] = buffer }
        guard let buffer = buffers[chime] else { return }
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

    nonisolated static func load() -> [Chime: AVAudioPCMBuffer] {
        Dictionary(uniqueKeysWithValues: Chime.allCases.compactMap { chime in buffer(chime).map { (chime, $0) } })
    }

    nonisolated static func buffer(_ chime: Chime) -> AVAudioPCMBuffer? {
        if let file = chime.file, let sound = url(file).flatMap(read) { return sound }
        return synthesize(chime, format: format)
    }

    /// A sound in the package's resource bundle (MacTV_MacTV.bundle): in the app's Resources folder (build.sh copies
    /// it there), or next to the binary in a Swift build or test run.
    nonisolated static func url(_ file: String) -> URL? {
        let places = [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent(),
                      Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent()]
        for place in places.compactMap({ $0 }) {
            if let bundle = Bundle(url: place.appendingPathComponent("MacTV_MacTV.bundle")),
               let url = bundle.url(forResource: file, withExtension: nil, subdirectory: "Sounds") {
                return url
            }
        }
        return nil
    }
    private final class BundleMarker {}

    /// A sound file, decoded whole, in the engine's format.
    nonisolated static func read(_ url: URL) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0,
              let decoded = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: decoded)) != nil else { return nil }
        if decoded.format == format { return decoded }
        guard let converter = AVAudioConverter(from: decoded.format, to: format) else { return nil }
        let ratio = format.sampleRate / decoded.format.sampleRate
        guard let converted = AVAudioPCMBuffer(pcmFormat: format,
                                               frameCapacity: AVAudioFrameCount(Double(decoded.frameLength) * ratio) + 1024)
        else { return nil }
        // The converter asks for its input on this thread, during convert(to:): the one buffer, then the end.
        nonisolated(unsafe) var input: AVAudioPCMBuffer? = decoded
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            guard let given = input else { status.pointee = .endOfStream; return nil }
            input = nil
            status.pointee = .haveData
            return given
        }
        return error == nil && converted.frameLength > 0 ? converted : nil
    }

    /// Soft notes with a quick attack and a gentle decay, nothing bright. "Not now" is always one of these; the start
    /// and end notes only stand in for PianaSoul's sounds when their files can't be read.
    nonisolated static func synthesize(_ chime: Chime, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let notes: [(frequency: Double, start: Double)] = switch chime {
        case .listen: [(659.26, 0), (987.77, 0.085)]       // E5 then B5
        case .done: [(987.77, 0), (659.26, 0.085)]         // B5 then E5
        case .unavailable: [(220, 0), (220, 0.14)]         // A3 twice
        }
        let rate = format.sampleRate, duration = 0.42
        let frames = AVAudioFrameCount(duration * rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channels = buffer.floatChannelData else { return nil }
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
            for channel in 0..<Int(format.channelCount) { channels[channel][frame] = Float(value) * level }
        }
        return buffer
    }
}
