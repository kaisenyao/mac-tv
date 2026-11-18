@preconcurrency import AVFoundation
import AppKit
import Combine
import SwiftUI

/// 哔哩哔哩的原生播放器：直接取流，用系统播放器播放，不经过网页，所以点了就播。
/// 焦点停在一张卡片上时就提前把它准备好（取流、连上服务器、缓冲开头），按下确认时基本是现成的。
@MainActor
final class BilibiliNativePlayer: ObservableObject {
    /// 正在播放（或正在打开）的视频；nil 表示播放器没开
    @Published private(set) var current: BiliVideo?
    @Published private(set) var paused = false
    /// 画面已经出来了（之前显示封面）
    @Published private(set) var showing = false
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var quality = ""
    @Published private(set) var controlsVisible = false
    @Published private(set) var failed = false
    /// 和正在播的视频相关的视频：播放时按下键拉出来，播完自动出现
    @Published private(set) var related: [BiliVideo] = []
    @Published private(set) var relatedVisible = false
    @Published private(set) var relatedIndex = 0

    /// 清晰度菜单：播放时按上键打开
    @Published private(set) var qualities: [Int] = []
    @Published private(set) var qualityMenuVisible = false
    @Published private(set) var qualityIndex = 0
    @Published private(set) var qualityID = 0
    /// 想要的清晰度上限，记住上次的选择；默认 1080P 高码率
    private var preferredQuality: Int {
        get { UserDefaults.standard.object(forKey: "bilibiliQuality") as? Int ?? 112 }
        set { UserDefaults.standard.set(newValue, forKey: "bilibiliQuality") }
    }

    enum Outcome { case stay, close }

    let player = AVPlayer()
    var cookie: () async -> String = { "" }
    var keepAwake: (Bool) -> Void = { _ in }
    var noteActivity: () -> Void = {}

