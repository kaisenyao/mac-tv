import AVFoundation
import AppKit
import Carbon.HIToolbox
import SwiftUI

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// The first external display, falling back to the main one.
    static var tvScreen: NSScreen {
        screens.first { CGDisplayIsBuiltin($0.displayID) == 0 } ?? main ?? screens[0]
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    /// ⌘H is down as the keyboard's TV button: letting go of ⌘ first lets go of it too
    var commandHDown = false
    let tv = TVController()
    var window: NSWindow!
    var server: RemoteServer?
    var tvMode: TVMode?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let flag = CommandLine.arguments.firstIndex(of: "--selftest-brave"), flag + 1 < CommandLine.arguments.count,
           let url = URL(string: CommandLine.arguments[flag + 1]) {
            BraveSessionProbe.start(url)
            return
        }
        if CommandLine.arguments.contains("--diagnostics") {
            Log.app.notice("Diagnostics report printed")
            print(DiagnosticReport.facts(tv) + "\n\n## Log (this session)\n\n" + DiagnosticReport.sessionLog())
            exit(0)
        }
        if CommandLine.arguments.contains("--selftest-drm") {
            DRMSelfTest.start()
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--export-remote"), flag + 1 < CommandLine.arguments.count {
            let sheet = flag + 2 < CommandLine.arguments.count ? CommandLine.arguments[flag + 2] : nil
            RemoteSnapshot.start(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]), sheet: sheet)
            return
        }
        // `--fullscreen-test <bundleID>` opens an app and puts its window in full screen the way a
        // launched game is, for checking without Steam games.
        if let flag = CommandLine.arguments.firstIndex(of: "--fullscreen-test"), flag + 1 < CommandLine.arguments.count,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: CommandLine.arguments[flag + 1]) {
            print("Accessibility allowed:", AXIsProcessTrusted())
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { app, _ in
                guard let pid = app?.processIdentifier else { exit(1) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    MainActor.assumeIsolated { print("Full screen:", GameWindow.makeFullScreen(pid: pid, on: NSScreen.main)) }
                    exit(0)
                }
            }
            return
        }
        // `--movie-probe <file> [frame.jpg]` prints what Mac TV makes of a video file: its title,
        // tracks and whether it plays here, and saves the frame a poster would use.
        if let flag = CommandLine.arguments.firstIndex(of: "--movie-probe"), flag + 1 < CommandLine.arguments.count {
            let url = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
            let frameFile = flag + 2 < CommandLine.arguments.count ? URL(fileURLWithPath: CommandLine.arguments[flag + 2]) : nil
            Task {
                let name = MovieName(url.deletingPathExtension().lastPathComponent)
                print("title: \(name.title)  year: \(name.year.map(String.init) ?? "-")  episode: \(name.episode ?? "-")")
                var frame: CGImage?
                if ["mkv", "webm"].contains(url.pathExtension.lowercased()) {
                    if let reader = try? MatroskaReader(url: url) {
                        print("duration: \(Double(reader.duration) / 1e9)s  cues: \(reader.cues.count)")
                        for track in reader.tracks {
                            print("track \(track.number): \(track.kind) \(track.codec) \(track.language) \(track.width)x\(track.height) \(track.sampleRate)Hz \(track.channels)ch")
                        }
                        var counts: [UInt64: Int] = [:]
                        for _ in 0..<500 { guard let block = reader.nextBlock() else { break }; counts[block.track, default: 0] += block.frames.count }
                        print("first 500 blocks, frames per track: \(counts)")
                    }
                    switch MatroskaPlayback.open(url).map(MatroskaPlayback.init) {
                    case .success(let engine): print("plays here: audio \(engine.audioOptions.map(\.title)), subtitles \(engine.subtitleOptions.map(\.title))")
                    case .failure(let problem): print("doesn't play here: \(problem)")
                    }
                    frame = MatroskaPlayback.frame(of: url, at: 0.12)
                } else {
                    switch await AVPlayback.open(url) {
                    case .success(let engine): print("plays here: \(engine.duration)s, audio \(engine.audioOptions.map(\.title))")
                    case .failure(let problem): print("doesn't play here: \(problem)")
                    }
                    frame = await AVPlayback.frame(of: url, at: 0.12)
                }
                print("frame: \(frame.map { "\($0.width)x\($0.height)" } ?? "none")")
                if let frame, let frameFile,
                   let jpeg = NSBitmapImageRep(cgImage: frame).representation(using: .jpeg, properties: [:]) {
                    try? jpeg.write(to: frameFile)
                }
                exit(0)
            }
            return
        }
        // `--steam-games` prints the Steam games Mac TV finds (MACTV_STEAM_ROOT points at other Steam files).
        if CommandLine.arguments.contains("--steam-games") {
            let games = SteamLibrary.installedGames().map { ["appID": $0.appID, "name": $0.name] }
            if let data = try? JSONSerialization.data(withJSONObject: games, options: [.prettyPrinted, .sortedKeys]) {
                print(String(decoding: data, as: UTF8.self))
            }
            exit(0)
        }
        // `--steam-tile <appID> <file.png>` renders a game's tile from Steam's artwork.
        if let flag = CommandLine.arguments.firstIndex(of: "--steam-tile"), flag + 2 < CommandLine.arguments.count {
            let appID = CommandLine.arguments[flag + 1], file = URL(fileURLWithPath: CommandLine.arguments[flag + 2])
            Task {
                let png = await SteamLibrary.tile(for: appID)
                try? png?.write(to: file)
                print(png == nil ? "No artwork for \(appID)" : "Wrote \(file.path)")
                exit(png == nil ? 1 : 0)
            }
            return
        }
        // `--seed-steam-shelf` adds a few AAA Steam tiles (artwork only; need not be installed) for Top Shelf checks.
        if CommandLine.arguments.contains("--seed-steam-shelf") {
            let tv = TVController()
            Task {
                await tv.seedSteamShelfSamples()
                let icons = AppFolder.url.appendingPathComponent("Icons", isDirectory: true)
                let names = (try? FileManager.default.contentsOfDirectory(atPath: icons.path)) ?? []
                let tiles = SteamLibrary.shelfArtSamples.compactMap { game -> String? in
                    tv.services.first(where: { $0.kind == .steam(appID: game.appID) })?.id
                }.filter { names.contains("\($0).png") }
                print("Seeded Steam shelf samples: \(tiles.count)/\(SteamLibrary.shelfArtSamples.count) tiles ready.")
                exit(tiles.count == SteamLibrary.shelfArtSamples.count ? 0 : 1)
            }
            return
        }
        // `--export-tiles <folder>` writes every dock tile as a PNG, for checking the icon layout.
        if let flag = CommandLine.arguments.firstIndex(of: "--export-tiles"), flag + 1 < CommandLine.arguments.count {
            let folder = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
            for service in AppLibrary().services() {
                guard let tile = Icons.tile(for: service), let tiff = tile.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
                try? png.write(to: folder.appendingPathComponent("\(service.id).png"))
            }
            exit(0)
        }
        // `--export-sounds <folder>` writes the interface sounds as WAV files, for listening to.
        if let flag = CommandLine.arguments.firstIndex(of: "--export-sounds"), flag + 1 < CommandLine.arguments.count {
            let folder = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
            for cue in Feedback.Cue.allCases {
                guard let buffer = Feedback.synthesize(cue, format: format),
                      let file = try? AVAudioFile(forWriting: folder.appendingPathComponent("\(cue).wav"), settings: format.settings)
                else { continue }
                try? file.write(from: buffer)
            }
            exit(0)
        }
        // `--export-home <folder>` renders the home screen in a few focus states, for design checks.
        if let flag = CommandLine.arguments.firstIndex(of: "--export-home"), flag + 1 < CommandLine.arguments.count {
            let folder = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
            let states: [(String, TVController.Focus)] = [("dock-first", .app(0)), ("dock-third", .app(2)),
                                                          ("shelf-first", .shelf(0)), ("grid", .app(6))]
            // 16:9 for a TV, 16:10 for a MacBook screen.
            for (shape, canvas) in [("tv", CGSize(width: 1920, height: 1080)), ("mac", CGSize(width: 1920, height: 1200))] {
                for (name, focus) in states {
                    let tv = TVController()
                    if case .shelf = focus { tv.setFocus(.app(0)) }
                    tv.setFocus(focus)
                    let renderer = ImageRenderer(content: ZStack { Wallpaper(); HomeView(tv: tv) }
                        .environment(\.canvasSize, canvas)
                        .frame(width: canvas.width, height: canvas.height).environment(\.colorScheme, .dark))
                    renderer.scale = 1
                    if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: folder.appendingPathComponent("\(shape)-\(name).png"))
                    }
                }
            }
            do {
                let tv = TVController()
                tv.openSettings(to: .lidOverride)
                let renderer = ImageRenderer(content: ZStack { Wallpaper(); HomeView(tv: tv); Color.black.opacity(0.55); SettingsSheet(tv: tv) }
                    .frame(width: 1920, height: 1080).environment(\.colorScheme, .dark))
                renderer.scale = 1
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: folder.appendingPathComponent("settings.png"))
                }
            }
            for (name, adder) in [("add-website", AppAdder(tab: .website, row: 1, address: "crunchyroll.co")),
                                  ("add-macapp", AppAdder(tab: .macApp, row: 2, query: "", selected: 1))] {
                let tv = TVController()
                tv.adder = adder
                let renderer = ImageRenderer(content: ZStack { Wallpaper(); HomeView(tv: tv); Color.black.opacity(0.55); AddAppSheet(tv: tv) }
                    .frame(width: 1920, height: 1080).environment(\.colorScheme, .dark))
                renderer.scale = 1
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: folder.appendingPathComponent("\(name).png"))
                }
            }
            for (name, flow) in [("setup-welcome", SetupFlow()), ("setup-apps", SetupFlow(step: .apps, index: 1)),
                                 ("setup-remote", SetupFlow(step: .remote))] {
                let tv = TVController()
                tv.setup = flow
                let renderer = ImageRenderer(content: ZStack { Wallpaper(); HomeView(tv: tv); Color.black.opacity(0.7); SetupScreen(tv: tv) }
                    .environment(\.canvasSize, CGSize(width: 1920, height: 1080))
                    .frame(width: 1920, height: 1080).environment(\.colorScheme, .dark))
                renderer.scale = 1
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: folder.appendingPathComponent("\(name).png"))
                }
            }
            let saver = ImageRenderer(content: Screensaver(idle: tv.idleCoordinator).frame(width: 1920, height: 1080).environment(\.colorScheme, .dark))
            saver.scale = 1
            if let image = saver.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: folder.appendingPathComponent("screensaver.png"))
            }
            exit(0)
        }

        NSApp.mainMenu = makeMainMenu()

        // A normal window; the green button or ⌃⌘F takes it full screen.
        window = TVWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Mac TV"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.minSize = NSSize(width: 640, height: 360)
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RootView(tv: tv))
        (window as? TVWindow)?.unhandledCancel = { [weak self] in self?.tv.pageLetBackThrough() }
        tv.window = window
        if !window.setFrameUsingName("MacTVWindow") { placeOnTV() }
        window.setFrameAutosaveName("MacTVWindow")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        tvMode = TVMode(window: window, tv: tv, preferences: tv.preferences)
        tvMode?.start()

        startRemoteServer()
        installLauncherKeys()
        tv.startPowerManagement()
        tv.startMemoryPressureWatch()
        tv.startControllers()
        // 自用分支：启动时就把哔哩哔哩每一页的内容取好，进去和切换时不用等
        tv.bilibiliStore.tv = tv
        tv.bilibiliStore.preload()
        tv.attributeBilibiliAccounts()   // 只做一次：以前登录过的哔哩哔哩账号分给登录着它的人（见 BiliAccounts）
        tv.neteaseStore.tv = tv
        tv.neteaseStore.preload()
        // 主屏顶部：哔哩哔哩关注的 UP 主最新视频、网易云的歌单、YouTube 为你推荐（在各自的设置里可以换）
        tv.appShelf.start()
        tv.ensureSteamHeroes()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displaysSlept),
            name: NSWorkspace.screensDidSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(macWoke),
            name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displaysWoke),
            name: NSWorkspace.screensDidWakeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        _ = DiagnosticReport.launched
        Log.app.notice("Mac TV \(AppVersion.current, privacy: .public) started on macOS \(ProcessInfo.processInfo.operatingSystemVersionString, privacy: .public)")

        // `--setup` shows first-run setup again.
        tv.updater.onAvailable = { [weak self] version in
            self?.tv.showToast("Mac TV \(version) Available")
        }
        tv.updater.isIdle = { [weak self] in self?.tv.idleForUpdate ?? false }
        tv.updater.start()
        tv.networkShares.start()
        // `--open-website <url>` opens a page in the website player at launch, for testing.
        if let flag = CommandLine.arguments.firstIndex(of: "--open-website"), flag + 1 < CommandLine.arguments.count,
           let url = WebsiteAddress.url(from: CommandLine.arguments[flag + 1]) {
            tv.open(Service.website(url))
            return
        }
        if tv.needsSetup || CommandLine.arguments.contains("--setup") {
            tv.startSetup()
            return
        } else if tv.profiles.all.count > 1 {
            tv.openProfiles()
        }
        if Updater.takeAutomaticRestart() {
            // Updated while nobody was watching: go back to the screen saver, not the pairing code.
            tv.showScreensaver()
        } else {
            tv.offerStartupPairing()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !CommandLine.arguments.contains("--selftest-brave")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 正在看哔哩哔哩、听得到：先把看到哪 / 听到哪记下（这台 Mac 上马上记好；告诉它们那一下不一定来得及）
        tv.bilibiliStore.player.stop()
        tv.dedaoStore.player.stop()
        tv.browserStore.closePrivateTabs()   // Mac TV quitting: private tabs don't survive it
        server?.stop()
        tv.closeExternalBrowser()
        tv.closeIINAPlayback(terminating: true)
        tv.stopPowerManagement()
    }

    /// First launch: a 16:9 window filling most of the TV display.
    private func placeOnTV() {
        let area = NSScreen.tvScreen.visibleFrame
        var size = NSSize(width: area.width * 0.8, height: area.width * 0.8 * 9 / 16)
        if size.height > area.height * 0.85 {
            size = NSSize(width: area.height * 0.85 * 16 / 9, height: area.height * 0.85)
        }
        window.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                               width: size.width, height: size.height), display: true)
    }

    @objc private func displaysSlept() { tv.macDisplaySlept() }
    @objc private func displaysWoke() { tv.macDisplayWoke() }
    /// The network can drop the remote's listener while the Mac sleeps; phones must find it again.
    @objc private func macWoke() { server?.ensureListening() }

    @objc private func screensChanged() {
        tvMode?.screensChanged()
        tv.refreshRemoteURL()
        tv.refreshPower()
    }

    private func startRemoteServer() {
        let token = RemoteServer.pairingCode()
        tv.remoteToken = token
        let server = RemoteServer(
            token: token,
            onCommand: { [weak self] in self?.tv.handle($0, from: .remote) },
            state: { [weak self] in self?.tv.remoteState() ?? [:] },
            icon: { [weak self] in self?.tv.iconPNG(for: $0) },
            routes: { [weak self] in self?.tv.handleAppsRequest($0) },
            pairing: tv.remoteCoordinator.pairingStore,
            onGuestCommand: { [weak self] in self?.tv.handleGuestCommand($0) ?? false },
            ownOrigins: { [weak self] in self?.tv.remoteCoordinator.origins ?? [] })
        server.start(ports: Array(8765...8775)) { [weak self] port in self?.tv.remotePort = port }
        self.server = server
    }

    /// Arrows, Return and Escape drive the home screen. In a player, keys go to the page.
    /// Trackpad or wheel scrolling moves between the Top Shelf, the dock and the grid.
    private func installLauncherKeys() {
        // Any pointer input counts as activity; a click that only wakes the screensaver goes no further.
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
            guard let self, event.window === window else { return event }
            let woke = tv.noteActivity()
            // 浏览器里正在改地址：点在输入框外面（网页、标签、按钮）就不改了，像按返回；这一下照常给点到的东西
            if event.type == .leftMouseDown, tv.browserStore.editing, !BrowserStore.isInTextEditor(event, in: window) {
                tv.browserStore.endEditingByClick()
            }
            if event.type == .mouseMoved && (abs(event.deltaX) > 0.5 || abs(event.deltaY) > 0.5) {
                tv.suppressHover = false
                PointerActivity.shared.set(true)
            }
            return woke && event.type == .leftMouseDown ? nil : event
        }
        // 双指滑动、鼠标滚轮：规则在 TrackpadGestures（手机遥控器触控板上的双指滑动也走那里）
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === window else { return event }
            if tv.noteActivity() { return nil }
            return tv.trackpadGestures.feed(TrackpadGestures.Sample(event), from: .trackpad) ? nil : event
        }
        // ⌘ let go while ⌘Q is held: too soon, Mac TV stays (see AppQuit). Let go while ⌘H is held: the TV button is.
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, !event.modifierFlags.contains(.command) else { return event }
            tv.quitKeyUp()
            if commandHDown { commandHDown = false; tv.inputPresses.up(.home, from: .keyboard) }
            return event
        }
        // A key that went down as a button (Esc, Return, ⌘H, the Home key, a seeking arrow): its release
        NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self else { return event }
            if event.charactersIgnoringModifiers?.lowercased() == "q" { tv.quitKeyUp() }
            if event.keyCode == 96 {   // F5 (🎤): the Siri button
                Log.app.notice("F5 up")
                if tv.inputPresses.siriUp(from: .keyboard) { return nil }
            }
            guard let key = Self.button(event) else { return event }
            if key == .home, commandHDown, event.keyCode != 115 { commandHDown = false }
            return tv.inputPresses.up(key, from: .keyboard) ? nil : event
        }
        // Mac TV no longer in front: a key held now never comes up here, so nothing stays held
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.commandHDown = false
                self.tv.quitKeyUp()
                self.tv.inputPresses.reset(.keyboard)
                self.tv.inputPresses.reset(.controller)   // macOS sends controllers to the app in front
            }
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let tv = self?.tv else { return event }
            // 只有 ⌘ ⌥ ⌃ ⇧ 算"按着修饰键"。大写锁定不算：它亮着的时候（很多人用它切换中英文输入），
            // 方向键、回车、Esc 照样要起作用，否则整个键盘像被锁住一样。
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function, .capsLock, .help])
            // ⌘Q, as Chrome: a press says "Hold ⌘Q to Quit"; held, Mac TV quits (see AppQuit). The Quit menu item,
            // a logout, restart, shutdown and the updater still quit at once: only this key holds.
            if mods == [.command], event.charactersIgnoringModifiers?.lowercased() == "q" {
                if !event.isARepeat { tv.quitKeyDown() }
                return nil
            }
            // ⌘H is the keyboard's TV button, everywhere (a web page and a text field too), before the menu sees it:
            // pressed, the Home Screen; twice, the App Switcher; held, Control Center. "Hide Mac TV" has no shortcut.
            if mods == [.command], event.charactersIgnoringModifiers?.lowercased() == "h" {
                self?.commandHDown = true
                if tv.inputPresses.down(.home, from: .keyboard) {   // a key repeat does nothing
                    // AppKit doesn't deliver H's keyUp while ⌘ is held, so the press would only end when ⌘ is let go
                    // (slow, and a hold by then). The H key itself is watched instead: the session's key state, which
                    // needs no permission; a press ends within 20 ms of letting go of H, ⌘ held or not.
                    let hDown = { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_ANSI_H)) }
                    if hDown() { tv.inputPresses.watch(.home, from: .keyboard, isDown: hDown) }
                    else { tv.inputPresses.up(.home, from: .keyboard) }   // let go already (or unreadable): a tap
                }
                return nil
            }
            guard event.window === self?.window else { return event }
            tv.noteInput()   // typing into a field counts too, so the screen saver doesn't start meanwhile
            // The screen saver: Left, Right, Esc, Return, Space and the Home key are its buttons (see
            // handleScreensaver); any other key just ends it
            if tv.screensaver, Self.button(event) == nil, event.keyCode != 49 {
                tv.screensaverOff()
                return nil
            }
            // Esc is Back, the same everywhere: pressed, Back; held, the Home Screen (see AppQuit). While an input
            // method has characters waiting in a search field, Esc is the input method's.
            if event.keyCode == 53, mods.isEmpty {
                let composing = (tv.mode == .launcher
                    && ((tv.bilibiliOpen && tv.bilibiliStore.editing) || (tv.neteaseOpen && tv.neteaseStore.typing)
                        || (tv.browserOpen && tv.browserStore.editing) || tv.movies?.typing == true)
                        || (tv.browserPageInFront && tv.browserStore.editing))
                    && ((self?.window.firstResponder as? NSTextView)?.hasMarkedText() ?? false)
                if composing { return event }
                tv.inputPresses.down(.back, from: .keyboard)
                return nil
            }
            // F5 (🎤 on a Mac keyboard, when macOS's own Dictation doesn't take it) is the Siri button: pressed, Search;
            // held, Jasmine, or dictation into the field with focus (see Jasmine)
            if event.keyCode == 96, mods.isEmpty {
                if !event.isARepeat {
                    let presses = tv.inputPresses
                    // A press still open (its keyUp never came) ends first, so the key can never wedge.
                    if presses.siriIsDown(from: .keyboard) { presses.siriUp(from: .keyboard) }
                    presses.siriDown(from: .keyboard)
                    // The keyDown and keyUp are what count. On top of them, one "it's up now" signal, only from what
                    // reads down at this moment: F5's own state when macOS tracks it; otherwise, for fn-F5 (whose
                    // keyUp AppKit may never deliver while fn is held), fn itself: letting go of fn lets go of F5.
                    // Neither readable: the keyUp ends it. Checked every 20 ms while it's down, as ⌘H.
                    let state = CGEventSourceStateID.combinedSessionState
                    let f5Down = { CGEventSource.keyState(state, key: CGKeyCode(kVK_F5)) }
                    let fnDown = { CGEventSource.flagsState(state).contains(.maskSecondaryFn) }
                    let f5 = f5Down(), fn = fnDown()
                    Log.app.notice("F5 down: F5 reads \(f5 ? "down" : "up", privacy: .public), fn \(fn ? "down" : "up", privacy: .public)")
                    if f5 { presses.watchSiri(from: .keyboard, isDown: f5Down) }
                    else if fn { presses.watchSiri(from: .keyboard, isDown: fnDown) }
                }
                return nil
            }
            // The Home key (Fn-Left Arrow on a Mac keyboard) is the TV button too, as ⌘H
            if event.keyCode == 115, mods.isEmpty {
                tv.inputPresses.down(.home, from: .keyboard)
                return nil
            }
            // In 网易云's and 得到's players Left and Right are buttons: pressed, the previous or next song or lecture;
            // held, seek, and letting go plays from there (PhonePresses, as the phone's)
            if (event.keyCode == 123 || event.keyCode == 124), mods.isEmpty, tv.mode == .launcher, tv.activeSheet == nil,
               (tv.neteaseOpen && tv.neteaseStore.canHoldSeek) || (tv.dedaoOpen && tv.dedaoStore.canHoldSeek) {
                tv.inputPresses.down(event.keyCode == 124 ? .right : .left, from: .keyboard)
                return nil
            }
            // 网易云音乐里的空格：就在当前界面放 / 停，不进播放界面（回车才进）
            if event.keyCode == 49, mods.isEmpty, tv.mode == .launcher, tv.neteaseOpen, tv.activeSheet == nil,
               !tv.neteaseStore.typing, tv.neteaseStore.account != nil {
                if !event.isARepeat { tv.neteaseStore.handle(.playPause) }
                return nil
            }
            // 得到里的空格：放 / 停
            if event.keyCode == 49, mods.isEmpty, tv.mode == .launcher, tv.dedaoOpen, tv.activeSheet == nil {
                if !event.isARepeat { tv.dedaoStore.handle(.playPause) }
                return nil
            }
            // 哔哩哔哩的搜索框正在输入时，其余按键整个交给输入框（中文输入法要用到方向键、回车）
            if tv.mode == .launcher, tv.bilibiliOpen, tv.bilibiliStore.editing {
                // 输入框确实拿着键盘时才交给它。万一它没拿到（比如应用刚切回来），
                // 就退出输入状态，按键照常起作用，而不是整个键盘都没反应。
                if self?.window.firstResponder is NSTextView { return event }
                tv.bilibiliStore.stopEditing()
            }
            // 浏览器的地址栏：和网易云的搜索框一样，还没拿到键盘（刚出现那一瞬间）就让它再要一次，这一下不算
            if tv.mode == .launcher, tv.browserOpen, tv.browserStore.editing {
                // ⌘ 的组合键（⌘W、⌘T、⌘L…）走菜单
                if self?.window.firstResponder is NSTextView || mods.contains(.command) { return event }
                tv.browserStore.refocus()
                return nil
            }
            // Movies' search field: the keys go to it while it has the keyboard (an input method needs the arrows and
            // Return). If it didn't get the keyboard, typing stops and the keys work as usual.
            if tv.mode == .launcher, tv.activeSheet == nil, tv.movies?.typing == true, tv.movies?.shareForm == nil {
                if self?.window.firstResponder is NSTextView { return event }
                tv.movies?.typing = false
            }
            // 网易云音乐的搜索框同理
            if tv.mode == .launcher, tv.neteaseOpen, tv.neteaseStore.typing {
                if self?.window.firstResponder is NSTextView { return event }
                // 输入框还没拿到键盘（刚出现的那一瞬间）：让它再要一次，这一下按键不算，也不把输入框收掉
                tv.neteaseStore.refocus()
                return nil
            }
            // 浏览器的网页上在标签栏里改地址：按键整个交给地址栏（和开始页的一样，还没拿到键盘就再要一次）
            if tv.browserPageInFront, tv.browserStore.editing {
                if self?.window.firstResponder is NSTextView || mods.contains(.command) { return event }
                tv.browserStore.refocus()
                return nil
            }
            // 浏览器的网页：焦点在标签栏上时，方向键、回车、空格归标签栏。
            // 焦点在网页里时，视频铺满的时候按上叫出标签栏，别的方向键照常给网页。
            // 按住回车半秒 = "⋯"菜单（和手机遥控器上按住 OK 一样），菜单开着时再按住是收起；
            // 按一下照常是回车（松开时算数，在网页里交给网页，菜单里是选这一项）。
            // 网页里正在用输入法打字（有待选的字）时不拦回车
            if tv.browserPageInFront, mods.isEmpty {
                let inBar = tv.browserChromeUp
                if inBar {
                    switch event.keyCode {
                    case 123: tv.handle(.move(.left)); return nil
                    case 124: tv.handle(.move(.right)); return nil
                    case 125: tv.handle(.move(.down)); return nil
                    case 126: tv.handle(.move(.up)); return nil
                    case 49: if !event.isARepeat { tv.handle(.select) }; return nil
                    case 36, 76: break   // 回车：下面按住 / 松开的那一套
                    default: return event
                    }
                } else if event.keyCode == 126, tv.browserStore.videoMode {
                    tv.handle(.move(.up))
                    return nil
                }
                let composing = !inBar && ((self?.window.firstResponder as? NSTextInputClient)?.hasMarkedText() ?? false)
                if event.keyCode == 36 || event.keyCode == 76, !composing {
                    tv.inputPresses.down(.select, from: .keyboard)
                    return nil
                }
            }
            // Over a web page or a movie, a sheet (Control Center, the App Switcher…) takes the keys
            guard tv.mode == .launcher || tv.mode == .movie || tv.activeSheet != nil else { return event }
            // The add-app sheet takes typing: letters, Space, Delete and ⌘V go to its fields.
            // So does naming a new profile.
            if tv.adder != nil || tv.profilePicker?.naming != nil || tv.settings?.typing == true || tv.movies?.shareForm != nil
                || (tv.activeSheet == .search && tv.systemSearch?.row == 0) {
                if mods == [.command], event.charactersIgnoringModifiers == "v",
                   let pasted = NSPasteboard.general.string(forType: .string) {
                    tv.handle(.text(pasted))
                    return nil
                }
                if mods.isEmpty, event.keyCode == 51 {
                    tv.handle(.deleteBackward)
                    return nil
                }
                let navigation: Set<UInt16> = [123, 124, 125, 126, 36, 76, 53]
                if !navigation.contains(event.keyCode), mods.subtracting(.shift).isEmpty,
                   let typed = event.characters, !typed.isEmpty,
                   typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                    tv.handle(.text(typed))
                    return nil
                }
            }
            guard mods.isEmpty else { return event }
            switch event.keyCode {
            case 123: tv.handle(.move(.left))
            case 124: tv.handle(.move(.right))
            case 125: tv.handle(.move(.down))
            case 126: tv.handle(.move(.up))
            // Return is the remotes' Select: pressed and let go, Select; held, the menu where there is one
            case 36, 76: tv.inputPresses.down(.select, from: .keyboard)
            case 49: if !event.isARepeat { tv.handle(.select) }   // Space: one Select, however long it's held
            default: return event
            }
            return nil
        }
    }

    /// A key that's one of the buttons InputPresses times: Esc (Back), Return (Select), ⌘H and the Home key (TV),
    /// Left and Right (in a player that seeks).
    private static func button(_ event: NSEvent) -> PhonePresses.Key? {
        switch event.keyCode {
        case 53: .back
        case 36, 76: .select
        case 115: .home
        case 123: .left
        case 124: .right
        default: event.charactersIgnoringModifiers?.lowercased() == "h" ? .home : nil
        }
    }

    @objc func goHome(_ sender: Any?) { tv.handle(.goHome) }   // the Home Screen item: the Home Screen, not a TV press
    @objc func reloadPage(_ sender: Any?) { tv.webView?.reload() }
    /// 浏览器的快捷键（Safari 的那一套）：只在浏览器开着时能用，别的时候灰掉，键照常给输入框、网页
    @objc func browserShortcut(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let shortcut = BrowserStore.Shortcut(rawValue: raw) else { return }
        tv.browserStore.perform(shortcut)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(browserShortcut(_:)) else { return true }
        guard let raw = item.representedObject as? String, let shortcut = BrowserStore.Shortcut(rawValue: raw) else { return false }
        return tv.browserStore.canPerform(shortcut)
    }

    private func browserItem(_ shortcut: BrowserStore.Shortcut, hidden key: String? = nil) -> NSMenuItem {
        let (character, modifiers) = shortcut.key
        let item = NSMenuItem(title: shortcut.title, action: #selector(browserShortcut(_:)), keyEquivalent: key ?? character)
        item.keyEquivalentModifierMask = modifiers
        item.representedObject = shortcut.rawValue
        item.isHidden = key != nil
        item.allowsKeyEquivalentWhenHidden = key != nil
        return item
    }
    @objc func copyReport(_ sender: Any?) { DiagnosticReport.copy(from: tv) }
    /// Help › Mac TV Help (⌘?): Settings › System › User Guide.
    @objc func showUserGuide(_ sender: Any?) {
        tv.openUserGuide()
        tv.bringToFront()
    }
    @objc func reportBug(_ sender: Any?) {
        SystemGuard.open(URL(string: "https://github.com/kaisenyao/mac-tv/issues/new?template=bug_report.md")!)
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        // No shortcuts: ⌘H is the TV button (the key monitor takes it, for its double press and hold)
        app.addItem(withTitle: "Home Screen", action: #selector(goHome(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Mac TV", action: #selector(NSApplication.hide(_:)), keyEquivalent: "")
        app.addItem(withTitle: "Quit Mac TV", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: app, title: "Mac TV")

        // 浏览器：和 Safari 一样的菜单、一样的键
        let file = NSMenu(title: "File")
        for shortcut in [BrowserStore.Shortcut.newTab, .newPrivateTab, .openLocation] { file.addItem(browserItem(shortcut)) }
        file.addItem(.separator())
        file.addItem(browserItem(.closeTab))
        main.addItem(submenu: file, title: "File")

        // Standard editing so ⌘V works in sign-in fields.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: edit, title: "Edit")

        let view = NSMenu(title: "View")
        let fullScreen = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.control, .command]
        view.addItem(withTitle: "Reload Page", action: #selector(reloadPage(_:)), keyEquivalent: "r")
        view.addItem(.separator())
        view.addItem(browserItem(.actualSize))
        view.addItem(browserItem(.zoomIn))
        view.addItem(browserItem(.zoomIn, hidden: "="))   // ⌘= 也是放大（不用按 ⇧）
        view.addItem(browserItem(.zoomOut))
        main.addItem(submenu: view, title: "View")

        let history = NSMenu(title: "History")
        history.addItem(browserItem(.back))
        history.addItem(browserItem(.forward))
        history.addItem(.separator())
        history.addItem(browserItem(.showAllHistory))
        main.addItem(submenu: history, title: "History")

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(browserItem(.previousTab))
        window.addItem(browserItem(.nextTab))
        main.addItem(submenu: window, title: "Window")
        NSApp.windowsMenu = window

        let help = NSMenu(title: "Help")
        help.addItem(withTitle: "Mac TV Help", action: #selector(showUserGuide(_:)), keyEquivalent: "?")
        help.addItem(.separator())
        help.addItem(withTitle: "Copy Diagnostics Report", action: #selector(copyReport(_:)), keyEquivalent: "")
        help.addItem(withTitle: "Report a Bug…", action: #selector(reportBug(_:)), keyEquivalent: "")
        main.addItem(submenu: help, title: "Help")
        NSApp.helpMenu = help

        return main
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}

// `--lid-guard <pid>`: the helper that restores lid sleep once Mac TV exits (see LidSleep).
if let flag = CommandLine.arguments.firstIndex(of: "--lid-guard"), flag + 1 < CommandLine.arguments.count,
   let parent = pid_t(CommandLine.arguments[flag + 1]) {
    LidSleep.runGuard(parent: parent)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
