import AppKit
import SwiftUI
import WebKit

/// 浏览器（电视上的 Safari）。开始页最上面是和网页上一样的标签栏，下面是地址栏（搜索或输入网址），
/// 再下面一排排是 Safari 的个人收藏、常去的网站、最近看过的页面、阅读列表。
/// 空白标签页（Safari 的 Start Page）和别的标签页一样是一个真的标签：看着它时就是开始页，选的网站开在它里面。
/// "+" 总是再开一个（像 Safari 可以有好几个空白标签页）。焦点下到那几排里时标签栏收上去、下面的跟着上移；
/// 回到地址栏再按上，标签栏回来；再按上进标签栏。
///
/// 开着网页时，最上面一条标签栏（像 Safari 的标签栏，见 BrowserTopBar）：后退、前进、一样宽的一个个标签、"+"、"⋯"，
/// 网页在它下面。网页里按返回，或者在页面最上面再按上，焦点进标签栏；在标签栏里按下回到网页。
/// 选中正在看的那个标签，就在标签栏里改地址（网址整个选中，打字换掉，回车打开，返回不改）。
/// 选中的那个标签，网站图标换成关闭按钮（×）：从标签往左一格就是它，往右回到标签。关掉正在看的，换到右边那个，
/// 没有就左边那个，都没有回开始页（和 Safari 一样）。
/// 视频铺满时标签栏收起，按上或返回才盖在视频上面出来。
///
/// 只有正在看的那个标签页有网页视图（一个网页的进程要一两百兆，多的近一个 G），别的只留地址、标题、
/// 前进后退的记录和一张截图，换过去时重新载入（先放截图，载好了换成真的网页）。
/// 无痕标签页用自己的一份不落盘的网站数据（WKWebsiteDataStore.nonPersistent），什么都不记：
/// 不进"最近浏览"、不存标签页、截图只在内存里；最后一个无痕标签页关掉（或离开浏览器）时那份数据一起扔掉。
///
/// Safari 的记录要 Mac TV 有"完全磁盘访问权限"才读得到（见 SafariLibrary）；没有的时候这里放一张卡片告诉你怎么打开。
/// 在 Mac TV 里看过的页面自己也记一份，和 Safari 的历史混在一起按时间排
@MainActor
final class BrowserStore: ObservableObject {
    static let appID = "browser"
    static let pageID = "browser-page"
    /// 最多留几个标签页（再开新的，最早的那个关掉）
    static let maxTabs = 12

    struct Row: Identifiable, Equatable {
        enum Style: Equatable { case tiles, cards, notice }
        let id: String
        let title: String
        let style: Style
        var pages: [WebPage]
    }

    /// 开始页的焦点：地址栏，或者某一排的某一个
    enum Focus: Equatable { case field, item(row: Int, column: Int) }

    /// 标签栏上的焦点（nil：焦点在网页里，或者开始页的地址栏、那几排里）。close：那个标签的关闭按钮（×）
    enum BarFocus: Hashable { case back, forward, tab(String), close(String), newTab, more }

    /// 空白标签页（还没打开网站，Safari 叫它 Start Page）的网址。和别的标签页一样存着
    nonisolated static let blankURL = URL(string: "about:blank")!

    /// "⋯"菜单里的一项。网页缩放是一行"Zoom  ‹ Medium ›"，和设置里的步进行一样：左右换一档，到头停住
    enum MenuItem: CaseIterable {
        case newPrivateTab, reload, zoom, addFavorite, removeFavorite, history, closeTab, startPage

        /// 网页上的；Add to Favorites 在这一页已经是个人收藏时换成 Remove from Favorites（见 menuRows）
        static let rows: [[MenuItem]] = [[.newPrivateTab], [.reload], [.zoom], [.addFavorite], [.history], [.closeTab], [.startPage]]
        /// 开始页上没有网页：不能重新载入、缩放，已经在开始页了
        static let startPageRows: [[MenuItem]] = [[.newPrivateTab], [.history], [.closeTab]]

        var name: String {
            switch self {
            case .newPrivateTab: "New Private Tab"
            case .reload: "Reload Page"
            case .zoom: "Zoom"
            case .closeTab: "Close Tab"
            case .startPage: "Open Start Page"
            case .history: "Show All History"
            case .addFavorite: "Add to Favorites"
            case .removeFavorite: "Remove from Favorites"
            }
        }

        var symbol: String {
            switch self {
            case .newPrivateTab: "hand.raised"
            case .reload: "arrow.clockwise"
            case .zoom: "textformat.size"
            case .closeTab: "xmark"
            case .startPage: "square.grid.2x2"
            case .history: "clock"
            case .addFavorite: "star"
            case .removeFavorite: "star.slash"
            }
        }
    }

    /// 开始页是谁的：决定选了一个网站以后开在哪
    enum Origin: Equatable {
        /// 从网页的标签栏返回到这里：没有"正在看的"标签，选的网站开成新标签页，返回回主屏
        case home
        /// 一个空白标签页（"+"、New Private Tab、Open Start Page，或者换到了它）：选的网站就开在它里面
        case blank(String)
    }

    /// 正在看的网页（标签栏上显示的）
    struct PageInfo: Equatable {
        var canGoBack = false
        var canGoForward = false
        var zoom = BrowserZoomLevel.medium.zoom
    }

    weak var tv: TVController?

    // 开始页
    /// 开始页开着（不是网页）
    @Published private(set) var onStartPage = false
    /// 开始页上的标签栏露着：一开始是；焦点下到那几排里收上去，回到地址栏再按上又出来
    @Published private(set) var startBarShown = true
    /// 开始页的标签栏露着、停稳了：这时才跟踪鼠标悬停（它滑的时候也跟踪的话，SwiftUI 每一帧都要重算光标底下是谁）
    @Published private(set) var startBarSettled = true
    @Published private(set) var rows: [Row] = []
    @Published private(set) var focus: Focus = .field
    /// 正在打网址：开始页的地址栏，或者（editingInBar）标签栏上正在看的那个标签
    @Published private(set) var editing = false
    @Published private(set) var editingInBar = false
    /// 地址栏该拿着键盘却没拿到时加一，界面看到它变了就再去要一次
    @Published private(set) var focusRequest = 0
    func refocus() { focusRequest += 1 }
    @Published private(set) var query = ""
    /// 地址栏里是这一页的网址（在标签栏上改地址）：一打字就整个换掉，像选中了一样
    private(set) var replaceQuery = false
    /// 刚用"+"开出来的空白标签页，和开它时看着的那个标签：在开始页上按返回就当没开过（关掉它、回到那一个）
    private var returnTo: (blank: String, to: String)?
    @Published private(set) var access: SafariLibrary.Access = .missing
    @Published private(set) var origin: Origin = .home
    private var columns: [String: Int] = [:]
    private var loadedAt = Date.distantPast
    private var safari = SafariLibrary.Snapshot(access: .missing)

    // 标签页
    @Published private(set) var tabs: [BrowserTab] = []
    @Published private(set) var activeID: String?
    /// 最后看的普通标签页（正在看无痕的时候，存下来的是它）
    private var lastNormalID: String?
    /// 这次运行里离开过的标签页的样子（前进后退、滚到哪），换回去时恢复。只在内存里
    private var states: [String: Any] = [:]
    /// 标签页离开时的截图：换回去、网页还没载好时先放着它。内存里只留最近四张（一张两兆左右），普通标签页的在磁盘上也有
    private let snapshots = NSCache<NSString, NSImage>()
    /// 标签页、截图、看过的页面、每个网站的缩放存在哪：每个人（个人资料）一份。
    /// mainStorage 是第一个人的（就是原来的那一份，测试用自己的）；别的人的从他的 ProfileSpace 来
    private let mainStorage: BrowserTabStorage
    private var storage: BrowserTabStorage
    /// 开始页上 Safari 的那几排（个人收藏、常去的网站、Safari 的历史、阅读列表）是这台 Mac 主人自己的：只给第一个人看
    private(set) var showsSafari = true
    /// 无痕标签页共用的一份网站数据（不落盘）。最后一个无痕标签页关掉就扔掉
    private var privateStore: WKWebsiteDataStore?
    /// 无痕标签页里调的缩放：只在内存里，不记
    private var privateZoom: [String: Double] = [:]