    private var warmed: (video: BiliVideo, item: AVPlayerItem, stream: BiliStream)?
    private var warming: (video: BiliVideo, task: Task<Void, Never>)?
    private var observers: Set<AnyCancellable> = []
    private var timeObserver: Any?
    private var hideControls: Task<Void, Never>?
    private var stream: BiliStream?
    private var loaders: [ObjectIdentifier: BiliHLS.Loader] = [:]
    private let loaderQueue = DispatchQueue(label: "bilibili.playlists")

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        player.publisher(for: \.timeControlStatus).receive(on: RunLoop.main).sink { [weak self] status in
            MainActor.assumeIsolated {
                guard let self, self.current != nil else { return }
                self.paused = status == .paused
            }
        }.store(in: &observers)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] now in
            MainActor.assumeIsolated {
                guard let self, self.current != nil else { return }
                self.time = now.seconds.isFinite ? now.seconds : 0
                if let total = self.player.currentItem?.duration.seconds, total.isFinite { self.duration = total }
                if !self.showing, self.time > 0.05 { self.showing = true }
                if Int(self.time) % 20 == 0 { self.noteActivity() }   // 别让屏保在看视频时跳出来
            }
        }
        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification).receive(on: RunLoop.main).sink { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.current != nil, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                // 播完了：有相关视频就摆出来接着挑，没有就回列表
                if self.related.isEmpty { self.stop() } else { self.showRelated() }
            }
        }.store(in: &observers)
    }

    // MARK: 预加载

    /// 焦点停在这个视频上了：提前准备好。换了焦点就丢掉上一个。
    func warm(_ video: BiliVideo?) {
        guard current == nil else { return }
        guard let video else {
            // 没有要准备的了：取消正在准备的，也把已经挂上去缓冲的那个摘掉
            warming?.task.cancel()
            warming = nil
            if warmed != nil {
                warmed = nil
                player.replaceCurrentItem(with: nil)
            }
            return
        }
        if warming?.video == video || warmed?.video == video { return }
        warming?.task.cancel()
        warming = nil
        let task = Task { @MainActor [weak self] in
            // 快速划过的卡片不准备；但如果这期间已经按了确认，就别等了
            for _ in 0..<7 {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, !Task.isCancelled else { return }
                if self.current == video { break }
            }
            guard let self, !Task.isCancelled else { return }
            let prepared = await self.prepare(video)
            guard !Task.isCancelled else { return }
            self.warming = nil
            guard let prepared else {
                if self.current == video { self.failed = true }
                return
            }
            if self.current == video {
                // 准备的途中用户已经按了确认：接上就播
                self.player.replaceCurrentItem(with: prepared.item)
                self.begin(video, stream: prepared.stream)
            } else if self.current == nil {
                self.warmed = (video, prepared.item, prepared.stream)
                self.player.replaceCurrentItem(with: prepared.item)   // 挂上去它就开始缓冲开头，但不播
                self.player.pause()
            }
        }
        warming = (video, task)
    }

    private func prepare(_ video: BiliVideo) async -> (item: AVPlayerItem, stream: BiliStream)? {
        guard let stream = await BiliAPI.stream(for: video, cookie: await cookie(), limit: preferredQuality),
              let lists = await BiliHLS.playlists(for: stream) else { return nil }
        // 播放列表由我们现做现给（自定义地址），真正的画面和声音片段播放器自己去视频服务器取。
        // 视频服务器会核对"浏览器标识"和来源页；系统播放器默认报它自己的标识，登录后的地址会因此被拒（403）。
        let loader = BiliHLS.Loader(lists)
        let asset = AVURLAsset(url: URL(string: "bilitv://play/master.m3u8")!,
                               options: ["AVURLAssetHTTPHeaderFieldsKey": ["Referer": "https://www.bilibili.com/"],
                                         AVURLAssetHTTPUserAgentKey: UserAgent.safari])
        asset.resourceLoader.setDelegate(loader, queue: loaderQueue)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 10
        loaders[ObjectIdentifier(item)] = loader   // 播放期间要一直留着它
        if loaders.count > 4, let stale = loaders.keys.first(where: { $0 != ObjectIdentifier(item) && $0 != player.currentItem.map(ObjectIdentifier.init) }) {
            loaders[stale] = nil
        }
        return (item, stream)
    }

    // MARK: 播放

    func play(_ video: BiliVideo) {
        if current != nil { report() }   // 从相关视频里直接换片：先把上一个的进度记下
        related = []
        relatedVisible = false
        relatedIndex = 0
        Task { @MainActor [weak self] in
            guard let self else { return }
            let list = await BiliAPI.related(to: video.bvid, cookie: await self.cookie())
            if self.current == video { self.related = list }
        }
        let alreadyPreparing = warming?.video == video
        if !alreadyPreparing {
            warming?.task.cancel()
            warming = nil
        }
        current = video
        failed = false
        showing = false
        paused = false
        time = 0
        duration = Double(video.duration)
        keepAwake(true)
        if let ready = warmed, ready.video == video {
            warmed = nil
            begin(video, stream: ready.stream)
            return
        }
        warmed = nil
        player.replaceCurrentItem(with: nil)
        if alreadyPreparing { return }   // 正在准备的就是它，准备好会自己开播，不用重来一遍
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let prepared = await self.prepare(video) else {
                if self.current == video { self.failed = true }
                return
            }
            guard self.current == video else { return }
            self.player.replaceCurrentItem(with: prepared.item)
            self.begin(video, stream: prepared.stream)
        }
    }

    private func begin(_ video: BiliVideo, stream: BiliStream) {
        self.stream = stream
        quality = stream.quality
        qualityID = stream.qualityID
        qualities = stream.available
        // 继续观看：从上次的位置接着放（快看完的就从头）
        if let progress = video.progress, progress > 5, video.duration - progress > 15 {
            player.seek(to: CMTime(seconds: Double(progress), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
        flashControls(seconds: 4)
    }

    /// 把看到哪了告诉哔哩哔哩
    private func report() {
        guard let video = current else { return }
        let seconds = Int(time), cid = stream?.cid ?? video.cid
        let finished = duration > 0 && duration - time < 5
        if seconds > 3 || finished {
            Task { [cookie] in
                await BiliAPI.reportProgress(bvid: video.bvid, cid: cid, seconds: finished ? -1 : seconds, cookie: await cookie())
            }
        }
    }

    private func showRelated() {
        guard !related.isEmpty else { return }
        relatedIndex = min(relatedIndex, related.count - 1)
        controlsVisible = false
        hideControls?.cancel()
        relatedVisible = true
    }

    func stop() {
        guard current != nil else { return }
        report()
        relatedVisible = false
        qualityMenuVisible = false
        related = []
        player.pause()
        player.replaceCurrentItem(with: nil)
        current = nil
        stream = nil
        showing = false
        controlsVisible = false
        hideControls?.cancel()
        keepAwake(false)
    }

    // MARK: 按键

    func handle(_ command: RemoteCommand) -> Outcome {
        if qualityMenuVisible {
            switch command {
            // 清晰度是从上面下来的一横排（和下面的相关视频对称）：左右选，确认切换，按下或返回收起
            case .move(.left): withAnimation(Motion.focus) { qualityIndex = max(0, qualityIndex - 1) }
            case .move(.right): withAnimation(Motion.focus) { qualityIndex = min(qualities.count - 1, qualityIndex + 1) }
            case .select: if qualities.indices.contains(qualityIndex) { switchQuality(to: qualities[qualityIndex]) }
            case .back, .move(.down), .move(.up): qualityMenuVisible = false
            case .playPause:
                if player.timeControlStatus == .paused { player.play() } else { player.pause() }
            default: break
            }
            return .stay
        }
        if relatedVisible {
            switch command {
            case .move(.left): withAnimation(Motion.focus) { relatedIndex = max(0, relatedIndex - 1) }
            case .move(.right): withAnimation(Motion.focus) { relatedIndex = min(related.count - 1, relatedIndex + 1) }
            case .select: if related.indices.contains(relatedIndex) { play(related[relatedIndex]) }
            case .move(.up): relatedVisible = false
            case .back:
                // 播完后摆出来的：返回就是回列表；播放中拉出来的：返回只是收起
                if duration > 0, duration - time < 2 { return .close }
                relatedVisible = false
            case .playPause:
                if player.timeControlStatus == .paused { player.play() } else { player.pause() }
            default: break
            }
            return .stay
        }
        switch command {
        case .back: return .close
        case .select, .playPause:
            if failed { return .stay }
            if player.timeControlStatus == .paused { player.play() } else { player.pause() }
            flashControls()
        case .move(.left), .seek(forward: false): seek(by: -10)
        case .move(.right), .seek(forward: true): seek(by: 10)
        case .move(.down): if related.isEmpty { flashControls() } else { showRelated() }
        case .move(.up):
            if qualities.count > 1 {
                qualityIndex = qualities.firstIndex(of: qualityID) ?? 0
                controlsVisible = false
                hideControls?.cancel()
                qualityMenuVisible = true
            } else { flashControls() }
        default: break
        }
        return .stay
    }

    /// 换清晰度：记住选择，按新的清晰度重新取流，从刚才的位置接着放
    private func switchQuality(to id: Int) {
        qualityMenuVisible = false
        guard let video = current, id != qualityID else { return }
        preferredQuality = id
        let position = time, wasPaused = player.timeControlStatus == .paused
        warmed = nil
        Task { @MainActor [weak self] in
            guard let self, let prepared = await self.prepare(video), self.current == video else { return }
            self.player.replaceCurrentItem(with: prepared.item)
            self.stream = prepared.stream
            self.quality = prepared.stream.quality
            self.qualityID = prepared.stream.qualityID
            self.qualities = prepared.stream.available
            await self.player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            if !wasPaused { self.player.play() }
            self.flashControls()
        }
    }

    /// 转盘用的细调：一格几秒
    func scrub(by delta: Double) { seek(by: delta) }

    private func seek(by delta: Double) {
        guard let item = player.currentItem, item.status == .readyToPlay else { return }
        let total = item.duration.seconds.isFinite ? item.duration.seconds : duration
        let target = max(0, min(total - 2, time + delta))
        time = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: CMTime(seconds: 1, preferredTimescale: 600),
                    toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600))
        flashControls()
    }

    private func flashControls(seconds: Double = 3.5) {
        controlsVisible = true
        hideControls?.cancel()
        hideControls = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            if self.player.timeControlStatus == .paused, self.current != nil { return }   // 暂停时一直显示
            self.controlsVisible = false
        }
    }
}

