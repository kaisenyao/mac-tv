import Combine
import SwiftUI

/// 哔哩哔哩、网易云、YouTube、得到在主屏顶部的内容：选中它们的图标时，顶部一张一张轮播（像 Apple TV 的大图轮播）。
/// 得到（DedaoShelfSource）是听书：后台在听时最前面一页"正在播放"（"打开播放器"），一页继续学习（"继续听"），
/// 其余是各个分类新上架、还没听过的书（"播放"）；没登录就不放。
/// 往上滑进来以后只有一个按钮：视频是"播放"（直播是"观看直播"），歌单是"播放"（进这个歌单从第一首放），
/// 网易云"正在播放"那一页是"打开网易云"（只显示，不控制）；左右是换上一个 / 下一个，底下的小点是第几个（点得了）。
///
/// 放什么在各自的设置里选：哔哩哔哩选一种（BiliShelfSource，默认关注的 UP 主最新的视频），
/// 网易云可以选好几种（NeteaseShelfSource，每一种是一个或几个歌单，默认每日推荐、我喜欢的音乐、推荐歌单；
/// 后台放歌时最前面还有一页"正在播放"），YouTube 在 设置 › Apps › Top Shelf 里选。
/// 内容来自这三个应用各自登录的账号，只在这台 Mac 上用
struct AppShelfItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case video(BiliVideo)
        /// YouTube 的一个视频（按"播放"在 YouTube 电视版里放）
        case youtube(String)
        /// 网易云的一个歌单（每日推荐、我喜欢的音乐、推荐的歌单、排行榜……）和它前面几首歌
        case collection(NeteasePlaylist, songs: [NeteaseSong])
        /// 网易云正在后台放的这首歌（只显示，不控制）：在放的时候轮播停在这一页
        case nowPlaying(NeteaseSong, paused: Bool)
        /// 得到正在后台放（或停着）的这一讲 / 这本书（只显示，不控制）：在放的时候轮播停在这一页
        case dedaoNow(DedaoAPI.Track, paused: Bool)
        /// 得到的一本书、一门课、一套名家讲书（最近学习、新书、热门……）。resume：最近学习里的，按钮是"继续听"
        case dedao(DedaoAPI.Item, resume: Bool)
    }

    let id: String
    let kind: Kind
    let title: String
    /// UP 主 / 主播；歌单是"多少首"、谁建的
    let subtitle: String
    /// "3 小时前 · 12.3万播放 · 12:34"
    let detail: String
    /// 大图：视频封面铺满整屏；专辑、歌单的封面放在右边
    let image: URL?
    /// 背景（模糊开的颜色）用的小图
    let thumbnail: URL?
    let avatar: URL?
    /// 左上角的标签（网易云每一个都写它是哪一种："每日推荐""推荐歌单"）；nil 用这个应用统一的那个
    var tag: String? = nil

    /// 专辑、歌单是方的封面；视频、直播是 16:9 的封面
    var square: Bool {
        switch kind {
        case .collection, .nowPlaying: true
        case .video, .youtube, .dedaoNow, .dedao: false
        }
    }
}

/// 哔哩哔哩的主屏顶部放什么
enum BiliShelfSource: String, CaseIterable {
    case following, recommended, popular, live
    var title: String {
        switch self {
        case .following: "动态"
        case .recommended: "推荐"
        case .popular: "热门"
        case .live: "直播"
        }
    }
    /// 每个人（个人资料）各选各的（见 ProfileSpace）
    static var current: BiliShelfSource {
        get { ProfileSpace.current.defaults.string(forKey: "bilibiliShelf").flatMap(BiliShelfSource.init) ?? .following }
        set { ProfileSpace.current.defaults.set(newValue.rawValue, forKey: "bilibiliShelf") }
    }
}

/// 网易云的主屏顶部放什么（可以选好几种，按这里的顺序轮播）
enum NeteaseShelfSource: String, CaseIterable {
    case daily, liked, recent, dailyLists, playlists, hot
    var title: String {
        switch self {
        case .daily: "每日推荐"
        case .liked: "我喜欢的音乐"
        case .recent: "最近播放"
        case .dailyLists: "每日歌单"
        case .playlists: "推荐歌单"
        case .hot: "热歌榜"
        }
    }
    static let defaults: [NeteaseShelfSource] = [.daily, .liked, .dailyLists, .playlists]

    /// 每日歌单、推荐歌单是一种摆好几个歌单的；别的一种一个
    var isListGroup: Bool { self == .dailyLists || self == .playlists }

    /// 每日歌单、推荐歌单各摆几个：主屏一次最多 AppShelf.limit 个，先给一种一个的那几种留位置，
    /// 剩下的这两种平分，一种最多 4 个（勾得越多，每种越少，全勾也都放得下）
    static func listsPerGroup(_ sources: [NeteaseShelfSource]) -> Int {
        let groups = sources.filter(\.isListGroup).count
        guard groups > 0 else { return 0 }
        return min(4, max(1, (AppShelf.limit - (sources.count - groups)) / groups))
    }

    /// 以前"推荐歌单"里前两个是每日歌单；拆成两种以后，勾过推荐歌单的把每日歌单也勾上，主屏看到的和以前一样（只做一次）
    /// 每个人（个人资料）各选各的（见 ProfileSpace）
    private static var store: UserDefaults { ProfileSpace.current.defaults }

    static func migrateSplitLists() {
        let store = store, key = "neteaseShelfSplitLists"
        guard !store.bool(forKey: key) else { return }
        store.set(true, forKey: key)
        let saved = store.stringArray(forKey: "neteaseShelfSources") ?? []
        if saved.contains(Self.playlists.rawValue), !saved.contains(Self.dailyLists.rawValue) {
            selected = Self.selected + [.dailyLists]
        }
    }
    static var selected: [NeteaseShelfSource] {
        get {
            let saved = (store.stringArray(forKey: "neteaseShelfSources") ?? []).compactMap(NeteaseShelfSource.init)
            return saved.isEmpty ? defaults : allCases.filter(saved.contains)
        }
        set { store.set(newValue.map(\.rawValue), forKey: "neteaseShelfSources") }
    }
    /// 后台放歌时，顶部最前面加一页"正在播放"（默认开着）
    static let nowPlayingKey = "nowPlaying"
    static var showsNowPlaying: Bool {
        get { store.object(forKey: "neteaseShelfNowPlaying") as? Bool ?? true }
        set { store.set(newValue, forKey: "neteaseShelfNowPlaying") }
    }
    /// 设置那一行右边写的："每日推荐"、"正在播放、每日推荐"、"正在播放等 4 项"
    static var summary: String {
        ListSummary.chinese((showsNowPlaying ? ["正在播放"] : []) + selected.map(\.title), none: "关闭")
    }
}

/// 得到的主屏顶部放什么：
/// - 正在听的书：一页，就是正在听的那本书。放着时是"正在播放"（进度、接下来的几讲、"打开播放器"）；
///   暂停、停了，同一页变成"继续学习"（"继续听"）；这次还没听过东西时，是最近学习里最新一本没听完的；
/// - 新书推荐：6 页，勾着的那几个分类最新上架、还没听过的书（分类在设置里"新书推荐"往里一层挑）
enum DedaoShelfSource {
    /// 新书推荐放几本（加上正在听的书一页，不超过 AppShelf.limit）
    static let newBookCount = 6

    /// 每个人（个人资料）各选各的（见 ProfileSpace）
    private static var store: UserDefaults { ProfileSpace.current.defaults }

    /// 以前的两个开关（正在播放、继续学习）有一个开着，就算开着
    static var showsListening: Bool {
        get {
            if let saved = store.object(forKey: "dedaoShelfListening") as? Bool { return saved }
            let nowPlaying = store.object(forKey: "dedaoShelfNowPlaying") as? Bool ?? true
            return nowPlaying || oldSources.map { $0.contains("continue") } ?? true
        }
        set { store.set(newValue, forKey: "dedaoShelfListening") }
    }

    static var showsNewBooks: Bool {
        get {
            if let saved = store.object(forKey: "dedaoShelfNewBooks") as? Bool { return saved }
            return oldSources.map { $0.contains("newBooks") } ?? true
        }
        set { store.set(newValue, forKey: "dedaoShelfNewBooks") }
    }

    /// 以前存的几种（只认得出"继续学习""新书推荐"；更早的最近学习、热门……认不出，当作没存过）
    private static var oldSources: [String]? {
        let saved = (store.stringArray(forKey: "dedaoShelfSources") ?? []).filter { $0 == "continue" || $0 == "newBooks" }
        return saved.isEmpty ? nil : saved
    }

