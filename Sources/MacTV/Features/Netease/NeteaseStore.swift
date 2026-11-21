import AVFoundation
import AppKit
import MediaPlayer
import Combine
import CoreImage
import SwiftUI

/// 播放进度：一秒变很多次，单独放一处。只有进度条、两头的时间和正在唱的那句歌词看它，
/// 不会每次都带着整个页面（包括盖在下面看不见的首页）重画一遍。
@MainActor
final class NeteaseClock: ObservableObject {
    /// 显示用的秒数（两头的时间、换句）：四分之一秒更新一次就够。逐字歌词和进度条每一帧直接问播放器，不看它
    @Published var time: Double = 0
    @Published var duration: Double = 0
}

/// 网易云音乐的原生页面：扫码登录；首页一排排封面（每日推荐、我喜欢的音乐、推荐歌单、我的歌单、排行榜）；
/// 搜索；歌单页（竖排的歌曲列表）；带歌词的"正在播放"。
@MainActor
final class NeteaseStore: ObservableObject {
    static let appID = "netease"

    enum Item: Hashable {
        case song(NeteaseSong)
        case playlist(NeteasePlaylist)
    }
    struct Row: Hashable { let id: String; var title: String; var items: [Item] }

    weak var tv: TVController?

    @Published private(set) var account: NeteaseAccount?
    /// 登录状态查过了没有（没查完之前不显示二维码，免得闪一下）
    @Published private(set) var checked = false
    @Published private(set) var loading = false
    /// 从官方登录页取出来的二维码；loginScanned = 已扫码，等手机上确认
    @Published private(set) var loginImage: NSImage?
    @Published private(set) var loginScanned = false
    /// 等了好一会儿二维码还没来：提示可以改去官方网页登录
    @Published private(set) var loginSlow = false
    private let loginPage = NeteaseLoginPage()
    private var loginWatch: Task<Void, Never>?

    @Published private(set) var home: [Row] = []
    /// 搜索：editing = 正在输入框里打字；results 不为 nil 时，下面显示的是搜索结果而不是首页
    @Published private(set) var editing = false
    @Published var query = ""
    @Published private(set) var results: [Row]?
    private var lastKeyword = ""
    /// 打开的某个歌单：竖排的歌曲列表，index 是选中的第几首
    struct Page {
        var list: NeteasePlaylist
        var songs: [NeteaseSong] = []
        var index = 0
        var loading = true
        /// 焦点在左边那几个按钮上（播放、随机播放、收藏）时是第几个；在歌曲列表里时为 nil
        var button: Int?
    }
    @Published private(set) var page: Page?

    /// 顶上一排，从左到右：正在放的歌（有歌在放才有）、搜索、头像。最上面一排再按上到这里，
    /// 停在上面只是选中，按确认才进去。
    enum TopItem: Hashable { case player, search, account }
    @Published private(set) var topFocus: TopItem?
    var topItems: [TopItem] { (current != nil ? [.player] : []) + (page == nil && !settingsOpen ? [.search, .account] : []) }

    /// 长按确认（或点"⋯"、点头像）弹出的小菜单
    enum MenuAction: Hashable {
        case like(NeteaseSong), addTo(NeteaseSong), pick(NeteasePlaylist, NeteaseSong), create(NeteaseSong)
        case subscribe(NeteasePlaylist), cycleMode, logout
        case artist(NeteaseSong), goArtist(NeteaseArtist), album(NeteaseSong)
        case rename(NeteasePlaylist), delete(NeteasePlaylist), confirmDelete(NeteasePlaylist), cancel
        case confirmLogout, confirmUnsubscribe(NeteasePlaylist), showQueue
        case openSettings, setQuality(String), refresh
        /// 设置里主屏顶部放什么：勾上 / 取消这一种（NeteaseShelfSource 的 rawValue），可以选好几种
        case toggleShelf(String)
    }
    enum MenuAnchor { case card, song, nowPlaying, account, pageButton, setting }
    struct MenuItem: Hashable {
        let symbol: String
        let title: String
        let action: MenuAction
        /// 确认"删除""退出登录""取消收藏"的那一项：选中时高亮是红的
        var danger: Bool {
            switch action {
            case .confirmDelete, .confirmLogout, .confirmUnsubscribe: true
            default: false
            }
        }
    }
    struct Menu { var anchor: MenuAnchor; var items: [MenuItem]; var index = 0; var title: String? = nil }
    /// 设置里勾主屏顶部那几项：停下来以后再去取（见 toggleShelf）
    private var shelfRefresh: Task<Void, Never>?

    /// 主屏顶部那几种，勾着的打勾
    private func shelfMenuItems() -> [MenuItem] {
        let chosen = Set(NeteaseShelfSource.selected)
        // 第一项是"正在播放"（后台放歌时顶部最前面那一页），后面是可以多选的那几种歌单
        let nowPlaying = MenuItem(symbol: NeteaseShelfSource.showsNowPlaying ? "checkmark" : "", title: "正在播放",
                                  action: .toggleShelf(NeteaseShelfSource.nowPlayingKey))
        return [nowPlaying] + NeteaseShelfSource.allCases.map {
            MenuItem(symbol: chosen.contains($0) ? "checkmark" : "", title: $0.title, action: .toggleShelf($0.rawValue))
        }
    }
    /// 设置 › Apps › Top Shelf 里勾一项：和这里的菜单走同一条（同样的规则、提示、重新取）
    func toggleShelf(_ raw: String) { run(.toggleShelf(raw)) }
    @Published private(set) var menu: Menu?
    /// 菜单是一层一层进去的（比如"收藏到歌单"里面是一列歌单）：这里记着上一层，Esc 一次只退一层
    private var menuParents: [Menu] = []
    /// 正在输名字的那一行（新建歌单，或给歌单改名）：菜单里那一行变成输入框
    @Published private(set) var naming: MenuAction?
    @Published var newName = ""
    /// 有输入框拿着键盘（搜索，或给新歌单起名字）
    var typing: Bool { editing || naming != nil }
    /// 输入框该拿着键盘却没拿到时加一，界面看到它变了就再去要一次
    @Published private(set) var focusRequest = 0
    func refocus() { focusRequest += 1 }

