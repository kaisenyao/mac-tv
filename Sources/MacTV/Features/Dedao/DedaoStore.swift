import AppKit
import Combine
import SwiftUI

/// 得到的原生页面，照着得到 App 的"听书"来：
///
/// - 没登录：一张二维码，用得到 App 或微信扫（登录你自己在手机上确认，这里不经手密码）。
/// - 登录着：页面马上出来（上次的分类、几排的标题），内容取到一排填一排，不先放一页"正在打开"。
/// - 左边栏（和哔哩哔哩的一样）：首页，下面是听书的分类（职场发展、自然科学、大咖书单……，从得到取，记着上次的）。
///   在一排最左边再按左拉出来，上下挑，停一下右边才换（换一页要重画好几排），按右、确认或返回收起。
/// - 首页：最近学习（最新的在前，带进度，手机上听的也在）、热门、新书、名家讲书、精品听书、我的课程。
/// - 分类页：全部（最热、最新）、再一个小类一排（自然科学 › 科学思维、天文学……），快到一排的头再取下一页。
/// - 右上角：正在播放（有的话）和账号。最上面一排再按上到这里，左右换，确认进去：播放界面，
///   或者账号菜单（刷新、设置、退出登录；同网易云的头像菜单，退出登录要再确认一次）。
/// - 设置：默认倍速、自动接着放。
/// - 选一本书直接放、打开播放界面（放完接着放这一排的下一本）；选一门课、一套名家讲书、一个分组，
///   进去是一列（课的讲、合集的书、分组里的东西）。
/// - 播放界面：确认 = 放 / 停，左右 = 退 15 秒 / 进 30 秒，双指横滑 = 拖进度；往下是上一讲、倍速、下一讲。
/// 返回一层一层退：菜单 → 播放界面 → 列表、设置 → 第一排 → 首页 → 主屏。离开得到时停下，并告诉得到听到哪了
@MainActor
final class DedaoStore: ObservableObject {
    static let appID = "dedao"

    weak var tv: TVController?
    let player = DedaoPlayer()
    /// 正在放的那一讲的文稿（播放界面右边）
    let reader = DedaoReader()

    /// loading 只在退出登录的那一下（等最后几次回报发完）；平时登录着就是 ready，内容边取边填
    enum Phase: Equatable { case loading, signIn, ready, failed(String) }
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var user: DedaoAPI.User?
    /// 出错的那一页上选中的是"重试"（0）还是"重新扫码登录"（1，登录着时才有）
    @Published private(set) var failureChoice = 0

    // MARK: 登录
    @Published private(set) var loginCode: DedaoAPI.LoginCode?
    @Published private(set) var loginExpired = false
    private var polling: Task<Void, Never>?
    /// 第几次要二维码：上一次的回来时已经换了新的，就不算数
    private var signInRun = 0

    // MARK: 左边栏

    /// 左边栏的一项：首页，或者得到的一个分类
    struct Section: Identifiable, Equatable {
        let id: String
        let title: String
        let symbol: String
        let topic: DedaoAPI.Topic?

        static let home = Section(id: "home", title: "首页", symbol: "house.fill", topic: nil)
    }
    /// 左边栏露出来的几项（设置里"左边栏显示"勾掉的不在里面；首页一直在）
    @Published private(set) var sections: [Section] = [.home]
    /// 得到给的全部分类（每一项下面的几排都按它建好，勾回来马上就有）
    private(set) var allSections: [Section] = [.home]
    /// 设置里勾掉、不在左边栏显示的分类（记的是没勾的，所以得到新加的分类默认是显示的）
    /// 每个人（个人资料）各选各的（见 ProfileSpace）
    static var hiddenSections: Set<String> {
        get { Set(ProfileSpace.current.defaults.stringArray(forKey: "dedaoHiddenSections") ?? []) }
        set { ProfileSpace.current.defaults.set(Array(newValue).sorted(), forKey: "dedaoHiddenSections") }
    }
    /// 右边现在是哪一项
    @Published private(set) var section = Section.home.id
    /// 左边栏里高亮停在哪一项。上下走时先只动它，停一会儿才换右边（同哔哩哔哩）
    @Published private(set) var sidebarSection = Section.home.id
    private var sidebarCommit: Task<Void, Never>?

    // MARK: 一排一排

    struct Row: Identifiable, Equatable {
        enum State: Equatable { case loading, ready, failed }
        /// 带着左边栏那一项的编号（"home/recent"、"<分类>/<小类>"），所以哪一页的哪一排都不重名
        let id: String
        let title: String
        var items: [DedaoAPI.Item] = []
        var state: State = .loading
        /// 取到了但是空的时候说的那句
        var empty = "暂无内容"
    }
    /// 左边栏每一项下面的几排
    @Published private(set) var content: [String: [Row]] = [:]
    /// 每一项停在哪一排：记排的编号（上面插进来一排时焦点不会跳到别的排上）
    @Published private(set) var focusedRows: [String: String] = [:]
    @Published private(set) var columns: [String: Int] = [:]

    enum TopItem: Hashable { case player, account }
    /// 焦点在哪一块：一排排卡片、左边栏、右上角那一排
    enum Focus: Equatable { case rows, sidebar, top(TopItem) }
    @Published private(set) var focus: Focus = .rows

    /// 一排从哪取
    private enum Source {
        case recent
        case courses
        /// whole：榜单，一次全给
        case products(topic: String, name: String, label: String, sort: DedaoAPI.Sort, whole: Bool)
    }
    private var sources: [String: Source] = [:]
    /// 一排取到第几页了：page 下一页是第几页，cursor 是得到要带回去的（request_id、最近学习的 timestamp）。
    /// 没有这一项的排还没取过（换了分类、刷新以后都是这样）
    private struct Paging {
        var page = 0
        var cursor = ""
        var more = true
        var loading = false
    }
    private var paging: [String: Paging] = [:]
    /// 换了账号、重新载入以后，之前还没回来的都不算数
    private var loadRun = 0

    // MARK: 账号菜单（同网易云的头像菜单）、设置

    enum MenuAction: Equatable {
        case refresh, settings, signOut, cancel, confirmSignOut, speed(Float)
        /// 设置里"左边栏显示"：勾上 / 勾掉这一个分类（菜单留着，可以接着勾）
        case toggleSection(String)
        /// 设置里"主屏顶部显示"：开关"正在听的书"；"新书推荐"往里一层（开关它、挑分类）
        case toggleListening, newBooksMenu, toggleNewBooks, toggleCategory(String)
        /// 播放界面的"⋯"：倍速、定时关闭（各是一层）、讲目列表；sleep 是定时的第几种
        case speedMenu, sleepMenu, sleep(Int), lectures
    }
    struct MenuItem: Equatable {
        let symbol: String
        let title: String
        let action: MenuAction
        /// 右边写的现在的值（"1.5×"）；定时关闭那一行的剩余时间由界面自己每秒算
        var detail = ""
        /// 右边一个"›"：按右（或确认）往里一层
        var chevron = false
        /// 这一组到这里为止：下面画一条细线和下一组隔开
        var groupEnd = false
        /// 确认"退出登录"的那一项：选中时高亮是红的
        var danger: Bool { action == .confirmSignOut }
    }
    /// 菜单从哪长出来：右上角的账号、设置页的那一行、播放界面书名右边的"⋯"
    enum MenuAnchor: Equatable { case account, setting, nowPlaying }
    struct Menu: Equatable {
        var anchor: MenuAnchor
        var items: [MenuItem]
        var index = 0
        var title: String?
    }
    @Published private(set) var menu: Menu?
    /// 菜单是一层一层的（退出登录里面是"取消 / 退出登录"）：记着上一层，返回一次只退一层
    private var menuParents: [Menu] = []

    enum Setting: CaseIterable { case speed, autoNext, sidebar, shelf }
    @Published private(set) var settingsOpen = false
    @Published private(set) var settingIndex = 0

    // MARK: 列表（一门课的讲、一套名家讲书、一个分组）
    enum Page: Equatable {
        case tracks(DedaoAPI.Item)
        case folder(DedaoAPI.Item)
        var item: DedaoAPI.Item {
            switch self { case .tracks(let item), .folder(let item): item }
        }
    }
    @Published private(set) var pages: [Page] = []
    @Published private(set) var tracks: [String: [DedaoAPI.Track]] = [:]
    @Published private(set) var folders: [String: [DedaoAPI.Item]] = [:]
    @Published private(set) var courses: [String: DedaoAPI.Course] = [:]
    @Published private(set) var listFocus: [String: Int] = [:]
    @Published private(set) var loadingPages: Set<String> = []
    /// 取不到的列表（不记成空的，按确认再取）
    @Published private(set) var failedPages: Set<String> = []
    /// 还有下一页的课
    private var morePages: Set<String> = []
    private var lectureLoads: [String: Task<Void, Error>] = [:]

    // MARK: 播放界面
    // 和网易云的正在播放一模一样的按法：确认 / 空格 = 放 / 停；短按左右 = 上一讲 / 下一讲（松开时算数）；
    // 按住左右 = 快退 / 快进，越按越快，松手从那里接着放；转盘、快进快退键 = ±10 秒；按住确认 = "⋯"菜单
    //（倍速、定时关闭、讲目列表）；下 = 讲目列表（不止一讲时）；返回 = 收起
    @Published private(set) var playerOpen = false
    /// 讲目列表（播放界面里按下，从下面滑上来的一排，同网易云的播放列表）
    @Published private(set) var lecturesVisible = false
    @Published private(set) var lectureFocus = 0
    /// 按住左右键快进快退
    private var holdTimer: Timer?
    private var holdStarted = Date()
    /// 上一次换讲是什么时候（手机遥控器按住方向键时连着发来的不算）
    private var lastLectureStep = Date.distantPast

    /// 上一次取到账号和分类是什么时候；distantPast = 这个账号还一次都没取到过（取不到时要放出错页）
    private var loadedAt = Date.distantPast
    private var playerChanges: AnyCancellable?
    private var trackChanges: AnyCancellable?
    /// 选了一本书、正在要它的音频
    private var opening: Task<Void, Never>?
    /// 这次以来听过东西：回到页面上时"最近学习"重新取一次
    private var listened = false
    private var timeChanges: AnyCancellable?

    init() {
        DedaoAPI.useProfile(.current)   // 登录信息是现在在看的这个人的（见 ProfileSpace）
        // 换了一讲、放 / 停、列表变了，页面跟着重画（右上角的正在播放、列表里在放的那一讲）。
        // 时间一秒变两次，不转过来：要显示时间的地方自己看着播放器
        playerChanges = Publishers.CombineLatest3(player.$queue, player.$index, player.$paused)
            .map { queue, index, paused in
                "\(queue.indices.contains(index) ? queue[index].id : "")-\(queue.count)-\(paused)"
            }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
        // 换了一讲：去取它的文稿（这里拿到的是要换成的那一讲，播放器还没改完）
        trackChanges = Publishers.CombineLatest(player.$queue, player.$index)
            .map { queue, index in queue.indices.contains(index) ? queue[index] : nil }
            .removeDuplicates { $0?.id == $1?.id }
            .sink { [weak self] track in self?.reader.show(track, userName: self?.user?.name) }
        // 文稿念到哪：播放器的媒体时间一变（放着每半秒、拖的时候每一下、跳完马上）就重算
        timeChanges = Publishers.CombineLatest4(player.$time, player.$scrubbing, player.$scrubTarget, player.$duration)
            .sink { [weak self] time, scrubbing, target, duration in
                self?.reader.follow(time: scrubbing ? target : time, duration: duration)
            }
    }

