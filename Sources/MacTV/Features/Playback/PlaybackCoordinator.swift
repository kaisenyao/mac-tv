import AppKit
import SwiftUI
import WebKit

/// Manages web player, native movie player, IINA sessions, and external browser playback.
@MainActor
final class PlaybackCoordinator: NSObject, ObservableObject {
    weak var tv: TVController?

    // Web Playback
    @Published private(set) var webView: WKWebView?
    private var popups: [NSWindow] = []

    // Native Movie Playback
    @Published private(set) var moviePlayer: MoviePlayer?
    @Published private(set) var currentLocalMovie: Movie?
    @Published private(set) var localMoviePlayer = "native"

    // IINA Playback
    @Published private var iinaSession: IINAPlaybackSession?
    @Published private(set) var iinaPlaybackError: String?
    @Published private(set) var iinaPlaybackStatus = ""

    // External Browser (Brave)
    @Published private(set) var externalBrowser: BraveSession?
    @Published private(set) var externalBrowserService: Service?
    @Published private(set) var externalBrowserError: String?
    @Published private(set) var externalBrowserOpening = false

    private var playbackRequest = UUID()

    private let jellyfin: JellyfinServers

    init(tv: TVController? = nil, jellyfin: JellyfinServers = .shared) {
        self.tv = tv
        self.jellyfin = jellyfin
        super.init()
    }

    /// Something is playing in front. What Home sent to the background (paused, see AppQuit) doesn't count, so the
    /// screen saver and updates go on as they do at Home.
    var isAnyPlaybackActive: Bool {
        (iinaSession != nil && !externalInBackground) || externalBrowser != nil
            || (moviePlayer != nil && !movieInBackground) || webView != nil
    }

    /// An IINA session is open and in front, running or not: remote commands go to it.
    var iinaOpen: Bool {
        iinaSession != nil && !externalInBackground
    }

    // MARK: - In the background (Home, see AppQuit)

    /// IINA, sent to the background by Home: still open behind Mac TV, paused, until Movies is opened again. Presses
    /// stay with Mac TV meanwhile.
    @Published private(set) var externalInBackground = false
    /// A website app that was playing in Brave when it went to the background (or the TV to standby): Brave can't be
    /// paused without running script in its page, so its window closed, and nothing plays unseen. Opening the app
    /// again opens this address in Brave.
    private(set) var closedBrave: (service: Service, url: URL)?
    /// The address Brave was last sent to (what's kept when it closes, if Brave can't say where its tab is)
    private var braveURL: URL?
    /// Movies, sent to the background by Home: its screen and its player, paused where they were.
    @Published private(set) var movieInBackground = false
    private(set) var parkedMovies: MoviesBrowser?

    /// TV standby: the page in front, a movie and IINA pause where they are (pages in the background are paused
    /// already). Brave in front goes to the background, which closes it, keeping its address.
    func pauseAll() {
        webView?.pauseAllMediaPlayback(completionHandler: nil)
        moviePlayer?.background()   // paused and saved, and its clock stops
        iinaSession?.pause()
        if externalBrowser != nil { tv?.goHome() }
    }

    /// Out of TV standby: a movie in front shows its controls again, still paused.
    func returnFromStandby() {
        if tv?.mode == .movie { moviePlayer?.foreground() }
    }

    /// Home: Movies (its library or its player) and IINA go to the background, paused. Brave closes, keeping where
    /// it was (see closedBrave).
    func sendToBackground(movies: MoviesBrowser?) {
        if iinaSession != nil {
            iinaSession?.pause()
            externalInBackground = true
        }
        if let browser = externalBrowser, let service = externalBrowserService {
            let url = browser.currentURL() ?? braveURL
            closeExternalBrowser()
            if let url { closedBrave = (service, url) }
        }
        if let player = moviePlayer, tv?.mode == .movie {
            player.background()
            movieInBackground = true
            tv?.displayCoordinator.releasePlaybackKeepAwake()
        }
        if let movies { parkedMovies = movies }
    }

