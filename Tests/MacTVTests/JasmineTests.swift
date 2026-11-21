import AppKit
import CoreAudio
import Foundation
import Testing
@testable import MacTV

/// Jasmine (小茗同学) and the Siri button: press and hold, the microphone from the moment the button goes down,
/// dictation into the field with focus, secure fields, Search, cancelling, and the API keys. The microphone, the
/// chimes and OpenAI are fakes: nothing here listens, plays or reaches the network.
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct JasmineTests {
    init() { _ = NSApplication.shared }

    // MARK: Fakes

    final class FakeMicrophone: Hearing {
        var onAudio: ((Data, Float) -> Void)?
        var onLost: (() -> Void)?
        private(set) var running = false
        private(set) var starts = 0
        func start(_ input: AudioInput?) throws { running = true; starts += 1 }
        func stop() { running = false }
        /// A tenth of a second of audio, marked so the order can be checked.
        func hear(_ mark: UInt8, level: Float = 0.5) {
            guard running else { return }
            onAudio?(Data([mark, mark]), level)
        }
    }

    final class FakeTranscriber: Transcribing {
        var onText: ((String) -> Void)?
        var onFinal: ((String) -> Void)?
        var onFailure: ((String) -> Void)?
        var handsFree = false
        private(set) var sent: [Data] = []
        private(set) var finished = false
        private(set) var cancelled = false
        func send(_ pcm: Data) { sent.append(pcm) }
        func finish() { finished = true }
        func cancel() { cancelled = true }
    }

    final class FakeBrain: Thinking {
        var script: (String, @MainActor (String) -> Void, @MainActor (ToolCall) async -> String) async throws -> String = { _, _, _ in "" }
        private(set) var asked: [(text: String, state: String)] = []
        private(set) var cancels = 0
        func respond(to text: String, state: String, tools: [AssistantTool], meanwhile: @escaping @MainActor (String) -> Void,
                     perform: @escaping @MainActor (ToolCall) async -> String) async throws -> String {
            asked.append((text, state))
            return try await script(text, meanwhile, perform)
        }
        func cancel() { cancels += 1 }
    }

    final class FakeVoice: Speaking {
        var onLevel: ((Float) -> Void)?
        var onFinished: (() -> Void)?
        private(set) var said: [String] = []
        private(set) var stops = 0
        private(set) var speaking = false
        func say(_ text: String) { said.append(text); speaking = true }
        func stop() { stops += 1; speaking = false }
        /// Everything given has been said.
        func finish() { speaking = false; onFinished?() }
    }

    final class FakeChimes: Chiming {
        private(set) var played: [Chime] = []
        func play(_ chime: Chime) { played.append(chime) }
    }

    @MainActor struct Rig {
        let tv: TVController
        let microphone: FakeMicrophone
        let chimes: FakeChimes
        let settings: JasmineSettings
        let box: Box
        final class Box { var made: [FakeTranscriber] = []; var ducks: [Float] = [] }
        let brain: FakeBrain
        let voice: FakeVoice
        var ducks: [Float] { box.ducks }
        var transcribers: [FakeTranscriber] { box.made }

        func siri(_ phases: SiriPhase...) { phases.forEach { tv.handle(.siri($0), from: .siriRemote) } }
    }

    /// A TV with Jasmine on fakes; `key` adds an OpenAI key (in memory, as every Keychain item under the tests).
    static func withJasmine(key: Bool = true, access: MicrophoneAccess.Status = .allowed,
                            _ body: (Rig) async throws -> Void) async throws {
        try await InteractionTests.withTV { tv in
            let suite = "MacTVTests.Jasmine.\(UUID().uuidString)"
            let settings = JasmineSettings(defaults: TestDefaults.named(suite))
            defer {
                TestDefaults.remove(suite)
                JasmineKey.allCases.forEach { JasmineSettings.shared.remove($0) }
            }
            if key { settings.save("sk-test-not-a-real-key", for: .openAI) }
            let rig = Rig(tv: tv, microphone: FakeMicrophone(), chimes: FakeChimes(), settings: settings, box: Rig.Box(),
                          brain: FakeBrain(), voice: FakeVoice())
            tv.jasmine = Jasmine(tv: tv, settings: settings, microphone: rig.microphone, chimes: rig.chimes,
                                 transcriber: { _, handsFree in
                                     let t = FakeTranscriber(); t.handsFree = handsFree; rig.box.made.append(t); return t
                                 },
                                 access: { access }, brain: { _ in rig.brain }, duck: { rig.box.ducks.append($0) },
                                 voice: rig.voice)
            try await body(rig)
            tv.jasmine.dismiss()
        }
    }

    // MARK: The button's timing

    @Test func aPressAndAHoldFromTheSameButton() {
        var press = SiriPress(holdAfter: 0.5)
        #expect(press.press(at: 0) == [.down])
        #expect(press.press(at: 0.1) == [])                     // a key repeat
        #expect(press.advance(to: 0.4) == [])
        #expect(press.release(at: 0.45) == [.tap])
        #expect(press.press(at: 1) == [.down])
        #expect(press.nextDeadline == 1.5)
        #expect(press.advance(to: 1.5) == [.hold])
        #expect(press.nextDeadline == nil)
        #expect(press.release(at: 3) == [.release])
        // A timer that came late: the hold still comes before the release
        #expect(press.press(at: 4) == [.down])
        #expect(press.release(at: 4.9) == [.hold, .release])
        // The remote went away mid-press
        #expect(press.press(at: 5) == [.down])
        #expect(press.reset() == [.cancel])
        #expect(press.reset() == [])
    }

    @Test func theSiriRemotesSiriButton() {
        var r = SiriRemoteRecognizer()
        #expect(r.press(.siri, at: 0) == [.siri(.down)])
        #expect(r.nextDeadline == InputTiming.hold)
        #expect(r.advance(to: InputTiming.hold) == [.siri(.hold)])
        #expect(r.release(.siri, at: 2) == [.siri(.release)])
        #expect(r.press(.siri, at: 3) == [.siri(.down)])
        #expect(r.release(.siri, at: 3.2) == [.siri(.tap)])
        #expect(r.press(.siri, at: 4) == [.siri(.down)])
        #expect(r.reset() == [.siri(.cancel)])
    }

    @Test func thePhoneSendsTheSameButton() {
        for phase in ["down", "tap", "hold", "release", "cancel"] {
            guard case .siri(let parsed)? = RemoteCommand(json: ["a": "siri", "p": phase]) else {
                Issue.record("siri \(phase) not understood"); continue
            }
            #expect(parsed.rawValue == phase)
        }
        #expect(RemoteCommand(json: ["a": "siri", "p": "listen"]) == nil)
    }

    @Test func theKeyboardAndAControllerTimeTheSameButton() async throws {
        try await Self.withJasmine { rig in
            rig.tv.openSystemSearch()
            let presses = rig.tv.inputPresses
            presses.siriDown(from: .keyboard, at: 0)            // F5
            #expect(rig.microphone.running)
            presses.advance(to: InputTiming.hold)
            #expect(rig.tv.jasmine.phase == .listening && rig.tv.jasmine.mode == .dictation)
            #expect(presses.siriUp(from: .keyboard, at: 1))
            #expect(rig.transcribers[0].finished)
            presses.siriDown(from: .controller, at: 2)          // Y, then the controller goes away
            presses.reset(.controller)
            #expect(!rig.microphone.running && rig.transcribers[1].cancelled)
            #expect(!presses.siriUp(from: .controller, at: 3))
        }
    }

    @Test func fnF5IsLetGoWhenItsUpEvenWithoutAKeyUp() async throws {
        try await Self.withJasmine { rig in
            let presses = rig.tv.inputPresses
            var f5Down = true
            presses.siriDown(from: .keyboard, at: 0)
            presses.watchSiri(from: .keyboard) { f5Down }
            presses.checkWatched()
            #expect(rig.microphone.running, "still down")
            f5Down = false                                      // let go, and no keyUp came
            presses.checkWatched()
            #expect(rig.tv.activeSheet == .search, "a press")
            #expect(!rig.microphone.running)
            // The next press works
            presses.siriDown(from: .keyboard, at: 1)
            #expect(rig.microphone.running && rig.transcribers.count == 2)
            #expect(presses.siriUp(from: .keyboard, at: 1.1))
        }
    }

    @Test func aSiriKeyWithoutItsKeyUpEndsWithTheNextPress() async throws {
        try await Self.withJasmine { rig in
            let presses = rig.tv.inputPresses
            presses.siriDown(from: .keyboard, at: 0)            // fn-F5: no watch (its state reads up), no keyUp
            presses.advance(to: InputTiming.hold)
            #expect(rig.tv.jasmine.phase == .listening)
            #expect(presses.siriIsDown(from: .keyboard))
            // The next keyDown (main.swift): the open press ends first, then the new one starts
            #expect(presses.siriUp(from: .keyboard, at: 3))
            #expect(rig.transcribers[0].finished && !presses.siriIsDown(from: .keyboard))
            presses.siriDown(from: .keyboard, at: 3)
            #expect(presses.siriIsDown(from: .keyboard) && rig.microphone.running && rig.transcribers.count == 2)
        }
    }

    @Test func aPressWhoseKeyUpWasLostIsCancelledNotSent() async throws {
        try await Self.withJasmine { rig in
            let presses = rig.tv.inputPresses
            // Dictating, then F5 pressed again with no keyUp between (main.swift cancels the open press)
            rig.tv.openSystemSearch()
            presses.siriDown(from: .keyboard, at: 0)
            presses.advance(to: InputTiming.hold)
            rig.microphone.hear(1)
            presses.siriCancel(from: .keyboard)
            #expect(rig.transcribers[0].cancelled && !rig.transcribers[0].finished, "nothing committed")
            rig.transcribers[0].onFinal?("打开设置")             // a late answer is ignored
            #expect(rig.tv.systemSearch?.query == "" && !rig.tv.jasmine.shown)
            // Talking to her: nothing is done or asked
            rig.tv.closeSystemSearch()
            presses.siriDown(from: .keyboard, at: 1)
            presses.advance(to: 1 + InputTiming.hold)
            presses.siriCancel(from: .keyboard)
            rig.transcribers[1].onFinal?("打开设置")
            #expect(rig.tv.activeSheet == nil && rig.brain.asked.isEmpty)
            #expect(!presses.siriIsDown(from: .keyboard))
            #expect(rig.ducks.last == 1)
            // A release that comes after all is ignored
            #expect(!presses.siriUp(from: .keyboard, at: 2))
        }
    }

    // MARK: Hands-free (Control Center's Jasmine button)

    @Test func summonedSheListensUntilYouStop() async throws {
        try await Self.withJasmine { rig in
            rig.tv.jasmine.summon()
            #expect(rig.microphone.running && rig.transcribers.count == 1 && rig.transcribers[0].handsFree)
            #expect(rig.tv.jasmine.phase == .listening && rig.tv.jasmine.mode == .assistant)
            #expect(rig.chimes.played == [.listen] && rig.ducks == [Jasmine.duckedTo])
            rig.microphone.hear(1)
            #expect(rig.transcribers[0].sent == [Data([1, 1])], "sent as it's heard: no button to wait for")
            rig.transcribers[0].onText?("打开设置")
            rig.transcribers[0].onFinal?("打开设置")             // the server heard you stop
            #expect(!rig.microphone.running && rig.chimes.played == [.listen, .done])
            #expect(rig.tv.activeSheet == .settings)
        }
    }

    @Test func summonedAgainSheAnswersWhatSheHeard() async throws {
        try await Self.withJasmine { rig in
            rig.brain.script = { _, _, _ in "你好！" }
            rig.tv.jasmine.summon()
            rig.tv.jasmine.summon()
            #expect(rig.transcribers[0].finished && !rig.microphone.running)
            rig.transcribers[0].onFinal?("你好")
            await Self.waitUntil { rig.tv.jasmine.phase == .speaking }
            #expect(rig.brain.asked.first?.text == "你好")
        }
    }

    @Test func backCancelsASummon() async throws {
        try await Self.withJasmine { rig in
            rig.tv.jasmine.summon()
            rig.tv.handle(.back, from: .siriRemote)
            #expect(!rig.tv.jasmine.shown && rig.transcribers[0].cancelled && !rig.microphone.running)
            rig.transcribers[0].onFinal?("打开设置")
            #expect(rig.tv.activeSheet == nil)
            #expect(rig.ducks.last == 1)
        }
    }

    @Test func handsFreeEndsWhenTheSpeakerStops() {
        var transcript = Transcript()
        _ = transcript.apply(["type": "input_audio_buffer.speech_started", "item_id": "a"])
        #expect(!transcript.spokenAndDone)
        _ = transcript.apply(["type": "input_audio_buffer.committed", "item_id": "a"])
        #expect(!transcript.spokenAndDone, "not written out yet")
        _ = transcript.apply(["type": "conversation.item.input_audio_transcription.completed", "item_id": "a", "transcript": "暂停"])
        #expect(transcript.spokenAndDone)
        _ = transcript.apply(["type": "input_audio_buffer.speech_started", "item_id": "b"])
        #expect(!transcript.spokenAndDone, "still speaking")
    }

    @Test func aKeyUpWithoutItsKeyDownIsAPress() async throws {
        try await Self.withJasmine { rig in
            let presses = rig.tv.inputPresses
            // macOS kept the 🎤 key's keyDown: its keyUp alone is a press (Search), so the key is never dead
            #expect(presses.siriKeyUp(from: .keyboard, at: 0))
            #expect(rig.tv.activeSheet == .search && !rig.microphone.running && !presses.siriIsDown(from: .keyboard))
            rig.tv.closeSystemSearch()
            // A press the watch let go (fn up first): its keyUp, coming after all, does nothing more
            presses.siriDown(from: .keyboard, at: 1)
            presses.watchSiri(from: .keyboard) { false }
            presses.checkWatched()
            #expect(rig.tv.activeSheet == .search)
            rig.tv.closeSystemSearch()
            #expect(presses.siriKeyUp(from: .keyboard, at: 1.2))
            #expect(rig.tv.activeSheet == nil, "not a second press")
            // With a press open, the keyUp is its release
            presses.siriDown(from: .keyboard, at: 2)
            presses.advance(to: 2 + InputTiming.hold)
            #expect(rig.tv.jasmine.phase == .listening)
            #expect(presses.siriKeyUp(from: .keyboard, at: 3))
            #expect(rig.tv.jasmine.phase == .finishing)
        }
    }

    // MARK: What was heard

    @Test func shortCommandsCountNoiseDoesnt() {
        #expect(Heard.meaningful("停"))
        #expect(Heard.meaningful("播"))
        #expect(Heard.meaningful("打开 YouTube"))
        #expect(!Heard.meaningful("。"))
        #expect(!Heard.meaningful(" "))
        #expect(Heard.forField("猫和老鼠。") == "猫和老鼠")
        #expect(Heard.forField("Taylor Swift.") == "Taylor Swift")
        #expect(Heard.clean(RealtimeTranscriber.Settings().prompt) == "")   // the recognizer saying its prompt back
    }

    @Test func partsAreJoinedAsSaid() {
        var transcript = Transcript()
        _ = transcript.apply(["type": "input_audio_buffer.committed", "item_id": "a"])
        _ = transcript.apply(["type": "conversation.item.input_audio_transcription.delta", "item_id": "a", "delta": "播放"])
        #expect(transcript.text == "播放")
        _ = transcript.apply(["type": "conversation.item.input_audio_transcription.completed", "item_id": "a", "transcript": "播放"])
        transcript.finish()
        #expect(!transcript.complete)                            // our commit isn't answered yet
        _ = transcript.apply(["type": "input_audio_buffer.committed", "item_id": "b"])
        _ = transcript.apply(["type": "conversation.item.input_audio_transcription.completed", "item_id": "b",
                              "transcript": "Taylor Swift"])
        #expect(transcript.complete)
        #expect(transcript.text == "播放Taylor Swift")
        #expect(Transcript.join(["Play", "Taylor Swift"]) == "Play Taylor Swift")
    }

    @Test func aCommitWithNothingLeftStillEnds() {
        var transcript = Transcript()
        _ = transcript.apply(["type": "input_audio_buffer.committed", "item_id": "a"])
        _ = transcript.apply(["type": "conversation.item.input_audio_transcription.completed", "item_id": "a", "transcript": "停"])
        transcript.finish()
        #expect(transcript.apply(["type": "error", "error": ["code": "input_audio_buffer_commit_empty", "message": "empty"]]) == .none)
        #expect(transcript.complete)
        #expect(transcript.text == "停")
        #expect(transcript.apply(["type": "error", "error": ["message": "Incorrect API key provided"]]) == .failed)
    }

    // MARK: The microphone

    @Test func theMicrophoneThatStaysPluggedIn() {
        let builtIn = AudioInput(id: 1, uid: "built-in", name: "MacBook Pro Microphone", transport: kAudioDeviceTransportTypeBuiltIn)
        let usb = AudioInput(id: 2, uid: "usb", name: "MX Brio", transport: kAudioDeviceTransportTypeUSB)
        let airPods = AudioInput(id: 3, uid: "airpods", name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth)
        #expect(AudioInputs.choose(nil, from: [airPods, builtIn, usb]) == usb)        // not macOS's default, AirPods
        #expect(AudioInputs.choose(nil, from: [airPods, builtIn]) == builtIn)
        #expect(AudioInputs.choose(nil, from: [airPods]) == airPods)
        #expect(AudioInputs.choose("airpods", from: [airPods, usb]) == airPods)       // chosen in Settings
        #expect(AudioInputs.choose("gone", from: [builtIn, usb]) == usb)              // chosen, but not connected
        #expect(AudioInputs.choose(nil, from: []) == nil)
    }

    // MARK: Dictation

    @Test func holdingDictatesIntoTheFieldFromTheFirstWord() async throws {
        try await Self.withJasmine { rig in
            rig.tv.openSystemSearch()
            #expect(rig.tv.dictationField == .systemSearch)
            rig.siri(.down)
            #expect(rig.microphone.running, "the microphone starts with the button")
            #expect(rig.transcribers.count == 1, "and the connection")
            rig.microphone.hear(1)
            rig.microphone.hear(2)
            #expect(rig.transcribers[0].sent.isEmpty, "nothing leaves the Mac before it's a hold")
            #expect(!rig.tv.jasmine.shown)
            rig.siri(.hold)
            #expect(rig.tv.jasmine.phase == .listening && rig.tv.jasmine.mode == .dictation)
            #expect(rig.chimes.played == [.listen])
            rig.microphone.hear(3)
            #expect(rig.transcribers[0].sent == [Data([1, 1]), Data([2, 2]), Data([3, 3])], "the first word first")
            rig.transcribers[0].onText?("打开")
            #expect(rig.tv.jasmine.heard == "打开")
            rig.siri(.release)
            #expect(!rig.microphone.running && rig.transcribers[0].finished)
            #expect(rig.chimes.played == [.listen, .done])
            rig.transcribers[0].onFinal?("打开 YouTube。")
            #expect(rig.tv.systemSearch?.query == "打开 YouTube")
            #expect(rig.tv.systemSearch?.typing == true)
            #expect(!rig.tv.jasmine.shown)
        }
    }

    @Test func aPressNeverListens() async throws {
        try await Self.withJasmine { rig in
            // Home: a press opens Search; what the microphone heard meanwhile is thrown away
            rig.siri(.down)
            rig.microphone.hear(1)
            rig.siri(.tap)
            #expect(rig.tv.activeSheet == .search)
            #expect(!rig.microphone.running)
            #expect(rig.transcribers[0].cancelled && rig.transcribers[0].sent.isEmpty)
            #expect(rig.chimes.played.isEmpty && !rig.tv.jasmine.shown)
            // With the field highlighted, a press does nothing
            rig.siri(.down, .tap)
            #expect(rig.tv.activeSheet == .search && rig.tv.systemSearch?.query == "")
            #expect(rig.transcribers.allSatisfy { $0.sent.isEmpty })
        }
    }

    @Test func secureFieldsAreNeverDictated() async throws {
        try await Self.withJasmine { rig in
            rig.tv.openSettings()
            rig.tv.settings = SettingsPanel(section: .general, open: true,
                                            path: [.init(page: .jasmine(.main), from: 0), .init(page: .jasmine(.key(.elevenLabs)), from: 4)])
            #expect(rig.tv.dictationField == .secure)
            rig.siri(.down, .hold)
            rig.microphone.hear(1)
            rig.siri(.release)
            #expect(rig.microphone.starts == 0, "the microphone never starts")
            #expect(rig.transcribers.isEmpty)
            #expect(rig.chimes.played == [.unavailable])
            #expect(rig.tv.settings?.secret.text == "")
        }
    }

    @Test func noiseOrNothingTypesNothing() async throws {
        try await Self.withJasmine { rig in
            rig.tv.openSystemSearch()
            rig.siri(.down, .hold, .release)
            rig.transcribers[0].onFinal?("。")
            #expect(rig.tv.systemSearch?.query == "")
            #expect(!rig.tv.jasmine.shown)
            // One character is a word
            rig.siri(.down, .hold, .release)
            rig.transcribers[1].onFinal?("停")
            #expect(rig.tv.systemSearch?.query == "停")
        }
    }

    @Test func goingAwayMidHoldCancels() async throws {
        try await Self.withJasmine { rig in
            rig.tv.openSystemSearch()
            rig.siri(.down, .hold)
            rig.microphone.hear(1)
            rig.siri(.cancel)                                    // the remote disconnected
            #expect(!rig.microphone.running && rig.transcribers[0].cancelled)
            #expect(!rig.tv.jasmine.shown)
            rig.transcribers[0].onFinal?("late words")
            #expect(rig.tv.systemSearch?.query == "", "nothing typed afterwards")
            // The microphone unplugged while listening
            rig.siri(.down, .hold)
            rig.microphone.onLost?()
            #expect(rig.transcribers[1].cancelled && rig.tv.jasmine.line == "Microphone Disconnected")
        }
    }

    // MARK: Jasmine

    @Test func holdingElsewhereTalksToJasmine() async throws {
        try await Self.withJasmine { rig in
            rig.siri(.down, .hold)
            #expect(rig.tv.jasmine.phase == .listening && rig.tv.jasmine.mode == .assistant)
            rig.siri(.release)
            rig.brain.script = { _, _, _ in "我是小茗同学。" }
            rig.transcribers[0].onFinal?("你是谁")
            await Self.waitUntil { rig.tv.jasmine.phase == .speaking }
            #expect(rig.tv.jasmine.shown && rig.tv.jasmine.heard == "你是谁")
            #expect(rig.tv.activeSheet == nil, "Home stays as it was")
            // A press while she shows: she goes away, and it opens nothing
            rig.siri(.down, .tap)
            #expect(!rig.tv.jasmine.shown && rig.tv.activeSheet == nil)
            // Back closes her, and goes no further
            rig.siri(.down, .hold, .release)
            rig.tv.handle(.back, from: .siriRemote)
            #expect(!rig.tv.jasmine.shown)
            #expect(rig.transcribers.last?.cancelled == true)
        }
    }

    @Test func holdingWhileSheShowsListensAgain() async throws {
        try await Self.withJasmine { rig in
            rig.brain.script = { _, _, _ in "你好！" }
            rig.siri(.down, .hold, .release)
            rig.transcribers[0].onFinal?("你好")
            await Self.waitUntil { rig.tv.jasmine.phase == .speaking }
            rig.siri(.down, .hold)
            #expect(rig.tv.jasmine.phase == .listening && rig.tv.jasmine.heard == "")
            #expect(rig.microphone.running && rig.transcribers.count == 2)
        }
    }

    @Test func withoutAKeyOrTheMicrophoneSheSaysSo() async throws {
        try await Self.withJasmine(key: false) { rig in
            rig.siri(.down, .hold)
            #expect(rig.microphone.starts == 0 && rig.transcribers.isEmpty)
            #expect(rig.tv.jasmine.line == "Add an OpenAI API key in Settings › General › Jasmine.")
        }
        try await Self.withJasmine(access: .denied) { rig in
            rig.siri(.down, .hold)
            #expect(rig.microphone.starts == 0)
            #expect(rig.tv.jasmine.line?.contains("Privacy & Security") == true)
        }
    }

    @Test func offTheButtonOnlyOpensSearch() async throws {
        try await Self.withJasmine { rig in
            rig.settings.enabled = false
            rig.siri(.down, .hold, .release)
            #expect(rig.microphone.starts == 0 && !rig.tv.jasmine.shown)
            rig.siri(.down, .tap)
            #expect(rig.tv.activeSheet == .search)
        }
    }

    @Test func theButtonSleepsWithTheTV() async throws {
        try await Self.withJasmine { rig in
            rig.tv.enterStandby(reason: "test")
            rig.siri(.down, .hold, .release, .down, .tap)
            #expect(rig.microphone.starts == 0 && rig.tv.activeSheet == nil && rig.tv.standby)
        }
    }

    // MARK: Doing things

    /// Waits for her model's answer (a fake, answering at once), at most 5 s.
    static func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), "waited 5 s")
    }

    @Test func shortCommandsNeedNoModel() {
        let apps = [(id: "bilibili", name: "哔哩哔哩"), (id: "youtube", name: "YouTube"), (id: "settings", name: "Settings"),
                    (id: "netease", name: "网易云音乐")]
        #expect(LocalCommand.match("暂停。", apps: apps) == .pause)
        #expect(LocalCommand.match("停", apps: apps) == .pause)
        #expect(LocalCommand.match("播", apps: apps) == .play)
        #expect(LocalCommand.match("Pause.", apps: apps) == .pause)
        #expect(LocalCommand.match("大声一点", apps: apps) == .volumeStep(10))
        #expect(LocalCommand.match("Turn it down", apps: apps) == .volumeStep(-10))
        #expect(LocalCommand.match("打开 YouTube", apps: apps) == .open("youtube"))
        #expect(LocalCommand.match("打开B站", apps: apps) == .open("bilibili"))
        #expect(LocalCommand.match("帮我打开网易云", apps: apps) == .open("netease"))
        #expect(LocalCommand.match("Open Settings", apps: apps) == .settings)
        #expect(LocalCommand.match("回到主屏幕", apps: apps) == .home)
        #expect(LocalCommand.match("播放 Taylor Swift", apps: apps) == nil, "a search is the model's")
        #expect(LocalCommand.match("打开冰箱", apps: apps) == nil)
    }

    @Test func aShortCommandIsDoneAtOnce() async throws {
        try await Self.withJasmine { rig in
            rig.siri(.down, .hold)
            #expect(rig.ducks == [Jasmine.duckedTo], "what's playing is lowered while she listens")
            rig.siri(.release)
            rig.transcribers[0].onFinal?("打开设置")
            #expect(rig.tv.activeSheet == .settings)
            #expect(rig.brain.asked.isEmpty, "no model")
            #expect(rig.ducks.last == 1)
            #expect(rig.tv.jasmine.phase == .message && rig.tv.jasmine.heard == "打开设置")
        }
    }

    @Test func anythingElseGoesToHerModelWithTheTVsTools() async throws {
        try await Self.withJasmine { rig in
            rig.brain.script = { _, meanwhile, perform in
                meanwhile("好的")
                let result = await perform(ToolCall(id: "c1", name: "open", arguments: ["target": "settings"]))
                #expect(result == #"{"ok":true}"#)
                return "设置打开了。"
            }
            rig.siri(.down, .hold, .release)
            rig.transcribers[0].onFinal?("我想改一下设置")
            await Self.waitUntil { rig.tv.jasmine.phase == .speaking }
            #expect(rig.brain.asked.first?.text == "我想改一下设置")
            #expect(rig.brain.asked.first?.state.contains(#""screen":"Home""#) == true)
            #expect(rig.tv.activeSheet == .settings)
            #expect(rig.tv.jasmine.line == "设置打开了。")
            #expect(rig.voice.said == ["好的", "设置打开了。"], "the early line while the tool runs, then the answer")
            #expect(rig.ducks == [Jasmine.duckedTo], "still lowered while she speaks")
            rig.voice.finish()
            #expect(rig.tv.jasmine.phase == .message)
            #expect(rig.ducks == [Jasmine.duckedTo, 1], "then as it was")
        }
    }

    @Test func pressingWhileSheSpeaksStopsHer() async throws {
        try await Self.withJasmine { rig in
            rig.brain.script = { _, _, _ in "从前有座山。山里有座庙。" }
            rig.siri(.down, .hold, .release)
            rig.transcribers[0].onFinal?("讲个故事")
            await Self.waitUntil { rig.tv.jasmine.phase == .speaking }
            rig.siri(.down)                                      // she stops as the button goes down
            #expect(rig.voice.stops >= 1 && !rig.voice.speaking)
            rig.siri(.hold)                                      // and listens again
            #expect(rig.tv.jasmine.phase == .listening)
            #expect(rig.ducks.last == Jasmine.duckedTo)
        }
    }

    @Test func sentencesAreSaidOneByOne() {
        #expect(Sentences.split("从前有座山。山里有座庙！好吗？") == ["从前有座山。", "山里有座庙！", "好吗？"])
        #expect(Sentences.split("Sure. It's 3 p.m. now. Anything else?") == ["Sure.", "It's 3 p.m. now.", "Anything else?"])
        #expect(Sentences.split("好的") == ["好的"])
        #expect(Sentences.split("  ") == [])
        #expect(Sentences.isChinese("好的，打开了 YouTube"))
        #expect(!Sentences.isChinese("Opening YouTube"))
        let ladaisy = Voice.Settings(voice: "8RCmdqih4CKjJ7Bd3ZxT"), yating = Voice.Settings(voice: "5eoK8NqMBsMdqUmImHNs")
        #expect(Voice.clipKey("好的。", ladaisy) == Voice.clipKey("好的。", ladaisy))
        #expect(Voice.clipKey("好的。", ladaisy) != Voice.clipKey("好的。", yating), "each voice keeps its own lines")
    }

    @Test func herModelFailingSaysWhy() async throws {
        try await Self.withJasmine { rig in
            rig.brain.script = { _, _, _ in throw BrainFailure.refused("Incorrect API key provided") }
            rig.siri(.down, .hold, .release)
            rig.transcribers[0].onFinal?("今天天气怎么样")
            await Self.waitUntil { rig.tv.jasmine.phase == .message }
            #expect(rig.tv.jasmine.line == "Incorrect API key provided")
            #expect(rig.chimes.played.last == .unavailable)
        }
    }

    @Test func pressingWhileSheThinksStopsHer() async throws {
        try await Self.withJasmine { rig in
            rig.brain.script = { _, _, _ in
                try await Task.sleep(for: .seconds(30))
                return "too late"
            }
            rig.siri(.down, .hold, .release)
            rig.transcribers[0].onFinal?("讲个笑话")
            await Self.waitUntil { rig.brain.asked.count == 1 }
            #expect(rig.tv.jasmine.phase == .thinking)
            rig.siri(.down, .tap)
            #expect(rig.brain.cancels >= 1 && !rig.tv.jasmine.shown)
            #expect(rig.ducks.last == 1)
        }
    }

    @Test func herToolsCheckWhatTheyreGiven() async throws {
        try await Self.withJasmine { rig in
            let tv = rig.tv
            #expect(tv.performJasmine(ToolCall(id: "1", name: "open", arguments: ["target": "nowhere"])).contains("not understood"))
            #expect(tv.performJasmine(ToolCall(id: "2", name: "control", arguments: ["action": "pause"])).contains("nothing is playing"))
            #expect(tv.performJasmine(ToolCall(id: "3", name: "fly", arguments: [:])).contains("not understood"))
            #expect(tv.jasmineTools.map(\.name) == ["open", "control", "volume"])
            let state = tv.jasmineState()
            #expect(!state.contains("sk-"), "no keys in what the model is told")
        }
    }

    @Test func duckingLowersWithoutTouchingTheVolume() {
        let suite = "MacTVTests.Ducking.\(UUID().uuidString)"
        defer { TestDefaults.remove(suite) }
        let volume = PlaybackVolume(defaults: TestDefaults.named(suite))
        volume.use("output")
        volume.perform(.set(50))
        volume.ducking = 0.2
        #expect(abs(volume.gain - PlaybackVolume.gain(for: 50) * 0.2) < 0.0001)
        volume.perform(.set(70))                                 // changed meanwhile ("set the volume to 70")
        volume.ducking = 1
        #expect(volume.level == 70)
        #expect(abs(volume.gain - PlaybackVolume.gain(for: 70)) < 0.0001)
        volume.use(nil)
        volume.ducking = 0.2
        #expect(volume.gain == 0.2, "a volume macOS controls: only what Mac TV plays is lowered")
    }

    // MARK: Search

    @Test func searchFindsAppsAndSettings() async throws {
        try await Self.withJasmine { rig in
            let tv = rig.tv
            tv.openSystemSearch()
            for letter in "Sett" { tv.handle(.text(String(letter))) }
            let results = tv.systemSearchList(tv.systemSearch?.query ?? "")
            #expect(results.contains(.app("settings")))
            tv.handle(.move(.down))
            #expect(tv.systemSearch?.row == 1)
            tv.handle(.select)
            #expect(tv.activeSheet == .settings, "the app opened")
            tv.openSystemSearch()
            for letter in "24-Hour" { tv.handle(.text(String(letter))) }
            #expect(tv.systemSearchList("24-Hour") == [.setting(.twentyFourHour)])
            tv.handle(.back)                                     // stops typing
            tv.handle(.back)                                     // closes Search
            #expect(tv.activeSheet != .search)
        }
    }

    // MARK: Typing (TVTextField)

    /// Where a real text field has the keyboard (main.swift then gives it the keys, so an input method composes).
    @Test func realTextFieldsTakeTheKeyboard() async throws {
        try await Self.withJasmine { rig in
            let tv = rig.tv
            #expect(!tv.tvTextFieldEditing, "Home: the keys are the TV's")
            tv.openSystemSearch()
            #expect(!tv.tvTextFieldEditing, "the field highlighted, not yet typed in")
            tv.handle(.select)
            #expect(tv.tvTextFieldEditing)
            tv.handle(.text("小茗"))                              // the phone's Type on TV
            #expect(tv.systemSearch?.query == "小茗")
            tv.handle(.back)
            #expect(!tv.tvTextFieldEditing && tv.activeSheet == .search)
            tv.closeSystemSearch()
            // An API key's page: a secure field
            tv.openSettings()
            tv.settings = SettingsPanel(section: .general, open: true,
                                        path: [.init(page: .jasmine(.main), from: 0), .init(page: .jasmine(.key(.openAI)), from: 3)])
            #expect(tv.tvTextFieldEditing)
            let key = tv.settingsContent(.jasmine(.keyField), panel: try #require(tv.settings), focused: true).field
            #expect(key?.secure == true && key?.editing == true)
            key?.set?("sk-typed")
            #expect(tv.settings?.secret.text == "sk-typed")
            tv.settings?.row = 1
            #expect(!tv.tvTextFieldEditing, "on Done")
            tv.settings = nil
            // Add App: the address and name fields, not the tabs
            tv.adder = AppAdder()
            #expect(tv.tvTextFieldEditing)
            tv.adder?.row = 0
            #expect(!tv.tvTextFieldEditing)
            tv.adder = nil
            // "Who's Watching?" naming a new profile
            tv.profilePicker = ProfilePicker(index: 0)
            #expect(!tv.tvTextFieldEditing)
            tv.profilePicker?.naming = ""
            #expect(tv.tvTextFieldEditing)
            tv.profilePicker = nil
        }
    }

    /// While a field has the keyboard, the standard editing keys are its own (main.swift's routing decision).
    @Test func editingShortcutsBelongToTheField() {
        let keep = { (key: UInt16, mods: NSEvent.ModifierFlags) in TextFieldKeys.belongToField(keyCode: key, modifiers: mods, composing: false) }
        // ⌘A ⌘C ⌘V ⌘X ⌘Z ⇧⌘Z
        for key: UInt16 in [0, 8, 9, 7, 6] { #expect(keep(key, [.command]), "⌘ key \(key)") }
        #expect(keep(6, [.command, .shift]))
        // ⌥ and ⌘ with the arrows (words, line ends, start and end), ⌥⌫, plain Left / Right, letters, Space, Return
        for key: UInt16 in [123, 124, 125, 126] {
            #expect(keep(key, [.option]) && keep(key, [.command]) && keep(key, [.shift, .option]))
        }
        #expect(keep(51, [.option]) && keep(51, []))
        #expect(keep(123, []) && keep(124, []) && keep(0, []) && keep(49, []) && keep(36, []))
        // Up and Down are the TV's, unless an input method is choosing
        #expect(!keep(125, []) && !keep(126, []))
        #expect(TextFieldKeys.belongToField(keyCode: 125, modifiers: [], composing: true))
    }

    /// A click outside the field being typed in ends the typing (main.swift asks, then each screen's own state).
    @Test func aClickOutsideTheFieldEndsTyping() async throws {
        #expect(TextEditingClicks.endsTyping(typing: true, insideEditor: false))
        #expect(!TextEditingClicks.endsTyping(typing: true, insideEditor: true), "a click in the field moves its caret")
        #expect(!TextEditingClicks.endsTyping(typing: false, insideEditor: false))
        #expect(TextFieldKeys.navigateWithoutKeyboard(keyCode: 125, modifiers: []))
        #expect(TextFieldKeys.navigateWithoutKeyboard(keyCode: 36, modifiers: []))
        #expect(!TextFieldKeys.navigateWithoutKeyboard(keyCode: 0, modifiers: []), "a letter gives the field the keyboard back")
        #expect(!TextFieldKeys.navigateWithoutKeyboard(keyCode: 123, modifiers: []), "Left is the field's (it would close a page)")
        try await Self.withJasmine { rig in
            let tv = rig.tv
            tv.openSystemSearch()
            tv.handle(.select)
            #expect(tv.typingInAField)
            tv.endTextEditing()
            #expect(tv.systemSearch?.typing == false && tv.activeSheet == .search, "back on the field, not typing")
            #expect(!tv.typingInAField)
            tv.closeSystemSearch()
            tv.openMovies()
            tv.movies?.typing = true
            #expect(tv.typingInAField)
            tv.endTextEditing()
            #expect(tv.movies?.typing == false && tv.movies != nil)
        }
    }

    // MARK: API keys

    @Test func anAPIKeyIsTypedSavedAndNeverShown() async throws {
        try await Self.withJasmine(key: false) { rig in
            let tv = rig.tv
            tv.openSettings()
            tv.settings = SettingsPanel(section: .general, open: true, path: [.init(page: .jasmine(.main), from: 0)])
            tv.settings?.row = 4
            tv.handle(.select)                                   // ElevenLabs API Key
            #expect(tv.settings?.page == .jasmine(.key(.elevenLabs)))
            #expect(tv.settings?.typing == true)
            tv.handle(.text("sk_secret_value"))
            let described = String(describing: tv.settings!) + String(reflecting: tv.settings!) + String(describing: tv.sheets)
            #expect(!described.contains("sk_secret_value"), "never in a description")
            let field = tv.settingsContent(.jasmine(.keyField), panel: tv.settings!, focused: true).field
            #expect(field?.secure == true)
            tv.handle(.text("\n"))                               // Return saves
            #expect(tv.settings?.page == .jasmine(.main))
            #expect(JasmineKeychain.value(.elevenLabs) == "sk_secret_value")
            #expect(SystemKeychain.refused == 0)
            // Removing asks first, with Cancel focused
            tv.settings = SettingsPanel(section: .general, open: true,
                                        path: [.init(page: .jasmine(.main), from: 0), .init(page: .jasmine(.key(.elevenLabs)), from: 4)])
            JasmineSettings.shared.save("sk_secret_value", for: .elevenLabs)
            tv.settings?.row = 2
            tv.handle(.select)
            #expect(tv.settings?.page == .confirmRemoval(.jasmine(.keyRemove)) && tv.settings?.row == 0)
            tv.handle(.move(.down))
            tv.handle(.select)
            #expect(JasmineKeychain.value(.elevenLabs) == nil)
            #expect(tv.settings?.page == .jasmine(.main))
        }
    }
}
