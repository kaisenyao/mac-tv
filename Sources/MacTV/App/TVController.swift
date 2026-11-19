import AppKit
import Combine
import SwiftUI
import WebKit

@MainActor
final class TVController: NSObject, ObservableObject {
    enum Mode: Equatable {
        case launcher
        case player(Service)
        /// A movie from the Movies app, in Mac TV's own player.
        case movie
    }

    /// What has focus on the home screen: an app tile, an item in the Top Shelf, or a pill in the
    /// status row at the top right.
    enum Focus: Equatable {
        case app(Int)
        case shelf(Int)
        case status(StatusItem)
    }

    /// The status row's pills that take focus, left to right; the clock doesn't.
    enum StatusItem: Equatable {
        case lid, controlCenter, profile
    }

    // MARK: - Dedicated Coordinators

    let playbackCoordinator: PlaybackCoordinator
    let remoteCoordinator: RemoteCoordinator
    let displayCoordinator: DisplayCoordinator
    let audioCoordinator: AudioCoordinator
    let idleCoordinator = IdleCoordinator()
    let preferences: Preferences
    let movieLibrary: MovieLibrary
    let jellyfin: JellyfinServers
    let networkShares: NetworkShares
    let updater: Updater
    let topShelf: TopShelfFeed
    let feedback: Feedback
    private var coordinatorChanges: [AnyCancellable] = []

    // MARK: - State

    @Published private(set) var mode: Mode = .launcher
    @Published private(set) var focus: Focus = .app(0)
    /// Suppresses mouse hover focus changes during scrolling or keyboard navigation until the pointer actually moves.
    var suppressHover = false
    // MARK: 交互规则（全局唯一的定义）
    //
    // 屏幕上每一块能操作的地方都属于下面一类，横着、竖着各自归一类。各应用只申报"焦点现在所在的地方横 / 竖是哪一类"
    // （module(horizontal:)）和"长条里朝这边还有没有下一个"（flickCanMove），方向、走几格、惯性、声音、震动都由这一处决定：
    // 双指滑动在 main.swift，按键音和震动在 handle(_:) 里按这里的分类挑。
    //
    // - strip 长条：窗口不动、内容在底下滚的一长排（视频排、歌单排、播放列表、相关视频、歌单页的歌）。选中是加一圈框。
    //   手指带着内容走：往左 / 往上滑是下一个。轻轻一拨一格；用力一甩接着滑，越往后越慢，到这一条的头就停。
    //   声音是轻快的"嗒"（甩出去时连着响，像拨滚轮），触控板轻震。
    // - picker 挑选：选项不动、白色高亮在动（主屏图标、顶栏、音质栏、清晰度栏、菜单、设置项、左边栏里的上下、排序）。
    //   选中是从灰变白。光标跟着手走：往右 / 往下滑光标往右 / 往下，一次滑动一格。声音是厚一点的"咔"，触控板明显一点地震一下。
    // - drawer 抽屉：从屏幕边上拉出来的面板（左边栏从左、音质栏和清晰度栏从上、播放列表和相关视频从下），
    //   以及在一摞会滚的排之间换排。内容跟着手走：往外拉出来，往反方向推回去；拉出来以后同方向再滑不动（像 Mac 的通知中心）。
    //   一次滑动一格，声音、震动和挑选一样。
    // - scrub 进度：视频、音乐播放中左右滑。进度跟着手走，每拖过一段（ScrubDetent）响一声"嗒"、震一下，抬手才跳过去。
    // - off：这里不响应。
    //
    // 从一个区域到另一个区域（进左边栏、上顶栏）只能是一次新的滑动的第一格：甩出去的惯性不会冲过去。
    // 一去一回方向相反：上到顶栏 / 头像是什么手势，回去就是反过来的手势。所以顶栏、头像的上下跟着它下面那一块走——
    // 下面是内容跟着手走的（视频排、首页那几排、歌单里的歌），往下滑上去、往上滑回来；
    // 下面是光标（设置项、歌单页左边的按钮），往上滑上去、往下滑回来。
    // 鼠标：点一下选中并打开，按住弹出菜单；停在上面只是轻轻浮起、不改选中，一按键或一滑动就收起（PointerActivity）。
    // 键盘：方向键就是光标方向；回车确认、长按回车菜单；Esc 返回、长按 Esc 回主屏。
    // 核对用的现象（不是依据）：长条里选中是加框；挑选里选中是变白。
    enum Module { case strip, picker, drawer, scrub, off }

