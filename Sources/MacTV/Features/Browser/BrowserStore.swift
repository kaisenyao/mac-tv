import AppKit
import SwiftUI
import WebKit

/// 浏览器（电视上的 Safari）。开始页最上面是地址栏（搜索或输入网址），下面一排排是 Safari 的个人收藏、
/// 常去的网站、最近看过的页面、阅读列表。选一个就开成一个标签页。
///
/// 开着网页时，最上面一条标签栏（像 Safari 的紧凑标签栏，见 BrowserTopBar）：后退、前进、一个个标签页、"+"、"⋯"，
/// 网页在它下面。网页里按返回，或者在页面最上面再按上，焦点进标签栏；在标签栏里按下回到网页。
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

    /// 标签栏上的焦点（nil：焦点在网页里）
    enum BarFocus: Hashable { case back, forward, tab(String), newTab, more }

    /// "⋯"菜单里的一项。缩小、原始大小、放大在同一行
    enum MenuItem: CaseIterable {
        case newPrivateTab, reload, zoomOut, zoomReset, zoomIn, closeTab, startPage

        static let rows: [[MenuItem]] = [[.newPrivateTab], [.reload], [.zoomOut, .zoomReset, .zoomIn], [.closeTab], [.startPage]]

        var name: String {
            switch self {
            case .newPrivateTab: "New Private Tab"
            case .reload: "Reload Page"
            case .zoomOut: "Zoom Out"
            case .zoomReset: "Actual Size"
            case .zoomIn: "Zoom In"
            case .closeTab: "Close Tab"
            case .startPage: "Open Start Page"
            }
        }

        var symbol: String {
            switch self {
            case .newPrivateTab: "hand.raised"
            case .reload: "arrow.clockwise"
            case .zoomOut: "minus"
            case .zoomReset: "textformat.size"
            case .zoomIn: "plus"
            case .closeTab: "xmark"
            case .startPage: "square.grid.2x2"
            }
        }
    }

    /// 开始页是从哪进来的：决定选了一个网站以后开在哪、返回去哪
    enum Origin: Equatable {
        /// 从主屏进来、或者从标签栏返回：选的网站开成新标签页，返回回主屏
        case home
        /// "+"、"⋯"里的新标签页（isPrivate：无痕）：开成新标签页，返回回到原来那一页
        case newTab(from: String?, isPrivate: Bool)
        /// 标签栏上点了正在看的那个标签页（地址）：在这个标签页里打开（前进后退还在），返回回到这一页
        case address(of: String)
    }

    /// 正在看的网页（标签栏上显示的）
    struct PageInfo: Equatable {
        var canGoBack = false
        var canGoForward = false
        var zoom = 1.5
    }

    weak var tv: TVController?

    // 开始页
    @Published private(set) var rows: [Row] = []
    @Published private(set) var focus: Focus = .field
    @Published private(set) var editing = false
    /// 地址栏该拿着键盘却没拿到时加一，界面看到它变了就再去要一次
    @Published private(set) var focusRequest = 0
    func refocus() { focusRequest += 1 }
    @Published private(set) var query = ""
    /// 地址栏里是这一页的网址（从标签栏的地址进来）：一打字就整个换掉，像选中了一样
    private(set) var replaceQuery = false
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
    private let storage: BrowserTabStorage
    /// 无痕标签页共用的一份网站数据（不落盘）。最后一个无痕标签页关掉就扔掉
    private var privateStore: WKWebsiteDataStore?
    /// 无痕标签页里调的缩放：只在内存里，不记
    private var privateZoom: [String: Double] = [:]

    // 标签栏
    @Published private(set) var barFocus: BarFocus?
    @Published private(set) var menu: MenuItem?
    /// 网页里有视频铺满了（或者网页自己进了全屏）：标签栏收起，网页占满整个屏幕
    @Published private(set) var videoMode = false
    @Published private(set) var page = PageInfo()
    /// 换回一个标签页、网页还没画出来时先放的截图
    @Published private(set) var placeholder: NSImage?
    private var placeholderTask: Task<Void, Never>?
    private var observations: [NSKeyValueObservation] = []
    private var zoomedHost = ""

    init(storage: BrowserTabStorage = .standard) {
        self.storage = storage
        let saved = storage.load()
        tabs = saved.tabs
        activeID = saved.active
        lastNormalID = saved.active
        snapshots.countLimit = 4
    }

    var activeTab: BrowserTab? { tabs.first { $0.id == activeID } }
    var hasPrivateSession: Bool { privateStore != nil }
    /// 开始页是开无痕标签页用的
    var startsPrivate: Bool { if case .newTab(_, true) = origin { true } else { false } }
    /// 标签栏露着：平时一直在；视频铺满时只有焦点在它上面才出来（盖在视频上）
    var barShown: Bool { !videoMode || barFocus != nil }

    /// 给按键音用：焦点变了才出声
    var focusKey: String { "\(focus)-\(editing)-\(rows.count)" }
    /// 标签栏、菜单里的焦点
    var chromeKey: String { "\(String(describing: barFocus))-\(String(describing: menu))-\(tabs.count)-\(activeID ?? "")" }

    func opened(origin: Origin = .home) {
        self.origin = origin
        editing = false
        replaceQuery = false
        rebuildRows()
        if Date().timeIntervalSince(loadedAt) > 60 { reload() }
    }

    func reload() {
        loadedAt = Date()
        Task.detached(priority: .userInitiated) {
            let snapshot = SafariLibrary.read()
            await MainActor.run { self.apply(snapshot) }
        }
    }

    private func apply(_ safari: SafariLibrary.Snapshot) {
        self.safari = safari
        access = safari.access
        withAnimation(Motion.navigate) { rebuildRows() }
    }

    func rebuildRows() {
        var built: [Row] = []
        if safari.access == .needsPermission {
            // 读不到 Safari：放一张说明，选它打开系统设置里那一页（打勾要你自己来）
            built.append(Row(id: "permission", title: "Safari History", style: .notice, pages: []))
        }
        if !safari.favorites.isEmpty { built.append(Row(id: "favorites", title: "Favorites", style: .tiles, pages: safari.favorites)) }
        if !safari.frequent.isEmpty { built.append(Row(id: "frequent", title: "Frequently Visited", style: .tiles, pages: safari.frequent)) }
        // 最近：Safari 的历史和在 Mac TV 里看过的合在一起，新的在前，同一页只留一次
        var seen = Set<String>()
        let recent = (safari.recent + BrowserHistory.all).sorted { ($0.visited ?? .distantPast) > ($1.visited ?? .distantPast) }
            .filter { seen.insert($0.id).inserted }
        if !recent.isEmpty { built.append(Row(id: "recent", title: "Recently Visited", style: .cards, pages: Array(recent.prefix(40)))) }
        if !safari.readingList.isEmpty { built.append(Row(id: "reading", title: "Reading List", style: .cards, pages: safari.readingList)) }
        rows = built
        if case .item(let row, _) = focus, !rows.indices.contains(row) { focus = .field }
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
        if editing {
            switch command {
            case .text(let text):
                query = replaceQuery ? text : query + text
                replaceQuery = false
            case .deleteBackward:
                if replaceQuery { query = ""; replaceQuery = false } else if !query.isEmpty { query.removeLast() }
            case .select: submit()
            case .back:
                stopEditing()
                if case .address(let id) = origin { resume(id) }   // 从标签栏的地址进来的：返回就回到那一页
            default: break
            }
            return
        }
        switch command {
        case .move(.down):
            switch focus {
            case .field: if !rows.isEmpty { setFocus(.item(row: 0, column: column(of: 0))) }
            case .item(let row, _): if row + 1 < rows.count { setFocus(.item(row: row + 1, column: column(of: row + 1))) }
            }
        case .move(.up):
            if case .item(let row, _) = focus { setFocus(row == 0 ? .field : .item(row: row - 1, column: column(of: row - 1))) }
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
            // 在下面几排里：先回到地址栏；在地址栏上：回主屏，或者回到进来之前看的那一页
            if case .item = focus { setFocus(.field); return }
            switch origin {
            case .home, .newTab(nil, _): tv?.goHome()
            case .newTab(let id?, _), .address(let id): resume(id)
            }
        default: break
        }
    }

    /// 转盘、双指滑动：在一排里走，到头就停
    func canMove(_ direction: RemoteCommand.Direction) -> Bool {
        guard case .item(let row, let column) = focus, rows.indices.contains(row) else { return direction == .down && !rows.isEmpty }
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
        withAnimation(Motion.focus) { columns[rows[row].id] = column; focus = .item(row: row, column: column) }
    }

    private func setFocus(_ value: Focus) {
        withAnimation(Motion.navigate) { focus = value }
    }

    // MARK: 地址栏

    func startEditing() {
        withAnimation(Motion.focus) { focus = .field; editing = true }
    }

    func stopEditing() {
        guard editing else { return }
        editing = false
        replaceQuery = false
        tv?.window?.makeFirstResponder(nil)
    }

    /// 键盘在地址栏里打的字
    func typed(_ text: String) {
        query = text
        replaceQuery = false
    }

    /// 像网址的（有点、没空格，或者写了 http）直接打开；别的当成搜索词去搜
    func submit() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        stopEditing()
        guard !text.isEmpty else { return }
        if let url = Self.address(text) { open(url); return }
        var search = URLComponents(string: "https://www.google.com/search")!
        search.queryItems = [URLQueryItem(name: "q", value: text)]
        if let url = search.url { open(url) }
    }

    nonisolated static func address(_ text: String) -> URL? {
        let looksLikeAddress = text.contains("://") || (text.contains(".") && !text.contains(" ") && !text.hasSuffix("."))
        return looksLikeAddress ? WebsiteAddress.url(from: text) : nil
    }

    /// 开始页上选了一个网站：从地址进来的在那个标签页里打开；别的开成新标签页
    /// （普通的：同一个网址已经开着就换到那个）
    func open(_ url: URL) {
        query = ""
        switch origin {
        case .address(let id):
            if let tab = tabs.first(where: { $0.id == id }) { show(tab, loading: url) } else { newTab(url) }
        case .newTab(_, true):
            newTab(url, isPrivate: true)
        default:
            if let same = tabs.first(where: { !$0.isPrivate && $0.url == url }) { show(same) } else { newTab(url) }
        }
    }

    /// 系统设置 → 隐私与安全性 → 完全磁盘访问权限（只是打开那一页，打勾要你自己来）
    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
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

    func resume(_ id: String) {
        if let tab = tabs.first(where: { $0.id == id }) { show(tab) } else { tv?.goHome() }
    }

    /// 从主屏打开浏览器：上次看的普通标签页还在就直接回到那一页（像 Safari）。没有就留在开始页
    func resumeLastTab() {
        guard let tab = tabs.first(where: { $0.id == activeID && !$0.isPrivate }) ?? tabs.last(where: { !$0.isPrivate }) else { return }
        show(tab)
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
        if !tab.isPrivate { BrowserHistory.add(address, title: url == nil && !tab.title.isEmpty ? tab.title : host) }
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

    /// 离开浏览器（回主屏、开别的应用）。无痕标签页这时就关掉、数据扔掉（电视家里人都会用，别留给下一个人）
    func leave() {
        if pageWebView != nil { suspendPage() }
        barFocus = nil
        menu = nil
        videoMode = false
        stopEditing()
        let privateTabs = tabs.filter(\.isPrivate)
        if !privateTabs.isEmpty {
            tabs.removeAll(where: \.isPrivate)
            privateTabs.forEach(forget)
            if activeTab == nil { activeID = lastNormalID }
        }
        dropPrivateSessionIfUnused()
        snapshots.removeAllObjects()
        save()
    }

    /// 回到开始页（标签栏上返回、"+"、"⋯"里的、点了正在看的那个标签页、最后一个标签页关掉了）
    func openStartPage(origin: Origin, editing: Bool = false) {
        guard let tv else { return }
        let address = activeTab?.url.absoluteString ?? ""
        if pageWebView != nil {
            suspendPage()
            tv.playbackCoordinator.closeWebPlayback()
        }
        barFocus = nil
        menu = nil
        videoMode = false
        tv.setMode(.launcher)
        tv.playerFailure = nil
        tv.browserOpen = true
        opened(origin: origin)
        if origin != .home { focus = .field }
        if editing {
            query = address
            startEditing()
            replaceQuery = !address.isEmpty
        }
        tv.bringToFront()
    }

    /// 关掉一个标签页。关的是正在看的：换到后面那个（没有就是前面那个）；最后一个也关了就回开始页
    func closeTab(_ id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasInBar = barFocus != nil
        let closed = tabs.remove(at: index)
        forget(closed)
        if barFocus == .tab(id) { barFocus = nil }
        if closed.id == activeID {
            activeID = nil
            if tabs.isEmpty {
                openStartPage(origin: .home)
            } else {
                let next = tabs[min(index, tabs.count - 1)]
                show(next)
                if wasInBar { barFocus = .tab(next.id) }
            }
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
        if activeTab?.isPrivate == false { BrowserHistory.add(url, title: title) }
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

    /// 这台电视上默认放大多少（按窗口宽度，见 BrowserZoom）
    var standardZoom: Double { BrowserZoom.standard(forWidth: tv?.window?.contentView?.bounds.width ?? 1920) }

    func zoom(for host: String, isPrivate: Bool) -> Double {
        (isPrivate ? privateZoom[BrowserZoom.key(host)] : nil) ?? storage.zoom(for: host) ?? standardZoom
    }

    private func setZoom(_ zoom: Double) {
        guard let web = pageWebView else { return }
        let zoom = BrowserZoom.clamp(zoom)
        web.pageZoom = zoom
        withAnimation(Motion.press) { page.zoom = zoom }
        let host = web.url?.host ?? activeTab?.url.host ?? ""
        guard !host.isEmpty else { return }
        let value: Double? = abs(zoom - standardZoom) < 0.001 ? nil : zoom
        // 无痕的只记在内存里
        if activeTab?.isPrivate == true { privateZoom[BrowserZoom.key(host)] = value } else { storage.setZoom(value, for: host) }
    }

    // MARK: 标签栏

    private var currentTabFocus: BarFocus? { activeID.map(BarFocus.tab) }

    /// 标签栏上能走到的，从左到右（不能用的后退、前进跳过）
    nonisolated static func barItems(tabs: [String], canGoBack: Bool, canGoForward: Bool) -> [BarFocus] {
        (canGoBack ? [.back] : []) + (canGoForward ? [.forward] : []) + tabs.map(BarFocus.tab) + [.newTab, .more]
    }

    var barItems: [BarFocus] { Self.barItems(tabs: tabs.map(\.id), canGoBack: page.canGoBack, canGoForward: page.canGoForward) }

    nonisolated static func step(in items: [BarFocus], from focus: BarFocus, by delta: Int) -> BarFocus? {
        guard let index = items.firstIndex(of: focus), items.indices.contains(index + delta) else { return nil }
        return items[index + delta]
    }

    /// "⋯"菜单里往一个方向走一格（走不动是 nil）。上下换行（进缩放那一行停在"原始大小"），左右只在缩放那一行里
    nonisolated static func menuStep(from item: MenuItem, _ direction: RemoteCommand.Direction) -> MenuItem? {
        let rows = MenuItem.rows
        guard let row = rows.firstIndex(where: { $0.contains(item) }), let column = rows[row].firstIndex(of: item) else { return nil }
        switch direction {
        case .up, .down:
            let next = row + (direction == .down ? 1 : -1)
            guard rows.indices.contains(next) else { return nil }
            return rows[next].count == 3 ? .zoomReset : rows[next][0]
        case .left, .right:
            let next = column + (direction == .right ? 1 : -1)
            return rows[row].indices.contains(next) ? rows[row][next] : nil
        }
    }

    /// 焦点进标签栏（默认停在正在看的那个标签页上）
    func focusBar(on target: BarFocus? = nil) {
        guard let web = pageWebView else { return }
        page.canGoBack = web.canGoBack
        page.canGoForward = web.canGoForward
        page.zoom = web.pageZoom
        withAnimation(Motion.focus) { barFocus = target ?? currentTabFocus ?? .newTab }
    }

    /// 焦点回网页
    func leaveBar() {
        withAnimation(Motion.focus) { barFocus = nil; menu = nil }
        if let web = pageWebView { tv?.window?.makeFirstResponder(web) }
    }

    /// 按住确认：打开"⋯"菜单
    func openMenu() -> Bool {
        guard pageWebView != nil, menu == nil else { return false }
        if barFocus == nil { focusBar(on: .more) }
        withAnimation(Motion.appear) { barFocus = .more; menu = .newPrivateTab }
        return true
    }

    private func closeMenu() {
        withAnimation(Motion.appear) { menu = nil }
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
        guard let focus = barFocus else { return false }
        if let item = menu {
            switch command {
            case .move(let direction):
                if let next = Self.menuStep(from: item, direction) { withAnimation(Motion.focus) { menu = next } }
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
            if let next = Self.step(in: barItems, from: focus, by: direction == .right ? 1 : -1) {
                withAnimation(Motion.focus) { barFocus = next }
            }
        case .move(.down): leaveBar()
        case .move: break
        case .select: activate(focus)
        case .back: openStartPage(origin: .home)   // 和以前一样：网页返回到头回开始页，开始页再返回回主屏
        case .click: leaveBar(); return false
        case .pointer, .playPause, .seek, .text, .deleteBackward: return false
        default: break
        }
        return true
    }

    func activate(_ item: BarFocus) {
        guard let web = pageWebView else { return }
        switch item {
        case .back: if web.canGoBack { web.goBack() }
        case .forward: if web.canGoForward { web.goForward() }
        case .tab(let id):
            if id == activeID {
                openStartPage(origin: .address(of: id), editing: true)   // 正在看的那个：改地址、搜索
            } else if let tab = tabs.first(where: { $0.id == id }) {
                show(tab)
                barFocus = .tab(id)   // 换过去，焦点留在标签栏上，可以接着换；按下回到网页
            }
        case .newTab: openStartPage(origin: .newTab(from: activeID, isPrivate: activeTab?.isPrivate ?? false))
        case .more: _ = openMenu()
        }
    }

    func activateMenu(_ item: MenuItem) {
        switch item {
        case .newPrivateTab: closeMenu(); openStartPage(origin: .newTab(from: activeID, isPrivate: true))
        case .reload: closeMenu(); pageWebView?.reload()
        case .zoomOut: setZoom(BrowserZoom.step(from: page.zoom, larger: false))
        case .zoomReset: setZoom(standardZoom)
        case .zoomIn: setZoom(BrowserZoom.step(from: page.zoom, larger: true))
        case .closeTab: closeMenu(); if let id = activeID { closeTab(id) }
        case .startPage: closeMenu(); openStartPage(origin: .newTab(from: activeID, isPrivate: activeTab?.isPrivate ?? false))
        }
    }

    /// 标签栏、菜单里横着 / 竖着算哪一类（规则见 TVController.Module）
    func chromeModule(horizontal: Bool) -> TVController.Module {
        if menu != nil { return .picker }                  // 菜单：一列固定的几行
        return horizontal ? .picker : .drawer              // 一排固定的按钮和标签；从上面拉下来的一条
    }

    func chromeCanMove(_ direction: RemoteCommand.Direction) -> Bool {
        guard let focus = barFocus else { return false }
        if let item = menu { return Self.menuStep(from: item, direction) != nil }
        switch direction {
        case .left: return Self.step(in: barItems, from: focus, by: -1) != nil
        case .right: return Self.step(in: barItems, from: focus, by: 1) != nil
        case .down: return true
        case .up: return false
        }
    }

    /// 鼠标点了标签栏上的一个
    func tapBar(_ item: BarFocus) {
        guard pageWebView != nil else { return }
        withAnimation(Motion.focus) { barFocus = item; menu = nil }
        activate(item)
    }

    func tapMenu(_ item: MenuItem) {
        guard menu != nil else { return }
        withAnimation(Motion.focus) { menu = item }
        activateMenu(item)
    }
}

/// 在 Mac TV 里看过的页面（最多一百条，最新的在前）。无痕标签页的不记
enum BrowserHistory {
    private static let key = "browserHistory"
    static var all: [WebPage] {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([WebPage].self, from: $0) } ?? []
    }
    static func add(_ url: URL, title: String) {
        var pages = all.filter { $0.url != url }
        pages.insert(WebPage(url: url, title: title, visited: Date()), at: 0)
        if let data = try? JSONEncoder().encode(Array(pages.prefix(100))) { UserDefaults.standard.set(data, forKey: key) }
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

    /// 在浏览器里打开一个网页（开成一个标签页）
    func openBrowserPage(_ url: URL) {
        browserStore.tv = self
        browserStore.open(url)
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