    @Published private(set) var liked: Set<Int> = []
    /// 我的歌单（自己建的和收藏的），第一个是"我喜欢的音乐"
    private(set) var myLists: [NeteasePlaylist] = []
    /// 最近播放的歌（"我的歌单"最前面那张卡片点进去就是它）
    private var recentSongs: [NeteaseSong] = []
    private var recentCard: NeteasePlaylist? {
        guard let first = recentSongs.first else { return nil }
        return NeteasePlaylist(id: 0, name: "最近播放", cover: first.cover, count: recentSongs.count, kind: .recent)
    }
    /// "我的歌单"那一排：最近播放在最前面，然后是我喜欢的音乐、自己建的、收藏的
    private var listItems: [Item] { (recentCard.map { [$0] } ?? []).map(Item.playlist) + myLists.map(Item.playlist) }
    /// 取过的歌单里的歌：再进同一个歌单不用再等（海外到网易云每次往返要一两秒）
    private var songCache: [Int: [NeteaseSong]] = [:]
    /// 今天的每日推荐（从主屏顶部进"每日推荐"这一页时直接摆出来）
    /// 每日推荐的歌，和它是哪一天的（网易云早上 6 点换；过了这一天就要重新取）
    private var dailySongs: [NeteaseSong] = [] { didSet { dailyDay = Self.dailyDay() } }
    private var dailyDay = ""
    private static func dailyDay(_ date: Date = Date()) -> String {
        let shifted = date.addingTimeInterval(-6 * 3600)
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: shifted)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }
    /// 今天的每日推荐已经有了（不是昨天的）
    private var dailyIsFresh: Bool { !dailySongs.isEmpty && dailyDay == Self.dailyDay() }
    /// 什么时候暂停的（停太久再放时要重新要歌的地址）
    private var pausedAt = Date.distantFuture
    @Published private(set) var rowIndex = 0
    @Published private(set) var columns: [String: Int] = [:]

    // 播放
    @Published private(set) var current: NeteaseSong?
    @Published private(set) var paused = false
    let clock = NeteaseClock()
    var time: Double { clock.time }
    var duration: Double { clock.duration }
    /// 播放界面开着。只有这里自己改它；能从外面设，是给测试摆出"开着播放界面时回主屏"那个样子
    @Published var nowPlayingVisible = false {
        // 播放界面一打开，就在后台把这首歌的歌手页、专辑页取好：点歌手名字、专辑进去时不用等
        didSet {
            guard nowPlayingVisible, !oldValue else { return }
            if let current { prefetchPages(of: current) }
            updateLine(at: playbackTime())   // 一打开就对到现在唱的那一句（关着的时候不跟）
        }
    }
    @Published private(set) var lyrics: [NeteaseLyricLine] = []
    /// 现在唱到第几句（-1 = 还没开始）
    @Published private(set) var lyricIndex = -1
    /// 播放界面要不要留歌词那一栏。切歌时歌词会先清空再载入，这个值等新歌的歌词结果回来才改，
    /// 所以布局不会在切歌的那一下左右晃。
    @Published private(set) var lyricsShown = true
    /// 现在这份歌词属于哪首歌（还没载入时为 0）：切歌时旧歌词先淡出，新歌词到了再淡入
    @Published private(set) var lyricsSong = 0

    /// 音质档位。选了账号或这首歌没有的档位，服务器会给它能给的最高一档，actualLevel 是实际拿到的。
    struct Quality: Hashable { let level: String; let name: String }
    static let qualities = [Quality(level: "standard", name: "标准"), Quality(level: "higher", name: "较高"),
                            Quality(level: "exhigh", name: "极高"), Quality(level: "lossless", name: "无损"),
                            Quality(level: "hires", name: "Hi-Res"), Quality(level: "jymaster", name: "超清母带")]
    @Published private(set) var qualityVisible = false
    @Published private(set) var qualityIndex = 0
    @Published private(set) var actualLevel = ""
    /// 这个账号最高能听到哪一档（会员等级决定，和歌无关）。登录后问一次，之后每首歌的结果顺便更新；记在本机
    @Published private(set) var accountMax = NeteaseStore.store.string(forKey: "neteaseAccountMax") ?? "" {
        didSet { if !reloading { Self.store.set(accountMax, forKey: "neteaseAccountMax") } }
    }
    /// 网易云的设置、登录、播放进度都是每个人（个人资料）各一份：在现在在看的这个人的设置里（第一个人是原来的地方）
    private static var store: UserDefaults { ProfileSpace.current.defaults }
    /// 换了人，正在把他的设置读进来：不往回存，也不做改设置时要做的事
    private var reloading = false
    private static let order = ["standard", "higher", "exhigh", "lossless", "hires", "jyeffect", "sky", "dolby", "jymaster"]
    private static func rank(_ level: String) -> Int { order.firstIndex(of: level) ?? -1 }
    /// 这首歌（用你的账号）最高能放到哪一档。还没问到时为空
    @Published private(set) var songMax = ""

    /// 播放界面的音质栏：只列这首歌能放的档位，白色停在这首歌正在放的那一档。在这里换只管这一首，
    /// 切到下一首又按设置页里的音质来（设置页里的才是全局的）。
    /// 最好的在最左边（和哔哩哔哩的清晰度一样）：从左往右看，第一眼就是最好的
    var offered: [Quality] {
        let top = Self.rank(songMax.isEmpty ? accountMax : songMax)
        return (top < 0 ? Self.qualities : Self.qualities.filter { Self.rank($0.level) <= top }).reversed()
    }

    /// 问一次账号的上限：用一首确定有"超清母带"的歌按最高档去要，服务器给回来的那一档就是这个账号能到的最高一档
    private func probeAccountMax() async {
        let epoch = ProfileSpace.current.epoch
        guard let found = await NeteaseAPI.address(song: Self.referenceSong, level: "jymaster"),
              ProfileSpace.isCurrent(epoch) else { return }   // 问的时候换了人：那是上一个人的账号
        noteReachable(found.level)
    }
    /// 一首有超清母带的歌，只用来问账号上限
    private static let referenceSong = 2698851599

    /// 某首歌实际拿到了这一档：账号至少能到这一档
    private func noteReachable(_ level: String) {
        if Self.rank(level) > Self.rank(accountMax) { accountMax = level }
    }
    /// 设置页里的音质：全局的，每首歌都按它去要（歌或账号没有这一档，服务器给能给的最高一档）
    @Published private(set) var preferredLevel = NeteaseStore.store.string(forKey: "neteaseQuality") ?? "exhigh" {
        didSet { if !reloading { Self.store.set(preferredLevel, forKey: "neteaseQuality") } }
    }
    /// 设置页里能选的档位：知道账号上限时只列到上限（选不到的不列）。最好的在最上面
    var settableQualities: [Quality] {
        let top = Self.rank(accountMax)
        return (top < 0 ? Self.qualities : Self.qualities.filter { Self.rank($0.level) <= top }).reversed()
    }
    /// 设置页上显示、打勾的那一档：设置比账号上限还高时，实际就是上限那一档
    var effectiveLevel: String {
        Self.rank(accountMax) >= 0 && Self.rank(preferredLevel) > Self.rank(accountMax) ? accountMax : preferredLevel
    }
    /// 在播放界面的音质栏里给这一首单独选的档位（换歌就作废）
    private var songLevel: (song: Int, level: String)?
    private func level(for song: NeteaseSong) -> String {
        if let songLevel, songLevel.song == song.id { return songLevel.level }
        return preferredLevel
    }
    static func name(of level: String) -> String { qualities.first { $0.level == level }?.name ?? "" }

    // MARK: 设置页（头像菜单里进）

    /// shelf：选中网易云的图标时，主屏上方轮播什么（每日推荐、推荐歌单、我喜欢的音乐、热歌榜；见 AppShelf）
    enum Setting: CaseIterable { case quality, balance, background, resume, history, shelf }
    @Published private(set) var settingsOpen = false
    @Published private(set) var settingIndex = 0
    /// 后台播放：开着时长按 Esc 回主屏，歌接着放；关着时回主屏就像退出了应用，歌停掉，下次进来从首页开始
    @Published private(set) var backgroundPlay = NeteaseStore.store.object(forKey: "neteaseBackground") as? Bool ?? true {
        didSet { if !reloading { Self.store.set(backgroundPlay, forKey: "neteaseBackground") } }
    }
    /// 平衡音量：每首歌按网易云给的响度增益调音量，换歌时不会忽大忽小（和网易云客户端的同名设置一样）
    @Published private(set) var balanceVolume = NeteaseStore.store.object(forKey: "neteaseBalance") as? Bool ?? true {
        didSet { if !reloading { Self.store.set(balanceVolume, forKey: "neteaseBalance"); applyVolume() } }
    }
    /// 记住播放进度：下次打开时停在上次那首歌、那个位置（暂停着，按播放接着听）
    @Published private(set) var rememberProgress = NeteaseStore.store.object(forKey: "neteaseRemember") as? Bool ?? true {
        didSet {
            guard !reloading else { return }
            Self.store.set(rememberProgress, forKey: "neteaseRemember")
            if rememberProgress { saveQueue(); saveProgress() } else { Self.forgetProgress() }
        }
    }
    /// 同步听歌记录：在这里听的歌告诉网易云，手机上的"最近播放"、听歌排行、推荐都算上
    @Published private(set) var syncHistory = NeteaseStore.store.object(forKey: "neteaseHistory") as? Bool ?? true {
        didSet { if !reloading { Self.store.set(syncHistory, forKey: "neteaseHistory") } }
    }

    func isOn(_ setting: Setting) -> Bool {
        switch setting {
        case .quality: true
        case .balance: balanceVolume
        case .background: backgroundPlay
        case .resume: rememberProgress
        case .history: syncHistory
        case .shelf: true
        }
    }
    /// 接着往下放的歌，和现在放到第几首
    @Published private(set) var queue: [NeteaseSong] = []
    @Published private(set) var queueIndex = 0
    /// 播放界面按下：当前的播放列表，横着一排
    @Published private(set) var queueVisible = false
    @Published private(set) var queueFocus = 0

    enum PlayMode: String, CaseIterable {
        case list, shuffle, single
        var title: String { ["list": "列表循环", "shuffle": "随机播放", "single": "单曲循环"][rawValue] ?? "" }
        var symbol: String { ["list": "repeat", "shuffle": "shuffle", "single": "repeat.1"][rawValue] ?? "repeat" }
    }
    @Published private(set) var mode = PlayMode(rawValue: NeteaseStore.store.string(forKey: "neteaseMode") ?? "") ?? .list
    private let player = PlaybackVolume.attached(AVPlayer())   // 电视的音量调不了时，音量键调它（见 PlaybackVolume）
    private var timeObserver: Any?
    private var bag: Set<AnyCancellable> = []
    private var loginTask: Task<Void, Never>?
    private var open = false

    init() {
        NeteaseAPI.useProfile(.current)   // 登录信息是现在在看的这个人的（见 ProfileSpace）
        NeteaseShelfSource.migrateSplitLists()
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] now in
            MainActor.assumeIsolated {
                // 跳转、拖动的时候，播放器报上来的还是旧位置：这段时间不用它（不然进度条、歌词会先跳回去再跳过来）
                guard let self, self.current != nil, !self.seeking, !self.scrubbing else { return }
                let seconds = now.seconds.isFinite ? now.seconds : 0
                // 显示的秒数：播放界面开着时四分之一秒更新一次，关着时半秒
                let step = self.nowPlayingVisible ? 0.25 : 0.5
                if abs(seconds - self.clock.time) >= step || seconds < self.clock.time { self.clock.time = seconds }
                let position = seconds
                if let total = self.player.currentItem?.duration.seconds, total.isFinite, total > 0, total != self.clock.duration { self.clock.duration = total }
                self.updateLine(at: position)
                // 真正听了多久：只算一小步一小步往前走的（跳转、拖动跳过去的不算）
                let heard = seconds - self.lastHeard
                if heard > 0, heard < 1 { self.listened += heard }
                self.lastHeard = seconds
                // 记住播放进度：每放十秒记一次（只写一个数，很轻）
                if abs(seconds - self.savedAt) >= 10 { self.saveProgress() }
            }
        }
        // 退出 Mac TV 时记下放到哪了
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification).sink { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveProgress()
                self?.flushQueue()
            }
        }.store(in: &bag)
        NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification).receive(on: RunLoop.main).sink { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let song = self.current, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                Log.playback.info("netease: song stopped part way, asking for its address again")
                self.play(song, failures: 1, resumeAt: self.playbackTime())
            }
        }.store(in: &bag)
        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification).receive(on: RunLoop.main).sink { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.finishListening(finished: true)
                self.skip(1, automatic: true)
            }
        }.store(in: &bag)
        wireMediaKeys()
    }

    /// 焦点或画面变了就会变的一串字：按键音效靠它判断"这一下有没有真的动"
    var focusKey: String {
        "\(page?.list.id ?? 0)-\(page?.index ?? 0)-\(page?.button ?? -1)-\(row)-\(rows.indices.contains(row) ? column(of: rows[row]) : 0)-\(editing)-\(results != nil)"
            + "-\(nowPlayingVisible)-\(current?.id ?? 0)-\(paused)-\(qualityVisible)-\(qualityIndex)"
            + "-\(String(describing: topFocus))-\(menu?.index ?? -1)-\(menu?.items.count ?? 0)-\(queueVisible)-\(queueFocus)-\(mode.rawValue)"
            + "-\(settingsOpen)-\(settingIndex)-\(backgroundPlay)-\(balanceVolume)-\(rememberProgress)-\(syncHistory)-\(preferredLevel)"
    }

    var rows: [Row] { results ?? home }
    var row: Int { min(rowIndex, max(0, rows.count - 1)) }
    func column(of row: Row) -> Int { max(0, min(columns[row.id] ?? 0, row.items.count - 1)) }
    /// 首页（或搜索结果）里选中的那一项；在输入框里、歌单页里时没有
    var focused: Item? {
        guard !editing, page == nil, !settingsOpen, topFocus == nil, rows.indices.contains(row) else { return nil }
        let line = rows[row]
        return line.items.indices.contains(column(of: line)) ? line.items[column(of: line)] : nil
    }

    // MARK: 进出

    func opened() {
        open = true
        prepare()
    }

    private var preparing: Task<Void, Never>?
    private var loadedAt = Date.distantPast

    /// 查登录状态、取首页内容。应用一启动就在后台做一遍，所以点进来时通常已经好了；
    /// 放久了（一刻钟）再进来会在后台悄悄更新一次，不打断眼前的内容。
    private func prepare() {
        guard preparing == nil else { return }
        let epoch = ProfileSpace.current.epoch
        preparing = Task { @MainActor in
            // 中途换了人（个人资料）：这一趟是上一个人的，什么都不留（换人时已经另起一趟）
            defer { if ProfileSpace.isCurrent(epoch) { preparing = nil } }
            if account == nil {
                let found = NeteaseAPI.hasLogin ? await NeteaseAPI.account() : nil
                guard ProfileSpace.isCurrent(epoch) else { return }
                account = found
            }
            checked = true
            if account == nil { startLogin(); return }
            if needsRestore { needsRestore = false; restoreProgress() }
            if home.isEmpty || Date().timeIntervalSince(loadedAt) > 900 { await loadHome() }
        }
    }

    /// keepingScreen：回主屏、网易云留在后台（见 AppQuit）：正在放的那一页（播放界面、播放列表）留着，再点进来还是它；
    /// 只收起一时的东西（菜单、打字、音质栏、登录）
    func closed(keepingScreen: Bool = false) {
        open = false
        loginTask?.cancel()
        stopLogin()
        endScrub()   // 按住左右快进、双指拖着的时候离开：停在拖到的地方，计时器不留在后台
        endEditing()
        menu = nil
        menuParents = []
        qualityVisible = false
        guard !keepingScreen else { return }
        topFocus = nil
        nowPlayingVisible = false
        queueVisible = false
    }

    /// 后台播放关着时回主屏：像退出了应用——歌停掉，下次进来从首页最上面开始（取好的内容留着，不用重新等）
    func quit() {
        stop()
        needsRestore = true   // 下次进来像重新打开应用：停在这首歌、这个位置
        page = nil
        pageHistory = []
        settingsOpen = false
        results = nil
        query = ""
        rowIndex = 0
        columns = [:]
    }

    // MARK: 登录（在官方网页上）

    static let loginID = "netease-login"

    /// 应用启动时调用：已登录就先把账号和首页内容取好。没登录什么都不做，二维码等你进来了才取。
    func preload() {
        if NeteaseAPI.hasLogin { prepare() }
    }

    /// 进到二维码页时才调用：加载官方登录页，取它的二维码显示；同时盯着登录状态，登上了就进列表。离开时关掉。
    private func startLogin() {
        guard let tv, loginWatch == nil else { return }
        loginPage.onImage = { [weak self] image in self?.loginImage = image; self?.loginScanned = false }
        loginPage.onState = { [weak self] code in
            if code == 802 { self?.loginScanned = true }
            guard code == 800, let self else { return }
            // 二维码过期了：官方页通常会自己换一张（脚本会替它点"刷新"）。3 秒后还是原来那张，就整页重来。
            let stale = self.loginImage
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, let tv = self.tv, self.loginWatch != nil, self.loginImage === stale else { return }
                self.loginImage = nil
                self.loginPage.start(store: tv.profile.websiteDataStore, in: tv.window)
            }
        }
        loginPage.start(store: tv.profile.websiteDataStore, in: tv.window)
        loginSlow = false
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            if let self, self.loginWatch != nil, self.loginImage == nil { self.loginSlow = true }
        }
        // 登录是这个人的（他的网页数据、他的设置）：中途换了人就停，登上的不算到下一个人身上
        let epoch = ProfileSpace.current.epoch, webStore = tv.profile.websiteDataStore
        loginWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1200))
                guard let self, !Task.isCancelled, ProfileSpace.isCurrent(epoch) else { return }
                let cookies = await webStore.httpCookieStore.allCookies().filter { $0.domain.hasSuffix("163.com") }
                guard cookies.contains(where: { $0.name == "MUSIC_U" && !$0.value.isEmpty }) else { continue }
                guard NeteaseAPI.importLogin(Dictionary(cookies.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a }),
                                             epoch: epoch) else { return }
                guard let account = await NeteaseAPI.account() else { continue }
                guard ProfileSpace.isCurrent(epoch) else { return }
                self.loginWatch = nil
                self.stopLogin()
                self.account = account
                if self.open {
                    await self.loadHome()
                }
                return
            }
        }
    }

    private func stopLogin() {
        loginWatch?.cancel()
        loginWatch = nil
        loginPage.stop()
        loginImage = nil
        loginScanned = false
    }

    /// 打开网易云官方网页，你在上面自己登录（扫码或别的方式都行）；登录好了会自动回到这里
    private func openLogin() {
        guard let tv, let url = URL(string: "https://music.163.com/#/login") else { return }
        let service = Service(id: Self.loginID, name: "网易云音乐", kind: .web(url), accent: "#E60026", deep: "#2B0206")
        tv.playbackCoordinator.playWeb(service, url: url)
        loginTask?.cancel()
        let epoch = ProfileSpace.current.epoch, webStore = tv.profile.websiteDataStore
        loginTask = Task { @MainActor [weak self] in
            for _ in 0..<300 {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, let tv = self.tv, ProfileSpace.isCurrent(epoch) else { return }
                guard case .player(let service) = tv.mode, service.id == Self.loginID else { return }
                let cookies = await webStore.httpCookieStore.allCookies().filter { $0.domain.hasSuffix("163.com") }
                guard cookies.contains(where: { $0.name == "MUSIC_U" && !$0.value.isEmpty }) else { continue }
                guard NeteaseAPI.importLogin(Dictionary(cookies.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a }),
                                             epoch: epoch) else { return }
                if let account = await NeteaseAPI.account(), ProfileSpace.isCurrent(epoch) {
                    self.account = account
                    tv.returnToNetease()
                    return
                }
            }
        }
    }

    func handleInPlayer(_ command: RemoteCommand, service: Service) -> Bool {
        guard let tv, service.id == Self.loginID else { return false }
        if case .back = command { tv.returnToNetease(); return true }
        return false
    }

    /// 左上角的字标（Icons/netease-logo.png）。原图是白底黑字，放在深色页面上要处理一下：
    /// 白底变透明，黑字变白字，左边的红色图标原样保留。
    static let wordmark: NSImage? = {
        guard let url = Bundle.main.url(forResource: "netease-logo.png", withExtension: nil, subdirectory: "Icons"),
              let source = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = source.width, height = source.height
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        func isRed(_ i: Int) -> Bool { Int(pixels[i]) - Int(max(pixels[i + 1], pixels[i + 2])) > 90 }
        // 红色图标占的方框
        var left = width, right = -1, top = height, bottom = -1
        for y in 0..<height { for x in 0..<width where isRed((y * width + x) * 4) {
            left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
        } }
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            let inIcon = x >= left && x <= right && y >= top && y <= bottom
            var alpha: Double
            if inIcon {
                // 图标里的白色笔画要留着；只有红色圆形外面那一点白要去掉
                let radius = Double(right - left + 1) * 0.5
                let dx = max(Double(left) + radius - Double(x), Double(x) - (Double(right) - radius), 0)
                let dy = max(Double(top) + radius - Double(y), Double(y) - (Double(bottom) - radius), 0)
                alpha = max(0, min(1, radius - (dx * dx + dy * dy).squareRoot() + 0.5))
            } else {
                alpha = 1 - Double(min(pixels[i], pixels[i + 1], pixels[i + 2])) / 255
                pixels[i] = 255; pixels[i + 1] = 255; pixels[i + 2] = 255
            }
            pixels[i] = UInt8(Double(pixels[i]) * alpha); pixels[i + 1] = UInt8(Double(pixels[i + 1]) * alpha)
            pixels[i + 2] = UInt8(Double(pixels[i + 2]) * alpha); pixels[i + 3] = UInt8(255 * alpha)
            if alpha > 0.05 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
        } }
        guard maxX > minX, maxY > minY, let whole = context.makeImage(),
              let cropped = whole.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    }()

    private func logout() {
        stop()
        Self.forgetProgress()   // 换个账号登录时不接着放上一个账号的歌
        accountMax = ""
        NeteaseAPI.forgetLogin()
        account = nil
        home = []
        page = nil
        settingsOpen = false
        pageHistory = []
        results = nil
        query = ""
        menu = nil
        topFocus = nil
        liked = []
        myLists = []
        dailySongs = []
        recentSongs = []
        dailyLists = []
        batchLists = []
        songCache.removeAll()
        pageCache.removeAll()
        prepared.removeAll()
        preparedLyrics.removeAll()
        tv?.appShelf.reset(Self.appID)
        // 网页那边的登录也一起清掉，不然下次打开登录页会直接又登上
        let store = tv?.profile.websiteDataStore.httpCookieStore
        Task { @MainActor [weak self] in
            if let store {
                for cookie in await store.allCookies() where cookie.domain.hasSuffix("163.com") { await store.deleteCookie(cookie) }
            }
            // 清干净了马上备新的二维码
            if self?.open == true, self?.account == nil { self?.startLogin() }
        }
    }

    // MARK: 内容

    /// 首页这次摆出来的两排歌单：每日歌单（网易云的每日推荐歌单，早上 6 点换），和推荐歌单（按口味推荐那一池里
    /// 轮到的这一批，手动刷新一次往后轮一批）。主屏顶部的"每日歌单""推荐歌单"也从这里取，两边一样
    private(set) var dailyLists: [NeteasePlaylist] = []
    private(set) var batchLists: [NeteasePlaylist] = []
    /// 按口味推荐的那一池里，每批摆多少个；现在轮到第几批
    nonisolated static let picksBatch = 12
    private var picksTurn = 0

    /// 那一池里的第 turn 批（轮到头再从头来）；池子不够一批就全摆
    nonisolated static func batch(of pool: [NeteasePlaylist], turn: Int) -> [NeteasePlaylist] {
        guard pool.count > picksBatch else { return pool }
        let start = (turn * picksBatch) % pool.count
        return (0..<picksBatch).map { pool[(start + $0) % pool.count] }
    }


    /// 首页从上到下：每日推荐、每日歌单、推荐歌单、我的歌单（第一个就是"我喜欢的音乐"）、排行榜
    private func loadHome() async {
        guard let account else { return }
        let epoch = ProfileSpace.current.epoch
        loading = true
        async let daily = NeteaseAPI.daily()
        async let picks = NeteaseAPI.recommendedPlaylists()
        async let tops = NeteaseAPI.charts()
        async let hearts = NeteaseAPI.likedSongs(user: account.id)
        async let played = NeteaseAPI.recentSongs()
        let lists = await NeteaseAPI.playlists(user: account.id)
        let recommended = await daily
        // 取的时候换了人（个人资料）：这是上一个人的首页，不摆
        guard ProfileSpace.isCurrent(epoch) else { return }   // 其余几个还没回来的随之取消
        if !recommended.isEmpty { dailySongs = recommended }
        func build(_ todays: [NeteasePlaylist], _ batch: [NeteasePlaylist], _ charts: [NeteasePlaylist]) -> [Row] {
            var built: [Row] = []
            if !recommended.isEmpty { built.append(Row(id: "daily", title: "每日推荐", items: recommended.map(Item.song))) }
            if !todays.isEmpty { built.append(Row(id: "dailyLists", title: "每日歌单", items: todays.map(Item.playlist))) }
            if !batch.isEmpty { built.append(Row(id: "picks", title: "推荐歌单", items: batch.map(Item.playlist))) }
            if !lists.isEmpty || !recentSongs.isEmpty {
                built.append(Row(id: "lists", title: "我的歌单", items: (recentCard.map { [$0] } ?? []).map(Item.playlist) + lists.map(Item.playlist)))
            }
            if !charts.isEmpty { built.append(Row(id: "charts", title: "排行榜", items: charts.map(Item.playlist))) }
            return built
        }
        // 先到的先摆出来，其余几排随后补上
        if home.isEmpty { withAnimation(Motion.navigate) { home = build([], [], []) } }
        let (recommendedLists, charts, likedIDs, recent) = await (picks, tops, hearts, played)
        guard ProfileSpace.isCurrent(epoch) else { return }
        guard self.account == account else { loading = false; return }
        let batch = Self.batch(of: recommendedLists.more, turn: picksTurn)
        if !recommendedLists.daily.isEmpty || !batch.isEmpty {
            // 记一笔这次的两排和上次比变了没有（只记个数，不记内容）
            func changed(_ new: [NeteasePlaylist], _ old: [NeteasePlaylist]) -> String { new.map(\.id) == old.map(\.id) ? "same" : "changed" }
            Log.playback.info("netease home: \(recommendedLists.daily.count, privacy: .public) daily lists \(changed(recommendedLists.daily, self.dailyLists), privacy: .public), \(batch.count, privacy: .public) picks \(changed(batch, self.batchLists), privacy: .public)")
            dailyLists = recommendedLists.daily
            batchLists = batch
        }
        recentSongs = recent
        myLists = lists
        if let likedIDs { liked = likedIDs }   // 取失败就保留原来的红心，不清空
        // 正停在某一排上时，更新内容不把焦点挪走（按这一排的名字找回去）
        let built = build(dailyLists, batchLists, charts)
        // 网断了什么都没取到：留着原来的几排，不把首页清空
        if built.isEmpty, !home.isEmpty { loading = false; return }
        let focusedID = home.indices.contains(rowIndex) ? home[rowIndex].id : nil
        withAnimation(Motion.navigate) {
            home = built
            if results == nil { rowIndex = focusedID.flatMap { id in built.firstIndex { $0.id == id } } ?? 0 }
        }
        loadedAt = Date()
        loading = false
        if accountMax.isEmpty { Task { @MainActor in await probeAccountMax() } }
        for line in built { prefetchCovers(line.items.prefix(7).map(cover)) }
        // 先在后台把"我喜欢的音乐"和前面几个歌单的歌取好，点进去时直接就有
        Task { @MainActor in
            for list in lists.prefix(4) where songCache[list.id] == nil {
                let songs = await NeteaseAPI.songs(playlist: list.id)
                guard ProfileSpace.isCurrent(epoch) else { return }
                if !songs.isEmpty { songCache[list.id] = songs }
            }
        }
    }

    // MARK: 歌手页、专辑页提前取好

    /// 取过的歌手页、专辑页（头像 / 封面、名字、歌）：再进不用等。最多记 30 个，十分钟内有效
    private var pageCache: [String: (info: NeteasePlaylist, songs: [NeteaseSong], at: Date)] = [:]
    private var pageFetching: Set<String> = []
    private func pageKey(_ kind: NeteasePlaylist.Kind, _ id: Int) -> String { "\(kind)-\(id)" }

    /// 在后台把歌手页或专辑页取好，头像 / 封面也先下好：点"查看歌手""查看专辑"时一进去就有
    private func prefetchPage(_ kind: NeteasePlaylist.Kind, _ id: Int) {
        let key = pageKey(kind, id)
        guard id > 0, kind == .artist || kind == .album, !pageFetching.contains(key) else { return }
        if let cached = pageCache[key], Date().timeIntervalSince(cached.at) < 600 { return }
        pageFetching.insert(key)
        Task { @MainActor in
            defer { pageFetching.remove(key) }
            let found = kind == .artist ? await NeteaseAPI.artist(id) : await NeteaseAPI.album(id)
            guard let found else { return }
            remember(found.info, found.songs)
        }
    }

    private func remember(_ info: NeteasePlaylist, _ songs: [NeteaseSong]) {
        guard !songs.isEmpty else { return }
        pageCache[pageKey(info.kind, info.id)] = (info, songs, Date())
        if pageCache.count > 30, let oldest = pageCache.min(by: { $0.value.at < $1.value.at })?.key { pageCache[oldest] = nil }
        prefetchCovers([info.cover])
    }

    /// 一首歌的菜单打开了：它的歌手（最多三位）和专辑先在后台取着
    private func prefetchPages(of song: NeteaseSong) {
        for artist in song.artists.prefix(3) { prefetchPage(.artist, artist.id) }
        prefetchPage(.album, song.album)
    }

    /// 打开一个歌单（或歌手、专辑）。取过的直接摆出来，同时在后台更新一遍。
    private func openPlaylist(_ list: NeteasePlaylist) {
        let known = pageCache[pageKey(list.kind, list.id)]
        let cached = switch list.kind {
        case .playlist: songCache[list.id]
        case .recent: recentSongs
        case .daily: dailySongs.isEmpty ? nil : dailySongs
        default: known?.songs
        }
        var opened = Page(list: known?.info ?? list, songs: cached ?? [], loading: cached == nil)
        if let current, let index = opened.songs.firstIndex(of: current) { opened.index = index }
        withAnimation(Motion.navigate) { page = opened }
        Task { @MainActor in
            var info: NeteasePlaylist?
            var songs: [NeteaseSong] = []
            switch list.kind {
            case .playlist: songs = await NeteaseAPI.songs(playlist: list.id)
            case .artist: if let found = await NeteaseAPI.artist(list.id) { info = found.info; songs = found.songs; remember(found.info, found.songs) }
            case .album: if let found = await NeteaseAPI.album(list.id) { info = found.info; songs = found.songs; remember(found.info, found.songs) }
            case .recent:
                songs = await NeteaseAPI.recentSongs()
                if !songs.isEmpty { recentSongs = songs }
            case .daily:
                songs = await NeteaseAPI.daily()
                if !songs.isEmpty { dailySongs = songs }
            }
            guard let page, page.list.id == list.id, page.list.kind == list.kind else { return }
            if list.kind == .playlist, !songs.isEmpty { songCache[list.id] = songs }
            guard !songs.isEmpty || page.songs.isEmpty else { return }
            // 更新时选中的那一首不跳走：按歌认回去
            let keep = page.songs.indices.contains(page.index) ? page.songs[page.index] : nil
            withAnimation(Motion.navigate) {
                if let info { self.page?.list = info }
                self.page?.songs = songs
                self.page?.loading = false
                if let index = (keep ?? current).flatMap({ songs.firstIndex(of: $0) }) { self.page?.index = index }
            }
        }
    }

    /// 手机上粘贴了网易云的链接：歌直接放（进播放界面），歌单、专辑、歌手打开那一页
    func openLinked(_ kind: PhoneLink.Netease, id: Int) {
        guard account != nil else { tv?.showToast("请先登录网易云音乐"); return }
        menuParents = []
        menu = nil
        switch kind {
        case .song:
            Task { @MainActor in
                guard let song = await NeteaseAPI.song(id: id) else { tv?.showToast("无法打开这首歌"); return }
                guard open else { return }
                start(song, in: [song])
            }
        case .playlist:
            if nowPlayingVisible { withAnimation(Motion.navigate) { nowPlayingVisible = false } }
            if settingsOpen { withAnimation(Motion.navigate) { settingsOpen = false } }
            topFocus = nil
            // 先取歌单的名字和封面再翻过去，标题、背景不会先空着
            Task { @MainActor in
                let info = await NeteaseAPI.playlistInfo(id)
                openPlaylist(info ?? NeteasePlaylist(id: id, name: "歌单", kind: .playlist))
            }
        case .album:
            openWhenReady(.album, id, fallback: NeteasePlaylist(id: id, name: "", kind: .album))
        case .artist:
            openArtist(NeteaseArtist(id: id, name: ""))
        }
    }

    /// 去歌手页、专辑页之前在哪（哪个歌单页、是不是在播放界面）：返回时一层层退回去，从哪里来回到哪里
    private var pageHistory: [(page: Page?, player: Bool, settings: Bool)] = []

    func openArtist(_ artist: NeteaseArtist) {
        openWhenReady(.artist, artist.id, fallback: NeteasePlaylist(id: artist.id, name: artist.name, kind: .artist))
    }

    func openAlbum(of song: NeteaseSong) {
        guard song.album > 0 else { return }
        openWhenReady(.album, song.album, fallback: NeteasePlaylist(id: song.album, name: song.albumName, cover: song.cover, kind: .album))
    }

    /// 点了"查看歌手 / 专辑"、还没翻过去的那一次（又点了别的就作废）
    private var pendingOpen = 0

    /// 去歌手页 / 专辑页：最多等 0.6 秒，把这一页的头像 / 封面和名字取好、图下好再翻过去。翻过去就是完整的一页，
    /// 背景从上一张直接换成这一张——不然歌手头像还没取到时背景先暗下去、取到了再亮起来，看起来像闪了一下。
    /// 播放界面、菜单打开时已经在后台提前取了，多数时候不用等；0.6 秒还没好就先翻过去。
    /// 等的这一会儿如果去了别处（关了播放界面、换了页），这次就不翻了
    private func openWhenReady(_ kind: NeteasePlaylist.Kind, _ id: Int, fallback: NeteasePlaylist) {
        let from: (page: Page?, player: Bool, settings: Bool) = (page, nowPlayingVisible, settingsOpen)
        pendingOpen += 1
        let ticket = pendingOpen
        menuParents = []
        withAnimation(Motion.focus) { menu = nil }
        prefetchPage(kind, id)
        Task { @MainActor in
            let key = pageKey(kind, id)
            for _ in 0..<12 {
                if let cached = pageCache[key], cached.info.cover.map({ BiliImageCache.shared.image(for: $0) != nil }) ?? true { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard ticket == pendingOpen, page?.list.id == from.page?.list.id, page?.list.kind == from.page?.list.kind,
                  nowPlayingVisible == from.player, settingsOpen == from.settings else { return }
            pageHistory.append(from)
            leaveOverlays()
            openPlaylist(fallback)
        }
    }

    /// 从歌单页 / 歌手页 / 专辑页返回：回到进来之前的地方（播放界面、上一个歌单页、设置页，或者首页）
    private func leavePage() {
        guard let previous = pageHistory.popLast() else {
            withAnimation(Motion.navigate) { page = nil }
            return
        }
        withAnimation(Motion.navigate) {
            page = previous.page
            settingsOpen = previous.settings
            if previous.player, current != nil { nowPlayingVisible = true }
        }
    }

    /// 去歌手页、专辑页之前：菜单、播放界面这些盖在上面的都收起来
    private func leaveOverlays() {
        menuParents = []
        endEditing()
        withAnimation(Motion.navigate) {
            menu = nil
            nowPlayingVisible = false
            qualityVisible = false
            queueVisible = false
            topFocus = nil
            settingsOpen = false
        }
    }

    // MARK: 搜索

    func stopEditing() { endEditing() }

    /// Siri 键按一下：顶上的搜索选中（typing：直接开始打字，听写的字要进来）。有页面、设置盖着时不动
    func focusSearch(typing: Bool) {
        guard naming == nil, page == nil, !settingsOpen else { return }
        withAnimation(Motion.focus) {
            nowPlayingVisible = false
            topFocus = .search
            if typing { editing = true }
        }
    }

    private func endEditing() {
        guard typing else { return }
        editing = false
        if naming != nil { naming = nil; menu = nil }
        tv?.window?.makeFirstResponder(nil)
    }

    func submitSearch() {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        endEditing()
        guard !keyword.isEmpty else { return }
        lastKeyword = keyword
        loading = true
        Task { @MainActor in
            async let songs = NeteaseAPI.searchSongs(keyword)
            async let singers = NeteaseAPI.searchArtists(keyword)
            async let records = NeteaseAPI.searchAlbums(keyword)
            async let lists = NeteaseAPI.searchPlaylists(keyword)
            let (found, artists, albums, playlists) = await (songs, singers, records, lists)
            guard lastKeyword == keyword else { return }
            loading = false
            // 歌手、歌曲、专辑、歌单；搜的像是人名（最匹配的歌手名字和搜的词一样）时歌手排最前，否则歌曲在前
            let songRow = found.isEmpty ? [] : [Row(id: "search-songs", title: "歌曲", items: found.map(Item.song))]
            let artistRow = artists.isEmpty ? [] : [Row(id: "search-artists", title: "歌手", items: artists.map(Item.playlist))]
            let personFirst = artists.first.map { $0.name.localizedCaseInsensitiveCompare(keyword) == .orderedSame
                || $0.name.localizedCaseInsensitiveContains(keyword) && keyword.count >= 2 } ?? false
            var built: [Row] = personFirst ? artistRow + songRow : songRow + artistRow
            if !albums.isEmpty { built.append(Row(id: "search-albums", title: "专辑", items: albums.map(Item.playlist))) }
            if !playlists.isEmpty { built.append(Row(id: "search-lists", title: "歌单", items: playlists.map(Item.playlist))) }
            guard !built.isEmpty else { tv?.showToast("没有找到「\(keyword)」"); return }
            for id in ["search-songs", "search-artists", "search-albums", "search-lists"] { columns[id] = 0 }
            withAnimation(Motion.navigate) { results = built; rowIndex = 0; topFocus = nil }
        }
    }

    // MARK: 按键

    func handle(_ command: RemoteCommand) {
        if naming != nil {
            switch command {
            case .select: submitName()
            case .text(let text): newName += text
            case .deleteBackward: if !newName.isEmpty { newName.removeLast() }
            case .back:
                withAnimation(Motion.focus) { naming = nil }
                tv?.window?.makeFirstResponder(nil)
            default: break
            }
            return
        }
        if menu != nil { handleMenu(command); return }
        if nowPlayingVisible { handleNowPlaying(command); return }
        guard account != nil else {
            // 二维码页上按确认不做任何事；只有二维码一直取不到时，才用确认键去官方网页登录
            if case .select = command, checked, loginSlow, loginImage == nil { openLogin() }
            return
        }
        if editing {
            switch command {
            case .select: submitSearch()
            case .text(let text): query += text
            case .deleteBackward: if !query.isEmpty { query.removeLast() }
            case .back, .move(.down): withAnimation(Motion.focus) { endEditing() }
            default: break
            }
            return
        }
        if topFocus != nil { handleTop(command); return }
        if settingsOpen { handleSettings(command); return }
        if page != nil { handlePage(command); return }
        switch command {
        case .move(.left): setColumn(-1)
        case .move(.right): setColumn(1)
        case .move(.up):
            if row > 0 { withAnimation(Motion.navigate) { rowIndex = row - 1 } }
            else { withAnimation(Motion.focus) { topFocus = topItems.first } }   // 最上面一排再按上：到顶上那一排
        case .move(.down): if row < rows.count - 1 { withAnimation(Motion.navigate) { rowIndex = row + 1 } }
        case .select: activate()
        case .playPause: playPauseHere()
        case .back:
            // 在搜索结果里：Esc 回到首页；首页就是最上一层：回主屏，网易云留在后台（见 AppQuit）
            if results != nil { withAnimation(Motion.navigate) { results = nil; query = ""; rowIndex = 0 } }
            else { tv?.goHome() }
        default: break
        }
    }

    /// 顶上那一排：左右换，确认才进去，下（或返回）回到内容
    private func handleTop(_ command: RemoteCommand) {
        guard let focus = topFocus else { return }
        let items = topItems
        let index = items.firstIndex(of: focus) ?? 0
        switch command {
        case .move(.left): if index > 0 { withAnimation(Motion.focus) { topFocus = items[index - 1] } }
        case .move(.right): if index < items.count - 1 { withAnimation(Motion.focus) { topFocus = items[index + 1] } }
        case .move(.down), .back: withAnimation(Motion.focus) { topFocus = nil }
        case .select: activateTop(focus)
        case .playPause: playPauseHere()
        default: break
        }
    }

    private func activateTop(_ item: TopItem) {
        switch item {
        case .player: if current != nil { withAnimation(Motion.navigate) { nowPlayingVisible = true } }
        case .search: withAnimation(Motion.focus) { editing = true }
        case .account:
            prefetchCovers([account?.largeAvatar])   // 设置页的大头像先下好，进去时不用等
            menuParents = []
            withAnimation(Motion.focus) {
                menu = Menu(anchor: .account, items: [MenuItem(symbol: "arrow.clockwise", title: "刷新", action: .refresh),
                                                      MenuItem(symbol: "gearshape", title: "设置", action: .openSettings),
                                                      MenuItem(symbol: "rectangle.portrait.and.arrow.right", title: "退出登录", action: .logout)])
            }
        }
    }

    // MARK: 设置页

    /// 设置页：上下选，确认改（音质弹出一列档位，后台播放直接开 / 关），返回回到头像上
    private func handleSettings(_ command: RemoteCommand) {
        let count = Setting.allCases.count
        switch command {
        case .move(.up):
            if settingIndex > 0 { withAnimation(Motion.focus) { settingIndex -= 1 } }
            else if current != nil { withAnimation(Motion.focus) { topFocus = .player } }
        case .move(.down): if settingIndex < count - 1 { withAnimation(Motion.focus) { settingIndex += 1 } }
        case .select: activateSetting(settingIndex)
        case .playPause: playPauseHere()
        case .back:
            withAnimation(Motion.navigate) { settingsOpen = false }
            withAnimation(Motion.focus) { topFocus = .account }   // 从头像进来的，回到头像上
        default: break
        }
    }

    private func openSettings() {
        menuParents = []
        withAnimation(Motion.focus) { menu = nil; topFocus = nil }
        settingIndex = 0
        withAnimation(Motion.navigate) { settingsOpen = true }
    }

    func activateSetting(_ index: Int) {
        guard settingsOpen, Setting.allCases.indices.contains(index) else { return }
        settingIndex = index
        topFocus = nil
        switch Setting.allCases[index] {
        case .quality:
            // 一列档位，勾着现在的那一档，打开时就停在它上面
            let options = settableQualities
            let chosen = effectiveLevel
            menuParents = []
            withAnimation(Motion.focus) {
                menu = Menu(anchor: .setting,
                            items: options.map { MenuItem(symbol: $0.level == chosen ? "checkmark" : "", title: $0.name, action: .setQuality($0.level)) },
                            index: options.firstIndex { $0.level == chosen } ?? 0)
            }
        case .balance: withAnimation(Motion.focus) { balanceVolume.toggle() }
        case .background: withAnimation(Motion.focus) { backgroundPlay.toggle() }
        case .resume: withAnimation(Motion.focus) { rememberProgress.toggle() }
        case .history: withAnimation(Motion.focus) { syncHistory.toggle() }
        case .shelf:
            // 多选：勾着的是现在放的几种；按确认勾上 / 取消，菜单留着，返回才收起
            menuParents = []
            withAnimation(Motion.focus) {
                menu = Menu(anchor: .setting, items: shelfMenuItems(), index: 0)
            }
        }
    }

    /// 设置页里换了音质：以后每首都按它来；正在放的这首也马上换过去（新的准备好之前旧的接着放，不断）
    private func setPreferredLevel(_ level: String) {
        preferredLevel = level
        songLevel = nil
        prepared.removeAll()   // 提前取好的下一首是按旧设置要的
        guard let current else { return }
        // 这首按新设置会拿到哪一档：它有的档位里，不超过设置的最高一档
        let expected = songMax.isEmpty ? level : (offered.first { Self.rank($0.level) <= Self.rank(level) }?.level ?? level)
        if expected != actualLevel { play(current, resumeAt: playbackTime()) }
        prepareNext()
    }

    /// 触控板点顶上那一排
    func tapTop(_ item: TopItem) {
        guard account != nil, !nowPlayingVisible, menu == nil, topItems.contains(item) else { return }
        endEditing()
        topFocus = item
        activateTop(item)
    }

    /// 歌单页。右边：上下选歌，确认播放（整个歌单接着往下放）。按左到左边那一排按钮（播放、随机播放、收藏），
    /// 在按钮上左右换，最右边再按右回到歌曲。返回回到首页。
    private func handlePage(_ command: RemoteCommand) {
        guard let page else { return }
        if let button = page.button {
            let count = pageButtons.count
            switch command {
            // 按钮是横着一排：左右换，最右边再按右回到歌曲
            case .move(.left): if button > 0 { withAnimation(Motion.focus) { self.page?.button = button - 1 } }
            case .move(.right):
                if button < count - 1 { withAnimation(Motion.focus) { self.page?.button = button + 1 } }
                else if !page.songs.isEmpty { withAnimation(Motion.focus) { self.page?.button = nil } }
            case .move(.up): if current != nil { withAnimation(Motion.focus) { topFocus = .player } }
            case .select: pressPageButton(button)
            case .playPause: playPauseHere()
            case .back: leavePage()
            default: break
            }
            return
        }
        switch command {
        case .move(.up):
            if page.index > 0 { withAnimation(stepMotion()) { self.page?.index = page.index - 1 } }
            else if current != nil { withAnimation(Motion.focus) { topFocus = .player } }
        case .move(.down): if page.index < page.songs.count - 1 { withAnimation(stepMotion()) { self.page?.index = page.index + 1 } }
        case .move(.left): withAnimation(Motion.focus) { self.page?.button = 0 }
        case .select:
            guard page.songs.indices.contains(page.index) else { return }
            start(page.songs[page.index], in: page.songs)
        case .playPause: playPauseHere()
        case .back: leavePage()
        default: break
        }
    }

    enum PageButton { case play, shuffle, subscribe }
    /// 自己建的歌单没有"收藏"这个按钮
    var pageButtons: [PageButton] {
        guard let page else { return [] }
        let mine = page.list.creator != 0 && page.list.creator == account?.id
        return page.list.kind != .playlist || mine ? [.play, .shuffle] : [.play, .shuffle, .subscribe]
    }
    func subscribed(_ list: NeteasePlaylist) -> Bool { myLists.contains { $0.id == list.id } }

    func pressPageButton(_ index: Int) {
        guard let page, pageButtons.indices.contains(index), !page.songs.isEmpty || pageButtons[index] == .subscribe else { return }
        self.page?.button = index
        switch pageButtons[index] {
        case .play:
            setMode(mode == .shuffle ? .list : mode)
            restart(page.songs[0], in: page.songs)
        case .shuffle:
            setMode(.shuffle)
            restart(page.songs.randomElement() ?? page.songs[0], in: page.songs)
        case .subscribe:
            if subscribed(page.list) {
                menuParents = []
                confirm("取消收藏「\(page.list.name)」？", "取消收藏", symbol: "star.slash", .confirmUnsubscribe(page.list), anchor: .pageButton)
            } else {
                toggleSubscribed(page.list)
            }
        }
    }

    /// 空格：就在当前界面放或停，不进播放界面（回车才进）。
    /// 选中的是一首没在放的歌，就从它开始放；选中的是歌单而现在什么都没放，就放这个歌单；其余都是暂停 / 继续。
    private func playPauseHere() {
        if nowPlayingVisible || topFocus != nil { if current != nil { togglePause() }; return }
        if let page, page.button == nil, page.songs.indices.contains(page.index) {
            let song = page.songs[page.index]
            if song != current { start(song, in: page.songs, show: false); return }
        } else if page == nil, case .song(let song)? = focused, song != current {
            start(song, in: rows[row].items.compactMap { item -> NeteaseSong? in if case .song(let s) = item { return s } else { return nil } }, show: false)
            return
        } else if page == nil, current == nil, case .playlist(let list)? = focused {
            Task { @MainActor in
                var songs = songCache[list.id] ?? []
                if songs.isEmpty { songs = await NeteaseAPI.songs(playlist: list.id) }
                if open, let first = songs.first, current == nil { start(first, in: songs, show: false); queueSource = list.id }
            }
            return
        }
        if current != nil { togglePause() }
    }

    private func handleNowPlaying(_ command: RemoteCommand) {
        if qualityVisible {
            switch command {
            case .move(.left): withAnimation(Motion.focus) { qualityIndex = max(0, qualityIndex - 1) }
            case .move(.right): withAnimation(Motion.focus) { qualityIndex = min(offered.count - 1, qualityIndex + 1) }
            case .select:
                guard offered.indices.contains(qualityIndex), let current else { return }
                let chosen = offered[qualityIndex].level
                withAnimation(Motion.navigate) { qualityVisible = false }
                // 只管这一首：设置页里的全局音质不动，下一首还按设置来
                guard chosen != actualLevel else { return }
                songLevel = (current.id, chosen)
                play(current, resumeAt: playbackTime())   // 这首按选的档位重新要一次，从现在的位置接着放
            // 音质栏是往下拉出来的：往上推回去（或返回）才收起；再往下拉不动
            case .back, .move(.down): withAnimation(Motion.navigate) { qualityVisible = false }
            default: break
            }
            return
        }
        if queueVisible {
            switch command {
            case .move(.left): withAnimation(stepMotion()) { queueFocus = max(0, queueFocus - 1) }
            case .move(.right): withAnimation(stepMotion()) { queueFocus = min(queue.count - 1, queueFocus + 1) }
            case .select:
                withAnimation(Motion.navigate) { queueVisible = false }
                if queue.indices.contains(queueFocus), queueFocus != queueIndex {
                    queueIndex = queueFocus
                    play(queue[queueIndex])
                }
            case .back, .move(.up): withAnimation(Motion.navigate) { queueVisible = false }
            case .playPause: togglePause()
            default: break
            }
            return
        }
        switch command {
        case .select, .playPause: togglePause()
        case .move(.left): skip(-1)
        case .move(.right): skip(1)
        case .move(.up):
            // 上：音质。停在现在用的那一档上
            // 打开时停在这首歌正在放的那一档上：只是看一眼再按确认，什么都不会变
            qualityIndex = offered.firstIndex { $0.level == actualLevel } ?? 0
            withAnimation(Motion.navigate) { qualityVisible = true }
        case .move(.down):
            // 下：当前的播放列表
            guard queue.count > 1 else { return }
            queueFocus = queueIndex
            withAnimation(Motion.navigate) { queueVisible = true }
        case .seek(let forward): seek(by: forward ? 10 : -10)
        case .back: withAnimation(Motion.navigate) { nowPlayingVisible = false }
        default: break
        }
    }

    private var lastStep = Date.distantPast

    /// 单按一下用平常那条动画；按住方向键连续走时，换一条更短、更跟手的，
    /// 不然每一下都重新起一段弹簧、上一段还没走完就被接上，速度忽快忽慢
    private func stepMotion() -> Animation {
        let now = Date()
        defer { lastStep = now }
        return now.timeIntervalSince(lastStep) < 0.2 ? .smooth(duration: 0.16) : Motion.focus
    }

    private func setColumn(_ delta: Int) {
        guard rows.indices.contains(row) else { return }
        let line = rows[row]
        let next = max(0, min(line.items.count - 1, column(of: line) + delta))
        guard next != column(of: line) else { return }
        withAnimation(stepMotion()) { columns[line.id] = next }
        prefetchCovers(line.items.dropFirst(next + 1).prefix(12).map(cover))   // 甩着翻会一下走好几张：多备几张
    }

    func focus(row r: Int, column c: Int) {
        guard rows.indices.contains(r) else { return }
        endEditing()
        withAnimation(Motion.focus) { topFocus = nil; rowIndex = r; columns[rows[r].id] = c }
    }

    /// 触控板点歌单页里的某一首
    func tapSong(_ index: Int) {
        guard let page, page.songs.indices.contains(index) else { return }
        self.page?.index = index
        self.page?.button = nil
        start(page.songs[index], in: page.songs)
    }

    func activate() {
        guard let item = focused else { return }
        switch item {
        case .song(let song):
            start(song, in: rows[row].items.compactMap { item -> NeteaseSong? in if case .song(let s) = item { return s } else { return nil } })
        case .playlist(let list):
            pageHistory.removeAll()   // 从首页进的：返回就是回首页
            openPlaylist(list)
        }
    }

    // MARK: 鼠标 / 触控板点击（播放界面）

    func tapPlayPause() { if current != nil { togglePause() } }

    /// 点进度条下面的音质：音质栏从上面滑下来（和在播放界面按上键一样）
    func openQualityBar() {
        guard nowPlayingVisible, current != nil, !qualityVisible else { return }
        if queueVisible { withAnimation(Motion.navigate) { queueVisible = false } }
        handleNowPlaying(.move(.up))
    }

    func seek(toFraction fraction: Double) {
        guard duration > 0 else { return }
        seek(by: max(0, min(1, fraction)) * duration - time)
    }

    /// 点某句歌词跳到那句
    func seek(toTime target: Double) {
        guard duration > 0 else { return }
        jump(to: max(0, min(duration - 1, target)))
    }

    // MARK: 鼠标：点一下 = 选中并打开；按住半秒 = 菜单；翻页用双指上下左右滑（和方向键一样）。
    // 鼠标停在哪里都不改选中，只是轻轻浮起（以前停着也会选，选中一张整排就滑，鼠标底下换成下一张又被选中，一路往一边跑）。
    // 只有弹出的菜单和音质栏跟着鼠标高亮：它们不会滚动

    /// 按住卡片半秒：选中它、弹出它的菜单（和长按确认一样）
    func longPressCard(row r: Int, column c: Int) {
        guard menu == nil else { return }
        focus(row: r, column: c)
        openCardMenu()
    }

    /// 按住歌单页里的一首半秒：选中它、弹出菜单
    func longPressSong(_ index: Int) {
        guard menu == nil, let page, page.songs.indices.contains(index) else { return }
        topFocus = nil
        self.page?.button = nil
        withAnimation(Motion.focus) { self.page?.index = index }
        openCardMenu()
    }

    /// 鼠标移到菜单的某一项：白色高亮滑过去（菜单不会滚动，可以跟着鼠标走）
    func hoverMenu(_ index: Int) {
        guard let menu, menu.items.indices.contains(index), menu.index != index, naming == nil else { return }
        withAnimation(Motion.focus) { self.menu?.index = index }
    }

    func hoverQuality(_ index: Int) {
        guard qualityVisible, offered.indices.contains(index), qualityIndex != index else { return }
        withAnimation(Motion.focus) { qualityIndex = index }
    }

    func tapQuality(_ index: Int) {
        guard qualityVisible, offered.indices.contains(index) else { return }
        qualityIndex = index
        handleNowPlaying(.select)
    }

    func tapQueue(_ index: Int) {
        guard queueVisible, queue.indices.contains(index) else { return }
        queueFocus = index
        handleNowPlaying(.select)
    }

    // MARK: 菜单

    private func songItems(_ song: NeteaseSong, withMode: Bool) -> [MenuItem] {
        prefetchPages(of: song)   // "查看歌手""查看专辑"点进去时不用等
        let on = liked.contains(song.id)
        var items = [MenuItem(symbol: on ? "heart.fill" : "heart", title: on ? "取消喜欢" : "喜欢", action: .like(song)),
                     MenuItem(symbol: "text.badge.plus", title: "收藏到歌单", action: .addTo(song))]
        if !song.artists.isEmpty { items.append(MenuItem(symbol: "person.crop.circle", title: "查看歌手", action: .artist(song))) }
        if song.album > 0 { items.append(MenuItem(symbol: "square.stack", title: "查看专辑", action: .album(song))) }
        if withMode, queue.count > 1 { items.append(MenuItem(symbol: "list.bullet", title: "播放列表", action: .showQueue)) }
        if withMode { items.append(MenuItem(symbol: mode.symbol, title: mode.title, action: .cycleMode)) }
        return items
    }

    /// 长按确认时调用。返回是否真的打开了菜单（没有可弹的就还是一次普通的确认）。
    @discardableResult
    func openCardMenu() -> Bool {
        // 从顶栏的"正在播放"进的播放界面，焦点还记在顶栏上（返回时回到那里）：播放界面里不看它
        guard account != nil, menu == nil, !typing, nowPlayingVisible || topFocus == nil else { return false }
        var opened: Menu?
        if nowPlayingVisible {
            guard !qualityVisible, !queueVisible, let current else { return false }
            opened = Menu(anchor: .nowPlaying, items: songItems(current, withMode: true))
        } else if let page {
            guard page.button == nil, page.songs.indices.contains(page.index) else { return false }
            opened = Menu(anchor: .song, items: songItems(page.songs[page.index], withMode: false))
        } else if case .song(let song)? = focused {
            opened = Menu(anchor: .card, items: songItems(song, withMode: false))
        } else if case .playlist(let list)? = focused {
            // 收藏、改名、删除都只对歌单有用：专辑、歌手、最近播放没有这个菜单
            guard list.kind == .playlist else { return false }
            if list.creator != 0, list.creator == account?.id {
                // 自己建的歌单：改名、删除。"我喜欢的音乐"两样都不行
                guard list.id != myLists.first?.id else { return false }
                opened = Menu(anchor: .card, items: [MenuItem(symbol: "pencil", title: "重命名", action: .rename(list)),
                                                     MenuItem(symbol: "trash", title: "删除歌单", action: .delete(list))])
            } else {
                let on = subscribed(list)
                opened = Menu(anchor: .card, items: [MenuItem(symbol: on ? "star.fill" : "star", title: on ? "取消收藏" : "收藏歌单", action: .subscribe(list))])
            }
        }
        guard let opened else { return false }
        menuParents = []
        withAnimation(Motion.focus) { menu = opened }
        return true
    }

    /// 触控板点播放界面里的"⋯"
    func tapMore() {
        if menu != nil { menuParents = []; withAnimation(Motion.focus) { menu = nil } } else { openCardMenu() }
    }

    func tapMenu(_ index: Int) {
        guard let menu, menu.items.indices.contains(index) else { return }
        self.menu?.index = index
        handle(.select)
    }

    private func handleMenu(_ command: RemoteCommand) {
        guard let menu else { return }
        switch command {
        case .move(.up): withAnimation(Motion.focus) { self.menu?.index = max(0, menu.index - 1) }
        case .move(.down): withAnimation(Motion.focus) { self.menu?.index = min(menu.items.count - 1, menu.index + 1) }
        case .select: if menu.items.indices.contains(menu.index) { run(menu.items[menu.index].action) }
        case .back, .move(.left):
            // 退一层：里面那层回到外面那层，最外层才是关掉
            withAnimation(Motion.focus) { self.menu = menuParents.popLast() }
        default: break
        }
    }

    private func run(_ action: MenuAction) {
        switch action {
        case .like(let song):
            let on = !liked.contains(song.id)
            menuParents = []
            withAnimation(Motion.focus) { menu = nil }
            // 先在界面上改好（"我喜欢的音乐"里当场加上或拿掉），不等服务器；服务器说失败再改回来
            setLiked(song, on)
            Task { @MainActor in
                let ok = await NeteaseAPI.setLiked(song: song.id, on)
                if !ok { setLiked(song, !on); tv?.showToast("操作失败") }
            }
        case .addTo(let song):
            // 换成一列歌单让你挑：只有自己建的歌单能往里加歌（"我喜欢的音乐"走上面的"喜欢"）
            let mine = myLists.dropFirst().filter { $0.creator == account?.id }
            let anchor = menu?.anchor ?? .card
            if let menu { menuParents.append(menu) }
            withAnimation(Motion.focus) {
                menu = Menu(anchor: anchor, items: [MenuItem(symbol: "plus", title: "新建歌单", action: .create(song))]
                            + mine.prefix(7).map { MenuItem(symbol: "music.note.list", title: $0.name, action: .pick($0, song)) })
            }
        case .pick(let list, let song):
            withAnimation(Motion.focus) { menu = nil }
            Task { @MainActor in
                let ok = await NeteaseAPI.add(song: song.id, to: list.id)
                tv?.showToast(ok ? "已收藏到「\(list.name)」" : "操作失败")
            }
        case .create:
            newName = ""
            withAnimation(Motion.focus) { naming = action }
        case .rename(let list):
            newName = list.name
            withAnimation(Motion.focus) { naming = action }
        case .delete(let list):
            confirm("删除「\(list.name)」？", "删除", symbol: "trash", .confirmDelete(list))
        case .cancel:
            withAnimation(Motion.focus) { menu = menuParents.popLast() }
        case .confirmDelete(let list):
            menuParents = []
            withAnimation(Motion.focus) { menu = nil }
            Task { @MainActor in
                let ok = await NeteaseAPI.deletePlaylist(list.id)
                guard ok else { tv?.showToast("操作失败"); return }
                myLists.removeAll { $0.id == list.id }
                songCache[list.id] = nil
                replaceListsRow()
            }
        case .subscribe(let list):
            if subscribed(list) {
                confirm("取消收藏「\(list.name)」？", "取消收藏", symbol: "star.slash", .confirmUnsubscribe(list))
            } else {
                menuParents = []
                withAnimation(Motion.focus) { menu = nil }
                toggleSubscribed(list)
            }
        case .showQueue:
            // 和在播放界面按下键一样：当前的播放列表从下面滑上来
            menuParents = []
            withAnimation(Motion.focus) { menu = nil }
            queueFocus = queueIndex
            withAnimation(Motion.navigate) { queueVisible = true }
        case .cycleMode:
            let all = PlayMode.allCases
            setMode(all[((all.firstIndex(of: mode) ?? 0) + 1) % all.count])
            // 菜单留着，那一行换成新的模式，可以接着按
            if let current, let anchor = menu?.anchor, let index = menu?.index {
                menu = Menu(anchor: anchor, items: songItems(current, withMode: true), index: index)
            }
        case .artist(let song):
            // 只有一位歌手直接去；几位合唱的先列出来挑
            if song.artists.count == 1 {
                openArtist(song.artists[0])
            } else {
                let anchor = menu?.anchor ?? .card
                if let menu { menuParents.append(menu) }
                withAnimation(Motion.focus) {
                    menu = Menu(anchor: anchor, items: song.artists.prefix(8).map { MenuItem(symbol: "person.crop.circle", title: $0.name, action: .goArtist($0)) })
                }
            }
        case .goArtist(let artist): openArtist(artist)
        case .album(let song): openAlbum(of: song)
        case .logout:
            confirm("要退出登录吗？", "退出登录", symbol: "rectangle.portrait.and.arrow.right", .confirmLogout)
        case .confirmLogout:
            menuParents = []
            withAnimation(Motion.focus) { menu = nil }
            logout()
        case .confirmUnsubscribe(let list):
            menuParents = []
            withAnimation(Motion.focus) { menu = nil }
            toggleSubscribed(list)
        case .openSettings:
            openSettings()
        case .refresh:
            // 和哔哩哔哩头像里的"刷新"一样：首页几排（每日推荐、推荐歌单、我的歌单、排行榜）重新取一遍，
            // 推荐歌单里按口味推荐的那部分换下一批；取过的歌单、歌手页作废，再点进去拿的是最新的。
            // 取的时候原来的内容留着，不闪
            menuParents = []
            withAnimation(Motion.focus) { menu = nil }
            songCache.removeAll()
            pageCache.removeAll()
            picksTurn += 1   // 推荐歌单换一批
            let before = loadedAt
            Task { @MainActor in
                await loadHome()
                let refreshed = loadedAt > before
                if !refreshed { tv?.showToast("无法刷新，请检查网络") }
                // 推荐歌单换了一批：那一排回到最前面，第一眼就看得到换了
                if refreshed { withAnimation(Motion.navigate) { columns["picks"] = 0 } }
                // 主屏顶部的网易云那几页也跟着换成刚取的
                if refreshed { tv?.appShelf.refresh(Self.appID, force: true) }
            }
        case .setQuality(let level):
            menuParents = []
            withAnimation(Motion.focus) { menu = nil }
            if level != preferredLevel { setPreferredLevel(level) }
        case .toggleShelf(let raw) where raw == NeteaseShelfSource.nowPlayingKey:
            // 正在播放那一页：开关一下，主屏顶部马上跟着变（不用重新取歌单）
            NeteaseShelfSource.showsNowPlaying.toggle()
            withAnimation(Motion.focus) { menu?.items = shelfMenuItems() }
            objectWillChange.send()
            tv?.appShelf.nowPlayingSettingChanged()
        case .toggleShelf(let raw):
            guard let source = NeteaseShelfSource(rawValue: raw) else { return }
            var chosen = NeteaseShelfSource.selected
            if let at = chosen.firstIndex(of: source) {
                guard chosen.count > 1 else { tv?.showToast("至少选择一项"); return }   // 全取消了主屏顶部就空了
                chosen.remove(at: at)
            } else {
                chosen.append(source)
            }
            NeteaseShelfSource.selected = chosen
            withAnimation(Motion.focus) { menu?.items = shelfMenuItems() }
            objectWillChange.send()
            // 连着勾好几项时只在停下来以后取一次
            shelfRefresh?.cancel()
            shelfRefresh = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
                self?.tv?.appShelf.sourceChanged("netease")
            }
        }
    }

    /// 喜欢 / 取消喜欢在界面上的样子：心形、"我喜欢的音乐"里的歌（缓存和开着的歌单页）、首页上它的歌数
    private func setLiked(_ song: NeteaseSong, _ on: Bool) {
        if on { liked.insert(song.id) } else { liked.remove(song.id) }
        guard let favorites = myLists.first else { return }
        if var songs = songCache[favorites.id] {
            songs.removeAll { $0 == song }
            if on { songs.insert(song, at: 0) }
            songCache[favorites.id] = songs
        }
        if let index = myLists.firstIndex(where: { $0.id == favorites.id }) {
            myLists[index].count = max(0, myLists[index].count + (on ? 1 : -1))
            replaceListsRow()
        }
        guard var page, page.list.id == favorites.id, page.list.kind == .playlist else { return }
        if let removed = page.songs.firstIndex(of: song) {
            page.songs.remove(at: removed)
            // 拿掉的在选中那一行上面：选中的往上挪一格，还停在原来那首歌上；拿掉的就是选中的：停在它下面那首
            if removed < page.index { page.index -= 1 }
        }
        if on { page.songs.insert(song, at: 0); page.index += page.songs.count > 1 ? 1 : 0 }
        page.index = max(0, min(page.index, page.songs.count - 1))
        page.list.count = page.songs.count
        withAnimation(Motion.focus) { self.page = page }
    }

    /// 退出登录、删除、取消收藏之前先问一次：菜单换成"取消 / 确认"两项，默认停在"取消"上，误按确认不会做。
    /// 按 Esc 或"取消"回到上一层。
    private func confirm(_ title: String, _ verb: String, symbol: String, _ action: MenuAction, anchor: MenuAnchor? = nil) {
        let anchor = anchor ?? menu?.anchor ?? .card
        if let menu { menuParents.append(menu) }
        withAnimation(Motion.focus) {
            menu = Menu(anchor: anchor, items: [MenuItem(symbol: "xmark", title: "取消", action: .cancel),
                                                MenuItem(symbol: symbol, title: verb, action: action)],
                        index: 0, title: title)
        }
    }

    /// 输入框里的名字输好了：新建歌单（并把那首歌放进去），或者给歌单改名
    func submitName() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = naming, !name.isEmpty else { return }
        withAnimation(Motion.focus) { endEditing() }
        Task { @MainActor in
            switch target {
            case .create(let song):
                guard let list = await NeteaseAPI.createPlaylist(name) else { tv?.showToast("操作失败"); return }
                let ok = await NeteaseAPI.add(song: song.id, to: list.id)
                tv?.showToast(ok ? "已收藏到「\(list.name)」" : "已创建歌单，但未能添加歌曲")
            case .rename(let list):
                let ok = await NeteaseAPI.rename(playlist: list.id, to: name)
                guard ok else { tv?.showToast("操作失败"); return }
            default:
                return
            }
            await refreshMyLists()
        }
    }

    /// 我的歌单变了（新建、改名）：重新取一遍，首页那一排当场换掉
    private func refreshMyLists() async {
        guard let account else { return }
        let epoch = ProfileSpace.current.epoch
        let lists = await NeteaseAPI.playlists(user: account.id)
        guard !lists.isEmpty, ProfileSpace.isCurrent(epoch) else { return }
        myLists = lists
        replaceListsRow()
    }

    /// 首页"我的歌单"那一排换成 myLists 现在的样子（自己建的在前，收藏的在后）
    private func replaceListsRow() {
        let row = Row(id: "lists", title: "我的歌单", items: listItems)
        withAnimation(Motion.navigate) {
            if let index = home.firstIndex(where: { $0.id == "lists" }) {
                home[index] = row
            } else if let after = home.firstIndex(where: { $0.id == "picks" }) {
                home.insert(row, at: after + 1)
            } else {
                home.append(row)
            }
        }
    }

    /// 点菜单外面：收起菜单（正在输名字的话也一起收）
    func dismissMenu() {
        endEditing()
        menuParents = []
        withAnimation(Motion.focus) { menu = nil }
    }

    /// 点播放界面上面的空白处：收起音质栏、播放列表
    func dismissPanels() {
        withAnimation(Motion.navigate) { qualityVisible = false; queueVisible = false }
    }

    private func toggleSubscribed(_ list: NeteasePlaylist) {
        let on = !subscribed(list)
        Task { @MainActor in
            let ok = await NeteaseAPI.setSubscribed(playlist: list.id, on)
            guard ok else { tv?.showToast("操作失败"); return }
            // 收藏的歌单也放进"我的歌单"，当场就出现（排在自己建的后面）
            if on { myLists.append(list) } else { myLists.removeAll { $0.id == list.id } }
            replaceListsRow()
        }
    }

    // MARK: 播放

    private func setMode(_ value: PlayMode) {
        mode = value
        Self.store.set(value.rawValue, forKey: "neteaseMode")
    }

    /// 放这首歌，songs 是接着往下放的队列。已经在放这一首的话，只是回到播放界面。
    /// show：要不要打开播放界面（回车打开，空格不打开）
    /// 从头放这一串（"播放全部""随机播放"）：正在放的那首先记进听歌记录，再换（就算是同一首也从头来）
    private func restart(_ song: NeteaseSong, in songs: [NeteaseSong]) {
        if current != nil { finishListening(finished: false) }
        current = nil
        start(song, in: songs)
    }

    private func start(_ song: NeteaseSong, in songs: [NeteaseSong], show: Bool = true) {
        if current != song {
            queue = songs
            upcoming = nil
            queueIndex = songs.firstIndex(of: song) ?? 0
            queueSource = if let page, page.list.kind == .playlist { page.list.id } else { 0 }
            play(song)
        } else if !show, paused {
            togglePause()
        }
        if show { withAnimation(Motion.navigate) { nowPlayingVisible = true } }
    }

    /// startPaused：恢复上次的歌，载好、停在 resumeAt 那里，不出声
    private func play(_ song: NeteaseSong, failures: Int = 0, resumeAt: Double? = nil, startPaused: Bool = false) {
        let changed = current != song
        if changed, current != nil { finishListening(finished: false) }   // 上一首切走了：听够了就记进听歌记录
        current = song
        // 换音质时保持原来的暂停 / 播放；换歌就放（恢复上次的歌时停着）
        if resumeAt == nil || startPaused { paused = startPaused }
        if !paused { tv?.startedPlaying(Self.appID) }
        if changed {
            // 上一首还在等下载的跳转作废，不会跑到这首上来
            seekCount += 1
            seeking = false
            listened = 0
            lastHeard = resumeAt ?? 0
            savedAt = resumeAt ?? 0
            clock.time = resumeAt ?? 0
            clock.duration = Double(song.duration)
            scheduleQueueSave()
            player.pause()
            lyrics = []
            lyricsSong = 0
            songMax = ""
            songLevel = nil   // 在音质栏里给上一首单独选的档位，到这首就不算了
            if nowPlayingVisible { prefetchPages(of: song) }
            lyricIndex = -1
            Task { @MainActor in
                // 下一首提前取好的歌词直接用
                var lines: [NeteaseLyricLine]
                if let ready = preparedLyrics.removeValue(forKey: song.id) { lines = ready } else { lines = await NeteaseAPI.lyrics(song: song.id) }
                guard current == song else { return }
                lyrics = lines
                lyricsSong = song.id
                updateLine(at: playbackTime())   // 停着的时候（比如刚恢复上次的歌）播放器不报时间，这里先对上
                if lyricsShown != !lines.isEmpty { withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) { lyricsShown = !lines.isEmpty } }
            }
        }
        let level = level(for: song)
        Task { @MainActor in
            // 下一首提前取好的地址（十分钟以内、同一档音质）直接用，切歌不用再等
            var found: (url: URL, level: String, gain: Double?)?
            var readyAsset: AVURLAsset?
            if resumeAt == nil, let ready = prepared.removeValue(forKey: song.id), ready.asked == level, Date().timeIntervalSince(ready.at) < 600 {
                found = (ready.url, ready.level, ready.gain)
                readyAsset = ready.asset
            } else {
                found = await NeteaseAPI.address(song: song.id, level: level)
            }
            guard current == song else { return }
            guard let found else {
                // 恢复上次的歌没成（比如刚开机还没联网）：悄悄收起，下次进来再试
                // 带回来的已听秒数留到下次恢复成功再算，这里不上报
                if startPaused { listened = 0; stop(); needsRestore = true; return }
                // 这一首放不了（版权、会员或地区）：自动跳下一首；连着三首都不行就停下来说一声
                if failures < 2, queue.count > 1, resumeAt == nil {
                    queueIndex = (queueIndex + 1) % queue.count
                    play(queue[queueIndex], failures: failures + 1)
                } else {
                    tv?.showToast("无法播放")
                    if resumeAt == nil { stop() }
                }
                return
            }
            let same = found.level == actualLevel && resumeAt != nil && player.currentItem != nil
            actualLevel = found.level
            noteReachable(found.level)
            if level == "jymaster" {
                songMax = found.level   // 要的就是最高档：服务器给回来的就是这首歌能到的最高一档，不用再问
            } else if songMax.isEmpty {
                // 设置低于最高档时，另外按最高档问一次，音质栏才知道这首歌最高能到哪
                Task { @MainActor in
                    if let top = await NeteaseAPI.address(song: song.id, level: "jymaster"), current == song {
                        songMax = top.level
                        noteReachable(top.level)
                    }
                }
            }
            if !same {
                // 文件开头先在后台读好再换上去：换的那一下界面不用等播放器
                let asset = readyAsset ?? AVURLAsset(url: found.url)
                if readyAsset == nil { _ = try? await asset.load(.isPlayable) }
                guard current == song else { return }
                let item = AVPlayerItem(asset: asset)
                // 平衡音量：新的这首一出声就是它该有的音量
                currentGain = found.gain
                applyVolume()
                if resumeAt != nil {
                    // 换音质：从换的这一刻接上（取新地址那一两秒里旧的一直在放，不倒回去重复）；恢复上次的歌：从记下的位置。
                    // 等新文件准备好再精确跳过去；跳完之前不理会播放器报上来的时间，歌词不会乱跳
                    let position = player.currentItem == nil ? (resumeAt ?? 0) : playbackTime()
                    seekCount += 1
                    let count = seekCount
                    seeking = true
                    clock.time = position
                    player.replaceCurrentItem(with: item)
                    for _ in 0..<100 where item.status == .unknown { try? await Task.sleep(for: .milliseconds(50)) }
                    if position > 0.5 {
                        await player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                    if count == seekCount { seeking = false }
                    guard current == song else { return }
                    updateLine(at: position)
                } else {
                    player.replaceCurrentItem(with: item)
                }
            }
            if !paused { player.play() }
            publishNowPlaying()
            if resumeAt == nil || startPaused { prepareNext() } else { realignWhenBuffered() }
        }
    }

    // MARK: 听歌记录

    /// 这一首真正听了多少秒（跳过去的不算），和上一次看到的位置
    private var listened = 0.0
    private var lastHeard = 0.0
    /// 现在这个播放列表是从哪个歌单放的（上报时带上；不是歌单为 0）
    private var queueSource = 0

    /// 这首不听了（放完、切走、停掉）：听够了（30 秒，或者短歌的一半）就告诉网易云，
    /// 成功了首页"最近播放"那张卡片也当场换成这首
    private func finishListening(finished: Bool) {
        defer { listened = 0 }
        guard syncHistory, account != nil, let song = current else { return }
        let seconds = Int(listened.rounded())
        guard seconds >= Self.reportThreshold(duration: song.duration) else { return }
        let source = queueSource
        // 用现在这个人的登录信息报：换人时停下的那一首，报到听它的人的账号上（不是下一个人的）
        let login = NeteaseAPI.login
        Task { @MainActor in
            let ok = await NeteaseAPI.$pinned.withValue(login) {
                await NeteaseAPI.reportPlay(song: song.id, seconds: seconds, finished: finished, playlist: source)
            }
            Log.playback.info("网易云听歌记录：听了 \(seconds, privacy: .public) 秒（\(finished ? "放完" : "切走", privacy: .public)），上报\(ok ? "成功" : "失败", privacy: .public)")
            guard ok, NeteaseAPI.isCurrent(login) else { return }
            guard !recentSongs.isEmpty else { return }   // 原来没有这张卡片：等下次刷新首页再出现，免得那一排突然多一张、焦点错位
            recentSongs.removeAll { $0 == song }
            recentSongs.insert(song, at: 0)
            if !home.isEmpty { replaceListsRow() }
        }
    }

    /// 听了多少秒才算听过：30 秒，短歌是一半
    static func reportThreshold(duration: Int) -> Int { max(1, min(30, duration / 2)) }

    // MARK: 记住播放进度

    /// 播放列表存成一个文件（三千首约 800 KB，在后台写），放到哪了存在设置里（每十秒写一个数）
    struct SavedQueue: Codable, Sendable { var songs: [NeteaseSong]; var index: Int; var source: Int }
    /// 第一个人的还在 Mac TV 文件夹里原来的地方；别的人的在他自己的文件夹里（Apps/netease，见 AppStorage）
    private static var queueFile: URL {
        let space = ProfileSpace.current
        let folder = space.isMain ? space.folder : space.storage(for: appID).folder
        return folder.appendingPathComponent("netease-queue.json")
    }
    private var savedAt = 0.0
    private var queueSave: Task<Void, Never>?
    /// 应用刚打开，或者上次是"退出"（后台播放关着时回主屏、去开别的应用）：进来时恢复上次的歌
    private var needsRestore = true

    private func saveProgress() {
        guard rememberProgress, let current, player.currentItem != nil else { return }   // 还没载好（恢复没成）时不写，免得把记下的位置冲掉
        let position = playbackTime()
        savedAt = position
        Self.store.set(current.id, forKey: "neteaseLastSong")
        Self.store.set(position, forKey: "neteaseLastPosition")
        // 这首已经听了多久也记着：直接退出 Mac TV 再打开，接着累计，听够了照样进听歌记录
        Self.store.set(listened, forKey: "neteaseLastListened")
    }

    /// 换歌后一秒再存播放列表：连着按下一首时只存最后一次
    private func scheduleQueueSave() {
        queueSave?.cancel()
        queueSave = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveQueue(now: false)
        }
    }

    /// 停下、退出应用前：还没存的播放列表马上存
    private func flushQueue() {
        guard queueSave != nil else { return }
        queueSave?.cancel()
        saveQueue(now: true)
    }

    /// now = false 时在后台编码、写文件（几千首的歌单也不占主线程，界面不会卡一下）
    private func saveQueue(now: Bool = true) {
        queueSave = nil
        guard rememberProgress, !queue.isEmpty, queue.indices.contains(queueIndex) else { return }
        let saved = SavedQueue(songs: queue, index: queueIndex, source: queueSource)
        let file = Self.queueFile
        let write = { @Sendable in
            guard let data = try? JSONEncoder().encode(saved) else { return }
            try? data.write(to: file, options: .atomic)
        }
        if now { write() } else { Task.detached(priority: .utility) { write() } }
    }

    static func forgetProgress() {
        try? FileManager.default.removeItem(at: queueFile)
        Self.store.removeObject(forKey: "neteaseLastSong")
        Self.store.removeObject(forKey: "neteaseLastPosition")
        Self.store.removeObject(forKey: "neteaseLastListened")
    }

    /// 上次的歌：载好、停在上次的位置，不出声。按播放（或空格、媒体键）接着听
    private func restoreProgress() {
        guard rememberProgress, current == nil, let saved = Self.savedQueue() else { return }
        let lastID = Self.store.integer(forKey: "neteaseLastSong")
        let index = saved.songs.firstIndex { $0.id == lastID } ?? min(max(0, saved.index), saved.songs.count - 1)
        let song = saved.songs[index]
        let position = Self.resumePosition(saved: song.id == lastID ? Self.store.double(forKey: "neteaseLastPosition") : 0,
                                           duration: song.duration)
        queue = saved.songs
        queueIndex = index
        queueSource = saved.source
        upcoming = nil
        Log.playback.info("网易云恢复上次的歌：列表 \(saved.songs.count, privacy: .public) 首中的第 \(index + 1, privacy: .public) 首，从 \(Int(position), privacy: .public) 秒")
        play(song, resumeAt: position, startPaused: true)
        if song.id == lastID { listened = max(0, Self.store.double(forKey: "neteaseLastListened")) }
    }

    private static func savedQueue() -> SavedQueue? {
        guard let data = try? Data(contentsOf: queueFile), let saved = try? JSONDecoder().decode(SavedQueue.self, from: data),
              !saved.songs.isEmpty else { return nil }
        return saved
    }

    /// 从哪接着放：上次差不多放完了（最后 3 秒）就从头
    static func resumePosition(saved: Double, duration: Int) -> Double {
        guard saved.isFinite, saved > 0 else { return 0 }
        return duration > 0 && saved > Double(duration) - 3 ? 0 : saved
    }

    // MARK: 平衡音量

    /// 正在放的这首要加减多少分贝（网易云给的；不知道时为 nil）
    private var currentGain: Double?
    /// 不知道增益的歌，按一首普通的歌算：实测最近听的 300 首，增益中位数约 -7 分贝
    static let typicalGain = -7.0

    /// 平衡音量下这首歌的播放器音量。播放器音量只能调小、不能调大：要往上提的（录得很轻的歌）放到原音量为止。
    /// 整体和网易云客户端开着"平衡音量"时一样响
    static func volume(forGain gain: Double?) -> Float {
        Float(pow(10, min(gain ?? typicalGain, 0) / 20))
    }

    private func applyVolume() {
        PlaybackVolume.shared.set(player, base: balanceVolume ? Self.volume(forGain: currentGain) : 1)
        Log.playback.info("网易云音量：平衡\(self.balanceVolume ? "开" : "关", privacy: .public)，增益 \(self.currentGain.map { String(format: "%.1f", $0) } ?? "未知", privacy: .public) 分贝，音量 \(String(format: "%.2f", self.player.volume), privacy: .public)")
    }

    // MARK: 下一首提前准备

    /// 下一首的播放地址、歌词、封面，在这一首开始放以后就取好；切到下一首时不用再等网易云回话
    private var prepared: [Int: (url: URL, level: String, gain: Double?, asked: String, at: Date, asset: AVURLAsset)] = [:]
    private var preparedLyrics: [Int: [NeteaseLyricLine]] = [:]
    /// 随机播放时，下一首提前挑好（这样才能提前准备）
    private var upcoming: Int?

    private func prepareNext() {
        guard queue.count > 1, mode != .single else { return }
        if mode == .shuffle, upcoming == nil {
            var next = queueIndex
            while next == queueIndex { next = Int.random(in: 0..<queue.count) }
            upcoming = next
        }
        let song = queue[mode == .shuffle ? (upcoming ?? 0) : (queueIndex + 1) % queue.count]
        let level = preferredLevel
        prefetchCovers([song.cover])
        Task { @MainActor in
            if preparedLyrics[song.id] == nil { preparedLyrics[song.id] = await NeteaseAPI.lyrics(song: song.id) }
            if prepared[song.id] == nil, let found = await NeteaseAPI.address(song: song.id, level: level) {
                // 文件开头也提前读好：切到它时换上去就能放，不用在那一刻等
                let asset = AVURLAsset(url: found.url)
                _ = try? await asset.load(.isPlayable)
                prepared[song.id] = (found.url, found.level, found.gain, level, Date(), asset)
            }
        }
    }

    /// 封面先下好放进内存：滑到它、切到它时直接就有
    func prefetchCovers(_ urls: [URL?]) {
        for case let url? in urls where BiliImageCache.shared.image(for: url) == nil {
            Task { @MainActor in _ = await BiliImageCache.shared.load(url) }
        }
    }

    private func cover(of item: Item) -> URL? {
        switch item {
        case .song(let song): song.cover
        case .playlist(let list): list.cover
        }
    }

    /// delta：+1 下一首，-1 上一首。automatic = 这首放完了自己往下走（单曲循环只在这时候起作用）。
    /// 小茗同学的"下一首""上一首"也走这里
    func skip(_ delta: Int, automatic: Bool = false) {
        guard !queue.isEmpty else { return }
        if automatic, mode == .single, current != nil {
            jump(to: 0) { [weak self] in if self?.paused == false { self?.player.play() } }
            return
        }
        if mode == .shuffle, delta > 0, queue.count > 1 {
            if let upcoming, upcoming != queueIndex, queue.indices.contains(upcoming) {
                queueIndex = upcoming
            } else {
                var next = queueIndex
                while next == queueIndex { next = Int.random(in: 0..<queue.count) }
                queueIndex = next
            }
            upcoming = nil
        } else {
            queueIndex = (queueIndex + delta + queue.count) % queue.count
        }
        play(queue[queueIndex])
        // 歌单页开着的话，选中的那一行跟着正在放的歌走
        if let page, let index = page.songs.firstIndex(of: queue[queueIndex]) { self.page?.index = index }
    }

    /// 接下来要放的几首和它们在播放列表里排第几（主屏顶部"正在播放"那一页用）：
    /// 随机播放只知道下一首（提前挑好的那首）；别的按列表往下，到头接回第一首
    func nextSongs(_ count: Int) -> [(number: Int, song: NeteaseSong)] {
        guard queue.count > 1, count > 0 else { return [] }
        if mode == .shuffle {
            guard let next = upcoming, queue.indices.contains(next) else { return [] }
            return [(next + 1, queue[next])]
        }
        return (1...min(count, queue.count - 1)).map { step in
            let at = (queueIndex + step) % queue.count
            return (at + 1, queue[at])
        }
    }

    /// 主屏上按了播放 / 暂停（网易云在后台放歌时）
    func toggleFromHome() { togglePause() }

    /// TV standby: the song pauses where it is
    func pauseIfPlaying() {
        if current != nil, !paused { togglePause() }
    }

    private func togglePause() {
        paused.toggle()
        if paused {
            player.pause()
            pausedAt = Date()
            saveProgress()
        } else if let song = current, Date().timeIntervalSince(pausedAt) > 15 * 60 {
            // 停了一刻钟以上：歌的地址大概已经过期了（只管二十分钟左右），重新要一次再从原处接着放
            play(song, resumeAt: playbackTime())
        } else {
            tv?.startedPlaying(Self.appID)   // 后台在放的书停下
            // 继续之前，先在原地精确对齐一次再放（还在暂停中做，听不出来）：无损、超清母带这类边下边放的文件，
            // 暂停后接着放时，声音和播放器报的时间可能错开，歌词就对不上了。效果和点一下歌词一样
            jump(to: playbackTime()) { [weak self] in
                if self?.paused == false { self?.player.play() }
            }
        }
        clock.time = playbackTime()
        publishNowPlaying()
    }

    /// 跳到一个还没下载到的位置时（比如切音质换了新文件），系统只能估算，声音会和报的时间错开。
    /// 等当前这一段下载好以后，在原地精确对齐一次——和点一下歌词的效果一样，歌词就跟上了
    private func realignWhenBuffered() {
        let song = current
        Task { @MainActor in
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(250))
                guard current == song, !seeking, !scrubbing, let item = player.currentItem else { return }
                let now = player.currentTime().seconds
                let ready = item.loadedTimeRanges.contains { value in
                    let range = value.timeRangeValue
                    return range.start.seconds <= now && range.end.seconds >= now + 3
                }
                if ready { jump(to: playbackTime()); return }
            }
        }
    }

    private func seek(by seconds: Double) {
        guard duration > 0 else { return }
        jump(to: max(0, min(duration - 1, playbackTime() + seconds)))
    }

    // MARK: 时间和跳转（保证歌词始终跟着声音）

    /// 正在跳转：跳完之前播放器报上来的还是旧位置，这段时间不用它
    private var seeking = false
    private var seekCount = 0

    /// 现在放到哪了（秒）。逐字歌词、进度条每一帧都直接问播放器，和声音严丝合缝——
    /// 暂停、缓冲、继续都不会多推或少推；拖动、跳转的时候用目标位置
    func playbackTime() -> Double {
        if scrubbing || seeking { return clock.time }
        let now = player.currentTime().seconds
        return now.isFinite ? now : clock.time
    }

    /// 精确跳到某一刻。FLAC（无损、超清母带）"大概跳"会和实际差好几秒：声音在 A 处，播放器却说在 B 处，
    /// 歌词就对不上了。所以一律精确跳，跳完之前不理会播放器报上来的旧位置。
    ///
    /// 跳到还没下载到的地方（双指快进、按住快进、点后面的歌词）时，系统只能按文件大小估算位置，
    /// 声音和报的时间会错开——以前要再点一下歌词才对上。现在：先停着等那一段下载好，
    /// 再在同一个位置精确跳一次，然后才出声。和"点一下歌词"是同一个效果，只是自动做、而且在出声之前做完
    private func jump(to target: Double, then: (@MainActor () -> Void)? = nil) {
        seekCount += 1
        let count = seekCount
        seeking = true
        clock.time = target
        updateLine(at: target)
        let cold = !isBuffered(target)
        if cold, player.rate > 0 { player.pause() }
        Task { @MainActor in
            let time = CMTime(seconds: target, preferredTimescale: 600)
            await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            guard count == seekCount else { return }   // 中途又跳了一次，以最后那次为准
            if cold {
                // 最多等 4 秒；网太慢等不到的话先放着，下载好以后再在原地对齐一次
                var ready = false
                for _ in 0..<32 {
                    if isBuffered(target) { ready = true; break }
                    try? await Task.sleep(for: .milliseconds(125))
                    guard count == seekCount else { return }
                }
                if ready {
                    await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                    guard count == seekCount else { return }
                }
                // 等完了按"现在该不该出声"来定（连着跳了几次、中途按了暂停、开始拖进度，都以最新的为准）
                if !paused, !scrubbing { player.play() }
                if !ready { realignWhenBuffered() }
            }
            seeking = false
            then?()
            publishNowPlaying()
        }
    }

    /// 这一刻往后两秒的声音下载好了没有
    private func isBuffered(_ seconds: Double) -> Bool {
        guard let item = player.currentItem else { return false }
        let until = min(seconds + 2, max(seconds, duration - 0.5))
        return item.loadedTimeRanges.contains { value in
            let range = value.timeRangeValue
            return range.start.seconds <= seconds + 0.05 && range.end.seconds >= until
        }
    }

    /// 唱到第几句（换句提前四分之一秒，看着正好跟上声音）
    /// 唱到第几句：只有播放界面显示歌词，它关着时不更新（不然每换一句，整个网易云的页面都要跟着重画一遍）
    private func updateLine(at seconds: Double) {
        guard nowPlayingVisible else { return }
        let line = (lyrics.lastIndex { $0.time <= seconds + 0.25 }) ?? -1
        if line != lyricIndex { lyricIndex = line }
    }

    // MARK: 拖进度条、按住左右键快进快退

    /// 正在拖 / 按住快进快退：声音先停，进度条和歌词跟着目标位置走，松手才真的跳过去，接着放
    @Published private(set) var scrubbing = false
    private var scrubTarget = 0.0
    private var scrubWasPlaying = false
    private var scrubTimer: Timer?
    private var scrubStarted = Date()

    /// 播放界面上没有别的东西开着的时候，左右键才是"切歌 / 快进快退"
    var canHoldSeek: Bool { nowPlayingVisible && current != nil && !qualityVisible && !queueVisible && menu == nil && !typing }

    func beginScrub() {
        guard current != nil, !scrubbing else { return }
        scrubWasPlaying = !paused
        scrubTarget = playbackTime()
        scrubbing = true
        player.pause()
        // 还在等下载的那次跳转作废：拖完松手时会按拖到的地方重新跳
        seekCount += 1
        seeking = false
    }

    func scrub(to seconds: Double) {
        guard scrubbing, duration > 0 else { return }
        scrubTarget = max(0, min(duration - 0.5, seconds))
        clock.time = scrubTarget
        updateLine(at: scrubTarget)
    }

    /// 双指左右滑拖进度：手指滑了 points 这么远（往右为正），进度、歌词跟着走；手指抬起时 endScrub 跳过去接着放。
    /// 一次滑多远按歌的长短算，和哔哩哔哩看视频是同一个比例
    /// 返回这一下有没有跨过一个档位（每一段响一声"嗒"）
    @discardableResult
    func scrubMove(points: Double) -> Bool {
        guard current != nil, duration > 0 else { return false }
        if !scrubbing { beginScrub() }
        let perPoint = max(0.05, min(1.0, duration / 1500))
        let before = scrubTarget
        scrub(to: scrubTarget + points * perPoint)
        return ScrubDetent.crossed(from: before, to: scrubTarget, duration: duration)
    }

    func endScrub() {
        guard scrubbing else { return }
        scrubTimer?.invalidate()
        scrubTimer = nil
        let resume = scrubWasPlaying
        jump(to: scrubTarget) { [weak self] in
            // 等下载的那几秒里又按了暂停、又开始拖，就不出声
            if resume, self?.paused == false, self?.scrubbing == false { self?.player.play() }
        }
        scrubbing = false
    }

    /// 按住左右在快进快退
    var holdSeeking: Bool { scrubTimer != nil }

    /// 测试用：当作播放界面开着、在放这首歌（不联网、不出声）
    func pretendPlaying(_ song: NeteaseSong) {
        current = song
        clock.duration = Double(song.duration)
        nowPlayingVisible = true
    }

    /// 按住左右键：快进 / 快退，按得越久越快
    func beginHold(forward: Bool) {
        guard canHoldSeek else { return }
        beginScrub()
        scrubStarted = Date()
        scrubTimer?.invalidate()
        scrubTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.scrubbing else { return }
                let held = Date().timeIntervalSince(self.scrubStarted)
                let speed = held < 1.5 ? 8.0 : (held < 4 ? 20.0 : 45.0)   // 每按住一秒，往前 / 往后走多少秒
                let before = self.scrubTarget
                self.scrub(to: self.scrubTarget + (forward ? 1 : -1) * speed * 0.05)
                // 每过一个档位"嗒"一声、震一下，和双指拖进度一样
                if ScrubDetent.crossed(from: before, to: self.scrubTarget, duration: self.duration) {
                    self.tv?.feedback.play(.move, from: .keyboard)
                }
            }
        }
    }

    func stop() {
        finishListening(finished: false)
        saveProgress()
        flushQueue()
        player.pause()
        player.replaceCurrentItem(with: nil)
        current = nil
        nowPlayingVisible = false
        qualityVisible = false
        queueVisible = false
        queue = []
        if topFocus == .player { topFocus = nil }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    /// 去开别的应用：歌停掉，下次进来恢复到这里
    func stopUntilNextVisit() {
        stop()
        needsRestore = true
    }

    // MARK: 交互区域（规则见 TVController.Module）

    func module(horizontal: Bool) -> TVController.Module {
        guard account != nil else { return .off }
        if typing { return horizontal ? .off : .drawer }
        if menu != nil { return .picker }                                          // 菜单：固定的几项
        if nowPlayingVisible {
            if qualityVisible { return horizontal ? .picker : .drawer }             // 音质栏：挑一个；上下收起
            if queueVisible { return horizontal ? .strip : .drawer }                // 播放列表：长条；往下收起
            return horizontal ? .scrub : .drawer    // 上下拉出音质栏（往下）/ 播放列表（往上）；左右拖进度（和哔哩哔哩看视频一样）
        }
        if topFocus != nil {
            // 顶栏：左右是挑一个。上下回到下面那块，和上来时方向相反（见 TVController.Module 的"一去一回"）：
            // 下面是设置项、歌单页左边的按钮（光标，往上滑上来的）→ 往下滑回去；
            // 下面是首页那几排、歌单里的歌（内容跟着手走，往下滑上来的）→ 往上滑回去
            if horizontal { return .picker }
            return settingsOpen || page?.button != nil ? .picker : .drawer
        }
        if settingsOpen { return horizontal ? .off : .picker }                  // 设置：固定的几行
        if let page {
            if page.button != nil { return .picker }                               // 左边那排按钮：挑一个；往上滑到顶栏
            return horizontal ? .picker : .strip   // 歌曲列表：竖着是长条；往左是去旁边的按钮
        }
        return horizontal ? .strip : .drawer                                        // 首页那几排：横着是长条，上下换排
    }

    /// 转盘沿着哪个方向走（见 TVController.wheelRunsHorizontally）
    var wheelRunsHorizontally: Bool {
        if menu != nil || settingsOpen { return false }                   // 菜单、设置是竖的
        if nowPlayingVisible || topFocus != nil { return true }           // 音质栏、播放列表、顶栏是横的
        if let page { return page.button != nil }                         // 歌单页：歌是竖的，左边按钮是横的
        return true                                                       // 首页那几排
    }

    /// 转盘只在焦点所在的这一排 / 这一列里走，走到头就停：不会从第一首歌转上顶栏、从按钮转进歌单、
    /// 从设置第一行转上顶栏（要去那里得按一下方向键）
    func wheelCanMove(_ direction: RemoteCommand.Direction) -> Bool {
        if typing { return false }
        if menu != nil { return true }                                         // 菜单：到头自己停
        if nowPlayingVisible { return queueVisible ? flickCanMove(direction) : true }
        if topFocus != nil { return true }                                     // 顶栏一排：到头自己停
        if settingsOpen { return direction != .up || settingIndex > 0 }
        if let page, let button = page.button {
            switch direction {
            case .left: return button > 0
            case .right: return button < pageButtons.count - 1
            default: return false
            }
        }
        return flickCanMove(direction)
    }

    /// 转盘在播放界面里快进 / 快退几秒
    func nudge(_ seconds: Double) { seek(by: seconds) }

    func flickCanMove(_ direction: RemoteCommand.Direction) -> Bool {
        guard menu == nil, !typing else { return false }
        if nowPlayingVisible {
            guard queueVisible else { return false }
            switch direction {
            case .left: return queueFocus > 0
            case .right: return queueFocus < queue.count - 1
            default: return false
            }
        }
        if let page {
            guard page.button == nil, topFocus == nil else { return false }
            switch direction {
            case .up: return page.index > 0                    // 到第一首就停，不上顶栏
            case .down: return page.index < page.songs.count - 1
            default: return false
            }
        }
        guard topFocus == nil, !settingsOpen, rows.indices.contains(row) else { return false }
        let line = rows[row]
        switch direction {
        case .left: return column(of: line) > 0
        case .right: return column(of: line) < line.items.count - 1
        default: return false
        }
    }

    /// 有没有歌在放（包括暂停着）
    var playing: Bool { current != nil }

    // MARK: 键盘上的媒体键（上一首 / 播放暂停 / 下一首）

    /// 把正在放的歌告诉系统：这样键盘上的媒体键、控制中心里的播放控件都会找到这里来
    private func publishNowPlaying() {
        guard let current else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: current.name,
            MPMediaItemPropertyArtist: current.artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: time,
            MPNowPlayingInfoPropertyPlaybackRate: paused ? 0.0 : 1.0,
        ]
        MPNowPlayingInfoCenter.default().playbackState = paused ? .paused : .playing
    }

    private func wireMediaKeys() {
        let center = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor (NeteaseStore) -> Void) {
            command.addTarget { [weak self] _ in
                Task { @MainActor in
                    // 正在看哔哩哔哩的视频时，键盘上的播放 / 暂停是给视频的，不去动后台停着的音乐
                    guard let self, self.current != nil, self.tv?.bilibiliStore.player.current == nil else { return }
                    action(self)
                }
                return .success
            }
        }
        on(center.togglePlayPauseCommand) { $0.togglePause() }
        on(center.playCommand) { if $0.paused { $0.togglePause() } }
        on(center.pauseCommand) { if !$0.paused { $0.togglePause() } }
        on(center.nextTrackCommand) { $0.skip(1) }
        on(center.previousTrackCommand) { $0.skip(-1) }
    }
}