    func module(horizontal: Bool) -> Module {
        if activeSheet != nil { return .picker }   // 弹出的面板：一列固定的选项
        if bilibiliOpen { return bilibiliStore.module(horizontal: horizontal) }
        if neteaseOpen { return neteaseStore.module(horizontal: horizontal) }
        if movies != nil { return .drawer }
        // 主屏：左右是在一排固定的图标里挑；上下是在 Top Shelf、图标、下面的格子之间翻
        return horizontal ? .picker : .drawer
    }

    /// 拖进度：手指横着滑了多远（往右为正）、手指抬起
    func scrubMove(points: Double) {
        let crossed = bilibiliOpen ? bilibiliStore.player.scrubMove(points: points)
            : neteaseOpen ? neteaseStore.scrubMove(points: points) : false
        if crossed { feedback.play(.move, from: .trackpad) }   // 拖过一段响一声，像旋钮的档位
    }
    func endScrub() {
        if bilibiliOpen { bilibiliStore.player.endScrub() } else if neteaseOpen { neteaseStore.endScrub() }
    }

    /// 转盘沿着哪个方向走：焦点所在的这一排是横的（首页那几排、顶栏、音质栏、播放列表、排序）还是竖的（菜单、左边栏、设置、歌单里的歌）
    func wheelRunsHorizontally() -> Bool {
        if activeSheet != nil { return false }   // 弹出的面板都是竖着一列
        if bilibiliOpen { return bilibiliStore.wheelRunsHorizontally }
        if neteaseOpen { return neteaseStore.wheelRunsHorizontally }
        return true                               // 主屏：一排图标
    }

    /// 长条里朝这个方向还有没有下一个。没有就停：一次滑动接着走的（第二格起、甩出去的惯性）不离开这一条
    func flickCanMove(_ direction: RemoteCommand.Direction) -> Bool {
        if bilibiliOpen { return bilibiliStore.flickCanMove(direction) }
        if neteaseOpen { return neteaseStore.flickCanMove(direction) }
        return false
    }
    /// The top-row app whose content the Top Shelf shows.
    @Published private(set) var shelfAppIndex = 0
    /// Pointer position over the focused tile, -0.5…0.5 on each axis, for the parallax tilt. Kept
    /// in its own object, so the pointer moving redraws the tiles, not every view watching the TV.
    let pointerTilt = PointerTilt()
    var tilt: CGSize {
        get { pointerTilt.value }
        set { if pointerTilt.value != newValue { pointerTilt.value = newValue } }
    }
    /// The sheets open over the home screen.
    @Published var sheets = SheetStack() {
        didSet { if sheets.pairing != oldValue.pairing { pairingChanged() } }
    }
    @Published var playerFailure: PlayerFailure?
    /// The Movies app's screen, while it's open.
    @Published var movies: MoviesBrowser?
    /// 哔哩哔哩的原生页面（自用分支）
    let bilibiliStore = BilibiliStore()
    @Published var bilibiliOpen = false
    let neteaseStore = NeteaseStore()
    @Published var neteaseOpen = false
    /// Who's watching: their apps and their sign-ins.
    @Published var profile: Profile

    /// The focused button on Mac TV's own Brave screen.
    @Published var browserFocus = 0
    let browserPreferences: BrowserPreferences
    /// Toasts, the volume indicator and controller banners.
    let notices = Notices()
    /// The connected game controller, if any.
    @Published var controller: ControllerInfo?

    /// The home screen's apps, in order; changes when the user adds or removes apps.
    @Published private(set) var services: [Service] = []
    let profiles: ProfileStore
    var library: AppLibrary
    let columns = 6
    let deviceName = Host.current().localizedName ?? "Mac"
    weak var window: NSWindow?