    // 标签栏
    @Published private(set) var barFocus: BarFocus?
    @Published private(set) var menu: MenuItem?
    /// History 那一页开着（见 BrowserHistory.swift）
    @Published var historyState: BrowserHistoryState?
    /// 历史记录存在哪（每个人一份）
    var profileStorage: BrowserTabStorage { storage }
    /// Safari 的个人收藏（只有第一个人读；只读，不往 Safari 里写）
    var safariFavorites: [WebPage] { showsSafari ? safari.favorites : [] }
    /// 正在看的网页（开始页、空白标签页上没有）
    var currentPage: WebPage? {
        guard !onStartPage, let tab = activeTab, !tab.isBlank else { return nil }
        return WebPage(url: pageWebView?.url ?? tab.url, title: pageWebView?.title ?? tab.title)
    }
    var currentPageURL: URL? { currentPage?.url }
    /// 开始页上按住确认弹出的那一个的菜单（个人收藏：Open in New Tab、Rename、Edit Address…、Delete），见 BrowserFavorites.swift
    @Published var itemMenu: BrowserItemMenu?
    /// 刚按下的那个按钮：轻轻往下一沉再回来（和别处的按钮一样），一下就清掉
    @Published private(set) var pressed: BarFocus?
    private var pressTask: Task<Void, Never>?
    /// 网页里有视频铺满了（或者网页自己进了全屏）：标签栏收起，网页占满整个屏幕
    @Published private(set) var videoMode = false
    @Published private(set) var page = PageInfo()
    /// 换回一个标签页、网页还没画出来时先放的截图
    @Published private(set) var placeholder: NSImage?
    private var placeholderTask: Task<Void, Never>?
    private var observations: [NSKeyValueObservation] = []
    private var zoomedHost = ""

    /// space：在看的这个人（个人资料）不是第一个人时，用他自己的那一份
    init(storage: BrowserTabStorage = .standard, space: ProfileSpace? = nil) {
        mainStorage = storage
        let own = space.map { $0.isMain ? storage : .forProfile($0) } ?? storage
        self.storage = own
        showsSafari = space?.isMain ?? true
        let saved = own.load()
        tabs = saved.tabs
        activeID = saved.active
        lastNormalID = saved.active
        snapshots.countLimit = 4
    }

    var activeTab: BrowserTab? { tabs.first { $0.id == activeID } }
    var hasPrivateSession: Bool { privateStore != nil }
    /// 开始页是一个无痕的空白标签页
    var startsPrivate: Bool { tabs.first { $0.id == blankID }?.isPrivate ?? false }
    /// 标签栏露着：平时一直在；视频铺满时只有焦点在它上面才出来（盖在视频上）
    var barShown: Bool { !videoMode || barFocus != nil }

    /// 给按键音用：焦点变了才出声（开始页上的标签栏收起、出来也算）
    var focusKey: String { "\(focus)-\(rows.count)-\(startBarShown)-" + chromeKey + historyKey + itemMenuKey }
    /// 标签栏、菜单里的焦点
    var chromeKey: String { "\(String(describing: barFocus))-\(String(describing: menu))-\(tabs.count)-\(activeID ?? "")-\(editing)-\(page.zoom)" }

    // MARK: 标签栏上有什么（网页上、开始页上是同一条）