    /// Opening Movies again: back to its screen and player as they were. False when it isn't in the background.
    func resumeMovies() -> Bool {
        if iinaSession != nil, externalInBackground {
            externalInBackground = false
            tv?.movies = parkedMovies
            parkedMovies = nil
            activateIINA()
            return true
        }
        guard parkedMovies != nil || movieInBackground else { return false }
        tv?.movies = parkedMovies ?? MoviesBrowser()
        parkedMovies = nil
        if movieInBackground, let player = moviePlayer {
            movieInBackground = false
            player.foreground()
            tv?.setMode(.movie)
            tv?.displayCoordinator.holdPlaybackKeepAwake(reason: "Watching a movie in Mac TV")
        }
        return true
    }

    /// Opening the website app that was playing in Brave: Brave opens again at the same address. False when it wasn't.
    func resumeExternalBrowser(_ service: Service) -> Bool {
        guard let closed = closedBrave, closed.service.id == service.id else { return false }
        closedBrave = nil
        playInBrave(service, url: closed.url)
        return true
    }

    /// Movies quits: its screen and player in the background go.
    func quitMovies() {
        parkedMovies = nil
        movieInBackground = false
        closeIINAPlayback()
        clearCurrentLocalMovie()
        stopMoviePlayer()
    }

    func resetPlaybackRequest() {
        playbackRequest = UUID()
    }

    func clearCurrentLocalMovie() {
        currentLocalMovie = nil
    }

    func stopMoviePlayer() {
        if let player = moviePlayer {
            player.stop()
            moviePlayer = nil
        }
        movieInBackground = false
    }

    // MARK: - Web Playback

    /// restoring、zoom、dataStore 只有浏览器的标签页用：换回一个标签页时按记下的样子恢复（前进后退、滚到哪），
    /// 按网站记下的缩放；无痕标签页用自己那份不落盘的网站数据（见 BrowserStore）
    func playWeb(_ service: Service, url: URL, restoring state: Any? = nil, zoom: Double? = nil,
                 dataStore: WKWebsiteDataStore? = nil) {
        if tv?.browserPreferences.choice(for: tv?.profile.id ?? "").rawValue == BrowserChoice.brave.rawValue {
            playInBrave(service, url: url)
            return
        }
        playbackRequest = UUID()
        currentLocalMovie = nil
        tv?.playerFailure = nil
        let web = makeWebView(for: service, dataStore: dataStore)
        if let zoom { web.pageZoom = zoom }
        if let state { web.interactionState = state } else { web.load(URLRequest(url: url)) }
        webView = web
        tv?.setMode(.player(service))
        tv?.clearPointer()
        tv?.displayCoordinator.holdPlaybackKeepAwake(reason: "Watching \(service.name) in Mac TV")
        tv?.bringToFront()
        // A website app is a video app, and its page starts playing as it opens (Web's pages and sign-in pages aren't)
        if ![BrowserStore.pageID, BilibiliStore.loginID, NeteaseStore.loginID].contains(service.id) { tv?.startedPlaying(service.id) }
        Task { @MainActor [weak self] in self?.tv?.window?.makeFirstResponder(web) }
    }

    func closeWebPlayback() {
        if let web = webView {
            web.pauseAllMediaPlayback(completionHandler: nil)
            web.stopLoading()
        }
        webView = nil
        closePopups()
        tv?.displayCoordinator.releasePlaybackKeepAwake()
    }

    /// The website apps (and YouTube) Home sent to the background: each page paused and kept as it was, so opening
    /// the app again comes back to the same place, as on Apple TV. As many as there are; only memory pressure
    /// releases one (see reclaimWeb). Web keeps its own tabs, and the apps' sign-in pages aren't kept.
    private var parkedWeb: [String: (service: Service, web: WKWebView, profile: String)] = [:]
    /// The website apps memory pressure released: where each was, to open it there again (its address, and what
    /// WebKit can bring back of its history and scroll position). Their switcher cards and pictures stay.
    private var reclaimedWeb: [String: (url: URL, state: Any?, profile: String)] = [:]

