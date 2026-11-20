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
        private(set) var sent: [Data] = []
        private(set) var finished = false
        private(set) var cancelled = false
        func send(_ pcm: Data) { sent.append(pcm) }
        func finish() { finished = true }
        func cancel() { cancelled = true }
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
        final class Box { var made: [FakeTranscriber] = [] }
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
            let rig = Rig(tv: tv, microphone: FakeMicrophone(), chimes: FakeChimes(), settings: settings, box: Rig.Box())
            tv.jasmine = Jasmine(tv: tv, settings: settings, microphone: rig.microphone, chimes: rig.chimes,
                                 transcriber: { _ in let t = FakeTranscriber(); rig.box.made.append(t); return t },
                                 access: { access })
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
            rig.transcribers[0].onFinal?("打开哔哩哔哩")
            #expect(rig.tv.jasmine.phase == .message && rig.tv.jasmine.heard == "打开哔哩哔哩")
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
            rig.siri(.down, .hold, .release)
            rig.transcribers[0].onFinal?("你好")
            #expect(rig.tv.jasmine.phase == .message)
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
