import AppKit
import Combine
import SwiftUI
import WebKit

/// 哔哩哔哩原生页面的状态：顶部几个标签、每个标签下的几排内容、焦点位置、登录情况。
///
/// 结构学的是 Apple TV 自家的应用：顶部一行文字标签，下面是一排排大卡片。
/// 内容够用但不堆：首页只放最常看的三排，其余按"关注 / 发现 / 我的"分开。
@MainActor
final class BilibiliStore: ObservableObject {
    static let appID = "bilibili"
    static let loginID = "bilibili-login"

    enum Tab: String, CaseIterable, Identifiable {
        case search, home, following, discover, mine
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .search: "magnifyingglass"
            case .home: "house.fill"
            case .following: "person.2.fill"
            case .discover: "flame.fill"
            case .mine: "person.crop.circle.fill"
            }
        }
        var title: String {
            switch self {
            case .home: "首页"
            case .following: "关注"
            case .discover: "发现"
            case .mine: "我的"
            case .search: "搜索"
            }
        }
    }

    enum Item: Hashable {
        case video(BiliVideo)
        case login, refresh, settings, logout
        /// 退出登录的确认：先问一次，默认停在"取消"上
        case keepLogin, confirmLogout
        /// 一个 UP 主（搜索结果里），按确认进他的主页
        case user(BiliUser)
        /// 这一排暂时没有内容时占位的一张卡片，只显示一句话，按了没反应
        case empty(String)
    }

    struct Row: Identifiable, Hashable {
        let id: String
        let title: String
        var items: [Item]
    }

    @Published private(set) var tab: Tab = .home
    /// 焦点在左边栏上（在最左一张卡片上再按左）
    @Published private(set) var headerFocused = false
    /// 焦点在右上角的头像上（在最上面一排再按上）
    @Published private(set) var accountFocused = false
    /// 头像下面的账号菜单开着，以及选中了第几项
    @Published private(set) var accountMenuOpen = false { didSet { if !accountMenuOpen { confirmingLogout = false } } }
    @Published private(set) var accountIndex = 0
    var accountActions: [Item] { account == nil ? [.login] : (confirmingLogout ? [.keepLogin, .confirmLogout] : [.refresh, .settings, .logout]) }
    /// 头像菜单换成了"取消 / 退出登录"两项（菜单一收起就回到原样）
    @Published private(set) var confirmingLogout = false

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
        var sortFocused = true
        var browsing = false
        var lists: [Sort: [BiliVideo]] = [:]
        /// 焦点在关注按钮上；armed = 已经按过一次"取消关注"，再按一次才真的取消
        var followFocused = false
        var armed = false
        /// 从看视频时右边的面板进来的：返回时回到这个视频（带着刚才看到的位置）接着放
        var returnTo: BiliVideo?
    }
    @Published private(set) var upPage: UpPage?

    /// 在视频卡片上长按确认弹出的小菜单
    enum CardAction: Hashable { case upPage, favorite, watchLater }
    @Published private(set) var cardMenu: [CardAction]?
    @Published private(set) var cardMenuIndex = 0
    /// 菜单是为哪个视频打开的（执行时用它，不用"当前焦点"，免得列表在后台刷新后加错视频）
    private var cardMenuVideo: BiliVideo?
    private var emptyPages: [String: Int] = [:]
    private var signingKey: (key: String, at: Date)?
    /// 正在输入搜索词：键盘交给输入框（这样中文输入法才能用）
    @Published private(set) var editing = false
    @Published var query = ""
    @Published private(set) var content: [Tab: [Row]] = [:]
    @Published private(set) var rowIndex: [Tab: Int] = [:]
    @Published private(set) var columns: [String: Int] = [:]
    @Published private(set) var loadingTabs: Set<Tab> = []
    @Published private(set) var failedTabs: Set<Tab> = []
    @Published private(set) var account: BiliAccount?

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
        if editing { return horizontal ? .off : .drawer }
        if settingsOpen { return horizontal ? .off : .picker }                  // 设置：固定的几行
        if cardMenu != nil || accountMenuOpen { return .picker }               // 菜单：固定的几项
        // 左边栏是从左边拉出来的抽屉（像 Mac 右边的通知中心）：往右滑拉出来，往左滑推回去，再往右滑不动；
        // 在里面上下是挑一项（光标）
        if headerFocused { return horizontal ? .drawer : .picker }
        // 右上角头像、UP 主页的关注按钮和三个排序：和下面的视频排在同一列里，上下跟视频排一样是"内容跟着手走"——
        // 往下滑上到头像，往上滑回到视频（一去一回方向相反，和底下的视频排对称）。
        // 头像、关注按钮往右滑是把左边栏拉出来；三个排序左右是挑一个
        if accountFocused || upPage?.followFocused == true { return .drawer }
        if let page = upPage, page.sortFocused, !page.browsing { return horizontal ? .picker : .drawer }
        return horizontal ? .strip : .drawer                                    // 视频排：横着是长条，上下换排
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
        guard !headerFocused, !accountFocused, cardMenu == nil, rows.indices.contains(row) else { return false }
        switch direction {
        case .left: return column > 0                              // 到第一张就停，不进左边栏
        case .right: return column < rows[row].items.count - 1
        default: return false
        }
    }
    /// 原生播放器：直接取流，不经过网页
    let player = BilibiliNativePlayer()
    private var playerChanges: AnyCancellable?
    private var loadedAt: [Tab: Date] = [:]
    private var loginWatch: Task<Void, Never>?
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
    var focused: Item? {
        guard !headerFocused, !accountFocused, upPage?.followFocused != true, upPage?.browsing != false,
              rows.indices.contains(row), rows[row].items.indices.contains(column) else { return nil }
        return rows[row].items[column]
    }
    /// 当前这一排选中的那一项，不管焦点是不是暂时去了左边栏（上半屏的标题和背景用它，免得一开栏就换内容）
    var highlighted: Item? {
        guard rows.indices.contains(row), rows[row].items.indices.contains(column) else { return nil }
        return rows[row].items[column]
    }
    /// 给按键音用：焦点变了才出声
    var focusKey: String {
        "\(tab.rawValue)-\(headerFocused)-\(row)-\(column)-\(rows.count)-\(player.current?.bvid ?? "")"
            // 播放器里的清晰度栏、底下那排视频也算：在里面左右走才有按键声
            + "-\(player.qualityMenuVisible)-\(player.qualityIndex)-\(player.relatedVisible)-\(player.relatedIndex)"
            + "-\(player.panelVisible)-\(player.panelIndex)-\(String(describing: player.panelList))-\(player.panelListIndex)"
            + "-\(player.shelf)-\(player.episodeFocus)"
            + "-\(settingsOpen)-\(settingIndex)-\(String(describing: settingList))-\(settingListIndex)"
            + "-\(accountFocused)-\(accountMenuOpen)-\(accountIndex)-\(confirmingLogout)-\(cardMenu?.count ?? 0)-\(cardMenuIndex)"
            // 左边栏的高亮（上下滑时先动它，停一下才换页）、UP 主页的排序和关注、搜索框
            + "-\(sidebarTab.rawValue)-\(editing)-\(upPage?.sort.rawValue ?? -1)-\(upPage?.sortFocused ?? false)"
            + "-\(upPage?.followFocused ?? false)-\(upPage?.browsing ?? false)"
            // 看视频时键盘左右是快进快退十秒：进度也算，这样每一下都有声音
            + "-\(Int(player.time))"
    }

    private func wirePlayer() {
        player.cookie = { [weak self] in await self?.cookieHeader() ?? "" }
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
        for tab in Tab.allCases where isStale(tab) { load(tab) }
    }

    private func isStale(_ tab: Tab) -> Bool {
        tab != .search && Date().timeIntervalSince(loadedAt[tab] ?? .distantPast) > 600
    }

    func reload() {
        loadedAt = [:]
        load(tab == .search ? .home : tab)
    }

    private func load(_ target: Tab) {
        guard target != .search, !loadingTabs.contains(target) else { return }
        loadingTabs.insert(target)
        failedTabs.remove(target)
        Task { @MainActor in
            let cookie = await cookieHeader()
            // 账号信息和内容一起取，不排队；只有第一次（还不知道是谁）才先等它
            async let me = BiliAPI.account(cookie: cookie)
            let known = self.account
            let account = known != nil ? known : await me
            if known == nil { self.account = account }
            var built: [Row] = []
            func add(_ id: String, _ title: String, _ videos: [BiliVideo]) {
                if !videos.isEmpty { built.append(Row(id: id, title: title, items: videos.map(Item.video))) }
            }
            switch target {
            case .home:
                async let recent = BiliAPI.history(cookie: cookie)
                async let picks = BiliAPI.recommended(cookie: cookie)
                async let hot = BiliAPI.popular(cookie: cookie)
                let (history, recommended, popular) = await (recent, picks, hot)
                // 历史记录不带播放数：给"继续观看"最前面的几个补上（补不到就不显示，不影响别的）
                var unfinished = history.filter { $0.progress != -1 }
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
                if built.isEmpty { self.failedTabs.insert(.home) }
            case .following:
                // 每个关注的 UP 主一排（全部都有，不管最近更没更新），谁最近更新谁在前
                let people = await BiliAPI.followings(mid: account?.mid ?? 0, cookie: cookie)
                if let key = await currentSigningKey(cookie: cookie), !people.isEmpty {
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
            case .discover:
                async let ranked = BiliAPI.ranking(cookie: cookie)
                async let week = BiliAPI.weekly(cookie: cookie)
                async let best = BiliAPI.classics(cookie: cookie)
                let (ranking, weekly, classics) = await (ranked, week, best)
                add("ranking", "排行榜", ranking)
                add("weekly", "每周必看", weekly)
                add("classics", "入站必刷", classics)
                if built.isEmpty { self.failedTabs.insert(.discover) }
            case .mine:
                async let recent = BiliAPI.history(cookie: cookie, count: 30)
                async let saved = BiliAPI.favorites(mid: account?.mid ?? 0, cookie: cookie)
                async let later = BiliAPI.watchLater(cookie: cookie)
                let (history, favorites, watchLater) = await (recent, saved, later)
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
            if known != nil {
                // 顺便更新登录状态。取不到不等于没登录（可能只是网络抖了一下）：登录信息还在就保持原样
                if let fresh = await me { self.account = fresh }
                else if !cookie.contains("SESSDATA=") { self.account = nil }
            }
            if target == .home {   // 首页重新取过，翻页从头算
                for id in ["recommended", "popular"] { self.pages[id] = 1; self.exhausted.remove(id) }
            }
            self.content[target] = built
            self.loadedAt[target] = Date()
            self.loadingTabs.remove(target)
            self.warmFocused()
        }
    }

    /// 请求签名用的密钥，半小时内重复用同一个
    private func currentSigningKey(cookie: String) async -> String? {
        if let cached = signingKey, Date().timeIntervalSince(cached.at) < 1800 { return cached.key }
        guard let key = await BiliAPI.signingKey(cookie: cookie) else { return nil }
        signingKey = (key, Date())
        return key
    }

    /// 读到的登录信息记一会儿：每个请求都去问网页那边要，既慢又要一直开着一个隐形网页
    private var cookieCache: (value: String, at: Date)?

    /// 登录状态存在这个应用自己的网页数据里（和内置网页共用）；这里只把它带给请求。
    /// fresh = 不用记着的，现在去读（等登录、退出登录时用）
    private func cookieHeader(fresh: Bool = false) async -> String {
        if !fresh, let cached = cookieCache, Date().timeIntervalSince(cached.at) < 600 { return cached.value }
        guard let profile = tv?.profile else { return "" }
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
        var mine = cookies.filter { $0.domain.hasSuffix("bilibili.com") }
        if mine.isEmpty, profile.websiteDataStore == WKWebsiteDataStore.default() {
            // 默认数据仓库和系统的 cookie 存储是同一份文件，直接从那里读
            mine = (HTTPCookieStorage.shared.cookies ?? []).filter { $0.domain.hasSuffix("bilibili.com") }
        }
        let value = mine.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        if !value.isEmpty {
            cookieCache = (value, Date())
            cookieWaker = nil   // 读到了就把隐形网页关掉，不让它一直占着一个网页进程
        }
        return value
    }

    /// 焦点落在哪个视频上，就提前把它准备好
    private func warmFocused() {
        guard tv?.bilibiliOpen == true else { return }   // 还没进哔哩哔哩时只取列表，不准备视频
        // 设置页盖在上面时不准备（不然改了清晰度，回去点开的还是按旧清晰度准备好的那个）
        if !editing, !settingsOpen, case .video(let video) = focused { player.warm(video) } else { player.warm(nil) }
    }

    // MARK: 按键

    func handle(_ command: RemoteCommand) {
        if player.current != nil {
            if player.handle(command) == .close { player.stop() }
            return
        }
        defer { warmFocused() }
        if editing {
            // 键盘打字直接进输入框，这里只处理手机遥控器发来的文字和确认 / 返回
            switch command {
            case .text(let text): query += text
            case .deleteBackward: if !query.isEmpty { query.removeLast() }
            case .select: submitSearch()
            case .back: stopEditing()
            default: break
            }
            return
        }
        if settingsOpen {
            handleSettings(command)
            return
        }
        if let menu = cardMenu {
            switch command {
            case .move(.up): withAnimation(Motion.focus) { cardMenuIndex = max(0, cardMenuIndex - 1) }
            case .move(.down): withAnimation(Motion.focus) { cardMenuIndex = min(menu.count - 1, cardMenuIndex + 1) }
            case .select:
                let chosen = menu.indices.contains(cardMenuIndex) ? menu[cardMenuIndex] : nil
                withAnimation(Motion.focus) { cardMenu = nil }
                if let chosen { run(chosen) }
            case .back, .move(.left), .move(.right): withAnimation(Motion.focus) { cardMenu = nil }
            default: break
            }
            return
        }
        if accountMenuOpen {
            let actions = accountActions
            switch command {
            case .move(.up): withAnimation(Motion.focus) { accountIndex = max(0, accountIndex - 1) }
            case .move(.down): withAnimation(Motion.focus) { accountIndex = min(actions.count - 1, accountIndex + 1) }
            case .select:
                let chosen = actions.indices.contains(accountIndex) ? actions[accountIndex] : nil
                withAnimation(Motion.focus) { accountMenuOpen = false; accountFocused = false }
                if let chosen { perform(chosen) }
            case .back, .move(.left): withAnimation(Motion.focus) { accountMenuOpen = false }
            default: break
            }
            return
        }
        if accountFocused {
            switch command {
            case .select: withAnimation(Motion.focus) { accountIndex = 0; accountMenuOpen = true }
            case .move(.down), .back:
                // 在 UP 主的主页里，头像下面是关注按钮；别的页直接回到内容
                withAnimation(Motion.focus) { accountFocused = false; if upPage != nil { upPage?.followFocused = true } }
            case .move(.left): withAnimation(Motion.focus) { accountFocused = false; headerFocused = true }
            default: break
            }
            return
        }
        if upPage?.followFocused == true {
            switch command {
            case .select: toggleFollow()
            case .move(.down): withAnimation(Motion.focus) { upPage?.followFocused = false; upPage?.armed = false; upPage?.sortFocused = true }
            case .move(.up): withAnimation(Motion.focus) { upPage?.followFocused = false; upPage?.armed = false; accountFocused = true }
            case .move(.left): withAnimation(Motion.focus) { upPage?.followFocused = false; upPage?.armed = false; headerFocused = true }
            case .back: leaveUpPage()
            default: break
            }
            return
        }
        if let page = upPage, page.sortFocused, !page.browsing, !headerFocused {
            switch command {
            case .move(.left):
                if page.sort.rawValue > 0 { setSort(UpPage.Sort(rawValue: page.sort.rawValue - 1) ?? .latest) }
                else { withAnimation(Motion.focus) { headerFocused = true } }
            case .move(.right): if let next = UpPage.Sort(rawValue: page.sort.rawValue + 1) { setSort(next) }
            case .move(.up): withAnimation(Motion.focus) { upPage?.sortFocused = false; upPage?.followFocused = true }
            case .move(.down), .select:
                if !rows.isEmpty {
                    withAnimation(Motion.navigate) { upPage?.sortFocused = false; upPage?.browsing = true }
                    warmFocused()
                }
            case .back: leaveUpPage()
            default: break
            }
            return
        }
        if headerFocused {
            switch command {
            case .move(.up): step(-1)
            case .move(.down): step(1)
            case .move(.right), .select:
                commitSidebar()
                if tab == .search {
                    // 搜索页：左边栏收起，输入框直接可以打字。已有结果时按右是去结果，按确认才是重新输入。
                    if case .move = command, !rows.isEmpty { withAnimation(Motion.focus) { headerFocused = false } }
                    else { withAnimation(Motion.focus) { headerFocused = false; editing = true } }
                } else if !rows.isEmpty {
                    withAnimation(Motion.focus) { headerFocused = false }
                }
            // 左边栏是盖在右边内容之上的二级菜单：按一下 Esc 永远是收起它、回到右边
            //（哪怕右边暂时只有一个搜索框）。离开哔哩哔哩要长按 Esc。
            case .back:
                commitSidebar()
                withAnimation(Motion.focus) { headerFocused = false }
            default: break
            }
            return
        }
        switch command {
        case .move(.left):
            if column > 0 { setColumn(column - 1) } else { withAnimation(Motion.focus) { headerFocused = true } }
        case .move(.right): setColumn(column + 1)
        case .move(.up):
            if row > 0 { withAnimation(Motion.navigate) { setRow(row - 1) } }
            else if upPage != nil {   // UP 主页：第一排再按上，回到三个排序那里
                player.warm(nil)
                withAnimation(Motion.navigate) { upPage?.browsing = false; upPage?.sortFocused = true }
            }
            else if tab == .search { withAnimation(Motion.focus) { editing = true } }   // 从结果往上回到输入框
            else { withAnimation(Motion.focus) { accountFocused = true } }               // 最上面一排再按上：到右上角的头像
        case .move(.down): if row < rows.count - 1 { withAnimation(Motion.navigate) { setRow(row + 1) } }
        case .select:
            if tab == .search, rows.isEmpty { withAnimation(Motion.focus) { editing = true } }   // 焦点在搜索框上
            else { activate() }
        case .back:
            // 在某个 UP 主的主页里：Esc 回到进来之前的那一页。其他时候在内容里短按 Esc 不做任何事。
            if upPage != nil { leaveUpPage() }
            // 搜索结果的上一级是搜索框：Esc 收起结果，回到搜索框（搜索词留着，按确认可以接着改）
            else if tab == .search, !rows.isEmpty {
                player.warm(nil)
                withAnimation(Motion.navigate) { content[.search] = [] }
            }
        case .playPause: if case .video = focused { activate() }
        default: break
        }
    }

    /// 转盘沿着哪个方向走（见 TVController.wheelRunsHorizontally）
    var wheelRunsHorizontally: Bool {
        if player.current != nil { return !player.panelVisible }                // 相关视频、清晰度栏是横的；右边的面板是竖的
        if settingsOpen { return false }                                        // 设置是竖的
        if cardMenu != nil || accountMenuOpen || headerFocused { return false }  // 菜单、左边栏是竖的
        if accountFocused || upPage?.followFocused == true { return false }     // 头像、关注按钮：往下回到内容
        return true                                                             // 视频排、三个排序
    }

    /// 左边栏里高亮停在哪一项。上下滑时先只移动它，停下来一会儿才换右边的内容——换一页要重画好几排卡片、
    /// 给选中的视频预热、有时还要联网，每走一格都换的话前几下会卡
    @Published private(set) var sidebarTab: Tab = .home
    private var sidebarCommit: Task<Void, Never>?

    private func step(_ delta: Int) {
        let all = Tab.allCases
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

    func select(_ target: Tab) {
        cardMenu = nil
        accountMenuOpen = false
        accountFocused = false
        if settingsOpen { withAnimation(Motion.navigate) { settingsOpen = false; settingList = nil } }
        if editing, target != .search { stopEditing() }
        sidebarCommit?.cancel()
        sidebarCommit = nil
        sidebarTab = target
        withAnimation(Motion.navigate) { tab = target; upPage = nil }
        if content[target] == nil || isStale(target) { load(target) }
        warmFocused()
    }

    private func setColumn(_ value: Int) {
        guard rows.indices.contains(row) else { return }
        let clamped = max(0, min(rows[row].items.count - 1, value))
        guard clamped != column else { return }
        withAnimation(stepMotion()) { columns[rows[row].id] = clamped }
        // 往后几张的封面先下好：甩着翻会一下走好几张，不然翻过去是一排空的灰块
        for case .video(let video) in rows[row].items.dropFirst(clamped + 1).prefix(12) {
            if let url = video.cover, BiliImageCache.shared.image(for: url) == nil {
                Task { @MainActor in _ = await BiliImageCache.shared.load(url) }
            }
        }
        loadMoreIfNeeded()
    }

    private var lastStep = Date.distantPast
    /// 单按一下用平常的动画；连着走（按住方向键、双指一甩）时换一条短的，不然每一下都重新起一段弹簧，忽快忽慢
    private func stepMotion() -> Animation {
        let now = Date()
        defer { lastStep = now }
        return now.timeIntervalSince(lastStep) < 0.2 ? .smooth(duration: 0.16) : Motion.focus
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
        Task { @MainActor in
            let cookie = await cookieHeader()
            let more: [BiliVideo]
            switch id {
            case "recommended": more = await BiliAPI.recommended(cookie: cookie, page: next)
            case "popular": more = await BiliAPI.popular(cookie: cookie, page: next)
            default: more = await BiliAPI.search(keyword, cookie: cookie, page: next)
            }
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

    func focus(row r: Int, column c: Int) {
        guard rows.indices.contains(r) else { return }
        withAnimation(Motion.focus) {
            headerFocused = false; accountFocused = false
            if upPage != nil { upPage?.browsing = true; upPage?.sortFocused = false; upPage?.followFocused = false; upPage?.armed = false }
            setRow(r); columns[rows[r].id] = c
        }
    }

    func activate() {
        guard let item = focused else { if failed { reload() }; return }
        perform(item)
    }

    private func perform(_ item: Item) {
        guard let tv else { return }
        switch item {
        case .video(let video):
            player.play(video)
        case .login:
            let url = URL(string: "https://passport.bilibili.com/login")!
            let service = Service(id: Self.loginID, name: "哔哩哔哩", kind: .web(url), accent: "#FB7299", deep: "#3A0F1E")
            tv.playbackCoordinator.playWeb(service, url: url)
            watchForLogin()
        case .empty:
            break
        case .user(let user):
            openUp(user)
        case .refresh:
            reload()
        case .settings:
            openSettings()
        case .logout:
            // 退出登录之前先问一次；默认停在"取消"上，误按确认不会退出
            withAnimation(Motion.focus) {
                accountFocused = true
                accountMenuOpen = true
                confirmingLogout = true
                accountIndex = 0
            }
        case .keepLogin:
            withAnimation(Motion.focus) { confirmingLogout = false; accountIndex = 2 }
        case .confirmLogout:
            withAnimation(Motion.focus) { accountMenuOpen = false; accountFocused = false }
            Task { @MainActor in
                let store = tv.profile.websiteDataStore.httpCookieStore
                for cookie in await store.allCookies() where cookie.domain.hasSuffix("bilibili.com") {
                    await store.deleteCookie(cookie)
                }
                for cookie in HTTPCookieStorage.shared.cookies ?? [] where cookie.domain.hasSuffix("bilibili.com") {
                    HTTPCookieStorage.shared.deleteCookie(cookie)
                }
                tv.showToast("已退出登录")
                self.account = nil
                self.cookieCache = nil
                self.content = [:]
                self.reload()
            }
        }
    }

    func dismissAccount() { accountMenuOpen = false; accountFocused = false }

    /// 离开哔哩哔哩、换页、用触控板点别处时：把各种开着的小东西都收起来，下次进来是干净的
    func resetTransient() {
        if editing { editing = false; tv?.window?.makeFirstResponder(nil) }
        cardMenu = nil
        cardMenuVideo = nil
        accountMenuOpen = false
        accountFocused = false
        headerFocused = false
        upPage?.followFocused = false
        upPage?.armed = false
        settingsOpen = false
        settingList = nil
    }

    // MARK: UP 主的主页

    func openUp(_ user: BiliUser, returnTo video: BiliVideo? = nil) {
        let id = "uppage-\(user.mid)"
        columns[id] = 0
        withAnimation(Motion.navigate) {
            headerFocused = false
            accountFocused = false
            upPage = UpPage(user: user, returnTo: video)
        }
        Task { @MainActor in
            let cookie = await cookieHeader()
            async let followed = BiliAPI.isFollowing(mid: user.mid, cookie: cookie)
            async let card = BiliAPI.userCard(mid: user.mid, name: user.name, cookie: cookie)
            let key = await currentSigningKey(cookie: cookie)
            let following = await followed
            let full = await card
            var uploads: [BiliVideo] = []
            if let key { uploads = await BiliAPI.uploads(mid: user.mid, name: full.name, key: key, cookie: cookie).videos }
            guard self.upPage?.user.mid == user.mid else { return }
            withAnimation(Motion.navigate) {
                self.upPage?.lists[.latest] = uploads
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
        withAnimation(Motion.navigate) { upPage = nil }
        if let back { player.play(back, startPaused: true) }
    }

    private func showUploads(_ videos: [BiliVideo], sort: UpPage.Sort) {
        guard let mid = upPage?.user.mid else { return }
        let id = "uppage-\(mid)-\(sort.rawValue)"
        columns[id] = 0
        upPage?.row = 0
        upPage?.rows = videos.isEmpty ? [] : [Row(id: id, title: sort.title, items: videos.map(Item.video))]
    }

    /// 换排序：取过的直接换上，没取过的现取（取的时候先留着原来那排，不闪）
    private func setSort(_ sort: UpPage.Sort) {
        guard let page = upPage, page.sort != sort else { return }
        withAnimation(Motion.focus) { upPage?.sort = sort }
        if let cached = page.lists[sort] {
            withAnimation(Motion.navigate) { showUploads(cached, sort: sort) }
            return
        }
        let user = page.user
        Task { @MainActor in
            let cookie = await cookieHeader()
            guard let key = await currentSigningKey(cookie: cookie) else { return }
            let videos = await BiliAPI.uploads(mid: user.mid, name: user.name, key: key, cookie: cookie, order: sort.order).videos
            guard self.upPage?.user.mid == user.mid else { return }
            if !videos.isEmpty { self.upPage?.lists[sort] = videos }
            if self.upPage?.sort == sort { withAnimation(Motion.navigate) { self.showUploads(videos, sort: sort) } }
        }
    }

    func tapSort(_ index: Int) {
        guard upPage != nil, let sort = UpPage.Sort(rawValue: index) else { return }
        withAnimation(Motion.focus) {
            headerFocused = false; accountFocused = false
            upPage?.browsing = false; upPage?.followFocused = false; upPage?.armed = false; upPage?.sortFocused = true
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
            tv.showToast(following ? "已取消关注 \(user.name)" : "已关注 \(user.name)")
        }
    }

    // MARK: 设置页（头像菜单里的"设置"）

    /// 设置项：清晰度、倍速（和看视频时右边面板里的是同一个值）、字幕（有字幕时自动打开）、弹幕
    enum Setting: Int, CaseIterable { case quality, speed, subtitles, danmaku }
    /// 清晰度、倍速选了以后，右边换成一列档位；弹幕选了以后换成弹幕的几项设置（按确认换下一个值）
    enum SettingList: Hashable { case quality, speed, danmaku }
    /// 设置里能选的清晰度（从高到低；账号或视频没有那一档时自动用能给的最高一档）
    static let settableQualities = [120, 116, 112, 80, 64, 32]

    @Published private(set) var settingsOpen = false
    @Published private(set) var settingIndex = 0
    @Published private(set) var settingList: SettingList?
    @Published private(set) var settingListIndex = 0

    private func openSettings() {
        withAnimation(Motion.focus) { accountMenuOpen = false; accountFocused = false; headerFocused = false }
        settingIndex = 0
        settingList = nil
        player.warm(nil)
        withAnimation(Motion.navigate) { settingsOpen = true }
    }

    /// 设置页：上下选一行，确认改（清晰度、倍速换成一列档位，字幕直接开 / 关）；返回回到头像上
    private func handleSettings(_ command: RemoteCommand) {
        if let list = settingList {
            let count = switch list {
            case .quality: Self.settableQualities.count
            case .speed: BilibiliNativePlayer.speeds.count
            case .danmaku: player.danmakuOptions.count
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
        case .back:
            withAnimation(Motion.navigate) { settingsOpen = false }
            withAnimation(Motion.focus) { accountFocused = true }   // 从头像进来的，回到头像上
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
        case .danmaku:
            withAnimation(Motion.focus) { player.cycleDanmakuOption(index) }
            objectWillChange.send()
            return   // 这一列留着，可以接着改别的
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

    // MARK: 卡片菜单（在视频卡片上长按确认）

    /// 返回是否真的打开了菜单（不在视频卡片上就不会打开）
    @discardableResult
    func openCardMenu() -> Bool {
        guard player.current == nil, !editing, cardMenu == nil, case .video(let video)? = focused else { return false }
        var actions: [CardAction] = []
        if video.ownerMid > 0, upPage?.user.mid != video.ownerMid { actions.append(.upPage) }
        if account != nil {
            if video.aid > 0 { actions.append(.favorite) }
            actions.append(.watchLater)
        }
        guard !actions.isEmpty else { return false }
        player.warm(nil)
        cardMenuVideo = video
        withAnimation(Motion.focus) { cardMenuIndex = 0; cardMenu = actions }
        return true
    }

    func tapCardMenu(_ index: Int) {
        guard let menu = cardMenu, menu.indices.contains(index) else { return }
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

    /// 用触控板点头像：焦点过去并打开 / 收起菜单（不管刚才焦点在哪）
    func tapAccount() {
        guard player.current == nil, !editing else { return }
        if settingsOpen { withAnimation(Motion.navigate) { settingsOpen = false; settingList = nil } }
        withAnimation(Motion.focus) {
            headerFocused = false
            accountFocused = true
            accountIndex = 0
            accountMenuOpen.toggle()
        }
    }

    /// 用触控板点菜单里的某一项
    func tapAccountAction(_ index: Int) {
        guard accountMenuOpen, accountActions.indices.contains(index) else { return }
        accountIndex = index
        handle(.select)
    }

    // MARK: 搜索

    /// 取消输入：留在右边（有结果就在结果上，没有就在搜索框上），不会跳去左边栏
    func stopEditing() {
        guard editing else { return }
        endEditing()
    }

    private func endEditing() {
        editing = false
        tv?.window?.makeFirstResponder(nil)
    }

    func submitSearch() {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { stopEditing(); return }
        endEditing()
        headerFocused = false
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
            let userRow = users.isEmpty ? [] : [Row(id: "search-users", title: "UP 主", items: users.map(Item.user))]
            // 搜的像是一个人的名字（最匹配的 UP 主名字里含有搜索词），UP 主就排在前面；否则视频在前
            let personFirst = users.first.map { $0.name.localizedCaseInsensitiveContains(keyword) } ?? false
            self.upPage = nil
            self.content[.search] = personFirst ? userRow + videoRow : videoRow + userRow
            let nothing = results.isEmpty && users.isEmpty
            if self.tab == .search { withAnimation(Motion.focus) { self.headerFocused = false } }
            if nothing { self.tv?.showToast("没有找到「\(keyword)」") }
            self.warmFocused()
        }
    }

    /// 登录页开着的时候每两秒看一眼，登录成功就自动回到列表
    private func watchForLogin() {
        loginWatch?.cancel()
        loginWatch = Task { @MainActor [weak self] in
            for _ in 0..<150 {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, let tv = self.tv else { return }
                guard case .player(let service) = tv.mode, service.id == Self.loginID else { return }
                if let account = await BiliAPI.account(cookie: await self.cookieHeader(fresh: true)) {
                    self.cookieCache = nil
                    tv.returnToBilibili()
                    tv.showToast("已登录：\(account.name)")
                    return
                }
            }
        }
    }

    /// 登录页（网页）里的返回键：回到哔哩哔哩，而不是回主屏
    func handleInPlayer(_ command: RemoteCommand, service: Service) -> Bool {
        guard let tv, service.id == Self.loginID else { return false }
        if case .back = command { tv.returnToBilibili(); return true }
        return false
    }
}

extension TVController {
    func openBilibili() {
        if mode != .launcher { goHome() }   // 比如从手机上直接点开哔哩哔哩时，先把正在放的别的东西收掉
        bilibiliStore.tv = self
        sheets.closeDismissible()
        movies = nil
        bilibiliOpen = true
        bilibiliStore.opened()
    }

    func closeBilibili() {
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
        bilibiliStore.reload()   // 登录状态变了，内容要重新取
        bringToFront()
    }
}