    /// 给按键音用：焦点变了才出声
    var focusKey: String {
        "\(phase)-\(failureChoice)-\(loginExpired)-\(focus)-\(section)-\(sidebarSection)-\(focusedRows[section] ?? "")-\(column)"
            + "-\(pages.count)-\(currentPage.map { listFocus[$0.item.id] ?? 0 } ?? -1)"
            + "-\(playerOpen)-\(lecturesVisible)-\(lectureFocus)-\(player.index)-\(player.current?.id ?? "")"
            + "-\(menu?.anchor == nil ? "" : "\(menu!.anchor)")-\(menu?.index ?? -1)"
            + "-\(menu?.items.count ?? 0)-\(menu?.title ?? "")-\(settingsOpen)-\(settingIndex)"
    }

    var currentPage: Page? { pages.last }

    // MARK: 进出

    func opened() {
        if !DedaoCookies.signedIn {
            startSignIn()
        } else if phase != .ready || Date().timeIntervalSince(loadedAt) > 600 {
            reload()
        } else {
            refreshRecent()
        }
    }

    /// 回主屏、得到留在后台（见 AppQuit）：书接着放，只在屏幕上才有用的停掉——扫码登录不再问
    /// （再进来 opened 换一张新码），按住左右的快进快退在走到的地方停下
    func backgrounded() {
        polling?.cancel()
        polling = nil
        endHold()
    }

    /// 退出得到（见 closeDedao）：正在要的音频不要了（不然退出以后它在后台响起来），正在放的停下
    func closed() {
        polling?.cancel()
        polling = nil
        opening?.cancel()
        opening = nil
        sidebarCommit?.cancel()
        sidebarCommit = nil
        holdTimer?.invalidate()
        holdTimer = nil
        if player.scrubbing { player.endScrub() }
        player.stop()
        playerOpen = false
        lecturesVisible = false
        menu = nil
        menuParents = []
        settingsOpen = false
        if focus == .sidebar { focus = .rows; sidebarSection = section }
    }

    /// 登录着打开得到：页面马上出来（上次的分类、几排的标题和空着的卡片），再去取账号、分类和每一排
    func reload() {
        if content.isEmpty { setSections(DedaoAPI.savedTopics() ?? DedaoAPI.fallbackTopics) }
        if phase != .ready { withAnimation(Motion.appear) { phase = .ready } }
        accountLoading = true
        Task { @MainActor in await load(quietly: false) }
    }

    /// 正在取账号和分类（取好了会清掉列表页）：这期间从主屏顶部选的课、名家讲书先记着，取好了再打开
    private var accountLoading = false
    private var pendingShelf: DedaoAPI.Item?

    /// 账号、分类、首页那几排（还有现在这一页）重新取一遍。取的时候原来的内容留着，不闪。
    /// 成了返回 true；这个账号还一次都没取到过时，取不到就放出错页（quietly：只返回 false，不说）
    @discardableResult
    private func load(quietly: Bool) async -> Bool {
        loadRun += 1
        let run = loadRun
        do {
            async let account = DedaoAPI.user()
            async let tree = Self.topicsIfAny()
            let who = try await account
            let topics = await tree
            guard run == loadRun else { return false }
            user = who
            loadedAt = Date()
            // 取过的课、合集、分组都不要了（可能换了账号、买了新的），再点进去拿的是最新的
            pages = []
            tracks = [:]
            folders = [:]
            courses = [:]
            listFocus = [:]
            failedPages = []
            morePages = []
            lectureLoads = [:]
            setSections(topics ?? DedaoAPI.savedTopics() ?? DedaoAPI.fallbackTopics)
            if phase != .ready { withAnimation(Motion.appear) { phase = .ready } }
            for row in content[Section.home.id] ?? [] { loadRow(row.id) }
            loadNearbyRows()
            accountLoading = false
            if let pending = pendingShelf { pendingShelf = nil; playFromShelf(pending) }
            return true
        } catch {
            guard run == loadRun else { return false }
            accountLoading = false
            pendingShelf = nil
            guard !DedaoAPI.isCancellation(error) else { return false }
            if error as? DedaoError == .signedOut { signOut(); return false }
            let message = (error as? DedaoError)?.message ?? DedaoError.offline.message
            if loadedAt == .distantPast { fail(message) } else if !quietly { tv?.showToast(message) }
            return false
        }
    }

    /// 账号菜单里的"刷新"：分类、几排、最近学习都重新取
    private func refresh() {
        accountLoading = true
        Task { @MainActor in
            if !(await load(quietly: true)) { tv?.showToast("无法刷新，请检查网络") }
        }
    }