extension TVController {
    func openNetease() {
        if mode != .launcher { goHome() }
        neteaseStore.tv = self
        sheets.closeDismissible()
        movies = nil
        neteaseOpen = true
        neteaseStore.opened()
    }

    /// 从登录页回到网易云音乐（而不是回主屏）
    func returnToNetease() {
        playbackCoordinator.closeWebPlayback()
        setMode(.launcher)
        playerFailure = nil
        neteaseOpen = true
        neteaseStore.opened()
        bringToFront()
    }

    /// 回主屏：页面收起来，再点进来还在原来的地方。设置里开着后台播放时音乐接着放（和 Apple TV 一样），关着时停在这里
    func leaveNetease() {
        guard neteaseOpen else { return }
        // 网易云留在后台，正在看的那一页（比如播放界面）留着：设置里开着后台播放时歌接着放，关着时停在这里
        neteaseStore.closed(keepingScreen: true)
        if !neteaseStore.backgroundPlay {
            neteaseStore.pauseIfPlaying()
            Log.app.notice("Paused netease on Home: its Background Playback is off")
        }
        neteaseOpen = false
    }

    /// 退出网易云（App Switcher，见 AppQuit）：页面收起来，音乐也停（下次进来停在这首歌、这个位置）
    func closeNetease() {
        neteaseStore.closed()
        if neteaseStore.playing { neteaseStore.stopUntilNextVisit() }
        neteaseOpen = false
    }
}