    /// Home over a page: pause it and keep it, or close it when it's one that isn't kept.
    func parkWebPlayback() {
        guard let web = webView, case .player(let service)? = tv?.mode, let profile = tv?.profile.id,
              ![BrowserStore.pageID, BilibiliStore.loginID, NeteaseStore.loginID].contains(service.id) else {
            closeWebPlayback()
            return
        }
        // Paused, and suspended so the page can't start its own media again while it waits (it's out of the window,
        // so WebKit already treats it as hidden: no drawing, timers throttled).
        web.pauseAllMediaPlayback(completionHandler: nil)
        web.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        parkedWeb[service.id] = (service, web, profile)
        reclaimedWeb[service.id] = nil
        webView = nil
        closePopups()
        tv?.displayCoordinator.releasePlaybackKeepAwake()
    }

    /// Opening a website app that's in the background: its page as it was, or, if memory pressure released it,
    /// opened again at the same address. False when there's none for it (or it was someone else's, before a
    /// profile switch).
    func resumeParkedWeb(_ service: Service) -> Bool {
        guard let profile = tv?.profile.id else { return false }
        if let reclaimed = reclaimedWeb.removeValue(forKey: service.id) {
            guard reclaimed.profile == profile else { return false }
            playWeb(service, url: reclaimed.url, restoring: reclaimed.state)
            return true
        }
        guard let parked = parkedWeb[service.id] else { return false }
        parkedWeb[service.id] = nil
        guard parked.profile == profile else {
            parked.web.stopLoading()
            return false
        }
        parked.web.setAllMediaPlaybackSuspended(false, completionHandler: nil)   // still paused: play goes on from there
        playbackRequest = UUID()
        currentLocalMovie = nil
        tv?.playerFailure = nil
        webView = parked.web
        tv?.setMode(.player(service))
        tv?.clearPointer()
        tv?.displayCoordinator.holdPlaybackKeepAwake(reason: "Watching \(service.name) in Mac TV")
        tv?.bringToFront()
        Task { @MainActor [weak self] in self?.tv?.window?.makeFirstResponder(parked.web) }
        return true
    }

    /// A website app in the background quits (all of them with no id): its page goes, and where it was (in Brave too).
    func dropParkedWeb(_ id: String? = nil) {
        if let closed = closedBrave, id == nil || closed.service.id == id { closedBrave = nil }
        for key in Array(parkedWeb.keys) where id == nil || key == id { parkedWeb.removeValue(forKey: key)?.web.stopLoading() }
        for key in Array(reclaimedWeb.keys) where id == nil || key == id { reclaimedWeb[key] = nil }
    }

    /// Memory pressure: this website app's page is released, keeping where it was (see reclaimedWeb). Its sign-ins,
    /// cookies and stored data are untouched: they live in the profile's own website data store.
    func reclaimWeb(_ id: String) {
        guard let parked = parkedWeb.removeValue(forKey: id) else { return }
        if let url = parked.web.url { reclaimedWeb[id] = (url, parked.web.interactionState, parked.profile) }
        parked.web.stopLoading()
        Log.playback.notice("Released \(id, privacy: .public)'s page: memory pressure")
    }

    /// The website apps whose pages are kept in the background now.
    var parkedWebIDs: Set<String> { Set(parkedWeb.keys) }
    /// The website apps memory pressure released, to open again where they were.
    var reclaimedWebIDs: Set<String> { Set(reclaimedWeb.keys) }

    private func closePopups() {
        for popup in popups { popup.close() }
        popups.removeAll()
    }

