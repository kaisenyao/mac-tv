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
    var topItems: [TopItem] { (current != nil ? [.player] : []) + (page == nil ? [.search, .account] : []) }

    /// 长按确认（或点"⋯"、点头像）弹出的小菜单
    enum MenuAction: Hashable {
        case like(NeteaseSong), addTo(NeteaseSong), pick(NeteasePlaylist, NeteaseSong), create(NeteaseSong)
        case subscribe(NeteasePlaylist), cycleMode, logout
        case artist(NeteaseSong), goArtist(NeteaseArtist), album(NeteaseSong)
        case rename(NeteasePlaylist), delete(NeteasePlaylist), confirmDelete(NeteasePlaylist), cancel
        case confirmLogout, confirmUnsubscribe(NeteasePlaylist)
    }
    enum MenuAnchor { case card, song, nowPlaying, account, pageButton }
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
    /// 取过的歌单里的歌：再进同一个歌单不用再等（海外到网易云每次往返要一两秒）
    private var songCache: [Int: [NeteaseSong]] = [:]
    @Published private(set) var rowIndex = 0
    @Published private(set) var columns: [String: Int] = [:]

    // 播放
    @Published private(set) var current: NeteaseSong?
    @Published private(set) var paused = false
    let clock = NeteaseClock()
    var time: Double { clock.time }
    var duration: Double { clock.duration }
    @Published private(set) var nowPlayingVisible = false
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
    @Published private(set) var accountMax = UserDefaults.standard.string(forKey: "neteaseAccountMax") ?? "" {
        didSet { UserDefaults.standard.set(accountMax, forKey: "neteaseAccountMax") }
    }
    private static let order = ["standard", "higher", "exhigh", "lossless", "hires", "jyeffect", "sky", "dolby", "jymaster"]
    private static func rank(_ level: String) -> Int { order.firstIndex(of: level) ?? -1 }
    /// 这首歌（用你的账号）最高能放到哪一档。还没问到时为空
    @Published private(set) var songMax = ""

    /// 音质栏：设置是全局的（"最高想要哪一档"，记着不变），这一排只列这首歌能放的档位，白色停在这首歌正在放的那一档。
    /// 比如设置是超清母带、这首最高只有极高：只列到极高、停在极高；切到有超清母带的歌，就停在超清母带。
    var offered: [Quality] {
        let top = Self.rank(songMax.isEmpty ? accountMax : songMax)
        return top < 0 ? Self.qualities : Self.qualities.filter { Self.rank($0.level) <= top }
    }

    /// 问一次账号的上限：用一首确定有"超清母带"的歌按最高档去要，服务器给回来的那一档就是这个账号能到的最高一档
    private func probeAccountMax() async {
        guard let found = await NeteaseAPI.address(song: Self.referenceSong, level: "jymaster") else { return }
        noteReachable(found.level)
    }
    /// 一首有超清母带的歌，只用来问账号上限
    private static let referenceSong = 2698851599

    /// 某首歌实际拿到了这一档：账号至少能到这一档
    private func noteReachable(_ level: String) {
        if Self.rank(level) > Self.rank(accountMax) { accountMax = level }
    }
    private(set) var preferredLevel: String {
        get { UserDefaults.standard.string(forKey: "neteaseQuality") ?? "exhigh" }
        set { UserDefaults.standard.set(newValue, forKey: "neteaseQuality") }
    }
    static func name(of level: String) -> String { qualities.first { $0.level == level }?.name ?? "" }
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
    @Published private(set) var mode = PlayMode(rawValue: UserDefaults.standard.string(forKey: "neteaseMode") ?? "") ?? .list
    private let player = AVPlayer()
    private var timeObserver: Any?
    private var bag: Set<AnyCancellable> = []
    private var loginTask: Task<Void, Never>?
    private var open = false

    init() {
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
            }
        }
        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification).receive(on: RunLoop.main).sink { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
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
    }

    var rows: [Row] { results ?? home }
    var row: Int { min(rowIndex, max(0, rows.count - 1)) }
    func column(of row: Row) -> Int { max(0, min(columns[row.id] ?? 0, row.items.count - 1)) }
    /// 首页（或搜索结果）里选中的那一项；在输入框里、歌单页里时没有
    var focused: Item? {
        guard !editing, page == nil, topFocus == nil, rows.indices.contains(row) else { return nil }
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
        preparing = Task { @MainActor in
            defer { preparing = nil }
            if account == nil { account = NeteaseAPI.hasLogin ? await NeteaseAPI.account() : nil }
            checked = true
            if account == nil { startLogin() }
            else if home.isEmpty || Date().timeIntervalSince(loadedAt) > 900 { await loadHome() }
        }
    }

    func closed() {
        open = false
        loginTask?.cancel()
        stopLogin()
        endEditing()
        menu = nil
        topFocus = nil
        nowPlayingVisible = false
        qualityVisible = false
        queueVisible = false
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
        loginWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1200))
                guard let self, !Task.isCancelled, let tv = self.tv else { return }
                let cookies = await tv.profile.websiteDataStore.httpCookieStore.allCookies().filter { $0.domain.hasSuffix("163.com") }
                guard cookies.contains(where: { $0.name == "MUSIC_U" && !$0.value.isEmpty }) else { continue }
                NeteaseAPI.importLogin(Dictionary(cookies.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a }))
                guard let account = await NeteaseAPI.account() else { continue }
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
        loginTask = Task { @MainActor [weak self] in
            for _ in 0..<300 {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, let tv = self.tv else { return }
                guard case .player(let service) = tv.mode, service.id == Self.loginID else { return }
                let cookies = await tv.profile.websiteDataStore.httpCookieStore.allCookies().filter { $0.domain.hasSuffix("163.com") }
                guard cookies.contains(where: { $0.name == "MUSIC_U" && !$0.value.isEmpty }) else { continue }
                NeteaseAPI.importLogin(Dictionary(cookies.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a }))
                if let account = await NeteaseAPI.account() {
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

    /// 这台 Mac 上装着的网易云音乐的应用图标（没装就没有）。直接读系统里的，不往项目里拷别人的图。
    static let appIcon: NSImage? = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.netease.163music")
        .map { NSWorkspace.shared.icon(forFile: $0.path) }

    private func logout() {
        stop()
        accountMax = ""
        NeteaseAPI.forgetLogin()
        account = nil
        home = []
        page = nil
        results = nil
        query = ""
        menu = nil
        topFocus = nil
        liked = []
        myLists = []
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

    /// 首页从上到下：每日推荐、推荐歌单、我的歌单（第一个就是"我喜欢的音乐"）、排行榜
    private func loadHome() async {
        guard let account else { return }
        loading = true
        async let daily = NeteaseAPI.daily()
        async let picks = NeteaseAPI.recommendedPlaylists()
        async let tops = NeteaseAPI.charts()
        async let hearts = NeteaseAPI.likedSongs(user: account.id)
        let lists = await NeteaseAPI.playlists(user: account.id)
        let recommended = await daily
        func build(_ suggested: [NeteasePlaylist], _ charts: [NeteasePlaylist]) -> [Row] {
            var built: [Row] = []
            if !recommended.isEmpty { built.append(Row(id: "daily", title: "每日推荐", items: recommended.map(Item.song))) }
            if !suggested.isEmpty { built.append(Row(id: "picks", title: "推荐歌单", items: suggested.map(Item.playlist))) }
            if !lists.isEmpty { built.append(Row(id: "lists", title: "我的歌单", items: lists.map(Item.playlist))) }
            if !charts.isEmpty { built.append(Row(id: "charts", title: "排行榜", items: charts.map(Item.playlist))) }
            return built
        }
        // 先到的先摆出来，其余几排随后补上
        if home.isEmpty { withAnimation(Motion.navigate) { home = build([], []) } }
        let (suggested, charts, likedIDs) = await (picks, tops, hearts)
        guard self.account == account else { loading = false; return }
        myLists = lists
        liked = likedIDs
        // 正停在某一排上时，更新内容不把焦点挪走（按这一排的名字找回去）
        let built = build(suggested, charts)
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
                if !songs.isEmpty { songCache[list.id] = songs }
            }
        }
    }

    /// 打开一个歌单（或歌手、专辑）。取过的直接摆出来，同时在后台更新一遍。
    private func openPlaylist(_ list: NeteasePlaylist) {
        let cached = list.kind == .playlist ? songCache[list.id] : nil
        var opened = Page(list: list, songs: cached ?? [], loading: cached == nil)
        if let current, let index = opened.songs.firstIndex(of: current) { opened.index = index }
        withAnimation(Motion.navigate) { page = opened }
        Task { @MainActor in
            var info: NeteasePlaylist?
            var songs: [NeteaseSong] = []
            switch list.kind {
            case .playlist: songs = await NeteaseAPI.songs(playlist: list.id)
            case .artist: if let found = await NeteaseAPI.artist(list.id) { info = found.info; songs = found.songs }
            case .album: if let found = await NeteaseAPI.album(list.id) { info = found.info; songs = found.songs }
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

    func openArtist(_ artist: NeteaseArtist) {
        leaveOverlays()
        openPlaylist(NeteasePlaylist(id: artist.id, name: artist.name, kind: .artist))
    }

    func openAlbum(of song: NeteaseSong) {
        guard song.album > 0 else { return }
        leaveOverlays()
        openPlaylist(NeteasePlaylist(id: song.album, name: song.albumName, cover: song.cover, kind: .album))
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
        }
    }

    // MARK: 搜索

    func stopEditing() { endEditing() }

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
            // 在搜索结果里：Esc 回到首页
            if results != nil { withAnimation(Motion.navigate) { results = nil; query = ""; rowIndex = 0 } }
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
            menuParents = []
            withAnimation(Motion.focus) {
                menu = Menu(anchor: .account, items: [MenuItem(symbol: "rectangle.portrait.and.arrow.right", title: "退出登录", action: .logout)])
            }
        }
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
            case .back: withAnimation(Motion.navigate) { self.page = nil }
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
        case .back: withAnimation(Motion.navigate) { self.page = nil }
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
            current = nil
            start(page.songs[0], in: page.songs)
        case .shuffle:
            setMode(.shuffle)
            current = nil
            start(page.songs.randomElement() ?? page.songs[0], in: page.songs)
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
                if let first = songs.first, current == nil { start(first, in: songs, show: false) }
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
                guard offered.indices.contains(qualityIndex) else { return }
                let chosen = offered[qualityIndex].level
                withAnimation(Motion.navigate) { qualityVisible = false }
                // 音质是全局的：选了哪档，以后每首歌都按这一档去要，歌没有就由服务器给它有的最高一档
                // 选的是这首歌的最高一档，而全局设置比它还高：设置不动（不然在一首只有极高的歌上点一下"极高"，
                // 以后有超清母带的歌也只放极高了）。选了比这首最高档还低的，才把全局设置改成它
                let isSongTop = chosen == offered.last?.level
                if !(isSongTop && Self.rank(preferredLevel) > Self.rank(chosen)) { preferredLevel = chosen }
                if chosen != actualLevel {
                    tv?.showToast("已切换至「\(Self.name(of: chosen))」")
                    if let current { play(current, resumeAt: playbackTime()) }   // 这首歌按新设置重新要一次，从现在的位置接着放
                }
            case .back, .move(.down), .move(.up): withAnimation(Motion.navigate) { qualityVisible = false }
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
            qualityIndex = offered.firstIndex { $0.level == actualLevel } ?? max(0, offered.count - 1)
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
        prefetchCovers(line.items.dropFirst(next + 1).prefix(6).map(cover))
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
        case .playlist(let list): openPlaylist(list)
        }
    }

    // MARK: 鼠标 / 触控板点击（播放界面）

    func tapPlayPause() { if current != nil { togglePause() } }

    func seek(toFraction fraction: Double) {
        guard duration > 0 else { return }
        seek(by: max(0, min(1, fraction)) * duration - time)
    }

    /// 点某句歌词跳到那句
    func seek(toTime target: Double) {
        guard duration > 0 else { return }
        jump(to: max(0, min(duration - 1, target)))
    }

    // MARK: 鼠标移到哪，焦点就到哪（屏幕上只有一个高亮）

    func hoverCard(row r: Int, column c: Int) {
        guard menu == nil, !typing, page == nil, rows.indices.contains(r) else { return }
        guard topFocus != nil || r != row || column(of: rows[r]) != c else { return }
        withAnimation(Motion.focus) { topFocus = nil; rowIndex = r; columns[rows[r].id] = c }
    }

    func hoverSong(_ index: Int) {
        guard menu == nil, !typing, let page, page.songs.indices.contains(index) else { return }
        guard topFocus != nil || page.button != nil || page.index != index else { return }
        withAnimation(Motion.focus) { topFocus = nil; self.page?.button = nil; self.page?.index = index }
    }

    func hoverPageButton(_ index: Int) {
        guard menu == nil, !typing, page != nil, pageButtons.indices.contains(index), page?.button != index || topFocus != nil else { return }
        withAnimation(Motion.focus) { topFocus = nil; page?.button = index }
    }

    func hoverQueue(_ index: Int) {
        guard queueVisible, queue.indices.contains(index), queueFocus != index else { return }
        withAnimation(Motion.focus) { queueFocus = index }
    }

    func hoverTop(_ item: TopItem) {
        guard menu == nil, !typing, !nowPlayingVisible, topItems.contains(item), topFocus != item else { return }
        withAnimation(Motion.focus) { topFocus = item }
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
        let on = liked.contains(song.id)
        var items = [MenuItem(symbol: on ? "heart.fill" : "heart", title: on ? "取消喜欢" : "喜欢", action: .like(song)),
                     MenuItem(symbol: "text.badge.plus", title: "收藏到歌单", action: .addTo(song))]
        if !song.artists.isEmpty { items.append(MenuItem(symbol: "person.crop.circle", title: "查看歌手", action: .artist(song))) }
        if song.album > 0 { items.append(MenuItem(symbol: "square.stack", title: "查看专辑", action: .album(song))) }
        if withMode { items.append(MenuItem(symbol: mode.symbol, title: mode.title, action: .cycleMode)) }
        return items
    }

    /// 长按确认时调用。返回是否真的打开了菜单（没有可弹的就还是一次普通的确认）。
    @discardableResult
    func openCardMenu() -> Bool {
        guard account != nil, menu == nil, !typing, topFocus == nil else { return false }
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
                if !ok { setLiked(song, !on) }
                tv?.showToast(ok ? (on ? "已喜欢" : "已取消喜欢") : "操作失败")
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
            confirm("退出网易云音乐？", "退出登录", symbol: "rectangle.portrait.and.arrow.right", .confirmLogout)
        case .confirmLogout:
            menuParents = []
            withAnimation(Motion.focus) { menu = nil }
            logout()
        case .confirmUnsubscribe(let list):
            menuParents = []
            withAnimation(Motion.focus) { menu = nil }
            toggleSubscribed(list)
        }
    }

    /// 新歌单的名字输好了：建歌单，把那首歌放进去
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
                tv?.showToast(ok ? "已收藏到「\(list.name)」" : "歌单建好了，但歌没放进去")
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
        let lists = await NeteaseAPI.playlists(user: account.id)
        guard !lists.isEmpty else { return }
        myLists = lists
        replaceListsRow()
    }

    /// 首页"我的歌单"那一排换成 myLists 现在的样子（自己建的在前，收藏的在后）
    private func replaceListsRow() {
        let row = Row(id: "lists", title: "我的歌单", items: myLists.map(Item.playlist))
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
            if ok {
                // 收藏的歌单也放进"我的歌单"，当场就出现（排在自己建的后面）
                if on { myLists.append(list) } else { myLists.removeAll { $0.id == list.id } }
                replaceListsRow()
            }
            tv?.showToast(ok ? (on ? "已收藏" : "已取消收藏") : "操作失败")
        }
    }

    // MARK: 播放

    private func setMode(_ value: PlayMode) {
        mode = value
        UserDefaults.standard.set(value.rawValue, forKey: "neteaseMode")
    }

    /// 放这首歌，songs 是接着往下放的队列。已经在放这一首的话，只是回到播放界面。
    /// show：要不要打开播放界面（回车打开，空格不打开）
    private func start(_ song: NeteaseSong, in songs: [NeteaseSong], show: Bool = true) {
        if current != song {
            queue = songs
            upcoming = nil
            queueIndex = songs.firstIndex(of: song) ?? 0
            play(song)
        } else if !show, paused {
            togglePause()
        }
        if show { withAnimation(Motion.navigate) { nowPlayingVisible = true } }
    }

    private func play(_ song: NeteaseSong, failures: Int = 0, resumeAt: Double? = nil) {
        let changed = current != song
        current = song
        paused = false
        if changed {
            clock.time = 0
            clock.duration = Double(song.duration)
            player.pause()
            lyrics = []
            lyricsSong = 0
            songMax = ""
            lyricIndex = -1
            Task { @MainActor in
                // 下一首提前取好的歌词直接用
                var lines: [NeteaseLyricLine]
                if let ready = preparedLyrics.removeValue(forKey: song.id) { lines = ready } else { lines = await NeteaseAPI.lyrics(song: song.id) }
                guard current == song else { return }
                lyrics = lines
                lyricsSong = song.id
                if lyricsShown != !lines.isEmpty { withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) { lyricsShown = !lines.isEmpty } }
            }
        }
        let level = preferredLevel
        Task { @MainActor in
            // 下一首提前取好的地址（十分钟以内、同一档音质）直接用，切歌不用再等
            var found: (url: URL, level: String)?
            var readyAsset: AVURLAsset?
            if resumeAt == nil, let ready = prepared.removeValue(forKey: song.id), ready.asked == level, Date().timeIntervalSince(ready.at) < 600 {
                found = (ready.url, ready.level)
                readyAsset = ready.asset
            } else {
                found = await NeteaseAPI.address(song: song.id, level: level)
            }
            guard current == song else { return }
            guard let found else {
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
                if resumeAt != nil {
                    // 换音质：从换的这一刻接上（取新地址那一两秒里旧的一直在放，不倒回去重复）。
                    // 等新文件准备好再精确跳过去；跳完之前不理会播放器报上来的时间，歌词不会乱跳
                    let position = playbackTime()
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
                } else {
                    player.replaceCurrentItem(with: item)
                }
            }
            if !paused { player.play() }
            publishNowPlaying()
            if resumeAt == nil { prepareNext() }
        }
    }

    // MARK: 下一首提前准备

    /// 下一首的播放地址、歌词、封面，在这一首开始放以后就取好；切到下一首时不用再等网易云回话
    private var prepared: [Int: (url: URL, level: String, asked: String, at: Date, asset: AVURLAsset)] = [:]
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
                prepared[song.id] = (found.url, found.level, level, Date(), asset)
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
    private func skip(_ delta: Int, automatic: Bool = false) {
        guard !queue.isEmpty else { return }
        if automatic, mode == .single, current != nil {
            jump(to: 0) { [weak self] in self?.player.play() }
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

    private func togglePause() {
        paused.toggle()
        if paused { player.pause() } else { player.play() }
        clock.time = playbackTime()
        publishNowPlaying()
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
    private func jump(to target: Double, then: (@MainActor () -> Void)? = nil) {
        seekCount += 1
        let count = seekCount
        seeking = true
        clock.time = target
        updateLine(at: target)
        Task { @MainActor in
            await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            guard count == seekCount else { return }   // 中途又跳了一次，以最后那次为准
            seeking = false
            then?()
            publishNowPlaying()
        }
    }

    /// 唱到第几句（换句提前四分之一秒，看着正好跟上声音）
    private func updateLine(at seconds: Double) {
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
    }

    func scrub(to seconds: Double) {
        guard scrubbing, duration > 0 else { return }
        scrubTarget = max(0, min(duration - 0.5, seconds))
        clock.time = scrubTarget
        updateLine(at: scrubTarget)
    }

    func endScrub() {
        guard scrubbing else { return }
        scrubTimer?.invalidate()
        scrubTimer = nil
        let resume = scrubWasPlaying
        jump(to: scrubTarget) { [weak self] in
            if resume { self?.player.play() }
        }
        scrubbing = false
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
                self.scrub(to: self.scrubTarget + (forward ? 1 : -1) * speed * 0.05)
            }
        }
    }

    func stop() {
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
                    guard let self, self.current != nil else { return }
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

    /// 回主屏：页面收起来，音乐接着放（和 Apple TV 一样）；再点进来还在原来的地方
    func leaveNetease() {
        guard neteaseOpen else { return }
        neteaseStore.closed()
        neteaseOpen = false
    }

    /// 打开别的应用：页面收起来，音乐也停
    func closeNetease() {
        neteaseStore.closed()
        neteaseStore.stop()
        neteaseOpen = false
    }
}
