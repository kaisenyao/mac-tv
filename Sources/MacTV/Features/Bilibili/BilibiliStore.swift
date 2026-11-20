import AppKit
import Combine
import SwiftUI
import WebKit

/// 哔哩哔哩原生页面的状态：左边栏的几页、每一页的几排内容、焦点位置、登录情况。
///
/// 结构学的是 Apple TV 自家的应用：左边一列导航，右边是一排排大卡片。
/// 首页是继续观看、推荐、热门和几个榜单；关注、直播、我的各是一页，搜索单独一页。
@MainActor
final class BilibiliStore: ObservableObject {
    static let appID = "bilibili"
    static let loginID = "bilibili-login"

    enum Tab: String, CaseIterable, Identifiable {
        case search, home, following, live, mine
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .search: "magnifyingglass"
            case .home: "house.fill"
            case .following: "person.2.fill"
            case .live: "dot.radiowaves.left.and.right"
            case .mine: "person.crop.circle.fill"
            }
        }
        var title: String {
            switch self {
            case .home: "首页"
            case .following: "动态"
            case .live: "直播"
            case .mine: "我的"
            case .search: "搜索"
            }
        }
    }

    /// 卡片排里的一项
    enum Item: Hashable {
        case video(BiliVideo)
        /// 一个 UP 主（搜索结果里），按确认进他的主页
        case user(BiliUser)
        /// 没登录时占位的"登录"（打开登录页）、没有关注时的"刷新"
        case login, refresh
        /// 这一排暂时没有内容时占位的一张卡片，只显示一句话，按了没反应
        case empty(String)
        /// 搜索页下面：一个搜过的词、一条热搜、"清空"搜索历史
        case keyword(String)
        case trend(BiliTrend)
        case clearHistory

        /// 内容刷新后按它找回原来选中的那一项（视频的播放数、进度会变，不能整个比）
        var id: String {
            switch self {
            case .video(let video): "video-\(video.bvid)"
            case .user(let user): "user-\(user.mid)"
            case .login: "login"
            case .refresh: "refresh"
            case .empty(let text): "empty-\(text)"
            case .keyword(let word): "keyword-\(word)"
            case .trend(let trend): "trend-\(trend.keyword)"
            case .clearHistory: "clear-history"
            }
        }
    }

    /// 右上角头像菜单里的一项
    enum AccountAction: Hashable {
        /// 没登录、有登录过的账号时，账号列表下面的"登录其他账号"（打开登录页）
        case login
        case refresh, settings, logout
        /// "切换账号"：菜单换成登录过的账号列表；选一个就换过去，"添加账号"登录一个新的
        case switchAccount, useAccount(Int), addAccount
        /// 退出登录的确认：先问一次，默认停在"取消"上
        case keepLogin, confirmLogout
    }

    /// 头像菜单的哪一层：平常那几项、登录过的账号列表、退出登录的确认
    enum AccountMenu: Hashable { case main, accounts, confirmLogout }

    /// 焦点在哪。同一时刻只在一处（以前是好几个各管各的开关，会凑出"搜索框和卡片同时选中"这样不可能的组合）
    enum Focus: Hashable {
        /// 下面的卡片排。在 UP 主的主页里是三个排序或下面的视频（看 UpPage.browsing）
        case rows
        /// 左边栏（在最左一张卡片上再按左）
        case sidebar
        /// 右上角的头像（在最上面一排再按上），以及它下面打开的菜单
        case account
        case accountMenu(AccountMenu)
        /// 搜索框：选中了还没打字 / 正在输入（键盘交给输入框，这样中文输入法才能用）
        case searchField
        case typing
        /// 设置页（头像菜单里的"设置"）
        case settings
        /// 视频卡片上长按确认弹出的小菜单
        case cardMenu
        /// 搜索页上选了"清空"：从它长出来的那张问一句的小卡片（取消 / 清空）
        case clearConfirm
        /// UP 主主页上的关注按钮
        case follow
    }

    struct Row: Identifiable, Hashable {
        let id: String
        let title: String
        var items: [Item]
    }

    @Published private(set) var tab: Tab = .home
    @Published private(set) var focus: Focus = .rows {
        didSet {
            guard focus != oldValue else { return }
            // 离开输入框：键盘还给页面
            if oldValue == .typing { tv?.window?.makeFirstResponder(nil) }
            // 离开关注按钮："再按一次取消关注"作废；到了关注按钮上，上半屏是 UP 主的头像和排序（不是视频的标题）
            if oldValue == .follow { upPage?.armed = false }
            if focus == .follow { upPage?.browsing = false }
            if case .accountMenu(let level) = focus { accountMenuShown = level }
        }
    }
    /// 头像菜单最近一次开着的是哪一层：收起的动画里还照它画，不会在收起的途中变成另外几项
    private var accountMenuShown = AccountMenu.main
    /// 头像菜单里选中了第几项
    @Published private(set) var accountIndex = 0
    /// 头像菜单里现在的几项（菜单一直画着，收着时是收起之前的那几项）
    var accountActions: [AccountAction] {
        let menu: AccountMenu = if case .accountMenu(let level) = focus { level } else { accountMenuShown }
        switch menu {
        case .accounts: return savedAccounts.map { .useAccount($0.mid) } + [.addAccount]
        case .confirmLogout: return [.keepLogin, .confirmLogout]
        case .main:
            // 没登录：登录过的账号（点一下直接换过去），下面一项"登录其他账号"。
            // 一个登录过的账号都没有时不出菜单，选头像直接打开登录页（见 openAccount）
            guard account != nil else { return savedAccounts.map { .useAccount($0.mid) } + [.login] }
            return [.refresh, .switchAccount, .settings, .logout]
        }
    }
    /// 选头像（确认键、触控板点一下）：没登录、也没有登录过的账号时直接打开登录页，不先出一个只有一项的菜单
    var accountOpensLogin: Bool { account == nil && savedAccounts.isEmpty }
    /// 测试用：当作登录过的是这几个账号（不碰钥匙串和本机设置）
    func pretendSavedAccounts(_ accounts: [BiliSavedAccount]) { savedAccounts = accounts }
    /// 登录过的账号（名字、头像；登录信息在钥匙串里，见 BiliAccounts）
    @Published private(set) var savedAccounts = BiliAccounts.list()
    /// 左边栏里藏起来的几页（设置里的"左边栏显示"；首页一直都在）
    @Published private(set) var hiddenTabs = BiliSidebar.hidden
    /// 左边栏里显示的几页，按顺序
    var visibleTabs: [Tab] { Tab.allCases.filter { !hiddenTabs.contains($0) } }

    // 给页面用的几个问法，都从 focus 来
    var sidebarFocused: Bool { focus == .sidebar }
    /// 头像亮着：选中了它，或者它下面的菜单开着
    var accountFocused: Bool { focus == .account || accountMenuOpen }
    var accountMenuOpen: Bool { if case .accountMenu = focus { true } else { false } }
    var searchFocused: Bool { focus == .searchField }
    var editing: Bool { focus == .typing }
    var settingsOpen: Bool { focus == .settings }
    var cardMenu: [CardAction]? { focus == .cardMenu ? cardMenuActions : nil }
    var clearConfirmOpen: Bool { focus == .clearConfirm }
    var followFocused: Bool { focus == .follow }
    /// UP 主页上，焦点在三个排序上
    var sortFocused: Bool { focus == .rows && upPage.map { !$0.browsing } == true }

    /// 正在看的某个 UP 主的主页（从搜索结果或卡片菜单进来）。它盖在当前这一页上，按 Esc 回去。
    /// 关注按钮在页面上方、名字旁边（第一排再按上才到），不放在视频那一排里，免得误触。
    /// 进来时焦点在三个排序上（最新发布 / 最多播放 / 最多收藏），上面是头像和关注；
    /// 往下到了视频（browsing），上半屏就和别的页一样换成视频的大标题。
    struct UpPage {
        enum Sort: Int, CaseIterable {
            case latest, plays, favorites
            var title: String { ["最新发布", "最多播放", "最多收藏"][rawValue] }
            var order: String { ["pubdate", "click", "stow"][rawValue] }
        }
        var user: BiliUser
        var following = false
        var rows: [Row] = []
        var row = 0
        var loading = true
        var sort = Sort.latest
        /// 往下到了视频那一排（焦点在卡片排上时：false 是在三个排序上）
        var browsing = false
        /// 取到过的几种排法（取失败的不记，下次换过去再取）
        var lists: [Sort: [BiliVideo]] = [:]
        /// 已经在关注按钮上按过一次"取消关注"，再按一次才真的取消
        var armed = false
        /// 从看视频时右边的面板进来的：返回时回到这个视频（带着刚才看到的位置）接着放
        var returnTo: BiliVideo?
        /// 他现在正在直播：这一排最前面放他的直播间（从看过的直播进来，能直接接着看）
        var live: BiliVideo?
    }
    @Published private(set) var upPage: UpPage? {
        didSet {
            // 主页收起来了：焦点不能还停在它的关注按钮上
            if upPage == nil, focus == .follow { focus = contentFocus }
        }
    }

    /// 在视频卡片上长按确认弹出的小菜单
    enum CardAction: Hashable { case upPage, favorite, watchLater }
    /// 菜单里有哪几项、选中了第几项（只在 focus 是 .cardMenu 时有意义）
    @Published private(set) var cardMenuActions: [CardAction] = []
    @Published private(set) var cardMenuIndex = 0
    /// 菜单是为哪个视频打开的（执行时用它，不用"当前焦点"，免得列表在后台刷新后加错视频）
    private var cardMenuVideo: BiliVideo?
    private var emptyPages: [String: Int] = [:]
    private var signingKey: (key: String, at: Date)?
    @Published var query = ""
    @Published private(set) var content: [Tab: [Row]] = [:]
    @Published private(set) var rowIndex: [Tab: Int] = [:]
    @Published private(set) var columns: [String: Int] = [:]
    @Published private(set) var loadingTabs: Set<Tab> = []
    @Published private(set) var failedTabs: Set<Tab> = []
    @Published private(set) var account: BiliAccount?
    /// 每次清掉登录（退出、切换账号、换了 Mac TV 的用户）就加一。在路上的请求回来时对一下：
    /// 不一样了就是上一个账号的东西，扔掉，不写进页面、不记到别的账号名下
    private var loginEpoch = 0

    weak var tv: TVController? { didSet { wirePlayer() } }
    // MARK: 交互区域（规则见 TVController.Module）

    func module(horizontal: Bool) -> TVController.Module {
        if player.current != nil {
            // 右边的面板（长按确认拉出来）：是从右边拉出来的抽屉，往右滑推回去；在里面上下挑一行
            if player.panelVisible { return horizontal ? .drawer : .picker }
            // 播放中：上下拉出清晰度栏（往下）/ 相关视频（往上）。左右：相关视频是长条；
            // 清晰度栏是挑一个；平时左右是拖进度（进度条跟着手走，往右滑往前）
            guard horizontal else { return .drawer }
            if player.relatedVisible { return .strip }
            return player.qualityMenuVisible ? .picker : .scrub
        }
        // 登录页：左边的二维码、右边表单里固定的几样，两个方向都是挑一个
        if login != nil { return .picker }
        // 头像、搜索框的上下跟着它们下面那一块走（一去一回方向相反）：下面是搜索页的搜索历史和热搜（光标）时，
        // 往上滑上去、往下滑回来；下面是视频排（内容跟着手走）时，往下滑上去、往上滑回来
        let aboveContent: TVController.Module = showingLanding ? .picker : .drawer
        switch focus {
        case .typing: return horizontal ? .off : aboveContent
        case .searchField: return horizontal ? .picker : aboveContent   // 搜索框：一个固定的东西
        case .settings: return horizontal ? .off : .picker               // 设置：固定的几行
        case .cardMenu, .accountMenu, .clearConfirm: return .picker       // 菜单：固定的几项
        // 左边栏是从左边拉出来的抽屉（像 Mac 右边的通知中心）：往右滑拉出来，往左滑推回去，再往右滑不动；
        // 在里面上下是挑一项（光标）
        case .sidebar: return horizontal ? .drawer : .picker
        // 右上角头像、UP 主页的关注按钮：往右滑是把左边栏拉出来；上下见上面（关注按钮下面是三个排序，和视频排一样）
        case .account: return horizontal ? .drawer : aboveContent
        case .follow: return .drawer
        case .rows:
            // UP 主页的三个排序：左右是挑一个；上下和视频排一样（往下滑上到关注按钮）
            if sortFocused { return horizontal ? .picker : .drawer }
            // 搜索页的搜索历史和热搜：选项不动、白色高亮在动，两个方向都是挑一个
            if showingLanding { return .picker }
            return horizontal ? .strip : .drawer                                    // 视频排：横着是长条，上下换排
        }
    }

    func flickCanMove(_ direction: RemoteCommand.Direction) -> Bool {
        if player.current != nil {
            guard player.relatedVisible else { return false }
            let (index, count) = player.shelf == .episodes ? (player.episodeFocus, player.episodes.count)
                : (player.relatedIndex, player.related.count)
            switch direction {
            case .left: return index > 0
            case .right: return index < count - 1
            default: return false
            }
        }
        guard login == nil, focus == .rows, !sortFocused, rows.indices.contains(row) else { return false }
        switch direction {
        // 到第一张就停，不进左边栏；热搜是一条接一条的（1 到 10），在一排的两头也能接着走
        case .left: return column > 0 || (isHotRow(row) && isHotRow(row - 1))
        case .right: return column < rows[row].items.count - 1 || (isHotRow(row) && isHotRow(row + 1))
        default: return false
        }
    }
    /// 原生播放器：直接取流，不经过网页
    let player = BilibiliNativePlayer()
    private var playerChanges: AnyCancellable?
    private var loadedAt: [Tab: Date] = [:]
    /// 开着的登录页（盖在列表上面，见 BilibiliLoginScreen）。开着时按键都给它
    @Published private(set) var login: BiliLoginPage?
    /// 扫码登录用的接口（测试里换成假的）
    var qrService: BiliQRService = BiliQRWeb()
    /// 能一直往后翻的排（推荐、热门、搜索结果）：已经取到第几页、是否正在取、是否到头了
    private var pages: [String: Int] = [:]
    private var fetchingMore: Set<String> = []
    private var exhausted: Set<String> = []
    private var lastKeyword = ""
    private var cookieWaker: WKWebView?

    var rows: [Row] { upPage?.rows ?? content[tab] ?? [] }
    var row: Int { min(upPage?.row ?? rowIndex[tab] ?? 0, max(0, rows.count - 1)) }

    private func setRow(_ value: Int) {
        if upPage != nil { upPage?.row = value } else { rowIndex[tab] = value }
    }
    var loading: Bool { upPage?.loading ?? (loadingTabs.contains(tab) && (content[tab] ?? []).isEmpty) }
    var failed: Bool { failedTabs.contains(tab) }
    var column: Int { rows.indices.contains(row) ? column(of: rows[row]) : 0 }
    /// 这一排选中的是第几个（内容被刷新变短时不会越界）
    func column(of row: Row) -> Int { max(0, min(columns[row.id] ?? 0, row.items.count - 1)) }
    /// 焦点所在的那张卡片（焦点在卡片排上才有；UP 主页上要往下到了视频那一排）
    var focused: Item? {
        guard focus == .rows, !sortFocused else { return nil }
        return highlighted
    }
    /// 当前这一排选中的那一项，不管焦点是不是暂时去了左边栏（上半屏的标题和背景用它，免得一开栏就换内容）
    var highlighted: Item? {
        guard rows.indices.contains(row), rows[row].items.indices.contains(column) else { return nil }
        return rows[row].items[column]
    }
    /// 回到右边的内容时焦点去哪：搜索页上还没有内容（只有一个搜索框）就停在搜索框上
    private var contentFocus: Focus { tab == .search && upPage == nil && rows.isEmpty ? .searchField : .rows }
    /// 看起来焦点在哪：刚按了搜索、结果还没出来时，焦点已经在（还空着的）结果上，看起来选中的还是搜索框
    var shownFocus: Focus { focus == .rows && contentFocus == .searchField ? .searchField : focus }
    /// 给按键音和震动用：看得见的焦点动了一格，它就变一次（走不动、看不出变化时不变，不出声）
    var focusKey: String {
        "\(tab.rawValue)-\(shownFocus)-\(row)-\(column)-\(rows.count)-\(player.current?.bvid ?? "")"
            // 播放器里的清晰度栏、底下那排视频也算：在里面左右走才有按键声
            + "-\(player.qualityMenuVisible)-\(player.qualityIndex)-\(player.relatedVisible)-\(player.relatedIndex)"
            + "-\(player.panelVisible)-\(player.panelIndex)-\(String(describing: player.panelList))-\(player.panelListIndex)"
            + "-\(player.shelf)-\(player.episodeFocus)"
            + "-\(settingIndex)-\(String(describing: settingList))-\(settingListIndex)-\(accountIndex)-\(cardMenuIndex)"
            + "-\(clearChoice.rawValue)"
            // 左边栏的高亮（上下滑时先动它，停一下才换页）、UP 主页的排序、往下到没到视频
            + "-\(sidebarTab.rawValue)-\(upPage?.sort.rawValue ?? -1)-\(upPage?.browsing ?? false)"
            // 看视频时键盘左右是快进快退十秒：进度也算，这样每一下都有声音
            + "-\(Int(player.time))"
            // 登录页：在二维码和表单之间、表单里走一格
            + "-\(login?.focusKey ?? "")"
    }

    private func wirePlayer() {
        player.cookie = { [weak self] in await self?.cookieHeader() ?? "" }
        player.cookieOfNow = { [weak self] in self?.cookieSource() ?? { "" } }
        player.toast = { [weak self] text in self?.tv?.showToast(text) }
        player.keepAwake = { [weak self] on in
            if on { self?.tv?.displayCoordinator.holdPlaybackKeepAwake(reason: "在 Mac TV 里看哔哩哔哩") }
            else { self?.tv?.displayCoordinator.releasePlaybackKeepAwake() }
        }
        player.noteActivity = { [weak self] in _ = self?.tv?.noteActivity() }
        player.accountMid = { [weak self] in self?.account?.mid ?? 0 }
        player.signingKey = { [weak self] in
            guard let self else { return nil }
            return await self.currentSigningKey(cookie: await self.cookieHeader())
        }
        // 面板里的"UP 主"、点标题下面的名字：关掉视频（记下看到哪了），进他的主页；在主页上返回，回到这个视频停在那一帧
        player.openUp = { [weak self] user, video in
            guard let self else { return }
            self.player.stop()
            self.openUp(user, returnTo: video)
        }
        // 播放器开关时让页面跟着刷新；看完后"继续观看"和"历史记录"要更新
        playerChanges = player.$current.removeDuplicates().dropFirst().sink { [weak self] video in
            guard let self else { return }
            self.objectWillChange.send()
            if video == nil {
                self.loadedAt[.home] = nil
                self.loadedAt[.mine] = nil
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    if self.tab == .home || self.tab == .mine { self.load(self.tab) }
                }
            }
        }
    }

    // MARK: 载入

    func opened() { preload() }

    /// 把每一页的内容都提前取好（应用启动时、每次进哔哩哔哩时）。
    /// 已经有内容的页先照旧显示，后台悄悄换成新的，所以切换左边栏时不用等。
    func preload() {
        for tab in visibleTabs where isStale(tab) { load(tab) }   // 左边栏里藏起来的页不取
        if !hiddenTabs.contains(.search), content[.search]?.isEmpty ?? true { showLanding() }
    }

    // MARK: 搜索页：搜索历史、热搜

    private var trends: [BiliTrend] = []
    private var trendsAt = Date.distantPast
    /// 测试用：当作热搜刚取过、就是这几条（搜索页不去联网）
    func pretendTrends(_ list: [BiliTrend]) { trends = list; trendsAt = Date() }

    /// 清空搜索历史之前问的那一句里的两项："取消"在上面，打开时停在它上面
    enum ClearChoice: Int { case cancel, clear }
    @Published private(set) var clearChoice = ClearChoice.cancel

    /// 这一排是热搜（两条一排，按 1、2、3……的顺序左右走）
    private func isHotRow(_ index: Int) -> Bool {
        showingLanding && rows.indices.contains(index) && rows[index].id.hasPrefix("hot-")
    }

    /// 搜索页现在摆的是搜索历史和热搜（不是搜索结果）
    var showingLanding: Bool {
        tab == .search && upPage == nil && (content[.search]?.first.map { Self.isLandingRow($0.id) } ?? false)
    }

    private static func isLandingRow(_ id: String) -> Bool { id == "search-history" || id.hasPrefix("hot-") }

    /// 搜索历史一排（最近的六个，后面一个"清空"），热搜两列五行。热搜十分钟内取过就不再取
    func showLanding() {
        replaceRows(landingRows(), for: .search)
        guard Date().timeIntervalSince(trendsAt) > 600 else { return }
        Task { @MainActor in
            let found = await BiliAPI.trending(cookie: await self.cookieHeader())
            guard !found.isEmpty else { return }
            self.trends = found
            self.trendsAt = Date()
            // 搜索页上摆的还是搜索历史和热搜（不是搜索结果，也不是正在搜）：换上新的热搜
            let rows = self.content[.search] ?? []
            guard !self.loadingTabs.contains(.search), rows.first.map({ Self.isLandingRow($0.id) }) ?? true else { return }
            self.replaceRows(self.landingRows(), for: .search)
        }
    }

    private func landingRows() -> [Row] {
        var rows: [Row] = []
        let history = Array(BiliSearchHistory.all.prefix(6))
        if !history.isEmpty { rows.append(Row(id: "search-history", title: "搜索历史", items: history.map(Item.keyword) + [.clearHistory])) }
        let hot = Array(trends.prefix(10))
        for start in stride(from: 0, to: hot.count, by: 2) {
            rows.append(Row(id: "hot-\(start / 2)", title: start == 0 ? "热搜" : "", items: hot[start..<min(start + 2, hot.count)].map(Item.trend)))
        }
        return rows
    }

    private func isStale(_ tab: Tab) -> Bool {
        tab != .search && Date().timeIntervalSince(loadedAt[tab] ?? .distantPast) > 600
    }

    /// 重新取。登录信息也重新读（刚在登录页登录完、刚换了账号，记着的那份已经不对了）。
    /// byUser：人自己按的"刷新"，没取到时说一声（后台刷新不说）
    func reload(byUser: Bool = false) {
        forgetCookies()
        loadedAt = [:]
        load(tab == .search ? .home : tab, byUser: byUser)
    }

    private func load(_ target: Tab, byUser: Bool = false) {
        guard target != .search, !loadingTabs.contains(target) else { return }
        loadingTabs.insert(target)
        failedTabs.remove(target)
        let epoch = loginEpoch
        Task { @MainActor in
            let jar = await cookieJar()
            let cookie = jar.header
            // 账号信息和内容一起取，不排队；只有第一次（还不知道是谁）才先等它
            async let me = BiliAPI.account(cookie: cookie)
            let known = self.account
            var account = known
            if known == nil {
                let answer = await me
                guard epoch == self.loginEpoch else { return }
                if case .signedIn(let fresh) = answer { self.adopt(fresh, cookies: jar.cookies); account = fresh }
            }
            var built: [Row] = []
            func add(_ id: String, _ title: String, _ videos: [BiliVideo]) {
                if !videos.isEmpty { built.append(Row(id: id, title: title, items: videos.map(Item.video))) }
            }
            switch target {
            case .home:
                // 首页：继续观看、推荐、热门，接着是原来"发现"里的排行榜、每周必看、入站必刷
                async let recent = BiliAPI.history(cookie: cookie)
                async let picks = BiliAPI.recommended(cookie: cookie)
                async let hot = BiliAPI.popular(cookie: cookie)
                async let ranked = BiliAPI.ranking(cookie: cookie)
                async let week = BiliAPI.weekly(cookie: cookie)
                async let best = BiliAPI.classics(cookie: cookie)
                let (history, recommended, popular) = await (recent, picks, hot)
                let (ranking, weekly, classics) = await (ranked, week, best)
                // 历史记录不带播放数：给"继续观看"最前面的几个补上（补不到就不显示，不影响别的）
                // 继续观看只放视频（看过的直播间在"我的"那页的历史记录里）
                var unfinished = history.filter { $0.progress != -1 && !$0.isRoom }
                if let key = await currentSigningKey(cookie: cookie) {
                    let head = Array(unfinished.prefix(8))
                    let counts = await withTaskGroup(of: (String, Int).self) { group in
                        for video in head {
                            group.addTask { (video.bvid, await BiliAPI.views(bvid: video.bvid, key: key, cookie: cookie)) }
                        }
                        var all: [String: Int] = [:]
                        for await (bvid, count) in group { all[bvid] = count }
                        return all
                    }
                    for index in unfinished.indices { if let count = counts[unfinished[index].bvid], count > 0 { unfinished[index].views = count } }
                }
                add("continue", "继续观看", unfinished)
                add("recommended", "推荐", recommended)
                add("popular", "热门", popular)
                add("ranking", "排行榜", ranking)
                add("weekly", "每周必看", weekly)
                add("classics", "入站必刷", classics)
            case .following:
                // 每个关注的 UP 主一排（全部都有，不管最近更没更新），谁最近更新谁在前
                let people = await BiliAPI.followings(mid: account?.mid ?? 0, cookie: cookie)
                if !people.isEmpty, let key = await currentSigningKey(cookie: cookie) {
                    var results: [(Int, String, [BiliVideo], Int)] = []
                    // 一次最多同时取 5 个人的，取太猛会被风控，结果是某些人的那一排悄悄不见
                    let list = Array(people.prefix(40))
                    for start in stride(from: 0, to: list.count, by: 5) {
                        let batch = Array(list[start..<min(start + 5, list.count)])
                        let part = await withTaskGroup(of: (Int, String, [BiliVideo], Int).self) { group in
                            for person in batch {
                                group.addTask {
                                    let uploads = await BiliAPI.uploads(mid: person.mid, name: person.name, key: key, cookie: cookie)
                                    return (person.mid, person.name, uploads.videos, uploads.latest)
                                }
                            }
                            var all: [(Int, String, [BiliVideo], Int)] = []
                            for await result in group { all.append(result) }
                            return all
                        }
                        results += part
                    }
                    for result in results.sorted(by: { $0.3 > $1.3 }) { add("up-\(result.0)", result.1, result.2) }
                }
                if built.isEmpty {
                    built.append(Row(id: "following-empty", title: account == nil ? "登录后查看" : "暂无关注",
                                     items: account == nil ? [.login] : [.refresh]))
                }
            case .live:
                // 直播：关注的主播里正在播的（登录后），再是推荐直播和各分区正热的
                async let mine = BiliAPI.liveFollowing(cookie: cookie)
                async let index = BiliAPI.liveIndex(cookie: cookie)
                let (following, areas) = await (mine, index)
                add("live-following", "关注的主播", following)
                for (index, area) in areas.enumerated() { add("live-\(index)", area.title, area.rooms) }
            case .mine:
                async let recent = BiliAPI.history(cookie: cookie, count: 30)
                async let saved = BiliAPI.favorites(mid: account?.mid ?? 0, cookie: cookie)
                async let later = BiliAPI.watchLater(cookie: cookie)
                let (history, favorites, watchLater) = await (recent, saved, later)
                // 历史记录：看过的视频和直播间。直播间在播的直接进去看，没在播的写"未开播"、选它进主播的主页
                add("history", "历史记录", history)
                // 收藏：每个收藏夹一排。"收藏"这一栏登录后一直都在，里面还没有东西时放一张占位卡片说明
                let filled = favorites.filter { !$0.videos.isEmpty }
                for (index, folder) in filled.enumerated() {
                    add("favorites-\(index)", filled.count == 1 && folder.title == "默认收藏夹" ? "收藏" : "收藏 · \(folder.title)", folder.videos)
                }
                if filled.isEmpty, account != nil {
                    built.append(Row(id: "favorites-empty", title: "收藏", items: [.empty("暂无收藏")]))
                }
                add("later", "稍后再看", watchLater)
                // 账号的操作在右上角头像里；没登录时这里留一个入口，免得这一页是空的
                if account == nil { built.append(Row(id: "account", title: "登录后查看", items: [.login])) }
            case .search: break
            }
            var signedOut = false
            if known != nil {
                // 顺便更新登录状态。确实没登录了（在别处退出、过期了）才算没登录，别的页下次进去也重新取；
                // 问不到不等于没登录（可能只是网络抖了一下），保持原样
                let answer = await me
                guard epoch == self.loginEpoch else { return }
                switch answer {
                case .signedIn(let fresh): self.adopt(fresh, cookies: jar.cookies)
                case .signedOut:
                    self.account = nil
                    self.loadedAt = [:]
                    signedOut = true
                case .unknown: break
                }
            }
            guard epoch == self.loginEpoch else { return }   // 取的途中退出、换了账号：这些是上一个账号的
            self.loadingTabs.remove(target)
            if !signedOut, Self.hasVideos(self.content[target] ?? []), !Self.hasVideos(built) {
                // 刷新什么都没取到（多半是网络抖了一下）：原来的留着，下次进来再取
                if byUser, self.tv?.bilibiliOpen == true, self.tab == target, self.upPage == nil { self.tv?.showToast("无法刷新") }
            } else {
                if target == .home {   // 首页重新取过，翻页从头算
                    for id in ["recommended", "popular"] { self.pages[id] = 1; self.exhausted.remove(id) }
                }
                // 第一次取到：一排排渐渐出来；后台刷新：原地换上，不动
                let first = (self.content[target] ?? []).isEmpty
                withAnimation(first ? Motion.navigate : nil) { self.replaceRows(built, for: target) }
                if built.isEmpty { self.failedTabs.insert(target) } else { self.loadedAt[target] = Date() }
            }
            self.warmFocused()
        }
    }

    private static func hasVideos(_ rows: [Row]) -> Bool {
        rows.contains { $0.items.contains { if case .video = $0 { true } else { false } } }
    }

    /// 换上新取到的几排。焦点留在原来那一排、原来那一项上：按编号找，不按第几排第几个
    /// （新内容里排的顺序、个数可能变了，比如刚看过的视频挪到了"继续观看"的最前面）
    private func replaceRows(_ rows: [Row], for target: Tab) {
        let old = content[target] ?? []
        let at = min(rowIndex[target] ?? 0, max(0, old.count - 1))
        let focusedRow = old.indices.contains(at) ? old[at] : nil
        let focusedItem = focusedRow.flatMap { row in row.items.isEmpty ? nil : row.items[column(of: row)] }
        content[target] = rows
        guard let focusedRow, let index = rows.firstIndex(where: { $0.id == focusedRow.id }) else {
            rowIndex[target] = min(at, max(0, rows.count - 1))
            return
        }
        rowIndex[target] = index
        if let focusedItem, let column = rows[index].items.firstIndex(where: { $0.id == focusedItem.id }) {
            columns[focusedRow.id] = column
        }
    }

    /// 请求签名用的密钥，半小时内重复用同一个
    private func currentSigningKey(cookie: String) async -> String? {
        if let cached = signingKey, Date().timeIntervalSince(cached.at) < 1800 { return cached.key }
        let epoch = loginEpoch
        guard let key = await BiliAPI.signingKey(cookie: cookie) else { return nil }
        if epoch == loginEpoch { signingKey = (key, Date()) }
        return key
    }

    // MARK: 登录信息（cookie）

    /// 读到的哔哩哔哩 cookie：原样的（记账号时存进钥匙串）和拼好的请求头（带给请求）
    private struct CookieJar {
        var cookies: [HTTPCookie] = []
        var header: String { cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ") }
    }

    /// 读到的登录信息记一会儿：每个请求都去问网页那边要，既慢又要一直开着一个隐形网页
    private var cookieCache: (jar: CookieJar, at: Date)?
    /// 每次作废记着的登录信息就加一：作废之前就开始读的，读回来也不再记（读到的可能是作废之前的样子）
    private var cookieGeneration = 0

    private func forgetCookies() {
        cookieCache = nil
        cookieGeneration += 1
    }

    private func cookieHeader(fresh: Bool = false) async -> String { await cookieJar(fresh: fresh).header }

    /// 现在这个人的登录信息，绑在他身上（他的网页数据）：过一会儿才发的请求（停下时报看到哪了），
    /// 中间换了人，带的也还是他的
    private func cookieSource() -> () async -> String {
        if let cached = cookieCache, Date().timeIntervalSince(cached.at) < 600 {
            let header = cached.jar.header
            return { header }
        }
        guard let store = tv?.profile.websiteDataStore.httpCookieStore else { return { "" } }
        return { CookieJar(cookies: (await store.allCookies()).filter(\.isBilibili)).header }
    }

    /// 登录状态存在这个应用自己的网页数据里（和内置网页共用）；这里只把哔哩哔哩的那几个带给请求。
    /// fresh = 不用记着的，现在去读（等登录、换账号时用）
    private func cookieJar(fresh: Bool = false) async -> CookieJar {
        if !fresh, let cached = cookieCache, Date().timeIntervalSince(cached.at) < 600 { return cached.jar }
        guard let profile = tv?.profile else { return CookieJar() }
        let generation = cookieGeneration
        let store = profile.websiteDataStore.httpCookieStore
        var cookies = await store.allCookies()
        if cookies.isEmpty {
            // WebKit 的 cookie 仓库是懒加载的：这次启动后还没开过任何网页时，它会回答"一个都没有"。
            // 建一个不显示的网页视图把它唤醒，再读一次。
            if cookieWaker == nil {
                let config = WKWebViewConfiguration()
                config.websiteDataStore = profile.websiteDataStore
                cookieWaker = WKWebView(frame: .zero, configuration: config)
                cookieWaker?.loadHTMLString("", baseURL: URL(string: "https://www.bilibili.com/"))
            }
            for _ in 0..<10 where cookies.isEmpty {
                try? await Task.sleep(for: .milliseconds(150))
                cookies = await store.allCookies()
            }
        }
        var jar = CookieJar(cookies: cookies.filter(\.isBilibili))
        if jar.cookies.isEmpty, profile.websiteDataStore == WKWebsiteDataStore.default() {
            // 默认数据仓库和系统的 cookie 存储是同一份文件，直接从那里读
            jar.cookies = (HTTPCookieStorage.shared.cookies ?? []).filter(\.isBilibili)
        }
        if !jar.cookies.isEmpty, generation == cookieGeneration {
            cookieCache = (jar, Date())
            cookieWaker = nil   // 读到了就把隐形网页关掉，不让它一直占着一个网页进程
        }
        return jar
    }

    /// 焦点落在哪个视频上，就提前把它准备好。焦点不在卡片上（左边栏、搜索框、菜单、设置页）就不准备——
    /// 设置页里改了清晰度，回去点开的不能还是按旧清晰度准备好的那个
    private func warmFocused() {
        guard tv?.bilibiliOpen == true else { return }   // 还没进哔哩哔哩时只取列表，不准备视频
        // 直播不提前准备（挂上去就是在拉直播流）；登录页盖着时也不准备
        if login == nil, case .video(let video) = focused, !video.isRoom { player.warm(video) }
        else { player.warm(nil) }
    }

    // MARK: 按键

    func handle(_ command: RemoteCommand) {
        if player.current != nil {
            if player.handle(command) == .close { player.stop() }
            return
        }
        if let login {
            login.handle(command)
            return
        }
        defer { warmFocused() }
        switch focus {
        case .typing: handleTyping(command)
        case .searchField: handleSearchField(command)
        case .settings: handleSettings(command)
        case .cardMenu: handleCardMenu(command)
        case .clearConfirm: handleClearConfirm(command)
        case .accountMenu(let menu): handleAccountMenu(command, menu)
        case .account: handleAccount(command)
        case .follow: handleFollow(command)
        case .sidebar: handleSidebar(command)
        case .rows: if sortFocused { handleSort(command) } else { handleRows(command) }
        }
    }

    /// 正在输入：键盘打字直接进输入框，这里只处理手机遥控器发来的文字和确认 / 返回
    private func handleTyping(_ command: RemoteCommand) {
        switch command {
        case .text(let text): query += text
        case .deleteBackward: if !query.isEmpty { query.removeLast() }
        case .select: submitSearch()
        // 不打了：退出输入，搜索框还是选中的（键盘的方向键在输入框里给输入法用，这里只有手机遥控器的上下）
        case .back, .move(.up): stopEditing()
        case .move(.down): withAnimation(Motion.navigate) { focus = rows.isEmpty ? .searchField : .rows }
        default: break
        }
    }

    /// 搜索框选中了、还没打字：按确认才开始打字；方向键照常走，不会一挪上来就被输入框占住
    private func handleSearchField(_ command: RemoteCommand) {
        switch command {
        case .select: withAnimation(Motion.focus) { focus = .typing }
        case .text(let text):
            // 手机遥控器上直接打字：开始输入并接上这个字
            withAnimation(Motion.focus) { focus = .typing }
            query += text
        case .move(.down): if !rows.isEmpty { withAnimation(Motion.navigate) { focus = .rows } }
        case .move(.up): withAnimation(Motion.focus) { focus = .account }
        case .move(.left), .back: withAnimation(Motion.focus) { focus = .sidebar }
        default: break
        }
    }

    private func handleCardMenu(_ command: RemoteCommand) {
        let menu = cardMenuActions
        switch command {
        case .move(.up): withAnimation(Motion.focus) { cardMenuIndex = max(0, cardMenuIndex - 1) }
        case .move(.down): withAnimation(Motion.focus) { cardMenuIndex = min(menu.count - 1, cardMenuIndex + 1) }
        case .select:
            withAnimation(Motion.focus) { focus = .rows }
            if menu.indices.contains(cardMenuIndex) { run(menu[cardMenuIndex]) }
        case .back, .move(.left), .move(.right): withAnimation(Motion.focus) { focus = .rows }
        default: break
        }
    }

    /// 清空搜索历史的那一问：上下在"取消""清空"之间走，确认选它，返回是取消
    private func handleClearConfirm(_ command: RemoteCommand) {
        switch command {
        case .move(.up): withAnimation(Motion.focus) { clearChoice = .cancel }
        case .move(.down): withAnimation(Motion.focus) { clearChoice = .clear }
        case .select: chooseClear(clearChoice)
        case .back: chooseClear(.cancel)
        default: break
        }
    }

    /// 用鼠标点了那一问里的一项
    func tapClearChoice(_ choice: ClearChoice) {
        guard focus == .clearConfirm else { return }
        clearChoice = choice
        chooseClear(choice)
    }

    /// 点了那一问后面压暗的地方：同"取消"
    func dismissClearConfirm() {
        guard focus == .clearConfirm else { return }
        chooseClear(.cancel)
    }

    /// 那一问收起，焦点回到"清空"上；选的是"清空"就真的清掉，搜索页重新摆
    private func chooseClear(_ choice: ClearChoice) {
        withAnimation(Motion.focus) { focus = .rows }
        guard choice == .clear else { return }
        BiliSearchHistory.clear()
        showLanding()
    }

    private func handleAccountMenu(_ command: RemoteCommand, _ menu: AccountMenu) {
        let actions = accountActions
        switch command {
        case .move(.up): withAnimation(Motion.focus) { accountIndex = max(0, accountIndex - 1) }
        case .move(.down): withAnimation(Motion.focus) { accountIndex = min(actions.count - 1, accountIndex + 1) }
        case .select: if actions.indices.contains(accountIndex) { perform(actions[accountIndex]) }
        // 账号列表、退出登录的确认里返回：回到头像菜单，停在进来的那一项上
        case .back where menu == .accounts: showAccountMenu(at: .switchAccount)
        case .back where menu == .confirmLogout: showAccountMenu(at: .logout)
        case .back, .move(.left): withAnimation(Motion.focus) { focus = .account }
        default: break
        }
    }

    /// 回到头像菜单的第一层，停在 action 那一项上
    private func showAccountMenu(at action: AccountAction) {
        withAnimation(Motion.focus) {
            focus = .accountMenu(.main)
            accountIndex = accountActions.firstIndex(of: action) ?? 0
        }
    }

    /// 选了头像：打开菜单；没登录、也没有登录过的账号时直接打开登录页
    private func openAccount() {
        if accountOpensLogin {
            focus = .account   // 登录页关了回到头像上
            openLogin()
            return
        }
        withAnimation(Motion.focus) { accountIndex = 0; focus = .accountMenu(.main) }
    }

    private func handleAccount(_ command: RemoteCommand) {
        switch command {
        case .select: openAccount()
        // 在 UP 主的主页里，头像下面是关注按钮；搜索页上是搜索框；别的页直接回到内容
        case .move(.down), .back:
            withAnimation(Motion.focus) { focus = upPage != nil ? .follow : (tab == .search ? .searchField : .rows) }
        case .move(.left): withAnimation(Motion.focus) { focus = .sidebar }
        default: break
        }
    }

    private func handleFollow(_ command: RemoteCommand) {
        switch command {
        case .select: toggleFollow()
        case .move(.down): withAnimation(Motion.focus) { focus = .rows }   // 下面是三个排序
        case .move(.up): withAnimation(Motion.focus) { focus = .account }
        case .move(.left): withAnimation(Motion.focus) { focus = .sidebar }
        case .back: leaveUpPage()
        default: break
        }
    }

    /// UP 主页的三个排序：左右换排序（下面那排视频跟着换），往下到视频，往上到关注按钮
    private func handleSort(_ command: RemoteCommand) {
        guard let page = upPage else { return }
        switch command {
        case .move(.left):
            if let previous = UpPage.Sort(rawValue: page.sort.rawValue - 1) { setSort(previous) }
            else { withAnimation(Motion.focus) { focus = .sidebar } }
        case .move(.right): if let next = UpPage.Sort(rawValue: page.sort.rawValue + 1) { setSort(next) }
        case .move(.up): withAnimation(Motion.focus) { focus = .follow }
        case .move(.down), .select: if !rows.isEmpty { withAnimation(Motion.navigate) { upPage?.browsing = true } }
        case .back: leaveUpPage()
        default: break
        }
    }

    private func handleSidebar(_ command: RemoteCommand) {
        switch command {
        case .move(.up): step(-1)
        case .move(.down): step(1)
        case .move(.right), .select:
            commitSidebar()
            // 搜索页：左边栏收起，焦点停在搜索框上（选中、不打字），再按一下确认才开始打字。
            // 别的页（包括盖在搜索页上的 UP 主页），哪怕右边暂时还没有内容也收起
            withAnimation(Motion.focus) { focus = tab == .search && upPage == nil ? .searchField : .rows }
        // 左边栏是盖在右边内容之上的二级菜单：按一下 Esc 永远是收起它、回到右边
        //（哪怕右边暂时只有一个搜索框）。内容里最上一层再按返回是回主屏（哔哩哔哩留在后台），长按 Esc 是退出它（见 AppQuit）。
        case .back:
            commitSidebar()
            withAnimation(Motion.focus) { focus = contentFocus }
        default: break
        }
    }

    /// 卡片排：左右在一排里走，上下换排；最上面一排再按上是头像（搜索页上是搜索框，UP 主页上是三个排序）
    private func handleRows(_ command: RemoteCommand) {
        switch command {
        case .move(.left):
            if column > 0 { setColumn(column - 1) }
            else if isHotRow(row), isHotRow(row - 1) {
                // 热搜按顺序往回走：3 再往左是 2（上一行的最后一个）
                let previous = row - 1
                withAnimation(Motion.focus) { columns[rows[previous].id] = rows[previous].items.count - 1; setRow(previous) }
            }
            else { withAnimation(Motion.focus) { focus = .sidebar } }
        case .move(.right):
            if isHotRow(row), isHotRow(row + 1), column == rows[row].items.count - 1 {
                // 热搜按顺序往下走：2 再往右是 3（下一行的第一个），一直到 10
                let next = row + 1
                withAnimation(Motion.focus) { columns[rows[next].id] = 0; setRow(next) }
            } else {
                setColumn(column + 1)
            }
        case .move(.up):
            if row > 0 {
                // 热搜是两列的格子：上下换行保持在同一列（4 按上是 2），不用那一行上次停的位置
                if isHotRow(row), isHotRow(row - 1) { columns[rows[row - 1].id] = min(column, rows[row - 1].items.count - 1) }
                withAnimation(Motion.navigate) { setRow(row - 1) }
            }
            else if upPage != nil { withAnimation(Motion.navigate) { upPage?.browsing = false } }   // UP 主页：第一排再按上，回到三个排序
            else if tab == .search { withAnimation(Motion.focus) { focus = .searchField } }      // 从结果往上回到搜索框（选中，不打字）
            else { withAnimation(Motion.focus) { focus = .account } }                            // 最上面一排再按上：到右上角的头像
        case .move(.down):
            if row < rows.count - 1 {
                if isHotRow(row), isHotRow(row + 1) { columns[rows[row + 1].id] = min(column, rows[row + 1].items.count - 1) }
                withAnimation(Motion.navigate) { setRow(row + 1) }
            }
        case .select:
            // 搜索页还没有结果（刚按了搜索、还在取）：这时看起来选中的是搜索框，按确认接着改搜索词
            if tab == .search, upPage == nil, rows.isEmpty { withAnimation(Motion.focus) { focus = .typing } }
            else { activate() }
        case .back:
            // 在某个 UP 主的主页里：Esc 回到进来之前的那一页。
            if upPage != nil { leaveUpPage() }
            // 搜索结果的上一级是搜索页本身（搜索历史、热搜）
            else if tab == .search, !showingLanding, !rows.isEmpty { withAnimation(Motion.navigate) { showLanding() } }
            // 最上一层：回主屏，哔哩哔哩留在后台（和 Apple TV 一样，见 AppQuit）
            else { tv?.goHome() }
        case .playPause: if case .video = focused { activate() }
        default: break
        }
    }

    /// 转盘只在焦点所在的这一排 / 这一列里走：走到头就停，不会转进左边栏、头像这些别的地方
    /// （要去那里得按一下方向键）。转得猛了也不会一下子把左边栏拉出来
    func wheelCanMove(_ direction: RemoteCommand.Direction) -> Bool {
        if player.current != nil {
            if player.relatedVisible { return flickCanMove(direction) }   // 选集、相关视频：到第一张就停
            return true                                                    // 清晰度栏、右边面板：在里面走，到头自己停
        }
        if let login { return login.canMove(direction) }                  // 登录页：只在表单里上下走，不转回二维码
        switch focus {
        case .typing, .searchField, .account, .follow: return false
        case .settings, .cardMenu, .accountMenu, .clearConfirm, .sidebar: return true   // 一列固定的选项，到头自己停
        case .rows:
            guard let page = upPage, sortFocused else { return flickCanMove(direction) }   // 视频排：到第一张就停，不进左边栏
            switch direction {
            case .left: return page.sort.rawValue > 0                                       // 第一个排序再往左是左边栏
            case .right: return page.sort.rawValue < UpPage.Sort.allCases.count - 1
            default: return false
            }
        }
    }

    /// 转盘沿着哪个方向走（见 TVController.wheelRunsHorizontally）
    var wheelRunsHorizontally: Bool {
        if player.current != nil { return !player.panelVisible }   // 相关视频、清晰度栏是横的；右边的面板是竖的
        if login != nil { return false }                            // 登录表单：从上往下一样一样走
        switch focus {
        // 设置、菜单、左边栏是竖的；头像、关注按钮往下回到内容
        case .settings, .cardMenu, .accountMenu, .clearConfirm, .sidebar, .account, .follow: return false
        case .rows, .searchField, .typing: return true            // 视频排、三个排序
        }
    }

    /// 左边栏里高亮停在哪一项。上下滑时先只移动它，停下来一会儿才换右边的内容——换一页要重画好几排卡片、
    /// 给选中的视频预热、有时还要联网，每走一格都换的话前几下会卡
    @Published private(set) var sidebarTab: Tab = .home
    private var sidebarCommit: Task<Void, Never>?

    /// 在左边栏里上下走一格（藏起来的页跳过）
    private func step(_ delta: Int) {
        let all = visibleTabs
        guard let index = all.firstIndex(of: sidebarTab), all.indices.contains(index + delta) else { return }
        withAnimation(Motion.focus) { sidebarTab = all[index + delta] }
        sidebarCommit?.cancel()
        sidebarCommit = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.commitSidebar()
        }
    }

    /// 高亮停住了，或者离开左边栏：右边换成高亮的那一页
    private func commitSidebar() {
        sidebarCommit?.cancel()
        sidebarCommit = nil
        if sidebarTab != tab { select(sidebarTab) }
    }

    /// 换到这一页（用鼠标点了左边栏，或者在左边栏里停住了）。在左边栏里上下走时焦点留在左边栏；
    /// 用鼠标点的，焦点到新的这一页的内容上（在搜索页上点搜索，正在输入的接着输入）
    func select(_ target: Tab) {
        guard !hiddenTabs.contains(target) else { return }
        let keep = focus == .sidebar || (target == .search && (focus == .typing || focus == .searchField))
        switchTab(to: target, focusContent: !keep)
    }

    /// 右边换成这一页。focusContent：焦点也到这一页的内容上（不然留在原处：左边栏、设置页）
    private func switchTab(to target: Tab, focusContent: Bool) {
        sidebarCommit?.cancel()
        sidebarCommit = nil
        sidebarTab = target
        withAnimation(Motion.navigate) {
            tab = target
            upPage = nil
            if focusContent { focus = .rows }
        }
        if target == .search, content[.search]?.isEmpty ?? true || showingLanding { showLanding() }
        if content[target] == nil || isStale(target) { load(target) }
        warmFocused()
    }

    private func setColumn(_ value: Int) {
        guard rows.indices.contains(row) else { return }
        let clamped = max(0, min(rows[row].items.count - 1, value))
        guard clamped != column else { return }
        withAnimation(BiliMotion.step()) { columns[rows[row].id] = clamped }
        // 往后几张的封面先下好：甩着翻会一下走好几张，不然翻过去是一排空的灰块
        for case .video(let video) in rows[row].items.dropFirst(clamped + 1).prefix(12) {
            if let url = video.cover, BiliImageCache.shared.image(for: url) == nil {
                Task { @MainActor in _ = await BiliImageCache.shared.load(url) }
            }
        }
        loadMoreIfNeeded()
    }

    /// 快翻到一排的末尾时，悄悄再取一批接在后面，所以可以一直往后翻
    private func loadMoreIfNeeded() {
        guard rows.indices.contains(row) else { return }
        let current = rows[row], id = current.id, owner = tab
        guard ["recommended", "popular", "search"].contains(id), !fetchingMore.contains(id), !exhausted.contains(id),
              column >= current.items.count - 8 else { return }
        fetchingMore.insert(id)
        let next = (pages[id] ?? 1) + 1
        let keyword = lastKeyword
        let epoch = loginEpoch
        Task { @MainActor in
            let cookie = await cookieHeader()
            let more: [BiliVideo]
            switch id {
            case "recommended": more = await BiliAPI.recommended(cookie: cookie, page: next)
            case "popular": more = await BiliAPI.popular(cookie: cookie, page: next)
            default: more = await BiliAPI.search(keyword, cookie: cookie, page: next)
            }
            guard epoch == self.loginEpoch else { return }   // 这期间退出、换了账号：这一批是上一个账号的推荐
            self.fetchingMore.remove(id)
            guard var list = self.content[owner], let index = list.firstIndex(where: { $0.id == id }) else { return }
            if id == "search", keyword != self.lastKeyword { return }   // 这期间换了搜索词
            let have = Set(list[index].items.compactMap { item -> String? in
                if case .video(let video) = item { return video.bvid } else { return nil }
            })
            let fresh = more.filter { !have.contains($0.bvid) }
            if more.isEmpty {
                // 一次取不到可能只是网络问题；连续两次才认为真的到头了
                self.emptyPages[id, default: 0] += 1
                if self.emptyPages[id, default: 0] >= 2 { self.exhausted.insert(id) }
                return
            }
            self.emptyPages[id] = 0
            self.pages[id] = next
            list[index].items += fresh.map(Item.video)
            self.content[owner] = list
            if fresh.isEmpty { self.loadMoreIfNeeded() }   // 这一批全是重复的，接着取下一批
        }
    }

    /// 用鼠标点了一张卡片（搜过的词、热搜也是）：焦点过去（不管刚才在哪：左边栏、头像、搜索框……），打开它
    func tapItem(row r: Int, column c: Int) {
        guard rows.indices.contains(r) else { return }
        withAnimation(Motion.focus) {
            focus = .rows
            if upPage != nil { upPage?.browsing = true }
            setRow(r)
            columns[rows[r].id] = c
        }
        activate()
    }

    func activate() {
        guard let item = focused else { if failed { reload() }; return }
        perform(item)
    }

    private func perform(_ item: Item) {
        // 别的几样要放视频、开登录页、联网，得有 tv；"清空"只是在这一页上先问一句
        guard tv != nil || item == .clearHistory else { return }
        switch item {
        case .video(let video) where video.endedRoom > 0:
            // 看过的直播、现在没在播：进主播的主页（他最近发了什么、在不在播）
            if video.ownerMid > 0 { openUp(BiliUser(mid: video.ownerMid, name: video.owner, face: video.face)) }
            else { tv?.showToast("主播未开播") }
        case .video(let video):
            player.play(video)
        case .user(let user):
            openUp(user)
        case .login:
            openLogin()
        case .refresh:
            reload(byUser: true)
        case .empty:
            break
        case .keyword(let word):
            query = word
            submitSearch()
        case .trend(let trend):
            query = trend.keyword
            submitSearch()
        case .clearHistory:
            // 清空之前先问一句（和 iOS 的"清除历史记录"一样）：从"清空"长出一张小卡片，默认停在"取消"上
            withAnimation(Motion.focus) { clearChoice = .cancel; focus = .clearConfirm }
        }
    }

    /// 头像菜单里选了一项
    private func perform(_ action: AccountAction) {
        guard tv != nil else { return }
        switch action {
        case .login:
            // "登录其他账号"：菜单收起，打开登录页；登录页返回时回到头像上
            withAnimation(Motion.focus) { focus = .account }
            openLogin()
        case .refresh:
            closeAccountMenu()
            reload(byUser: true)
        case .settings:
            openSettings()
        case .switchAccount:
            // 菜单换成登录过的账号列表，停在现在这个账号上
            withAnimation(Motion.focus) {
                focus = .accountMenu(.accounts)
                accountIndex = savedAccounts.firstIndex { $0.mid == account?.mid } ?? 0
            }
        case .useAccount(let mid):
            closeAccountMenu()
            if mid != account?.mid { switchAccount(to: mid) }
        case .addAccount:
            closeAccountMenu()
            // 先退出现在的账号（它的登录信息记进钥匙串，随时能切回来），再打开登录页
            Task { @MainActor in
                await self.rememberCurrent()
                await self.clearLogin()
                self.openLogin()
            }
        case .logout:
            // 退出登录之前先问一次；默认停在"取消"上，误按确认不会退出
            withAnimation(Motion.focus) { focus = .accountMenu(.confirmLogout); accountIndex = 0 }
        case .keepLogin:
            showAccountMenu(at: .logout)   // 不退出了：回到头像菜单，停在"退出登录"上
        case .confirmLogout:
            closeAccountMenu()
            Task { @MainActor in
                // 退出登录：这个账号从"登录过的账号"里去掉，钥匙串里的登录信息也删掉
                if let mid = self.account?.mid { BiliAccounts.forget(mid) }
                self.savedAccounts = BiliAccounts.list()
                await self.clearLogin()
                self.reload()
            }
        }
    }

    /// 头像菜单里选的这一项要离开菜单：菜单收起，焦点回到右边的内容
    private func closeAccountMenu() {
        withAnimation(Motion.focus) { focus = contentFocus }
    }

    /// 打开登录页（盖在列表上：左边扫码，右边哔哩哔哩自己的表单）；登录成功自动回到列表（见 finishLogin）
    func openLogin() {
        guard login == nil else { return }
        let qr = BiliQRLogin(service: qrService)
        // 表单用这个人自己的网页数据：在里面登录，登录信息就存在别处读的那个地方
        let page = BiliLoginPage(qr: qr, dataStore: tv?.profile.websiteDataStore)
        page.tv = tv
        qr.signedIn = { [weak self] cookies in await self?.saveLogin(cookies) }
        page.signedIn = { [weak self] in self?.finishLogin() }
        page.close = { [weak self] in self?.closeLogin() }
        login = page
        page.open()
    }

    /// 关掉登录页：不再问二维码，网页拆掉；焦点回到打开它的地方（头像、"登录"卡片）
    func closeLogin() {
        guard let page = login else { return }
        page.shutdown()
        login = nil
    }

    /// 扫码登录成功：哔哩哔哩发下来的登录信息放进这个人的网页数据（和在网页里登录存的是同一个地方、
    /// 同样的名字和域名），再同 finishLogin
    private func saveLogin(_ cookies: [HTTPCookie]) async {
        guard let page = login else { return }
        if let tv { await BiliQRLogin.save(cookies, in: tv.profile.websiteDataStore.httpCookieStore) }
        guard login === page else { return }   // 存的这一会儿登录页关了、换了人：不算
        finishLogin()
    }

    /// 登录成功（扫码，或者在表单里登录了）：关掉登录页，登录信息重新读、内容重新取
    /// （取的时候认出是谁，记进登录过的账号）
    private func finishLogin() {
        closeLogin()
        guard let tv else { return }
        reload()
        tv.showToast("登录成功")
    }

    // MARK: 多账号

    /// 知道是谁了：记下这个账号和解出它的那份登录信息（钥匙串），以后能在头像菜单里切回来
    private func adopt(_ fresh: BiliAccount, cookies: [HTTPCookie]) {
        guard fresh != account else { return }
        account = fresh
        BiliAccounts.remember(fresh, cookies: cookies)
        savedAccounts = BiliAccounts.list()
    }

    /// 现在登录着的账号连同它此刻的登录信息记进钥匙串（换账号、加账号之前，切回来时用的是最新的）
    private func rememberCurrent() async {
        let epoch = loginEpoch
        let jar = await cookieJar(fresh: true)
        guard epoch == loginEpoch, let account else { return }
        BiliAccounts.remember(account, cookies: jar.cookies)
        savedAccounts = BiliAccounts.list()
    }

    /// 把现在的哔哩哔哩登录清掉（网页那边和这边一起），页面回到没登录的样子
    private func clearLogin() async {
        guard let tv else { return }
        let store = tv.profile.websiteDataStore.httpCookieStore
        // 系统的 cookie 存储和默认网页数据是同一份：那是第一个人的，只在第一个人退出登录时清（别的人各有各的网页数据）
        let usesDefaultStore = tv.profile.store == nil
        for cookie in await store.allCookies() where cookie.isBilibili { await store.deleteCookie(cookie) }
        if usesDefaultStore {
            for cookie in HTTPCookieStorage.shared.cookies ?? [] where cookie.isBilibili { HTTPCookieStorage.shared.deleteCookie(cookie) }
        }
        forgetLogin()
    }

    /// 这边记着的登录情况全部作废：账号、各页内容、签名密钥、读到的登录信息。还在路上的请求回来也不再用（见 loginEpoch）
    private func forgetLogin() {
        loginEpoch += 1
        forgetCookies()
        account = nil
        signingKey = nil
        // 搜索历史、热搜、搜索结果不分账号，留着
        content = content.filter { $0.key == .search }
        rowIndex = rowIndex.filter { $0.key == .search }
        loadingTabs = loadingTabs.filter { $0 == .search }
        failedTabs = []
        loadedAt = [:]
        pages = [:]
        fetchingMore = []
        exhausted = []
        emptyPages = [:]
        upPage = nil
    }

    /// 换到一个登录过的账号：清掉现在的登录，放上那个账号存下来的，整页按新账号重新取
    private func switchAccount(to mid: Int) {
        let saved = BiliAccounts.cookies(for: mid)
        let name = savedAccounts.first { $0.mid == mid }?.name ?? "这个账号"
        guard !saved.isEmpty, let tv else { tv?.showToast("「\(name)」的登录已过期，请重新登录"); return }
        // 换的是这个人（个人资料）的账号、放进他的网页数据：中途换了人就停，不放进下一个人那里
        let space = ProfileSpace.current, store = tv.profile.websiteDataStore.httpCookieStore
        Task { @MainActor in
            await self.rememberCurrent()
            await self.clearLogin()
            guard ProfileSpace.isCurrent(space.epoch) else { return }
            let epoch = self.loginEpoch
            for cookie in saved { await store.setCookie(cookie) }
            let jar = await self.cookieJar(fresh: true)
            let answer = await BiliAPI.account(cookie: jar.header)
            guard epoch == self.loginEpoch, ProfileSpace.isCurrent(space.epoch) else { return }
            switch answer {
            case .signedIn(let account):
                self.adopt(account, cookies: jar.cookies)
            case .signedOut:
                // 存下来的登录信息不管用了（在别处退出过、过期了）：从列表里去掉
                await self.clearLogin()
                BiliAccounts.forget(mid, in: space)
                self.savedAccounts = BiliAccounts.list()
                tv.showToast("「\(name)」的登录已过期，请重新登录")
            case .unknown:
                // 暂时问不到（网络不通）：登录信息已经换上了，等网络好了刷新时自然知道是谁
                break
            }
            self.reload()
        }
    }

    /// 要换人了：在放的是这个人的视频，停下（看到哪了记在他自己那里、报到他的账号上，见 cookieOfNow）
    func profileWillChange() {
        player.stop()
        player.warm(nil)
        resetTransient()
    }

    /// 换了一个 Mac TV 的用户：每个人的哔哩哔哩登录在各自的网页数据里，登录过的账号、搜索历史、看到哪了、
    /// 播放设置在各自的设置里。这边记着的账号、内容、签名密钥、读到的登录信息都是上一个人的，全部作废，
    /// 按新的人重新取（见 ProfileApp）
    func profileChanged() {
        player.stop()
        player.warm(nil)
        forgetLogin()
        // 搜索页（搜索历史、搜过的结果）也是上一个人的
        content = [:]
        rowIndex = [:]
        loadingTabs = []
        columns = [:]
        query = ""
        cookieWaker = nil   // 唤醒的是上一个人的网页数据
        savedAccounts = BiliAccounts.list()
        hiddenTabs = BiliSidebar.hidden
        tab = .home   // 首页每个人都有（别的页这个人可能藏起来了）
        sidebarTab = .home
        player.reloadSettings()
        resetTransient()
        preload()
    }

    /// 离开哔哩哔哩、从外面直接放一个视频、换了人时：把各种开着的小东西都收起来（登录页也关掉，不再问二维码），
    /// 下次进来焦点在内容上
    func resetTransient() {
        closeLogin()
        focus = contentFocus
        settingList = nil
    }

    // MARK: UP 主的主页

    func openUp(_ user: BiliUser, returnTo video: BiliVideo? = nil) {
        let id = "uppage-\(user.mid)"
        columns[id] = 0
        withAnimation(Motion.navigate) {
            focus = .rows   // 进来时停在三个排序上
            upPage = UpPage(user: user, returnTo: video)
        }
        let epoch = loginEpoch
        Task { @MainActor in
            let cookie = await cookieHeader()
            async let followed = BiliAPI.isFollowing(mid: user.mid, cookie: cookie)
            async let card = BiliAPI.userCard(mid: user.mid, name: user.name, cookie: cookie)
            async let room = BiliAPI.liveRoomOf(mid: user.mid)
            let key = await currentSigningKey(cookie: cookie)
            let following = await followed
            let full = await card
            var uploads: [BiliVideo] = []
            if let key { uploads = await BiliAPI.uploads(mid: user.mid, name: full.name, key: key, cookie: cookie).videos }
            // 直播间那张卡片上写主播的名字、带头像（查直播间的接口不给）
            let live = await room.map { video in
                BiliVideo(bvid: video.bvid, title: video.title, cover: video.cover, duration: 0, owner: full.name, views: video.views,
                          ownerMid: user.mid, liveRoom: video.liveRoom, face: full.face ?? user.face)
            }
            guard epoch == self.loginEpoch, self.upPage?.user.mid == user.mid else { return }
            withAnimation(Motion.navigate) {
                self.upPage?.live = live
                if !uploads.isEmpty { self.upPage?.lists[.latest] = uploads }   // 没取到不记，换回"最新发布"时再取
                self.upPage?.user = BiliUser(mid: user.mid, name: full.name, face: full.face ?? user.face,
                                             fans: max(full.fans, user.fans), videos: max(full.videos, user.videos))
                self.upPage?.following = following
                if self.upPage?.sort == .latest { self.showUploads(uploads, sort: .latest) }
                self.upPage?.loading = false
            }
        }
    }

    /// 返回离开 UP 主的主页：回到进来之前的那一页。是从视频里进来的（面板里的"UP 主"、点标题下面的名字），
    /// 就回到那个视频，停在刚才那一帧，按播放接着放
    private func leaveUpPage() {
        let back = upPage?.returnTo
        withAnimation(Motion.navigate) {
            upPage = nil
            focus = contentFocus
        }
        if let back { player.play(back, startPaused: true) }
    }

    private func showUploads(_ videos: [BiliVideo], sort: UpPage.Sort) {
        guard let mid = upPage?.user.mid else { return }
        let id = "uppage-\(mid)-\(sort.rawValue)"
        columns[id] = 0
        upPage?.row = 0
        // 他正在直播：直播间放在最前面（不管按什么排）
        let items = ((upPage?.live).map { [$0] } ?? []) + videos
        upPage?.rows = items.isEmpty ? [] : [Row(id: id, title: sort.title, items: items.map(Item.video))]
    }

    /// 换排序：取过的直接换上，没取过的现取（取的时候先留着原来那排，不闪）
    private func setSort(_ sort: UpPage.Sort) {
        guard let page = upPage, page.sort != sort else { return }
        withAnimation(Motion.focus) { upPage?.sort = sort }
        if let cached = page.lists[sort] {
            withAnimation(Motion.navigate) { showUploads(cached, sort: sort) }
            return
        }
        let user = page.user, epoch = loginEpoch
        Task { @MainActor in
            let cookie = await cookieHeader()
            guard let key = await currentSigningKey(cookie: cookie) else { return }
            let videos = await BiliAPI.uploads(mid: user.mid, name: user.name, key: key, cookie: cookie, order: sort.order).videos
            guard epoch == self.loginEpoch, self.upPage?.user.mid == user.mid else { return }
            if !videos.isEmpty { self.upPage?.lists[sort] = videos }
            if self.upPage?.sort == sort { withAnimation(Motion.navigate) { self.showUploads(videos, sort: sort) } }
        }
    }

    /// 用鼠标点了一个排序：焦点过去，换成这个排序
    func tapSort(_ index: Int) {
        guard upPage != nil, let sort = UpPage.Sort(rawValue: index) else { return }
        withAnimation(Motion.focus) {
            focus = .rows
            upPage?.browsing = false
        }
        setSort(sort)
    }

    /// 关注 / 取消关注。取消要再按一次确认。
    private func toggleFollow() {
        guard let tv, let page = upPage else { return }
        guard account != nil else { tv.showToast("登录后才能关注"); return }
        if page.following, !page.armed {
            withAnimation(Motion.focus) { upPage?.armed = true }
            return
        }
        let user = page.user, following = page.following
        Task { @MainActor in
            let ok = await BiliAPI.setFollowing(mid: user.mid, follow: !following, cookie: await self.cookieHeader())
            guard self.upPage?.user.mid == user.mid else { return }
            withAnimation(Motion.focus) {
                self.upPage?.armed = false
                if ok { self.upPage?.following = !following }
            }
            guard ok else { tv.showToast("操作失败"); return }
            self.loadedAt[.following] = nil   // "关注"那一页下次进去时重新取
        }
    }

    // MARK: 手机发来的链接

    /// 手机上粘贴了一个哔哩哔哩视频的链接：取到视频信息就直接放（盖在现在这一页上，返回回到这一页）。
    /// 等的途中回了主屏、开了别的应用，就不放了
    func openLinked(bvid: String?, aid: Int?, page: Int?) {
        Task { @MainActor in
            let cookie = await cookieHeader()
            let key = await currentSigningKey(cookie: cookie)
            let video = await BiliAPI.video(bvid: bvid, aid: aid, page: page, key: key, cookie: cookie)
            guard tv?.bilibiliOpen == true else { return }
            guard let video else { tv?.showToast("无法打开此视频"); return }
            resetTransient()
            player.play(video)
        }
    }

    /// 手机上粘贴了一个直播间的链接：在播就直接看；没在播就说一声，进主播的主页（等的途中离开了哔哩哔哩就算了）
    func openLinkedLive(room: Int) {
        Task { @MainActor in
            let (live, mid) = await BiliAPI.liveRoom(id: room)
            guard tv?.bilibiliOpen == true else { return }
            if let live {
                resetTransient()
                player.play(live)
            } else if mid > 0 {
                let card = await BiliAPI.userCard(mid: mid, name: "", cookie: await cookieHeader())
                guard tv?.bilibiliOpen == true else { return }
                tv?.showToast("主播未开播")
                resetTransient()
                openUp(card)
            } else {
                tv?.showToast("无法打开此直播间")
            }
        }
    }

    // MARK: 设置页（头像菜单里的"设置"）

    /// 设置项：清晰度、倍速（和看视频时右边面板里的是同一个值）、字幕（有字幕时自动打开）、弹幕、
    /// 左边栏显示哪几页（见 BiliSidebar）、
    /// 主屏顶部：选中哔哩哔哩的图标时，主屏上方轮播什么（关注更新、推荐、热门、直播；见 AppShelf）
    enum Setting: Int, CaseIterable { case quality, speed, subtitles, danmaku, sidebar, shelf }
    /// 清晰度、倍速、主屏顶部选了以后，右边换成一列档位；弹幕选了以后换成弹幕的几项设置（按确认换下一个值）；
    /// 左边栏换成可以勾选的几页（按确认勾上 / 取消，可以勾好几个）
    enum SettingList: Hashable { case quality, speed, danmaku, sidebar, shelf }
    /// 设置里能选的清晰度（从高到低；账号或视频没有那一档时自动用能给的最高一档）
    static let settableQualities = [120, 116, 112, 80, 64, 32]

    @Published private(set) var settingIndex = 0
    @Published private(set) var settingList: SettingList?
    @Published private(set) var settingListIndex = 0

    private func openSettings() {
        settingIndex = 0
        settingList = nil
        player.warm(nil)
        withAnimation(Motion.navigate) { focus = .settings }
    }

    /// 设置页：上下选一行，确认改（清晰度、倍速换成一列档位，字幕直接开 / 关）；返回回到头像上
    private func handleSettings(_ command: RemoteCommand) {
        if let list = settingList {
            let count = switch list {
            case .quality: Self.settableQualities.count
            case .speed: BilibiliNativePlayer.speeds.count
            case .danmaku: player.danmakuOptions.count
            case .sidebar: BiliSidebar.choices.count
            case .shelf: BiliShelfSource.allCases.count
            }
            switch command {
            case .move(.up): withAnimation(Motion.focus) { settingListIndex = max(0, settingListIndex - 1) }
            case .move(.down): withAnimation(Motion.focus) { settingListIndex = min(count - 1, settingListIndex + 1) }
            case .select: chooseSetting(list, settingListIndex)
            case .back: withAnimation(Motion.focus) { settingList = nil }
            default: break
            }
            return
        }
        switch command {
        case .move(.up): withAnimation(Motion.focus) { settingIndex = max(0, settingIndex - 1) }
        case .move(.down): withAnimation(Motion.focus) { settingIndex = min(Setting.allCases.count - 1, settingIndex + 1) }
        case .select: activateSetting(settingIndex)
        case .back: withAnimation(Motion.navigate) { focus = .account }   // 从头像进来的，回到头像上
        default: break
        }
    }

    func activateSetting(_ index: Int) {
        guard settingsOpen, let setting = Setting(rawValue: index) else { return }
        settingIndex = index
        switch setting {
        case .quality:
            let chosen = player.preferredQuality
            settingListIndex = Self.settableQualities.firstIndex { $0 <= chosen } ?? 0
            withAnimation(Motion.focus) { settingList = .quality }
        case .speed:
            settingListIndex = BilibiliNativePlayer.speeds.firstIndex(of: player.speed) ?? 3
            withAnimation(Motion.focus) { settingList = .speed }
        case .subtitles:
            withAnimation(Motion.focus) { player.subtitlesOn.toggle() }
        case .danmaku:
            settingListIndex = 0
            withAnimation(Motion.focus) { settingList = .danmaku }
        case .sidebar:
            settingListIndex = 0
            withAnimation(Motion.focus) { settingList = .sidebar }
        case .shelf:
            settingListIndex = BiliShelfSource.allCases.firstIndex(of: BiliShelfSource.current) ?? 0
            withAnimation(Motion.focus) { settingList = .shelf }
        }
    }

    func chooseSetting(_ list: SettingList, _ index: Int) {
        switch list {
        case .quality:
            if Self.settableQualities.indices.contains(index) {
                player.preferredQuality = Self.settableQualities[index]
                player.warm(nil)   // 按旧清晰度准备好的作废
            }
        case .speed: if BilibiliNativePlayer.speeds.indices.contains(index) { player.speed = BilibiliNativePlayer.speeds[index] }
        case .shelf:
            if BiliShelfSource.allCases.indices.contains(index), BiliShelfSource.allCases[index] != BiliShelfSource.current {
                BiliShelfSource.current = BiliShelfSource.allCases[index]
                tv?.appShelf.sourceChanged(Self.appID)   // 主屏顶部按新的重新取
                objectWillChange.send()
            }
        case .danmaku:
            withAnimation(Motion.focus) { player.cycleDanmakuOption(index) }
            objectWillChange.send()
            return   // 这一列留着，可以接着改别的
        case .sidebar:
            if BiliSidebar.choices.indices.contains(index) { toggleSidebar(BiliSidebar.choices[index]) }
            return   // 可以接着勾别的
        }
        withAnimation(Motion.focus) { settingList = nil }
    }

    /// 鼠标点设置页里的一行 / 档位列表里的一项
    func tapSetting(_ index: Int) {
        guard settingsOpen else { return }
        if settingList != nil { withAnimation(Motion.focus) { settingList = nil } }
        activateSetting(index)
    }

    func tapSettingOption(_ index: Int) {
        guard settingsOpen, let list = settingList else { return }
        settingListIndex = index
        chooseSetting(list, index)
    }

    /// 左边栏里显示 / 藏起这一页，左边栏马上跟着变。藏起来的正好是现在这一页：右边回到首页（焦点留在设置页里）
    private func toggleSidebar(_ target: Tab) {
        var hidden = hiddenTabs
        if hidden.contains(target) { hidden.remove(target) } else { hidden.insert(target) }
        BiliSidebar.hidden = hidden
        withAnimation(BiliMotion.slide) { hiddenTabs = BiliSidebar.hidden }
        if hiddenTabs.contains(tab) { switchTab(to: .home, focusContent: false) }
    }

    // MARK: 卡片菜单（在视频卡片上长按确认）

    /// 返回是否真的打开了菜单（不在视频卡片上就不会打开）
    @discardableResult
    func openCardMenu() -> Bool {
        guard player.current == nil, login == nil, case .video(let video)? = focused else { return false }
        var actions: [CardAction] = []
        if video.ownerMid > 0, upPage?.user.mid != video.ownerMid { actions.append(.upPage) }
        // 直播间不是视频：收藏、稍后再看用不了（只留"UP 主"，进主播的主页）
        if account != nil, !video.isRoom {
            if video.aid > 0 { actions.append(.favorite) }
            actions.append(.watchLater)
        }
        guard !actions.isEmpty else { return false }
        player.warm(nil)
        cardMenuVideo = video
        cardMenuActions = actions
        withAnimation(Motion.focus) { cardMenuIndex = 0; focus = .cardMenu }
        return true
    }

    /// 卡片菜单开着时再长按确认：收起，回到那张卡片上（同返回）
    func closeCardMenu() -> Bool {
        guard focus == .cardMenu else { return false }
        withAnimation(Motion.focus) { focus = .rows }
        warmFocused()
        return true
    }

    func tapCardMenu(_ index: Int) {
        guard focus == .cardMenu, cardMenuActions.indices.contains(index) else { return }
        cardMenuIndex = index
        handle(.select)
    }

    private func run(_ action: CardAction) {
        guard let tv, let video = cardMenuVideo else { return }
        switch action {
        case .upPage:
            openUp(BiliUser(mid: video.ownerMid, name: video.owner))
        case .watchLater:
            Task { @MainActor in
                let ok = await BiliAPI.addWatchLater(bvid: video.bvid, cookie: await self.cookieHeader())
                if ok { self.loadedAt[.mine] = nil }
                tv.showToast(ok ? "已加入稍后再看" : "操作失败")
            }
        case .favorite:
            Task { @MainActor in
                let ok = await BiliAPI.addFavorite(aid: video.aid, mid: self.account?.mid ?? 0, cookie: await self.cookieHeader())
                if ok { self.loadedAt[.mine] = nil }
                tv.showToast(ok ? "已收藏" : "操作失败")
            }
        }
    }

    /// 用触控板点头像：焦点过去并打开 / 收起菜单（不管刚才焦点在哪：左边栏、搜索框、设置页……）。
    /// 没登录、也没有登录过的账号时直接打开登录页
    func tapAccount() {
        guard player.current == nil, !editing, login == nil else { return }
        if !accountMenuOpen, accountOpensLogin { openAccount(); return }
        withAnimation(Motion.focus) {
            accountIndex = 0
            focus = accountMenuOpen ? .account : .accountMenu(.main)
        }
    }

    /// 用触控板点菜单里的某一项
    func tapAccountAction(_ index: Int) {
        guard accountMenuOpen, accountActions.indices.contains(index) else { return }
        accountIndex = index
        handle(.select)
    }

    // MARK: 搜索

    /// Siri 键按一下：到搜索页，搜索框选中（还没打字），接着按住 Siri 键就是往里听写
    func focusSearch() {
        guard !editing else { return }
        switchTab(to: .search, focusContent: false)
        withAnimation(Motion.focus) { focus = .searchField }
    }

    /// 用鼠标、触控板点了搜索页上的搜索框：开始打字，和选中它再按确认一样（不管焦点刚才在这一页的哪里）。
    /// 已经在打字时什么也不做
    func tapSearchField() {
        guard player.current == nil, login == nil, tab == .search, upPage == nil, !editing else { return }
        // 左边栏里的高亮还没停住就点了：留在搜索页，不再换过去
        sidebarCommit?.cancel()
        sidebarCommit = nil
        sidebarTab = tab
        withAnimation(Motion.focus) { focus = .typing }
    }

    /// 退出输入：搜索框还是选中的（亮着），再按确认接着打
    func stopEditing() {
        guard editing else { return }
        focus = tab == .search ? .searchField : .rows
    }

    func submitSearch() {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { stopEditing(); return }
        BiliSearchHistory.add(keyword)
        focus = .rows   // 结果出来时焦点就在第一个结果上（还在取的时候看起来选中的是搜索框）
        loadingTabs.insert(.search)
        content[.search] = []
        lastKeyword = keyword
        pages["search"] = 1
        exhausted.remove("search")
        Task { @MainActor in
            let cookie = await cookieHeader()
            async let found = BiliAPI.search(keyword, cookie: cookie)
            async let people = BiliAPI.searchUsers(keyword, cookie: cookie)
            let (results, users) = await (found, people)
            guard self.lastKeyword == keyword else { return }
            self.loadingTabs.remove(.search)
            self.columns["search"] = 0
            self.columns["search-users"] = 0
            self.rowIndex[.search] = 0
            let videoRow = results.isEmpty ? [] : [Row(id: "search", title: "视频", items: results.map(Item.video))]
            let userRow = users.isEmpty ? [] : [Row(id: "search-users", title: "UP主", items: users.map(Item.user))]
            // 搜的像是一个人的名字（最匹配的 UP 主名字里含有搜索词），UP 主就排在前面；否则视频在前
            let personFirst = users.first.map { $0.name.localizedCaseInsensitiveContains(keyword) } ?? false
            // 只换搜索页自己的东西：这期间打开的 UP 主页、挪去的左边栏都不动。
            // 结果是渐渐出来的（上半屏从搜索框换成视频标题时一起挪，不是一下子跳过去）
            withAnimation(Motion.navigate) { self.content[.search] = personFirst ? userRow + videoRow : videoRow + userRow }
            if results.isEmpty && users.isEmpty { self.tv?.showToast("没有找到「\(keyword)」") }
            self.warmFocused()
        }
    }

    /// 以前的登录页（整页网页，现在换成了原生的 BilibiliLoginScreen）里的返回键：回到哔哩哔哩，而不是回主屏
    func handleInPlayer(_ command: RemoteCommand, service: Service) -> Bool {
        guard let tv, service.id == Self.loginID else { return false }
        if case .back = command { tv.returnToBilibili(); return true }
        return false
    }
}

