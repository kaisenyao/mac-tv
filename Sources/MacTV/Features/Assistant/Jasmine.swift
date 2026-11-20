import SwiftUI

/// Jasmine (小茗同学), Mac TV's assistant, and the Siri button that calls her. As on Apple TV (tvOS 27):
///
/// | Siri button | Press | Hold (InputTiming.hold) |
/// |---|---|---|
/// | A text field has focus | Nothing | Dictation into it, until you let go |
/// | A password or API key field | Nothing | Nothing: a "not now" chime (never sent to a cloud service) |
/// | Otherwise | The app's search, or the system Search (Home, apps without one); never the microphone | Jasmine, until you let go |
/// | Jasmine is showing | She stops and goes away | She stops and listens again |
///
/// The microphone starts the moment the button goes down, into a buffer, so the first word isn't lost while the
/// hold is still being decided: a press throws the buffer away (nothing was sent anywhere); a hold sends it first
/// and goes on. Back closes her. A remote, microphone or network going away while she listens cancels it.
@MainActor
final class Jasmine: ObservableObject {
    enum Mode: Equatable { case dictation, assistant }
    enum Phase: Equatable {
        case hidden
        /// Hearing you, the button held
        case listening
        /// The button is up: the last words are being written out
        case finishing
        /// Something to say in a line: what was heard, or why it can't listen
        case message
    }

    @Published private(set) var phase: Phase = .hidden
    @Published private(set) var mode: Mode = .assistant
    /// What you said, as it's heard.
    @Published private(set) var heard = ""
    /// One line from her: a reply, or why she can't listen.
    @Published private(set) var line: String?
    /// The microphone's loudness while she listens (0–1), for the orb.
    @Published private(set) var level: Float = 0

    var shown: Bool { phase != .hidden }

    private weak var tv: TVController?
    private let settings: JasmineSettings
    private let microphone: Hearing
    private let chimes: Chiming
    private let transcriber: (String) -> Transcribing
    /// Whether the microphone may be used (a test puts in its own answer).
    private let access: () -> MicrophoneAccess.Status

    /// One press of the Siri button, from down to up.
    private struct Press {
        var field: DictationField?
        /// Heard before the hold was decided: sent first if it becomes a hold.
        var buffer: [Data] = []
        var bufferedBytes = 0
        var hearing = false
        var holding = false
        /// Jasmine was showing when it went down: a press stops her; a hold listens again.
        var interrupting = false
    }
    private var press: Press?
    private var session: Transcribing?
    /// The field dictation types into when the words come.
    private var dictating: DictationField?
    private var hideTask: Task<Void, Never>?
    /// Two seconds of 24 kHz 16-bit mono: more than the hold time, in case the main actor was busy.
    private static let bufferLimit = 2 * 24_000 * 2

    init(tv: TVController, settings: JasmineSettings = .shared, microphone: Hearing? = nil, chimes: Chiming? = nil,
         transcriber: ((String) -> Transcribing)? = nil, access: (() -> MicrophoneAccess.Status)? = nil) {
        self.tv = tv
        self.settings = settings
        self.microphone = microphone ?? Microphone()
        self.chimes = chimes ?? Chimes(allowed: !SystemGuard.fake)
        self.transcriber = transcriber ?? { key in
            RealtimeTranscriber(key: key, settings: .init(keywords: Self.keywords))
        }
        self.access = access ?? { MicrophoneAccess.status }
        self.microphone.onAudio = { [weak self] data, level in self?.heard(data, level: level) }
        self.microphone.onLost = { [weak self] in self?.cancel(because: "Microphone Disconnected") }
    }

    /// Words that are easy to mishear: Jasmine's names, the apps, short commands.
    static let keywords = ["小茗同学", "Jasmine", "哔哩哔哩", "网易云音乐", "得到", "YouTube", "Movies", "Safari",
                           "暂停", "继续", "下一集", "下一首", "大声一点", "小声一点"]

    // MARK: The Siri button

    func siri(_ phase: SiriPhase) {
        switch phase {
        case .down: down()
        case .hold: hold()
        case .tap: tap()
        case .release: release()
        case .cancel: cancel(because: nil)
        }
    }

    /// Back while she's showing closes her (and the press goes no further).
    func takes(_ command: RemoteCommand) -> Bool {
        guard shown, case .back = command else { return false }
        dismiss()
        return true
    }

    private func down() {
        guard let tv, press == nil else { return }
        var press = Press(field: tv.dictationField)
        press.interrupting = shown
        if shown { stopEverything() }   // she stops as the button goes down; a press then closes her, a hold listens
        // Listening can only start where it's allowed: never for a secure field, only with Jasmine on, a key and the
        // microphone allowed (a press never asks for it).
        if press.field?.isSecure != true, settings.enabled, settings.added.contains(.openAI),
           access() == .allowed, startHearing() {
            press.hearing = true
            if let key = settings.key(.openAI) { connect(key) }
        }
        self.press = press
    }