// MARK: 主屏顶部（见 AppShelf）

extension NeteaseStore {
    /// 主屏顶部轮播的内容：选了的每一种是一个（每日歌单、推荐歌单是几个）歌单，带着前几首歌。没登录时什么都不给，
    /// 主屏就照旧只显示网易云的颜色
    func shelfItems(_ sources: [NeteaseShelfSource]) async -> (label: String, items: [AppShelfItem]) {
        var known = self.account
        if known == nil { known = await NeteaseAPI.account() }
        guard let account = known else { return ("", []) }
        var items: [AppShelfItem] = []
        func add(_ list: NeteasePlaylist, _ songs: [NeteaseSong], tag: String, subtitle: String? = nil) {
            guard !songs.isEmpty else { return }
            let count = max(list.count, songs.count)
            items.append(AppShelfItem(id: "ne-\(list.kind)-\(list.id)", kind: .collection(list, songs: songs), title: list.name,
                                      subtitle: subtitle ?? "\(count) 首", detail: "",
                                      image: Self.large(list.cover ?? songs.first?.cover), thumbnail: list.cover ?? songs.first?.cover,
                                      avatar: nil, tag: tag))
        }
        let perGroup = NeteaseShelfSource.listsPerGroup(sources)
        var fetched: (daily: [NeteasePlaylist], more: [NeteasePlaylist])?
        for source in sources {
            switch source {
            case .daily:
                let songs = dailyIsFresh ? dailySongs : await NeteaseAPI.daily()
                if !songs.isEmpty { dailySongs = songs }
                let list = NeteasePlaylist(id: 0, name: "每日推荐", cover: songs.first?.cover, count: songs.count, kind: .daily)
                // 标签写今天的日期（大标题已经是"每日推荐"了，不重复）
                let today = Calendar.current.dateComponents([.month, .day], from: Date())
                add(list, songs, tag: "\(today.month ?? 1)月\(today.day ?? 1)日", subtitle: "根据你的口味生成 · \(songs.count) 首")
            case .liked:
                var mine = myLists.first
                if mine == nil { mine = await NeteaseAPI.playlists(user: account.id).first }
                guard let mine else { continue }
                var songs = songCache[mine.id] ?? []
                if songs.isEmpty { songs = await NeteaseAPI.songs(playlist: mine.id, limit: 20) }
                // 网易云给"我喜欢的音乐"做的封面是第一首歌的封面上叠一颗白色的心：用第一首歌原本的封面
                var liked = mine
                liked.cover = songs.first?.cover ?? mine.cover
                add(liked, songs, tag: "我的歌单")
            case .recent:
                let songs = recentSongs.isEmpty ? await NeteaseAPI.recentSongs() : recentSongs
                add(NeteasePlaylist(id: 0, name: "最近播放", cover: songs.first?.cover, count: songs.count, kind: .recent), songs, tag: "听歌记录")
            case .dailyLists, .playlists:
                // 首页取过就用首页那两排，两边一样；还没取过（没进过网易云）就取一次，两种共用
                if dailyLists.isEmpty, batchLists.isEmpty, fetched == nil { fetched = await NeteaseAPI.recommendedPlaylists() }
                let todays = dailyLists.isEmpty ? fetched?.daily ?? [] : dailyLists
                let batch = batchLists.isEmpty ? Self.batch(of: fetched?.more ?? [], turn: picksTurn) : batchLists
                let lists = Array((source == .dailyLists ? todays : batch).prefix(perGroup))
                // 各自的前几首一起取
                let songs = await withTaskGroup(of: (Int, [NeteaseSong]).self) { group in
                    for list in lists { group.addTask { (list.id, await NeteaseAPI.songs(playlist: list.id, limit: 10)) } }
                    var all: [Int: [NeteaseSong]] = [:]
                    for await (id, found) in group { all[id] = found }
                    return all
                }
                for list in lists { add(list, songs[list.id] ?? [], tag: source.title) }
            case .hot:
                let id = 3778678   // 热歌榜
                guard let list = await NeteaseAPI.playlistInfo(id) else { continue }
                add(list, await NeteaseAPI.songs(playlist: id, limit: 10), tag: "排行榜")
            }
        }
        return ("", items)
    }

