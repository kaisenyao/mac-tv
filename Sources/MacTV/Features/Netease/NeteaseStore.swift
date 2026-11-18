import AVFoundation
import AppKit
import MediaPlayer
import Combine
import CoreImage
import SwiftUI

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
    /// "退出登录"按过一次了，再按一次才真的退出
    @Published private(set) var logoutArmed = false

    /// 顶上一排，从左到右：正在放的歌（有歌在放才有）、搜索、头像。最上面一排再按上到这里，
    /// 停在上面只是选中，按确认才进去。
    enum TopItem: Hashable { case player, search, account }
    @Published private(set) var topFocus: TopItem?
    var topItems: [TopItem] { (current != nil ? [.player] : []) + (page == nil ? [.search, .account] : []) }

    /// 长按确认（或点"⋯"、点头像）弹出的小菜单
    enum MenuAction: Hashable {
        case like(NeteaseSong), addTo(NeteaseSong), pick(NeteasePlaylist, NeteaseSong), create(NeteaseSong)
        case subscribe(NeteasePlaylist), cycleMode, logout
    }
    enum MenuAnchor { case card, song, nowPlaying, account }
    struct MenuItem: Hashable { let symbol: String; let title: String; let action: MenuAction }
    struct Menu { var anchor: MenuAnchor; var items: [MenuItem]; var index = 0 }
    @Published private(set) var menu: Menu?
    /// 菜单是一层一层进去的（比如"收藏到歌单"里面是一列歌单）：这里记着上一层，Esc 一次只退一层
    private var menuParents: [Menu] = []
    /// 正在给新歌单起名字（菜单里那一行变成输入框）
    @Published private(set) var naming: NeteaseSong?
    @Published var newName = ""
    /// 有输入框拿着键盘（搜索，或给新歌单起名字）
    var typing: Bool { editing || naming != nil }
    /// 输入框该拿着键盘却没拿到时加一，界面看到它变了就再去要一次
    @Published private(set) var focusRequest = 0
    func refocus() { focusRequest += 1 }

    @Published private(set) var liked: Set<Int> = []
    /// 我的歌单（自己建的和收藏的），第一个是"我喜欢的音乐"
    private(set) var myLists: [NeteasePlaylist] = []
    @Published private(set) var rowIndex = 0
    @Published private(set) var columns: [String: Int] = [:]

    // 播放
    @Published private(set) var current: NeteaseSong?
    @Published private(set) var paused = false
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
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
    /// 这首歌最高有哪一档、这个账号最高能听哪一档（还没查到时为空）
    @Published private(set) var songTop = ""
    @Published private(set) var accountTop = ""
    private static let order = ["standard", "higher", "exhigh", "lossless", "hires", "jyeffect", "sky", "dolby", "jymaster"]
    private static func rank(_ level: String) -> Int { order.firstIndex(of: level) ?? -1 }
    /// 音质栏里列出来的档位：只列这首歌真有的（还没查到就先全列）。
    /// 超清母带不看这首歌的标注：标注写着最高 Hi-Res 的歌，实际也常常能拿到超清母带。
    var offered: [Quality] {
        let top = Self.rank(songTop)
        return top < 0 ? Self.qualities : Self.qualities.filter { Self.rank($0.level) <= top || $0.level == "jymaster" }
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
                guard let self, self.current != nil else { return }
                // 界面上的时间：歌词是逐字的并且正开着播放界面时才需要这么细，其余时候半秒更新一次就够
                let seconds = now.seconds.isFinite ? now.seconds : 0
                let fine = self.nowPlayingVisible && self.lyrics.first?.words.isEmpty == false
                if fine || abs(seconds - self.time) >= 0.5 || seconds < self.time { self.time = seconds }
                let position = seconds
                if let total = self.player.currentItem?.duration.seconds, total.isFinite, total > 0 { self.duration = total }
                let line = (self.lyrics.lastIndex { $0.time <= position + 0.25 }) ?? -1
                if line != self.lyricIndex { self.lyricIndex = line }
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
            + "-\(nowPlayingVisible)-\(current?.id ?? 0)-\(paused)-\(qualityVisible)-\(qualityIndex)-\(logoutArmed)"
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
        logoutArmed = false
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
                    tv.showToast("已登录：\(account.name)")
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
                    tv.showToast("已登录：\(account.name)")
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
        NeteaseAPI.forgetLogin()
        account = nil
        home = []
        page = nil
        results = nil
        query = ""
        logoutArmed = false
        menu = nil
        topFocus = nil
        liked = []
        myLists = []
        // 网页那边的登录也一起清掉，不然下次打开登录页会直接又登上
        tv?.showToast("已退出登录")
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
    }

    private func openPlaylist(_ list: NeteasePlaylist) {
        withAnimation(Motion.navigate) { page = Page(list: list) }
        Task { @MainActor in
            let songs = await NeteaseAPI.songs(playlist: list.id)
            guard page?.list.id == list.id else { return }
            if songs.isEmpty { tv?.showToast("歌单是空的") }
            withAnimation(Motion.navigate) {
                page?.songs = songs
                page?.loading = false
                // 正在放的歌就在这个歌单里的话，直接停在它上面
                if let current, let index = songs.firstIndex(of: current) { page?.index = index }
            }
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
            async let lists = NeteaseAPI.searchPlaylists(keyword)
            let (found, playlists) = await (songs, lists)
            guard lastKeyword == keyword else { return }
            loading = false
            var built: [Row] = []
            if !found.isEmpty { built.append(Row(id: "search-songs", title: "歌曲", items: found.map(Item.song))) }
            if !playlists.isEmpty { built.append(Row(id: "search-lists", title: "歌单", items: playlists.map(Item.playlist))) }
            guard !built.isEmpty else { tv?.showToast("没有找到「\(keyword)」"); return }
            columns["search-songs"] = 0
            columns["search-lists"] = 0
            withAnimation(Motion.navigate) { results = built; rowIndex = 0; topFocus = nil }
        }
    }

    // MARK: 按键

    func handle(_ command: RemoteCommand) {
        if naming != nil {
            switch command {
            case .select: createList()
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
        case .playPause: if current != nil { togglePause() }
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
        case .playPause: if current != nil { togglePause() }
        default: break
        }
    }

    private func activateTop(_ item: TopItem) {
        switch item {
        case .player: if current != nil { withAnimation(Motion.navigate) { nowPlayingVisible = true } }
        case .search: withAnimation(Motion.focus) { editing = true }
        case .account:
            logoutArmed = false
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
            case .playPause: if current != nil { togglePause() }
            case .back: withAnimation(Motion.navigate) { self.page = nil }
            default: break
            }
            return
        }
        switch command {
        case .move(.up):
            if page.index > 0 { withAnimation(Motion.focus) { self.page?.index = page.index - 1 } }
            else if current != nil { withAnimation(Motion.focus) { topFocus = .player } }
        case .move(.down): if page.index < page.songs.count - 1 { withAnimation(Motion.focus) { self.page?.index = page.index + 1 } }
        case .move(.left): withAnimation(Motion.focus) { self.page?.button = 0 }
        case .select:
            guard page.songs.indices.contains(page.index) else { return }
            start(page.songs[page.index], in: page.songs)
        case .playPause: if current != nil { togglePause() }
        case .back: withAnimation(Motion.navigate) { self.page = nil }
        default: break
        }
    }

    enum PageButton { case play, shuffle, subscribe }
    /// 自己建的歌单没有"收藏"这个按钮
    var pageButtons: [PageButton] {
        guard let page else { return [] }
        return page.list.creator != 0 && page.list.creator == account?.id ? [.play, .shuffle] : [.play, .shuffle, .subscribe]
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
        case .subscribe: toggleSubscribed(page.list)
        }
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
                preferredLevel = chosen
                if chosen != actualLevel, let current { play(current, resumeAt: time) }   // 换音质：从现在的位置接着放
            case .back, .move(.down), .move(.up): withAnimation(Motion.navigate) { qualityVisible = false }
            default: break
            }
            return
        }
        if queueVisible {
            switch command {
            case .move(.left): withAnimation(Motion.focus) { queueFocus = max(0, queueFocus - 1) }
            case .move(.right): withAnimation(Motion.focus) { queueFocus = min(queue.count - 1, queueFocus + 1) }
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
            qualityIndex = offered.firstIndex { $0.level == (actualLevel.isEmpty ? preferredLevel : actualLevel) } ?? max(0, offered.count - 1)
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

    private func setColumn(_ delta: Int) {
        guard rows.indices.contains(row) else { return }
        let line = rows[row]
        let next = max(0, min(line.items.count - 1, column(of: line) + delta))
        withAnimation(Motion.focus) { columns[line.id] = next }
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

    // MARK: 菜单

    private func songItems(_ song: NeteaseSong, withMode: Bool) -> [MenuItem] {
        let on = liked.contains(song.id)
        var items = [MenuItem(symbol: on ? "heart.fill" : "heart", title: on ? "取消喜欢" : "喜欢", action: .like(song)),
                     MenuItem(symbol: "text.badge.plus", title: "收藏到歌单", action: .addTo(song))]
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
            guard list.creator == 0 || list.creator != account?.id else { return false }   // 自己建的歌单没什么可收藏的
            let on = subscribed(list)
            opened = Menu(anchor: .card, items: [MenuItem(symbol: on ? "star.fill" : "star", title: on ? "取消收藏" : "收藏歌单", action: .subscribe(list))])
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
        case .move(.up): withAnimation(Motion.focus) { self.menu?.index = max(0, menu.index - 1); logoutArmed = false }
        case .move(.down): withAnimation(Motion.focus) { self.menu?.index = min(menu.items.count - 1, menu.index + 1); logoutArmed = false }
        case .select: if menu.items.indices.contains(menu.index) { run(menu.items[menu.index].action) }
        case .back, .move(.left):
            // 退一层：里面那层回到外面那层，最外层才是关掉
            withAnimation(Motion.focus) { self.menu = menuParents.popLast(); logoutArmed = false }
        default: break
        }
    }

    private func run(_ action: MenuAction) {
        switch action {
        case .like(let song):
            let on = !liked.contains(song.id)
            withAnimation(Motion.focus) { menu = nil }
            Task { @MainActor in
                let ok = await NeteaseAPI.setLiked(song: song.id, on)
                if ok { if on { liked.insert(song.id) } else { liked.remove(song.id) } }
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
        case .create(let song):
            newName = ""
            withAnimation(Motion.focus) { naming = song }
        case .subscribe(let list):
            withAnimation(Motion.focus) { menu = nil }
            toggleSubscribed(list)
        case .cycleMode:
            let all = PlayMode.allCases
            setMode(all[((all.firstIndex(of: mode) ?? 0) + 1) % all.count])
            // 菜单留着，那一行换成新的模式，可以接着按
            if let current, let anchor = menu?.anchor, let index = menu?.index {
                menu = Menu(anchor: anchor, items: songItems(current, withMode: true), index: index)
            }
        case .logout:
            // 退出登录要按两次，免得误触
            if logoutArmed { logout() } else { withAnimation(Motion.focus) { logoutArmed = true } }
        }
    }

    /// 新歌单的名字输好了：建歌单，把那首歌放进去
    func createList() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let song = naming, !name.isEmpty else { return }
        withAnimation(Motion.focus) { endEditing() }
        Task { @MainActor in
            guard let list = await NeteaseAPI.createPlaylist(name) else { tv?.showToast("操作失败"); return }
            let ok = await NeteaseAPI.add(song: song.id, to: list.id)
            tv?.showToast(ok ? "已收藏到「\(list.name)」" : "歌单建好了，但歌没放进去")
            loadedAt = .distantPast   // 我的歌单多了一个，下次进首页时重新取
            if let account { myLists = await NeteaseAPI.playlists(user: account.id) }
        }
    }

    private func toggleSubscribed(_ list: NeteasePlaylist) {
        let on = !subscribed(list)
        Task { @MainActor in
            let ok = await NeteaseAPI.setSubscribed(playlist: list.id, on)
            if ok {
                if on { myLists.append(list) } else { myLists.removeAll { $0.id == list.id } }
                loadedAt = .distantPast
                objectWillChange.send()
            }
            tv?.showToast(ok ? (on ? "已收藏歌单" : "已取消收藏") : "操作失败")
        }
    }

    // MARK: 播放

    private func setMode(_ value: PlayMode) {
        mode = value
        UserDefaults.standard.set(value.rawValue, forKey: "neteaseMode")
    }

    /// 放这首歌，songs 是接着往下放的队列。已经在放这一首的话，只是回到播放界面。
    private func start(_ song: NeteaseSong, in songs: [NeteaseSong]) {
        if current != song {
            queue = songs
            queueIndex = songs.firstIndex(of: song) ?? 0
            play(song)
        }
        withAnimation(Motion.navigate) { nowPlayingVisible = true }
    }

    private func play(_ song: NeteaseSong, failures: Int = 0, resumeAt: Double? = nil) {
        let changed = current != song
        current = song
        paused = false
        if changed {
            time = 0
            duration = Double(song.duration)
            player.pause()
            lyrics = []
            lyricsSong = 0
            lyricIndex = -1
            songTop = ""
            accountTop = ""
            Task { @MainActor in
                let levels = await NeteaseAPI.levels(song: song.id)
                guard current == song, let levels else { return }
                songTop = levels.song
                accountTop = levels.account
            }
            Task { @MainActor in
                let lines = await NeteaseAPI.lyrics(song: song.id)
                guard current == song else { return }
                lyrics = lines
                lyricsSong = song.id
                if lyricsShown != !lines.isEmpty { withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) { lyricsShown = !lines.isEmpty } }
            }
        }
        let level = preferredLevel
        Task { @MainActor in
            let found = await NeteaseAPI.address(song: song.id, level: level)
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
            // 选的那一档这首歌（或这个账号）没有：服务器给了它能给的最高一档，说一声，免得像是没反应
            if resumeAt != nil, found.level != level {
                // 分清是账号的会员等级不够，还是别的原因
                let blocked = !accountTop.isEmpty && Self.rank(level) > Self.rank(accountTop)
                tv?.showToast(blocked ? "你的会员最高能听「\(Self.name(of: accountTop))」" : "只拿到了「\(Self.name(of: found.level))」")
            }
            let same = found.level == actualLevel && resumeAt != nil && player.currentItem != nil
            actualLevel = found.level
            if !same {
                player.replaceCurrentItem(with: AVPlayerItem(url: found.url))
                if let resumeAt, resumeAt > 1 { await player.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600)) }
            }
            if !paused { player.play() }
            publishNowPlaying()
        }
    }

    /// delta：+1 下一首，-1 上一首。automatic = 这首放完了自己往下走（单曲循环只在这时候起作用）。
    private func skip(_ delta: Int, automatic: Bool = false) {
        guard !queue.isEmpty else { return }
        if automatic, mode == .single, let current {
            player.seek(to: .zero)
            time = 0
            lyricIndex = -1
            player.play()
            _ = current
            return
        }
        if mode == .shuffle, delta > 0, queue.count > 1 {
            var next = queueIndex
            while next == queueIndex { next = Int.random(in: 0..<queue.count) }
            queueIndex = next
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
        publishNowPlaying()
    }

    private func seek(by seconds: Double) {
        guard duration > 0 else { return }
        let target = max(0, min(duration - 1, time + seconds))
        time = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        publishNowPlaying()
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