    /// 新书推荐里勾掉的分类（按名字记：得到新加的分类默认是勾着的）
    static var hiddenCategories: Set<String> {
        get { Set(store.stringArray(forKey: "dedaoShelfHiddenCategories") ?? []) }
        set { store.set(Array(newValue).sorted(), forKey: "dedaoShelfHiddenCategories") }
    }

    /// 设置那一行右边写的："正在播放、新书推荐"、"新书推荐"
    static var summary: String {
        ListSummary.chinese((showsListening ? ["正在播放"] : []) + (showsNewBooks ? ["新书推荐"] : []), none: "关闭")
    }

    /// 新书推荐那一行右边写的："全部分类""5 个分类"
    static func categorySummary(_ all: [String]) -> String {
        let shown = all.filter { !hiddenCategories.contains($0) }.count
        return shown >= all.count ? "全部分类" : "\(shown) 个分类"
    }
}

@MainActor
final class AppShelf: ObservableObject {
    static let services: Set<String> = [BilibiliStore.appID, "netease", "youtube", DedaoStore.appID]
    /// 每个应用一次轮播几个
    nonisolated static let limit = 8

    /// 每个应用的内容，和它是按哪一项取的（显示在左上角的标签里："关注更新""每日推荐"……）
    @Published private(set) var items: [String: [AppShelfItem]] = [:]
    @Published private(set) var labels: [String: String] = [:]
    @Published private(set) var index: [String: Int] = [:]
    /// 上一次往哪边翻（1 下一个，-1 上一个）：换页时内容往这边滑走、新的从另一边滑进来
    @Published private(set) var direction = 1
    /// 翻了几次页：按键当下就变（真正换页在下一帧），按键音、震动看它，连着翻好几下也一下不少
    private(set) var turns = 0
    /// 已经定下、还没画出来的那一页（连着翻时下一下从这里接着算）
    private var target: [String: Int] = [:]
    /// 每个应用最近一次去取内容的编号：回来晚了的旧结果不盖掉新的
    private var generation: [String: Int] = [:]
    /// 换页的动画：自动轮播和手动翻是同一条，内容、背景颜色一起走
    static let pageAnimation = Animation.spring(response: 0.55, dampingFraction: 0.9)

    /// 影片那一格顶部换海报的节拍（每 8 秒一下，选中影片时才走）
    @Published private(set) var beat = 0
    /// 这一张是什么时候换上来的（大图慢慢移动从这时算起）
    private(set) var beatStarted = Date()

    private weak var tv: TVController?
    private var clock: Timer?
    private var refreshedAt: [String: Date] = [:]
    private var refreshing: Set<String> = []
    /// 各应用取来的那几页（网易云前面还会加一页"正在播放"，见 composed）
    private var fetched: [String: [AppShelfItem]] = [:]
    /// 网易云在后台放的这首歌那一页；没在放是 nil
    private var nowPlaying: AppShelfItem?
    private var nowPlayingWatch: AnyCancellable?
    /// 得到在后台放（或停着）的那一讲那一页
    private var dedaoNow: AppShelfItem?
    private var dedaoWatch: AnyCancellable?

    init(tv: TVController) { self.tv = tv }