    /// 开始页是这个空白标签页的
    var blankID: String? {
        guard onStartPage, case .blank(let id) = origin, tabs.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    /// 标签栏上的标签（空白的也在里面）
    var barTabs: [BrowserTab] { tabs }

    /// 标签栏上"正在看的"那个（描一圈边，选它就是改地址）。从网页返回到开始页时没有
    var barCurrentID: String? { onStartPage ? blankID : activeID }
    var barIsPrivate: Bool { tabs.first { $0.id == barCurrentID }?.isPrivate ?? false }
    /// 开始页上没有网页：后退、前进不能用
    var barCanGoBack: Bool { !onStartPage && page.canGoBack }
    var barCanGoForward: Bool { !onStartPage && page.canGoForward }
    var menuRows: [[MenuItem]] {
        var rows = !onStartPage ? MenuItem.rows : barCurrentID == nil ? [[.newPrivateTab], [.history]] : MenuItem.startPageRows
        if isFavorite(currentPageURL) { rows = rows.map { $0 == [.addFavorite] ? [.removeFavorite] : $0 } }
        // 只剩一个空白标签页：没有可关的（离开浏览器是按住返回）
        return tabsClosable ? rows : rows.filter { $0 != [.closeTab] }
    }

    /// 标签能关：至少两个（最后一个没有 ×，也不在菜单里）
    /// 标签能关：不止一个，或者剩下的那一个开着网站（关掉它就变回开始页）。只剩一个空白标签页时没有 ×，也不在菜单里
    var tabsClosable: Bool { tabs.count > 1 || tabs.contains { !$0.isBlank } }

    /// refreshRows: false 是从一个开始页换到另一个（"+"、New Private Tab）：那几排还是刚才那些，不重排、不重读
    /// （重读 Safari 要一会儿，读完再重排一次，就是开新标签页一秒后又闪一下的那一下）
    func opened(origin: Origin = .home, refreshRows: Bool = true) {
        self.origin = origin
        onStartPage = true
        editing = false
        editingInBar = false
        replaceQuery = false
        query = ""
        if refreshRows { rebuildRows() }
        placeStartBar(focus == .field)
        if refreshRows, Date().timeIntervalSince(loadedAt) > 60 { reload() }
    }

    func reload() {
        loadedAt = Date()
        // Safari 的记录只给第一个人看：别的人连读都不读
        guard showsSafari else { apply(SafariLibrary.Snapshot(access: .missing)); return }
        Task.detached(priority: .userInitiated) {
            let snapshot = SafariLibrary.read()
            await MainActor.run { self.apply(snapshot) }
        }
    }

    private func apply(_ safari: SafariLibrary.Snapshot) {
        // 读的时候换了人：那是第一个人的 Safari，不放到别人的开始页上
        guard showsSafari || safari.access == .missing else { return }
        self.safari = safari
        access = safari.access
        seedFavorites(from: safari)
        withAnimation(Motion.navigate) { rebuildRows() }
    }

    func rebuildRows() {
        var built: [Row] = []
        if safari.access == .needsPermission {
            // 读不到 Safari：放一张说明，选它打开系统设置里那一页（打勾要你自己来）
            built.append(Row(id: "permission", title: "Safari History", style: .notice, pages: []))
        }
        // 个人收藏是 Web 自己的一份（第一个人第一次从 Safari 抄一份过来，以后只改自己的，不写 Safari），见 BrowserFavorites.swift
        if !favoritePages.isEmpty { built.append(Row(id: "favorites", title: "Favorites", style: .tiles, pages: favoritePages)) }
        if !safari.frequent.isEmpty { built.append(Row(id: "frequent", title: "Frequently Visited", style: .tiles, pages: safari.frequent)) }
        // 最近：Safari 的历史和在 Mac TV 里看过的合在一起，新的在前，同一页只留一次
        var seen = Set<String>()
        let recent = (safari.recent + storage.history).sorted { ($0.visited ?? .distantPast) > ($1.visited ?? .distantPast) }
            .filter { seen.insert($0.id).inserted }
        if !recent.isEmpty { built.append(Row(id: "recent", title: "Recently Visited", style: .cards, pages: Array(recent.prefix(40)))) }
        if !safari.readingList.isEmpty { built.append(Row(id: "reading", title: "Reading List", style: .cards, pages: safari.readingList)) }
        if built != rows { rows = built }   // 一样的不再赋一遍（不然读完 Safari 又整个重画一次）
        if case .item(let row, _) = focus, !rows.indices.contains(row) { focus = .field; placeStartBar(true) }
    }

    // MARK: 开始页的按键

    func column(of row: Int) -> Int {
        guard rows.indices.contains(row) else { return 0 }
        let count = max(1, rows[row].style == .notice ? 1 : rows[row].pages.count)
        return min(columns[rows[row].id] ?? 0, count - 1)
    }

    var focusedPage: WebPage? {
        guard case .item(let row, _) = focus, rows.indices.contains(row), rows[row].style != .notice else { return nil }
        let pages = rows[row].pages, column = column(of: row)
        return pages.indices.contains(column) ? pages[column] : nil
    }

    func handle(_ command: RemoteCommand) {
        if historyState != nil { handleHistory(command); return }   // History 那一页
        if itemMenu != nil { handleItemMenu(command); return }      // 按住确认弹出的那一个的菜单
        if editing { handleEditing(command); return }
        if barFocus != nil { _ = handleBar(command); return }   // 焦点在上面的标签栏里
        switch command {
        case .move(.down):
            switch focus {
            case .field: if !rows.isEmpty { setFocus(.item(row: 0, column: column(of: 0))) }
            case .item(let row, _): if row + 1 < rows.count { setFocus(.item(row: row + 1, column: column(of: row + 1))) }
            }
        case .move(.up):
            switch focus {
            case .item(let row, _): setFocus(row == 0 ? .field : .item(row: row - 1, column: column(of: row - 1)))
            // 地址栏上：标签栏收着就先放出来（回到一进来的样子），露着再按上才进标签栏
            case .field: if startBarShown { focusBar() } else { showStartBar() }
            }
        case .move(let direction) where direction == .left || direction == .right:
            guard case .item(let row, _) = focus, rows.indices.contains(row) else { return }
            let count = rows[row].style == .notice ? 1 : rows[row].pages.count
            let delta = direction == .left ? -1 : 1
            let next = max(0, min(count - 1, column(of: row) + delta))
            withAnimation(Motion.focus) { columns[rows[row].id] = next; focus = .item(row: row, column: next) }
        case .select:
            switch focus {
            case .field: startEditing()
            case .item(let row, _):
                if rows.indices.contains(row), rows[row].style == .notice { openPrivacySettings() }
                else if let page = focusedPage { open(page.url) }
            }
        case .back:
            // 在下面几排里：先回到地址栏（标签栏也回来）。在地址栏上：刚用"+"开的空白标签页当没开过，
            // 回到开它时看着的那一个；不然回主屏
            if case .item = focus { setFocus(.field); showStartBar(); return }
            if let back = returnTo, back.blank == blankID, let tab = tabs.first(where: { $0.id == back.to }) {
                discard(back.blank)
                open(tab)
            } else {
                tv?.goHome()
            }
        default: break
        }
    }

    /// 转盘、双指滑动：在一排里走，到头就停
    func canMove(_ direction: RemoteCommand.Direction) -> Bool {
        if historyState != nil { return historyCanMove(direction) }
        if itemMenu != nil { return direction == .up || direction == .down }
        if barFocus != nil { return chromeCanMove(direction) }
        guard case .item(let row, let column) = focus, rows.indices.contains(row) else {
            return direction == .up || (direction == .down && !rows.isEmpty)   // 地址栏上：往上是标签栏
        }
        switch direction {
        case .left: return column > 0
        case .right: return column < rows[row].pages.count - 1
        case .up: return true
        case .down: return row + 1 < rows.count
        }
    }

    func focus(row: Int, column: Int) {
        guard rows.indices.contains(row) else { return }
        stopEditing()   // 打着字时点了下面的一个：先收起地址栏，这一下打开的是点的那个
        withAnimation(Motion.focus) {
            columns[rows[row].id] = column
            focus = .item(row: row, column: column)
            barFocus = nil
            menu = nil
        }
        slideStartBar(false)
    }

    /// 焦点下到那几排里，标签栏跟着收上去（一个位移动画，下面的跟着上移）；回到地址栏时不动，再按上才出来
    private func setFocus(_ value: Focus) {
        withAnimation(Motion.navigate) { focus = value }
        if case .item = value { slideStartBar(false) }
    }

    private func showStartBar() { slideStartBar(true) }

    /// 标签栏收上去 / 放下来：一个位移动画，下面的跟着挪。放下来停稳了才再跟踪鼠标悬停
    private func slideStartBar(_ shown: Bool) {
        guard shown != startBarShown else { return }
        startBarSettled = false
        withAnimation(Motion.navigate, completionCriteria: .logicallyComplete) {
            startBarShown = shown
        } completion: { [weak self] in
            guard let self, self.startBarShown == shown else { return }
            self.startBarSettled = shown
        }
    }

    /// 不做动画地放好（刚打开开始页、焦点直接进标签栏）
    private func placeStartBar(_ shown: Bool) {
        startBarShown = shown
        startBarSettled = shown
    }

    // MARK: 地址栏

    func startEditing() {
        withAnimation(Motion.focus) { focus = .field; editing = true; editingInBar = false; barFocus = nil; menu = nil }
    }

    /// 打字（个人收藏改名、改网址）：焦点留在原来那一个上，字进 query（和地址栏一样的输入方式）
    func startTextEntry(_ text: String) {
        query = text
        replaceQuery = !text.isEmpty
        withAnimation(Motion.focus) { editing = true; editingInBar = false; barFocus = nil; menu = nil }
    }

    /// 在标签栏上改正在看的那个标签的地址（像 Safari）：网页上是它的网址（整个选中，一打字就换掉），
    /// 空白标签页上是空的。焦点留在这个标签上
    func startEditingInBar() {
        guard let id = barCurrentID, let tab = tabs.first(where: { $0.id == id }) else { return }
        query = tab.isBlank ? "" : (pageWebView?.url ?? tab.url).absoluteString
        replaceQuery = !query.isEmpty
        withAnimation(Motion.focus) { editing = true; editingInBar = true; barFocus = .tab(id); menu = nil }
    }

    /// 这一下点在正在打字的输入框里（输入框的编辑器、或者正在编辑的 NSTextField 里面）
    static func isInTextEditor(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard let content = window.contentView else { return false }
        var view = content.hitTest(content.convert(event.locationInWindow, from: nil))
        while let current = view {
            if current === window.firstResponder { return true }
            if let field = current as? NSTextField, field.currentEditor() != nil { return true }
            view = current.superview
        }
        return false
    }

    /// 鼠标（手机触控板的光标）点在了地址栏外面：和返回一样不改了，点到的东西照常收到这一下（见 main.swift）
    func endEditingByClick() {
        guard editing else { return }
        if editingInBar { leaveBar() }
        stopEditing()
    }

    func stopEditing() {
        guard editing else { return }
        let inBar = editingInBar
        withAnimation(Motion.focus) { editing = false; editingInBar = false }
        replaceQuery = false
        if inBar { query = "" }   // 标签栏上没打开就不改了：打的字不留（开始页的地址栏不显示它）
        tv?.window?.makeFirstResponder(nil)
        // 网页上：键盘还给网页（焦点还在标签栏上时，方向键照样归标签栏，见 main.swift）
        if inBar, let web = pageWebView { tv?.window?.makeFirstResponder(web) }
    }

    /// 打网址时的按键（开始页、标签栏一样）：手机上打的字、删除、确认是打开，返回是不改了
    private func handleEditing(_ command: RemoteCommand) {
        switch command {
        case .text(let text):
            query = replaceQuery ? text : query + text
            replaceQuery = false
        case .deleteBackward:
            if replaceQuery { query = ""; replaceQuery = false } else if !query.isEmpty { query.removeLast() }
        case .select: submit()
        case .back:
            // 不改了：标签变回原来的样子，焦点回网页（开始页上回地址栏）。不留在标签上，免得它一下变成白的
            // 先让焦点离开标签栏、再收起地址栏：反过来的话中间会画出一帧"选中的标签"（黑字、×）
            if editingInBar { leaveBar() }
            stopEditing()
        default: break
        }
    }

    /// 键盘在地址栏里打的字
    func typed(_ text: String) {
        query = text
        replaceQuery = false
    }

    /// 像网址的（有点、没空格，或者写了 http）直接打开；别的当成搜索词去搜。
    /// 网页上（标签栏里改的地址）在这个标签页里打开，焦点回网页；开始页上开在它的空白标签页里
    func submit() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let inBar = editingInBar
        stopEditing()
        guard !text.isEmpty, let url = Self.destination(text) else { return }
        if inBar, !onStartPage, let web = pageWebView {
            query = ""
            web.load(URLRequest(url: url))
            leaveBar()
            return
        }
        open(url)
    }