    private static func topicsIfAny() async -> [DedaoAPI.Topic]? {
        do { return try await DedaoAPI.topics() } catch {
            Log.playback.info("dedao: topics not loaded: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func fail(_ message: String) {
        failureChoice = 0
        phase = .failed(message)
    }

    // MARK: 左边栏的几项、每一项下面的几排

    /// 认得的分类按这个顺序排（主题在前，场景、书单在后）；不认得的（得到新加的）照得到给的顺序接在后面
    nonisolated static let preferredOrder = ["职场发展", "财富投资", "商业经管", "身心关系", "教育成长", "历史", "人文艺术", "社会观察",
                                 "自然科学", "AI", "高分必听", "大咖书单", "晨间唤醒", "通勤充电", "睡前放松", "运动伴侣", "亲子共读"]

    /// 左边栏：首页在最上面，下面是分类。榜单（热门、名家讲书……）放在首页里，不单独占一项；视频的不要
    static func sections(from topics: [DedaoAPI.Topic]) -> [Section] {
        let subjects = topics.enumerated().filter { $0.element.kind == .subject }
        let ordered = subjects.sorted { a, b in
            let x = preferredOrder.firstIndex(of: a.element.name) ?? preferredOrder.count + a.offset
            let y = preferredOrder.firstIndex(of: b.element.name) ?? preferredOrder.count + b.offset
            return x < y
        }
        return [.home] + ordered.map { Section(id: $0.element.id, title: $0.element.name, symbol: symbol(for: $0.element.name), topic: $0.element) }
    }

    static func symbol(for name: String) -> String {
        let symbols = ["职场发展": "briefcase.fill", "财富投资": "chart.line.uptrend.xyaxis", "商业经管": "building.2.fill",
                       "身心关系": "heart.fill", "教育成长": "graduationcap.fill", "历史": "building.columns.fill",
                       "人文艺术": "paintpalette.fill", "社会观察": "globe.asia.australia.fill", "自然科学": "atom",
                       "AI": "cpu", "高分必听": "star.fill", "大咖书单": "person.2.fill", "晨间唤醒": "sunrise.fill",
                       "通勤充电": "tram.fill", "睡前放松": "moon.zzz.fill", "运动伴侣": "figure.run",
                       "亲子共读": "figure.and.child.holdinghands"]
        return symbols[name] ?? "books.vertical.fill"
    }

    /// 按分类排好左边栏和每一项下面的几排。之前取到过的排（编号一样的）先留着原来的卡片，新的取到了再换，不闪；
    /// 取的进度都清掉，所以每一排再看到时都会重新取一次
    private func setSections(_ topics: [DedaoAPI.Topic]) {
        let built = Self.sections(from: topics)
        let before = content
        allSections = built
        sections = Self.visible(built, hidden: Self.hiddenSections)
        content = [:]
        sources = [:]
        paging = [:]
        buildHome(topics)
        for entry in built { if let topic = entry.topic { buildTopic(topic) } }
        for (key, rows) in content {
            content[key] = rows.map { row in
                guard let old = before[key]?.first(where: { $0.id == row.id }), !old.items.isEmpty else { return row }
                var kept = row
                kept.items = old.items
                kept.state = .ready
                return kept
            }
        }
        focusedRows = focusedRows.filter { key, id in content[key]?.contains { $0.id == id } == true }
        if !sections.contains(where: { $0.id == section }) { section = Section.home.id }
        sidebarSection = section
        if focus == .sidebar || focus == .top(.player) && player.current == nil { focus = .rows }
    }

    /// 左边栏露出来的：首页一直在，勾掉的分类不要
    static func visible(_ all: [Section], hidden: Set<String>) -> [Section] {
        all.filter { $0.id == Section.home.id || !hidden.contains($0.id) }
    }

    /// 设置那一行右边写的："职场发展等 12 项"，全勾掉了是"仅首页"
    var sidebarSummary: String {
        ListSummary.chinese(sections.filter { $0.id != Section.home.id }.map(\.title), none: "仅首页")
    }

    /// "左边栏显示"那一列：每个分类一项，显示着的打勾
    private func sidebarMenuItems() -> [MenuItem] {
        let hidden = Self.hiddenSections
        return allSections.filter { $0.id != Section.home.id }.map {
            MenuItem(symbol: hidden.contains($0.id) ? "" : "checkmark", title: $0.title, action: .toggleSection($0.id))
        }
    }

    /// 勾上 / 勾掉一个分类：左边栏马上跟着变（几排早就建好了，不用重新取）。正看着的那一项被勾掉了：回到首页
    private func toggleSection(_ id: String) {
        var hidden = Self.hiddenSections
        if hidden.contains(id) { hidden.remove(id) } else { hidden.insert(id) }
        Self.hiddenSections = hidden
        withAnimation(Motion.focus) {
            menu?.items = sidebarMenuItems()
            sections = Self.visible(allSections, hidden: hidden)
        }
        if !sections.contains(where: { $0.id == section }) { select(Section.home.id, keepMenu: true) }
        if !sections.contains(where: { $0.id == sidebarSection }) { sidebarSection = section }
    }

    /// 首页：最近学习、热门、新书、名家讲书、精品听书（照得到的榜单）、我的课程
    private func buildHome(_ topics: [DedaoAPI.Topic]) {
        var rows = [Row(id: "home/recent", title: "最近学习", empty: "暂无最近学习")]
        sources["home/recent"] = .recent
        let newBooks = Row(id: "home/new", title: "新书")
        sources[newBooks.id] = .products(topic: DedaoAPI.everything, name: "全部", label: DedaoAPI.everything, sort: .new, whole: false)
        for topic in topics where topic.kind == .ranking || topic.kind == .package {
            let row = Row(id: "home/\(topic.id)", title: topic.name)
            sources[row.id] = .products(topic: topic.id, name: topic.name, label: DedaoAPI.everything, sort: .hot, whole: true)
            rows.append(row)
            if topic.kind == .ranking, !rows.contains(where: { $0.id == newBooks.id }) { rows.append(newBooks) }
        }
        if !rows.contains(where: { $0.id == newBooks.id }) { rows.insert(newBooks, at: 1) }
        rows.append(Row(id: "home/courses", title: "我的课程"))
        sources["home/courses"] = .courses
        content[Section.home.id] = rows
    }

    /// 一个分类：全部（最热、最新），再一个小类一排
    private func buildTopic(_ topic: DedaoAPI.Topic) {
        var rows = [Row(id: "\(topic.id)/hot", title: "全部 · 最热"), Row(id: "\(topic.id)/new", title: "全部 · 最新")]
        sources[rows[0].id] = .products(topic: topic.id, name: topic.name, label: DedaoAPI.everything, sort: .hot, whole: false)
        sources[rows[1].id] = .products(topic: topic.id, name: topic.name, label: DedaoAPI.everything, sort: .new, whole: false)
        for label in topic.labels {
            let row = Row(id: "\(topic.id)/\(label.id)", title: label.name)
            sources[row.id] = .products(topic: topic.id, name: topic.name, label: label.id, sort: .hot, whole: false)
            rows.append(row)
        }
        content[topic.id] = rows
    }

    // MARK: 取一排

    /// 取一排（more：接着取下一页）
    private func loadRow(_ id: String, more: Bool = false) {
        guard let source = sources[id] else { return }
        // 最近学习要知道是谁（账号还没取到时先不取，取到了会再来）
        if case .recent = source, user == nil { return }
        var state = paging[id] ?? Paging()
        guard !state.loading, !more || state.more else { return }
        if !more {
            state = Paging()
            update(id) { if $0.items.isEmpty { $0.state = .loading } }
        }
        state.loading = true
        paging[id] = state
        let run = loadRun
        Task { @MainActor in
            do {
                let (items, next) = try await fetch(source, from: state)
                guard run == loadRun else { return }
                paging[id] = next
                update(id) { row in
                    if more {
                        let known = Set(row.items.map(\.id))
                        row.items += items.filter { !known.contains($0.id) }
                    } else {
                        row.items = Self.unique(items)
                    }
                    row.state = .ready
                }
                // 我的课程：没有买过课就不要这一排（它在最下面，去掉不会挪动别的排）
                if id == "home/courses", !more, items.isEmpty { removeRow(id) }
            } catch {
                guard run == loadRun else { return }
                paging[id]?.loading = false
                if DedaoAPI.isCancellation(error) { return }
                Log.playback.info("dedao: row \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                if error as? DedaoError == .signedOut { signOut(); return }
                if !more { update(id) { if $0.items.isEmpty { $0.state = .failed } } }
            }
        }
    }

    private func fetch(_ source: Source, from state: Paging) async throws -> ([DedaoAPI.Item], Paging) {
        var next = state
        next.loading = false
        switch source {
        case .recent:
            if let hazy = user?.hazy {
                do {
                    let page = try await DedaoAPI.recent(user: hazy, after: Int(state.cursor) ?? 0)
                    next.cursor = "\(page.cursor)"
                    next.more = page.more && page.cursor > 0
                    return (page.items, next)
                } catch where state.cursor.isEmpty && !DedaoAPI.isCancellation(error) {
                    // "最近学习"取不到（得到改了接口）：用书架上最近学过的顶上
                    Log.playback.info("dedao: recent failed, using the shelf: \(String(describing: error), privacy: .public)")
                }
            }
            next.more = false
            return (try await recentFromShelves(), next)
        case .courses:
            let items = try await DedaoAPI.shelf(.courses, page: state.page + 1)
            next.page = state.page + 1
            next.more = items.count >= 30
            return (items, next)
        case .products(let topic, let name, let label, let sort, let whole):
            let size = whole ? 100 : 18
            var page = try await DedaoAPI.products(topic: topic, name: name, label: label, sort: sort, page: state.page,
                                                   size: size, requestID: state.cursor)
            if whole, page.total > size {
                // 榜单比一次给的多：照它说的总数再要一次（网页版也是这样）
                page = try await DedaoAPI.products(topic: topic, name: name, label: label, sort: sort, size: min(page.total, 300))
            }
            next.page = state.page + 1
            next.cursor = page.requestID
            next.more = !whole && page.more
            return (page.items, next)
        }
    }

    /// 书架上的听书和课程，最近学过的在前（分组不要）
    private func recentFromShelves() async throws -> [DedaoAPI.Item] {
        async let books = DedaoAPI.shelf(.books)
        async let lessons = DedaoAPI.shelf(.courses)
        let all = try await books + lessons
        return all.filter { if case .folder = $0.kind { false } else { true } }.sorted { $0.studied > $1.studied }
    }

    /// 回到页面上、关了播放界面：听过东西的话，"最近学习"重新取一次（刚听的跑到最前面，进度也新）
    private func refreshRecent() {
        guard listened, phase == .ready else { return }
        listened = false
        loadRow("home/recent")
    }

    /// 焦点那一排和它上下的排还没取的，取（分类页有十几排，不一下子全取）
    private func loadNearbyRows() {
        let list = rows, at = row
        guard !list.isEmpty else { return }
        for index in max(0, at - 1)...min(list.count - 1, at + 2) where paging[list[index].id] == nil {
            loadRow(list[index].id)
        }
    }

    /// 快走到一排的头了：再取一页接在后面
    private func loadMoreIfNeeded() {
        guard rows.indices.contains(row) else { return }
        let line = rows[row]
        guard line.state == .ready, column >= line.items.count - 6, paging[line.id]?.more == true else { return }
        loadRow(line.id, more: true)
    }

    private static func unique(_ items: [DedaoAPI.Item]) -> [DedaoAPI.Item] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    /// 改一排。选中的那一个换了位置（比如最近学习刷新后刚听的那本跑到最前面）：焦点跟着它走
    private func update(_ id: String, _ change: (inout Row) -> Void) {
        for (key, var list) in content {
            guard let index = list.firstIndex(where: { $0.id == id }) else { continue }
            let before = list[index]
            let focused = before.items.indices.contains(column(of: before)) ? before.items[column(of: before)].id : nil
            change(&list[index])
            if let focused, let now = list[index].items.firstIndex(where: { $0.id == focused }) { columns[id] = now }
            content[key] = list
            return
        }
    }

    private func removeRow(_ id: String) {
        for (key, var list) in content {
            guard let index = list.firstIndex(where: { $0.id == id }) else { continue }
            if focusedRows[key] == id { focusedRows[key] = index > 0 ? list[index - 1].id : nil }
            list.remove(at: index)
            content[key] = list
            return
        }
    }

    // MARK: 登录

    func startSignIn() {
        signInRun += 1
        let run = signInRun
        phase = .signIn
        loginExpired = false
        loginCode = nil
        polling?.cancel()
        polling = Task { @MainActor in
            do {
                let code = try await DedaoAPI.loginCode()
                guard !Task.isCancelled, run == signInRun else { return }
                loginCode = code
                // 一秒半问一次扫了没有，最多十分钟
                for _ in 0..<400 {
                    try await Task.sleep(for: .seconds(1.5))
                    guard !Task.isCancelled, run == signInRun else { return }
                    let state = await DedaoAPI.loginState(code)
                    guard !Task.isCancelled, run == signInRun else { return }
                    switch state {
                    case .waiting: continue
                    case .expired: loginExpired = true; return
                    case .rejected:
                        // 收到的 cookie 不算数：清掉，下次换一张二维码从头来
                        DedaoAPI.signOut()
                        loginCode = nil
                        fail("手机上确认了，但得到没让这边登录上。按确认换一张二维码再试")
                        return
                    case .done:
                        loginCode = nil
                        reload()
                        tv?.appShelf.reset(Self.appID)   // 主屏顶部按这个账号取
                        return
                    }
                }
                loginExpired = true
            } catch {
                guard !Task.isCancelled, run == signInRun, !DedaoAPI.isCancellation(error) else { return }
                fail((error as? DedaoError)?.message ?? DedaoError.offline.message)
            }
        }
    }

    /// 退出登录（或者登录过期了）：先等最后几次"听到哪了"发完（要用登录信息），再清登录，换二维码
    private func signOut() {
        loadRun += 1
        loadedAt = .distantPast
        opening?.cancel()
        user = nil
        content = [:]
        sections = [.home]
        allSections = [.home]
        section = Section.home.id
        sidebarSection = section
        focus = .rows
        menu = nil
        menuParents = []
        settingsOpen = false
        pages = []
        playerOpen = false
        lecturesVisible = false
        phase = .loading
        Task { @MainActor in
            await player.reset()
            reader.reset()
            DedaoAPI.signOut()
            tv?.appShelf.reset(Self.appID)   // 主屏顶部不再放这个账号的东西（没登录就只剩得到的图标）
            // 清完了再要新的二维码（不然新二维码的那份会被一起清掉）；已经离开得到了就等下次进来再要
            if tv?.dedaoOpen == true { startSignIn() } else { phase = .signIn }
        }
    }

    // MARK: 按键

    func handle(_ command: RemoteCommand) {
        if case .playPause = command { player.togglePause(); return }
        // 快进快退键（手机遥控器、媒体键）：±10 秒（同网易云）
        if case .seek(let forward) = command { player.skip(forward ? 10 : -10); return }
        switch phase {
        case .loading: if case .back = command { tv?.goHome() }
        case .failed: handleFailure(command)
        case .signIn:
            switch command {
            case .select: if loginExpired { startSignIn() }
            case .back: tv?.goHome()
            default: break
            }
        case .ready:
            if menu != nil { handleMenu(command) }   // 菜单（播放界面的"⋯"也是）盖在最上面
            else if playerOpen { handlePlayer(command) }
            else if settingsOpen { handleSettings(command) }
            else if let page = currentPage { handleList(command, page: page) }
            else { handleBrowse(command) }
        }
    }

    /// 出错的页面：重试；登录着的话旁边还有"重新扫码登录"（cookie 坏了、一直进不去时用）
    var canRescan: Bool { DedaoCookies.signedIn }

    private func handleFailure(_ command: RemoteCommand) {
        switch command {
        case .move(.left), .move(.up): if failureChoice != 0 { withAnimation(Motion.focus) { failureChoice = 0 } }
        case .move(.right), .move(.down): if canRescan, failureChoice != 1 { withAnimation(Motion.focus) { failureChoice = 1 } }
        case .select: chooseFailure(failureChoice)
        case .back: tv?.goHome()
        default: break
        }
    }

    func chooseFailure(_ choice: Int) {
        guard case .failed = phase else { return }
        failureChoice = choice
        if choice == 1, canRescan { signOut() }
        else if DedaoCookies.signedIn { reload() }
        else { startSignIn() }
    }

    private func handleBrowse(_ command: RemoteCommand) {
        switch focus {
        case .sidebar:
            switch command {
            case .move(.up): step(-1)
            case .move(.down): step(1)
            case .move(.right), .select:
                commitSidebar()
                withAnimation(Motion.focus) { focus = .rows }
            // 左边栏是盖在右边内容上的：按一下返回是收起它、回到右边
            case .back:
                commitSidebar()
                withAnimation(Motion.focus) { focus = .rows }
            default: break
            }
        case .top(let item):
            let items = topItems
            let index = items.firstIndex(of: item) ?? 0
            switch command {
            case .move(.left):
                if index > 0 { withAnimation(Motion.focus) { focus = .top(items[index - 1]) } } else { openSidebar() }
            case .move(.right): if index + 1 < items.count { withAnimation(Motion.focus) { focus = .top(items[index + 1]) } }
            case .move(.down), .back: withAnimation(Motion.focus) { focus = .rows }
            case .select: activateTop(item)
            default: break
            }
        case .rows:
            switch command {
            case .move(.left): if column > 0 { setColumn(column - 1) } else { openSidebar() }
            case .move(.right): setColumn(column + 1)
            case .move(.up):
                if row > 0 { setRow(row - 1) }
                else if let first = topItems.first { withAnimation(Motion.focus) { focus = .top(first) } }   // 最上面一排再按上：右上角
            case .move(.down): if row + 1 < rows.count { setRow(row + 1) }
            case .select: activate()
            case .back:
                if row > 0 { setRow(0) }                                   // 先回到第一排
                else if section != Section.home.id { select(Section.home.id) }   // 分类页回到首页
                else { tv?.goHome() }
            default: break
            }
        }
    }

    private func handleList(_ command: RemoteCommand, page: Page) {
        let id = page.item.id
        let count = listCount(page)
        let at = listFocus[id] ?? 0
        switch command {
        case .move(.up): if at > 0 { setList(id, at - 1) }
        case .move(.down):
            if at + 1 < count { setList(id, at + 1) }
            loadMoreIfNeeded(page)
        case .select:
            // 没取到：再取一次
            if count == 0 { if failedPages.contains(id) { reloadPage(page) }; return }
            switch page {
            case .folder:
                let items = folders[id] ?? []
                if items.indices.contains(at) { open(items[at], from: nil) }
            case .tracks(let item):
                let list = tracks[id] ?? []
                guard list.indices.contains(at) else { return }
                guard list[at].playable else { tv?.showToast("此讲无法播放"); return }
                if player.current?.id == list[at].id { openPlayer(); return }
                play(list, at: at, in: item)
            }
        case .back:
            withAnimation(Motion.navigate) { _ = pages.popLast() }
        default: break
        }
    }

    /// 播放界面（同网易云的正在播放）：确认 = 放 / 停；左右 = 上一讲 / 下一讲（第一讲、最后一讲再按没反应）；
    /// 下 = 讲目列表（不止一讲时）；返回 = 收起。按住左右的快进快退在键盘那边（beginHold），按住确认是"⋯"菜单
    private func handlePlayer(_ command: RemoteCommand) {
        if lecturesVisible {
            // 讲目列表：左右挑，确认放那一讲；往上推回去（或返回）收起
            switch command {
            case .move(.left): if lectureFocus > 0 { withAnimation(stepMotion()) { lectureFocus -= 1 } }
            case .move(.right): if lectureFocus + 1 < player.queue.count { withAnimation(stepMotion()) { lectureFocus += 1 } }
            case .select:
                withAnimation(Motion.navigate) { lecturesVisible = false }
                if player.queue.indices.contains(lectureFocus), lectureFocus != player.index {
                    guard player.queue[lectureFocus].playable else { tv?.showToast("此讲无法播放"); return }
                    player.jump(toTrack: lectureFocus)
                }
            case .back, .move(.up): withAnimation(Motion.navigate) { lecturesVisible = false }
            case .playPause: player.togglePause()
            default: break
            }
            return
        }
        switch command {
        case .select, .playPause: player.togglePause()
        case .move(let direction) where direction == .left || direction == .right:
            // 一下一讲。手机遥控器按住方向键会连着发（键盘那边按住是快进快退）：连着来的不算，免得一下翻过好几讲
            let now = Date()
            guard now.timeIntervalSince(lastLectureStep) > 0.3 else { return }
            if direction == .left ? player.hasPrevious : player.hasNext {
                lastLectureStep = now
                player.step(direction == .left ? -1 : 1)
            }
        case .move(.down): openLectures()
        case .back: closePlayer()
        default: break
        }
    }

    /// 讲目列表：从下面滑上来，停在正在放的那一讲上（只有一讲时没有）
    private func openLectures() {
        guard player.queue.count > 1 else { return }
        lectureFocus = player.index
        withAnimation(Motion.navigate) { lecturesVisible = true }
    }

    // MARK: 按住左右键快进快退（同网易云）

    /// 播放界面上没有别的东西开着的时候，左右键才是"上一讲 / 下一讲、按住快进快退"
    var canHoldSeek: Bool { phase == .ready && playerOpen && menu == nil && !lecturesVisible && player.current != nil }

    /// 按住左右键：声音先停，进度条和文稿跟着走，越按越快；松手（endHold）从那里接着放
    func beginHold(forward: Bool) {
        guard canHoldSeek, player.duration > 0 else { return }
        player.beginScrub()
        holdStarted = Date()
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.player.scrubbing else { return }
                let held = Date().timeIntervalSince(self.holdStarted)
                let speed = held < 1.5 ? 8.0 : (held < 4 ? 20.0 : 45.0)   // 每按住一秒，往前 / 往后走多少秒
                let before = self.player.scrubTarget
                self.player.scrub(to: before + (forward ? 1 : -1) * speed * 0.05)
                // 每过一个档位"嗒"一声、震一下，和双指拖进度一样
                if ScrubDetent.crossed(from: before, to: self.player.scrubTarget, duration: self.player.duration) {
                    self.tv?.feedback.play(.move, from: .keyboard)
                }
            }
        }
    }

    func endHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        player.endScrub()
    }