    func makeWebView(for service: Service, dataStore: WKWebsiteDataStore? = nil) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Each profile's own store keeps its sign-ins between launches.
        if let dataStore {
            config.websiteDataStore = dataStore   // 浏览器的无痕标签页
        } else if let profile = tv?.profile {
            config.websiteDataStore = profile.websiteDataStore
        }
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        // A page's Fullscreen API never reaches the window: Mac TV's full screen is TV mode's (see TVWindow). Videos
        // fill the page as they are; YouTube's TV page plays inside its own page.
        config.preferences.isElementFullscreenEnabled = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.userContentController.addUserScript(
            WKUserScript(source: WebPlayback.script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController.addUserScript(
            WKUserScript(source: StillMouse.script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController.addUserScript(
            WKUserScript(source: AutoPlay.script(skip: tv?.autoSkip ?? true, next: tv?.autoNext ?? true),
                         injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        if service.id == "youtube" {
            config.userContentController.addUserScript(
                WKUserScript(source: YouTubeTV.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        if service.id == BilibiliStore.loginID {
            config.userContentController.addUserScript(
                WKUserScript(source: BilibiliLoginPage.chinese, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        if service.dpadNavigation {
            config.userContentController.addUserScript(
                WKUserScript(source: SpatialNav.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        // 浏览器：视频铺满了没有、在页面最上面按上（去标签栏）、网页画出来了，告诉 BrowserStore
        if service.id == BrowserStore.pageID, let store = tv?.browserStore { BrowserPageScript.install(in: config, store: store) }
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = service.userAgent
        web.uiDelegate = self
        web.navigationDelegate = self
        web.underPageBackgroundColor = .black
        web.isInspectable = true
        PlaybackVolume.shared.install(in: web)   // 系统、显示器都调不了音量时，音量键调网页里的声音
        return web
    }

    func runWebPlayback(_ action: String, in web: WKWebView, fallback: Key) {
        Task { @MainActor [weak self, weak web] in
            guard let web else { return }
            do {
                let value = try await web.callAsyncJavaScript("return await window.__macTVPlayback(action)",
                    arguments: ["action": action], contentWorld: .page)
                guard self?.webView === web else { return }
                if value as? String == "none" { self?.sendKey(fallback, to: web) }
                else if value as? String == "unsupported" { self?.tv?.showToast("This website doesn't support this control.") }
            } catch {
                if self?.webView === web { self?.sendKey(fallback, to: web) }
            }
        }
    }

    func sendKey(_ key: Key, to web: WKWebView) {
        guard let window = tv?.window else { return }
        if window.firstResponder !== web { window.makeFirstResponder(web) }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: key.flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: key.chars, charactersIgnoringModifiers: key.chars,
                isARepeat: false, keyCode: key.code)
            else { continue }
            window.sendEvent(event)
        }
    }

    func scrollPage(_ web: WKWebView, by dy: Double) {
        let point = tv?.pointer ?? CGPoint(x: web.bounds.midX, y: web.bounds.midY)
        let x = Int(point.x), y = Int(web.bounds.height - point.y), amount = Int(dy)
        web.evaluateJavaScript("""
            ((x, y, dy) => {
              for (let el = document.elementFromPoint(x, y); el && el !== document.body; el = el.parentElement) {
                const style = getComputedStyle(el);
                if (/(auto|scroll)/.test(style.overflowY) && el.scrollHeight > el.clientHeight) { el.scrollBy(0, dy); return; }
              }
              window.scrollBy(0, dy);
            })(\(x), \(y), \(amount))
        """)
    }

    func handleInPlayer(_ command: RemoteCommand, service: Service) {
        if tv?.playerFailure != nil { tv?.handlePlayerFailure(command); return }
        guard let web = webView else { return }
        switch command {
        case .move(let direction): sendKey(.direction(direction), to: web)
        case .select: sendKey(.enter, to: web)
        case .back:
            if !service.dpadNavigation {
                sendKey(.escape, to: web)
            } else if web.canGoBack {
                web.goBack()
            } else if service.id == BrowserStore.pageID {
                tv?.returnToBrowser()   // 浏览器里打开的网页：返回到头回到浏览器的开始页
            } else {
                tv?.goHome()
            }
        case .playPause:
            runWebPlayback("toggle", in: web, fallback: .space)
        case .seek(let forward):
            runWebPlayback(forward ? "forward" : "backward", in: web, fallback: forward ? .right : .left)
        case .text(let text):
            for character in text {
                sendKey(character == "\n" ? .enter : Key(code: 0, chars: String(character)), to: web)
            }
        case .deleteBackward: sendKey(.delete, to: web)
        case .pointer(let dx, let dy): tv?.movePointer(dx: dx, dy: dy)
        case .click: tv?.clickPointer()
        case .scroll(let dy): scrollPage(web, by: dy)
        case .openInBrowser:
            if let url = web.url {
                tv?.goHome()
                SystemGuard.open(url)
            }
        default: break
        }
    }

    // MARK: - Native Movies

    func playMovie(_ movie: Movie, from seconds: Double) {
        tv?.startedPlaying("movies")   // 开始放影片：后台的歌、书停下
        closeIINAPlayback()
        closeExternalBrowser()
        let request = UUID()
        playbackRequest = request
        currentLocalMovie = movie
        localMoviePlayer = "native"
        Task { @MainActor in
            let opened: Result<PlaybackEngine, PlaybackProblem>
            var stream: JellyfinServers.Stream?
            if movie.isRemote {
                switch await jellyfin.stream(for: movie) {
                case .success(let found):
                    stream = found
                    opened = await AVPlayback.open(found.url).map { $0 as PlaybackEngine }
                case .failure(let problem):
                    Log.movies.error("Server movie stream unavailable")
                    guard playbackRequest == request else { return }
                    currentLocalMovie = nil
                    tv?.showToast(problem.message)
                    return
                }
            } else if ["mkv", "webm"].contains(movie.url.pathExtension.lowercased()) {
                opened = await Task.detached(priority: .userInitiated) { MatroskaPlayback.open(movie.url) }.value
                    .map { MatroskaPlayback($0) as PlaybackEngine }
            } else {
                opened = await AVPlayback.open(movie.url).map { $0 as PlaybackEngine }
            }
            guard playbackRequest == request else {
                if case .success(let engine) = opened { engine.stop() }
                return
            }
            switch opened {
            case .success(let engine):
                if let stream { jellyfin.started(stream, movie: movie, at: seconds) }
                startMovie(movie, engine: engine, from: seconds)
            case .failure:
                openElsewhere(movie)
            }
        }
    }

    private func startMovie(_ movie: Movie, engine: PlaybackEngine, from seconds: Double) {
        let player = MoviePlayer(movie: movie, engine: engine, library: tv?.movieLibrary ?? .shared)
        player.onEnd = { [weak self] in self?.movieEnded(movie) }
        player.onClose = { [weak self] in self?.closeMovie() }
        player.onFailure = { [weak self] _ in self?.movieFailed(movie) }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            if tv?.movies == nil { tv?.openMoviesBrowserOnly() }
            moviePlayer = player
            tv?.setMode(.movie)
        }
        tv?.displayCoordinator.holdPlaybackKeepAwake(reason: "Watching \(movie.title) in Mac TV")
        tv?.bringToFront()
        player.start(at: seconds)
    }

    func closeMovie() {
        playbackRequest = UUID()
        currentLocalMovie = nil
        if let player = moviePlayer { jellyfin.stopped(player.movie, at: player.engine.currentTime) }
        moviePlayer?.stop()
        if let path = moviePlayer?.movie.path {
            tv?.reconcileMovieBrowserPosition(for: path)
        }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            moviePlayer = nil
            tv?.setMode(.launcher)
        }
        tv?.displayCoordinator.releasePlaybackKeepAwake()
    }

    /// The end of a movie: back to Movies, or with Autoplay Next Episode on, straight into the show's next episode.
    private func movieEnded(_ movie: Movie) {
        closeMovie()
        guard let tv, tv.autoNext else { return }
        let library = tv.movieLibrary
        guard let current = library.movie(movie.path), let next = library.show(of: current)?.episode(after: current) else { return }
        playMovie(next, from: next.inProgress ? max(0, (next.position ?? 0) - 5) : 0)
    }

    /// The picture or sound stopped partway. Where it stopped is saved (closing saves it). A file that's no longer
    /// there (a share that dropped) says so; anything else is a file this player can't decode, offered to IINA or VLC.
    private func movieFailed(_ movie: Movie) {
        closeMovie()
        guard !movie.isRemote else { openElsewhere(movie); return }
        let path = movie.path
        Task { @MainActor [weak self] in
            // A dead share can keep a file check waiting: give it two seconds
            let reachable = await withTaskGroup(of: Bool?.self) { group in
                group.addTask { await Task.detached { FileManager.default.isReadableFile(atPath: path) }.value }
                group.addTask { try? await Task.sleep(for: .seconds(2)); return nil }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first ?? false
            }
            if reachable {
                self?.openElsewhere(movie)
            } else {
                self?.tv?.showToast("“\(movie.title)” isn't available right now. Its source may be offline.")
                self?.tv?.movieLibrary.refresh()
            }
        }
    }

    private func openElsewhere(_ movie: Movie) {
        guard !movie.isRemote else {
            currentLocalMovie = nil
            Log.movies.error("Server movie doesn't play in Mac TV's player")
            tv?.showToast("Mac TV couldn't play \(movie.title) from \(movie.server ?? "the server").")
            return
        }
        let iina = "com.colliderli.iina", vlc = "org.videolan.vlc"
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: iina) != nil,
           playInIINA(movie, screen: tv?.playbackScreen) { return }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: vlc), SystemGuard.allows("open VLC") {
            NSWorkspace.shared.open([movie.url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            tv?.setLaunchedAppID(vlc)
            tv?.showToast("Playing in VLC")
        } else {
            tv?.showToast("Can't play this file. Install IINA to play it.")
        }
    }

    func handleInMovie(_ command: RemoteCommand) {
        guard let player = moviePlayer else { return }
        if player.menu != nil {
            switch command {
            case .move(let direction): player.moveInMenu(direction)
            case .select: player.chooseInMenu()
            case .back: player.menu = nil; player.showControls()
            case .playPause: player.togglePlayback()
            default: break
            }
            return
        }
        switch command {
        case .select, .playPause: player.togglePlayback()
        case .move(.left): player.skip(-10)
        case .move(.right): player.skip(10)
        case .seek(let forward): player.skip(forward ? 10 : -10)
        case .move(.down): player.openMenu()
        case .move(.up): player.showControls()
        case .back: closeMovie()
        case .pointer, .click, .scroll: player.showControls()
        default: break
        }
    }

    // MARK: - IINA Playback

    @discardableResult
    func playInIINA(_ movie: Movie, subtitle: URL? = nil, position: Double? = nil, screen: NSScreen?) -> Bool {
        if currentLocalMovie?.path == movie.path, let session = iinaSession, session.isRunning {
            do {
                if let subtitle { try session.loadSubtitle(subtitle) }
                try session.activate()
                return true
            } catch {
                iinaPlaybackError = error.localizedDescription
                Log.playback.failure("IINA", error)
                tv?.showToast(error.localizedDescription)
                return false
            }
        }
        guard let screen else { tv?.showToast("Connect the display for movie playback."); return false }
        let pos = position ?? (moviePlayer?.movie.path == movie.path ? moviePlayer?.time : nil)
        var launched: IINAPlaybackSession?
        do {
            let session = try IINAPlaybackSession()
            launched = session
            tv?.goHome()
            iinaSession = session
            currentLocalMovie = movie
            localMoviePlayer = "iina"
            tv?.setLaunchedAppID("com.colliderli.iina")
            iinaPlaybackStatus = "Opening IINA on \(screen.localizedName)…"
            session.onError = { [weak self, weak session] error in
                guard let self, let session, self.iinaSession === session else { return }
                self.iinaPlaybackError = error.localizedDescription + (session.isRunning ? "" : " Select the movie again in Files.")
                Log.playback.failure("IINA", error)
                self.iinaPlaybackStatus = "IINA needs attention"
                if !session.isRunning { self.tv?.displayCoordinator.releasePlaybackKeepAwake() }
                self.tv?.showToast(error.localizedDescription)
            }
            session.onReady = { [weak self, weak session] in
                guard let self, let session, self.iinaSession === session else { return }
                self.iinaPlaybackError = nil
                self.iinaPlaybackStatus = "IINA on \(screen.localizedName)"
            }
            try session.launch(file: movie.url, subtitle: subtitle, position: pos, screen: screen)
            tv?.displayCoordinator.holdPlaybackKeepAwake(reason: "Watching a movie in IINA")
            return true
        } catch {
            launched?.close()
            iinaSession = nil
            currentLocalMovie = nil
            iinaPlaybackError = error.localizedDescription
            Log.playback.failure("IINA", error)
            tv?.showToast(error.localizedDescription)
            return false
        }
    }

    func closeIINAPlayback(terminating: Bool = false) {
        let previous = iinaSession
        iinaSession = nil
        externalInBackground = false
        iinaPlaybackError = nil
        iinaPlaybackStatus = ""
        previous?.close(immediate: terminating)
    }

    func handleIINACommand(_ command: RemoteCommand) {
        _ = iinaSession?.handle(command)
    }

    func activateIINA() {
        guard let session = iinaSession else { return }
        do { try session.activate() }
        catch {
            iinaPlaybackError = error.localizedDescription
            Log.playback.failure("IINA", error)
            tv?.showToast(error.localizedDescription)
        }
    }

    func searchIINASubtitles() -> Bool {
        guard AXIsProcessTrusted() else {
            tv?.showToast("Allow Mac TV in Accessibility settings to control IINA."); return false
        }
        guard let expected = currentLocalMovie?.path else { return false }
        Task { @MainActor [weak self] in
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(350))
                guard let self, self.currentLocalMovie?.path == expected else { return }
                let target: NSRunningApplication?
                if let session = self.iinaSession { target = session.application }
                else { target = NSRunningApplication.runningApplications(withBundleIdentifier: "com.colliderli.iina").first }
                guard let running = target else { continue }
                running.activate(options: [])
                let element = AXUIElementCreateApplication(running.processIdentifier)
                var bar: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXMenuBarAttribute as CFString, &bar) == .success,
                      let bar else { continue }
                if self.pressIINASubtitleSearch(unsafeDowncast(bar, to: AXUIElement.self), depth: 0) { return }
            }
            self?.tv?.showToast("IINA Subtitle Search Isn't Available")
        }
        return true
    }

    private func pressIINASubtitleSearch(_ element: AXUIElement, depth: Int) -> Bool {
        guard depth < 6 else { return false }
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
        let name = (title as? String ?? "").lowercased()
        if name.contains("online") && name.contains("subtitle") && (name.contains("find") || name.contains("search")) {
            return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
        }
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        for child in children as? [AXUIElement] ?? [] {
            if pressIINASubtitleSearch(child, depth: depth + 1) { return true }
        }
        return false
    }

    // MARK: - External Browser (Brave)

    func playInBrave(_ service: Service, url: URL) {
        closeExternalBrowser()
        webView?.pauseAllMediaPlayback(completionHandler: nil)
        webView?.stopLoading()
        webView = nil
        currentLocalMovie = nil
        tv?.playerFailure = nil
        if !movieInBackground {   // Movies in the background stays there
            moviePlayer?.stop()
            moviePlayer = nil
        }
        tv?.setLaunchedAppID(nil)
        let session = BraveSession()
        externalBrowser = session
        braveURL = url
        tv?.braveFocus = 0
        externalBrowserService = service
        tv?.setMode(.player(service))
        tv?.displayCoordinator.holdPlaybackKeepAwake(reason: "Watching \(service.name) in Brave")
        openExternalBrowser(session, url: url)
    }

    func retryExternalBrowser() {
        guard !externalBrowserOpening, externalBrowser != nil,
              let service = externalBrowserService, case .web(let url) = service.kind else { return }
        playInBrave(service, url: url)
    }

    func navigateExternalBrowser(service: Service, url: URL) throws {
        guard let browser = externalBrowser else { return }
        externalBrowserService = service
        braveURL = url
        do { try browser.navigate(to: url) }
        catch {
            externalBrowserError = error.localizedDescription
            Log.playback.failure("Brave", error)
            throw error
        }
        externalBrowserError = nil
        tv?.setMode(.player(service))
    }

    private func openExternalBrowser(_ session: BraveSession, url: URL) {
        let request = UUID()
        playbackRequest = request
        externalBrowserError = nil
        externalBrowserOpening = true
        Task { @MainActor [weak self] in
            do {
                try await session.open(url)
                guard let self, self.playbackRequest == request, self.externalBrowser === session else {
                    try? session.close(); return
                }
                if let screen = self.tv?.playbackScreen {
                    try await session.fit(to: screen)
                }
                guard self.playbackRequest == request, self.externalBrowser === session else {
                    try? session.close(); return
                }
                try session.activate()
                self.externalBrowserOpening = false
            } catch {
                guard let self, self.playbackRequest == request, self.externalBrowser === session else { return }
                self.externalBrowserOpening = false
                self.tv?.displayCoordinator.releasePlaybackKeepAwake()
                self.externalBrowserError = error.localizedDescription
                Log.playback.failure("Brave", error)
                self.tv?.bringToFront()
            }
        }
    }

    func activateExternalBrowser() {
        do {
            try externalBrowser?.activate()
            externalBrowserError = nil
        } catch {
            externalBrowserError = error.localizedDescription
            Log.playback.failure("Brave", error)
        }
    }

    func closeExternalBrowser() {
        let previous = externalBrowser
        externalBrowser = nil
        externalBrowserService = nil
        externalBrowserError = nil
        externalBrowserOpening = false
        do { try previous?.close() }
        catch BraveSession.SessionError.noWindow {}
        catch BraveSession.SessionError.unavailable {}
        catch {
            Log.playback.failure("Closing Brave window", error)
            tv?.showToast("Could not close the Mac TV Brave window. Close it manually in Brave.")
        }
    }

    func handleExternalBrowserCommand(_ command: RemoteCommand) {
        guard let browser = externalBrowser else { return }
        do { _ = try browser.handle(command) }
        catch {
            externalBrowserError = error.localizedDescription
            Log.playback.failure("Brave", error)
        }
    }
}

// MARK: - WKUIDelegate

extension PlaybackCoordinator: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // 浏览器里"在新窗口打开"的链接：开成一个新标签页（写了大小的登录小窗口还是照旧弹出来）
        if tv?.browserStore.opensAsNewTab(navigationAction, features: windowFeatures, from: webView) == true { return nil }
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 700), configuration: configuration)
        popup.customUserAgent = webView.customUserAgent
        popup.uiDelegate = self
        popup.navigationDelegate = self
        let popupWindow = NSWindow(contentRect: popup.frame, styleMask: [.titled, .closable, .resizable],
                                   backing: .buffered, defer: false)
        popupWindow.contentView = popup
        popupWindow.isReleasedWhenClosed = false
        popupWindow.level = .floating
        if let frame = tv?.window?.frame {
            popupWindow.setFrameOrigin(NSPoint(x: frame.midX - 260, y: frame.midY - 350))
        }
        popupWindow.makeKeyAndOrderFront(nil)
        popups.append(popupWindow)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        // 自用分支：网页应用自己要求关闭（比如 YouTube 电视界面里选"退出"）时，回主屏
        if webView === self.webView { tv?.goHome(); return }
        guard let popupWindow = popups.first(where: { $0.contentView === webView }) else { return }
        popupWindow.close()
        popups.removeAll { $0 === popupWindow }
    }
}

// MARK: - WKNavigationDelegate

extension PlaybackCoordinator: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        tv?.recordPlayerFailure(webView, error: error)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        tv?.recordPlayerFailure(webView, error: error)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { tv?.recordPlayerFailure(webView) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === self.webView {
            tv?.playerFailure = nil
            // 浏览器里看的页面：载好以后把真正的标题和地址记进"最近浏览"和这个标签页
            tv?.browserStore.pageLoaded(webView)
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard navigationAction.targetFrame?.isMainFrame ?? true, let host = navigationAction.request.url?.host() else { return .allow }
        let signingIn = host == "accounts.google.com" || host.hasSuffix(".accounts.google.com")
        var usual = UserAgent.safari
        if case .player(let service) = tv?.mode { usual = service.userAgent }
        let wanted = signingIn ? UserAgent.googleSignIn : usual
        if webView.customUserAgent != wanted { webView.customUserAgent = wanted }
        return .allow
    }
}