    /// 地址栏里打的字要去哪：像网址的就是它，别的用 Google 搜
    nonisolated static func destination(_ text: String) -> URL? {
        if let url = address(text) { return url }
        var search = URLComponents(string: "https://www.google.com/search")!
        search.queryItems = [URLQueryItem(name: "q", value: text)]
        return search.url
    }

    nonisolated static func address(_ text: String) -> URL? {
        let looksLikeAddress = text.contains("://") || (text.contains(".") && !text.contains(" ") && !text.hasSuffix("."))
        return looksLikeAddress ? WebsiteAddress.url(from: text) : nil
    }

    /// 开始页上选了一个网站：空白标签页的开始页就开在它里面；从网页返回来的开成新标签页
    /// （同一个网址已经开着就换到那个）
    func open(_ url: URL) {
        query = ""
        if let id = blankID, let tab = tabs.first(where: { $0.id == id }) {
            show(tab, loading: url)
        } else if let same = tabs.first(where: { !$0.isPrivate && $0.url == url }) {
            show(same)
        } else {
            newTab(url)
        }
    }

    /// 系统设置 → 隐私与安全性 → 完全磁盘访问权限（只是打开那一页，打勾要你自己来）
    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            SystemGuard.open(url)
        }
    }

    // MARK: 标签页

    /// 正在看的浏览器网页（不是浏览器的、或者网页没开着就是 nil）
    private var pageWebView: WKWebView? {
        guard let tv, case .player(let service) = tv.mode, service.id == Self.pageID else { return nil }
        return tv.webView
    }

    func newTab(_ url: URL, isPrivate: Bool = false) {
        let tab = BrowserTab(url: url, title: "", isPrivate: isPrivate)
        if isPrivate, privateStore == nil { privateStore = .nonPersistent() }
        tabs.append(tab)
        // 太多了：最早开的那个（不是正在看的）关掉
        while tabs.count > Self.maxTabs, let oldest = tabs.firstIndex(where: { $0.id != activeID && $0.id != tab.id }) {
            forget(tabs.remove(at: oldest))
        }
        save()
        show(tab)
    }

    /// 新开一个空白标签页（"+"、New Private Tab、Open Start Page）：标签栏最后多一个 Start Page，开始页是它的。
    /// from：开它时看着的那个标签（在开始页上按返回就回到那一个，这个空白的当没开过）
    func newBlankTab(isPrivate: Bool = false, from: String? = nil) {
        let tab = BrowserTab(url: Self.blankURL, title: "", isPrivate: isPrivate)
        if isPrivate, privateStore == nil { privateStore = .nonPersistent() }
        tabs.append(tab)
        while tabs.count > Self.maxTabs, let oldest = tabs.firstIndex(where: { $0.id != activeID && $0.id != tab.id && $0.id != from }) {
            forget(tabs.remove(at: oldest))
        }
        showBlank(tab)
        returnTo = from.map { (tab.id, $0) }
    }

    /// 换到一个标签：空白的是它的开始页，别的是网页
    func open(_ tab: BrowserTab) {
        if tab.isBlank { showBlank(tab) } else { show(tab) }
    }

    func resume(_ id: String) {
        if let tab = tabs.first(where: { $0.id == id }) { open(tab) } else { tv?.goHome() }
    }

    /// 从主屏打开浏览器：上次看的普通标签页还在就直接回到它（像 Safari；空白的就是它的开始页）。
    /// 一个都没有就开一个空白标签页
    func resumeLastTab() {
        guard let tab = tabs.first(where: { $0.id == activeID && !$0.isPrivate }) ?? tabs.last(where: { !$0.isPrivate }) else {
            newBlankTab()
            return
        }
        open(tab)
    }

    /// 看一个空白标签页：开始页是它的
    private func showBlank(_ tab: BrowserTab) {
        returnTo = nil
        openStartPage(origin: .blank(tab.id))
        activeID = tab.id
        if !tab.isPrivate { lastNormalID = tab.id }
        save()
    }

    /// 刚开的空白标签页不要了（开始页上按返回）：直接拿掉，不按关标签的规矩换别的（接着就换到开它时看着的那个）
    private func discard(_ id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].isBlank else { return }
        forget(tabs.remove(at: index))
        if activeID == id { activeID = nil }
        if lastNormalID == id { lastNormalID = nil }
        returnTo = nil
        dropPrivateSessionIfUnused()
        save()
    }

    /// 打开一个标签页（loading：在这个标签页里打开另一个网址）。正在看的那一页先记下样子、关掉它的网页视图，
    /// 同一时间只有一个网页视图
    func show(_ tab: BrowserTab, loading url: URL? = nil) {
        guard let tv else { return }
        if pageWebView != nil {
            suspendPage()
            tv.playbackCoordinator.closeWebPlayback()
        }
        stopEditing()
        onStartPage = false
        returnTo = nil
        barFocus = nil
        menu = nil
        videoMode = false
        activeID = tab.id
        if !tab.isPrivate { lastNormalID = tab.id }
        let address = url ?? tab.url
        if url != nil { update(tab.id) { $0.url = address; $0.title = "" } }
        let host = address.host ?? ""
        let zoom = zoom(for: host, isPrivate: tab.isPrivate)
        let state = states.removeValue(forKey: tab.id)
        if !tab.isPrivate { storage.addHistory(address, title: url == nil && !tab.title.isEmpty ? tab.title : host) }
        // 换回来的标签页：先放它离开时的截图，网页画出来了再换成真的（不白一下）
        placeholder = url == nil ? snapshotImage(for: tab) : nil
        if tab.isPrivate, privateStore == nil { privateStore = .nonPersistent() }
        tv.playbackCoordinator.playWeb(Service(id: Self.pageID, name: host.isEmpty ? "Web Page" : host, kind: .web(address),
                                               userAgent: UserAgent.safari, dpadNavigation: true),
                                       url: address, restoring: state, zoom: zoom,
                                       dataStore: tab.isPrivate ? privateStore : nil)
        save()
        guard let web = pageWebView else { placeholder = nil; return }   // 网站设成用 Brave 打开：没有标签栏
        // 恢复了样子再换网址：前进后退还在（恢复的那一下被换网址取消，不算出错）
        if url != nil, state != nil { web.load(URLRequest(url: address)) }
        attach(web, host: host)
        page = PageInfo(zoom: zoom)
        if placeholder != nil { schedulePlaceholderTimeout() }
    }

    /// 正在看的这一页要让出来（换标签页、回开始页、回主屏）：记下它的样子（前进后退、滚到哪）、地址、标题和一张截图。
    /// 网页视图由调用的人关掉
    private func suspendPage() {
        placeholderTask?.cancel()
        placeholder = nil
        guard let web = pageWebView else { detach(); return }
        if let tab = activeTab {
            if let state = web.interactionState { states[tab.id] = state }
            update(tab.id) { tab in
                if let url = web.url, url.scheme?.hasPrefix("http") == true { tab.url = url }
                if let title = web.title, !title.isEmpty { tab.title = title }
            }
            if let tab = activeTab { snapshot(web, for: tab) }
        }
        detach()
        save()
    }

    /// 离开浏览器（回主屏、开别的应用）：标签页都留着，无痕的也留着，再进来还在（Mac TV decision）
    func leave() {
        if pageWebView != nil { suspendPage() }
        onStartPage = false
        returnTo = nil
        barFocus = nil
        menu = nil
        videoMode = false
        stopEditing()
        snapshots.removeAllObjects()
        save()
    }

    /// Web quits (the App Switcher), someone else starts watching, or Mac TV quits: the private tabs close and their
    /// data goes (a TV is shared by the family; the next person mustn't find them).
    func closePrivateTabs() {
        let privateTabs = tabs.filter(\.isPrivate)
        if !privateTabs.isEmpty {
            tabs.removeAll(where: \.isPrivate)
            privateTabs.forEach(forget)
            if activeTab == nil { activeID = lastNormalID }
        }
        dropPrivateSessionIfUnused()
        save()
    }

    /// Memory pressure: the tab pictures kept decoded go (they're on disk; private tabs' come back when shown).
    func trimMemory() { snapshots.removeAllObjects() }

    /// 回到开始页（网页的标签栏上返回，或者看一个空白标签页）
    func openStartPage(origin: Origin) {
        if pageWebView != nil {
            suspendPage()
            tv?.playbackCoordinator.closeWebPlayback()
        }
        stopEditing()
        barFocus = nil
        menu = nil
        videoMode = false
        let fromStartPage = onStartPage
        if let tv {
            tv.setMode(.launcher)
            tv.playerFailure = nil
            tv.browserOpen = true
        }
        opened(origin: origin, refreshRows: !fromStartPage)
        if origin != .home { focus = .field }
        placeStartBar(focus == .field)
        tv?.bringToFront()
    }

    /// 关掉一个标签以后谁是正在看的（和 Safari 一样）：关的不是正在看的，还是原来那个；
    /// 是正在看的，换到它右边那个，没有就左边那个；一个都不剩是 nil（回开始页）。order 是标签栏上从左到右的顺序
    nonisolated static func currentAfterClosing(_ closing: String, in order: [String], current: String) -> String? {
        guard closing == current, let index = order.firstIndex(of: closing) else { return current }
        if index + 1 < order.count { return order[index + 1] }
        return index > 0 ? order[index - 1] : nil
    }

    /// 关掉标签栏上的一个标签（× 、"⋯"里的 Close Tab）。正在看的关了按 Safari 的规矩换一个（空白的换过去是它的开始页）；
    /// 焦点在标签栏上的，留在现在正在看的那个标签上；只剩一个标签了就离开标签栏（开始页上回搜索框），不留一个白的在那儿。
    /// 最后一个标签开着网站：不离开浏览器，它就地变成空白标签页（开始页，焦点在搜索框）；只剩一个空白的就没有可关的。
    /// 离开浏览器是按住返回。标签栏上它淡掉、旁边的撑开（BrowserTopBar 的动画）
    func closeTab(_ id: String) {
        guard tabsClosable, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs.count == 1 {
            // 同一个标签（同一个 id、同一块胶囊）换成空白的：标题从网站名换成 Start Page，网页换成开始页
            stopEditing()
            forget(tabs[index])
            let blank = BrowserTab(id: id, url: Self.blankURL, title: "")
            tabs[index] = blank
            if id == lastNormalID { lastNormalID = nil }
            showBlank(blank)
            dropPrivateSessionIfUnused()
            return
        }
        let current = barCurrentID, wasInBar = barFocus != nil
        let next = current.flatMap { Self.currentAfterClosing(id, in: tabs.map(\.id), current: $0) }
        stopEditing()
        let closed = tabs.remove(at: index)
        forget(closed)
        if closed.id == activeID { activeID = nil }
        if closed.id == lastNormalID { lastNormalID = nil }
        if returnTo?.blank == id || returnTo?.to == id { returnTo = nil }
        let stayInBar = wasInBar && tabs.count > 1
        if id != current {
            if stayInBar, let current { withAnimation(Motion.focus) { barFocus = .tab(current) } }
            else if wasInBar { leaveBar() }
        } else if let tab = tabs.first(where: { $0.id == next }) {
            open(tab)
            if stayInBar { focusBar(on: .tab(tab.id)) }
            else if wasInBar { leaveBar() }
        }
        dropPrivateSessionIfUnused()
        save()
    }

    /// 最后一个无痕标签页没了：那份网站数据扔掉（网页视图关掉以后它就没了）
    private func dropPrivateSessionIfUnused() {
        guard !tabs.contains(where: \.isPrivate) else { return }
        privateStore = nil
        privateZoom = [:]
    }

    private func update(_ id: String, _ change: (inout BrowserTab) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        change(&tabs[index])
    }

    private func forget(_ tab: BrowserTab) {
        states[tab.id] = nil
        snapshots.removeObject(forKey: tab.id as NSString)
        if !tab.isPrivate { storage.removeSnapshot(tab.id) }
    }

    /// 只存普通标签页；正在看的是无痕的，存最后看的那个普通的
    private func save() {
        let active = activeTab?.isPrivate == true ? lastNormalID : activeID
        storage.save(tabs.filter { !$0.isPrivate }, active: active)
    }

    // MARK: 截图

    /// 截一张这一页的样子（换回来时先放着）。离开这一页时网页视图已经关了，截图回来之前留着它。无痕的只放内存里
    private func snapshot(_ web: WKWebView, for tab: BrowserTab) {
        let id = tab.id, isPrivate = tab.isPrivate, file = storage.snapshotFile(id)
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: Double(BrowserSnapshots.width) / Double(web.window?.backingScaleFactor ?? 1))
        web.takeSnapshot(with: config) { [weak self] image, _ in
            MainActor.assumeIsolated {
                _ = web
                guard let self, self.tabs.contains(where: { $0.id == id }),   // 已经关掉的不要了
                      let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let small = BrowserSnapshots.shrink(cg) else { return }
                self.snapshots.setObject(NSImage(cgImage: small.image, size: NSSize(width: small.image.width, height: small.image.height)),
                                         forKey: id as NSString)
                if !isPrivate { Task.detached(priority: .utility) { BrowserSnapshots.write(small, to: file) } }
            }
        }
    }

    private func snapshotImage(for tab: BrowserTab) -> NSImage? {
        if let image = snapshots.object(forKey: tab.id as NSString) { return image }
        return tab.isPrivate ? nil : storage.loadSnapshot(tab.id)
    }

    private func schedulePlaceholderTimeout() {
        placeholderTask?.cancel()
        placeholderTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.clearPlaceholder()
        }
    }

    private func clearPlaceholder() {
        placeholderTask?.cancel()
        guard placeholder != nil else { return }
        withAnimation(Motion.appear) { placeholder = nil }
    }

    // MARK: 网页那一边（PlaybackCoordinator、网页里的脚本告诉这里）

    /// 网页载好了：把真正的标题和地址记进这个标签页（普通的还记进"最近浏览"）
    func pageLoaded(_ web: WKWebView) {
        guard web === pageWebView, let url = web.url else { return }
        let title = web.title ?? ""
        if activeTab?.isPrivate == false { storage.addHistory(url, title: title) }
        if let id = activeID {
            update(id) { tab in
                if url.scheme?.hasPrefix("http") == true { tab.url = url }
                if !title.isEmpty { tab.title = title }
            }
        }
        clearPlaceholder()
    }

    /// 网页要开新窗口：点的是"在新窗口打开"的链接（或者没写大小的 window.open）就开成一个新标签页
    /// （无痕标签页里开的也是无痕的）；写了大小的小窗口（登录、付款这种要把结果交回原来那一页的）照旧弹出来
    func opensAsNewTab(_ action: WKNavigationAction, features: WKWindowFeatures, from web: WKWebView) -> Bool {
        guard web === pageWebView, let url = action.request.url, url.scheme?.hasPrefix("http") == true,
              action.navigationType == .linkActivated || (features.width == nil && features.height == nil) else { return false }
        let isPrivate = activeTab?.isPrivate ?? false
        Task { @MainActor [weak self] in self?.newTab(url, isPrivate: isPrivate) }
        return true
    }

    /// 网页里的脚本（BrowserPageScript、SpatialNav）发来的：视频铺满了没有、在页面最上面又按了上、网页画出来了
    func received(_ body: Any, from web: WKWebView?) {
        guard let web, web === pageWebView, let message = body as? [String: Any] else { return }
        if let video = message["video"] as? Bool, video != videoMode {
            videoMode = video   // 网页的大小立刻变（不做动画，免得网页一帧帧地重排）；标签栏自己滑进滑出
        }
        if message["edge"] as? String == "up", barFocus == nil {
            focusBar()
            tv?.feedback.play(.step, from: .keyboard)
        }
        if message["ready"] != nil { clearPlaceholder() }
    }

    private func attach(_ web: WKWebView, host: String) {
        detach()
        zoomedHost = BrowserZoom.key(host)
        observations = [
            web.observe(\.url, options: [.new]) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.urlChanged(web) }
            },
            web.observe(\.title, options: [.new]) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.titleChanged(web) }
            },
            web.observe(\.canGoBack, options: [.new]) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.historyChanged(web) }
            },
            web.observe(\.canGoForward, options: [.new]) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.historyChanged(web) }
            },
        ]
    }

    private func detach() {
        observations.forEach { $0.invalidate() }
        observations = []
    }

    /// 换了网址：标签上的地址跟着变；到了别的网站就用那个网站的缩放
    private func urlChanged(_ web: WKWebView) {
        guard web === pageWebView, let url = web.url, url.scheme?.hasPrefix("http") == true, let id = activeID else { return }
        update(id) { $0.url = url }
        let host = BrowserZoom.key(url.host ?? "")
        guard !host.isEmpty, host != zoomedHost else { return }
        zoomedHost = host
        let zoom = zoom(for: host, isPrivate: activeTab?.isPrivate ?? false)
        if web.pageZoom != zoom { web.pageZoom = zoom }
        page.zoom = zoom
    }

    private func titleChanged(_ web: WKWebView) {
        guard web === pageWebView, let title = web.title, !title.isEmpty, let id = activeID, activeTab?.title != title else { return }
        update(id) { $0.title = title }
    }

    private func historyChanged(_ web: WKWebView) {
        guard web === pageWebView else { return }
        page.canGoBack = web.canGoBack
        page.canGoForward = web.canGoForward
        // 焦点在后退 / 前进上，它变成不能用了：挪到正在看的标签页上
        if (barFocus == .back && !page.canGoBack) || (barFocus == .forward && !page.canGoForward) { barFocus = currentTabFocus }
    }

    // MARK: 缩放

    /// 这个网站的缩放（小、中、大三档之一）。以前记下的百分比换成最近的一档，以前的默认值算"中"
    func zoom(for host: String, isPrivate: Bool) -> Double {
        let stored = (isPrivate ? privateZoom[BrowserZoom.key(host)] : nil) ?? storage.zoom(for: host)
        let oldDefault = BrowserZoom.standard(forWidth: tv?.window?.contentView?.bounds.width ?? 1920)
        return BrowserZoomLevel.level(stored: stored, oldDefault: oldDefault).zoom
    }

    private func setZoom(_ level: BrowserZoomLevel) {
        guard let web = pageWebView else { return }
        web.pageZoom = level.zoom
        withAnimation(Motion.press) { page.zoom = level.zoom }
        let host = web.url?.host ?? activeTab?.url.host ?? ""
        guard !host.isEmpty else { return }
        let value: Double? = level == .medium ? nil : level.zoom
        // 无痕的只记在内存里
        if activeTab?.isPrivate == true { privateZoom[BrowserZoom.key(host)] = value } else { storage.setZoom(value, for: host) }
    }

    // MARK: 标签栏

    private var currentTabFocus: BarFocus? { barCurrentID.map(BarFocus.tab) }

    /// 标签栏上能走到的，从左到右（不能用的后退、前进跳过）。关闭按钮不在这里面，见 barStep
    nonisolated static func barItems(tabs: [String], canGoBack: Bool, canGoForward: Bool) -> [BarFocus] {
        (canGoBack ? [.back] : []) + (canGoForward ? [.forward] : []) + tabs.map(BarFocus.tab) + [.newTab, .more]
    }

    var barItems: [BarFocus] { Self.barItems(tabs: barTabs.map(\.id), canGoBack: barCanGoBack, canGoForward: barCanGoForward) }

    nonisolated static func step(in items: [BarFocus], from focus: BarFocus, by delta: Int) -> BarFocus? {
        guard let index = items.firstIndex(of: focus), items.indices.contains(index + delta) else { return nil }
        return items[index + delta]
    }

    /// 标签栏上左右走一格（走不动是 nil）。选中的标签前面是它的 ×（网站图标的位置）：从标签往左先到它的 ×，
    /// 再往左才到前一个；从 × 往右回到标签。往右走不经过 ×（别的标签的 × 只有选中它时才出来），不碍事
    /// closable：标签有没有 ×（见 tabsClosable；不给就按"不止一个标签"算）
    nonisolated static func barStep(in items: [BarFocus], from focus: BarFocus, _ direction: RemoteCommand.Direction,
                                    closable: Bool? = nil) -> BarFocus? {
        switch (focus, direction) {
        case (.tab(let id), .left):
            // 没有 ×（只剩一个空白标签页）：往左直接走到前面的按钮
            let tabCount = items.filter { if case .tab = $0 { true } else { false } }.count
            guard items.contains(.tab(id)) else { return nil }
            return closable ?? (tabCount > 1) ? .close(id) : step(in: items, from: focus, by: -1)
        case (.close(let id), .right): return items.contains(.tab(id)) ? .tab(id) : nil
        case (.close(let id), .left): return step(in: items, from: .tab(id), by: -1)
        case (_, .left): return step(in: items, from: focus, by: -1)
        case (_, .right): return step(in: items, from: focus, by: 1)
        default: return nil
        }
    }

    /// "⋯"菜单里上下走一格（走不动是 nil）。左右不换行：在 Zoom 那一行是换一档（zoomStep）
    nonisolated static func menuStep(from item: MenuItem, _ direction: RemoteCommand.Direction,
                                     rows: [[MenuItem]] = MenuItem.rows) -> MenuItem? {
        guard let row = rows.firstIndex(where: { $0.contains(item) }) else { return nil }
        switch direction {
        case .up, .down:
            let next = row + (direction == .down ? 1 : -1)
            return rows.indices.contains(next) ? rows[next][0] : nil
        case .left, .right: return nil
        }
    }

    /// 缩放往大（+1）或往小（-1）走一档：到头了是 nil（不绕回去）
    nonisolated static func zoomStep(from level: BrowserZoomLevel, by delta: Int) -> BrowserZoomLevel? {
        let levels = BrowserZoomLevel.allCases
        guard let index = levels.firstIndex(of: level), levels.indices.contains(index + delta) else { return nil }
        return levels[index + delta]
    }

    var zoomLevel: BrowserZoomLevel { BrowserZoomLevel.nearest(page.zoom) }

    /// 换一档缩放（"⋯"里 Zoom 那一行的左右、‹ ›，⌘+ ⌘−）：到头了不动，返回 false
    @discardableResult
    func stepZoom(_ delta: Int) -> Bool {
        guard pageWebView != nil, let level = Self.zoomStep(from: zoomLevel, by: delta) else { return false }
        setZoom(level)
        return true
    }

    /// ⌘0：回到中（每个网站的默认）
    func resetZoom() {
        guard pageWebView != nil, zoomLevel != .medium else { return }
        setZoom(.medium)
    }

    /// 焦点进标签栏（默认停在正在看的那个标签上）。网页上、开始页上都是这一条
    func focusBar(on target: BarFocus? = nil) {
        if let web = pageWebView {
            page.canGoBack = web.canGoBack
            page.canGoForward = web.canGoForward
            page.zoom = web.pageZoom
        } else if !onStartPage {
            return
        }
        withAnimation(Motion.focus) {
            if onStartPage { placeStartBar(true); focus = .field }
            barFocus = target ?? currentTabFocus ?? tabs.last.map { .tab($0.id) } ?? .newTab
        }
    }

    /// 焦点回网页（开始页上：回地址栏）
    func leaveBar() {
        withAnimation(Motion.focus) { barFocus = nil; menu = nil }
        if let web = pageWebView { tv?.window?.makeFirstResponder(web) }
    }

    /// 按住确认：打开"⋯"菜单
    func openMenu() -> Bool {
        guard pageWebView != nil || onStartPage, menu == nil else { return false }
        if editing { endEditingByClick() }   // 正在改地址时按住确认：先不改了（不留下改了一半的地址栏）
        if barFocus == nil { focusBar(on: .more) }
        withAnimation(Motion.appear) { barFocus = .more; menu = menuRows[0][0] }
        return true
    }

    private func closeMenu() {
        withAnimation(Motion.appear) { menu = nil }
    }

    /// "⋯"菜单开着时再按住确认：收起，焦点留在标签栏的"⋯"上（同返回，规矩见 TVController.toggle）
    func closeHoldMenu() -> Bool {
        guard menu != nil else { return false }
        closeMenu()
        return true
    }

    /// 焦点在网页里时归这里管的两个键：返回（焦点进标签栏）、视频铺满时的上（叫出标签栏）。别的照常给网页
    func handleInPage(_ command: RemoteCommand) -> Bool {
        guard barFocus == nil, let web = pageWebView else { return false }
        switch command {
        case .back:
            // 视频铺满时先让网页退出它自己的全屏（Esc），标签栏盖在上面出来
            if videoMode { tv?.playbackCoordinator.sendKey(.escape, to: web) }
            focusBar()
            return true
        case .move(.up) where videoMode:
            focusBar()
            return true
        default:
            return false
        }
    }

    /// 焦点在标签栏（或者菜单）里时的按键。不归它们管的（播放 / 暂停、打字、鼠标）返回 false，照常给网页
    func handleBar(_ command: RemoteCommand) -> Bool {
        if historyState != nil { handleHistory(command); return true }
        if itemMenu != nil { handleItemMenu(command); return true }   // 网页上 Remove from Favorites 的那一问
        guard let focus = barFocus else { return false }
        if editing {
            // 在标签栏上改地址：打的字、删除、确认（打开）、返回（不改了）。方向键在键盘上直接给输入框（main.swift）
            switch command {
            case .click: leaveBar(); stopEditing(); return false   // 点了网页：不改了，焦点回网页（顺序见 handleEditing 的返回）
            case .pointer, .playPause, .seek: return false
            default: handleEditing(command)
            }
            return true
        }
        if let item = menu {
            switch command {
            case .move(let direction):
                if item == .zoom, direction == .left || direction == .right { stepZoom(direction == .right ? 1 : -1) }
                else if let next = Self.menuStep(from: item, direction, rows: menuRows) { withAnimation(Motion.focus) { menu = next } }
                else if direction == .up { closeMenu() }   // 菜单从"⋯"下面拉出来的：在第一行再往上就收起
            case .select: activateMenu(item)
            case .back: closeMenu()
            case .click: leaveBar(); return false   // 用鼠标点了网页：焦点回网页（点在标签栏上的，tapBar 会再把焦点放回去）
            case .pointer, .playPause, .text, .deleteBackward: return false
            default: break
            }
            return true
        }
        switch command {
        case .move(let direction) where direction == .left || direction == .right:
            if let next = Self.barStep(in: barItems, from: focus, direction, closable: tabsClosable) {
                withAnimation(Motion.focus) { barFocus = next }
            }
        case .move(.down): leaveBar()
        case .move: break
        case .select: activate(focus)
        // 网页上：和以前一样，网页返回到头回开始页，开始页再返回回主屏。开始页上：回地址栏
        case .back: if onStartPage { leaveBar() } else { openStartPage(origin: .home) }
        case .click: leaveBar(); return false
        case .pointer, .playPause, .seek, .text, .deleteBackward: return false
        default: break
        }
        return true
    }

    func activate(_ item: BarFocus) {
        press(item)
        if case .close(let id) = item { closeTab(id); return }
        switch item {
        case .back: pageWebView.map { if $0.canGoBack { $0.goBack() } }
        case .forward: pageWebView.map { if $0.canGoForward { $0.goForward() } }
        case .tab(let id) where id == barCurrentID:
            startEditingInBar()   // 正在看的那个：就在标签栏上改地址、搜索
        case .tab(let id):
            guard let tab = tabs.first(where: { $0.id == id }) else { return }
            open(tab)
            focusBar(on: .tab(id))   // 换过去，焦点留在标签栏上，可以接着换；按下回到网页（开始页上回地址栏）
        case .newTab:
            // 总是再开一个空白标签页（开始页上也是），无痕的里面开的也是无痕的
            newBlankTab(isPrivate: barIsPrivate, from: barCurrentID)
            focusBar(on: .newTab)   // 焦点留在"+"上：看得见新标签长出来，可以接着再开；按下到地址栏
        case .more: _ = openMenu()
        case .close: break
        }
    }

    /// 按下的那一下：按钮往下一沉，0.18 秒后弹回来（一次性的，不是一直在跑的动画）
    private func press(_ item: BarFocus) {
        pressTask?.cancel()
        withAnimation(Motion.press) { pressed = item }
        pressTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.18))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.press) { self?.pressed = nil }
        }
    }

    func activateMenu(_ item: MenuItem) {
        switch item {
        case .newPrivateTab:
            closeMenu()
            newBlankTab(isPrivate: true, from: barCurrentID)
        case .reload: closeMenu(); pageWebView?.reload()
        case .addFavorite: closeMenu(); addFavorite(currentPage)
        case .removeFavorite: closeMenu(); confirmRemoveFavorite(currentPage)   // 取消收藏先问
        case .zoom: break   // 换档是左右（和设置里的步进行一样），确认不做别的
        case .closeTab: closeMenu(); if let id = barCurrentID { closeTab(id) }
        case .startPage: closeMenu(); newBlankTab(isPrivate: barIsPrivate, from: barCurrentID)
        case .history: closeMenu(); leaveBar(); openHistory()
        }
    }

    /// 标签栏、菜单里横着 / 竖着算哪一类（规则见 TVController.Module）
    func chromeModule(horizontal: Bool) -> TVController.Module {
        if menu != nil { return .picker }                  // 菜单：一列固定的几行
        return horizontal ? .picker : .drawer              // 一排固定的按钮和标签；从上面拉下来的一条
    }

    /// 开始页：焦点在标签栏上和网页上的标签栏一样；在地址栏、那几排里横着是长条
    func startModule(horizontal: Bool) -> TVController.Module {
        barFocus != nil ? chromeModule(horizontal: horizontal) : horizontal ? .strip : .drawer
    }

    /// 开始页上转盘沿着哪个方向走：标签栏横着（"⋯"菜单竖着），那几排横着，地址栏竖着
    var startWheelRunsHorizontally: Bool { barFocus != nil ? menu == nil : focus != .field }

    func chromeCanMove(_ direction: RemoteCommand.Direction) -> Bool {
        guard let focus = barFocus else { return false }
        if let item = menu {
            if item == .zoom, direction == .left || direction == .right {
                return pageWebView != nil && Self.zoomStep(from: zoomLevel, by: direction == .right ? 1 : -1) != nil
            }
            return Self.menuStep(from: item, direction, rows: menuRows) != nil
        }
        switch direction {
        case .left, .right: return Self.barStep(in: barItems, from: focus, direction, closable: tabsClosable) != nil
        case .down: return true
        case .up: return false
        }
    }

    /// 鼠标点了标签栏上的一个（点 × 直接关掉那个标签；点正在改地址的那个标签不打断）
    func tapBar(_ item: BarFocus) {
        guard historyState == nil else { return }   // History 盖着标签栏
        guard pageWebView != nil || onStartPage else { return }
        if editing, editingInBar, item == .tab(barCurrentID ?? "") { return }
        stopEditing()
        withAnimation(Motion.focus) { barFocus = item; menu = nil }
        activate(item)
    }

    func tapMenu(_ item: MenuItem) {
        guard historyState == nil else { return }
        guard menu != nil else { return }
        withAnimation(Motion.focus) { menu = item }
        activateMenu(item)
    }

    // MARK: 键盘快捷键（Safari 的那一套，见 main.swift 的菜单）

    /// 菜单里的一项快捷键。名字是 Apple 的菜单标题（rawValue 存在 NSMenuItem.representedObject 里）
    enum Shortcut: String, CaseIterable {
        case newTab, newPrivateTab, openLocation, closeTab, back, forward, previousTab, nextTab, zoomIn, zoomOut, actualSize, showAllHistory

        var title: String {
            switch self {
            case .newTab: "New Tab"
            case .newPrivateTab: "New Private Tab"
            case .openLocation: "Open Location…"
            case .closeTab: "Close Tab"
            case .back: "Back"
            case .forward: "Forward"
            case .previousTab: "Show Previous Tab"
            case .nextTab: "Show Next Tab"
            case .zoomIn: "Zoom In"
            case .zoomOut: "Zoom Out"
            case .actualSize: "Actual Size"
            case .showAllHistory: "Show All History"
            }
        }

        /// 键和修饰键（⌘ 总在；大写字母、{ } 是带 ⇧ 的）
        var key: (String, NSEvent.ModifierFlags) {
            switch self {
            case .newTab: ("t", [.command])
            case .newPrivateTab: ("N", [.command, .shift])
            case .openLocation: ("l", [.command])
            case .closeTab: ("w", [.command])
            case .back: ("[", [.command])
            case .forward: ("]", [.command])
            case .previousTab: ("{", [.command, .shift])
            case .nextTab: ("}", [.command, .shift])
            case .zoomIn: ("+", [.command])
            case .zoomOut: ("-", [.command])
            case .actualSize: ("0", [.command])
            case .showAllHistory: ("y", [.command])
            }
        }
    }

    /// 浏览器开着（开始页或网页在前面）
    private var browserInFront: Bool {
        guard let tv else { return false }
        return (tv.browserOpen && tv.mode == .launcher) || tv.browserPageInFront
    }

    /// 这一项现在能不能用（菜单里灰掉的那几项，键会照常给输入框、网页）
    func canPerform(_ shortcut: Shortcut) -> Bool {
        guard browserInFront else { return false }
        if historyState != nil { return false }   // History 开着：⌘Y 也不再开一次，返回关它
        switch shortcut {
        case .showAllHistory: return true
        case .newTab, .newPrivateTab, .openLocation: return true
        case .closeTab: return barCurrentID != nil && tabsClosable
        case .back: return barCanGoBack
        case .forward: return barCanGoForward
        case .previousTab, .nextTab: return tabs.count > 1
        case .zoomIn: return pageWebView != nil && Self.zoomStep(from: zoomLevel, by: 1) != nil
        case .zoomOut: return pageWebView != nil && Self.zoomStep(from: zoomLevel, by: -1) != nil
        case .actualSize: return pageWebView != nil && zoomLevel != .medium
        }
    }

    /// 快捷键：和屏幕上的那个控件走同一条路（同样的动画），按下去的声音和遥控器的确认一样
    func perform(_ shortcut: Shortcut) {
        guard canPerform(shortcut) else { return }
        menu = nil
        switch shortcut {
        case .newTab: activate(.newTab)
        case .newPrivateTab: activateMenu(.newPrivateTab)
        case .openLocation:
            if let id = barCurrentID {
                if !(editing && editingInBar) { tapBar(.tab(id)) }   // 和选正在看的那个标签一样：就地改地址
            } else {
                startEditing()                                       // 开始页（没有正在看的标签）：它的搜索框
            }
        case .closeTab: if let id = barCurrentID { activate(.close(id)) }
        case .back: activate(.back)
        case .forward: activate(.forward)
        case .previousTab, .nextTab:
            guard let current = barCurrentID ?? activeID, let index = tabs.firstIndex(where: { $0.id == current }) else { return }
            let next = (index + (shortcut == .nextTab ? 1 : -1) + tabs.count) % tabs.count   // 像 Safari：到头绕回去
            tapBar(.tab(tabs[next].id))
        case .zoomIn: stepZoom(1)
        case .zoomOut: stepZoom(-1)
        case .actualSize: resetZoom()
        case .showAllHistory: leaveBar(); openHistory()
        }
        tv?.feedback.play(.select, from: .keyboard)
    }
}