    /// 主屏顶部"正在播放"那一页按了"打开网易云"：直接到播放界面
    func showNowPlaying() {
        guard current != nil else { return }
        withAnimation(Motion.navigate) { nowPlayingVisible = true }
    }

    /// 封面的大图（主屏顶部右边那张）
    static func large(_ url: URL?) -> URL? {
        guard let url else { return nil }
        return URL(string: url.absoluteString.replacingOccurrences(of: "param=500y500", with: "param=1200y1200"))
    }

    /// 在主屏顶部按了"播放"：进这个歌单（每日推荐、最近播放也当成一个歌单），从第一首放、打开播放界面。
    /// 从播放界面返回看到的就是这个歌单
    func playFromShelf(_ list: NeteasePlaylist, songs: [NeteaseSong]) {
        guard account != nil else { return }
        menuParents = []
        menu = nil
        Task { @MainActor in
            // 主屏上只带了前几首：歌单要整个放，先取全（取过的直接用）
            var queue = songs
            if list.kind == .playlist {
                if let cached = songCache[list.id], cached.count >= songs.count { queue = cached }
                else {
                    let all = await NeteaseAPI.songs(playlist: list.id)
                    if !all.isEmpty { queue = all; songCache[list.id] = all }
                }
            }
            // 取歌单的这一两秒里已经离开网易云了（回主屏、开了别的应用）：不放
            guard open, account != nil else { return }
            if list.kind == .daily, !songs.isEmpty { dailySongs = songs }
            openPlaylist(list)
            guard let first = queue.first else { tv?.showToast("此歌单没有歌曲"); return }
            start(first, in: queue)
        }
    }
}

