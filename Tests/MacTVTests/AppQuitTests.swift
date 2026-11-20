import AppKit
import Foundation
import Testing
@testable import MacTV

/// Back, Home and Quit in every app, as on Apple TV, and ⌘Q held to quit Mac TV, as Chrome.
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct AppQuitTests {
    init() {
        _ = NSApplication.shared
        AudioCoordinator.readVolume = { VolumeLevel(level: 50, muted: false) }
    }

    /// A TV with everything in a scratch folder and its own defaults, both removed afterwards.
    private func withTV(_ body: (TVController) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacTVTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "MacTVTests.Quit.\(UUID().uuidString)"
        defer {
            TestDefaults.remove(suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let tv = TVController(library: AppLibrary(folder: folder), profiles: ProfileStore(folder: folder),
                              services: AppServices(preferences: Preferences(defaults: TestDefaults.named(suite))))
        tv.remoteCoordinator.pairingStore = PairingStore(folder: folder)
        try await body(tv)
        tv.goHome()
        tv.playbackCoordinator.dropParkedWeb()
    }

    /// A website app on a blank page: nothing goes to the network.
    private let site = Service(id: "test-site", name: "Test Site", kind: .web(URL(string: "about:blank")!), accent: "#333333", deep: "#111111")

    // MARK: Back and Home: the app goes to the background

    @Test func backAtAnAppsTopLevelGoesHomeAndLeavesItInTheBackground() async throws {
        try await withTV { tv in
            // 哔哩哔哩: Back in its rows, at the top level. (Mac TV links the stores at launch, and 得到 when it opens.)
            tv.bilibiliStore.tv = tv
            tv.dedaoStore.tv = tv
            tv.bilibiliOpen = true
            #expect(tv.appInFront?.id == BilibiliStore.appID)
            tv.handle(.back)
            #expect(!tv.bilibiliOpen && tv.mode == .launcher)
            // 得到: Back while it loads goes Home too.
            tv.dedaoOpen = true
            #expect(tv.appInFront?.id == DedaoStore.appID)
            tv.handle(.back)
            #expect(!tv.dedaoOpen)
            // Movies: Back on its library.
            tv.movies = MoviesBrowser()
            #expect(tv.appInFront?.id == "movies")
            tv.handle(.back)
            #expect(tv.movies == nil)
            #expect(tv.appInFront == nil)
            // All three went to the background (Movies too, as the spec's Back rule says), the most recent first.
            #expect(tv.backgroundApps.map(\.id).prefix(3) == ["movies", DedaoStore.appID, BilibiliStore.appID])
        }
    }

    @Test func homeKeepsAWebsiteAppAsItWasAndPausesIt() async throws {
        try await withTV { tv in
            tv.open(site)
            let page = try #require(tv.webView)
            #expect(tv.mode == .player(site) && tv.appInFront?.id == site.id)
            tv.handle(.home)
            #expect(tv.mode == .launcher && tv.webView == nil)
            #expect(tv.playbackCoordinator.parkedWebIDs == [site.id])   // paused, kept
            tv.open(site)
            #expect(tv.webView === page && tv.mode == .player(site))   // the same page, where it was
            #expect(tv.playbackCoordinator.parkedWebIDs.isEmpty)
        }
    }

    @Test func homeLeavesAudioAppsPlayingInTheBackground() async throws {
        try await withTV { tv in
            // 得到 goes to the background without closing: its player isn't stopped by Home.
            tv.dedaoOpen = true
            tv.sendAppsToBackground()
            #expect(!tv.dedaoOpen)
            // TV standby (the sleep timer, Power held, Sleep Now) pauses everything, audio too.
            tv.enterStandby(reason: "test")
            #expect(tv.standby && tv.dedaoStore.player.paused)
            tv.wakeFromStandby()
            #expect(!tv.standby)
        }
    }

    @Test func moviesStaysWhereItWasInTheBackground() async throws {
        try await withTV { tv in
            let movies = try #require(Catalog.services.first { $0.kind == .movies })
            tv.movies = MoviesBrowser()
            tv.movies?.section = .movies
            tv.movies?.row = 2
            tv.movies?.columns["grid-2"] = 3
            tv.handle(.home)
            #expect(tv.movies == nil && tv.appInFront == nil)
            tv.open(movies)
            #expect(tv.movies?.section == .movies && tv.movies?.row == 2 && tv.movies?.columns["grid-2"] == 3)   // the same place
            // Quitting Movies drops it: next time it opens fresh.
            tv.quitApp("movies", reason: "test")
            #expect(tv.movies == nil && tv.playbackCoordinator.parkedMovies == nil)
        }
    }

    @Test func aMovieInTheBackgroundIsPausedAndNothingTicks() async throws {
        let engine = StubEngine()
        let player = MoviePlayer(movie: Movie(path: "/tmp/none.mp4", title: "None", added: Date(), size: 0), engine: engine)
        player.start(at: 0)
        try await Task.sleep(for: .milliseconds(600))
        #expect(engine.reads > 0)   // the player reads the time while it's in front
        player.background()
        #expect(!player.playing && engine.pauses == 1)
        let reads = engine.reads
        try await Task.sleep(for: .milliseconds(700))
        #expect(engine.reads == reads)   // nothing ticks in the background
        player.foreground()
        try await Task.sleep(for: .milliseconds(600))
        #expect(engine.reads > reads && !player.playing)   // back, still paused
        player.stop()
    }

    // MARK: Holding Back, and the App Switcher

    @Test func holdingBackGoesHomeWithTheAppInTheBackground() async throws {
        try await withTV { tv in
            tv.dedaoOpen = true
            // The phone and the Siri Remote: Back held, as it really arrives (hold, alive, release).
            tv.handle(.press(.back, .hold), from: .remote)
            tv.handle(.press(.back, .alive), from: .remote)
            tv.handle(.press(.back, .release), from: .remote)
            #expect(!tv.dedaoOpen && tv.mode == .launcher && tv.appSwitcher == nil)
            #expect(tv.backgroundApps.first?.id == DedaoStore.appID)   // in the background, not quit
        }
    }

    @Test func homeTwiceOpensTheSwitcherOnTheAppJustLeft() async throws {
        try await withTV { tv in
            // Nothing in the background: no switcher, as on Apple TV it shows only open apps; just Home.
            tv.handle(.home)
            tv.handle(.home)
            #expect(tv.appSwitcher == nil && tv.backgroundApps.isEmpty && tv.mode == .launcher)
            // Two apps in the background, then the TV button twice from the second.
            tv.movies = MoviesBrowser()
            tv.handle(.home)
            tv.open(site)
            tv.lastTVPress = nil   // a press of its own, not the second of two
            tv.handle(.home)   // the site goes to the background
            tv.handle(.home)   // and again: the switcher
            #expect(tv.backgroundApps.map(\.id) == [site.id, "movies"])
            #expect(tv.appSwitcher?.index == 0)   // on the site, the app just left; no Home card
            // Left stops at the first app; Right at the last.
            tv.handle(.move(.left))
            #expect(tv.appSwitcher?.index == 0)
            for _ in 0..<4 { tv.handle(.move(.right)) }
            #expect(tv.appSwitcher?.index == 1)
            // The TV button again leaves it for where it was opened: the site.
            tv.handle(.home)
            #expect(tv.appSwitcher == nil && tv.mode == .player(site))
        }
    }

    @Test func selectSwitchesToTheAppAsItWas() async throws {
        try await withTV { tv in
            tv.open(site)
            let page = try #require(tv.webView)
            tv.handle(.home)
            tv.handle(.home)
            tv.handle(.select)
            #expect(tv.appSwitcher == nil && tv.mode == .player(site) && tv.webView === page)
            // Back leaves it without switching: back in the site, as it was.
            tv.lastTVPress = nil
            tv.handle(.home)
            tv.handle(.home)
            tv.handle(.back)
            #expect(tv.appSwitcher == nil && tv.mode == .player(site) && tv.webView === page)
            // Opened from Home, Back leaves it for Home.
            tv.lastTVPress = nil
            tv.handle(.home)
            tv.lastTVPress = nil
            tv.handle(.home)
            tv.handle(.home)
            #expect(tv.appSwitcher?.origin == nil && tv.appSwitcher?.index == 0)
            tv.handle(.back)
            #expect(tv.appSwitcher == nil && tv.mode == .launcher)
        }
    }

    /// Up on an app's card quits it, from every input: the keyboard's Up, a controller's D-pad, the phone's and Siri
    /// Remote's clickpad (pressed, or swiped up). The last one quit, the switcher closes on Home.
    @Test func upOnACardQuitsTheApp() async throws {
        try await withTV { tv in
            let ups: [(String, () -> Void)] = [
                ("keyboard", { tv.handle(.move(.up)) }),
                ("controller", { tv.handle(.move(.up), from: .controller) }),
                ("phone", { tv.handle(.press(.up, .tap), from: .remote) }),
                ("clickpad swipe", {
                    for phase in ["began", "changed", "changed", "ended"] {
                        tv.handle(.swipe(dx: 0, dy: -60, phase: phase, focusFollowsFinger: true), from: .remote)
                    }
                }),
            ]
            for (name, up) in ups {
                tv.open(site)
                tv.handle(.home)
                tv.handle(.home)
                #expect(tv.appSwitcher?.index == 0, "\(name)")
                up()
                #expect(tv.appSwitcher?.leaving == site.id, "\(name): the card slides up")
                try await Task.sleep(for: TVController.switcherQuitSlide + .milliseconds(150))
                #expect(tv.backgroundApps.isEmpty && tv.playbackCoordinator.parkedWebIDs.isEmpty, "\(name): quit")
                #expect(tv.appSnapshots[site.id] == nil, "\(name): its picture goes too")
                #expect(tv.appSwitcher == nil && tv.mode == .launcher, "\(name): the last one quit, Home")
                tv.lastTVPress = nil
            }
        }
    }

    @Test func quittingOneOfTwoKeepsTheSwitcherOnTheNext() async throws {
        try await withTV { tv in
            tv.movies = MoviesBrowser()
            tv.handle(.home)
            tv.open(site)
            tv.lastTVPress = nil
            tv.handle(.home)
            tv.handle(.home)
            #expect(tv.backgroundApps.map(\.id) == [site.id, "movies"])
            tv.handle(.move(.right))
            tv.handle(.move(.up))   // quits Movies, the last card
            tv.handle(.move(.up))   // a second Up while it slides does nothing more
            try await Task.sleep(for: TVController.switcherQuitSlide + .milliseconds(150))
            #expect(tv.backgroundApps.map(\.id) == [site.id])
            #expect(tv.appSwitcher?.index == 0 && tv.appSwitcher?.leaving == nil, "on the card that's left")
            tv.handle(.back)
            #expect(tv.appSwitcher == nil && tv.mode == .player(site), "back where it was opened")
        }
    }

    @Test func homeKeepsNeteasesNowPlayingScreen() async throws {
        try await withTV { tv in
            tv.neteaseStore.tv = tv
            guard tv.neteaseStore.backgroundPlay else { return }   // its default, and the owner's setting
            tv.neteaseOpen = true
            tv.neteaseStore.nowPlayingVisible = true
            tv.handle(.home)
            #expect(!tv.neteaseOpen && tv.neteaseStore.nowPlayingVisible)   // in the background, on the same screen
            #expect(tv.appInFront == nil)
            // Quitting it (not Home) is what starts it over.
            tv.neteaseOpen = true
            tv.quitApp(NeteaseStore.appID, reason: "test")
            #expect(!tv.neteaseOpen && !tv.neteaseStore.nowPlayingVisible)
        }
    }

    // MARK: ⌘Q, as Chrome

    @Test func aShortPressOfCommandQSaysToHoldAndQuitsNothing() async throws {
        try await withTV { tv in
            var quit = false
            tv.terminate = { quit = true }
            tv.quitKeyDown()
            #expect(tv.notices.toast == "Hold ⌘Q to Quit")
            tv.quitKeyUp()   // let go too soon
            try await Task.sleep(for: TVController.quitKeyHold + .milliseconds(300))
            #expect(!quit)
        }
    }

    @Test func holdingCommandQQuitsMacTV() async throws {
        try await withTV { tv in
            var quit = false
            tv.terminate = { quit = true }
            tv.quitKeyDown()
            try await Task.sleep(for: TVController.quitKeyHold - .milliseconds(500))
            #expect(!quit)   // not yet
            try await Task.sleep(for: .milliseconds(800))
            #expect(quit)
            // A second, quick press later doesn't count the first one's time.
            quit = false
            tv.quitKeyDown()
            tv.quitKeyUp()
            tv.quitKeyDown()
            try await Task.sleep(for: .milliseconds(500))
            tv.quitKeyUp()
            try await Task.sleep(for: TVController.quitKeyHold)
            #expect(!quit)
        }
    }

    @Test func onlyTheKeyHoldsSystemQuitsGoThrough() {
        // No applicationShouldTerminate: a logout, restart, shutdown, the updater's relaunch and the Quit menu
        // item quit at once. Only the ⌘Q key, caught before the menu, waits for a hold.
        #expect(!AppDelegate.instancesRespond(to: #selector(NSApplicationDelegate.applicationShouldTerminate(_:))))
    }
}

/// A movie engine that plays nothing and counts what the player asks of it.
@MainActor
private final class StubEngine: PlaybackEngine {
    let layer = CALayer()
    var duration: Double { 100 }
    var reads = 0
    var pauses = 0
    var currentTime: Double { reads += 1; return 10 }
    var isPlaying = false
    var ended = false
    var renderFailure: String?
    var audioOptions: [MediaOption] = []
    var subtitleOptions: [MediaOption] = []
    var selectedAudio: Int?
    var selectedSubtitle: Int?
    func start(at seconds: Double) { isPlaying = true }
    func play() { isPlaying = true }
    func pause() { isPlaying = false; pauses += 1 }
    func seek(to seconds: Double) {}
    func selectAudio(_ index: Int) {}
    func selectSubtitle(_ index: Int?) {}
    func subtitle(at seconds: Double) -> String? { nil }
    func stop() { isPlaying = false }
}