    /// Press the players' own Skip Intro / Skip Recap buttons.
    var autoSkip: Bool {
        get { preferences.autoSkip }
        set { preferences.autoSkip = newValue }
    }

    /// Press Next Episode when the player offers it.
    var autoNext: Bool {
        get { preferences.autoNext }
        set { preferences.autoNext = newValue }
    }

    // MARK: - Forwarded Properties to Coordinators

    // Playback
    var webView: WKWebView? { playbackCoordinator.webView }
    var moviePlayer: MoviePlayer? { playbackCoordinator.moviePlayer }
    var currentLocalMovie: Movie? { playbackCoordinator.currentLocalMovie }
    var localMoviePlayer: String { playbackCoordinator.localMoviePlayer }
    var iinaPlaybackError: String? { playbackCoordinator.iinaPlaybackError }
    var iinaPlaybackStatus: String { playbackCoordinator.iinaPlaybackStatus }
    var externalBrowser: BraveSession? { playbackCoordinator.externalBrowser }
    var externalBrowserService: Service? { playbackCoordinator.externalBrowserService }
    var externalBrowserError: String? { playbackCoordinator.externalBrowserError }
    var externalBrowserOpening: Bool { playbackCoordinator.externalBrowserOpening }

    // Remote
    var remoteToken: String {
        get { remoteCoordinator.remoteToken }
        set { remoteCoordinator.remoteToken = newValue }
    }
    var remoteGuestToken: String { remoteCoordinator.remoteGuestToken }
    var remoteLinks: [RemoteLink] { remoteCoordinator.remoteLinks }
    var remoteGuestLinks: [RemoteLink] { remoteCoordinator.remoteGuestLinks }
    var remotePort: UInt16 {
        get { remoteCoordinator.remotePort }
        set { remoteCoordinator.remotePort = newValue }
    }
    var pairingGuest: Bool {
        get { remoteCoordinator.pairingGuest }
        set { remoteCoordinator.pairingGuest = newValue }
    }
    var phonePaired: Bool {
        get { remoteCoordinator.phonePaired }
        set { remoteCoordinator.phonePaired = newValue }
    }

    // Display & Power
    var power: PowerStatus { displayCoordinator.power }
    var lidSleepOff: Bool { displayCoordinator.lidSleepOff }
    var displaysSleeping: Bool { displayCoordinator.displaysSleeping }
    var keepMacAwake: Bool {
        get { displayCoordinator.keepMacAwake }
        set { displayCoordinator.keepMacAwake = newValue }
    }
    var lidOverride: Bool {
        get { displayCoordinator.lidOverride }
        set { displayCoordinator.lidOverride = newValue }
    }
    var lidStatus: String { displayCoordinator.lidStatus }
    var playbackScreen: NSScreen? { displayCoordinator.playbackScreen }

    // Audio Output
    var audioDevices: [AudioOutputDevice] { audioCoordinator.devices }
    var currentAudioDevice: AudioOutputDevice? { audioCoordinator.currentDevice }

    // MARK: - Forwarded Methods

    func offerStartupPairing() { remoteCoordinator.offerStartupPairing() }
    func showStartupPairingIfReady() { remoteCoordinator.showStartupPairingIfReady() }
    func noteRemoteConnection() { remoteCoordinator.noteRemoteConnection() }
    func refreshRemoteURL() { remoteCoordinator.refreshRemoteURL() }
    func remoteState() -> [String: Any] { remoteCoordinator.remoteState() }
    func handleAppsRequest(_ request: HTTPRequest) -> HTTPResponse? { remoteCoordinator.handleAppsRequest(request) }
    func handleGuestCommand(_ command: RemoteCommand) -> Bool { remoteCoordinator.handleGuestCommand(command) }

    func startPowerManagement() { displayCoordinator.startPowerManagement() }
    func stopPowerManagement() { displayCoordinator.stopPowerManagement() }
    func refreshPower() { displayCoordinator.refreshPower() }
    func noteDisplaySleep(_ sleeping: Bool) { displayCoordinator.noteDisplaySleep(sleeping) }
    func wakeDisplays() { displayCoordinator.wakeDisplays() }

