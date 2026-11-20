@preconcurrency import AVFoundation
import CryptoKit

/// The assistant's voice: what to say, in order, said as soon as its first sound arrives. `stop` cuts it off at
/// once (nothing more is said); `onFinished` comes when everything given has been said.
@MainActor
protocol Speaking: AnyObject {
    /// Loudness of what's being said now (0–1), for the orb.
    var onLevel: ((Float) -> Void)? { get set }
    /// Everything given so far has been said (or failed to be).
    var onFinished: (() -> Void)? { get set }
    var speaking: Bool { get }
    func say(_ text: String)
    func stop()
}

/// Sentences, as they're best sent to a voice: each one as soon as it's complete, so the first is heard while the
/// rest is still being made.
enum Sentences {
    static func split(_ text: String) -> [String] {
        let characters = Array(text)
        var sentences: [String] = []
        var current = ""
        for (index, character) in characters.enumerated() {
            current.append(character)
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            // An English full stop ends a sentence only before a space and a capital (not "3 p.m. now").
            let stop = "。！？!?；;\n".contains(character)
                || (character == "." && next == " " && index + 2 < characters.count && characters[index + 2].isUppercase)
            if stop {
                let sentence = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { sentences.append(sentence) }
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { sentences.append(rest) }
        return sentences
    }

    /// Has Chinese in it (for the system voice's language: a Chinese voice reads the English words too).
    static func isChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.isIdeographic }
    }
}

/// ElevenLabs, as PianaSoul speaks: `/v1/text-to-speech/{voice}/stream`, raw 24 kHz PCM, `eleven_v4_turbo`, stability
/// 0.5, similarity 0.75, speaker boost; played in tenths of a second as they arrive. One request a sentence, the next
/// asked for while this one plays. Short lines ("好的。") are kept on disk once made, so they're said at once next
/// time. Without a key, or once ElevenLabs refuses the key, the Mac's own voice speaks instead.
@MainActor
final class Voice: Speaking {
    struct Settings: Equatable {
        var voice: String
        var model = "eleven_v4_turbo"
        var stability = 0.5
        var similarity = 0.75
        var speed = 1.0
    }

    var onLevel: ((Float) -> Void)?
    var onFinished: (() -> Void)?

    private let key: () -> String?
    private let settings: () -> Settings
    private let session: URLSession
    private let allowed: Bool
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private let system = AVSpeechSynthesizer()
    private var systemDelegate: SystemVoiceDelegate?
    /// Sentences waiting to be asked for, in order.
    private var queue: [String] = []
    private var fetching: Task<Void, Never>?
    /// Buffers scheduled and not yet played.
    private var pending = 0
    private var generation = 0
    /// ElevenLabs refused the key (401, 402, 403): the Mac's voice until the key changes.
    private var refusedKey: String?
    private var idle: Task<Void, Never>?
    private let cache: URL?

    /// A line this short is kept once made.
    static let cachedLength = 16
    /// How long to wait for a sentence's first sound before the Mac's voice says it instead (PianaSoul's 10 s).
    static let timeout: TimeInterval = 10