    /// 按住左右在快进快退
    var holdSeeking: Bool { holdTimer != nil }

    /// 测试用：当作登录了、播放界面开着、在听这一讲（不联网、不出声）
    func pretendListening(_ track: DedaoAPI.Track) {
        phase = .ready
        playerOpen = true
        player.pretendLoaded(track)
    }

    // MARK: 播放界面的"⋯"菜单（同网易云）

    /// 按住确认、点"⋯"：倍速、定时关闭、讲目列表。返回是否打开了（没打开就是一次普通的确认）
    @discardableResult
    func openPlayerMenu() -> Bool {
        guard phase == .ready, playerOpen, menu == nil, !lecturesVisible, player.current != nil else { return false }
        menuParents = []
        withAnimation(Motion.focus) { menu = Menu(anchor: .nowPlaying, items: playerMenuItems()) }
        return true
    }

    private func playerMenuItems() -> [MenuItem] {
        var items = [MenuItem(symbol: "gauge.with.dots.needle.67percent", title: "倍速", action: .speedMenu,
                              detail: Self.speedText(player.speed)),
                     MenuItem(symbol: "timer", title: "定时关闭", action: .sleepMenu)]
        if player.queue.count > 1 { items.append(MenuItem(symbol: "list.bullet", title: "目录", action: .lectures)) }
        return items
    }

    /// 点"⋯"：开着就收起
    func tapMore() {
        if menu?.anchor == .nowPlaying { dismissMenu() } else { openPlayerMenu() }
    }

    /// 点封面：放 / 停
    func tapPlayPause() { if player.current != nil { player.togglePause() } }

    /// 点讲目列表里的一讲
    func tapLecture(_ index: Int) {
        guard lecturesVisible, player.queue.indices.contains(index) else { return }
        lectureFocus = index
        handlePlayer(.select)
    }

    /// 点讲目列表外面：收起
    func dismissLectures() {
        guard lecturesVisible else { return }
        withAnimation(Motion.navigate) { lecturesVisible = false }
    }

    // MARK: 左边栏

    private func openSidebar() {
        sidebarSection = section
        withAnimation(Motion.focus) { focus = .sidebar }
    }