/// 系统播放器的画面
private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// 播放界面：全屏画面，上面是电视式的控制层（大标题、粗进度条），按键时出现，几秒后消失。
struct BilibiliPlayerScreen: View {
    @ObservedObject var player: BilibiliNativePlayer
    let video: BiliVideo

    var body: some View {
        ZStack {
            Color.black
            PlayerSurface(player: player.player)
            TVCanvas { overlay }
        }
        .ignoresSafeArea()
    }

    @Namespace private var glass

    /// 面板滑入 / 滑出用的曲线：和哔哩哔哩页面的侧边栏是同一条，带一点弹性
    private static let slide = Animation.spring(response: 0.42, dampingFraction: 0.84)

    /// 托字用的暗角：靠边最深，按缓出曲线很快衰减，尾部淡得看不出边界。
    /// 普通的线性渐变中段偏重、收尾拖得长，看起来就是"一大片阴影"；这条曲线同样的深度下显得轻得多。
    private static func scrim(strength: Double, from edge: UnitPoint) -> LinearGradient {
        let curve: [(Double, Double)] = [(0, 1), (0.19, 0.738), (0.34, 0.541), (0.47, 0.382), (0.565, 0.278), (0.65, 0.194),
                                         (0.73, 0.126), (0.802, 0.075), (0.861, 0.042), (0.91, 0.021), (0.952, 0.008),
                                         (0.982, 0.002), (1, 0)]
        return LinearGradient(stops: curve.map { .init(color: .black.opacity(strength * $0.1), location: $0.0) },
                              startPoint: edge, endPoint: edge == .top ? .bottom : .top)
    }