    func start() {
        guard clock == nil else { return }
        refresh(BilibiliStore.appID)
        refresh("netease")
        refresh("youtube")
        refresh(DedaoStore.appID)
        // 每 8 秒换下一个（和别的应用的顶部同样的节奏）；往上滑进来、正在挑按钮时不换
        clock = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // 得到开始放、换了一讲、暂停 / 接着放：重排它的"正在播放"那一页
        if let player = tv?.dedaoStore.player {
            dedaoWatch = Publishers.CombineLatest3(player.$queue, player.$index, player.$paused)
                .map { queue, index, paused in (queue.indices.contains(index) ? queue[index] : nil, paused) }
                .removeDuplicates { $0.0?.id == $1.0?.id && $0.1 == $1.1 }
                .receive(on: DispatchQueue.main)
                .sink { [weak self] track, paused in
                    MainActor.assumeIsolated { self?.showDedaoNow(track, paused: paused) }
                }
        }
        // 网易云开始放、换了一首、暂停 / 接着放：重排"正在播放"那一页
        guard let store = tv?.neteaseStore else { return }
        nowPlayingWatch = store.$current.combineLatest(store.$paused)
            .removeDuplicates { $0.0?.id == $1.0?.id && $0.1 == $1.1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] song, paused in
                MainActor.assumeIsolated { self?.showNowPlaying(song, paused: paused) }
            }
    }

    private func tick() {
        // 只在看得见主屏的时候走：别的应用、浏览器、影片、弹出的面板、屏保、显示器睡着、窗口整个被挡住时都不翻也不取
        guard let tv, tv.mode == .launcher, !tv.bilibiliOpen, !tv.neteaseOpen, !tv.dedaoOpen, !tv.browserOpen,
              tv.movies == nil, tv.activeSheet == nil, !tv.screensaver, !tv.displaysSleeping,
              tv.window?.occlusionState.contains(.visible) == true else { return }
        if case .movies = tv.shelfService.kind {
            beatStarted = Date()
            withAnimation(.easeInOut(duration: 1.4)) { beat += 1 }
        }
        if case .shelf = tv.focus { return }
        let id = tv.shelfService.id
        // 内容放久了（二十分钟）就悄悄换新的
        if Date().timeIntervalSince(refreshedAt[id] ?? .distantPast) > 1200 { refresh(id) }
        // 网易云在放歌：停在"正在播放"不自动翻（暂停了照常翻；左右键手动翻不受影响）
        if id == NeteaseStore.appID, case .nowPlaying(_, paused: false)? = nowPlaying?.kind { return }
        if id == DedaoStore.appID, case .dedaoNow(_, paused: false)? = dedaoNow?.kind { return }   // 得到也一样
        guard let list = items[id], list.count > 1 else { return }
        turn(id, by: 1, count: list.count)
    }

    func current(for id: String) -> AppShelfItem? {
        guard let list = items[id], !list.isEmpty else { return nil }
        return list[min(index[id] ?? 0, list.count - 1)]
    }

    /// 换上一个 / 下一个（在按钮的两头再往左 / 往右）
    func step(_ id: String, by delta: Int) {
        guard let list = items[id], list.count > 1 else { return }
        turn(id, by: delta, count: list.count)
    }

    /// 点了下面的第几个小点：直接跳到那一页（往后的从右边滑进来，往前的从左边）
    func jump(_ id: String, to target: Int) {
        guard let list = items[id], list.indices.contains(target) else { return }
        let from = index[id] ?? 0
        guard target != from else { return }
        turn(id, by: target - from, count: list.count)
    }

    /// 这个应用顶部的几页：取来的那些；网易云在后台放歌时，最前面再加一页"正在播放"
    private func composed(_ id: String) -> [AppShelfItem] {
        let pages = fetched[id] ?? []
        // 得到：正在听的书只有一页——播放器里有书时用它（放着、停着两个样子），没有时才用取来的"继续学习"那一页
        if id == DedaoStore.appID, let dedaoNow { return [dedaoNow] + pages.filter { !$0.id.hasPrefix(DedaoStore.continuePrefix) } }
        guard id == NeteaseStore.appID, let nowPlaying else { return pages }
        return [nowPlaying] + pages
    }

    /// 网易云设置里开关了"正在播放"
    func nowPlayingSettingChanged() {
        guard let store = tv?.neteaseStore else { return }
        showNowPlaying(store.current, paused: store.paused)
    }

    /// 得到设置里开关了"正在听的书"
    func dedaoNowSettingChanged() {
        guard let player = tv?.dedaoStore.player else { return }
        showDedaoNow(player.current, paused: player.paused)
    }

    /// 得到正在听（或者停着）的这一讲：做成第一页（设置里关了、没登录就不加）。开始放、换了一讲、从暂停接着放时，轮播回到这一页
    private func showDedaoNow(_ track: DedaoAPI.Track?, paused: Bool) {
        let id = DedaoStore.appID
        let before = dedaoNow
        dedaoNow = (DedaoShelfSource.showsListening && DedaoCookies.signedIn ? track : nil).map { track in
            DedaoStore.shelfNowItem(track, paused: paused, source: tv?.dedaoStore.playingFrom)
        }
        place(id, started: {
            guard case .dedaoNow(let now, paused: false)? = dedaoNow?.kind else { return false }
            guard case .dedaoNow(let old, let wasPaused)? = before?.kind else { return true }
            return old.id != now.id || wasPaused
        }())
    }

    /// 网易云正在放（或者停着）的这首歌：做成第一页（设置里关了就不加）。开始放、换了一首、从暂停接着放时，轮播回到这一页
    private func showNowPlaying(_ song: NeteaseSong?, paused: Bool) {
        let id = NeteaseStore.appID
        let before = nowPlaying
        nowPlaying = (NeteaseShelfSource.showsNowPlaying ? song : nil).map { song in
            AppShelfItem(id: "ne-now-\(song.id)", kind: .nowPlaying(song, paused: paused), title: song.name,
                         subtitle: [song.artist, song.albumName].filter { !$0.isEmpty }.joined(separator: " · "), detail: "",
                         image: NeteaseStore.large(song.cover), thumbnail: song.cover, avatar: nil, tag: paused ? "已暂停" : "正在播放")
        }
        place(id, started: {
            guard case .nowPlaying(let now, paused: false)? = nowPlaying?.kind else { return false }
            guard case .nowPlaying(let old, let wasPaused)? = before?.kind else { return true }
            return old.id != now.id || wasPaused
        }())
    }

    /// "正在播放"那一页变了：重排这个应用的几页。刚开始放（started）就回到这一页，
    /// 不过正在顶部这一栏里看别的页时不把人拽走（"正在播放"照样加在最前面）
    private func place(_ id: String, started: Bool) {
        let keep = current(for: id)?.id
        let pages = composed(id)
        let browsing: Bool = { if case .shelf = tv?.focus, tv?.shelfService.id == id { true } else { false } }()
        target[id] = nil
        withAnimation(Self.pageAnimation) {
            items[id] = pages
            if started, !browsing { direction = -1; index[id] = 0 }
            else { index[id] = keep.flatMap { old in pages.firstIndex { $0.id == old } } ?? min(index[id] ?? 0, max(0, pages.count - 1)) }
        }
    }

    /// 先定方向、画一帧（要滑走的那一页按新方向滑），下一帧再换页。要去的那一页当下就记下，
    /// 连着翻好几下（转盘一下转三格）每一下都从上一下要去的地方接着算
    private func turn(_ id: String, by delta: Int, count: Int) {
        let base = target[id] ?? index[id] ?? 0
        let next = ((base + delta) % count + count) % count
        target[id] = next
        direction = delta >= 0 ? 1 : -1
        turns += 1
        afterThisFrame {
            guard let pages = self.items[id], !pages.isEmpty else { return }
            withAnimation(Self.pageAnimation) { self.index[id] = min(next, pages.count - 1) }
            if self.target[id] == next { self.target[id] = nil }
        }
    }
    /// 换页的第二步什么时候做（平时是下一个 main actor 任务；测试里自己挑时候）
    var afterThisFrame: (@escaping @MainActor () -> Void) -> Void = { work in Task { @MainActor in work() } }

    /// 测试用：这个应用顶部直接是这几页（不去网上取）
    func show(_ id: String, pages: [AppShelfItem], label: String = "") {
        fetched[id] = pages
        items[id] = composed(id)
        labels[id] = label
        index[id] = 0
        target[id] = nil
    }

    /// 换了一个人（个人资料）、退出了登录：这个应用（nil 是全部）顶部的东西清掉，按现在的账号重新取
    func reset(_ id: String? = nil) {
        let ids = id.map { [$0] } ?? Array(Self.services)
        for id in ids {
            fetched[id] = nil
            items[id] = composed(id)
            index[id] = 0
            target[id] = nil
            labels[id] = nil
            refreshedAt[id] = nil
            refresh(id, force: true)
        }
    }

    /// 设置里换了放什么：马上按新的取一遍
    func sourceChanged(_ id: String) {
        pendingSource[id]?.cancel()
        refreshedAt[id] = nil
        refresh(id, force: true)
    }

    /// 同上，但等手停下来（0.7 秒没再换）才取：连着换好几下只取最后那一次
    func sourceChangedSoon(_ id: String) {
        pendingSource[id]?.cancel()
        pendingSource[id] = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self.sourceChanged(id)
        }
    }
    private var pendingSource: [String: Task<Void, Never>] = [:]

    func refresh(_ id: String, force: Bool = false) {
        guard let tv, !refreshing.contains(id) || force else { return }
        refreshing.insert(id)
        let ticket = (generation[id] ?? 0) + 1
        generation[id] = ticket
        Task { @MainActor in
            let result: (label: String, items: [AppShelfItem])
            switch id {
            case BilibiliStore.appID: result = await tv.bilibiliStore.shelfItems(BiliShelfSource.current)
            case "youtube": result = await tv.youtubeShelfItems()
            case DedaoStore.appID: result = await tv.dedaoStore.shelfItems()
            default: result = await tv.neteaseStore.shelfItems(NeteaseShelfSource.selected)
            }
            // 之后又有人要过（换了放什么、刷新了）：这份旧了，等新的那一份
            guard generation[id] == ticket else { return }
            refreshing.remove(id)
            // 取不到（网断了、还没登录）：留着原来的，两分钟后再试（不是每 8 秒一次）
            guard !result.items.isEmpty else {
                refreshedAt[id] = Date().addingTimeInterval(-1200 + 120)
                return
            }
            let keep = current(for: id)?.id
            fetched[id] = Array(result.items.prefix(Self.limit))
            target[id] = nil
            items[id] = composed(id)
            labels[id] = result.label
            index[id] = keep.flatMap { old in items[id]?.firstIndex { $0.id == old } } ?? 0
            refreshedAt[id] = Date()
            // 大图先下好：轮到它时直接就有
            // 背景颜色从小图里取：也先下好，换页时颜色和内容一起变，不会晚一拍再闪一下
            for item in items[id] ?? [] {
                for url in [item.image, item.thumbnail].compactMap({ $0 }) where BiliImageCache.shared.image(for: url) == nil {
                    _ = await BiliImageCache.shared.load(url)
                }
            }
        }
    }

    // MARK: 按钮

    /// 往上滑进来以后只有一个按钮（所以左右就是换上一个 / 下一个）
    enum Action: Hashable {
        case play, watchLive, openPlayer
        /// YouTube 的"Play"（YouTube 不是中文应用，按钮和系统一样用英文）
        case watch
        /// 得到：最近学习里的"继续听"，正在播放那一页的"打开播放器"
        case resume, openDedaoPlayer
        var title: String {
            switch self {
            case .play: "播放"
            case .watch: "Play"
            case .watchLive: "观看直播"
            case .openPlayer: "打开网易云音乐"
            case .resume: "继续播放"
            case .openDedaoPlayer: "打开播放器"
            }
        }
        var symbol: String { self == .openPlayer || self == .openDedaoPlayer ? "arrow.up.right" : "play.fill" }
    }

    func actions(for id: String) -> [Action] {
        guard let item = current(for: id) else { return [] }
        switch item.kind {
        case .video(let video) where video.isLive: return [.watchLive]
        case .youtube: return [.watch]
        case .nowPlaying: return [.openPlayer]   // 正在播放那一页只显示，不控制；这个按钮只是进网易云的播放界面
        // 得到正在听的书：放着时是"打开播放器"（只是进播放界面），停着时是"继续听"
        case .dedaoNow(_, let paused): return [paused ? .resume : .openDedaoPlayer]
        case .dedao(_, let resume): return [resume ? .resume : .play]
        default: return [.play]
        }
    }


    func activate(_ action: Action, for id: String) {
        guard let tv, let item = current(for: id) else { return }
        // 都先像在主屏上选了这个应用一样打开它（open 会先关掉别的应用，比如后台在放的网易云）
        switch item.kind {
        case .video(let video):
            tv.openApp(BilibiliStore.appID)
            tv.bilibiliStore.resetTransient()
            tv.bilibiliStore.player.play(video)
        case .collection(let list, let songs):
            // 进这个歌单、从第一首放；从播放界面返回看到的是这个歌单
            tv.openApp(NeteaseStore.appID)
            tv.neteaseStore.playFromShelf(list, songs: songs)
        case .youtube(let id):
            tv.openYouTubeVideo(id)
        case .nowPlaying:
            tv.openApp(NeteaseStore.appID)
            tv.neteaseStore.showNowPlaying()
        case .dedaoNow(_, let paused):
            tv.openApp(DedaoStore.appID)
            if paused { tv.dedaoStore.resumeFromShelf() } else { tv.dedaoStore.openPlayer() }
        case .dedao(let book, _):
            // 书：放（接着上次听到的地方），打开播放界面；课、名家讲书：进它的一列，从没听完的那一讲放
            tv.openApp(DedaoStore.appID)
            tv.dedaoStore.playFromShelf(book)
        }
    }
}