    private func step(_ delta: Int) {
        guard let index = sections.firstIndex(where: { $0.id == sidebarSection }), sections.indices.contains(index + delta) else { return }
        withAnimation(Motion.focus) { sidebarSection = sections[index + delta].id }
        sidebarCommit?.cancel()
        sidebarCommit = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.commitSidebar()
        }
    }

    /// 高亮停住了，或者离开左边栏：右边换成高亮的那一项
    private func commitSidebar() {
        sidebarCommit?.cancel()
        sidebarCommit = nil
        if sidebarSection != section { select(sidebarSection) }
    }

    /// 换到左边栏的这一项（鼠标点一下也是这个）。keepMenu：设置里勾掉了正看着的分类，菜单还留着
    func select(_ id: String, keepMenu: Bool = false) {
        guard sections.contains(where: { $0.id == id }) else { return }
        sidebarCommit?.cancel()
        sidebarCommit = nil
        if !keepMenu { dismissMenu() }
        sidebarSection = id
        withAnimation(Motion.navigate) { section = id }
        loadNearbyRows()
    }

    // MARK: 右上角

    /// 右上角那一排：正在播放（有的话）、账号
    var topItems: [TopItem] { (player.current != nil ? [.player] : []) + [.account] }

    private func activateTop(_ item: TopItem) {
        switch item {
        case .player: openPlayer()
        case .account: openAccountMenu()
        }
    }

    /// 鼠标点了右上角的一个：选中它并打开（账号菜单开着时再点一下是收起）
    func tapTop(_ item: TopItem) {
        guard phase == .ready, !playerOpen, !settingsOpen, currentPage == nil, topItems.contains(item) else { return }
        if item == .account, menu?.anchor == .account { dismissMenu(); return }
        dismissMenu()
        withAnimation(Motion.focus) { focus = .top(item) }
        activateTop(item)
    }

    // MARK: 菜单

    /// 账号菜单：刷新、设置、退出登录（同网易云的头像菜单）
    private func openAccountMenu() {
        menuParents = []
        withAnimation(Motion.focus) {
            menu = Menu(anchor: .account, items: [MenuItem(symbol: "arrow.clockwise", title: "刷新", action: .refresh),
                                                  MenuItem(symbol: "gearshape", title: "设置", action: .settings),
                                                  MenuItem(symbol: "rectangle.portrait.and.arrow.right", title: "退出登录", action: .signOut)])
        }
    }

    /// 菜单：上下挑，确认；返回（或左）退一层，最外层才收起
    private func handleMenu(_ command: RemoteCommand) {
        guard let menu else { return }
        switch command {
        case .move(.up): if menu.index > 0 { withAnimation(Motion.focus) { self.menu?.index = menu.index - 1 } }
        case .move(.down): if menu.index + 1 < menu.items.count { withAnimation(Motion.focus) { self.menu?.index = menu.index + 1 } }
        case .select: if menu.items.indices.contains(menu.index) { run(menu.items[menu.index].action) }
        // 带"›"的那一行：按右往里一层（同网易云的多层菜单）
        case .move(.right): if menu.items.indices.contains(menu.index), menu.items[menu.index].chevron { run(menu.items[menu.index].action) }
        case .back, .move(.left): withAnimation(Motion.focus) { self.menu = menuParents.popLast() }
        default: break
        }
    }

    private func run(_ action: MenuAction) {
        switch action {
        case .refresh:
            dismissMenu()
            refresh()
        case .settings:
            dismissMenu()
            openSettings()
        case .signOut:
            // 先问一次：换成"取消 / 退出登录"两项，默认停在"取消"上，误按确认不会退
            if let menu { menuParents.append(menu) }
            withAnimation(Motion.focus) {
                menu = Menu(anchor: .account,
                            items: [MenuItem(symbol: "xmark", title: "取消", action: .cancel),
                                    MenuItem(symbol: "rectangle.portrait.and.arrow.right", title: "退出登录", action: .confirmSignOut)],
                            title: "要退出登录吗？")
            }
        case .cancel:
            withAnimation(Motion.focus) { menu = menuParents.popLast() }
        case .confirmSignOut:
            dismissMenu()
            signOut()
        case .speed(let value):
            dismissMenu()
            player.setSpeed(value)
        case .toggleSection(let id):
            toggleSection(id)
        case .speedMenu:
            // 往里一层：六档倍速，勾着现在的那一档、打开时停在它上面（同网易云的音质）
            let speeds = DedaoPlayer.speeds
            push(Menu(anchor: .nowPlaying,
                      items: speeds.map { MenuItem(symbol: $0 == player.speed ? "checkmark" : "", title: Self.speedText($0), action: .speed($0)) },
                      index: speeds.firstIndex(of: player.speed) ?? 1, title: "倍速"))
        case .sleepMenu:
            let choices = DedaoSleepTimer.choices
            let chosen = player.sleep.flatMap { timer in choices.firstIndex(of: timer.choice) } ?? 0
            push(Menu(anchor: .nowPlaying,
                      items: choices.enumerated().map { MenuItem(symbol: $0.offset == chosen ? "checkmark" : "", title: $0.element.title, action: .sleep($0.offset)) },
                      index: chosen, title: "定时关闭"))
        case .sleep(let at):
            dismissMenu()
            if DedaoSleepTimer.choices.indices.contains(at) { player.setSleep(DedaoSleepTimer.choices[at]) }
        case .lectures:
            dismissMenu()
            openLectures()
        case .toggleListening:
            toggleListening()
        case .newBooksMenu:
            push(Menu(anchor: .setting, items: newBooksMenuItems(), index: 0, title: "新书推荐"))
        case .toggleNewBooks:
            toggleNewBooks()
        case .toggleCategory(let name):
            toggleCategory(name)
        }
    }

    /// 菜单往里一层：返回时回到这一层
    private func push(_ next: Menu) {
        if let menu { menuParents.append(menu) }
        withAnimation(Motion.focus) { menu = next }
    }

    /// 鼠标点了菜单里的一项
    func tapMenu(_ index: Int) {
        guard let menu, menu.items.indices.contains(index) else { return }
        self.menu?.index = index
        run(menu.items[index].action)
    }

    /// 鼠标停在菜单的一项上：高亮跟过去
    func hoverMenu(_ index: Int) {
        guard let menu, menu.items.indices.contains(index), menu.index != index else { return }
        withAnimation(Motion.focus) { self.menu?.index = index }
    }

    /// 收起菜单（点菜单外面、换页时）
    func dismissMenu() {
        menuParents = []
        guard menu != nil else { return }
        withAnimation(Motion.focus) { menu = nil }
    }

    // MARK: 设置

    private func openSettings() {
        settingIndex = 0
        withAnimation(Motion.navigate) { settingsOpen = true }
    }

    /// 设置页：上下挑一行，确认改（倍速弹出一列档位，开关直接换）；返回回到右上角的账号上
    private func handleSettings(_ command: RemoteCommand) {
        let count = Setting.allCases.count
        switch command {
        case .move(.up): if settingIndex > 0 { withAnimation(Motion.focus) { settingIndex -= 1 } }
        case .move(.down): if settingIndex + 1 < count { withAnimation(Motion.focus) { settingIndex += 1 } }
        case .select: activateSetting(settingIndex)
        case .back:
            withAnimation(Motion.navigate) { settingsOpen = false }
            withAnimation(Motion.focus) { focus = .top(.account) }
        default: break
        }
    }

    func activateSetting(_ index: Int) {
        guard settingsOpen, Setting.allCases.indices.contains(index) else { return }
        withAnimation(Motion.focus) { settingIndex = index }
        switch Setting.allCases[index] {
        case .speed:
            // 一列档位，勾着现在的那一档，打开时就停在它上面
            let speeds = DedaoPlayer.speeds
            menuParents = []
            withAnimation(Motion.focus) {
                menu = Menu(anchor: .setting,
                            items: speeds.map { MenuItem(symbol: $0 == player.speed ? "checkmark" : "", title: Self.speedText($0), action: .speed($0)) },
                            index: speeds.firstIndex(of: player.speed) ?? 1)
            }
        case .autoNext:
            withAnimation(Motion.focus) { player.autoNext.toggle() }
            objectWillChange.send()
        case .sidebar:
            // 多选（同网易云的"主屏顶部显示"）：按确认勾上 / 勾掉，菜单留着，返回才收起
            let items = sidebarMenuItems()
            guard !items.isEmpty else { tv?.showToast("分类尚未载入，请稍后再试"); return }
            menuParents = []
            withAnimation(Motion.focus) { menu = Menu(anchor: .setting, items: items, index: 0) }
        case .shelf:
            // 多选（同网易云）：正在播放在最前面，下面是几种书单；按确认勾上 / 勾掉，菜单留着，返回才收起
            menuParents = []
            withAnimation(Motion.focus) { menu = Menu(anchor: .setting, items: shelfMenuItems(), index: 0) }
        }
    }

    // MARK: 主屏顶部（选中得到的图标时轮播的那几页，见 AppShelf）

    /// "主屏顶部显示"那一列：正在听的书（下面一条细线），新书推荐（右边写几个分类，"›"往里一层）
    private func shelfMenuItems() -> [MenuItem] {
        let names = Self.shelfCategories(DedaoAPI.savedTopics() ?? []).map(\.name)
        return [MenuItem(symbol: DedaoShelfSource.showsListening ? "checkmark" : "", title: "正在播放", action: .toggleListening,
                         groupEnd: true),
                MenuItem(symbol: DedaoShelfSource.showsNewBooks ? "checkmark" : "", title: "新书推荐", action: .newBooksMenu,
                         detail: DedaoShelfSource.showsNewBooks ? DedaoShelfSource.categorySummary(names) : "关闭", chevron: true)]
    }

    /// "新书推荐"里面一层：开关新书推荐（下面一条细线），再是每个分类（勾着的推荐它的新书）
    private func newBooksMenuItems() -> [MenuItem] {
        let hidden = DedaoShelfSource.hiddenCategories
        return [MenuItem(symbol: DedaoShelfSource.showsNewBooks ? "checkmark" : "", title: "新书推荐", action: .toggleNewBooks,
                         groupEnd: true)]
            + Self.shelfCategories(DedaoAPI.savedTopics() ?? []).map {
                MenuItem(symbol: hidden.contains($0.name) ? "" : "checkmark", title: $0.name, action: .toggleCategory($0.name))
            }
    }

    /// 改了以后：这一层、外面那一层都换成新的样子（返回时外面那一层的字也是新的），主屏顶部停下来以后重新取一次
    private func shelfSettingsChanged(listening: Bool = false) {
        withAnimation(Motion.focus) {
            if menu?.title == "新书推荐" { menu?.items = newBooksMenuItems() } else { menu?.items = shelfMenuItems() }
            if let last = menuParents.indices.last, menuParents[last].anchor == .setting, menuParents[last].title == nil {
                menuParents[last].items = shelfMenuItems()
            }
        }
        objectWillChange.send()
        if listening { tv?.appShelf.dedaoNowSettingChanged() }
        tv?.appShelf.sourceChangedSoon(Self.appID)
    }

    /// 正在听的书、新书推荐至少留一个（全关了主屏顶部就空了）。这三个开关 设置 › Apps › Top Shelf 里也用
    func toggleListening() {
        guard !DedaoShelfSource.showsListening || DedaoShelfSource.showsNewBooks else { tv?.showToast("至少选择一项"); return }
        DedaoShelfSource.showsListening.toggle()
        shelfSettingsChanged(listening: true)
    }

    func toggleNewBooks() {
        guard !DedaoShelfSource.showsNewBooks || DedaoShelfSource.showsListening else { tv?.showToast("至少选择一项"); return }
        DedaoShelfSource.showsNewBooks.toggle()
        shelfSettingsChanged()
    }

    /// 勾上 / 勾掉一个分类：至少留一个
    func toggleCategory(_ name: String) {
        var hidden = DedaoShelfSource.hiddenCategories
        let all = Self.shelfCategories(DedaoAPI.savedTopics() ?? []).map(\.name)
        if hidden.contains(name) {
            hidden.remove(name)
        } else {
            guard all.filter({ !hidden.contains($0) }).count > 1 else { tv?.showToast("至少选择一项"); return }
            hidden.insert(name)
        }
        DedaoShelfSource.hiddenCategories = hidden
        shelfSettingsChanged()
    }

    /// 主屏顶部的几页（一共最多 AppShelf.limit 页）：
    /// - 继续学习：一页，最近一本没听完的书、课（最新那本听完了就往前找；都听完了就没有这一页）；
    /// - 新书推荐：剩下的几页，各个分类最新上架的书，听过、听了一半的不要，按分类错开、新的在前。
    /// 没登录就什么都不给（主屏只放得到的图标）
    func shelfItems() async -> (label: String, items: [AppShelfItem]) {
        guard DedaoCookies.signedIn else { return ("", []) }
        var cards: [AppShelfItem] = []
        // 听过的：最近学习（进过得到就用首页那一排；没进过就取两页）和书架，推荐新书时躲开它们
        var heard = loaded("home/recent")
        if heard.isEmpty {
            var who = user
            if who == nil { who = try? await DedaoAPI.user() }
            if let hazy = who?.hazy, let first = try? await DedaoAPI.recent(user: hazy) {
                heard = first.items
                if first.more, let second = try? await DedaoAPI.recent(user: hazy, after: first.cursor) { heard += second.items }
            }
            if heard.isEmpty { heard = (try? await recentFromShelves()) ?? [] }
        }
        // 正在听的书：这次还没听过东西时用这一页（播放器里有书时，主屏顶部用播放器的那一页，见 AppShelf.composed）
        if DedaoShelfSource.showsListening, let book = heard.first(where: { !$0.finished && $0.progress < 98 && $0.cover != nil }) {
            cards.append(Self.shelfCard(book, tag: "继续学习", resume: true))
        }
        if DedaoShelfSource.showsNewBooks {
            let room = DedaoShelfSource.newBookCount
            let lists = await newestByCategory(count: room)
            for pick in Self.pickNewBooks(lists, heard: Self.heardKeys(heard), count: room) {
                cards.append(Self.shelfCard(pick.book, tag: "新书 · \(pick.category)", resume: false))
            }
        }
        return ("", cards)
    }

    /// 推荐新书的分类：得到"全部分类"里的主题（职场发展、财富投资……自然科学、AI，得到新加的也算），
    /// 不要场景、书单那几项（晨间唤醒、高分必听……）。按左边栏的顺序排
    nonisolated static let notSubjects: Set<String> = ["高分必听", "大咖书单", "晨间唤醒", "通勤充电", "睡前放松", "运动伴侣", "亲子共读", "镇馆之宝"]

    nonisolated static func shelfCategories(_ topics: [DedaoAPI.Topic]) -> [DedaoAPI.Topic] {
        let subjects = topics.enumerated().filter { $0.element.kind == .subject && !notSubjects.contains($0.element.name) }
        return subjects.sorted { a, b in
            (preferredOrder.firstIndex(of: a.element.name) ?? preferredOrder.count + a.offset)
                < (preferredOrder.firstIndex(of: b.element.name) ?? preferredOrder.count + b.offset)
        }.map(\.element)
    }

    /// 勾着的那几个分类最新上架的书（几个分类一起取，都是不用登录的小请求）。勾得多就每天从不同的分类开始轮着取够用的几个；
    /// 勾得少，每个分类多取几本（后几轮从它们里面接着拿）
    private func newestByCategory(count: Int) async -> [(category: String, books: [DedaoAPI.Item])] {
        guard count > 0 else { return [] }
        var topics = DedaoAPI.savedTopics() ?? []
        if topics.isEmpty { topics = (try? await DedaoAPI.topics()) ?? [] }
        let hidden = DedaoShelfSource.hiddenCategories
        var subjects = Self.shelfCategories(topics).filter { !hidden.contains($0.name) }
        if subjects.isEmpty { subjects = Self.shelfCategories(topics) }
        guard !subjects.isEmpty else { return [] }
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        let start = day % subjects.count
        let chosen = Array((subjects[start...] + subjects[..<start]).prefix(min(subjects.count, count + 1)))
        let size = min(18, max(4, (count + chosen.count - 1) / chosen.count + 3))
        return await withTaskGroup(of: (Int, String, [DedaoAPI.Item]).self) { group in
            for (order, topic) in chosen.enumerated() {
                group.addTask {
                    let page = try? await DedaoAPI.products(topic: topic.id, name: topic.name, sort: .new, size: size)
                    return (order, topic.name, page?.items ?? [])
                }
            }
            var found: [(Int, String, [DedaoAPI.Item])] = []
            for await result in group { found.append(result) }
            return found.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
        }
    }

    /// 听过的书都记下哪些能认出它的：编号、音频编号、书名（最近学习和书单给的编号不一定是同一种，书名、音频编号兜底）
    nonisolated static func heardKeys(_ books: [DedaoAPI.Item]) -> Set<String> {
        var keys = Set<String>()
        for book in books {
            keys.insert("id:" + book.enid)
            if !book.alias.isEmpty { keys.insert("audio:" + book.alias) }
            let title = cleanTitle(book.title).title
            if !title.isEmpty { keys.insert("title:" + title) }
        }
        return keys
    }

    /// 从各个分类的新书里挑 count 本：听过的（在最近学习、书架里，或者书单自己说听了一部分、听完了）不要；
    /// 一轮从每个分类各拿最新的一本，这一轮按上架时间新的在前，再下一轮——所以不会一连几页都是同一个分类。
    /// 几个分类里都有的同一本书只放一次
    nonisolated static func pickNewBooks(_ lists: [(category: String, books: [DedaoAPI.Item])], heard: Set<String>,
                                         count: Int) -> [(category: String, book: DedaoAPI.Item)] {
        func listened(_ book: DedaoAPI.Item) -> Bool {
            book.progress > 0 || book.finished || heard.contains("id:" + book.enid)
                || (!book.alias.isEmpty && heard.contains("audio:" + book.alias))
                || heard.contains("title:" + cleanTitle(book.title).title)
        }
        var queues = lists.map { list in (category: list.category, books: list.books.filter { $0.cover != nil && !listened($0) }) }
        var picked: [(category: String, book: DedaoAPI.Item)] = []
        var seen = Set<String>()
        while picked.count < count, queues.contains(where: { !$0.books.isEmpty }) {
            var round: [(category: String, book: DedaoAPI.Item)] = []
            for index in queues.indices {
                while let book = queues[index].books.first {
                    queues[index].books.removeFirst()
                    if seen.insert(book.enid).inserted { round.append((queues[index].category, book)); break }
                }
            }
            round.sort { $0.book.published > $1.book.published }
            picked += round.prefix(count - picked.count)
        }
        return picked
    }

    /// 首页这一排已经取好的（没取过是空的）
    private func loaded(_ row: String) -> [DedaoAPI.Item] {
        content[Section.home.id]?.first { $0.id == row }?.items ?? []
    }

    /// 主屏顶部一页：竖封面、书名、解读人 · 多长（课程、名家讲书再写一个"课程""名家讲书"）、介绍、听到哪了。
    /// tag 是左上角那个（"继续学习""新书 · 自然科学"），resume 是按钮写"继续听"还是"播放"
    static func shelfCard(_ book: DedaoAPI.Item, tag: String, resume: Bool) -> AppShelfItem {
        let kind: String
        switch book.kind {
        case .course: kind = "课程"
        case .collection: kind = "名家讲书"
        default: kind = ""
        }
        let line = [book.author, book.duration > 0 ? minutes(book.duration) : "", kind].filter { !$0.isEmpty }.joined(separator: " · ")
        return AppShelfItem(id: (resume ? continuePrefix : "dd-new-") + book.enid, kind: .dedao(book, resume: resume),
                            title: cleanTitle(book.title).title, subtitle: line, detail: book.intro,
                            image: book.cover, thumbnail: book.cover, avatar: nil, tag: tag)
    }

    /// "继续学习"那一页的编号开头（播放器里有书时，这一页让给播放器的那一页）
    nonisolated static let continuePrefix = "dd-continue-"

    /// 正在听的那一页：书名（去掉"| 解读人"、前面的"（英文新书）"、外面的《》）、解读人 · 课程名（知道的话）· 多长。
    /// source：从哪门课、哪套名家讲书放的（知道的话）
    static func shelfNowItem(_ track: DedaoAPI.Track, paused: Bool, source: String? = nil) -> AppShelfItem {
        let (title, interpreter) = DedaoPlayerScreen.split(track.title)
        let subtitle = [interpreter ?? track.reader, source ?? (track.productType == 66 ? "课程" : ""),
                        track.duration > 0 ? minutes(track.duration) : ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        return AppShelfItem(id: "dd-now-\(track.id)", kind: .dedaoNow(track, paused: paused), title: cleanTitle(title).title,
                            subtitle: subtitle, detail: "", image: track.cover, thumbnail: track.cover, avatar: nil,
                            tag: paused ? "继续学习" : "正在播放")
    }

    /// 大标题用的书名："（英文新书）《繁杂工作》"→"繁杂工作"，前面括号里的那几个字另外做个小框（badge）；
    /// 整个名字都包在《》里的去掉书名号，书名号只在中间的（"带你读懂《荷马史诗》"）照留
    nonisolated static func cleanTitle(_ raw: String) -> (title: String, badge: String?) {
        var text = raw.trimmingCharacters(in: .whitespaces)
        var badge: String?
        let pairs: [Character: Character] = ["（": "）", "(": ")", "【": "】", "[": "]"]
        if let first = text.first, let close = pairs[first], let end = text.firstIndex(of: close) {
            let inside = text[text.index(after: text.startIndex)..<end].trimmingCharacters(in: .whitespaces)
            let rest = text[text.index(after: end)...].trimmingCharacters(in: .whitespaces)
            if !inside.isEmpty, inside.count <= 8, !rest.isEmpty { badge = inside; text = rest }
        }
        if text.hasPrefix("《"), text.hasSuffix("》"), text.count > 2, text.filter({ $0 == "《" }).count == 1 {
            text = String(text.dropFirst().dropLast())
        }
        return (text.isEmpty ? raw : text, badge)
    }

    /// "29 分钟""1 小时 5 分钟"
    nonisolated static func minutes(_ seconds: Double) -> String {
        let total = max(1, Int((seconds / 60).rounded()))
        return total >= 60 ? "\(total / 60) 小时" + (total % 60 > 0 ? " \(total % 60) 分钟" : "") : "\(total) 分钟"
    }

    /// 没听过的课、名家讲书写一共几讲、几本
    nonisolated static func countText(_ book: DedaoAPI.Item) -> String? {
        guard book.count > 0 else { return nil }
        switch book.kind {
        case .course: return "共 \(book.count) 讲"
        case .collection: return "共 \(book.count) 本"
        default: return nil
        }
    }

    /// 听到哪了："已听 40%""已听完"；没听过是 nil
    static func progressText(_ book: DedaoAPI.Item) -> String? {
        if book.finished || book.progress >= 100 { return "已听完" }
        return book.progress > 0 ? "已听 \(book.progress)%" : nil
    }

    /// 接下来的几讲（序号是在这一串里排第几）
    static func upcoming(_ queue: [DedaoAPI.Track], after index: Int, count: Int) -> [(number: Int, track: DedaoAPI.Track)] {
        guard count > 0, queue.indices.contains(index) else { return [] }
        return queue.indices.dropFirst(index + 1).prefix(count).map { ($0 + 1, queue[$0]) }
    }

    /// 主屏顶部按了"继续听""播放"：书直接放（接着上次听到的地方）、打开播放界面；课、名家讲书进它的一列，
    /// 从没听完的那一讲放。得到还在取账号（刚打开）时先记着，取好了再做
    func playFromShelf(_ book: DedaoAPI.Item) {
        guard phase == .ready || phase == .loading else { return }
        dismissMenu()
        if settingsOpen { settingsOpen = false }
        switch book.kind {
        case .book: play(book, from: nil)
        case .collection, .course:
            if accountLoading { pendingShelf = book; return }
            pages = []
            autoplay = book.id
            open(book, from: nil)
            if tracks[book.id] != nil { startAutoplay(book) }
        case .folder: break
        }
    }

    /// 主屏顶部正在听的书（停着的那个样子）按了"继续听"：打开播放界面，接着放
    func resumeFromShelf() {
        guard player.current != nil else { return }
        dismissMenu()
        if settingsOpen { settingsOpen = false }
        openPlayer()
        if player.paused { player.togglePause() }
    }

    // MARK: 主屏顶部"上次听到"

    /// 主屏顶部正在听的书那一页上"上次听到"的那几句：听到的地方那一段文稿（和播放界面的跟读同一个估算）。
    /// 播放器那本用播放器取好的文稿；"继续学习"那一本（这次还没放过）取一次记着。没有文稿、文稿不全听到了后面：nil（放介绍）
    func lastHeard(_ item: AppShelfItem) async -> String? {
        switch item.kind {
        case .dedaoNow(let track, _):
            let at = player.current?.id == track.id ? player.time : track.resumeAt
            let duration = player.current?.id == track.id && player.duration > 0 ? player.duration : track.duration
            if case .ready(let text) = reader.state, reader.trackID == track.id { return Self.quote(text, at: at, duration: duration) }
            guard let text = await quoteTranscript(for: track) else { return nil }
            return Self.quote(text, at: at, duration: duration)
        case .dedao(let book, _):
            // 课程不知道上次是哪一讲，只有书能找到文稿
            guard book.kind == .book, !book.alias.isEmpty, book.duration > 0 else { return nil }
            let track = DedaoAPI.track(["alias_id": book.alias, "duration": book.duration], title: book.title,
                                       productEnid: book.enid, productType: 13, itemEnid: book.enid, cover: book.cover)
            guard let text = await quoteTranscript(for: track) else { return nil }
            return Self.quote(text, at: book.duration * Double(book.progress) / 100, duration: book.duration)
        default:
            return nil
        }
    }

    /// 主屏顶部要过的文稿（最多记几篇；取不到不记，下次再取）
    private var quoteTranscripts: [String: DedaoAPI.Transcript] = [:]

    private func quoteTranscript(for track: DedaoAPI.Track) async -> DedaoAPI.Transcript? {
        if let known = quoteTranscripts[track.id] { return known }
        guard let text = try? await DedaoAPI.transcript(for: track, userName: user?.name) else { return nil }
        if quoteTranscripts.count > 6 { quoteTranscripts.removeAll() }
        quoteTranscripts[track.id] = text
        return text
    }

    /// 听到第 at 秒的那一段（是标题就从下一段起），太短就接上后面一段，够两三行就停。
    /// 文稿不全、听到的地方已经在文稿后面了：nil
    nonisolated static func quote(_ transcript: DedaoAPI.Transcript, at: Double, duration: Double) -> String? {
        guard !transcript.paragraphs.isEmpty else { return nil }
        if transcript.partial(duration: duration), at * DedaoAPI.Transcript.speechRate > Double(transcript.characters) { return nil }
        var index = transcript.paragraph(at: at, duration: duration)
        while transcript.paragraphs.indices.contains(index), transcript.paragraphs[index].kind == .header { index += 1 }
        var text = ""
        while transcript.paragraphs.indices.contains(index), text.count < 70 {
            text += (text.isEmpty ? "" : " ") + transcript.paragraphs[index].text
            index += 1
        }
        return text.isEmpty ? nil : text
    }

    /// 从主屏顶部进的课、名家讲书：列表取到了就放没听完的那一讲
    private var autoplay: String?

    private func startAutoplay(_ book: DedaoAPI.Item) {
        guard autoplay == book.id, let list = tracks[book.id], !list.isEmpty else { return }
        autoplay = nil
        let at = listFocus[book.id] ?? 0
        guard list.indices.contains(at), list[at].playable, tv?.dedaoOpen == true else { return }
        play(list, at: at, in: book)
    }

    /// 倍速写成"1×""1.25×""1.5×""2×"（整数不带小数点，其余去掉末尾的 0）
    static func speedText(_ value: Float) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + "×"
    }

    // MARK: 打开

    private func activate() {
        guard rows.indices.contains(row) else { return }
        let line = rows[row]
        guard line.items.indices.contains(column) else {
            if line.state == .failed { loadRow(line.id) }   // 这一排没取到：再取一次
            return
        }
        open(line.items[column], from: line.id)
    }

    /// row：从哪一排选的（一本书放完接着放这一排的下一本）
    private func open(_ item: DedaoAPI.Item, from row: String?) {
        switch item.kind {
        case .book: play(item, from: row)
        case .collection, .course:
            push(.tracks(item))
            loadTracks(item)
        case .folder:
            push(.folder(item))
            loadFolder(item)
        }
    }

    /// 选了一本书：要到它的音频就放，打开播放界面。要的途中离开了得到、又选了别的：这一本不放了
    private func play(_ item: DedaoAPI.Item, from row: String?) {
        if player.current?.productType == 13, player.current?.itemEnid == item.enid { openPlayer(); return }
        opening?.cancel()
        opening = Task { @MainActor in
            do {
                let track = try await Self.audio(of: item)
                guard !Task.isCancelled, tv?.dedaoOpen == true, phase == .ready else { return }
                guard track.playable else { tv?.showToast("无法播放这本书"); return }
                playingFrom = nil
                var more: (@MainActor () async throws -> [DedaoAPI.Track])?
                if let row {
                    more = { [weak self] in
                        guard let self else { return [] }
                        return try await self.nextBook(after: self.player.queue.last, in: row)
                    }
                }
                player.play([track], from: 0, more: more)
                listened = true
                openPlayer()
            } catch {
                guard !Task.isCancelled, !DedaoAPI.isCancellation(error) else { return }
                tv?.showToast((error as? DedaoError)?.message ?? DedaoError.offline.message)
            }
        }
    }

    /// 放一列里的第几讲（课的讲、名家讲书的书），打开播放界面。课程放到已经取到的最后一讲时，接着要后面的
    /// 正在放的是从哪门课、哪套名家讲书来的（主屏顶部写它的名字；单本书是 nil）
    private(set) var playingFrom: String?

    private func play(_ list: [DedaoAPI.Track], at: Int, in item: DedaoAPI.Item) {
        playingFrom = DedaoStore.cleanTitle(item.title).title
        var more: (@MainActor () async throws -> [DedaoAPI.Track])?
        if item.kind == .course {
            more = { [weak self] in
                guard let self else { return [] }
                return try await self.lectures(after: self.player.queue.last?.id, in: item)
            }
        }
        player.play(list, from: at, more: more)
        listened = true
        openPlayer()
    }

    /// 一本书的音频：书单里带着音频编号的直接要音频，少问一次
    private static func audio(of item: DedaoAPI.Item) async throws -> DedaoAPI.Track {
        if item.alias.isEmpty { return try await DedaoAPI.book(item.enid, cover: item.cover) }
        return try await DedaoAPI.bookAudio(alias: item.alias, itemEnid: item.enid, cover: item.cover)
    }

    /// 一本书放完了：这一排里它后面第一本放得了的书（名家讲书、课程跳过；没开会员放不了的跳过，最多试 4 本）。
    /// 网络断了抛错（播放器留着，下次再要）
    private func nextBook(after track: DedaoAPI.Track?, in rowID: String) async throws -> [DedaoAPI.Track] {
        guard let track, let line = content.values.lazy.compactMap({ $0.first { $0.id == rowID } }).first,
              let at = line.items.firstIndex(where: { $0.enid == track.itemEnid }) else { return [] }
        for item in line.items[(at + 1)...].filter({ $0.kind == .book }).prefix(4) {
            do {
                let next = try await Self.audio(of: item)
                if next.playable { return [next] }
            } catch DedaoError.failed {
                continue   // 这本没有音频：看下一本
            }
        }
        return []
    }

    private func push(_ page: Page) {
        withAnimation(Motion.navigate) { pages.append(page) }
    }

    private func reloadPage(_ page: Page) {
        switch page {
        case .tracks(let item): loadTracks(item)
        case .folder(let item): loadFolder(item)
        }
    }

    private func loadTracks(_ item: DedaoAPI.Item) {
        guard tracks[item.id] == nil, !loadingPages.contains(item.id) else { return }
        failedPages.remove(item.id)
        loadingPages.insert(item.id)
        let run = loadRun
        Task { @MainActor in
            defer { if run == loadRun { loadingPages.remove(item.id) } }
            do {
                if item.kind == .course {
                    async let info = try? DedaoAPI.course(item.enid)
                    async let first = DedaoAPI.lectures(item.enid, cover: item.cover)
                    let list = try await first
                    let course = await info
                    guard run == loadRun else { return }
                    if let course { courses[item.id] = course }
                    tracks[item.id] = list
                    // 一页满 30 讲就还有下一页（得到没说一共几讲时也是）
                    let total = course?.lectures ?? 0
                    if list.count >= DedaoAPI.lecturesPerPage, total == 0 || list.count < total { morePages.insert(item.id) }
                } else {
                    let list = try await DedaoAPI.collection(item.enid, cover: item.cover)
                    guard run == loadRun else { return }
                    tracks[item.id] = list
                }
                // 焦点先停在没听完的第一讲上
                let list = tracks[item.id] ?? []
                listFocus[item.id] = list.firstIndex { !$0.finished && $0.progress < 98 } ?? 0
                startAutoplay(item)   // 从主屏顶部进来的：直接放这一讲
            } catch {
                guard run == loadRun, !DedaoAPI.isCancellation(error) else { return }
                failedPages.insert(item.id)   // 这一页自己有"按确认再取"那一行
            }
        }
    }

    private func loadFolder(_ item: DedaoAPI.Item) {
        guard case .folder(let group) = item.kind, folders[item.id] == nil, !loadingPages.contains(item.id) else { return }
        failedPages.remove(item.id)
        loadingPages.insert(item.id)
        let run = loadRun
        Task { @MainActor in
            defer { if run == loadRun { loadingPages.remove(item.id) } }
            do {
                let list = try await DedaoAPI.shelf(item.shelf, group: group)
                guard run == loadRun else { return }
                folders[item.id] = list
            } catch {
                guard run == loadRun, !DedaoAPI.isCancellation(error) else { return }
                failedPages.insert(item.id)   // 不记成空的：按确认再取
            }
        }
    }

    /// 课程往下走到快底了：再要下一页（一次 30 讲）
    private func loadMoreIfNeeded(_ page: Page) {
        guard case .tracks(let item) = page, item.kind == .course, morePages.contains(item.id),
              let list = tracks[item.id], (listFocus[item.id] ?? 0) >= list.count - 6 else { return }
        Task { @MainActor in try? await loadNextLectures(item) }
    }

    /// 课程的下一页。正在取的就等它；取不到（网络）抛错，这门课还算有下一页，下次再取
    private func loadNextLectures(_ item: DedaoAPI.Item) async throws {
        if let running = lectureLoads[item.id] { return try await running.value }
        guard morePages.contains(item.id), let last = tracks[item.id]?.last else { return }
        let run = loadRun
        let task = Task { @MainActor [weak self] in
            let more = try await DedaoAPI.lectures(item.enid, after: last.articleID, cover: item.cover)
            guard let self, run == self.loadRun else { return }
            let list = self.tracks[item.id] ?? []
            let known = Set(list.map(\.id))
            let fresh = more.filter { !known.contains($0.id) }
            self.tracks[item.id] = list + fresh
            let total = self.courses[item.id]?.lectures ?? 0
            if fresh.isEmpty || more.count < DedaoAPI.lecturesPerPage || (total > 0 && list.count + fresh.count >= total) {
                self.morePages.remove(item.id)
            }
        }
        lectureLoads[item.id] = task
        loadingPages.insert(item.id)
        defer {
            if lectureLoads[item.id] == task { lectureLoads[item.id] = nil }
            if run == loadRun { loadingPages.remove(item.id) }
        }
        try await task.value
    }

    /// 播放器放到这门课已经交给它的最后一讲了：给它后面的讲（列表里已经有的直接给，没有就再取一页）
    private func lectures(after lastID: String?, in item: DedaoAPI.Item) async throws -> [DedaoAPI.Track] {
        func following() -> [DedaoAPI.Track] {
            let list = tracks[item.id] ?? []
            guard let lastID, let at = list.firstIndex(where: { $0.id == lastID }) else { return [] }
            return Array(list[(at + 1)...])
        }
        let known = following()
        if !known.isEmpty || !morePages.contains(item.id) { return known }
        try await loadNextLectures(item)
        return following()
    }

    func openPlayer() {
        guard player.current != nil else { return }
        dismissMenu()
        lecturesVisible = false
        withAnimation(Motion.navigate) { playerOpen = true }
    }

    private func closePlayer() {
        if player.scrubbing { endHold() }
        withAnimation(Motion.navigate) { playerOpen = false; lecturesVisible = false }
        refreshRecent()
    }

    // MARK: 焦点

    /// 现在这一项（左边栏选的）下面的几排
    var rows: [Row] { content[section] ?? [] }

    /// 焦点在第几排（按编号找；找不到是第一排）
    var row: Int {
        guard let id = focusedRows[section] else { return 0 }
        return rows.firstIndex { $0.id == id } ?? 0
    }

    var column: Int { rows.indices.contains(row) ? column(of: rows[row]) : 0 }

    /// 这一排选中的是第几个（内容变短时不会越界）
    func column(of row: Row) -> Int { max(0, min(columns[row.id] ?? 0, row.items.count - 1)) }

    /// 当前这一排选中的那一样，焦点暂时去了左边栏、右上角也算（上面的介绍和背景用它，免得一开栏就换）
    var highlighted: DedaoAPI.Item? {
        guard rows.indices.contains(row) else { return nil }
        let line = rows[row]
        return line.items.indices.contains(column(of: line)) ? line.items[column(of: line)] : nil
    }

    private func setRow(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        withAnimation(Motion.navigate) { focusedRows[section] = rows[index].id }
        loadNearbyRows()
    }

    private func setColumn(_ value: Int) {
        guard rows.indices.contains(row) else { return }
        let line = rows[row]
        let clamped = max(0, min(line.items.count - 1, value))
        guard clamped != column else { return }
        withAnimation(stepMotion()) { columns[line.id] = clamped }
        // 往后几张的封面先下好：甩着翻会一下走好几张，不然翻过去是一排空的灰块
        for item in line.items.dropFirst(clamped + 1).prefix(10) {
            if let url = item.cover, BiliImageCache.shared.image(for: url) == nil {
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

    private func setList(_ id: String, _ index: Int) {
        withAnimation(Motion.focus) { listFocus[id] = index }
    }

    func listCount(_ page: Page) -> Int {
        switch page {
        case .tracks(let item): tracks[item.id]?.count ?? 0
        case .folder(let item): folders[item.id]?.count ?? 0
        }
    }

    /// 触控板、鼠标点到某一张卡片
    func focusCard(row: Int, column: Int) {
        guard rows.indices.contains(row) else { return }
        dismissMenu()
        withAnimation(Motion.focus) {
            focus = .rows
            focusedRows[section] = rows[row].id
            columns[rows[row].id] = column
        }
        loadNearbyRows()
    }

    func focusListItem(_ index: Int) {
        guard let page = currentPage else { return }
        setList(page.item.id, index)
    }

    // MARK: 交互规则（见 TVController.Module）

    func module(horizontal: Bool) -> TVController.Module {
        guard phase == .ready else { return .picker }
        if menu != nil { return .picker }                           // 菜单：固定的几项（播放界面的"⋯"也是）
        if playerOpen {
            // 同网易云的正在播放：左右拖进度（进度跟着手走）；上下拉出讲目列表（往上滑）。
            // 讲目列表开着：左右是长条，往下滑推回去
            if lecturesVisible { return horizontal ? .strip : .drawer }
            return horizontal ? .scrub : .drawer
        }
        if settingsOpen { return horizontal ? .off : .picker }      // 设置：固定的几行
        if currentPage != nil { return horizontal ? .picker : .strip }
        switch focus {
        // 左边栏是从左边拉出来的抽屉：往右滑拉出来，往左滑推回去；在里面上下是挑一项（同哔哩哔哩）
        case .sidebar: return horizontal ? .drawer : .picker
        // 右上角：上下跟着下面那几排走（往下滑上来、往上滑回去）；正在播放和账号两个时，左右是挑一个，
        // 只有账号时左右和哔哩哔哩的头像一样（往右滑拉出左边栏）
        case .top: return horizontal && topItems.count > 1 ? .picker : .drawer
        case .rows: return horizontal ? .strip : .drawer
        }
    }

    /// 转盘、双指一甩接着走的时候，朝这边还有没有下一个：只在焦点所在的这一排 / 这一列里走，到头就停
    ///（不会从第一张转进左边栏、从右上角转回下面）
    func canMove(_ direction: RemoteCommand.Direction) -> Bool {
        switch phase {
        case .ready: break
        case .failed:
            guard canRescan else { return false }
            return direction == .left ? failureChoice > 0 : direction == .right ? failureChoice < 1 : false
        default: return false
        }
        if let menu {
            switch direction {
            case .up: return menu.index > 0
            case .down: return menu.index + 1 < menu.items.count
            default: return false
            }
        }
        if playerOpen {
            // 讲目列表里左右走，到头就停（转盘在播放界面是快进快退，不走这里）
            guard lecturesVisible else { return false }
            switch direction {
            case .left: return lectureFocus > 0
            case .right: return lectureFocus + 1 < player.queue.count
            default: return false
            }
        }
        if settingsOpen {
            switch direction {
            case .up: return settingIndex > 0
            case .down: return settingIndex + 1 < Setting.allCases.count
            default: return false
            }
        }
        if let page = currentPage {
            let at = listFocus[page.item.id] ?? 0
            switch direction {
            case .up: return at > 0
            case .down: return at + 1 < listCount(page)
            default: return false
            }
        }
        switch focus {
        case .sidebar: return true   // 一列固定的选项，到头自己停
        case .top(let item):
            let index = topItems.firstIndex(of: item) ?? 0
            switch direction {
            case .left: return index > 0
            case .right: return index + 1 < topItems.count
            default: return false
            }
        case .rows:
            guard rows.indices.contains(row) else { return false }
            switch direction {
            case .left: return column > 0
            case .right: return column < rows[row].items.count - 1
            default: return false
            }
        }
    }

    /// 转盘沿哪个方向走：一排排卡片、右上角、播放界面是横的；左边栏、菜单、设置、列表是竖的
    var wheelRunsHorizontally: Bool {
        guard phase == .ready else { return true }
        if menu != nil { return false }                // 菜单是竖的（播放界面的"⋯"也是）
        if playerOpen { return true }                  // 播放界面：快进快退；讲目列表是横的
        if settingsOpen || currentPage != nil { return false }
        switch focus {
        case .sidebar: return false
        case .top: return topItems.count > 1
        case .rows: return true
        }
    }
}

extension TVController {
    func openDedao() {
        if mode != .launcher { goHome() }
        dedaoStore.tv = self
        sheets.closeDismissible()
        movies = nil
        dedaoOpen = true
        dedaoStore.opened()
    }

    /// 退出得到（App Switcher，见 AppQuit；回主屏是 backgrounded）：页面收起来，正在放的停下（报一下听到哪了）
    func closeDedao() {
        guard dedaoOpen else { return }
        dedaoStore.closed()
        dedaoOpen = false
    }
}

// MARK: - 手机遥控器上的快捷键（见 RemoteShortcuts）：和播放界面、"⋯"菜单里的是同一些动作

extension DedaoStore {
    /// 登录了、有一讲在放（或停着）：快捷键能用
    var remoteReady: Bool { phase == .ready && player.current != nil }

    /// 换下一档倍速（0.75× 到 2×，到头回到最慢；换成了几倍，手机上的按钮写着）。开着的"⋯"菜单里写的是旧的，先收起
    @discardableResult
    func nextSpeed() -> Bool {
        guard remoteReady else { return false }
        let speeds = DedaoPlayer.speeds
        let next = speeds[((speeds.firstIndex(of: player.speed) ?? 0) + 1) % speeds.count]
        if menu?.anchor == .nowPlaying { dismissMenu() }
        player.setSpeed(next)
        return true
    }

    /// 文稿在播放界面右边：播放界面没开就打开，开着就收起（同返回）
    @discardableResult
    func togglePlayerFromRemote() -> Bool {
        guard remoteReady else { return false }
        if playerOpen {
            dismissMenu()
            closePlayer()
        } else {
            openPlayer()
        }
        return true
    }

    /// 定时关闭：打开播放界面（没开的话）和"⋯"菜单里"定时关闭"那一层，停在现在选的那一项上；返回回到"⋯"菜单
    @discardableResult
    func openSleepMenu() -> Bool {
        guard remoteReady else { return false }
        if player.scrubbing { endHold() }
        if playerOpen { dismissMenu(); dismissLectures() } else { openPlayer() }
        guard openPlayerMenu() else { return false }
        run(.sleepMenu)
        return true
    }

    /// "定时关闭"那一层开着：再按一次定时关闭，整个"⋯"菜单收起（规矩见 TVController.toggle），播放界面留着
    func closeSleepMenu() -> Bool {
        guard menu?.items.contains(where: { if case .sleep = $0.action { true } else { false } }) == true else { return false }
        return closePlayerMenu()
    }

    /// 按住确认弹出的"⋯"菜单（连同倍速、定时关闭那一层）开着
    var holdMenuOpen: Bool { menu?.anchor == .nowPlaying }

    /// 再按住确认：整个收起（同返回到底、同点"⋯"）
    func closePlayerMenu() -> Bool {
        guard holdMenuOpen else { return false }
        dismissMenu()
        return true
    }

    /// 定时关闭还剩多久："15 分钟"、"本讲结束"；没开是 nil
    func sleepLeft(at now: Date = Date()) -> String? {
        guard let timer = player.sleep else { return nil }
        guard let left = timer.remaining(at: now) else { return "本讲结束" }
        return "\(max(1, Int((left / 60).rounded(.up)))) 分钟"
    }

    /// 上一讲 / 下一讲有没有（跳过放不了的；下一讲还可能是没取到的）
    func canStepLecture(_ delta: Int) -> Bool { remoteReady && (delta > 0 ? player.hasNext : player.hasPrevious) }

    /// 上一讲 / 下一讲（同播放界面里按左右）
    @discardableResult
    func stepLecture(_ delta: Int) -> Bool {
        guard canStepLecture(delta) else { return false }
        if player.scrubbing { endHold() }
        player.step(delta)
        return true
    }
}

// MARK: 每个人（个人资料）各一份（见 ProfileApp）

extension DedaoStore: ProfileApp {
    /// 新的人从这些设置开始（和第一次打开得到一样）
    static var registeredDefaults: [String: Any] { ["dedaoSpeed": Float(1), "dedaoAutoNext": true] }

    /// 要换人了：在听的是这个人的书，停下；听到哪了用他自己的登录信息报给得到（见 DedaoPlayer.report）
    func profileWillChange() {
        closed()
        player.stop()
    }

    /// 换了人：登录、设置、内容全换成这个人的。像退出登录一样从头来，但什么都不删（上一个人的都还在他自己那里）
    func profileChanged() {
        DedaoAPI.useProfile(.current)
        signInRun += 1
        loadRun += 1
        polling?.cancel()
        polling = nil
        loadedAt = .distantPast
        opening?.cancel()
        opening = nil
        accountLoading = false
        pendingShelf = nil
        listened = false
        user = nil
        loginCode = nil
        loginExpired = false
        failureChoice = 0
        content = [:]
        focusedRows = [:]
        columns = [:]
        sections = [.home]
        allSections = [.home]
        section = Section.home.id
        sidebarSection = section
        focus = .rows
        menu = nil
        menuParents = []
        settingsOpen = false
        pages = []
        tracks = [:]
        folders = [:]
        courses = [:]
        listFocus = [:]
        loadingPages = []
        failedPages = []
        morePages = []
        lectureLoads = [:]
        playerOpen = false
        lecturesVisible = false
        playingFrom = nil
        player.profileReset()
        reader.reset()
        phase = .loading
    }
}