    private func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds)), h = s / 3600, m = s % 3600 / 60, x = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, x) : String(format: "%d:%02d", m, x)
    }

    @ViewBuilder private var overlay: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                // 画面出来之前：封面放大模糊 + 标题
                if !player.showing {
                    ZStack {
                        Color.black
                        BiliImage(url: video.cover)
                        .frame(width: w * 1.16, height: h * 1.16)
                        .blur(radius: 48)
                        .brightness(-0.35)
                        .frame(width: w, height: h)
                        .clipped()
                        if player.failed {
                            VStack(spacing: 18) {
                                Image(systemName: "exclamationmark.triangle").font(.system(size: 70))
                                Text("无法播放").font(.tv(.headline, emphasized: true))
                            }
                        } else {
                            ProgressView().controlSize(.large)
                        }
                    }
                    .transition(.opacity)
                }

                if player.paused, player.showing, !player.relatedVisible, !player.qualityMenuVisible {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 76, weight: .bold))
                        .frame(width: 180, height: 180)
                        .background(.ultraThinMaterial, in: Circle())
                        .transition(.opacity)
                }

                // 清晰度：从屏幕上方滑下来，居中。没有底板，只有一层从上往下渐隐的暗色托着文字。
                // 它一直都在，平时停在屏幕外面，所以进出都是连贯的滑动；白色高亮是同一块，在选项之间滑过去。
                VStack(spacing: 0) {
                  HStack(spacing: 34) {     // 标题和档位在同一行，整行居中
                    Text("清晰度").font(.system(size: 30, weight: .bold)).foregroundStyle(.white.opacity(0.75))
                        .shadow(color: .black.opacity(0.6), radius: 8, y: 2)
                    HStack(spacing: 10) {
                        ForEach(Array(player.qualities.enumerated()), id: \.element) { index, id in
                            let focused = index == player.qualityIndex
                            HStack(spacing: 12) {
                                if id == player.qualityID { Image(systemName: "checkmark").font(.system(size: 22, weight: .bold)) }
                                Text(BiliStream.name(of: id)).font(.system(size: 29, weight: focused ? .bold : .medium))
                            }
                            .foregroundStyle(focused ? .black : .white.opacity(0.85))
                            .shadow(color: .black.opacity(focused ? 0 : 0.6), radius: 8, y: 2)   // 暗色少了，靠文字自己的投影保证看得清
                            .padding(.horizontal, 30)
                            .frame(height: 78)
                            .matchedGeometryEffect(id: "quality-\(index)", in: glass, isSource: true)
                        }
                    }
                    .background {
                        RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white)
                            .matchedGeometryEffect(id: "quality-\(player.qualityIndex)", in: glass, isSource: false)
                    }
                  }
                    Spacer()
                }
                .padding(.top, 54)
                .frame(width: w, height: h, alignment: .top)
                .background(alignment: .top) {
                    // 暗色带的高度 = 上留白 + 按钮 + 同样的下留白，按钮在带子里上下居中；
                    // 往屏幕上方多延伸一截，是因为滑下来带一点回弹，会先冲过头，不延伸顶上会露缝。
                    VStack(spacing: 0) {
                        Color.black.opacity(0.42).frame(height: 400)
                        Self.scrim(strength: 0.42, from: .top).frame(height: 54 + 78 + 54)
                    }
                    .offset(y: -400)
                }
                .offset(y: player.qualityMenuVisible ? 0 : -210)
                .opacity(player.qualityMenuVisible ? 1 : 0)
                .animation(Self.slide, value: player.qualityMenuVisible)
                .animation(Self.slide, value: player.qualityIndex)

                // 相关视频：从屏幕下方滑上来，靠左排（和列表页的卡片排一个摆法：选中的在第二个位置，前面露出一张）。
                // 选中的卡片和列表页是同一种感觉：放大、白边、投影，标题变亮并往下让一点。
                VStack(alignment: .leading, spacing: 24) {
                    Spacer()
                    Text("相关视频").font(.system(size: 34, weight: .bold)).padding(.leading, w * 0.05)
                    let cardWidth: CGFloat = 340, gap: CGFloat = 34
                    HStack(alignment: .top, spacing: gap) {
                        ForEach(Array(player.related.enumerated()), id: \.element.id) { index, item in
                            if abs(index - player.relatedIndex) <= 6 {
                                let focused = index == player.relatedIndex
                                let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
                                VStack(alignment: .leading, spacing: 16) {
                                    ZStack(alignment: .bottomTrailing) {
                                        BiliImage(url: item.cover)
                                        .frame(width: cardWidth, height: cardWidth * 9 / 16)
                                        if item.duration > 0 {
                                            Text(item.durationText)
                                                .font(.system(size: 21, weight: .semibold).monospacedDigit())
                                                .padding(.horizontal, 10).padding(.vertical, 4)
                                                .background(.black.opacity(0.66), in: Capsule())
                                                .padding(10)
                                        }
                                    }
                                    .frame(width: cardWidth, height: cardWidth * 9 / 16)
                                    .clipShape(shape)
                                    .overlay(shape.strokeBorder(.white.opacity(focused ? 0.95 : 0.1), lineWidth: focused ? 5 : 1.5))
                                    .shadow(color: .black.opacity(focused ? 0.65 : 0), radius: 28, y: 20)
                                    .scaleEffect(focused ? 1.09 : 1)
                                    Text(item.title)
                                        .font(.system(size: 24, weight: focused ? .semibold : .medium))
                                        .foregroundStyle(.white.opacity(focused ? 1 : 0.7))
                                        .lineLimit(2)
                                        .frame(width: cardWidth, alignment: .leading)
                                        .offset(y: focused ? 10 : 0)
                                }
                                .zIndex(focused ? 1 : 0)
                                .opacity(index < player.relatedIndex - 1 ? 0 : 1)   // 再往左的隐去，不堆在屏幕边上
                            } else {
                                Color.clear.frame(width: cardWidth, height: 1)
                            }
                        }
                    }
                    .padding(.leading, w * 0.05)
                    .offset(x: -CGFloat(max(0, player.relatedIndex - 1)) * (cardWidth + gap))
                    .animation(Motion.focus, value: player.relatedIndex)
                }
                .padding(.bottom, 50)
                .frame(width: w, height: h, alignment: .bottomLeading)
                .background(alignment: .bottom) {
                    // 同样往屏幕下方多延伸一截，回弹时底下不露缝
                    VStack(spacing: 0) {
                        // 暗色的高度跟着这排内容走（标题、卡片、两行字，大约 400 高），只比内容高出一小段用来收尾
                        Self.scrim(strength: 0.6, from: .bottom).frame(height: 470)
                        Color.black.opacity(0.6).frame(height: 400)
                    }
                    .offset(y: 400)
                }
                .offset(y: player.relatedVisible ? 0 : 500)
                .opacity(player.relatedVisible ? 1 : 0)
                .animation(Self.slide, value: player.relatedVisible)

                if !player.relatedVisible && !player.qualityMenuVisible && (player.controlsVisible || !player.showing || player.paused) {
                    VStack(alignment: .leading, spacing: 0) {
                        Spacer()
                        Text(video.title)
                            .font(.system(size: 48, weight: .bold))
                            .lineLimit(2)
                            .frame(maxWidth: w * 0.7, alignment: .leading)
                            .shadow(color: .black.opacity(0.6), radius: 12, y: 3)
                        Text(video.owner).font(.system(size: 27)).opacity(0.7).padding(.top, 10)
                        GeometryReader { bar in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.28))
                                Capsule().fill(.white)
                                    .frame(width: max(10, bar.size.width * (player.duration > 0 ? min(1, player.time / player.duration) : 0)))
                            }
                        }
                        .frame(height: 10)
                        .padding(.top, 34)
                        HStack {
                            Text(clock(player.time))
                            Spacer()
                            Text(clock(player.duration))
                        }
                        .font(.system(size: 25, weight: .semibold).monospacedDigit())
                        .padding(.top, 14)
                    }
                    .padding(.horizontal, w * 0.05)
                    .padding(.bottom, 62)
                    .frame(width: w, height: h, alignment: .bottomLeading)
                    .background(alignment: .bottom) {
                        Self.scrim(strength: 0.6, from: .bottom)
                            .frame(height: 330)
                            .opacity(player.showing ? 1 : 0)
                    }
                    .transition(.opacity)
                }
            }
            .foregroundStyle(.white)
            .frame(width: w, height: h)
            .animation(.easeOut(duration: 0.25), value: player.controlsVisible)
            .animation(.easeOut(duration: 0.25), value: player.showing)
            .animation(.easeOut(duration: 0.2), value: player.paused)

        }
    }
}