    @discardableResult
    func playInIINA(_ movie: Movie, subtitle: URL? = nil) -> Bool {
        playbackCoordinator.playInIINA(movie, subtitle: subtitle, screen: playbackScreen)
    }
    func closeIINAPlayback(terminating: Bool = false) { playbackCoordinator.closeIINAPlayback(terminating: terminating) }
    func searchIINASubtitles() -> Bool { playbackCoordinator.searchIINASubtitles() }
    func playMovie(_ movie: Movie, from seconds: Double) { playbackCoordinator.playMovie(movie, from: seconds) }
    func closeMovie() { playbackCoordinator.closeMovie() }
    func retryExternalBrowser() { playbackCoordinator.retryExternalBrowser() }
    func activateExternalBrowser() { playbackCoordinator.activateExternalBrowser() }
    func closeExternalBrowser() { playbackCoordinator.closeExternalBrowser() }

    // MARK: - Private State

    private var controllerInput: ControllerInput?
    private var launchedAppID: String?
    /// A Steam game just launched from Mac TV: watched so Mac TV comes back when it quits.
    var steamWatchUntil: Date?
    var steamGamePID: pid_t?
    /// Mac TV opened Steam or a Steam game, so remote presses may go to it.
    var openedSteam = false
    var steamObservers: [NSObjectProtocol] = []
    var pointer: CGPoint?

    // MARK: - Lifecycle

    override convenience init() {
        let store = ProfileStore()
        self.init(library: AppLibrary(profileID: store.current.id), profiles: store)
    }

    init(library: AppLibrary, profiles: ProfileStore? = nil, browserPreferences: BrowserPreferences? = nil,
         services appServices: AppServices = AppServices()) {
        preferences = appServices.preferences
        movieLibrary = appServices.movieLibrary
        jellyfin = appServices.jellyfin
        networkShares = appServices.networkShares
        updater = appServices.updater
        topShelf = appServices.topShelf
        feedback = appServices.feedback
        self.browserPreferences = browserPreferences ?? BrowserPreferences()
        let store = profiles ?? ProfileStore(folder: library.storageFolder)
        self.profiles = store
        self.profile = store.current
        self.library = library
        let pc = PlaybackCoordinator(jellyfin: appServices.jellyfin)
        let rc = RemoteCoordinator()
        let dc = DisplayCoordinator(preferences: appServices.preferences)
        let ac = AudioCoordinator()
        self.playbackCoordinator = pc
        self.remoteCoordinator = rc
        self.displayCoordinator = dc
        self.audioCoordinator = ac
        super.init()
        pc.tv = self
        rc.tv = self
        dc.tv = self
        ac.tv = self
        idleCoordinator.tv = self
        // Views watch this controller, so any change a coordinator publishes redraws them.
        coordinatorChanges = [pc.objectWillChange, rc.objectWillChange, dc.objectWillChange, ac.objectWillChange,
                              idleCoordinator.objectWillChange, preferences.objectWillChange].map {
            $0.sink { [weak self] in self?.objectWillChange.send() }
        }
        services = library.services()
    }

    // MARK: - Screensaver and sleep timer

    var screensaver: Bool { idleCoordinator.screensaver }
    var sleepAt: Date? { idleCoordinator.sleepAt }
    @discardableResult
    func noteActivity() -> Bool { idleCoordinator.noteActivity() }
    func showScreensaver() { idleCoordinator.showScreensaver() }
    func screensaverOff() { idleCoordinator.hideScreensaver() }
    func setSleepTimer(minutes: Int) { idleCoordinator.setSleepTimer(minutes: minutes) }

    // MARK: - Adding and removing apps