extension TVController {
    /// Opened from open(), which sent what was in front to the background (music stops only when a video plays)
    func openBilibili() {
        bilibiliOpen = true
        bilibiliStore.player.returnFromBackground()
        bilibiliStore.opened()
    }

    /// 哔哩哔哩 quits (the App Switcher, a profile switch): what it was playing stops and saves, everything transient
    /// goes; next time it opens fresh. (Home doesn't come here: it only sends it to the background, see AppQuit.)
    func quitBilibili() {
        bilibiliStore.resetTransient()
        bilibiliStore.player.stop()
        bilibiliStore.player.warm(nil)
        bilibiliOpen = false
    }

    /// 从登录页回到哔哩哔哩（而不是回主屏）
    func returnToBilibili() {
        playbackCoordinator.closeWebPlayback()
        setMode(.launcher)
        playerFailure = nil
        bilibiliOpen = true
        bilibiliStore.reload()   // 登录状态变了，登录信息重新读，内容重新取
        bringToFront()
    }
}

/// 哔哩哔哩自己的两条动画（列表页、播放器、面板共用；别的都用 Motion）
@MainActor
enum BiliMotion {
    /// 从屏幕边上拉出来、收回去的东西：左边栏、头像菜单、卡片菜单、右边的面板、清晰度栏、下面那一块。带一点弹性
    static let slide = Motion.slide