// MARK: - 手机遥控器上的快捷键（见 RemoteShortcuts）：和菜单、顶栏里的是同一些动作

extension NeteaseStore {
    /// 登录了、没在给歌单起名字：快捷键能用
    var remoteReady: Bool { account != nil && naming == nil }

    /// 正在放的这首喜欢过
    var currentLiked: Bool { current.map { liked.contains($0.id) } ?? false }

    /// 喜欢 / 取消喜欢正在放的这首（同菜单里的"喜欢"：不用确认；没成功才说一声）
    @discardableResult
    func toggleLikeCurrent() -> Bool {
        guard remoteReady, let song = current else { return false }
        run(.like(song))
        return true
    }

    /// 歌词在播放界面里：有歌、有歌词（或者播放界面开着，可以收起）
    var canToggleNowPlaying: Bool { remoteReady && current != nil && (nowPlayingVisible || !lyrics.isEmpty) }

    /// 歌词：播放界面没开就打开（同顶栏的"正在播放"），开着就收起（同返回）。盖在上面的菜单先收起
    @discardableResult
    func toggleNowPlaying() -> Bool {
        guard canToggleNowPlaying else { return false }
        endEditing()
        menuParents = []
        withAnimation(Motion.focus) { menu = nil }
        if nowPlayingVisible {
            withAnimation(Motion.navigate) { qualityVisible = false; queueVisible = false; nowPlayingVisible = false }
        } else {
            showNowPlaying()
        }
        return true
    }

