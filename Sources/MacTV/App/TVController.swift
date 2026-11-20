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
    let feedback: Feedback
    private var coordinatorChanges: [AnyCancellable] = []

    /// 每个遥控器、键盘、手柄上按住的键是什么意思（见 PhonePresses）
    lazy var phonePresses = PhonePresses(tv: self)
    /// The keyboard's and controllers' buttons, timed as the remotes' are (see InputPresses)
    lazy var inputPresses = InputPresses(tv: self)
    /// 双指滑动：Mac 的触控板、滚轮和手机遥控器的触控板共用（见 TrackpadGestures）
    lazy var trackpadGestures = TrackpadGestures(tv: self)
    /// 哔哩哔哩、网易云、YouTube 在主屏顶部的轮播（见 AppShelf）
    lazy var appShelf = AppShelf(tv: self)

    // MARK: - State

    @Published private(set) var mode: Mode = .launcher
    @Published private(set) var focus: Focus = .app(0)
    /// Suppresses mouse hover focus changes during scrolling or keyboard navigation until the pointer actually moves.
    var suppressHover = false
    // MARK: 交互规则（全局唯一的定义）
    //
    // 屏幕上每一块能操作的地方都属于下面一类，横着、竖着各自归一类。各应用只申报"焦点现在所在的地方横 / 竖是哪一类"
    // （module(horizontal:)）和"长条里朝这边还有没有下一个"（flickCanMove），方向、走几格、惯性、声音、震动都由这一处决定：
    // 双指滑动在 TrackpadGestures.swift，按键音和震动在 handle(_:) 里按这里的分类挑。
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
    // 上面说的"内容跟着手走"是 Mac 的触控板、滚轮和手机触控板上的双指滑动。遥控器（Siri Remote、手机的点按区）上
    // 是焦点跟着手指走，像 Apple TV：往右 / 上滑焦点往右 / 上，长条、区域之间、挑选、面板里都一样，甩出去的惯性也接着往这边走；
    // 门槛、惯性、声音、震动和触控板一样。拖进度谁来的都是手指往右往前（TrackpadGestures.towardsNext）。
    // 鼠标：点一下选中并打开，按住弹出菜单；停在上面只是轻轻浮起、不改选中，一按键或一滑动就收起（PointerActivity）。
    // 键盘：方向键就是光标方向；回车确认、长按回车菜单（开着时再长按收起，见 toggle）；Esc 返回、长按 Esc 问要不要退出前面这个应用（见 AppQuit）。
    // 核对用的现象（不是依据）：长条里选中是加框；挑选里选中是变白。
    enum Module { case strip, picker, drawer, scrub, off }

    func module(horizontal: Bool) -> Module {
        // IINA、从主屏打开的 Mac 应用或 Steam 游戏在前面：按键都给它（见 handle(_:)），滑一下就是按一下方向键，
        // 不去动后面看不见的主屏
        if playbackCoordinator.iinaOpen || frontAppTakesKeys { return .picker }
        if activeSheet != nil { return .picker }   // 弹出的面板：一列固定的选项
        if browserChromeUp { return browserStore.chromeModule(horizontal: horizontal) }   // 浏览器网页上的标签栏、"⋯"菜单
        if bilibiliOpen { return bilibiliStore.module(horizontal: horizontal) }
        if neteaseOpen { return neteaseStore.module(horizontal: horizontal) }
        if browserOpen, mode == .launcher { return browserStore.startModule(horizontal: horizontal) }
        if dedaoOpen { return dedaoStore.module(horizontal: horizontal) }
        if movies != nil { return .drawer }
        // 主屏顶部的轮播（哔哩哔哩、网易云、YouTube）：左右是翻页，内容跟着手走，一次滑动翻一页；上下离开这一栏
        if case .shelf = focus, AppShelf.services.contains(shelfService.id), appShelf.current(for: shelfService.id) != nil {
            return .drawer
        }
        // 主屏：左右是在一排固定的图标里挑；上下是在 Top Shelf、图标、下面的格子之间翻
        return horizontal ? .picker : .drawer
    }

    /// 拖进度：手指横着滑了多远（往右为正）、手指抬起
    func scrubMove(points: Double) {
        let crossed = bilibiliOpen ? bilibiliStore.player.scrubMove(points: points)
            : neteaseOpen ? neteaseStore.scrubMove(points: points)
            : dedaoOpen ? dedaoStore.player.scrubMove(points: points) : false
        if crossed { feedback.play(.move, from: .trackpad) }   // 拖过一段响一声，像旋钮的档位
    }
    func endScrub() {
        if bilibiliOpen { bilibiliStore.player.endScrub() } else if neteaseOpen { neteaseStore.endScrub() }
        else if dedaoOpen { dedaoStore.player.endScrub() }
    }

    // MARK: 打开它的键再按一次就收起（全局唯一的规矩）
    //
    // 打开菜单、面板的键：按住 TV 键（控制中心）、按住确认（卡片菜单、看视频时右边的面板、浏览器的"⋯"、
    // 网易云和得到的菜单）、手机上的快捷键（清晰度、倍速、字幕、选集、投币、取消收藏的确认、每日推荐、定时关闭）。
    // 它打开的那个正在最上面时，同一个键再按一次就是收起：和按返回一样（同样的动画，"返回"的声音），不用去按返回；
    // 有菜单的好几层时整个收起（它打开的是整个）。最上面是别的菜单时照常打开它自己的（换过去）。
    // 本来就是开关的（弹幕、歌词、文稿）、再按一次是确认的（菜单里的一项、控制中心的格子）不归这里。

    /// close 收起了这个键打开的那个（它正开着）、不然 open 打开了：返回该响的声音（"返回"、"确认"）；都没做是 nil
    func toggle(close: () -> Bool, open: () -> Bool) -> Feedback.Cue? {
        if close() { return .back }
        return open() ? .select : nil
    }

    /// 按住确认（手机的 OK、Siri Remote、回车、旧版手机页的 okhold）：按住打开的菜单开着就收起，没开就打开，并响一声。
    /// 都没做（这里没有菜单）返回 false：照常是一次确认
    func holdSelect(from source: Feedback.Source) -> Bool {
        guard let cue = toggle(close: closeHoldMenu, open: openHoldMenu) else { return false }
        feedback.play(cue, from: source)
        return true
    }

    /// 按住确认打开的那个正在最上面：收起它（连同里面的几层），同按返回。条件和 openHoldMenu 一样
    func closeHoldMenu() -> Bool {
        if browserPageInFront { return browserStore.closeHoldMenu() }
        if browserOpen, mode == .launcher { return browserStore.closeHistoryRowMenu() || browserStore.closeItemMenu() }
        if activeSheet == .organizer { return closeOrganizerMenu() }   // Arrange Apps: an app's menu
        guard mode == .launcher, activeSheet == nil else { return false }
        if bilibiliOpen, !bilibiliStore.editing {
            let player = bilibiliStore.player
            if player.current == nil { return bilibiliStore.closeCardMenu() }
            guard player.panelVisible else { return false }
            player.closePanel()
            return true
        }
        if neteaseOpen { return neteaseStore.closeHoldMenu() }
        if dedaoOpen { return dedaoStore.closePlayerMenu() }
        return false
    }

    /// 按住确认会打开的东西（和 main.swift 里按住回车是同一套条件）。打开了返回 true
    func openHoldMenu() -> Bool {
        if browserPageInFront { return browserStore.openMenu() }   // 浏览器的网页：标签栏的"⋯"菜单
        if browserOpen, mode == .launcher, activeSheet == nil {   // Web：History 的一行、开始页上一个网站的菜单
            return browserStore.historyState != nil ? browserStore.openHistoryRowMenu() : browserStore.openItemMenu()
        }
        if activeSheet == .organizer { return openOrganizerMenu() }    // Arrange Apps: an app's menu (Hide)
        if homeAppFocused { return openHomeAppMenu() }                // Home: an app's menu (Edit Home Screen, Hide)
        guard mode == .launcher, activeSheet == nil else { return false }
        if bilibiliOpen, !bilibiliStore.editing {
            let store = bilibiliStore, player = store.player
            if player.current == nil {
                guard store.cardMenu == nil, !store.settingsOpen else { return false }
                return store.openCardMenu()
            }
            guard !player.panelVisible, !player.qualityMenuVisible, !player.relatedVisible else { return false }
            return player.openPanel()
        }
        if neteaseOpen, !neteaseStore.typing, neteaseStore.account != nil, neteaseStore.menu == nil {
            return neteaseStore.openCardMenu()
        }
        // 得到的播放界面：按住确认 = "⋯"菜单（倍速、定时关闭、讲目列表），同网易云
        if dedaoOpen { return dedaoStore.openPlayerMenu() }
        return false
    }

    /// 转盘这一格能不能走：只在焦点所在的这一排 / 这一列里走，不跨到别的区域（各应用自己判断）
    func wheelCanMove(_ direction: RemoteCommand.Direction) -> Bool {
        if activeSheet != nil { return true }
        if browserChromeUp { return browserStore.chromeCanMove(direction) }   // 浏览器的标签栏、"⋯"菜单
        if bilibiliOpen { return bilibiliStore.wheelCanMove(direction) }
        if neteaseOpen { return neteaseStore.wheelCanMove(direction) }
        if browserOpen, mode == .launcher { return browserStore.canMove(direction) }
        if dedaoOpen { return dedaoStore.canMove(direction) }
        return true
    }

    /// 转盘沿着哪个方向走：焦点所在的这一排是横的（首页那几排、顶栏、音质栏、播放列表、排序）还是竖的（菜单、左边栏、设置、歌单里的歌）
    func wheelRunsHorizontally() -> Bool {
        if activeSheet != nil { return false }   // 弹出的面板都是竖着一列
        if browserChromeUp { return browserStore.menu == nil }   // 浏览器的标签栏横着一排；"⋯"菜单竖着一列
        if bilibiliOpen { return bilibiliStore.wheelRunsHorizontally }
        if neteaseOpen { return neteaseStore.wheelRunsHorizontally }
        if browserOpen, mode == .launcher { return browserStore.startWheelRunsHorizontally }
        if dedaoOpen { return dedaoStore.wheelRunsHorizontally }
        return true                               // 主屏：一排图标
    }

    /// 长条里朝这个方向还有没有下一个。没有就停：一次滑动接着走的（第二格起、甩出去的惯性）不离开这一条
    func flickCanMove(_ direction: RemoteCommand.Direction) -> Bool {
        if browserChromeUp { return browserStore.chromeCanMove(direction) }
        if bilibiliOpen { return bilibiliStore.flickCanMove(direction) }
        if neteaseOpen { return neteaseStore.flickCanMove(direction) }
        if browserOpen, mode == .launcher { return browserStore.canMove(direction) }
        if dedaoOpen { return dedaoStore.canMove(direction) }
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
    /// The apps in the background, most recent first, and what each looked like when it went there (see AppQuit).
    @Published var backgroundApps: [Service] = []
    var appSnapshots: [String: NSImage] = [:]
    /// The last TV press: a second one from the same device soon after opens the App Switcher (see AppQuit).
    var lastTVPress: TVPress?
    /// TV standby: Mac TV turned the display off and paused everything (see Standby). Not macOS's own display sleep.
    @Published var standby = false
    /// macOS's memory pressure, while Mac TV runs (see memoryPressure)
    var memoryPressureSource: DispatchSourceMemoryPressure?
    /// A swipe on the screen saver so far (see handleScreensaver)
    var saverSwipe: (dx: Double, dy: Double) = (0, 0)
    /// ⌘Q is down, and Mac TV quits if it stays down (see AppQuit).
    var quitKeyHeld = false
    var quitKeyPresses = 0
    /// Quits Mac TV once ⌘Q has been held. A test puts in its own.
    var terminate: () -> Void = { NSApp.terminate(nil) }
    /// The Movies app's screen, while it's open.
    @Published var movies: MoviesBrowser?
    /// 哔哩哔哩的原生页面（自用分支）。这几个应用的数据是每个人（个人资料）各一份：
    /// 建它们之前 ProfileSpace.current 已经是在看的这个人（见 init），换人时各自重新读（见 ProfileApp）
    let bilibiliStore: BilibiliStore
    @Published var bilibiliOpen = false
    let neteaseStore: NeteaseStore
    @Published var neteaseOpen = false
    /// 浏览器的开始页开着（见 BrowserStore）
    @Published var browserOpen = false
    let browserStore: BrowserStore
    /// 得到（听书、课程）的原生页面开着（见 DedaoStore）
    @Published var dedaoOpen = false
    let dedaoStore: DedaoStore
    /// Who's watching: their apps and their sign-ins.
    @Published var profile: Profile
    /// Where each profile keeps its own things (see ProfileSpace).
    let spaces: ProfileSpaces
    /// The apps that keep their data per profile, told when someone else starts watching.
    let profileApps = ProfileAppRegistry()

    /// The focused button on Mac TV's own Brave screen.
    @Published var braveFocus = 0
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
    /// Brave in front (not in the background since Home).
    var externalBrowser: BraveSession? { playbackCoordinator.externalInBackground ? nil : playbackCoordinator.externalBrowser }
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
    /// The Mac app or Steam game opened from Mac TV is in front: remote presses go to it as keys.
    var frontAppTakesKeys: Bool {
        guard !NSApp.isActive, let front = NSWorkspace.shared.frontmostApplication else { return false }
        return front.bundleIdentifier == launchedAppID
            || (openedSteam && (front.bundleIdentifier == SteamLibrary.bundleID || front.processIdentifier == steamGamePID))
    }
    var pointer: CGPoint?
    /// 手机触控板的鼠标移动：摊到屏幕的每一帧里走（见 PointerGlide）
    lazy var pointerGlide = PointerGlide(move: { [weak self] dx, dy in self?.applyPointerMove(dx: dx, dy: dy) },
                                         ended: { [weak self] in self?.pointerStopped() })
    /// 上一次告诉界面"鼠标动了"是什么时候（见 applyPointerMove）
    var lastHoverEvent: CFTimeInterval = 0

    // MARK: - Lifecycle

    override convenience init() {
        let store = ProfileStore()
        self.init(library: AppLibrary(profileID: store.current.id), profiles: store, spaces: .live)
    }

    /// `spaces` is where each profile keeps its things: the real places for the app, and for a test (when
    /// it's left out) everything inside the library's folder.
    init(library: AppLibrary, profiles: ProfileStore? = nil, browserPreferences: BrowserPreferences? = nil,
         services appServices: AppServices = AppServices(), spaces: ProfileSpaces? = nil) {
        preferences = appServices.preferences
        movieLibrary = appServices.movieLibrary
        jellyfin = appServices.jellyfin
        networkShares = appServices.networkShares
        updater = appServices.updater
        feedback = appServices.feedback
        self.browserPreferences = browserPreferences ?? BrowserPreferences()
        let store = profiles ?? ProfileStore(folder: library.storageFolder)
        self.profiles = store
        self.profile = store.current
        self.library = library
        // Who's watching is settled before the apps read anything they keep per profile.
        let spaces = spaces ?? .sandbox(library.storageFolder)
        self.spaces = spaces
        ProfilePhotos.shared.spaces = spaces   // profile photos are in each profile's folder
        let space = spaces.enter(store.current.id)
        appServices.preferences.use(space)
        appServices.movieLibrary.use(space)
        bilibiliStore = BilibiliStore()
        neteaseStore = NeteaseStore()
        browserStore = BrowserStore(space: space)
        dedaoStore = DedaoStore()
        let pc = PlaybackCoordinator(jellyfin: appServices.jellyfin)
        let rc = RemoteCoordinator()
        rc.shortcutsProfileChanged(space)
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
        // 哔哩哔哩、网易云、得到、浏览器：每个人（个人资料）一份数据，换人时各自重新读（见 ProfileApp）
        bilibiliStore.player.onPlay = { [weak self] in self?.startedPlaying(BilibiliStore.appID) }
        dedaoStore.player.onPlay = { [weak self] in self?.startedPlaying(DedaoStore.appID) }
        profileApps.register(bilibiliStore)
        profileApps.register(neteaseStore)
        profileApps.register(dedaoStore)
        profileApps.register(browserStore)
    }

    // MARK: - Screensaver and sleep timer

    var screensaver: Bool { idleCoordinator.screensaver }
    var sleepAt: Date? { idleCoordinator.sleepAt }
    @discardableResult
    func noteActivity() -> Bool { idleCoordinator.noteActivity() }
    func noteInput() { idleCoordinator.noteInput() }
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
        // 手机触控板的鼠标（移动、点击）：在哪都是鼠标，哔哩哔哩、网易云里也一样，不交给应用当按键
        switch command {
        case .pointer(let dx, let dy): movePointer(dx: dx, dy: dy); return
        case .click: clickPointer(); return
        default: break
        }
        switch sheets.top {
        case .setup: handleSetup(command); return
        case .profilePicker: handleProfiles(command); return
        case .audioPicker: handleAudioPicker(command); return
        case .appSwitcher: handleAppSwitcher(command); return
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
        if browserOpen {
            browserStore.handle(command)
            return
        }
        if dedaoOpen {
            dedaoStore.handle(command)
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
            // As on Apple TV, Back on the top row's first app starts the screen saver. Anywhere else on Home, Back goes
            // to that app first, in one press, so pressing Back over and over always ends in the screen saver (Mac TV
            // decision: Apple documents the outcome, not the way there)
            if case .app(0) = focus { showScreensaver() } else { setFocus(.app(0)) }
        case .pointer(let dx, let dy): movePointer(dx: dx, dy: dy)
        case .click: clickPointer()
        case .playPause: toggleBackgroundAudio()
        default: break
        }
    }

    private var feedbackState: String {
        // 主屏顶部的轮播翻了一页也算走了一格（焦点还在"播放"上，但要有声音和震动）
        String(describing: (focus, sheets, movies, mode == .launcher)) + "\(appShelf.turns)"
            + (bilibiliOpen ? bilibiliStore.focusKey : "")
            + (neteaseOpen ? neteaseStore.focusKey : "")
            + (browserOpen ? browserStore.focusKey : "")
            + (dedaoOpen ? dedaoStore.focusKey : "")
    }

    // MARK: - Command Dispatch

    func handle(_ command: RemoteCommand, from source: Feedback.Source = .keyboard) {
        // 一个键的点一下 / 按住 / 松开（手机、Siri Remote、键盘、手柄都一样，见 PhonePresses）：换成具体的动作，再走下面同一条路
        if case .press(let key, let phase) = command {
            phonePresses.handle(key, phase, from: source)
            return
        }
        if source == .remote { noteRemoteConnection() }
        noteInput()
        // One input, one layer, in this order (docs/custom/interaction-spec.md, section 4): TV standby, the screen
        // saver, the system buttons, then the overlays, the app in front and Home.
        // 1. TV standby: Power, Back, TV and Select wake it, and that press does nothing else; the rest do nothing
        if standby {
            if command.wakesFromStandby { wakeFromStandby() }
            return
        }
        if source == .remote || source == .siriRemote, !command.entersStandby {
            RemoteActivity.note()   // someone is using the Mac (it keeps macOS from dimming the display)
            if displaysSleeping { wakeDisplays() }   // macOS dimmed it on its own: the press wakes it and acts too
        }
        // 2. The screen saver
        if screensaver {
            handleScreensaver(command, from: source)
            return
        }

        switch command {
        case .pointer, .click, .pointerHold, .scroll: break
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
                    else if dedaoOpen { dedaoStore.player.skip(forward ? 5 : -5) }
                }
                feedback.play(.move, from: source)
                return
            }
            let horizontal = wheelRunsHorizontally()
            let direction: RemoteCommand.Direction = horizontal ? (forward ? .right : .left) : (forward ? .down : .up)
            for _ in 0..<count {
                // 只在这一排 / 这一列里走，到头就停（转进左边栏、顶栏这些别的地方要按方向键）
                guard (mode != .launcher && !browserChromeUp) || wheelCanMove(direction) else { break }   // 浏览器的标签栏也到头就停
                handle(.move(direction), from: source)
            }
            return
        // 3. The system buttons, the same over everything (see AppQuit)
        case .home: pressTV(from: source); return
        case .goHome: holdBack(); return
        case .controlCenter: holdTV(); return
        case .power(let hold): if hold { enterStandby(reason: "Power held") }; return   // pressed while awake: nothing
        case .sleepNow: enterStandby(reason: "Sleep Now"); return
        case .swipe(let dx, let dy, let phase, let focusFollowsFinger):
            // 手机触控板上的双指滑动：和 Mac 触控板上滑一样（同一套门槛、惯性、声音）。
            // 点按区、Siri Remote 上的滑动也走这里，只是焦点跟着手指走（见 TrackpadGestures）。
            // 不归它管的地方（网页播放器里）就滚动网页，和以前一样
            let sample = TrackpadGestures.Sample(
                dx: dx, dy: dy,
                phase: ["began": .began, "changed": .changed, "ended": .ended][phase] ?? .none,
                momentum: phase == "momentum" ? .changed : (phase == "momentumEnd" ? .ended : .none),
                precise: true, focusFollowsFinger: focusFollowsFinger)
            if !trackpadGestures.feed(sample, from: source), phase == "changed" || phase == "momentum", dy != 0 {
                handle(.scroll(dy: -dy * 3), from: source)
            }
            return
        case .pointerHold:
            holdPointer()
            return
        case .longSelect:
            // 旧版手机页的按住 OK，和按住确认一样：在视频卡片、歌上是菜单，看视频时是右边的面板；
            // 菜单开着时再按住是收起；没有菜单可开的地方就是一次普通的确认
            if holdSelect(from: source) { return }
            handle(.select, from: source)
            return
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
            else { audioCoordinator.pressVolume(by: delta) }   // 系统调不了的输出：显示器的 DDC 或 Mac TV 自己的音量
            return
        case .mute:
            if playbackCoordinator.iinaOpen { playbackCoordinator.handleIINACommand(command) }
            else { audioCoordinator.pressMute() }
            return
        case .sleepTimer(let minutes): setSleepTimer(minutes: minutes); return
        case .shortcut(let id): runShortcut(id, from: source); return   // 手机遥控器上的快捷键（见 RemoteShortcuts）
        case .setting(let key, let value):
            if key == "autoSkip" { autoSkip = value }
            if key == "autoNext" { autoNext = value }
            if key == "keepMacAwake" { keepMacAwake = value }
            if key == "lidOverride" { lidOverride = value }
            return
        case .sleepMac:
            // The whole Mac, from Settings › System › Sleep Mac or the phone's Settings (each asks first). The remotes
            // can't wake it.
            goHome()
            SystemControl.sleepNow()
            return
        default: break
        }

        // 4. Overlays: a sheet over Home, an app or a web page takes the input (see ModalSheetRouter)
        if sheets.top != nil {
            handleInLauncherWithFeedback(command, from: source)
            return
        }

        if externalBrowser != nil {
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

        if frontAppTakesKeys {
            forwardToFrontApp(command)
            return
        }

        if source == .remote || source == .siriRemote || source == .controller, !NSApp.isActive {
            bringToFront()
        }

        switch mode {
        case .launcher: handleInLauncherWithFeedback(command, from: source)
        case .player(let service):
            if handleInBrowserChrome(command, from: source) { break }   // 浏览器网页：标签栏、"⋯"菜单，网页里的返回
            if !bilibiliStore.handleInPlayer(command, service: service), !neteaseStore.handleInPlayer(command, service: service) {
                playbackCoordinator.handleInPlayer(command, service: service)
            }
        case .movie: playbackCoordinator.handleInMovie(command)
        }
    }

    /// Mac TV's own screens (Home, its apps and sheets): the command, and its sound when it changed something.
    private func handleInLauncherWithFeedback(_ command: RemoteCommand, from source: Feedback.Source) {
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
        case .seek: feedback.play(.move, from: source)   // 快进 / 快退（滚轮、手柄的肩键）：轻快的"嗒"
        case .select: feedback.play(.select, from: source)
        case .back where changed: feedback.play(.back, from: source)
        default: break
        }
    }

    // MARK: - Opening & Home

    /// 按编号打开一个应用（和在主屏上选它一样，走 open：先关掉别的应用）
    func openApp(_ id: String) {
        guard let app = services.first(where: { $0.id == id }) ?? Catalog.services.first(where: { $0.id == id }) else { return }
        open(app)
    }

    /// Opens an app. What's in front goes to the background first, as the TV button sends it, and nothing else
    /// closes (see AppQuit): music and audio books keep playing until something else starts to (startedPlaying).
    func open(_ service: Service) {
        if appInFront != nil || mode != .launcher || movies != nil || playbackCoordinator.iinaOpen || externalBrowser != nil { goHome() }
        playbackCoordinator.resetPlaybackRequest()
        sheets.closeDismissible()
        switch service.id {
        case DedaoStore.appID: openDedao(); return
        case BrowserStore.appID: openBrowser(); return
        case BilibiliStore.appID: openBilibili(); return
        case NeteaseStore.appID: openNetease(); return
        default: break
        }
        switch service.kind {
        case .web(let url):
            // In the background since Home: back to it as it was.
            if !playbackCoordinator.resumeParkedWeb(service), !playbackCoordinator.resumeExternalBrowser(service) {
                playbackCoordinator.playWeb(service, url: url)
            }
        case .app(let bundleID):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
                  SystemGuard.allows("open \(bundleID)") else { return }
            launchedAppID = bundleID
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        case .steam(let appID):
            SystemGuard.open(SteamLibrary.launchURL(for: appID))
            openedSteam = true
            if appID != SteamLibrary.bigPicture.appID { watchForSteamGame() }
        case .movies:
            if !playbackCoordinator.resumeMovies() { openMovies() }
        case .addApp:
            adder = AppAdder()
        case .settings:
            openSettings()
        }
    }

    /// The Home Screen, from the TV button, holding Back, or Back at an app's top level: the app in front goes to the
    /// background, as on Apple TV (see AppQuit). Apps quit from the App Switcher.
    func goHome() {
        noteAppInBackground()   // before anything changes, while it still shows (see AppQuit)
        playbackCoordinator.resetPlaybackRequest()   // a movie or page still opening doesn't open
        playbackCoordinator.sendToBackground(movies: movies)
        movies = nil
        sendAppsToBackground()
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
            && !nativePlaybackActive
    }

    /// 哔哩哔哩、网易云、得到自己的播放器正在放（屏保底下、显示器睡着时也可能在放歌、放书）
    var nativePlaybackActive: Bool {
        bilibiliStore.player.blocksScreensaver
            || (neteaseStore.current != nil && !neteaseStore.paused)
            || (dedaoStore.player.current != nil && !dedaoStore.player.paused)
    }

    /// 主屏上按播放 / 暂停：后台在放的网易云、得到停下或接着放
    private func toggleBackgroundAudio() {
        if neteaseStore.current != nil { neteaseStore.toggleFromHome() }
        else if dedaoStore.player.current != nil { dedaoStore.player.togglePause() }
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
        if !setWebsitePlayer(next.rawValue) { showToast("Brave Browser Isn't Installed") }
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
        startSiriRemote()
    }

    func showControllerNotice(_ notice: ControllerNotice) { notices.showController(notice) }

    func showToast(_ text: String) { notices.showToast(text) }
}