    private static var lastStep = Date.distantPast

    /// 在一排里走一格（列表页的卡片排、播放器里的选集和相关视频）：单按一下用平常的；
    /// 连着走（按住方向键、双指一甩）时换一条短的，不然每一下都重新起一段弹簧，忽快忽慢
    static func step() -> Animation {
        let now = Date()
        defer { lastStep = now }
        return now.timeIntervalSince(lastStep) < 0.2 ? .smooth(duration: 0.16) : Motion.focus
    }
}

/// 左边栏显示哪几页（设置里的"左边栏显示"）。记的是藏起来的那几页：默认全都显示，以后多了一页也是显示的。
/// 首页一直都在，藏不掉
enum BiliSidebar {
    private static let key = "bilibiliSidebarHidden"
    /// 设置里能勾选的几页（按左边栏里的顺序）
    static let choices = BilibiliStore.Tab.allCases.filter { $0 != .home }

    static var hidden: Set<BilibiliStore.Tab> {
        // 每个人（个人资料）各选各的（见 ProfileSpace）
        get { Set((ProfileSpace.current.defaults.stringArray(forKey: key) ?? []).compactMap(BilibiliStore.Tab.init).filter(choices.contains)) }
        set { ProfileSpace.current.defaults.set(choices.filter(newValue.contains).map(\.rawValue), forKey: key) }
    }