extension AppShelf {
    /// "刚刚""5 分钟前""3 小时前""昨天""4 天前""11月2日"
    nonisolated static func ago(_ timestamp: Int, now: Date = Date()) -> String? {
        guard timestamp > 0 else { return nil }
        let seconds = Int(now.timeIntervalSince1970) - timestamp
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前" }
        if seconds < 86400 { return "\(seconds / 3600) 小时前" }
        if seconds < 2 * 86400 { return "昨天" }
        if seconds < 7 * 86400 { return "\(seconds / 86400) 天前" }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let parts = Calendar.current.dateComponents([.month, .day], from: date)
        return "\(parts.month ?? 1)月\(parts.day ?? 1)日"
    }
}

// MARK: 画面

/// 哔哩哔哩、网易云、YouTube 选中时的主屏顶部，是整个主屏的门面，按 Apple TV / Apple Music 的样子做：
/// - 视频、直播：封面占右边三分之二、顶到屏幕上沿，左边和下边慢慢淡进一片从封面里取的颜色，
///   标题、UP 主写在左边那片颜色上；封面慢慢放大一点点，不是一张死图。
/// - 歌单：背景是封面里几种颜色的渐变（封面黑白时用网易云的红），右边大封面，左边歌单名，
///   下面一块毛玻璃里是前几首歌（小封面、歌名、歌手）。
/// 往上滑进来（expanded）时，底下的应用图标让开，换成"播放"
struct AppShelfBanner: View {
    @ObservedObject var shelf: AppShelf
    @ObservedObject var tv: TVController
    let service: Service
    let expanded: Bool
    @Environment(\.canvasSize) private var canvas
    /// 小图还没下好时，下好了要重画一次（颜色从小图里取）
    @State private var loadedThumbnail: URL?

    var body: some View {
        if let item = shelf.current(for: service.id) {
            ZStack(alignment: .topLeading) {
                switch item.kind {
                case .nowPlaying(let song, let paused): nowPlayingLayout(item, song: song, paused: paused)
                case .collection: playlistLayout(item)
                case .video, .youtube: videoLayout(item)
                case .dedaoNow(_, let paused): dedaoLayout(item, paused: paused, now: true)
                case .dedao: dedaoLayout(item, paused: false, now: false)
                }
            }
            .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
            .clipped()
            .task(id: item.thumbnail) {
                guard let url = item.thumbnail, BiliImageCache.shared.image(for: url) == nil else { return }
                _ = await BiliImageCache.shared.load(url)
                withAnimation(AppShelf.pageAnimation) { loadedThumbnail = url }
            }
        }
    }

    /// 这个应用自己的颜色（和主屏图标、Catalog 里是同一个）
    private var accentHex: String { service.accent }
    private var accent: Color { Color(hex: accentHex) }

    /// 这一页的颜色：直接从已经下好的小图里取（取一次记着），和换页在同一个动画里变，不会晚一拍。
    /// 封面黑白、还没下好时用这个应用自己的颜色
    private func colors(_ item: AppShelfItem) -> ArtPalette {
        _ = loadedThumbnail
        if let palette = ArtPalette.cached(item.thumbnail), palette.colorful { return palette }
        return ArtPalette(accent: accentHex)
    }

    /// 换页时滑的那一块：这一页先很快地往翻的方向滑走、淡掉，下一页稍后从另一边滑进来——两页不会叠在一起出现重影
    ///（distance 越大越像是整页在移）。滑动交给 Core Animation（见 ShelfPage）。
    /// extra：除了这一页，里面画的东西还取决于什么（没变时这一块不重算）
    private func page<Content: View>(_ distance: CGFloat, _ item: AppShelfItem, _ extra: AnyHashable...,
                                     @ViewBuilder content: @escaping () -> Content) -> ShelfPage<Content> {
        ShelfPage(offset: CGFloat(shelf.direction) * distance, id: item.id, key: [AnyHashable(item)] + extra, content: content)
    }

    /// 左上角标签上写的（这一页自己的，或者这个应用统一的那个）
    private func tagText(_ item: AppShelfItem) -> String { item.tag ?? shelf.labels[service.id] ?? "" }

    /// 封面里的颜色斜着渐变，右边（唱片、书后面）透出一大圈亮，左边压一层黑托住字：换页时颜色跟着变（见 ShelfBackdrop）。
    /// 那层黑也放在这里（Core Animation 的渐变层）：和 Core Animation 的层叠在一起的 SwiftUI 渐变要在主线程上一点点画
    private func wash(_ colors: ArtPalette, center: UnitPoint, radius: CGFloat) -> ShelfBackdrop {
        ShelfBackdrop(layers: [
            ShelfGradient(kind: .linear(start: .topTrailing, end: .bottomLeading), colors: [colors.glow.opacity(0.55), colors.base]),
            ShelfGradient(kind: .radial(center: center, radius: radius), colors: [colors.glow.opacity(0.55), .clear]),
            ShelfGradient(kind: .linear(start: .leading, end: .trailing), colors: [.black.opacity(0.45), .black.opacity(0.1), .clear],
                          locations: [0, 0.45, 0.6]),
        ])
    }

    private func tag(_ item: AppShelfItem) -> some View {
        Text(tagText(item))
            .font(.system(size: 20, weight: .bold))
            .tracking(0.6)
            .padding(.horizontal, 14).frame(height: 34)
            .background(accent, in: Capsule())
            .foregroundStyle(.white)
    }

    /// 第几个：一排小点，现在这个是一段长一点的。不跟着换页滑，一直在原地
    private var dots: some View {
        let count = shelf.items[service.id]?.count ?? 0, current = shelf.index[service.id] ?? 0
        // 点画在 Core Animation 的层上，换页时跟着同一条弹簧挪（见 ShelfDots）
        return ShelfDots(count: count, current: current)
            .overlay(alignment: .leading) {
                // 每个点都能点：点哪个跳到哪一页（点的范围比点本身大一圈，好点中）。看不见，不用动画
                HStack(spacing: 0) {
                    ForEach(0..<count, id: \.self) { index in
                        Color.clear
                            .frame(width: ShelfDots.width(index, current: current), height: ShelfDots.height)
                            .padding(.horizontal, ShelfDots.gap / 2).padding(.vertical, 12)
                            .contentShape(Rectangle())
                            .onTapGesture { shelf.jump(service.id, to: index) }
                    }
                }
                .transaction { $0.animation = nil }
            }
            .opacity(count > 1 ? 1 : 0)
            .frame(height: 8)
    }

    /// "播放"：一直在同一个地方，不跟着换页滑（焦点在它上面，左右翻页时它不动）
    private var buttons: some View {
        HStack(spacing: 18) {
            ForEach(Array(shelf.actions(for: service.id).enumerated()), id: \.offset) { index, action in
                ShelfButton(title: action.title, systemImage: action.symbol,
                            focused: tv.focus == .shelf(index)) {
                    tv.setFocus(.shelf(index)); tv.activateShelf(index)
                }
            }
        }
        .frame(height: 76, alignment: .leading)
        .tvGlassTransition()
    }

    /// 应用图标那一排的上沿（平时文字要在它上面；往上滑进来时图标让开）
    private var dockTop: CGFloat { canvas.height - 320 }

    // MARK: 视频、直播
    //
    // 每一页的东西都在同一个位置、同一个大小：标签、两行高的标题框（标题一行时下面留空，不往上挤）、
    // UP 主那一行、按钮、小点。换页时只有内容在滑，框不动

    private static let videoTitleSize: CGFloat = 54
    private static let videoTitleBox: CGFloat = 136

