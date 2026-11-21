import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import MacTV

/// The interaction spec's test plan (docs/custom/interaction-spec.md, section 9): one input route with strict
/// priority, the same timing on every device, and what each button does in each state. Times are passed in; the
/// only real waits are the App Switcher's quit slide and WebKit, each with its own deadline.
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct InteractionTests {
    init() {
        _ = NSApplication.shared
        AudioCoordinator.readVolume = { VolumeLevel(level: 50, muted: false) }
    }

    /// A TV with everything in a scratch folder and its own defaults, both removed afterwards.
    static func withTV(_ body: (TVController) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacTVTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "MacTVTests.Interaction.\(UUID().uuidString)"
        defer {
            TestDefaults.remove(suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let tv = TVController(library: AppLibrary(folder: folder), profiles: ProfileStore(folder: folder),
                              services: AppServices(preferences: Preferences(defaults: TestDefaults.named(suite))))
        tv.remoteCoordinator.pairingStore = PairingStore(folder: folder)
        tv.bilibiliStore.tv = tv
        tv.neteaseStore.tv = tv
        tv.dedaoStore.tv = tv
        tv.inputPresses.now = { 0 }   // the tests say when things happen
        try await body(tv)
        tv.inputPresses.reset()
        tv.goHome()
        tv.playbackCoordinator.dropParkedWeb()
    }

    static let site = Service(id: "test-site", name: "Test Site", kind: .web(URL(string: "about:blank")!), accent: "#333333", deep: "#111111")
    static let other = Service(id: "test-other", name: "Other Site", kind: .web(URL(string: "about:blank#other")!), accent: "#333333", deep: "#111111")

    // MARK: Each device, the same buttons

    enum Device: String, CaseIterable { case siriRemote, phone, keyboard, controller }

    /// One press of `key` on `device`, as it really arrives: a tap, or held past the hold time and let go.
    static func press(_ tv: TVController, _ device: Device, _ key: PhonePresses.Key, hold: Bool = false) {
        switch device {
        case .siriRemote:
            let button: SiriRemoteButton = switch key {
            case .home: .tv
            case .back: .back
            case .select: .select
            case .power: .power
            case .up: .up
            case .down: .down
            case .left: .left
            case .right: .right
            }
            var remote = SiriRemoteRecognizer()
            var actions = remote.press(button, at: 0)
            if hold { actions += remote.advance(to: InputTiming.hold + 0.01) }
            actions += remote.release(button, at: hold ? 1 : 0.1)
            actions.forEach(tv.siriRemote)
        case .phone:
            // The page times the press itself and sends tap, or hold … release
            if hold {
                tv.handle(.press(key, .hold), from: .remote)
                tv.handle(.press(key, .release), from: .remote)
            } else {
                tv.handle(.press(key, .tap), from: .remote)
            }
        case .keyboard, .controller:
            let source: Feedback.Source = device == .keyboard ? .keyboard : .controller
            tv.inputPresses.down(key, from: source, at: 0)
            if hold { tv.inputPresses.advance(to: InputTiming.hold + 0.01) }
            tv.inputPresses.up(key, from: source)
        }
    }

    // MARK: Input × state

    enum State: String, CaseIterable { case standby, screenSaver, controlCenter, appSwitcher, appTopLevel, homeFirstApp }

    /// Puts the TV in `state`; 得到 (open without the network) is the app in front where there is one.
    static func enter(_ state: State, _ tv: TVController) {
        tv.lastTVPress = nil
        switch state {
        case .standby: tv.enterStandby(reason: "test")
        case .screenSaver: tv.showScreensaver()
        case .controlCenter:
            tv.dedaoOpen = true
            tv.holdTV()
        case .appSwitcher:
            tv.dedaoOpen = true
            tv.pressTV(from: .keyboard)
            tv.pressTV(from: .keyboard)
        case .appTopLevel: tv.dedaoOpen = true
        case .homeFirstApp: tv.setFocus(.app(0))
        }
        tv.lastTVPress = nil
    }

    struct Row {
        let state: State
        let key: PhonePresses.Key
        let hold: Bool
        let expect: @MainActor (TVController) -> Bool
    }

    /// What each button does in each state, on every device (one layer handles it, nothing passes through).
    static let table: [Row] = [
        // Standby: Power, Back, TV and Select wake, and do nothing else
        Row(state: .standby, key: .power, hold: false) { !$0.standby && $0.controlCenter == nil },
        Row(state: .standby, key: .power, hold: true) { !$0.standby },
        Row(state: .standby, key: .home, hold: false) { !$0.standby && $0.appSwitcher == nil },
        Row(state: .standby, key: .home, hold: true) { !$0.standby && $0.controlCenter == nil },
        Row(state: .standby, key: .back, hold: false) { !$0.standby && !$0.screensaver },
        Row(state: .standby, key: .select, hold: false) { !$0.standby && $0.mode == .launcher && !$0.dedaoOpen },
        // The screen saver: the press that ends it does nothing else; holding TV leaves for Control Center
        Row(state: .screenSaver, key: .select, hold: false) { !$0.screensaver && $0.mode == .launcher },
        Row(state: .screenSaver, key: .back, hold: false) { !$0.screensaver && $0.focus == .app(0) },
        Row(state: .screenSaver, key: .home, hold: false) { !$0.screensaver && $0.lastTVPress == nil },
        Row(state: .screenSaver, key: .home, hold: true) { !$0.screensaver && $0.controlCenter != nil },
        Row(state: .screenSaver, key: .power, hold: false) { !$0.screensaver && !$0.standby },
        // Control Center (over 得到): TV or Back closes it, back to 得到, unchanged
        Row(state: .controlCenter, key: .home, hold: false) { $0.controlCenter == nil && $0.dedaoOpen && $0.lastTVPress == nil },
        Row(state: .controlCenter, key: .home, hold: true) { $0.controlCenter == nil && $0.dedaoOpen },
        Row(state: .controlCenter, key: .back, hold: false) { $0.controlCenter == nil && $0.dedaoOpen },
        Row(state: .controlCenter, key: .power, hold: true) { $0.standby },
        // The App Switcher (opened in 得到): TV or Back goes back to 得到; Select switches to it
        Row(state: .appSwitcher, key: .home, hold: false) { $0.appSwitcher == nil && $0.dedaoOpen && $0.lastTVPress == nil },
        Row(state: .appSwitcher, key: .back, hold: false) { $0.appSwitcher == nil && $0.dedaoOpen },
        Row(state: .appSwitcher, key: .select, hold: false) { $0.appSwitcher == nil && $0.dedaoOpen },
        Row(state: .appSwitcher, key: .home, hold: true) { $0.appSwitcher == nil && $0.controlCenter != nil && $0.dedaoOpen },
        // An app at its top level
        Row(state: .appTopLevel, key: .home, hold: false) { !$0.dedaoOpen && $0.backgroundApps.first?.id == DedaoStore.appID && $0.lastTVPress != nil },
        Row(state: .appTopLevel, key: .home, hold: true) { $0.dedaoOpen && $0.controlCenter != nil },   // over the app, not Home
        Row(state: .appTopLevel, key: .back, hold: false) { !$0.dedaoOpen && $0.backgroundApps.first?.id == DedaoStore.appID },
        Row(state: .appTopLevel, key: .back, hold: true) { !$0.dedaoOpen && $0.lastTVPress == nil },   // Home, not a TV press
        Row(state: .appTopLevel, key: .power, hold: false) { $0.dedaoOpen && !$0.standby },             // awake: nothing
        Row(state: .appTopLevel, key: .power, hold: true) { $0.standby && $0.dedaoOpen },               // standby keeps what's in front
        // Home
        Row(state: .homeFirstApp, key: .back, hold: false) { $0.screensaver },
        Row(state: .homeFirstApp, key: .home, hold: true) { $0.controlCenter != nil },
    ]

    @Test func aProgramWithNoIdentifierIsNeverTheAppMacTVOpened() {
        #expect(!TVController.takesKeys(front: nil, launched: nil), "nothing opened, and an unnamed program in front")
        #expect(!TVController.takesKeys(front: nil, launched: "com.example.player"))
        #expect(!TVController.takesKeys(front: "com.example.other", launched: nil))
        #expect(!TVController.takesKeys(front: "com.example.other", launched: "com.example.player"))
        #expect(TVController.takesKeys(front: "com.example.player", launched: "com.example.player"))
    }

    @Test(arguments: Device.allCases)
    func everyButtonInEveryState(_ device: Device) async throws {
        for (number, row) in Self.table.enumerated() {
            try await Self.withTV { tv in
                Self.enter(row.state, tv)
                Self.press(tv, device, row.key, hold: row.hold)
                #expect(row.expect(tv), "\(device.rawValue), row \(number): \(row.key) \(row.hold ? "held" : "pressed") in \(row.state.rawValue)")
                if tv.standby { tv.wakeFromStandby() }
                tv.screensaverOff()
            }
        }
    }

    // MARK: Holds

    @Test(arguments: Device.allCases)
    func holdsActOnceAndTheirReleaseDoesNothing(_ device: Device) async throws {
        try await Self.withTV { tv in
            // TV held: Control Center, and letting go isn't a TV press (no Home, no double press)
            tv.dedaoOpen = true
            Self.press(tv, device, .home, hold: true)
            #expect(tv.controlCenter != nil && tv.dedaoOpen && tv.lastTVPress == nil)
            tv.controlCenter = nil
            // Back held: the Home Screen once, and a TV press right after is a first press, not the second
            Self.press(tv, device, .back, hold: true)
            #expect(!tv.dedaoOpen && tv.lastTVPress == nil)
            Self.press(tv, device, .home)
            #expect(tv.appSwitcher == nil && tv.lastTVPress != nil)
            // Power held: standby, and letting go doesn't wake it
            Self.press(tv, device == .keyboard || device == .controller ? .phone : device, .power, hold: true)
            #expect(tv.standby)
            tv.wakeFromStandby()
        }
    }

    // MARK: Fast repeats, key repeat

    @Test func twentyFastTVPressesNeverLeaveAnythingStuck() async throws {
        try await Self.withTV { tv in
            tv.dedaoOpen = true
            let start = Date()
            for n in 0..<21 { tv.pressTV(from: .siriRemote, at: start.addingTimeInterval(Double(n) * 0.05)) }
            // In threes: Home, the switcher, back to 得到 (a press that closes the switcher doesn't count toward the
            // next double press), so the 21st is back in 得到, with nothing left open
            #expect(tv.appSwitcher == nil && tv.dedaoOpen)
            // Two devices pressing once each, close together: two first presses, never the App Switcher
            tv.lastTVPress = nil
            tv.pressTV(from: .siriRemote, at: start)
            tv.pressTV(from: .remote, at: start.addingTimeInterval(0.1))
            #expect(tv.appSwitcher == nil)
        }
    }

    @Test func twentyBackPressesFromAnAppEndInTheScreenSaver() async throws {
        try await Self.withTV { tv in
            tv.dedaoOpen = true
            tv.setFocus(.app(3))
            for _ in 0..<20 where !tv.screensaver { Self.press(tv, .phone, .back) }
            #expect(tv.screensaver && !tv.dedaoOpen)
        }
    }

    @Test func aKeyRepeatIsOnePress() async throws {
        try await Self.withTV { tv in
            tv.dedaoOpen = true
            #expect(tv.inputPresses.down(.home, from: .keyboard, at: 0))
            #expect(!tv.inputPresses.down(.home, from: .keyboard, at: 0.03), "the repeat does nothing")
            #expect(!tv.inputPresses.down(.home, from: .keyboard, at: 0.06))
            tv.inputPresses.up(.home, from: .keyboard)
            #expect(!tv.dedaoOpen && tv.appSwitcher == nil, "one TV press")
        }
    }

    // MARK: ⌘H, with ⌘ held

    /// ⌘H as main.swift sends it: down, then the H key watched (AppKit doesn't deliver H's keyUp while ⌘ is held).
    /// `h` is the key's physical state; `time` when it went down.
    static func commandH(_ tv: TVController, at time: TimeInterval, h: @escaping () -> Bool) {
        if tv.inputPresses.down(.home, from: .keyboard, at: time) { tv.inputPresses.watch(.home, from: .keyboard, isDown: h) }
    }

    @Test func commandHActsWithinAWatchOfLettingGoOfH() async throws {
        #expect(InputPresses.watchInterval <= 0.03, "a tap acts within 30 ms of letting go of H")
        try await Self.withTV { tv in
            tv.dedaoOpen = true
            var h = true
            Self.commandH(tv, at: 0, h: { h })
            tv.inputPresses.checkWatched()
            #expect(tv.dedaoOpen, "still down: nothing yet")
            h = false   // H let go at 0.08 s, ⌘ still held
            tv.inputPresses.checkWatched()   // the next watch, ≤ 20 ms later
            #expect(!tv.dedaoOpen && tv.lastTVPress != nil, "Home, without waiting for ⌘")
        }
    }

    @Test func commandHTwiceWithCommandHeldIsTheAppSwitcher() async throws {
        try await Self.withTV { tv in
            tv.dedaoOpen = true
            var h = true
            Self.commandH(tv, at: 0, h: { h })
            h = false
            tv.inputPresses.checkWatched()
            #expect(!tv.dedaoOpen)
            // ⌘ never let go: the second ⌘H is a new press, not "already down"
            h = true
            Self.commandH(tv, at: 0.2, h: { h })
            h = false
            tv.inputPresses.checkWatched()
            #expect(tv.appSwitcher?.origin == DedaoStore.appID, "the App Switcher, on 得到")
        }
    }

    @Test func aCommandHTapWithCommandHeldAfterIsHomeNotControlCenter() async throws {
        try await Self.withTV { tv in
            tv.dedaoOpen = true
            var h = true
            Self.commandH(tv, at: 0, h: { h })
            h = false
            tv.inputPresses.checkWatched()        // H up at 0.1 s
            tv.inputPresses.advance(to: 1.1)      // ⌘ held for 1 s more
            #expect(!tv.dedaoOpen && tv.controlCenter == nil, "Home, never Control Center")
            // Held H for the hold time: Control Center, and letting go adds nothing
            tv.lastTVPress = nil
            tv.dedaoOpen = true
            h = true
            Self.commandH(tv, at: 2, h: { h })
            tv.inputPresses.advance(to: 2 + InputTiming.hold + 0.01)
            #expect(tv.controlCenter != nil && tv.dedaoOpen)
            h = false
            tv.inputPresses.checkWatched()
            #expect(tv.controlCenter != nil && tv.dedaoOpen && tv.lastTVPress == nil)
        }
    }

    // MARK: Devices going away

    @Test func aDeviceGoingAwayMidHoldDoesNothingLater() async throws {
        try await Self.withTV { tv in
            tv.dedaoOpen = true
            // A controller's B held as it disconnects (the same reset when Mac TV stops being the app in front)
            for source in [Feedback.Source.controller, .keyboard] {
                tv.inputPresses.down(.back, from: source, at: 0)
                tv.inputPresses.reset(source)
                tv.inputPresses.advance(to: 2)
                #expect(tv.dedaoOpen, "\(source): no Home later")
                #expect(tv.inputPresses.down(.back, from: source, at: 3), "\(source): the next press works first time")
                tv.inputPresses.reset(source)
            }
            // The Siri Remote: TV held as it goes away: let go, nothing fires afterwards
            var remote = SiriRemoteRecognizer()
            _ = remote.press(.tv, at: 0)
            remote.reset().forEach(tv.siriRemote)
            remote.advance(to: 2).forEach(tv.siriRemote)
            #expect(tv.dedaoOpen && tv.controlCenter == nil)
        }
    }

    // MARK: Standby

    @Test func everyWayIntoStandbyIsTheSameAndTheMacStaysAwake() async throws {
        try await Self.withTV { tv in
            let ways: [(String, () -> Void)] = [
                ("Siri Remote Power held", { Self.press(tv, .siriRemote, .power, hold: true) }),
                ("phone Power held", { Self.press(tv, .phone, .power, hold: true) }),
                ("Sleep Now", { tv.openControlCenter(); tv.activateControl(.sleepNow) }),
                ("Turn Off Display", { tv.openControlCenter(); tv.activateControl(.screenOff) }),
                ("the phone's Sleep Now", { tv.handle(RemoteCommand(json: ["a": "sleep"])!, from: .remote) }),
            ]
            SystemGuard.forgetRefused()
            for (name, way) in ways {
                tv.dedaoOpen = true
                way()
                #expect(tv.standby && tv.dedaoOpen && tv.dedaoStore.player.paused, "\(name): standby, what's in front kept")
                #expect(tv.bilibiliStore.player.inBackground, "\(name): nothing starts by itself")
                // Inputs that don't wake: swallowed
                for command in [RemoteCommand.volume(6), .playPause, .move(.left), .swipe(dx: 80, dy: 0, phase: "ended")] {
                    tv.handle(command, from: .remote)
                }
                var siri = SiriRemoteButtons()
                siri.press(.siri, at: 0).forEach(tv.siriRemote)
                #expect(tv.standby, "\(name): only Power, Back, TV and Select wake it")
                tv.handle(.select, from: .remote)
                #expect(!tv.standby && tv.dedaoOpen && tv.dedaoStore.player.paused, "\(name): awake, as it was, still paused")
            }
            // A short Power press while awake does nothing
            Self.press(tv, .siriRemote, .power)
            #expect(!tv.standby)
            #expect(SystemGuard.refused.allSatisfy { $0 == "pmset displaysleepnow" || $0 == "wake the display" },
                    "only the display: Mac TV has no way to sleep the Mac")
        }
    }

    /// macOS turning the display off on its own timer isn't TV standby: music keeps playing, a press acts as usual,
    /// and when the display comes back nothing has changed.
    @Test func macOSDimmingTheDisplayIsNotStandby() async throws {
        try await Self.withTV { tv in
            tv.neteaseStore.pretendPlaying(NeteaseSong(id: 1, name: "歌", duration: 200))
            #expect(!tv.neteaseStore.paused)
            tv.dedaoOpen = true
            tv.macDisplaySlept()
            #expect(!tv.standby && tv.displaysSleeping)
            #expect(!tv.neteaseStore.paused && tv.dedaoOpen, "music plays on, the app in front stays")
            Self.press(tv, .phone, .back)
            #expect(!tv.dedaoOpen, "the press does what it does, not only waking")
            tv.macDisplayWoke()
            #expect(!tv.standby && !tv.displaysSleeping && !tv.neteaseStore.paused, "nothing changed while it was off")
            // From TV standby, macOS waking the display (a key, the mouse) is waking from standby
            tv.enterStandby(reason: "test")
            #expect(tv.standby && tv.neteaseStore.paused)
            tv.macDisplayWoke()
            #expect(!tv.standby && !tv.displaysSleeping)
        }
    }

    // MARK: Control Center over an app

    @Test func controlCenterOpensOverTheAppAndClosesBackToIt() async throws {
        try await Self.withTV { tv in
            tv.open(Self.site)
            let page = try #require(tv.webView)
            tv.holdTV()
            #expect(tv.controlCenter != nil && tv.mode == .player(Self.site) && tv.webView === page, "over the page, not Home")
            tv.handle(.move(.right), from: .remote)
            #expect(tv.controlCenter != nil && tv.mode == .player(Self.site), "the page doesn't get the press")
            tv.handle(.home, from: .remote)
            #expect(tv.controlCenter == nil && tv.mode == .player(Self.site) && tv.webView === page)
        }
    }

    // MARK: The App Switcher

    @Test func theSwitcherOpensOnTheAppItWasPressedInAndReturnsThere() async throws {
        try await Self.withTV { tv in
            tv.open(Self.other)
            tv.goHome()
            tv.open(Self.site)
            tv.lastTVPress = nil
            tv.pressTV(from: .siriRemote)
            tv.pressTV(from: .siriRemote)
            #expect(tv.appSwitcher?.origin == Self.site.id && tv.backgroundApps.first?.id == Self.site.id && tv.appSwitcher?.index == 0)
            // Quit the app it came from, then Back: Home, since that app is gone
            tv.handle(.move(.up))
            try await Task.sleep(for: TVController.switcherQuitSlide + .milliseconds(150))
            #expect(tv.appSwitcher?.index == 0 && tv.backgroundApps.map(\.id) == [Self.other.id])
            tv.handle(.back)
            #expect(tv.appSwitcher == nil && tv.mode == .launcher)
        }
    }

    @Test func openedFromHomeQuittingEveryAppClosesItOnHome() async throws {
        try await Self.withTV { tv in
            tv.open(Self.other)
            tv.goHome()
            tv.open(Self.site)
            tv.goHome()
            tv.lastTVPress = nil
            tv.pressTV(from: .remote)   // on Home already: no app to leave
            tv.pressTV(from: .remote)
            #expect(tv.appSwitcher?.origin == nil && tv.backgroundApps.count == 2)
            for _ in 0..<2 {
                tv.handle(.move(.up))
                try await Task.sleep(for: TVController.switcherQuitSlide + .milliseconds(150))
            }
            #expect(tv.backgroundApps.isEmpty && tv.appSwitcher == nil && tv.mode == .launcher, "closed on Home")
            #expect(tv.webView == nil && tv.playbackCoordinator.parkedWebIDs.isEmpty)
        }
    }

    /// Brave can't be paused, so nothing plays unseen: Home closes it, keeping its address and its card; opening the
    /// app again opens that address in Brave; quitting the app forgets it. (In a test Brave never really opens:
    /// SystemGuard refuses it, which is all this needs.)
    @Test func braveClosesOnHomeAndReopensWhereItWas() async throws {
        try await Self.withTV { tv in
            let brave = Service(id: "test-brave", name: "Brave Site", kind: .web(URL(string: "https://example.com/")!))
            let watching = URL(string: "https://example.com/watch?v=1")!
            tv.playbackCoordinator.playInBrave(brave, url: watching)
            #expect(tv.externalBrowser != nil && tv.appInFront?.id == brave.id)
            tv.pressTV(from: .remote)
            #expect(tv.externalBrowser == nil, "closed, not left playing behind Mac TV")
            #expect(tv.playbackCoordinator.closedBrave?.url == watching && tv.backgroundApps.first?.id == brave.id)
            tv.open(brave)
            #expect(tv.externalBrowserService?.id == brave.id && tv.playbackCoordinator.closedBrave == nil, "the same address again")
            // TV standby closes it the same way
            tv.enterStandby(reason: "test")
            #expect(tv.externalBrowser == nil && tv.playbackCoordinator.closedBrave?.service.id == brave.id)
            tv.wakeFromStandby()
            // Quitting it from the App Switcher forgets where it was
            tv.quitApp(brave.id, reason: "test")
            #expect(tv.playbackCoordinator.closedBrave == nil && tv.backgroundApps.isEmpty)
        }
    }

    @Test func pressesDuringTheQuitSlideLandOnOneState() async throws {
        try await Self.withTV { tv in
            tv.open(Self.site)
            tv.pressTV(from: .remote)
            tv.pressTV(from: .remote)
            tv.handle(.move(.up))
            tv.handle(.move(.up))     // a second Up on the card already leaving: nothing more
            tv.handle(.select)        // Select on the card while it slides: nothing, it's quitting
            try await Task.sleep(for: TVController.switcherQuitSlide + .milliseconds(150))
            #expect(tv.appSwitcher == nil && tv.backgroundApps.isEmpty && tv.playbackCoordinator.parkedWebIDs.isEmpty)
            #expect(tv.mode == .launcher && tv.webView == nil, "quit once, nothing reopened")
        }
    }

    @Test func aLateSnapshotForAnAppQuitMeanwhileIsDropped() async throws {
        try await Self.withTV { tv in
            tv.open(Self.site)
            tv.pressTV(from: .remote)                     // Home: its picture is being taken
            tv.quitApp(Self.site.id, reason: "test")      // quit before the picture comes back
            for _ in 0..<40 { try await Task.sleep(for: .milliseconds(25)) }
            #expect(tv.appSnapshots[Self.site.id] == nil)
        }
    }

    // MARK: Memory pressure

    @Test func memoryPressureReleasesBackgroundPagesAndKeepsTheirCards() async throws {
        try await Self.withTV { tv in
            tv.open(Self.other)
            weak let otherPage = tv.webView
            tv.goHome()
            tv.open(Self.site)
            tv.goHome()
            tv.open(Self.site)   // in front again: never released
            #expect(tv.playbackCoordinator.parkedWebIDs == [Self.other.id])
            tv.goHome()
            #expect(tv.playbackCoordinator.parkedWebIDs == [Self.site.id, Self.other.id])
            // Warning: the least recently used one goes; its card stays
            tv.memoryPressure(critical: false)
            #expect(tv.playbackCoordinator.parkedWebIDs == [Self.site.id])
            #expect(tv.playbackCoordinator.reclaimedWebIDs == [Self.other.id])
            #expect(tv.backgroundApps.map(\.id).contains(Self.other.id), "its card stays")
            for _ in 0..<20 where otherPage != nil { try await Task.sleep(for: .milliseconds(25)) }
            #expect(otherPage == nil, "the page itself is gone")
            // Critical: every one in the background
            tv.memoryPressure(critical: true)
            #expect(tv.playbackCoordinator.parkedWebIDs.isEmpty)
            #expect(tv.playbackCoordinator.reclaimedWebIDs == [Self.site.id, Self.other.id])
            // Opening a released one opens it again, in the profile's own data store
            tv.open(Self.other)
            let page = try #require(tv.webView)
            #expect(page.configuration.websiteDataStore === tv.profile.websiteDataStore)
            #expect(!tv.playbackCoordinator.reclaimedWebIDs.contains(Self.other.id))
        }
    }

    // MARK: The screen saver's own buttons

    @Test func aerialsAndPhotosStepAndShowInfoOtherTypesOnlyLeave() async throws {
        try await Self.withTV { tv in
            let before = ScreenSaverSettings.wallpaper
            defer { ScreenSaverSettings.wallpaper = before }
            let pictures = (1...3).map { URL(fileURLWithPath: "/tmp/photo\($0).jpg") }
            for wallpaper in ScreenSaverSettings.Wallpaper.allCases {
                ScreenSaverSettings.wallpaper = wallpaper
                tv.showScreensaver()
                ScreenSaverSettings.playing = [.photos, .aerials].contains(wallpaper) ? pictures : []
                let browsable = !ScreenSaverSettings.playing.isEmpty
                tv.handle(.move(.right), from: .siriRemote)
                #expect(tv.screensaver == browsable, "\(wallpaper): Right")
                guard browsable else { continue }
                #expect(tv.idleCoordinator.picture == 1)
                tv.handle(.swipe(dx: 0, dy: 0, phase: "began"), from: .siriRemote)
                tv.handle(.swipe(dx: -120, dy: 10, phase: "changed"), from: .siriRemote)
                tv.handle(.swipe(dx: 0, dy: 0, phase: "ended"), from: .siriRemote)
                #expect(tv.idleCoordinator.picture == 0, "\(wallpaper): a swipe left")
                tv.handle(.move(.left), from: .keyboard)
                #expect(tv.idleCoordinator.picture == 2, "\(wallpaper): wraps around")
                tv.handle(.touchTap, from: .siriRemote)
                #expect(tv.screensaver && tv.idleCoordinator.info, "\(wallpaper): a tap shows its information")
                tv.handle(.volume(6), from: .siriRemote)
                #expect(tv.screensaver, "volume works without leaving")
                tv.handle(.select, from: .siriRemote)
                #expect(!tv.screensaver && tv.mode == .launcher, "\(wallpaper): Select leaves, and does nothing else")
            }
        }
    }

    @Test func aLightTapOnTheClickpadIsATapAndARestingThumbIsNot() {
        var touch = SiriRemoteTouch()
        _ = touch.frame(.init(x: 0.5, y: 0.5), at: 0)
        _ = touch.frame(.init(x: 0.51, y: 0.5), at: 0.08)
        #expect(touch.frame(nil, at: 0.12) == [.tap])
        _ = touch.frame(.init(x: 0.5, y: 0.5), at: 1)
        _ = touch.frame(.init(x: 0.5, y: 0.5), at: 1.5)
        #expect(touch.frame(nil, at: 1.6) == [], "a thumb resting, then lifted")
    }

    // MARK: 100 switches

    /// 100 × (open an app → the TV button → twice: the App Switcher → Up to quit it), across 哔哩哔哩, 网易云音乐,
    /// 得到, two website apps and Movies (opened without the network): afterwards nothing is left over, no page is
    /// still alive, and memory stays within a bound.
    @Test func aHundredSwitchesLeaveNothingBehind() async throws {
        try await Self.withTV { tv in
            weak var lastPage: WKWebView?
            let apps: [(String, () -> Void)] = [
                (BilibiliStore.appID, { tv.bilibiliOpen = true }),
                (NeteaseStore.appID, { tv.neteaseOpen = true }),
                (DedaoStore.appID, { tv.dedaoOpen = true }),
                (Self.site.id, { tv.open(Self.site); lastPage = tv.webView }),
                (Self.other.id, { tv.open(Self.other); lastPage = tv.webView }),
                ("movies", { tv.movies = MoviesBrowser() }),
            ]
            var footprints: [UInt64] = []
            for cycle in 0..<100 {
                let (id, open) = apps[cycle % apps.count]
                open()
                tv.lastTVPress = nil
                tv.pressTV(from: .siriRemote)
                tv.pressTV(from: .siriRemote)
                #expect(tv.appSwitcher?.index == 0 && tv.backgroundApps.first?.id == id, "cycle \(cycle)")
                tv.handle(.move(.up), from: .siriRemote)
                for _ in 0..<40 where !tv.backgroundApps.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
                #expect(tv.backgroundApps.isEmpty && tv.appSwitcher == nil, "cycle \(cycle): quit")
                if cycle >= 50 { footprints.append(Self.footprint()) }
            }
            #expect(tv.appSnapshots.isEmpty && tv.playbackCoordinator.parkedWebIDs.isEmpty)
            #expect(tv.playbackCoordinator.reclaimedWebIDs.isEmpty)
            #expect(!tv.bilibiliStore.player.liveTasksRunning && !tv.dedaoStore.holdSeeking && !tv.neteaseStore.holdSeeking)
            for _ in 0..<40 where lastPage != nil { try await Task.sleep(for: .milliseconds(25)) }
            #expect(lastPage == nil, "the quit page isn't kept alive")
            let growth = Int64(footprints.last ?? 0) - Int64(footprints.first ?? 0)
            #expect(growth < 48 * 1024 * 1024, "memory over the last 50 switches grew \(growth / 1024 / 1024) MB")
        }
    }

    /// Mac TV's memory footprint, as Activity Monitor's Memory column counts it.
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}

/// Tests never act on the real Mac: TestSandbox turns SystemGuard on before any test runs, so turning the display
/// off, sleeping the Mac, the output's volume and device, DDC, posted keys and System Settings are refused and
/// recorded. (A test once turned the owner's display off: a check on the test bundle alone missed the test helper.)
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct SystemGuardTests {
    /// Checked on its own, touching nothing: the guard is on before anything else in a test run can act.
    @Test func theGuardIsOn() {
        #expect(SystemGuard.fake)
        #expect(ProcessInfo.processInfo.environment["MACTV_SYSTEM"] == "fake")
    }

    @Test func aTestRunNeverActsOnTheMac() async throws {
        try #require(SystemGuard.fake)   // never reach the real calls below without it
        SystemGuard.forgetRefused()
        SystemControl.displayOff()
        #expect(!SystemControl.displayOn())
        SystemGuard.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
        #expect(SystemGuard.refused == ["pmset displaysleepnow", "wake the display",
                                        "open x-apple.systempreferences:com.apple.BluetoothSettings"])
        // The standby path asks for the display off, and is refused
        try await InteractionTests.withTV { tv in
            SystemGuard.forgetRefused()
            tv.enterStandby(reason: "test")
            #expect(tv.standby && SystemGuard.refused == ["pmset displaysleepnow"])
            tv.wakeFromStandby()
        }
    }
}