/// 把哔哩哔哩给的整段文件变成系统播放器擅长的"按片段播放"（HLS）。
///
/// 哔哩哔哩的画面和声音各是一个大文件，里面已经切成了几秒一段，并在文件开头附了一张索引。
/// 直接把大文件交给系统播放器，它会先把整个文件的结构扫一遍，长视频要等很久；
/// 读出那张索引、告诉播放器每一段在文件的哪个位置，它只取开头一小段就能开播，两小时的片子也一样快。
enum BiliHLS {
    /// 三份播放列表：总表、画面、声音
    static func playlists(for stream: BiliStream) async -> [String: Data]? {
        async let picture = media(stream.video)
        async let sound = media(stream.audio)
        guard let video = await picture, let audio = await sound else { return nil }
        let master = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="main",DEFAULT=YES,AUTOSELECT=YES,URI="bilitv://play/audio.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=\(max(1, stream.video.bandwidth + stream.audio.bandwidth)),CODECS="\(stream.video.codecs),\(stream.audio.codecs)",RESOLUTION=\(stream.video.width)x\(stream.video.height),AUDIO="a"
        bilitv://play/video.m3u8

        """
        return ["master.m3u8": Data(master.utf8), "video.m3u8": Data(video.utf8), "audio.m3u8": Data(audio.utf8)]
    }

    /// 一条轨道的播放列表；一台服务器不通就换下一台
    private static func media(_ track: BiliTrack) async -> String? {
        for url in track.urls {
            if let list = await media(track, from: url) { return list }
        }
        return nil
    }

    private static func media(_ track: BiliTrack, from url: URL) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.setValue(UserAgent.safari, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        request.setValue("bytes=\(track.indexRange)", forHTTPHeaderField: "Range")
        request.httpShouldHandleCookies = false
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        let bytes = [UInt8](data)
        func number(_ offset: Int, _ length: Int) -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<length { value = value << 8 | UInt64(bytes[offset + index]) }
            return value
        }
        // 索引是一个 "sidx" 盒子：时间刻度、第一段的偏移、然后每一段的字节数和时长
        guard bytes.count > 32, bytes[4...7].elementsEqual(Array("sidx".utf8)) else { return nil }
        let version = bytes[8]
        let timescale = Double(number(16, 4))
        var position = 20
        let firstOffset: UInt64
        if version == 0 { firstOffset = number(position + 4, 4); position += 8 }
        else { firstOffset = number(position + 8, 8); position += 16 }
        let count = Int(number(position + 2, 2))
        position += 4
        let index = track.indexRange.split(separator: "-").compactMap { UInt64($0) }
        let start = track.initRange.split(separator: "-").compactMap { UInt64($0) }
        guard timescale > 0, index.count == 2, start.count == 2, bytes.count >= position + count * 12 else { return nil }
        var offset = index[1] + 1 + firstOffset
        var segments: [String] = []
        var longest = 0.0
        for _ in 0..<count {
            let size = number(position, 4) & 0x7FFF_FFFF
            let seconds = Double(number(position + 4, 4)) / timescale
            position += 12
            longest = max(longest, seconds)
            segments += [String(format: "#EXTINF:%.5f,", seconds), "#EXT-X-BYTERANGE:\(size)@\(offset)", url.absoluteString]
            offset += size
        }
        let head = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-INDEPENDENT-SEGMENTS",
                    "#EXT-X-TARGETDURATION:\(Int(longest.rounded(.up)))",
                    "#EXT-X-MAP:URI=\"\(url.absoluteString)\",BYTERANGE=\"\(start[1] - start[0] + 1)@\(start[0])\""]
        return (head + segments + ["#EXT-X-ENDLIST"]).joined(separator: "\n") + "\n"
    }

    /// 播放器来要播放列表时，把现做的那三份给它
    final class Loader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
        private let files: [String: Data]
        init(_ files: [String: Data]) { self.files = files }

        func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                            shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
            guard let name = request.request.url?.lastPathComponent, let data = files[name] else { return false }
            request.contentInformationRequest?.contentType = "public.m3u-playlist"
            request.contentInformationRequest?.contentLength = Int64(data.count)
            request.contentInformationRequest?.isByteRangeAccessSupported = false
            request.dataRequest?.respond(with: data)
            request.finishLoading()
            return true
        }
    }
}
