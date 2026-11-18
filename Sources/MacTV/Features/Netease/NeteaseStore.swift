import AVFoundation
import AppKit
import Combine
import CoreImage
import SwiftUI

/// 网易云音乐的原生页面：扫码登录、每日推荐、我喜欢的音乐、我的歌单，和一个"正在播放"界面。
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
    @Published private(set) var loginImage: NSImage?
    @Published private(set) var loginScanned = false

    @Published private(set) var home: [Row] = []
    /// 打开的某个歌单
    @Published private(set) var page: Row?
    @Published private(set) var rowIndex = 0
    @Published private(set) var columns: [String: Int] = [:]

    // 播放
    @Published private(set) var current: NeteaseSong?
    @Published private(set) var paused = false
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var nowPlayingVisible = false
    private var queue: [NeteaseSong] = []
    private var queueIndex = 0
    private let player = AVPlayer()
    private var timeObserver: Any?
    private var bag: Set<AnyCancellable> = []
    private var loginTask: Task<Void, Never>?
    private var open = false

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] now in
            MainActor.assumeIsolated {
                guard let self, self.current != nil else { return }
                self.time = now.seconds.isFinite ? now.seconds : 0
                if let total = self.player.currentItem?.duration.seconds, total.isFinite, total > 0 { self.duration = total }
            }
        }
        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification).receive(on: RunLoop.main).sink { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.skip(1, automatic: true)
            }
        }.store(in: &bag)
    }

    var rows: [Row] { page.map { [$0] } ?? home }
    var row: Int { page != nil ? 0 : min(rowIndex, max(0, rows.count - 1)) }
    func column(of row: Row) -> Int { max(0, min(columns[row.id] ?? 0, row.items.count - 1)) }
    var focused: Item? {
        guard rows.indices.contains(row) else { return nil }
        let line = rows[row]
        return line.items.indices.contains(column(of: line)) ? line.items[column(of: line)] : nil
    }

    // MARK: 进出

    func opened() {
        open = true
        Task { @MainActor in
            if account == nil { account = NeteaseAPI.hasLogin ? await NeteaseAPI.account() : nil }
            checked = true
            if account == nil { startLogin() } else if home.isEmpty { await loadHome() }
        }
    }

    func closed() {
        open = false
        loginTask?.cancel()
        stop()
    }

    // MARK: 登录

    private func startLogin() {
        loginTask?.cancel()
        loginTask = Task { @MainActor in
            while !Task.isCancelled, open, account == nil {
                guard let code = await NeteaseAPI.loginCode() else {
                    try? await Task.sleep(for: .seconds(10)); continue   // 别问得太勤，会被当成刷接口
                }
                loginImage = Self.qrImage(code.address)
                loginScanned = false
                // 等扫码：过期了（约两分钟）就换一张新的
                waiting: while !Task.isCancelled, open {
                    try? await Task.sleep(for: .seconds(2))
                    switch await NeteaseAPI.loginState(key: code.key) {
                    case 802: loginScanned = true
                    case 803:
                        account = await NeteaseAPI.account()
                        if account != nil {
                            loginImage = nil
                            await loadHome()
                            return
                        }
                        break waiting
                    case 800: break waiting
                    default: break
                    }
                }
            }
        }
    }

    private static func qrImage(_ text: String) -> NSImage? { QRCode.image(for: text) }

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
                // 图标里的白色笔画要留着；只有圆角外面那一点白要去掉
                let radius = Double(right - left + 1) * 0.24
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
        tv?.showToast("已退出登录")
        startLogin()
    }

    // MARK: 内容

    private func loadHome() async {
        guard let account else { return }
        loading = true
        async let daily = NeteaseAPI.daily()
        let lists = await NeteaseAPI.playlists(user: account.id)
        var liked: [NeteaseSong] = []
        if let first = lists.first { liked = await NeteaseAPI.songs(playlist: first.id, limit: 60) }
        var built: [Row] = []
        let recommended = await daily
        if !recommended.isEmpty { built.append(Row(id: "daily", title: "每日推荐", items: recommended.map(Item.song))) }
        if !liked.isEmpty { built.append(Row(id: "liked", title: "我喜欢的音乐", items: liked.map(Item.song))) }
        if !lists.isEmpty { built.append(Row(id: "lists", title: "歌单", items: lists.map(Item.playlist))) }
        built.append(Row(id: "account", title: account.name, items: [.logout]))
        withAnimation(Motion.navigate) { home = built; rowIndex = 0 }
        loading = false
    }

    private func openPlaylist(_ list: NeteasePlaylist) {
        let id = "list-\(list.id)"
        columns[id] = 0
        loading = true
        Task { @MainActor in
            let songs = await NeteaseAPI.songs(playlist: list.id)
            loading = false
            guard !songs.isEmpty else { tv?.showToast("歌单是空的"); return }
            withAnimation(Motion.navigate) { page = Row(id: id, title: list.name, items: songs.map(Item.song)) }
        }
    }

    // MARK: 按键

    func handle(_ command: RemoteCommand) {
        if nowPlayingVisible {
            switch command {
            case .select, .playPause: togglePause()
            case .move(.left): skip(-1)
            case .move(.right): skip(1)
            case .seek(let forward): seek(by: forward ? 10 : -10)
            case .back, .move(.down): withAnimation(Motion.navigate) { nowPlayingVisible = false }
            default: break
            }
            return
        }
        guard account != nil else { return }
        switch command {
        case .move(.left): setColumn(-1)
        case .move(.right): setColumn(1)
        case .move(.up): if page == nil, row > 0 { withAnimation(Motion.navigate) { rowIndex = row - 1 } }
        case .move(.down): if page == nil, row < rows.count - 1 { withAnimation(Motion.navigate) { rowIndex = row + 1 } }
        case .select: activate()
        case .playPause: if current != nil { togglePause() }
        case .back: if page != nil { withAnimation(Motion.navigate) { page = nil } }
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
        withAnimation(Motion.focus) { if page == nil { rowIndex = r }; columns[rows[r].id] = c }
    }

    func activate() {
        guard let item = focused else { return }
        switch item {
        case .song(let song):
            if current == song { withAnimation(Motion.navigate) { nowPlayingVisible = true }; return }
            let songs = rows[row].items.compactMap { item -> NeteaseSong? in if case .song(let s) = item { return s } else { return nil } }
            queue = songs
            queueIndex = songs.firstIndex(of: song) ?? 0
            play(song)
            withAnimation(Motion.navigate) { nowPlayingVisible = true }
        case .playlist(let list): openPlaylist(list)
        case .logout: logout()
        }
    }

    // MARK: 播放

    private func play(_ song: NeteaseSong, failures: Int = 0) {
        current = song
        time = 0
        duration = Double(song.duration)
        paused = false
        player.pause()
        Task { @MainActor in
            let address = await NeteaseAPI.address(song: song.id)
            guard current == song else { return }
            guard let address else {
                // 这一首放不了（版权、会员或地区）：自动跳下一首；连着三首都不行就停下来说一声
                if failures < 2, queue.count > 1 {
                    queueIndex = (queueIndex + 1) % queue.count
                    play(queue[queueIndex], failures: failures + 1)
                } else {
                    tv?.showToast("无法播放")
                    stop()
                }
                return
            }
            player.replaceCurrentItem(with: AVPlayerItem(url: address))
            player.play()
        }
    }

    private func skip(_ delta: Int, automatic: Bool = false) {
        guard !queue.isEmpty else { return }
        queueIndex = (queueIndex + delta + queue.count) % queue.count
        play(queue[queueIndex])
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
        queue = []
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

    func closeNetease() {
        guard neteaseOpen else { return }
        neteaseStore.closed()
        neteaseOpen = false
    }
}
