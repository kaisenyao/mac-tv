import Foundation

/// Speech to text while it's said. Audio goes in as it's heard; `finish` says it has ended (the button came up),
/// and the whole text follows once, on `onFinal`. `cancel` drops everything, and nothing more is reported.
@MainActor
protocol Transcribing: AnyObject {
    /// Everything heard so far, while it's said (for the words shown as you speak).
    var onText: ((String) -> Void)? { get set }
    /// The whole text, once, after `finish`. Empty when nothing was said.
    var onFinal: ((String) -> Void)? { get set }
    /// It failed: why, in a few words. Nothing more is reported after it.
    var onFailure: ((String) -> Void)? { get set }
    func send(_ pcm: Data)
    func finish()
    func cancel()
}

/// What OpenAI's realtime transcription has said so far, put in order. Plain logic: the events go in as
/// JSON objects, so it's tested without the network.
///
/// The server splits what's said where you pause (semantic VAD, as PianaSoul hears) and writes each part out on its
/// own: `committed` gives a part's place, `delta`s and `completed` its words. Our own commit, when the button comes
/// up, ends the last part; when the server had just ended it itself, it answers that the buffer is empty.
struct Transcript {
    private(set) var order: [String] = []
    private var done: [String: String] = [:]
    private var partial: [String: String] = [:]
    /// Our commit was answered: a part ended, or there was nothing left to end.
    private(set) var answered = false
    private var finishing = false
    private(set) var failure: String?

    enum Change: Equatable { case none, text, failed }

    /// The button came up: our commit is on its way.
    mutating func finish() { finishing = true }

    mutating func apply(_ event: [String: Any]) -> Change {
        let type = event["type"] as? String ?? ""
        let item = event["item_id"] as? String ?? ""
        switch type {
        case "input_audio_buffer.committed":
            if !order.contains(item) { order.append(item) }
            if finishing { answered = true }
            return .none
        case "conversation.item.input_audio_transcription.delta":
            if !order.contains(item) { order.append(item) }
            partial[item, default: ""] += event["delta"] as? String ?? ""
            return .text
        case "conversation.item.input_audio_transcription.completed":
            if !order.contains(item) { order.append(item) }
            done[item] = event["transcript"] as? String ?? ""
            return .text
        case "conversation.item.input_audio_transcription.failed":
            failure = "Couldn’t hear that"
            return .failed
        case "error":
            let error = event["error"] as? [String: Any]
            // Our commit after the server had ended the last part itself: nothing was left.
            if (error?["code"] as? String) == "input_audio_buffer_commit_empty" {
                answered = true
                return .none
            }
            failure = (error?["message"] as? String).map { String($0.prefix(120)) } ?? "OpenAI refused the request"
            return .failed
        default:
            return .none
        }
    }

    /// Everything heard so far, the parts still being written out included.
    var text: String { Self.join(order.map { done[$0] ?? partial[$0] ?? "" }) }

    /// After `finish`: true once every part is written out.
    var complete: Bool { finishing && answered && order.allSatisfy { done[$0] != nil } }

    /// Parts joined as said: Chinese runs on, English keeps its spaces.
    static func join(_ parts: [String]) -> String {
        parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .reduce("") { joined, part in
                guard let last = joined.unicodeScalars.last, let first = part.unicodeScalars.first else { return joined + part }
                let wide = { (s: Unicode.Scalar) in s.properties.isIdeographic || CharacterSet.punctuationCharacters.contains(s) }
                return joined + (wide(last) || wide(first) ? "" : " ") + part
            }
    }
}

/// OpenAI's realtime transcription (wss, `intent=transcription`), as PianaSoul hears: `gpt-transcribe`, 24 kHz
/// PCM16, semantic VAD at high eagerness, a prompt and spelling hints, no noise reduction. The connection opens at
/// once, while the button is still deciding between a tap and a hold, so it's ready when the words come.
@MainActor
final class RealtimeTranscriber: Transcribing {
    struct Settings {
        var model = "gpt-transcribe"
        /// Mixed Chinese and English, as said to a TV.
        var prompt = "以下是普通话和英语混说的电视遥控器语音。打开 YouTube。播放 Taylor Swift 的 Love Story。暂停。"
        /// Words that are easy to mishear: app names, Jasmine's names, short commands.
        var keywords: [String] = []
    }

    var onText: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onFailure: ((String) -> Void)?

    /// How long to wait for the last words after the button came up.
    static let finalWait: Duration = .seconds(4)

    private let socket: URLSessionWebSocketTask
    private let settings: Settings
    private var transcript = Transcript()
    private var over = false
    private var waiting: Task<Void, Never>?

    init(key: String, settings: Settings, session: URLSession = .shared) {
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        socket = session.webSocketTask(with: request)
        self.settings = settings
        socket.resume()
        var transcription: [String: Any] = ["model": settings.model, "prompt": settings.prompt]
        if settings.model == "gpt-transcribe", !settings.keywords.isEmpty { transcription["keywords"] = Array(settings.keywords.prefix(50)) }
        send(["type": "session.update", "session": [
            "type": "transcription",
            "audio": ["input": [
                "format": ["type": "audio/pcm", "rate": 24_000],
                "transcription": transcription,
                "turn_detection": ["type": "semantic_vad", "eagerness": "high"],
                "noise_reduction": NSNull(),
            ] as [String: Any]],
        ] as [String: Any]])
        receive()
    }

    func send(_ pcm: Data) {
        guard !over, !pcm.isEmpty else { return }
        send(["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()])
    }

    func finish() {
        guard !over else { return }
        transcript.finish()
        send(["type": "input_audio_buffer.commit"])
        waiting = Task { [weak self] in
            try? await Task.sleep(for: Self.finalWait)
            guard let self, !Task.isCancelled, !self.over else { return }
            // The last words didn't come in time: what's written out is what was heard.
            let text = self.transcript.text
            if text.isEmpty { self.fail("No response from OpenAI") } else { self.end(text) }
        }
    }

    func cancel() {
        over = true
        waiting?.cancel()
        socket.cancel(with: .goingAway, reason: nil)
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message), let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in self?.fail("Can’t connect to OpenAI") }
        }
    }

    private func receive() {
        socket.receive { [weak self] result in
            let message: [String: Any]?
            let failed: Bool
            switch result {
            case .success(.string(let text)):
                message = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
                failed = false
            case .success(.data(let data)):
                message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                failed = false
            case .success:
                message = nil
                failed = false
            case .failure:
                message = nil
                failed = true
            }
            let event = message.map(SendableEvent.init)
            Task { @MainActor in
                guard let self, !self.over else { return }
                if failed { return self.fail("Can’t connect to OpenAI") }
                if let event { self.handle(event.value) }
                if !self.over { self.receive() }
            }
        }
    }

    private func handle(_ event: [String: Any]) {
        switch transcript.apply(event) {
        case .failed: fail(transcript.failure ?? "OpenAI refused the request")
        case .text: onText?(transcript.text)
        case .none: break
        }
        if !over, transcript.complete { end(transcript.text) }
    }

    private func end(_ text: String) {
        guard !over else { return }
        let final = onFinal
        cancel()
        final?(text)
    }

    private func fail(_ reason: String) {
        guard !over else { return }
        let failure = onFailure
        cancel()
        failure?(reason)
    }
}

/// A parsed JSON event, carried from URLSession's queue to the main actor (it's only read there).
private struct SendableEvent: @unchecked Sendable {
    let value: [String: Any]
}