    @ViewBuilder private func videoLayout(_ item: AppShelfItem) -> some View {
        let colors = colors(item)
        let width = canvas.width * 0.7, height = width * 9 / 16
        // 底色：封面里取的深色，右上角透出一点封面的亮色（换页时颜色跟着动画慢慢变）
        ShelfBackdrop(layers: [
            ShelfGradient(kind: .solid, colors: [colors.base]),
            ShelfGradient(kind: .radial(center: UnitPoint(x: 0.82, y: 0.3), radius: canvas.width * 0.55),
                          colors: [colors.glow.opacity(0.45), .clear]),
        ])
        .frame(width: canvas.width, height: canvas.height)
        // 封面：右上角，左边、下边淡进底色里
        page(140, item) {
            DriftingCover(url: item.image)
                .frame(width: width, height: height)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.42)],
                                     startPoint: .leading, endPoint: .trailing))
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.62), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        // 托字：左下角再压一层底色，标题落在封面上的那一截也看得清
        ShelfBackdrop(layers: [
            ShelfGradient(kind: .linear(start: .leading, end: .trailing),
                          colors: [colors.base.opacity(0.85), colors.base.opacity(0.35), .clear], locations: [0, 0.38, 0.6]),
        ])
        .frame(width: canvas.width, height: canvas.height)
        VStack(alignment: .leading, spacing: 0) {
            // 标签每一页都一样（"关注更新""为你推荐"），不跟着滑
            tag(item)
            // 跟着换页滑的那一块
            page(70, item) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.title)
                        .font(.system(size: Self.videoTitleSize, weight: .bold))
                        .lineLimit(2)
                        .lineSpacing(2)
                        .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
                        .frame(height: Self.videoTitleBox, alignment: .topLeading)
                        .padding(.top, 20)
                    HStack(spacing: 12) {
                        // 头像：哔哩哔哩每一页都有这个位置（没头像时空着，名字不跳）；YouTube 没有头像，名字顶格
                        if service.id == BilibiliStore.appID {
                            BiliImage(url: item.avatar).frame(width: 40, height: 40).clipShape(Circle())
                                .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1.5))
                                .opacity(item.avatar == nil ? 0 : 1)
                        }
                        Text(item.subtitle).font(.system(size: 26, weight: .semibold)).foregroundStyle(.white.opacity(0.92))
                        Text(item.detail).font(.system(size: 24, weight: .regular)).foregroundStyle(.white.opacity(0.62))
                    }
                    .lineLimit(1)
                    .frame(height: 40)
                    .padding(.top, 14)
                }
                .foregroundStyle(.white)
            }
            // 不跟着滑的：按钮、小点
            if expanded { buttons.padding(.top, 34) }
            dots.padding(.top, 32)
        }
        .foregroundStyle(.white)
        .frame(width: canvas.width * 0.5, alignment: .leading)
        .padding(.leading, 96)
        .frame(maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.bottom, expanded ? 130 : canvas.height - dockTop + 70)
    }

    // MARK: 歌单
    //
    // 同样每一页同一个位置、同一个大小：标题框两行高、一种字号（不按字数变大变小），歌固定四行的位置

    private static let playlistTitleSize: CGFloat = 56
    private static let playlistTitleBox: CGFloat = 140

    /// 封套里的黑胶比封套小一点：12 寸唱片（约 302 毫米）装在 12⅜ 寸的封套里（约 314 毫米），是封套的 0.96
    static func disc(in sleeve: CGFloat) -> CGFloat { (sleeve * 0.96).rounded() }

    /// 网易云：歌单的封面是一张唱片的封套，一张黑胶从封套里滑出来、慢慢转（网易云自己的标志就是这张转着的黑胶）。
    /// 左边是歌单名、多少首，下面是前四首歌
    @ViewBuilder private func playlistLayout(_ item: AppShelfItem) -> some View {
        let colors = colors(item)
        let sleeve: CGFloat = 540, disc = Self.disc(in: sleeve)
        let sleeveX = canvas.width - 510 - sleeve, top: CGFloat = 140
        // 背景：封面里的颜色斜着渐变，唱片后面透出一大圈亮
        wash(colors, center: UnitPoint(x: (sleeveX + sleeve) / canvas.width, y: 0.3), radius: 620)
            .frame(width: canvas.width, height: canvas.height)
        page(160, item) { RecordSleeve(cover: item.image, label: item.thumbnail, sleeve: sleeve, disc: disc, daily: isDaily(item)).id(item.id) }
            .padding(.leading, sleeveX).padding(.top, top)
        VStack(alignment: .leading, spacing: 0) {
            page(70, item, tagText(item)) {
                VStack(alignment: .leading, spacing: 0) {
                    tag(item)
                    Text(item.title)
                        .font(.system(size: Self.playlistTitleSize, weight: .bold))
                        .lineLimit(2)
                        .lineSpacing(2)
                        .frame(height: Self.playlistTitleBox, alignment: .topLeading)
                        .padding(.top, 18)
                    Text(item.subtitle)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                        .frame(height: 30, alignment: .leading)
                    songList(item).padding(.top, 22)
                }
                .foregroundStyle(.white)
            }
            if expanded { buttons.padding(.top, 30) }
            dots.padding(.top, 30)
        }
        .foregroundStyle(.white)
        .frame(width: sleeveX - 96 - 70, alignment: .leading)
        .padding(.leading, 96)
        .padding(.top, top + 6)
    }

    // MARK: 正在播放（网易云在后台放的歌）
    //
    // 和歌单那一页同一个排法：右边唱片（黑胶跟着歌转，暂停就停），左边标签、歌名、歌手 · 专辑，
    // 歌单那四行的位置换成进度和接下来的三首。只显示，不控制

    @ViewBuilder private func nowPlayingLayout(_ item: AppShelfItem, song: NeteaseSong, paused: Bool) -> some View {
        let colors = colors(item)
        let sleeve: CGFloat = 540, disc = Self.disc(in: sleeve)
        let sleeveX = canvas.width - 510 - sleeve, top: CGFloat = 140
        let store = tv.neteaseStore
        wash(colors, center: UnitPoint(x: (sleeveX + sleeve) / canvas.width, y: 0.3), radius: 620)
            .frame(width: canvas.width, height: canvas.height)
        page(160, item) {
            RecordSleeve(cover: item.image, label: item.thumbnail, sleeve: sleeve, disc: disc, daily: false,
                         playing: paused ? .paused : .playing)
                .id(item.id)
        }
        .padding(.leading, sleeveX).padding(.top, top)
        VStack(alignment: .leading, spacing: 0) {
            page(70, item, tagText(item)) {
                VStack(alignment: .leading, spacing: 0) {
                    tag(item)
                    Text(item.title)
                        .font(.system(size: Self.playlistTitleSize, weight: .bold))
                        .lineLimit(2)
                        .lineSpacing(2)
                        .frame(height: Self.playlistTitleBox, alignment: .topLeading)
                        .padding(.top, 18)
                    Text(item.subtitle)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                        .frame(height: 30, alignment: .leading)
                    NeteaseNowPanel(store: store, clock: store.clock).padding(.top, 22)
                }
                .foregroundStyle(.white)
            }
            if expanded { buttons.padding(.top, 30) }
            dots.padding(.top, 30)
        }
        .foregroundStyle(.white)
        .frame(width: sleeveX - 96 - 70, alignment: .leading)
        .padding(.leading, 96)
        .padding(.top, top + 6)
    }

    // MARK: 得到（书、课、正在听的那一讲）
    //
    // 和网易云的歌单那一页同一套框：同样的左边距、一样宽的左栏，按钮、小点在同一个位置（换到网易云、从网易云换过来，它们不跳）。
    // 左边的字从下往上排：最后一行落在网易云第四首歌的位置，离按钮、小点一样近；字少（书名一行、介绍两行）时
    // 整块沉下来挨着按钮，不贴在顶上、和按钮之间空一大截。几行之间按组留空：标签、书名和它下面那行小字一组，介绍、
    // 上架和评分（或者听到哪了）另一组。
    // 背景是封面里取的颜色铺开（同网易云，不糊图）；右边是一本竖着的书：封面、书脊的明暗、右边一摞书页、柔和的影子。
    // 书和网易云的唱片在同一条线上（上沿低于右上角那排按钮、下沿在应用图标那一排上面），往右靠，不挤在屏幕中间

    private static let dedaoBook = CGSize(width: 420, height: 560)
    /// 左边标签到内容底下那一整块最多多高：和网易云歌单那一页一样（标签 34、书名框 18 + 140、一行小字 30、22、四行歌 272）
    private static let dedaoInfoHeight: CGFloat = 34 + 18 + 140 + 30 + 22 + 272

    @ViewBuilder private func dedaoLayout(_ item: AppShelfItem, paused: Bool, now: Bool) -> some View {
        let colors = colors(item)
        let book = Self.dedaoBook
        // 左边那一栏和网易云一样宽（它的封套从 canvas.width - 510 - 540 开始）；书的右边离屏幕右边 300
        let columnEnd = canvas.width - 510 - 540
        let bookX = canvas.width - 300 - book.width, top: CGFloat = 150
        wash(colors, center: UnitPoint(x: (bookX + book.width / 2) / canvas.width, y: (top + book.height / 2) / canvas.height),
             radius: 640)
            .frame(width: canvas.width, height: canvas.height)
        page(160, item, now, paused) {
            DedaoShelfBook(cover: item.image, size: book)
                .scaleEffect(now && paused ? 0.94 : 1)
                .animation(.spring(response: 0.5, dampingFraction: 0.85), value: paused)
        }
        .padding(.leading, bookX).padding(.top, top)
        VStack(alignment: .leading, spacing: 0) {
            page(70, item, tagText(item)) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        tag(item)
                        // 书名前面的"英文新书""英文原版"这些：一个小小的框，不放进大标题里
                        if let badge = dedaoBadge(item) {
                            Text(badge)
                                .font(.system(size: 19, weight: .semibold))
                                .padding(.horizontal, 12).frame(height: 32)
                                .overlay(PillOutline().strokeBorder(.white.opacity(0.55), lineWidth: 1.5))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    // 书名不占两行的空位（一行的书名下面不留一大块空）；整块贴着下沿，按钮、小点照样在网易云的位置
                    Text(item.title)
                        .font(.system(size: Self.playlistTitleSize, weight: .bold))
                        .lineLimit(2)
                        .lineSpacing(4)
                        .padding(.top, 24)
                    Text(item.subtitle)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .frame(height: 30, alignment: .leading)
                        .padding(.top, 16)
                    switch item.kind {
                    case .dedaoNow(let track, let paused):
                        DedaoListeningPanel(store: tv.dedaoStore, player: tv.dedaoStore.player, item: item, track: track, book: nil,
                                            paused: paused, intro: track.summary)
                            .padding(.top, 34)
                    case .dedao(let book, true):
                        DedaoListeningPanel(store: tv.dedaoStore, player: tv.dedaoStore.player, item: item, track: nil, book: book,
                                            paused: true, intro: book.intro)
                            .padding(.top, 34)
                    case .dedao(let book, false):
                        DedaoShelfDetail(item: book, intro: item.detail).padding(.top, 34)
                    default:
                        EmptyView()
                    }
                }
                // 最后一行字和按钮（收起时是小点）之间留出和网易云最后一首歌一样的空
                .padding(.bottom, 16)
                // 字多得放不下（两行的书名、正在听一门课还有接下来两讲）时往上长，不把书名挤成一行
                .fixedSize(horizontal: false, vertical: true)
                .frame(height: Self.dedaoInfoHeight, alignment: .bottomLeading)
                .foregroundStyle(.white)
            }
            if expanded { buttons.padding(.top, 30) }
            dots.padding(.top, 30)
        }
        .foregroundStyle(.white)
        .frame(width: columnEnd - 96 - 70, alignment: .leading)
        .padding(.leading, 96)
        .padding(.top, 140 + 6)
    }

    /// 书名前面的小框（"英文新书"）：正在听的那一讲从它的名字里取
    private func dedaoBadge(_ item: AppShelfItem) -> String? {
        switch item.kind {
        case .dedao(let book, _): DedaoStore.cleanTitle(book.title).badge
        case .dedaoNow(let track, _): DedaoStore.cleanTitle(DedaoPlayerScreen.split(track.title).title).badge
        default: nil
        }
    }

    private func isDaily(_ item: AppShelfItem) -> Bool {
        if case .collection(let list, _) = item.kind { return list.kind == .daily }
        return false
    }

    /// 前四首歌：序号、小封面、歌名、歌手，一行一首，中间一条细线。总是占四行的位置（歌少时空着），下面的东西不会跟着跳
    private func songList(_ item: AppShelfItem) -> some View {
        let songs: [NeteaseSong] = if case .collection(_, let songs) = item.kind { Array(songs.prefix(4)) } else { [] }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<4, id: \.self) { index in
                if songs.indices.contains(index) {
                    ShelfSongRow(number: index + 1, song: songs[index], divider: index < songs.count - 1)
                } else {
                    Color.clear.frame(height: ShelfSongRow.height)
                }
            }
        }
        .frame(width: ShelfSongRow.width, alignment: .leading)
    }
}