    /// 换下一种播放模式（同菜单里的那一行；换成了什么，手机上的按钮写着）。开着的菜单里有这一行的话跟着换
    @discardableResult
    func cycleModeFromRemote() -> Bool {
        guard remoteReady else { return false }
        let all = PlayMode.allCases
        setMode(all[((all.firstIndex(of: mode) ?? 0) + 1) % all.count])
        if let open = menu, open.items.contains(where: { $0.action == .cycleMode }), let current {
            menu = Menu(anchor: open.anchor, items: songItems(current, withMode: true), index: open.index)
        }
        return true
    }

    /// 打开每日推荐那一页（同从主屏顶部进来）：盖在上面的菜单、播放界面、设置先收起，返回回到首页
    @discardableResult
    func openDaily() -> Bool {
        guard remoteReady else { return false }
        leaveOverlays()
        guard page?.list.kind != .daily else { return true }
        pageHistory.removeAll()
        openPlaylist(NeteasePlaylist(id: 0, name: "每日推荐", cover: dailySongs.first?.cover, count: dailySongs.count, kind: .daily))
        return true
    }

    /// 每日推荐那一页就在最上面（上面没有菜单、播放界面、设置、顶栏）：再按一次每日推荐 = 返回（规矩见 TVController.toggle）
    func closeDaily() -> Bool {
        guard remoteReady, menu == nil, !nowPlayingVisible, !typing, topFocus == nil, !settingsOpen,
              page?.list.kind == .daily else { return false }
        leavePage()
        return true
    }