    func reloadServices() {
        let oldFocus = focus
        let shelfID = services.indices.contains(shelfAppIndex) ? services[shelfAppIndex].id : nil
        let focusedID: String?
        if case .app(let index) = focus, services.indices.contains(index) { focusedID = services[index].id }
        else { focusedID = shelfID }
        services = library.services()
        if let index = services.firstIndex(where: { $0.id == shelfID }), index < columns { shelfAppIndex = index }
        else { shelfAppIndex = 0 }
        let newIndex = services.firstIndex { $0.id == focusedID }
        switch oldFocus {
        case .app(let index):
            let next = newIndex ?? min(index, max(services.count - 1, 0))
            setFocus(.app(next))
            if next < columns { shelfAppIndex = next }
        case .shelf(let index):
            if let newIndex, newIndex < columns, shelfCount > 0 {
                setFocus(.shelf(min(index, shelfCount - 1)))
            } else {
                setFocus(.app(newIndex ?? shelfAppIndex))
            }
        case .status(let item):
            if !statusItems.contains(item) { setFocus(.status(.controlCenter)) }
        }
        reconcileOrganizerSelection()
    }

    // MARK: - Home screen focus

    func setFocus(_ newFocus: Focus) {
        guard newFocus != focus else { return }
        focus = newFocus
        tilt = .zero
        if case .app(let index) = newFocus, index < columns { shelfAppIndex = index }
    }

    private func handleInLauncher(_ command: RemoteCommand) {
        switch sheets.top {
        case .setup: handleSetup(command); return
        case .profilePicker: handleProfiles(command); return
        case .audioPicker: handleAudioPicker(command); return
        case .playbackCheck:
            switch command { case .back, .select: playbackCheck = nil; default: break }
            return
        case .topShelfPreferences: handleTopShelfPreferences(command); return
        case .addApp: handleAdder(command); return
        case .pairing: handlePairing(command); return
        case .organizer: handleOrganizer(command); return
        case .settings: handleSettings(command); return
        case .controlCenter: handleControlCenter(command); return
        case nil: break
        }
        if bilibiliOpen {
            bilibiliStore.handle(command)
            return
        }
        if neteaseOpen {
            neteaseStore.handle(command)
            return
        }
        if movies != nil {
            handleMovies(command)
            return
        }
        switch command {
        case .move(let direction): moveFocus(direction)
        case .select:
            switch focus {
            case .app(let index): if services.indices.contains(index) { open(services[index]) }
            case .shelf(let index): activateShelf(index)
            case .status(let item): activateStatus(item)
            }
        case .back:
            switch focus {
            case .status: setFocus(shelfCount > 0 ? .shelf(0) : .app(shelfAppIndex))
            case .shelf: setFocus(.app(shelfAppIndex))
            case .app: if inGrid { setFocus(.app(0)) }
            }
        case .pointer(let dx, let dy): movePointer(dx: dx, dy: dy)
        case .click: clickPointer()
        default: break
        }
    }

    private var feedbackState: String {
        String(describing: (focus, sheets, movies, mode == .launcher)) + (bilibiliOpen ? bilibiliStore.focusKey : "")
            + (neteaseOpen ? neteaseStore.focusKey : "")
    }

    // MARK: - Command Dispatch