/// 网易云那几页左下角的一首歌：序号、小封面、歌名、歌手。歌单那一页和正在播放那一页用同一个，位置一模一样。
/// divider：下面画一条细线（和下一行隔开；最后一行不画）
private struct ShelfSongRow: View {
    static let height: CGFloat = 68
    static let width: CGFloat = 680
    let number: Int
    let song: NeteaseSong
    let divider: Bool

    var body: some View {
        HStack(spacing: 16) {
            Text(String(format: "%02d", number))
                .font(.system(size: 20, weight: .bold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 34, alignment: .leading)
            BiliImage(url: song.cover)
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(song.name).font(.system(size: 25, weight: .semibold)).lineLimit(1)
            Text(song.artist).font(.system(size: 21)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: Self.height)
        .overlay(alignment: .bottom) {
            if divider { Rectangle().fill(.white.opacity(0.09)).frame(height: 1) }
        }
    }
}

/// 一块挖了个圆孔的方块（填的时候用 even-odd）：盖在唱片上当遮罩，正中间的轴孔透出后面的背景
private struct SpindleHole: Shape {
    let diameter: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addEllipse(in: CGRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2, width: diameter, height: diameter))
        return path
    }
}

/// 唱片：封套（歌单封面）在前，黑胶从它后面往右滑出来。只有正在放的那首歌的唱片会转（暂停就停），
/// 歌单、专辑没在放，唱片不转。
/// 黑胶本身是画出来的：一圈圈纹路、中间贴着封面的圆标签和一个小孔，上面一层不转的反光
private struct RecordSleeve: View {
    let cover: URL?
    let label: URL?
    let sleeve: CGFloat
    let disc: CGFloat
    let daily: Bool
    /// 网易云正在放的歌：黑胶转（暂停就停在那个角度，接着放从那里接着转）。nil 是歌单：不转
    var playing: Playback? = nil

    enum Playback {
        case playing, paused
        var paused: Bool { self == .paused }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 出现时黑胶从封套里滑出来（晚 0.15 秒、一条弹簧）：滑动交给 Core Animation（见 ShelfSlideIn），
            // 黑胶上的纹路、影子不用每一帧都重画
            ShelfSlideIn(distance: sleeve / 2 - disc / 2 - (sleeve - disc / 2 + 30), delay: 0.15,
                         spring: ShelfSpring(response: 0.9, dampingFraction: 0.85)) { vinyl }
                .frame(width: disc, height: disc)
                .offset(x: sleeve - disc / 2 + 30, y: (sleeve - disc) / 2)
            BiliImage(url: cover)
                .frame(width: sleeve, height: sleeve)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    if daily {
                        // 每日推荐：封套左上角写今天几号（网易云自己的每日推荐也是这样）
                        Text("\(Calendar.current.component(.day, from: Date()))")
                            .font(.system(size: 118, weight: .heavy).monospacedDigit())
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.45), radius: 16, y: 4)
                            .padding(.leading, 30).padding(.top, 14)
                    }
                }
                .shadow(color: .black.opacity(0.55), radius: 40, x: 18, y: 26)
        }
        .frame(width: sleeve + disc / 2 + 60, height: sleeve, alignment: .topLeading)
    }

    private var vinyl: some View {
        ZStack {
            // 盘面、纹路、中间的标签：正在放的歌才转（转动交给 Core Animation，见 SpinningDisc）
            if let playing {
                SpinningDisc(paused: playing.paused) { record }
            } else {
                record
            }
            // 不转的反光
            Circle().fill(AngularGradient(stops: [.init(color: .white.opacity(0), location: 0),
                                                 .init(color: .white.opacity(0.1), location: 0.1),
                                                 .init(color: .white.opacity(0), location: 0.2),
                                                 .init(color: .white.opacity(0), location: 0.55),
                                                 .init(color: .white.opacity(0.07), location: 0.65),
                                                 .init(color: .white.opacity(0), location: 0.75),
                                                 .init(color: .white.opacity(0), location: 1)], center: .center))
            Circle().strokeBorder(.white.opacity(0.08), lineWidth: 1.5)
        }
        .frame(width: disc, height: disc)
        .shadow(color: .black.opacity(0.55), radius: 36, y: 22)
        // 中间的轴孔是真的穿透的：透过它看见后面的背景（唱片的影子在孔里也挖掉，不然孔里是一团黑）。孔在正中间，
        // 转起来、滑出来都还在原地；遮罩只画一次，不跟着每一帧算。遮罩比唱片大一圈，影子不被切掉
        .mask { SpindleHole(diameter: Self.hole(disc)).fill(style: FillStyle(eoFill: true)).padding(-100) }
    }

    /// 轴孔多大：真唱片 7 毫米的孔、100 毫米的标签，是标签的 0.07
    static func hole(_ disc: CGFloat) -> CGFloat { disc * 0.38 * 0.07 }

    /// 盘面、一圈圈纹路、中间贴着封面的圆标签和小孔
    private var record: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Color(white: 0.1), Color(white: 0.03)], center: .center,
                                         startRadius: disc * 0.2, endRadius: disc / 2))
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                var radius = size.width * 0.22
                while radius < size.width * 0.485 {
                    context.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                                   with: .color(.white.opacity(0.04)), lineWidth: 1)
                    radius += 3.4
                }
            }
            BiliImage(url: label)
                .frame(width: disc * 0.38, height: disc * 0.38)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 2))
            // 轴孔的边：贴着孔外沿一圈很淡的暗边，看起来是有厚度的孔，不是贴上去的一个点
            Circle().strokeBorder(.black.opacity(0.3), lineWidth: 1.25)
                .frame(width: Self.hole(disc) + 2.5, height: Self.hole(disc) + 2.5)
        }
        .frame(width: disc, height: disc)
    }
}