    /// 设置那一行右边写的："搜索等 4 项"、"直播、搜索"、"直播"、"仅首页"
    static func summary(hidden: Set<BilibiliStore.Tab>) -> String {
        ListSummary.chinese(choices.filter { !hidden.contains($0) }.map(\.title), none: "仅首页")
    }
}

// MARK: 主屏顶部（见 AppShelf）

extension BilibiliStore {
    /// 主屏顶部轮播的内容。关注的 UP 主最近没发视频（或没登录）时换成推荐，标签跟着写"推荐"
    func shelfItems(_ source: BiliShelfSource) async -> (label: String, items: [AppShelfItem]) {
        let cookie = await cookieHeader()
        var label = source.title
        var videos: [BiliVideo]
        switch source {
        case .following:
            videos = await BiliAPI.followingFeed(cookie: cookie)
            if videos.isEmpty {
                videos = await BiliAPI.recommended(cookie: cookie)
                label = BiliShelfSource.recommended.title
            }
        case .recommended: videos = await BiliAPI.recommended(cookie: cookie)
        case .popular: videos = await BiliAPI.popular(cookie: cookie)
        case .live:
            // 关注的主播在播的在前，不够再拿推荐直播补上
            async let mine = BiliAPI.liveFollowing(cookie: cookie)
            async let index = BiliAPI.liveIndex(cookie: cookie)
            let (following, areas) = await (mine, index)
            let seen = Set(following.map(\.liveRoom))
            videos = following + (areas.first?.rooms ?? []).filter { !seen.contains($0.liveRoom) }
        }
        let items = videos.prefix(AppShelf.limit).map { video -> AppShelfItem in
            var detail: [String] = []
            if video.isLive {
                detail.append("直播")
                if let area = video.note { detail.append(area) }
                if video.views > 0 { detail.append("\(video.viewsText) 人看过") }
            } else {
                if let ago = AppShelf.ago(video.published) { detail.append(ago) }
                if video.views > 0 { detail.append("\(video.viewsText)播放") }
                if video.duration > 0 { detail.append(video.durationText) }
            }
            return AppShelfItem(id: "bili-\(video.bvid)", kind: .video(video), title: video.title, subtitle: video.owner,
                                detail: detail.joined(separator: " · "), image: BiliAPI.largeCover(video.cover),
                                thumbnail: video.cover, avatar: video.face)
        }
        return (label, items)
    }
}

// MARK: 每个人（个人资料）各一份（见 ProfileApp）

extension BilibiliStore: ProfileApp {
    /// 新的人从这些设置开始（和第一次打开哔哩哔哩一样）
    static var registeredDefaults: [String: Any] {
        ["bilibiliQuality": 112, "bilibiliSpeed": 1.0, "bilibiliSubtitles": true, "bilibiliDanmaku": true]
    }
    /// 登录过的账号的登录信息在钥匙串里这个名字下（每个人一份，见 BiliAccounts）：删掉一个人时一起删
    static var keychainServices: [String] { [BiliAccounts.service] }

    /// 登录过的账号在别处改了（以前的账号分给了登录它的人）：头像菜单里重新列
    func savedAccountsChanged() { savedAccounts = BiliAccounts.list() }
}