    private func hold() {
        guard var press else { return }
        press.holding = true
        self.press = press
        if press.field?.isSecure == true {
            chimes.play(.unavailable)
            return
        }
        guard settings.enabled else { return }
        guard settings.added.contains(.openAI) else {
            return say("Add an OpenAI API key in Settings › General › Jasmine.", chime: .unavailable)
        }
        switch access() {
        case .denied:
            return say("Allow Mac TV to use the microphone in System Settings › Privacy & Security.", chime: .unavailable)
        case .notAsked:
            // macOS's question now; the next hold listens. Never in a test run.
            if SystemGuard.allows("ask for the microphone") { MicrophoneAccess.ask { _ in } }
            return
        case .allowed:
            break
        }
        if !press.hearing {
            // The microphone didn't start when the button went down (it was showing, or it failed): now, then.
            guard startHearing(), let key = settings.key(.openAI) else {
                return say("Can’t use the microphone.", chime: .unavailable)
            }
            connect(key)
            self.press?.hearing = true
        }
        mode = press.field == nil ? .assistant : .dictation
        dictating = press.field
        heard = ""
        line = nil
        hideTask?.cancel()
        withAnimation(Motion.appear) { phase = .listening }
        chimes.play(.listen)
        for piece in self.press?.buffer ?? [] { session?.send(piece) }
        self.press?.buffer = []
    }

    private func tap() {
        guard let press else { return }
        self.press = nil
        stopHearing()
        session?.cancel()
        session = nil
        if press.interrupting || shown {
            dismiss()
            return
        }
        // A press never listens: with a field in focus it does nothing; otherwise it opens search.
        if press.field == nil { tv?.openSearchForSiri() }
    }

    private func release() {
        guard let press else { return }
        self.press = nil
        guard press.hearing, phase == .listening else {
            if press.hearing { stopHearing(); session?.cancel(); session = nil }
            return
        }
        stopHearing()
        level = 0
        chimes.play(.done)
        withAnimation(Motion.appear) { phase = .finishing }
        session?.finish()
    }

    /// The remote, the microphone or the network went away: the words so far are dropped, nothing is typed or done.
    func cancel(because reason: String?) {
        press = nil
        stopHearing()
        session?.cancel()
        session = nil
        dictating = nil
        if let reason, shown { say(reason, chime: nil) } else { dismiss() }
    }

    func dismiss() {
        stopEverything()
        hideTask?.cancel()
        withAnimation(Motion.appear) {
            phase = .hidden
            heard = ""
            line = nil
        }
    }

    // MARK: Hearing

    private func startHearing() -> Bool {
        let real = microphone is Microphone
        if real { guard SystemGuard.allows("start the microphone") else { return false } }
        let input = real ? AudioInputs.choose(settings.microphone, from: AudioInputs.list()) : nil
        do { try microphone.start(input) } catch {
            Log.app.error("Jasmine: the microphone didn't start: \(String(describing: error), privacy: .public)")
            return false
        }
        return true
    }

    private func stopHearing() {
        microphone.stop()
        level = 0
    }

    private func stopEverything() {
        stopHearing()
        session?.cancel()
        session = nil
        dictating = nil
    }

    private func heard(_ data: Data, level: Float) {
        guard var press, press.hearing else {
            if phase == .listening { session?.send(data) }
            return
        }
        if press.holding, phase == .listening {
            session?.send(data)
            if abs(level - self.level) > 0.02 { self.level = level }
            return
        }
        // Not decided yet: kept, in case it's a hold.
        press.buffer.append(data)
        press.bufferedBytes += data.count
        while press.bufferedBytes > Self.bufferLimit, !press.buffer.isEmpty {
            press.bufferedBytes -= press.buffer.removeFirst().count
        }
        self.press = press
    }

    private func connect(_ key: String) {
        session?.cancel()
        let session = transcriber(key)
        session.onText = { [weak self] text in
            guard let self, self.phase == .listening || self.phase == .finishing else { return }
            self.heard = Heard.clean(text)
        }
        session.onFinal = { [weak self] text in self?.finished(Heard.clean(text)) }
        session.onFailure = { [weak self] reason in
            guard let self, self.shown else { return }
            self.session = nil
            self.stopHearing()
            self.say(reason, chime: .unavailable)
        }
        self.session = session
    }

    /// The whole of what was said.
    private func finished(_ text: String) {
        session = nil
        guard phase == .finishing else { return }
        guard Heard.meaningful(text) else { return dismiss() }   // nothing, or only noise
        heard = text
        switch mode {
        case .dictation:
            if let field = dictating { tv?.dictate(Heard.forField(text), into: field) }
            dictating = nil
            dismiss()
        case .assistant:
            // Until her brain is in: what she heard, for a moment.
            withAnimation(Motion.appear) { phase = .message }
            hide(after: .seconds(2.5))
        }
    }

    private func say(_ text: String, chime: Chime?) {
        if let chime { chimes.play(chime) }
        line = text
        withAnimation(Motion.appear) { phase = .message }
        hide(after: .seconds(4))
    }

    private func hide(after delay: Duration) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.phase == .message else { return }
            self.dismiss()
        }
    }
}

/// What speech recognition heard, made ready to use.
enum Heard {
    /// Without the recognizer's echo of its own prompt (it says it back over silence) and stray spaces.
    static func clean(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // As PianaSoul: its opening words, or the whole of the examples after them. A request that only
        // sounds like one example ("打开 YouTube") is kept.
        let prompt = RealtimeTranscriber.Settings().prompt
        let examples = prompt.split(separator: "。", maxSplits: 1).last.map(String.init) ?? ""
        if text.hasPrefix(String(prompt.prefix(6))) || text == examples { return "" }
        return text
    }

    /// Worth acting on: any word at all, one character too (停, 播), but not punctuation or nothing.
    static func meaningful(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
    }

    /// For a one-line field (a search, an address, a name): the sentence's last stop left out.
    static func forField(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last, "。．.！!？?".contains(last) { text.removeLast() }
        return text
    }
}