/// 视频封面：慢慢放大一点点（9 秒放大 6%），像 Apple TV 顶部的大图，不是一张死图。
/// 放大交给 Core Animation（轮播 8 秒翻一页，用 SwiftUI 动画的话主屏几乎一直在每帧重算）
private struct DriftingCover: View {
    let url: URL?

    var body: some View {
        LayerAnimated(motion: .drift) { BiliImage(url: url) }
            .clipped()
    }
}

/// 从封面里取的颜色：base 是一片深色（当底），glow 是封面里最亮眼的颜色（透出来的那一圈）。
/// colorful = 封面有颜色；黑白的封面取出来是灰的，那时用应用自己的颜色
struct ArtPalette: Equatable {
    let base: Color
    let glow: Color
    let colorful: Bool

    /// 已经下好的小图的颜色（算一次记着；图还没下好时 nil）
    @MainActor private static var memo: [URL: ArtPalette] = [:]
    @MainActor static func cached(_ url: URL?) -> ArtPalette? {
        guard let url else { return nil }
        if let known = memo[url] { return known }
        guard let image = BiliImageCache.shared.image(for: url), let palette = ArtPalette(image) else { return nil }
        if memo.count > 200 { memo.removeAll() }
        memo[url] = palette
        return palette
    }

    /// 应用自己的颜色（封面黑白、还没下好时）
    init(accent hex: String) {
        let tint = NSColor(Color(hex: hex)).usingColorSpace(.sRGB) ?? .systemRed
        base = Color(nsColor: NSColor(hue: tint.hueComponent, saturation: 0.7, brightness: 0.16, alpha: 1))
        glow = Color(nsColor: NSColor(hue: tint.hueComponent, saturation: 0.8, brightness: 0.62, alpha: 1))
        colorful = true
    }

    /// 把封面缩成 6×6 的小格子：所有格子平均出底色，最鲜艳的那一格是亮色
    init?(_ image: NSImage) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 6
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var total = (r: 0.0, g: 0.0, b: 0.0)
        var best: NSColor?
        var bestScore = -1.0
        for cell in 0..<(side * side) {
            let r = Double(pixels[cell * 4]) / 255, g = Double(pixels[cell * 4 + 1]) / 255, b = Double(pixels[cell * 4 + 2]) / 255
            total.r += r; total.g += g; total.b += b
            let color = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            // 又鲜艳又不太暗的那一格
            let score = Double(color.saturationComponent) * (0.35 + Double(color.brightnessComponent))
            if score > bestScore { bestScore = score; best = color }
        }
        let count = Double(side * side)
        let average = NSColor(srgbRed: total.r / count, green: total.g / count, blue: total.b / count, alpha: 1)
        let vivid = best ?? average
        colorful = vivid.saturationComponent > 0.22
        base = Color(nsColor: NSColor(hue: average.hueComponent, saturation: min(0.75, average.saturationComponent * 1.15),
                                      brightness: min(0.2, max(0.1, average.brightnessComponent * 0.4)), alpha: 1))
        glow = Color(nsColor: NSColor(hue: vivid.hueComponent, saturation: min(0.85, vivid.saturationComponent * 1.2),
                                      brightness: min(0.72, max(0.45, vivid.brightnessComponent)), alpha: 1))
    }
}

/// 正在放的歌的黑胶：慢慢转（18 秒一圈），暂停就停在那个角度，接着放从那里接着转
private struct SpinningDisc<Content: View>: View {
    let paused: Bool
    @ViewBuilder let content: () -> Content

    var body: some View { LayerAnimated(motion: .spin, paused: paused, content: content) }
}

/// 一块画面绕着正中间做的慢动画（转、慢慢放大），交给 Core Animation：画面只画一次，动画在系统合成那边跑，
/// App 自己一帧都不用算。用 SwiftUI 的动画的话，SwiftUI 每一帧都要把整个主屏重新过一遍——
/// 主屏闲着也占四成 CPU，按键事件被挤成一串处理，按键声、震动跟着丢
private struct LayerAnimated<Content: View>: NSViewRepresentable {
    enum Motion {
        /// 一直转：18 秒一圈，顺时针
        case spin
        /// 放大一次：9 秒放大到 1.06 倍，停在那里
        case drift
    }

    let motion: Motion
    var paused = false
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> LayerAnimatedView<Content> {
        LayerAnimatedView(NSHostingView(rootView: content()), animation: Self.animation(motion))
    }

    func updateNSView(_ view: LayerAnimatedView<Content>, context: Context) {
        view.host.rootView = content()
        view.setPaused(paused)
    }

    static func animation(_ motion: Motion) -> CAAnimation {
        switch motion {
        case .spin:
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 18
            spin.repeatCount = .infinity
            return spin
        case .drift:
            let zoom = CABasicAnimation(keyPath: "transform.scale")
            zoom.fromValue = 1
            zoom.toValue = 1.06
            zoom.duration = 9
            zoom.fillMode = .forwards
            return zoom
        }
    }
}

final class LayerAnimatedView<Content: View>: NSView {
    let host: NSHostingView<Content>
    private let animation: CAAnimation
    /// 动的那一层：一个没有大小的点，放在正中间，画好的画面以它为中心挂在它下面。
    /// 不能靠改图层的锚点让它绕中间转：视图的图层归 AppKit 管，它重建图层树时（不经过 layout()）会把锚点、
    /// 位置按视图的 frame 重新算一遍，放回角上；窗口拉成竖的时这个视图的大小不变（TVCanvas 缩放的是外面那层），
    /// layout() 也不会再跑，唱片就一直绕着角公转。零大小的图层不管锚点放在哪都是同一个点，AppKit 怎么重算都是正中间
    private let pivot = LayerPivotView()
    private var paused = false

    /// 转动、放大的那一层（测试用）
    var animatedLayer: CALayer? { pivot.layer }

    init(_ host: NSHostingView<Content>, animation: CAAnimation) {
        self.host = host
        self.animation = animation
        animation.isRemovedOnCompletion = false
        super.init(frame: .zero)
        wantsLayer = true
        pivot.wantsLayer = true
        pivot.clipsToBounds = false
        addSubview(pivot)
        pivot.addSubview(host)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        pivot.frame = CGRect(x: bounds.midX, y: bounds.midY, width: 0, height: 0)
        host.frame = CGRect(x: -bounds.width / 2, y: -bounds.height / 2, width: bounds.width, height: bounds.height)
        startIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard window != nil, let layer = pivot.layer, layer.animation(forKey: "motion") == nil else { return }
        layer.add(animation, forKey: "motion")
        if paused { freeze(layer) }
    }

    /// 暂停：停在现在的角度；接着放：从这个角度接着转
    func setPaused(_ paused: Bool) {
        guard paused != self.paused else { return }
        self.paused = paused
        guard let layer = pivot.layer else { return }
        if paused {
            freeze(layer)
        } else {
            let stoppedAt = layer.timeOffset
            layer.speed = 1
            layer.timeOffset = 0
            layer.beginTime = 0
            layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - stoppedAt
        }
    }

    private func freeze(_ layer: CALayer) {
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.speed = 0
        layer.timeOffset = now
    }
}

/// LayerAnimatedView 转动的中心点：零大小，画面挂在它外面。默认的点击检测先看点是不是在自己的 frame 里，
/// 零大小就永远不在，所以直接问里面的画面（和以前一样，点到画面上是画面接着）
private final class LayerPivotView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview else { return nil }
        let local = convert(point, from: superview)
        for subview in subviews.reversed() {
            if let hit = subview.hitTest(local) { return hit }
        }
        return nil
    }
}