// MARK: 每个人（个人资料）各一份（见 ProfileApp）

extension BrowserStore: ProfileApp {
    /// 要换人了：开着的网页收起来，标签页存进这个人自己的那一份（无痕的扔掉）
    func profileWillChange() {
        leave()
        closePrivateTabs()
    }

    /// 换了人：他自己的标签页、截图、看过的页面、缩放；Safari 那几排只有第一个人有
    func profileChanged() {
        let space = ProfileSpace.current
        storage = space.isMain ? mainStorage : .forProfile(space)
        showsSafari = space.isMain
        let saved = storage.load()
        tabs = saved.tabs
        activeID = saved.active
        lastNormalID = saved.active
        states = [:]
        snapshots.removeAllObjects()
        privateStore = nil
        privateZoom = [:]
        returnTo = nil
        origin = .home
        query = ""
        columns = [:]
        focus = .field
        placeholder = nil
        safari = SafariLibrary.Snapshot(access: .missing)
        access = .missing
        loadedAt = .distantPast
        rebuildRows()
    }
}

extension TVController {
    /// 从主屏打开浏览器：上次看的标签页还在就直接回到那一页，没有就是开始页
    func openBrowser() {
        if mode != .launcher { goHome() }
        browserStore.tv = self
        sheets.closeDismissible()
        movies = nil
        browserOpen = true
        browserStore.opened()
        browserStore.resumeLastTab()
    }

