import AVFoundation
import AppKit
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
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Esc 按下的时刻，和这一次按住是否已经触发过"回主屏"
    var escapeDownAt: Date?
    var escapeHeld = false
    /// 确认键按下的时刻（哔哩哔哩的列表里：按一下 = 确认，按住 = 这张卡片的菜单）
    var selectDownAt: Date?
    var selectHeld = false
    /// 长按用计时器来认（不靠系统的"按键重复"，那个可以在系统设置里关掉或调慢）
    var escapeTimer: Timer?
    var selectTimer: Timer?
    /// 网易云播放界面里的左右键：短按切歌，按住快进 / 快退
    var arrowDownAt: Date?
    var arrowHeld = false
    var arrowForward = true
    var arrowTimer: Timer?
    static let holdTime: TimeInterval = 0.5
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
                tv.settings = SettingsPanel(section: .power, open: true, row: 1)
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
            let saver = ImageRenderer(content: Screensaver().frame(width: 1920, height: 1080).environment(\.colorScheme, .dark))
            saver.scale = 1
            if let image = saver.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: folder.appendingPathComponent("screensaver.png"))
            }
            exit(0)
        }

        NSApp.mainMenu = makeMainMenu()

        // A normal window; the green button or ⌃⌘F takes it full screen.
        window = NSWindow(
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
        tv.startControllers()
        // 自用分支：启动时就把哔哩哔哩每一页的内容取好，进去和切换时不用等
        tv.bilibiliStore.tv = tv
        tv.bilibiliStore.preload()
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

    @objc private func displaysSlept() { tv.noteDisplaySleep(true) }
    @objc private func displaysWoke() { tv.noteDisplaySleep(false) }
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
        NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            // 网易云、得到播放界面的左右键松开：没按到"按住"的程度就是切歌 / 换一讲，按住过就是快进 / 快退结束、从那里接着放
            if let self, event.keyCode == 123 || event.keyCode == 124, self.arrowDownAt != nil {
                let held = self.arrowHeld
                self.arrowDownAt = nil
                self.arrowTimer?.invalidate()
                if held {
                    if self.tv.dedaoOpen { self.tv.dedaoStore.endHold() } else { self.tv.neteaseStore.endScrub() }
                } else {
                    self.tv.handle(.move(self.arrowForward ? .right : .left))
                }
                return nil
            }
            // 确认键松开：没按到"长按"的程度，才是一次"确认"
            if let self, event.keyCode == 36 || event.keyCode == 76, self.selectDownAt != nil {
                let held = self.selectHeld
                self.selectDownAt = nil
                self.selectTimer?.invalidate()
                if !held { self.tv.handle(.select) }
                return nil
            }
            // Esc 松开：没按到"长按"的程度，才是一次"返回"
            guard let self, event.keyCode == 53, self.escapeDownAt != nil else { return event }
            let held = self.escapeHeld
            self.escapeDownAt = nil
            self.escapeTimer?.invalidate()
            if !held { self.tv.handle(.back) }
            return nil
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let tv = self?.tv, event.window === self?.window else { return event }
            if tv.noteActivity() { return nil }
            // 只有 ⌘ ⌥ ⌃ ⇧ 算"按着修饰键"。大写锁定不算：它亮着的时候（很多人用它切换中英文输入），
            // 方向键、回车、Esc 照样要起作用，否则整个键盘像被锁住一样。
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function, .capsLock, .help])
            // 自用分支：Esc 的规矩，在哪都一样：
            //   按一下 = 返回（松开时才算数）；按住半秒 = 回主屏。
            // 搜索框里输入法还有待选字时，Esc 是输入法的，不拦。
            if event.keyCode == 53, mods.isEmpty {
                let composing = tv.mode == .launcher
                    && ((tv.bilibiliOpen && tv.bilibiliStore.editing) || (tv.neteaseOpen && tv.neteaseStore.typing)
                        || (tv.browserOpen && tv.browserStore.editing))
                    && ((self?.window.firstResponder as? NSTextView)?.hasMarkedText() ?? false)
                if composing { return event }
                if !event.isARepeat {
                    self?.escapeDownAt = Date()
                    self?.escapeHeld = false
                    self?.escapeTimer?.invalidate()
                    self?.escapeTimer = Timer.scheduledTimer(withTimeInterval: Self.holdTime, repeats: false) { [weak self] _ in
                        MainActor.assumeIsolated {
                            guard let self, self.escapeDownAt != nil, !self.escapeHeld else { return }
                            self.escapeHeld = true
                            self.tv.handle(.home)
                        }
                    }
                }
                return nil   // 按住时系统重发的 Esc 一律忽略
            }
            // 哔哩哔哩里的确认键：
            //   在列表里，按一下（松开时算数）= 确认；在视频卡片上按住半秒 = 这张卡片的菜单。
            //   看视频时，按一下 = 暂停 / 继续；按住半秒 = 从右边拉出面板（UP 主、点赞、投币、收藏、倍速、字幕）。
            //   按住不放时系统重发的"确认"一律不当成新的一次——菜单弹出来以后，不管还按着多久都不会自己选中第一项。
            //   不是视频卡片的地方没有菜单，按多久都还是一次普通的确认。
            if (event.keyCode == 36 || event.keyCode == 76), mods.isEmpty, tv.mode == .launcher, tv.bilibiliOpen, tv.activeSheet == nil,
               !tv.bilibiliStore.editing {
                if event.isARepeat { return nil }
                let store = tv.bilibiliStore, player = store.player
                let inList = player.current == nil && store.cardMenu == nil && !store.settingsOpen
                let watching = player.current != nil && !player.panelVisible && !player.qualityMenuVisible && !player.relatedVisible
                if inList || watching {
                    self?.selectDownAt = Date()
                    self?.selectHeld = false
                    self?.selectTimer?.invalidate()
                    self?.selectTimer = Timer.scheduledTimer(withTimeInterval: Self.holdTime, repeats: false) { [weak self] _ in
                        MainActor.assumeIsolated {
                            guard let self, self.selectDownAt != nil, !self.selectHeld else { return }
                            // 和手机遥控器上按住 OK 是同一套（TVController.openHoldMenu）
                            if self.tv.openHoldMenu() {
                                self.selectHeld = true
                                self.tv.feedback.play(.select, from: .keyboard)   // 和手机上按住 OK 一样：响一声、震一下
                            }
                        }
                    }
                    return nil
                }
                // 菜单、面板、设置已经开着：新按下的这一次立刻生效（走下面的常规处理）
            }
            // 网易云音乐、得到的播放界面：短按左右 = 上一首 / 下一首、上一讲 / 下一讲（松开时算数）；
            // 按住 = 快退 / 快进，松手从那里接着放
            if (event.keyCode == 123 || event.keyCode == 124), mods.isEmpty, tv.mode == .launcher, tv.activeSheet == nil,
               (tv.neteaseOpen && tv.neteaseStore.canHoldSeek) || (tv.dedaoOpen && tv.dedaoStore.canHoldSeek) {
                if event.isARepeat { return nil }
                let forward = event.keyCode == 124
                self?.arrowDownAt = Date()
                self?.arrowHeld = false
                self?.arrowForward = forward
                self?.arrowTimer?.invalidate()
                self?.arrowTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.arrowDownAt != nil else { return }
                        self.arrowHeld = true
                        if self.tv.dedaoOpen { self.tv.dedaoStore.beginHold(forward: forward) } else { self.tv.neteaseStore.beginHold(forward: forward) }
                    }
                }
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
            // 得到的播放界面里的确认键，和网易云一样：按一下（松开时算数）= 放 / 停；按住半秒 = "⋯"菜单
            //（倍速、定时关闭、讲目列表）。菜单、讲目列表开着时，新按下的这一次立刻生效（走下面的常规处理）
            if (event.keyCode == 36 || event.keyCode == 76), mods.isEmpty, tv.mode == .launcher, tv.dedaoOpen, tv.activeSheet == nil,
               tv.dedaoStore.canHoldSeek {
                if event.isARepeat { return nil }
                self?.selectDownAt = Date()
                self?.selectHeld = false
                self?.selectTimer?.invalidate()
                self?.selectTimer = Timer.scheduledTimer(withTimeInterval: Self.holdTime, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.selectDownAt != nil, !self.selectHeld else { return }
                        if self.tv.openHoldMenu() {
                            self.selectHeld = true
                            self.tv.feedback.play(.select, from: .keyboard)   // 和手机上按住 OK 一样：响一声、震一下
                        }
                    }
                }
                return nil
            }
            // 网易云音乐里的确认键，规矩一样：按一下（松开时算数）= 确认；
            // 在歌曲、歌单卡片上或播放界面里按住半秒 = 菜单（喜欢、收藏到歌单、播放模式）。
            if (event.keyCode == 36 || event.keyCode == 76), mods.isEmpty, tv.mode == .launcher, tv.neteaseOpen, tv.activeSheet == nil,
               !tv.neteaseStore.typing, tv.neteaseStore.account != nil {
                if event.isARepeat { return nil }
                if tv.neteaseStore.menu == nil {
                    self?.selectDownAt = Date()
                    self?.selectHeld = false
                    self?.selectTimer?.invalidate()
                    self?.selectTimer = Timer.scheduledTimer(withTimeInterval: Self.holdTime, repeats: false) { [weak self] _ in
                        MainActor.assumeIsolated {
                            guard let self, self.selectDownAt != nil, !self.selectHeld else { return }
                            // 和手机上按住 OK 是同一套：响一声、震一下
                            if self.tv.openHoldMenu() {
                                self.selectHeld = true
                                self.tv.feedback.play(.select, from: .keyboard)
                            }
                        }
                    }
                    return nil
                }
                // 菜单已经开着：新按下的这一次立刻生效
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
                if self?.window.firstResponder is NSTextView { return event }
                tv.browserStore.refocus()
                return nil
            }
            // 网易云音乐的搜索框同理
            if tv.mode == .launcher, tv.neteaseOpen, tv.neteaseStore.typing {
                if self?.window.firstResponder is NSTextView { return event }
                // 输入框还没拿到键盘（刚出现的那一瞬间）：让它再要一次，这一下按键不算，也不把输入框收掉
                tv.neteaseStore.refocus()
                return nil
            }
            // 浏览器的网页：焦点在标签栏上时，方向键、回车、空格归标签栏（"⋯"菜单开着时回车立刻生效）。
            // 焦点在网页里时，视频铺满的时候按上叫出标签栏，别的方向键照常给网页。
            // 按住回车半秒 = "⋯"菜单（和手机遥控器上按住 OK 一样）；按一下照常是回车（松开时算数，在网页里交给网页）。
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
                    case 36, 76:
                        if tv.browserStore.menu != nil {
                            if !event.isARepeat { tv.handle(.select) }
                            return nil
                        }
                    default: return event
                    }
                } else if event.keyCode == 126, tv.browserStore.videoMode {
                    tv.handle(.move(.up))
                    return nil
                }
                let composing = !inBar && ((self?.window.firstResponder as? NSTextInputClient)?.hasMarkedText() ?? false)
                if event.keyCode == 36 || event.keyCode == 76, !composing {
                    if event.isARepeat { return nil }
                    self?.selectDownAt = Date()
                    self?.selectHeld = false
                    self?.selectTimer?.invalidate()
                    self?.selectTimer = Timer.scheduledTimer(withTimeInterval: Self.holdTime, repeats: false) { [weak self] _ in
                        MainActor.assumeIsolated {
                            guard let self, self.selectDownAt != nil, !self.selectHeld else { return }
                            if self.tv.openHoldMenu() {
                                self.selectHeld = true
                                self.tv.feedback.play(.select, from: .keyboard)
                            }
                        }
                    }
                    return nil
                }
            }
            guard tv.mode == .launcher || tv.mode == .movie else { return event }
            // The add-app sheet takes typing: letters, Space, Delete and ⌘V go to its fields.
            // So does naming a new profile.
            if tv.adder != nil || tv.profilePicker?.naming != nil || tv.movies?.shareForm != nil {
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
            case 36, 76, 49: tv.handle(.select)
            case 53: tv.handle(.back)
            default: return event
            }
            return nil
        }
    }

    @objc func goHome(_ sender: Any?) { tv.handle(.home) }
    @objc func reloadPage(_ sender: Any?) { tv.webView?.reload() }
    @objc func copyReport(_ sender: Any?) { DiagnosticReport.copy(from: tv) }
    @objc func reportBug(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/kaisenyao/mac-tv/issues/new?template=bug_report.md")!)
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "Home", action: #selector(goHome(_:)), keyEquivalent: "H")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Mac TV", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Mac TV", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: app, title: "Mac TV")

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
        main.addItem(submenu: view, title: "View")

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        main.addItem(submenu: window, title: "Window")
        NSApp.windowsMenu = window

        let help = NSMenu(title: "Help")
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
