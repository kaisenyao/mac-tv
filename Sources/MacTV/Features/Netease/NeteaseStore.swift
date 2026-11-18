import AVFoundation
import AppKit
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
        case logout
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
    }
    @Published private(set) var page: Page?
    /// "退出登录"按过一次了，再按一次才真的退出
    @Published private(set) var logoutArmed = false
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

    /// 音质档位。选了账号或这首歌没有的档位，服务器会给它能给的最高一档，actualLevel 是实际拿到的。
    struct Quality: Hashable { let level: String; let name: String }
    static let qualities = [Quality(level: "standard", name: "标准"), Quality(level: "higher", name: "较高"),
                            Quality(level: "exhigh", name: "极高"), Quality(level: "lossless", name: "无损"),
                            Quality(level: "hires", name: "Hi-Res"), Quality(level: "jymaster", name: "超清母带")]
    @Published private(set) var qualityVisible = false
    @Published private(set) var qualityIndex = 0
    @Published private(set) var actualLevel = ""
    private(set) var preferredLevel: String {
        get { UserDefaults.standard.string(forKey: "neteaseQuality") ?? "exhigh" }
        set { UserDefaults.standard.set(newValue, forKey: "neteaseQuality") }
    }
    static func name(of level: String) -> String { qualities.first { $0.level == level }?.name ?? "" }
    private var queue: [NeteaseSong] = []
    private var queueIndex = 0
    private let player = AVPlayer()
    private var timeObserver: Any?
    private var bag: Set<AnyCancellable> = []
    private var loginTask: Task<Void, Never>?
    private var open = false

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] now in
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
    }

    /// 焦点或画面变了就会变的一串字：按键音效靠它判断"这一下有没有真的动"
    var focusKey: String {
        "\(page?.list.id ?? 0)-\(page?.index ?? 0)-\(row)-\(rows.indices.contains(row) ? column(of: rows[row]) : 0)-\(editing)-\(results != nil)"
            + "-\(nowPlayingVisible)-\(current?.id ?? 0)-\(paused)-\(qualityVisible)-\(qualityIndex)-\(logoutArmed)"
    }

    var rows: [Row] { results ?? home }
    var row: Int { min(rowIndex, max(0, rows.count - 1)) }
    func column(of row: Row) -> Int { max(0, min(columns[row.id] ?? 0, row.items.count - 1)) }
    /// 首页（或搜索结果）里选中的那一项；在输入框里、歌单页里时没有
    var focused: Item? {
        guard !editing, page == nil, rows.indices.contains(row) else { return nil }
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
        nowPlayingVisible = false
        qualityVisible = false
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

    private func loadHome() async {
        guard let account else { return }
        loading = true
        async let daily = NeteaseAPI.daily()
        async let picks = NeteaseAPI.recommendedPlaylists()
        async let tops = NeteaseAPI.charts()
        let lists = await NeteaseAPI.playlists(user: account.id)
        // 每日推荐和歌单先到先摆出来，其余几排随后补上
        let recommended = await daily
        if home.isEmpty, !recommended.isEmpty || !lists.isEmpty {
            var quick: [Row] = []
            if !recommended.isEmpty { quick.append(Row(id: "daily", title: "每日推荐", items: recommended.map(Item.song))) }
            if !lists.isEmpty { quick.append(Row(id: "lists", title: "我的歌单", items: lists.map(Item.playlist))) }
            withAnimation(Motion.navigate) { home = quick }
        }
        var liked: [NeteaseSong] = []
        if let first = lists.first { liked = await NeteaseAPI.songs(playlist: first.id, limit: 60) }
        let (suggested, charts) = await (picks, tops)
        var built: [Row] = []
        if !recommended.isEmpty { built.append(Row(id: "daily", title: "每日推荐", items: recommended.map(Item.song))) }
        if !liked.isEmpty { built.append(Row(id: "liked", title: "我喜欢的音乐", items: liked.map(Item.song))) }
        if !suggested.isEmpty { built.append(Row(id: "picks", title: "推荐歌单", items: suggested.map(Item.playlist))) }
        if !lists.isEmpty { built.append(Row(id: "lists", title: "我的歌单", items: lists.map(Item.playlist))) }
        if !charts.isEmpty { built.append(Row(id: "charts", title: "排行榜", items: charts.map(Item.playlist))) }
        built.append(Row(id: "account", title: account.name, items: [.logout]))
        guard self.account == account else { loading = false; return }
        // 正停在某一排上时，更新内容不把焦点挪走（按这一排的名字找回去）
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

    func stopEditing() {
        guard editing else { return }
        endEditing()
    }

    private func endEditing() {
        guard editing else { return }
        editing = false
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
            withAnimation(Motion.navigate) { results = built; rowIndex = 0 }
        }
    }

    // MARK: 按键

    func handle(_ command: RemoteCommand) {
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
        if page != nil { handlePage(command); return }
        if logoutArmed {
            // 按了一次"退出登录"后，除了再按一次确认，别的任何键都算取消
            if case .select = command {} else { withAnimation(Motion.focus) { logoutArmed = false } }
        }
        switch command {
        case .move(.left): setColumn(-1)
        case .move(.right): setColumn(1)
        case .move(.up):
            if row > 0 { withAnimation(Motion.navigate) { rowIndex = row - 1 } }
            else { withAnimation(Motion.focus) { editing = true } }   // 最上面一排再按上：到搜索框
        case .move(.down): if row < rows.count - 1 { withAnimation(Motion.navigate) { rowIndex = row + 1 } }
        case .select: activate()
        case .playPause: if current != nil { togglePause() }
        case .back:
            // 在搜索结果里：Esc 回到首页
            if results != nil { withAnimation(Motion.navigate) { results = nil; query = ""; rowIndex = 0 } }
        default: break
        }
    }

    /// 歌单页：上下选歌，确认播放（整个歌单接着往下放），返回回到首页
    private func handlePage(_ command: RemoteCommand) {
        guard let page else { return }
        switch command {
        case .move(.up): if page.index > 0 { withAnimation(Motion.focus) { self.page?.index = page.index - 1 } }
        case .move(.down): if page.index < page.songs.count - 1 { withAnimation(Motion.focus) { self.page?.index = page.index + 1 } }
        case .select:
            guard page.songs.indices.contains(page.index) else { return }
            start(page.songs[page.index], in: page.songs)
        case .playPause: if current != nil { togglePause() }
        case .back, .move(.left): withAnimation(Motion.navigate) { self.page = nil }
        default: break
        }
    }

    private func handleNowPlaying(_ command: RemoteCommand) {
        if qualityVisible {
            switch command {
            case .move(.left): withAnimation(Motion.focus) { qualityIndex = max(0, qualityIndex - 1) }
            case .move(.right): withAnimation(Motion.focus) { qualityIndex = min(Self.qualities.count - 1, qualityIndex + 1) }
            case .select:
                let chosen = Self.qualities[qualityIndex].level
                withAnimation(Motion.navigate) { qualityVisible = false }
                if chosen != preferredLevel {
                    preferredLevel = chosen
                    if let current { play(current, resumeAt: time) }   // 换音质：从现在的位置接着放
                }
            case .back, .move(.down), .move(.up): withAnimation(Motion.navigate) { qualityVisible = false }
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
            qualityIndex = Self.qualities.firstIndex { $0.level == (actualLevel.isEmpty ? preferredLevel : actualLevel) } ?? 2
            withAnimation(Motion.navigate) { qualityVisible = true }
        case .seek(let forward): seek(by: forward ? 10 : -10)
        case .back, .move(.down): withAnimation(Motion.navigate) { nowPlayingVisible = false }
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
        withAnimation(Motion.focus) { rowIndex = r; columns[rows[r].id] = c }
    }

    /// 触控板点歌单页里的某一首
    func tapSong(_ index: Int) {
        guard let page, page.songs.indices.contains(index) else { return }
        self.page?.index = index
        start(page.songs[index], in: page.songs)
    }

    /// 触控板点搜索框
    func tapSearch() {
        guard account != nil, page == nil, !nowPlayingVisible else { return }
        withAnimation(Motion.focus) { editing = true }
    }

    func activate() {
        guard let item = focused else { return }
        switch item {
        case .song(let song):
            start(song, in: rows[row].items.compactMap { item -> NeteaseSong? in if case .song(let s) = item { return s } else { return nil } })
        case .playlist(let list): openPlaylist(list)
        case .logout:
            // 退出登录要按两次，免得误触
            if logoutArmed { logout() } else { withAnimation(Motion.focus) { logoutArmed = true } }
        }
    }

    // MARK: 播放

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
            lyricIndex = -1
            Task { @MainActor in
                let lines = await NeteaseAPI.lyrics(song: song.id)
                if current == song { lyrics = lines }
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
            actualLevel = found.level
            player.replaceCurrentItem(with: AVPlayerItem(url: found.url))
            if let resumeAt, resumeAt > 1 { await player.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600)) }
            if !paused { player.play() }
        }
    }

    private func skip(_ delta: Int, automatic: Bool = false) {
        guard !queue.isEmpty else { return }
        queueIndex = (queueIndex + delta + queue.count) % queue.count
        play(queue[queueIndex])
        // 歌单页开着的话，选中的那一行跟着正在放的歌走
        if let page, let index = page.songs.firstIndex(of: queue[queueIndex]) { self.page?.index = index }
    }

    private func togglePause() {
        paused.toggle()
        if paused { player.pause() } else { player.play() }
    }

    private func seek(by seconds: Double) {
        guard duration > 0 else { return }
        let target = max(0, min(duration - 1, time + seconds))
        time = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        current = nil
        nowPlayingVisible = false
        qualityVisible = false
        queue = []
    }

    /// 有没有歌在放（包括暂停着）
    var playing: Bool { current != nil }
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
