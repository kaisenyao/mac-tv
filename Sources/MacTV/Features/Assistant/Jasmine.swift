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
        /// Working out what to say or do
        case thinking
        /// Saying her answer aloud
        case speaking
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
    /// A long answer shown whole: Select on MORE.
    @Published private(set) var expanded = false

    var shown: Bool { phase != .hidden }

    private weak var tv: TVController?
    private let settings: JasmineSettings
    private let microphone: Hearing
    private let chimes: Chiming
    /// A transcription session for a key; true: hands-free (her end of speech ends it, not a button).
    private let transcriber: (String, Bool) -> Transcribing
    /// Whether the microphone may be used (a test puts in its own answer).
    private let access: () -> MicrophoneAccess.Status
    private let makeBrain: (String) -> Thinking
    /// What Mac TV plays is lowered to this share while she listens and speaks (PlaybackVolume.ducking).
    private let duck: (Float) -> Void
    private let voice: Speaking
    private var brain: (key: String, thinking: Thinking)?
    private var thinkingTask: Task<Void, Never>?
    /// When the moments of one request happened, for the timing log.
    private var timing = Timing()
    struct Timing {
        var released: TimeInterval?
        var heard: TimeInterval?
        var acted: TimeInterval?
    }
    static let duckedTo: Float = 0.2

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
        /// She was listening hands-free when it went down: this press ended that (she answers what she heard), and
        /// does nothing more, whether it turns out a press or a hold.
        var ends = false
    }
    private var press: Press?
    private var session: Transcribing?
    /// The field dictation types into when the words come.
    private var dictating: DictationField?
    private var hideTask: Task<Void, Never>?
    /// A release that never came (lost on the phone's network): she stops listening after this long.
    private var listenLimit: Task<Void, Never>?
    static let longestListen: Duration = .seconds(30)
    /// Listening hands-free (Control Center's Jasmine button): it ends when you stop speaking, or after this long
    /// with nothing said.
    private var handsFree = false
    private var quietLimit: Task<Void, Never>?
    static let quietListen: Duration = .seconds(8)
    /// Two seconds of 24 kHz 16-bit mono: more than the hold time, in case the main actor was busy.
    private static let bufferLimit = 2 * 24_000 * 2

    init(tv: TVController, settings: JasmineSettings = .shared, microphone: Hearing? = nil, chimes: Chiming? = nil,
         transcriber: ((String, Bool) -> Transcribing)? = nil, access: (() -> MicrophoneAccess.Status)? = nil,
         brain: ((String) -> Thinking)? = nil, duck: ((Float) -> Void)? = nil, voice: Speaking? = nil) {
        self.tv = tv
        self.settings = settings
        self.microphone = microphone ?? Microphone()
        self.chimes = chimes ?? Chimes(allowed: !SystemGuard.fake)
        self.transcriber = transcriber ?? { key, handsFree in
            RealtimeTranscriber(key: key, settings: .init(keywords: Self.keywords), handsFree: handsFree)
        }
        self.access = access ?? { MicrophoneAccess.status }
        makeBrain = brain ?? { key in OpenAIBrain(key: key, settings: .init(instructions: TVController.jasmineInstructions)) }
        self.duck = duck ?? { PlaybackVolume.shared.ducking = $0 }
        self.voice = voice ?? Voice(key: { settings.key(.elevenLabs) }, settings: { Voice.Settings(voice: settings.voice) },
                                    allowed: !SystemGuard.fake, cache: Self.voiceCache)
        self.voice.onLevel = { [weak self] level in
            guard let self, self.phase == .speaking || self.phase == .thinking else { return }
            self.level = level
        }
        self.voice.onFinished = { [weak self] in self?.saidEverything() }
        self.microphone.onAudio = { [weak self] data, level in self?.heard(data, level: level) }
        self.microphone.onLost = { [weak self] in self?.cancel(because: "Microphone Disconnected") }
        if !SystemGuard.fake { OrbPipeline.prepare() }   // her orb's shader, compiled before she first shows
    }

    /// Where her short lines are kept once made (Voice): ~/Library/Caches/Mac TV/Jasmine.
    static let voiceCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Mac TV/Jasmine", isDirectory: true)

    /// Words that are easy to mishear: Jasmine's names, the apps, short commands.
    static let keywords = ["小茗同学", "Jasmine", "哔哩哔哩", "网易云音乐", "得到", "YouTube", "Videos", "Safari",
                           "暂停", "继续", "下一集", "下一首", "上一首", "快进", "后退", "字幕", "倍速", "大声一点", "小声一点"]

    // MARK: The Siri button

    func siri(_ phase: SiriPhase) {
        Log.app.notice("Jasmine: Siri button \(phase.rawValue, privacy: .public)")
        switch phase {
        case .down: down()
        case .hold: hold()
        case .tap: tap()
        case .release: release()
        case .cancel: cancel(because: nil)
        }
    }

    /// While she shows: Back closes her, and Select on a long answer shows the rest (MORE). Neither goes further.
    func takes(_ command: RemoteCommand) -> Bool {
        guard shown else { return false }
        switch command {
        case .back:
            dismiss()
            return true
        case .select:
            guard let line, JasmineAnswer.isCut(line), !expanded, phase == .speaking || phase == .message else { return false }
            expanded = true
            if phase == .message { hide(after: .seconds(12)) }
            return true
        default:
            return false
        }
    }

    private func down() {
        guard let tv, press == nil else { return }
        // Listening hands-free (a press of the button started it, or Control Center's): pressed again, she stops
        // listening and answers.
        if phase == .listening, handsFree {
            self.press = Press(ends: true)
            endListening()
            return
        }
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
        guard var press, !press.ends else { return }
        press.holding = true
        self.press = press
        if press.field?.isSecure == true {
            chimes.play(.unavailable)
            return
        }
        guard listen(field: press.field, hearing: press.hearing, handsFree: false) else { return }
        self.press?.hearing = true
        for piece in self.press?.buffer ?? [] { session?.send(piece) }
        self.press?.buffer = []
    }

    /// Talk to Jasmine without holding a button (Control Center's Jasmine button): she listens until you stop
    /// speaking (the server's end of speech, as PianaSoul hears), or 8 s with nothing said. Called again while she
    /// listens, she stops and answers what she heard; Back cancels. The same Jasmine as the held Siri button.
    func summon() {
        Log.app.notice("Jasmine: summoned (\(String(describing: self.phase), privacy: .public))")
        if phase == .listening, handsFree { return endListening() }
        guard press == nil else {
            Log.app.notice("Jasmine: summon ignored, the Siri button is down")
            return
        }
        if shown { stopEverything() }
        _ = listen(field: nil, hearing: false, handsFree: true)
    }

    /// Starts listening, when it may: Jasmine on, a key, the microphone allowed. False (having said why) when not.
    private func listen(field: DictationField?, hearing: Bool, handsFree: Bool) -> Bool {
        // Held, off does nothing (the button is still Search); asked for (Control Center), she says she's off.
        guard settings.enabled else {
            return refuse("she's off", saying: handsFree ? "Jasmine is turned off in Settings › General › Jasmine." : nil)
        }
        switch access() {
        case .denied:
            return refuse("the microphone isn't allowed",
                          saying: "Allow Mac TV to use the microphone in System Settings › Privacy & Security.")
        case .notAsked:
            // macOS's question now; the next try listens. Never in a test run.
            if SystemGuard.allows("ask for the microphone") { MicrophoneAccess.ask { _ in } }
            return refuse("the microphone was asked for", saying: "Allow Mac TV to use the microphone, then try again.")
        case .allowed:
            break
        }
        if !hearing {
            // The microphone didn't start when the button went down (she was showing, the key couldn't be read, or
            // it failed), or there's no button: now, then.
            guard let key = settings.key(.openAI) else {
                return refuse(settings.unreadable[.openAI] != nil ? "the OpenAI key can't be read" : "there's no OpenAI key",
                              saying: settings.problem(.openAI))
            }
            guard startHearing() else { return refuse("the microphone didn't start", saying: "Can’t use the microphone.") }
            connect(key, handsFree: handsFree)
        }
        Log.app.notice("Jasmine: listening (\(handsFree ? "hands-free" : field == nil ? "held" : "dictation", privacy: .public))")
        self.handsFree = handsFree
        mode = field == nil ? .assistant : .dictation
        dictating = field
        heard = ""
        line = nil
        expanded = false
        hideTask?.cancel()
        withAnimation(Motion.appear) { phase = .listening }
        listenLimit?.cancel()
        listenLimit = Task { [weak self] in
            try? await Task.sleep(for: Self.longestListen)
            guard !Task.isCancelled, let self, self.phase == .listening else { return }
            // Hands-free: what was said is answered. A hold never let go (its release lost): dropped, never sent on.
            if self.handsFree { self.endListening() } else { self.cancel(because: nil) }
        }
        if handsFree {
            quietLimit = Task { [weak self] in
                try? await Task.sleep(for: Self.quietListen)
                guard !Task.isCancelled, let self, self.phase == .listening, self.heard.isEmpty else { return }
                self.cancel(because: nil)
            }
        }
        duck(Self.duckedTo)
        chimes.play(.listen)
        return true
    }

    /// She can't listen: why, in the log; and in her caption, when there's something to say.
    private func refuse(_ why: String, saying line: String?) -> Bool {
        Log.app.notice("Jasmine can't listen: \(why, privacy: .public)")
        if let line { say(line, chime: .unavailable) }
        return false
    }

    private func tap() {
        guard let press else { return }
        self.press = nil
        stopHearing()
        session?.cancel()
        session = nil
        if press.ends { return }
        if press.interrupting || shown {
            dismiss()
            return
        }
        // A press: she listens without the button held, until you stop speaking (as Control Center's Jasmine button),
        // into the field in focus if there is one. With her turned off the press is Search (in a field, nothing).
        guard settings.enabled else {
            if press.field == nil { tv?.openSearchForSiri() }
            return
        }
        if press.field?.isSecure == true {
            chimes.play(.unavailable)
            return
        }
        _ = listen(field: press.field, hearing: false, handsFree: true)
    }

    private func release() {
        guard let press else { return }
        self.press = nil
        guard press.hearing, phase == .listening else {
            if press.hearing { stopHearing(); session?.cancel(); session = nil }
            return
        }
        endListening()
    }

    /// Listening ends (the button let go, or Control Center's button again): the last words are written out.
    private func endListening() {
        stopHearing()
        level = 0
        chimes.play(.done)
        withAnimation(Motion.appear) { phase = .finishing }
        timing = Timing(released: Self.now())
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
            expanded = false
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
        listenLimit?.cancel()
        listenLimit = nil
        quietLimit?.cancel()
        quietLimit = nil
        microphone.stop()
        level = 0
    }

    private func stopEverything() {
        stopHearing()
        session?.cancel()
        session = nil
        dictating = nil
        thinkingTask?.cancel()
        thinkingTask = nil
        brain?.thinking.cancel()
        voice.stop()
        handsFree = false
        duck(1)
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

    private func connect(_ key: String, handsFree: Bool = false) {
        session?.cancel()
        let session = transcriber(key, handsFree)
        session.onText = { [weak self] text in
            guard let self, self.phase == .listening || self.phase == .finishing else { return }
            self.heard = Heard.clean(text)
        }
        session.onFinal = { [weak self] text in
            guard let self else { return }
            // Hands-free, her end of speech ended it: as if the button were let go.
            if self.phase == .listening, self.handsFree {
                self.stopHearing()
                self.level = 0
                self.chimes.play(.done)
                withAnimation(Motion.appear) { self.phase = .finishing }
                self.timing = Timing(released: Self.now())
            }
            self.finished(Heard.clean(text))
        }
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
            timing.heard = Self.now()
            respond(to: text)
        }
    }

    /// A request: a short command at once, here; anything else to her model, with Mac TV's tools.
    private func respond(to text: String) {
        guard let tv else { return dismiss() }
        if let command = LocalCommand.match(text, apps: tv.jasmineApps) {
            let failure = tv.perform(command)
            timing.acted = Self.now()
            logTiming(local: true)
            duck(1)
            line = failure?.line
            withAnimation(Motion.appear) { phase = .message }
            hide(after: .seconds(failure == nil ? 1.2 : 2.5))
            return
        }
        guard let key = settings.key(.openAI) else { return say("Add an OpenAI API key in Settings › General › Jasmine.", chime: .unavailable) }
        if brain?.key != key { brain = (key, makeBrain(key)) }
        guard let thinking = brain?.thinking else { return }
        withAnimation(Motion.appear) { phase = .thinking }
        thinkingTask = Task { [weak self, weak tv] in
            do {
                let reply = try await thinking.respond(
                    to: text, state: tv?.jasmineState() ?? "{}", tools: tv?.jasmineTools ?? [],
                    meanwhile: { [weak self] early in
                        guard let self, self.phase == .thinking else { return }
                        self.line = early
                        self.voice.say(early)   // said while the tools run
                    },
                    perform: { [weak self, weak tv] call in
                        if self?.timing.acted == nil { self?.timing.acted = Self.now() }
                        return tv?.performJasmine(call) ?? #"{"ok":false}"#
                    })
                guard let self, !Task.isCancelled, self.phase == .thinking else { return }
                self.logTiming(local: false)
                if !reply.isEmpty {
                    self.line = reply
                    self.voice.say(reply)
                }
                guard self.line != nil else { return self.dismiss() }
                withAnimation(Motion.appear) { self.phase = .speaking }   // what's playing stays low until she's done
                if !self.voice.speaking { self.saidEverything() }
            } catch BrainFailure.cancelled {
            } catch BrainFailure.refused(let reason) {
                guard let self, self.phase == .thinking else { return }
                self.duck(1)
                self.say(reason, chime: .unavailable)
            } catch {
                guard let self, self.phase == .thinking else { return }
                self.duck(1)
                self.say("Can’t Reach OpenAI", chime: .unavailable)
            }
        }
    }

    /// She has said everything: what's playing comes back up, and she goes two seconds later.
    private func saidEverything() {
        guard phase == .speaking else { return }
        level = 0
        duck(1)
        withAnimation(Motion.appear) { phase = .message }
        // Two seconds once she's done; a long answer stays to be read.
        hide(after: .seconds(line.map { JasmineAnswer.isLong($0) ? (expanded ? 12 : 6) : 2 } ?? 2))
    }

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// One line per request: from letting go of the button to the words, the first action and the answer.
    private func logTiming(local: Bool) {
        guard let released = timing.released else { return }
        let text = timing.heard.map { String(format: "%.2f", $0 - released) } ?? "-"
        let acted = timing.acted.map { String(format: "%.2f", $0 - released) } ?? "-"
        let answer = String(format: "%.2f", Self.now() - released)
        Log.app.notice("Jasmine timing (\(local ? "local" : "model", privacy: .public)): words \(text, privacy: .public) s, action \(acted, privacy: .public) s, answer \(answer, privacy: .public) s")
    }

    private func say(_ text: String, chime: Chime?) {
        if let chime { chimes.play(chime) }
        duck(1)
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