    func closeBrowser() {
        browserStore.leave()
        browserOpen = false
    }

    /// 从网页回到浏览器的开始页（标签页还留着）
    func returnToBrowser() {
        browserStore.tv = self
        browserStore.openStartPage(origin: .home)
    }

    /// 浏览器的网页正在前面（标签栏能用）
    var browserPageInFront: Bool {
        guard case .player(let service) = mode, service.id == BrowserStore.pageID else { return false }
        return webView != nil && playerFailure == nil && externalBrowser == nil
    }

    /// 焦点在浏览器的标签栏上（滑动、转盘、方向键归它）
    var browserChromeUp: Bool { browserStore.barFocus != nil && browserPageInFront }

    /// 浏览器网页里的按键：焦点在标签栏上的归它；在网页里时只拦返回（进标签栏）和视频铺满时的上。
    /// 声音和震动跟着焦点变没变（和开始页一样）
    func handleInBrowserChrome(_ command: RemoteCommand, from source: Feedback.Source) -> Bool {
        guard browserPageInFront else { return false }
        let before = browserStore.chromeKey
        var cue = Feedback.Cue.step
        if case .move(let direction) = command, module(horizontal: direction == .left || direction == .right) == .strip { cue = .move }
        let handled = browserStore.barFocus != nil ? browserStore.handleBar(command) : browserStore.handleInPage(command)
        guard handled else { return false }
        let changed = browserStore.chromeKey != before
        switch command {
        case .move where changed: feedback.play(cue, from: source)
        case .select: feedback.play(.select, from: source)
        case .back where changed: feedback.play(.back, from: source)
        default: break
        }
        return true
    }
}