/// The App Switcher at 1920×1080, opened from an app (its card first and focused) and from Home, and mid-quit.
/// Written to work/native-qa/switcher/ and, when set, MACTV_RENDER_DIR.
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct AppSwitcherRenderTests {
    @Test func theAppSwitcherRenders() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let output = root.appendingPathComponent("work/native-qa/switcher")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let extra = ProcessInfo.processInfo.environment["MACTV_RENDER_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let extra { try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true) }
        try await InteractionTests.withTV { tv in
            // Three open apps, each with a picture as it looked (flat colours stand in for real screens)
            let apps = [InteractionTests.site, InteractionTests.other,
                        Service(id: "test-third", name: "Third Site", kind: .web(URL(string: "about:blank#3")!), accent: "#7A2E8E", deep: "#2A0F33")]
            for (app, hex) in zip(apps, ["#1E6FD9", "#D9481E", "#2EA44F"]) {
                tv.backgroundApps.append(app)
                let image = NSImage(size: NSSize(width: 640, height: 360), flipped: false) { rect in
                    NSColor(Color(hex: hex)).setFill(); rect.fill()
                    NSColor.white.withAlphaComponent(0.85).setFill()
                    NSBezierPath(roundedRect: NSRect(x: 40, y: 250, width: 300, height: 40), xRadius: 8, yRadius: 8).fill()
                    return true
                }
                tv.appSnapshots[app.id] = image
            }
            @MainActor func render(_ name: String) async throws {
                let view = ZStack { Wallpaper(); SheetBackdrop(); TVCanvas { AppSwitcherView(tv: tv) } }
                let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark).frame(width: 1920, height: 1080))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1920, height: 1080), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
                window.orderFront(nil)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(500))
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let png = try #require(rep.representation(using: .png, properties: [:]))
                try png.write(to: output.appendingPathComponent("\(name).png"))
                if let extra { try png.write(to: extra.appendingPathComponent("\(name).png")) }
                window.close()
            }
            tv.openAppSwitcher(returningTo: InteractionTests.site.id)
            try await render("1-from-an-app")
            tv.appSwitcher = nil
            tv.openAppSwitcher(returningTo: nil)
            tv.appSwitcher?.index = 1
            try await render("2-from-home-moved-right")
            tv.appSwitcher?.leaving = InteractionTests.other.id
            try await render("3-quitting")
            tv.appSwitcher = nil
            tv.backgroundApps = []
            tv.appSnapshots = [:]
        }
    }
}