    func handle(_ command: RemoteCommand, from source: Feedback.Source = .keyboard) {
        if source == .remote {
            noteRemoteConnection()
            if displaysSleeping {
                switch command {
                case .screenOff, .screenOn, .sleepMac: break
                default: wakeDisplays()
                }
            }
        }
        let dismissedScreensaver = noteActivity()
        switch command {
        case .screenOff, .screenOn, .sleepMac: break
        default: if dismissedScreensaver { return }
        }
        Analytics.noteInput(source)

        switch command {
        case .pointer, .click, .scroll: break
        default:
            NSCursor.setHiddenUntilMouseMoves(true)
            suppressHover = true
            PointerActivity.shared.set(false)
        }

        switch command {
        case .wheel(let step):
            // 转盘（手机遥控器上那一圈）= 沿着焦点所在的这一排 / 一列走，顺时针是下一个（规则见 Module）。
            // 视频、音乐播放中是快进 / 快退，一格 5 秒
            let forward = step > 0, count = min(abs(step), 16)
            if mode == .launcher, module(horizontal: true) == .scrub {
                for _ in 0..<count {
                    if bilibiliOpen { bilibiliStore.player.scrub(by: forward ? 5 : -5) } else if neteaseOpen { neteaseStore.nudge(forward ? 5 : -5) }
                }
                feedback.play(.move, from: source)
                return
            }
            let horizontal = wheelRunsHorizontally()
            for _ in 0..<count { handle(.move(horizontal ? (forward ? .right : .left) : (forward ? .down : .up)), from: source) }
            return
        case .home: goHome(); return
        case .activateBrowser:
            if playbackCoordinator.iinaOpen {
                playbackCoordinator.activateIINA()
            } else { activateExternalBrowser() }
            return
        case .retryBrowser:
            retryExternalBrowser()
            return
        case .launch(let id):
            if let service = services.first(where: { $0.id == id }) { open(service) }
            return
        case .volume(let delta):
            if playbackCoordinator.iinaOpen { playbackCoordinator.handleIINACommand(command) }
            else { showVolume(SystemControl.changeVolume(by: delta)) }
            return
        case .mute:
            if playbackCoordinator.iinaOpen { playbackCoordinator.handleIINACommand(command) }
            else { showVolume(SystemControl.toggleMute()) }
            return
        case .screenOff:
            displayCoordinator.noteDisplaySleep(true)
            SystemControl.displayOff()
            return
        case .screenOn: wakeDisplays(); return
        case .sleepTimer(let minutes): setSleepTimer(minutes: minutes); return
        case .setting(let key, let value):
            if key == "autoSkip" { autoSkip = value }
            if key == "autoNext" { autoNext = value }
            if key == "keepMacAwake" { keepMacAwake = value }
            if key == "lidOverride" { lidOverride = value }
            return
        case .sleepMac:
            goHome()
            SystemControl.sleepNow()
            return
        case .controlCenter:
            guard setup == nil, profilePicker == nil else { return }
            if controlCenter != nil {
                controlCenter = nil
            } else {
                if mode != .launcher || movies != nil { goHome() }
                sheets.closeDismissible()
                openControlCenter()
            }
            return
        default: break
        }

        if playbackCoordinator.externalBrowser != nil {
            if NSApp.isActive {
                switch command {
                case .move, .select, .back: handleBrowserScreen(command); return
                default: break
                }
            }
            playbackCoordinator.handleExternalBrowserCommand(command)
            return
        }

        if playbackCoordinator.iinaOpen {
            playbackCoordinator.handleIINACommand(command)
            return
        }

        if !NSApp.isActive, let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier == launchedAppID
            || (openedSteam && (front.bundleIdentifier == SteamLibrary.bundleID || front.processIdentifier == steamGamePID)) {
            forwardToFrontApp(command)
            return
        }

        if source == .remote || source == .controller, !NSApp.isActive {
            bringToFront()
        }

        switch mode {
        case .launcher:
            let before = feedbackState
            // 走一格的声音按焦点（走之前）所在的区域：长条、进度是轻快的"嗒"，其余一格一格的（挑选、抽屉）是"咔"
            var moveCue = Feedback.Cue.step
            if case .move(let direction) = command, [.strip, .scrub].contains(module(horizontal: direction == .left || direction == .right)) {
                moveCue = .move
            }
            handleInLauncher(command)
            let changed = feedbackState != before
            switch command {
            case .move where changed: feedback.play(moveCue, from: source)
            case .seek: feedback.play(.move, from: source)   // 快进 / 快退（滚轮、手机遥控器）：轻快的"嗒"
            case .select: feedback.play(.select, from: source)
            case .back where changed: feedback.play(.back, from: source)
            default: break
            }
        case .player(let service):
            if !bilibiliStore.handleInPlayer(command, service: service), !neteaseStore.handleInPlayer(command, service: service) {
                playbackCoordinator.handleInPlayer(command, service: service)
            }
        case .movie: playbackCoordinator.handleInMovie(command)
        }
    }

    // MARK: - Opening & Home