    /// 按住确认弹出的菜单（卡片、歌单里的歌、播放界面的"⋯"，连同里面的几层）开着
    var holdMenuOpen: Bool { menu.map { [.card, .song, .nowPlaying].contains($0.anchor) } ?? false }

    /// 再按住确认：把它整个收起（同返回到底、同点"⋯"）。正在给歌单起名字时不算（确认是起好了）
    func closeHoldMenu() -> Bool {
        guard holdMenuOpen, !typing else { return false }
        menuParents = []
        withAnimation(Motion.focus) { menu = nil }
        return true
    }
}

// MARK: 每个人（个人资料）各一份（见 ProfileApp）

extension NeteaseStore: ProfileApp {
    /// 新的人从这些设置开始（和第一次打开网易云一样）
    static var registeredDefaults: [String: Any] {
        ["neteaseQuality": "exhigh", "neteaseBackground": true, "neteaseBalance": true, "neteaseRemember": true,
         "neteaseHistory": true, "neteaseMode": PlayMode.list.rawValue]
    }

    /// 要换人了：在放的歌是这个人的，后台播放开着也停下；放到哪了、播放列表存进他自己那里，下次他回来接着听
    func profileWillChange() {
        shelfRefresh?.cancel()
        if current != nil { stop() } else { flushQueue() }
        needsRestore = true
    }

    /// 换了人：登录、设置、首页、缓存全换成这个人的（什么都不删，上一个人的都还在他自己那里）
    func profileChanged() {
        NeteaseAPI.useProfile(.current)
        loginTask?.cancel()
        stopLogin()
        preparing?.cancel()
        preparing = nil
        queueSave?.cancel()
        queueSave = nil
        reloadSettings()
        account = nil
        checked = false
        loading = false
        home = []
        page = nil
        pageHistory = []
        settingsOpen = false
        settingIndex = 0
        results = nil
        query = ""
        lastKeyword = ""
        editing = false
        naming = nil
        menu = nil
        menuParents = []
        topFocus = nil
        rowIndex = 0
        columns = [:]
        liked = []
        myLists = []
        dailySongs = []
        recentSongs = []
        dailyLists = []
        batchLists = []
        picksTurn = 0
        songCache.removeAll()
        pageCache.removeAll()
        pageFetching.removeAll()
        prepared.removeAll()
        preparedLyrics.removeAll()
        upcoming = nil
        songLevel = nil
        songMax = ""
        loadedAt = .distantPast
        needsRestore = true
        NeteaseShelfSource.migrateSplitLists()
        preload()
    }

    /// 这个人自己的设置（没改过的是默认的）。读进来不往回存
    private func reloadSettings() {
        let store = Self.store
        reloading = true
        defer { reloading = false }
        accountMax = store.string(forKey: "neteaseAccountMax") ?? ""
        preferredLevel = store.string(forKey: "neteaseQuality") ?? "exhigh"
        backgroundPlay = store.object(forKey: "neteaseBackground") as? Bool ?? true
        balanceVolume = store.object(forKey: "neteaseBalance") as? Bool ?? true
        rememberProgress = store.object(forKey: "neteaseRemember") as? Bool ?? true
        syncHistory = store.object(forKey: "neteaseHistory") as? Bool ?? true
        mode = PlayMode(rawValue: store.string(forKey: "neteaseMode") ?? "") ?? .list
        applyVolume()
    }
}