/// 正在播放那一页左下：歌单那四行的位置，第一行是进度（和两头的时间），下面三行是接下来的三首
///（序号是它们在播放列表里排第几）。只看网易云的进度和播放列表，一秒变几次只重画这一块
private struct NeteaseNowPanel: View {
    @ObservedObject var store: NeteaseStore
    @ObservedObject var clock: NeteaseClock
    private let width = ShelfSongRow.width

    var body: some View {
        let next = store.nextSongs(3)
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 12) {
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.2))
                    Capsule().fill(.white).frame(width: clock.duration > 0 ? width * min(1, clock.time / clock.duration) : 0)
                }
                .frame(width: width, height: 6)
                .animation(.linear(duration: 0.25), value: clock.time)
                HStack {
                    Text(clockText(clock.time))
                    Spacer()
                    Text("−" + clockText(max(0, clock.duration - clock.time)))
                }
                .font(.system(size: 20, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
            }
            .frame(width: width, height: ShelfSongRow.height)
            .overlay(alignment: .bottom) {
                if !next.isEmpty { Rectangle().fill(.white.opacity(0.09)).frame(height: 1) }
            }
            ForEach(0..<3, id: \.self) { index in
                if next.indices.contains(index) {
                    ShelfSongRow(number: next[index].number, song: next[index].song, divider: index < next.count - 1)
                } else {
                    Color.clear.frame(height: ShelfSongRow.height)
                }
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

/// 一本竖着的书：封面，左边一条书脊的明暗，右边露出一摞书页，下面柔和的影子。都是静的，不转不动
private struct DedaoShelfBook: View {
    let cover: URL?
    let size: CGSize

    var body: some View {
        let shape = UnevenRoundedRectangle(cornerRadii: .init(topLeading: 4, bottomLeading: 4, bottomTrailing: 12, topTrailing: 12),
                                           style: .continuous)
        ZStack(alignment: .topLeading) {
            // 书页：封面后面往右下错开一点点的两层，米白色
            ForEach(0..<2, id: \.self) { layer in
                shape.fill(Color(white: layer == 0 ? 0.86 : 0.93))
                    .frame(width: size.width, height: size.height - 10)
                    .offset(x: CGFloat(10 - layer * 4), y: CGFloat(5 + layer * 0))
            }
            // 封面还没下好时是一本深色的书（不透出后面的书页）
            ZStack {
                Color(white: 0.16)
                BiliImage(url: cover)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            // 书脊：左边一窄条先暗后亮，像封面在这里折过去
            .overlay(alignment: .leading) {
                LinearGradient(stops: [.init(color: .black.opacity(0.38), location: 0), .init(color: .black.opacity(0.08), location: 0.45),
                                       .init(color: .white.opacity(0.18), location: 0.6), .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: 34)
                    .clipShape(shape)
            }
            // 封面上一层很淡的光（左上亮、右下暗），不那么像一张平的图
            .overlay(LinearGradient(colors: [.white.opacity(0.08), .clear, .black.opacity(0.12)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing).clipShape(shape))
            .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 1))
        }
        .frame(width: size.width + 10, height: size.height, alignment: .topLeading)
        .shadow(color: .black.opacity(0.5), radius: 40, x: 18, y: 28)
    }
}

/// 得到一本书、一门课那一页下面那块（和正在听那一块一样高）：两三行介绍，下面一行听到哪了——
/// "已听 40%"和一条细进度、"已听完"，没听过的写评分和多少人学过（课程写一共几讲）
private struct DedaoShelfDetail: View {
    let item: DedaoAPI.Item
    let intro: String

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            if !intro.isEmpty {
                Text(intro)
                    .font(.system(size: 27))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineSpacing(9)
                    .lineLimit(3)
            }
            HStack(spacing: 28) {
                if item.finished || item.progress >= 100 {
                    Label("已听完", systemImage: "checkmark.circle.fill")
                } else if item.progress > 0 {
                    Text("已听 \(item.progress)%").monospacedDigit()
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.22))
                        Capsule().fill(.white).frame(width: 300 * CGFloat(item.progress) / 100)
                    }
                    .frame(width: 300, height: 6)
                } else {
                    // 没听过的：评分、多少人学过（新不新，左上角"新书 · 分类"已经说了）
                    if !item.score.isEmpty { Label("\(item.score) 分", systemImage: "star.fill") }
                    if let count = DedaoStore.countText(item) { Text(count) }
                    if !item.heat.isEmpty { Text(item.heat) }
                }
            }
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.white.opacity(0.62))
            .lineLimit(1)
        }
    }
}

/// 正在听的书那一页下面那块（放着、停着、这次还没放过的"继续学习"都是它）：
/// 一条细进度，下面左边"已听 22%"、右边"还剩 15:24"；再是"上次听到"那几句文稿（左边一条细细的颜色，像引文）；
/// 不止一讲时最后是接下来的两讲。只有进度跟着播放器变（放着时一秒两次）；那几句在暂停、翻到这一页时才重新取
private struct DedaoListeningPanel: View {
    let store: DedaoStore
    @ObservedObject var player: DedaoPlayer
    let item: AppShelfItem
    /// 播放器里那一讲（继续学习那一本是 nil）
    let track: DedaoAPI.Track?
    /// 这次还没放过的"继续学习"那一本
    let book: DedaoAPI.Item?
    let paused: Bool
    let intro: String
    @State private var heard: String?
    private let width: CGFloat = 680
    private static let accent = Color(hex: "#FF6A00")

    var body: some View {
        let (fraction, left) = progress
        let next = track == nil ? [] : DedaoStore.upcoming(player.queue, after: player.index, count: 2)
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 12) {
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.2))
                    Capsule().fill(.white).frame(width: width * fraction)
                }
                .frame(width: width, height: 6)
                HStack {
                    Text(fraction >= 0.98 ? "已听完" : "已听 \(Int((fraction * 100).rounded()))%")
                    Spacer()
                    if left > 0 { Text("还剩 " + clockText(left)) }
                }
                .font(.system(size: 20, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
            }
            .frame(width: width)
            // 上次听到：那一段文稿的两三行；没有文稿时放介绍（介绍上面不写标题）
            let text = heard ?? intro
            if !text.isEmpty {
                HStack(alignment: .top, spacing: 18) {
                    Capsule().fill(Self.accent).frame(width: 4)
                    VStack(alignment: .leading, spacing: 8) {
                        if heard != nil {
                            Text(paused ? "上次听到" : "听到这里")
                                .font(.system(size: 19, weight: .bold)).foregroundStyle(Self.accent)
                        }
                        Text(text)
                            .font(.system(size: 25))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineSpacing(6)
                            .lineLimit(item.title.count > 12 ? 2 : 3)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: width, alignment: .leading)
                .padding(.top, 26)
            }
            if !next.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(next.enumerated()), id: \.offset) { index, lecture in
                        HStack(spacing: 16) {
                            Text(String(format: "%02d", lecture.number))
                                .font(.system(size: 19, weight: .bold).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.4))
                                .frame(width: 34, alignment: .leading)
                            Text(DedaoStore.cleanTitle(DedaoPlayerScreen.split(lecture.track.title).title).title)
                                .font(.system(size: 23, weight: .semibold)).lineLimit(1)
                            Spacer(minLength: 0)
                            if lecture.track.duration > 0 {
                                Text(clockText(lecture.track.duration)).font(.system(size: 20).monospacedDigit()).foregroundStyle(.white.opacity(0.55))
                            }
                        }
                        .frame(width: width, height: 52)
                        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.09)).frame(height: 1) }
                    }
                }
                .padding(.top, 20)
            }
        }
        .frame(width: width, alignment: .leading)
        // 暂停了、翻到这一页时重新看一眼听到哪了（放着的时候不跟）
        .task(id: "\(item.id)-\(paused)") { heard = await store.lastHeard(item) }
    }

    /// 听了几成、还剩几秒：播放器那一讲看播放器，"继续学习"那一本看得到记的进度
    private var progress: (Double, Double) {
        if let track, player.current?.id == track.id, player.duration > 0 {
            return (min(1, player.time / player.duration), max(0, player.duration - player.time))
        }
        if let book {
            let fraction = book.finished ? 1 : Double(book.progress) / 100
            return (fraction, book.duration > 0 ? book.duration * (1 - fraction) : 0)
        }
        return (0, 0)
    }
}