    init(key: @escaping () -> String?, settings: @escaping () -> Settings, allowed: Bool, cache: URL?,
         session: URLSession = .shared) {
        self.key = key
        self.settings = settings
        self.allowed = allowed
        self.cache = cache
        self.session = session
        guard allowed else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    var speaking: Bool { pending > 0 || !queue.isEmpty || fetching != nil || system.isSpeaking }

    func say(_ text: String) {
        let sentences = Sentences.split(text)
        guard !sentences.isEmpty else { return }
        idle?.cancel()
        queue += sentences
        if fetching == nil { fetchNext() }
    }

    func stop() {
        generation += 1
        queue = []
        fetching?.cancel()
        fetching = nil
        pending = 0
        if allowed {
            player.stop()
            system.stopSpeaking(at: .immediate)
        }
        onLevel?(0)
        sleepSoon()
    }

    // MARK: Asking for each sentence

    private func fetchNext() {
        guard !queue.isEmpty else {
            fetching = nil
            finishIfDone()
            return
        }
        let sentence = queue.removeFirst()
        let generation = generation
        fetching = Task { [weak self] in
            await self?.speak(sentence)
            guard let self, self.generation == generation else { return }
            self.fetching = nil
            self.fetchNext()
        }
    }

    private func speak(_ sentence: String) async {
        let settings = settings()
        guard allowed else { return }
        guard let key = key(), key != refusedKey else { return await sayWithMac(sentence) }
        let clipKey = Self.clipKey(sentence, settings)
        if sentence.count <= Self.cachedLength, let clip = cached(clipKey) {
            play(clip)
            return
        }
        var url = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech/\(settings.voice)/stream")!
        url.queryItems = [URLQueryItem(name: "output_format", value: "pcm_24000")]
        var request = URLRequest(url: url.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "text": sentence, "model_id": settings.model,
            "voice_settings": ["stability": settings.stability, "similarity_boost": settings.similarity, "style": 0,
                               "use_speaker_boost": true, "speed": settings.speed],
        ] as [String: Any])
        do {
            let (bytes, response) = try await session.bytes(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                if [401, 402, 403].contains(http.statusCode) { refusedKey = key }
                Log.app.error("Jasmine's voice: ElevenLabs answered \(http.statusCode, privacy: .public)")
                return await sayWithMac(sentence)
            }
            var piece = Data(), whole = Data()
            for try await byte in bytes {
                if Task.isCancelled { return }
                piece.append(byte)
                if piece.count >= 4_800 {   // 0.1 s
                    play(piece)
                    whole.append(piece)
                    piece = Data()
                }
            }
            if !piece.isEmpty { play(piece); whole.append(piece) }
            if sentence.count <= Self.cachedLength, !whole.isEmpty { keep(whole, clipKey) }
        } catch {
            if Task.isCancelled { return }
            Log.app.error("Jasmine's voice: \(String(describing: error), privacy: .public)")
            await sayWithMac(sentence)
        }
    }

    // MARK: Playing

    /// 16-bit PCM at 24 kHz, scheduled after what's already playing.
    private func play(_ pcm: Data) {
        let samples = pcm.count / 2
        guard samples > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples)),
              let out = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples)
        var sum: Float = 0
        pcm.withUnsafeBytes { raw in
            let input = raw.bindMemory(to: Int16.self)
            for i in 0..<samples {
                let value = Float(Int16(littleEndian: input[i])) / 32_768
                out[i] = value
                sum += value * value
            }
        }
        let level = min(1, (sum / Float(samples)).squareRoot() * 8)
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
        pending += 1
        let generation = generation
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.pending -= 1
                if self.pending == 0 { self.onLevel?(0) }
                self.finishIfDone()
            }
        }
        if !player.isPlaying { player.play() }
        // Roughly in time with the sound: the level of the piece as it's scheduled to start.
        let delay = Double(pending - 1) * 0.1
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.generation == generation else { return }
            self.onLevel?(level)
        }
    }

    /// The Mac's own voice, for when ElevenLabs can't: Tingting for Chinese.
    private func sayWithMac(_ sentence: String) async {
        let utterance = AVSpeechUtterance(string: sentence)
        utterance.voice = AVSpeechSynthesisVoice(language: Sentences.isChinese(sentence) ? "zh-CN" : "en-US")
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let delegate = SystemVoiceDelegate { done.resume() }
            systemDelegate = delegate
            system.delegate = delegate
            onLevel?(0.5)
            system.speak(utterance)
        }
        onLevel?(0)
    }

    private func finishIfDone() {
        guard pending == 0, queue.isEmpty, fetching == nil, !system.isSpeaking else { return }
        onFinished?()
        sleepSoon()
    }

    /// The engine rests once nothing has been said for a few seconds.
    private func sleepSoon() {
        idle?.cancel()
        guard allowed else { return }
        idle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, !self.speaking else { return }
            self.player.stop()
            self.engine.pause()
        }
    }

    // MARK: Lines kept

    static func clipKey(_ text: String, _ settings: Settings) -> String {
        let made = "\(settings.voice)|\(settings.model)|\(settings.stability)|\(settings.similarity)|\(settings.speed)|\(text)"
        return SHA256.hash(data: Data(made.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func cached(_ key: String) -> Data? {
        cache.flatMap { try? Data(contentsOf: $0.appendingPathComponent(key + ".pcm")) }
    }

    private func keep(_ pcm: Data, _ key: String) {
        guard let cache else { return }
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try? pcm.write(to: cache.appendingPathComponent(key + ".pcm"), options: .atomic)
    }
}

/// Tells when the Mac's voice has finished (or was stopped).
private final class SystemVoiceDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let done: () -> Void
    private var called = false
    init(done: @escaping () -> Void) { self.done = done }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { finish() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { finish() }

    private func finish() {
        guard !called else { return }
        called = true
        done()
    }
}