    func open(_ service: Service) {
        if service.id == BilibiliStore.appID { closeNetease(); openBilibili(); return }
        if bilibiliOpen { closeBilibili() }   // 开别的应用时，哔哩哔哩不能还在后台放着
        if service.id == NeteaseStore.appID { openNetease(); return }
        closeNetease()
        playbackCoordinator.closeIINAPlayback()
        playbackCoordinator.closeExternalBrowser()
        var opened = ["app": analyticsAppName(service)]
        if case .web = service.kind { opened["player"] = browserPreferences.choice(for: profile.id).rawValue }
        Analytics.send(.appOpened, opened)
        playbackCoordinator.resetPlaybackRequest()
        sheets.closeDismissible()
        switch service.kind {
        case .web(let url):
            playbackCoordinator.playWeb(service, url: url)
        case .app(let bundleID):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
            launchedAppID = bundleID
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        case .steam(let appID):
            NSWorkspace.shared.open(SteamLibrary.launchURL(for: appID))
            openedSteam = true
            if appID != SteamLibrary.bigPicture.appID { watchForSteamGame() }
            showToast("Opening \(service.name) in Steam")
        case .movies:
            openMovies()
        case .addApp:
            adder = AppAdder()
        case .settings:
            openSettings()
        }
    }

    func goHome() {
        playbackCoordinator.closeIINAPlayback()
        playbackCoordinator.closeExternalBrowser()
        playbackCoordinator.resetPlaybackRequest()
        playbackCoordinator.clearCurrentLocalMovie()
        playbackCoordinator.stopMoviePlayer()
        movies = nil
        closeBilibili()
        leaveNetease()
        playbackCoordinator.closeWebPlayback()
        mode = .launcher
        sheets.closeDismissible()
        playerFailure = nil
        pointer = nil
        launchedAppID = nil
        displayCoordinator.releasePlaybackKeepAwake()
        bringToFront()
    }

    var idleForUpdate: Bool {
        (screensaver || displaysSleeping) && mode == .launcher && setup == nil && !playbackCoordinator.isAnyPlaybackActive
    }

    var braveInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.brave.Browser") != nil }
    var websitePlayerName: String { browserPreferences.choice(for: profile.id) == .brave ? "Brave" : "Built-in" }

    @discardableResult
    func setWebsitePlayer(_ raw: String) -> Bool {
        guard let choice = BrowserChoice(rawValue: raw), choice != .brave || braveInstalled else { return false }
        browserPreferences.setChoice(choice, for: profile.id)
        objectWillChange.send()
        return true
    }

    func stepWebsitePlayer() {
        let next = browserPreferences.choice(for: profile.id) == .embedded ? BrowserChoice.brave : .embedded
        if !setWebsitePlayer(next.rawValue) { showToast("Install Brave Browser to select it.") }
    }

    private func pairingChanged() {
        if sheets.pairing {
            remoteCoordinator.pairingGuest = false
            displayCoordinator.resetPairingFocus()
            refreshRemoteURL()
        } else {
            remoteCoordinator.notePairingDismissed()
        }
    }

    // MARK: - Helpers for Coordinators

    func setMode(_ newMode: Mode) { mode = newMode }
    func clearPointer() { pointer = nil }
    func setLaunchedAppID(_ id: String?) { launchedAppID = id }
    func openMoviesBrowserOnly() { movies = MoviesBrowser() }
    func reconcileMovieBrowserPosition(for path: String) {
        for (row, line) in movieRows.enumerated() {
            if let column = line.items.firstIndex(of: .movie(path)) {
                movies?.row = row
                movies?.column = column
                break
            }
        }
    }

    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func showVolume(_ level: VolumeLevel) { notices.showVolume(level) }

    func startControllers() {
        controllerInput = ControllerInput(tv: self)
        controllerInput?.start()
        if ProcessInfo.processInfo.environment["MACTV_PREVIEW_CONTROLLER"] == "1" {
            controllerChanged(ControllerInfo(name: "DualSense Wireless Controller", battery: 0.7, selectSymbol: "xmark.circle",
                                             backSymbol: "circle.circle", menuSymbol: "line.3.horizontal.circle"), connected: true)
        }
    }

    func showControllerNotice(_ notice: ControllerNotice) { notices.showController(notice) }

    func showToast(_ text: String) { notices.showToast(text) }
}
