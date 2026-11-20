@preconcurrency import AVFoundation
import AppKit
import MediaPlayer
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
    /// 放的途中在等数据（网慢、刚拖完进度、直播卡了）：画面中间转个圈，知道是在加载、不是卡死了。
    /// 等了 0.4 秒以上才出来，一闪而过的不显示
    @Published private(set) var buffering = false
    private var bufferingSoon: Task<Void, Never>?
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var controlsVisible = false
    @Published private(set) var failed = false
    /// 正在放（或者正在缓冲着要放）：这时不让屏保出来、显示器不睡。
    /// 暂停了、放完停在相关视频上、放不了、直播连不上都不算
    var blocksScreensaver: Bool { current != nil && !paused && !failed }
    /// 和正在播的视频相关的视频：播放时按下键拉出来，播完自动出现
    @Published private(set) var related: [BiliVideo] = []
    /// 下面拉出来的那一块开着（里面是"选集"和"相关视频"两排，见 shelves）
    @Published private(set) var relatedVisible = false
    @Published private(set) var relatedIndex = 0

    /// 选集（一个视频分了好几 P，或者它在某个合集里）：下面拉出来的那一块里，在"相关视频"上面一排。
    /// 放完一集自动接着放下一集。换集时这一排留着，不跟着清空
    @Published private(set) var episodes: [BiliEpisode] = []
    @Published private(set) var episodeFocus = 0
    /// 下面拉出来的那一块里的两排；焦点在哪一排
    enum Shelf: Hashable { case episodes, related }
    @Published private(set) var shelf: Shelf = .related
    var shelves: [Shelf] { (episodes.isEmpty ? [] : [.episodes]) + (related.isEmpty ? [] : [.related]) }
    /// 正在放的是第几集
    var episodeIndex: Int? { current.flatMap { video in episodes.firstIndex { $0.matches(video) } } }

    /// 清晰度菜单：播放时按上键打开
    @Published private(set) var qualities: [Int] = []
    @Published private(set) var qualityMenuVisible = false
    @Published private(set) var qualityIndex = 0
    @Published private(set) var qualityID = 0
    /// 想要的清晰度上限，记住上次的选择；默认 1080P 高码率
    var preferredQuality: Int {
        get { UserDefaults.standard.object(forKey: "bilibiliQuality") as? Int ?? 112 }
        set { UserDefaults.standard.set(newValue, forKey: "bilibiliQuality") }
    }

    enum Outcome { case stay, close }

    // MARK: 右边的面板（播放时长按确认拉出来）

    /// 面板里一行一行：UP 主、点赞、投币、收藏、选集（有的话）、倍速、字幕、弹幕
    enum PanelRow: Hashable { case up, like, coin, favorite, episodes, speed, subtitles, danmaku }
    /// 选了某一行以后在面板里展开的小列表：投几个币、倍速档位、字幕语言、确认取消收藏
    enum PanelList: Hashable { case coins, speed, subtitles, unfavorite, danmaku }
    @Published private(set) var panelVisible = false
    @Published private(set) var panelList: PanelList?
    /// 面板里选中的是哪一行（按行记，不按第几个：取到 UP 主、选集以后行会多出来，选中的不会跳到别的行上）
    @Published private(set) var panelRow: PanelRow = .speed
    var panelIndex: Int { panelRows.firstIndex(of: panelRow) ?? 0 }
    @Published private(set) var panelListIndex = 0
    /// UP 主是谁、点赞投币收藏的数；我点过赞没有、投了几个币、收藏了没有
    @Published private(set) var info: BiliVideoInfo?
    @Published private(set) var relation = BiliRelation()
    /// 在面板里点赞、投币、收藏过几次：之前发出去的"我和这个视频的关系"查询回来得晚，就不拿它盖掉刚做的
    private var relationEdits = 0
    /// 点赞：账号上确认过的样子、有没有请求在路上、等手停下来再发的计时（连着按只发最后一次，按太快哔哩哔哩会拒绝）
    private var likeConfirmed: Bool?
    private var likeSending = false
    private var likeSettle: Task<Void, Never>?
    /// 投币、收藏的请求还没回来：再按不重复发
    private var sending: Set<PanelRow> = []

    /// 哔哩哔哩网页上的几档倍速（从快到慢，和网页上的排法一样）
    static let speeds: [Double] = [2.0, 1.5, 1.25, 1.0, 0.75, 0.5]
    /// 2× 1.5× 1.25× 1× 0.75× 0.5×：不带多余的 0（和得到一样）
    nonisolated static func speedName(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US_POSIX"))) + "×"
    }
    /// 倍速：记住上次选的，下一个视频也按它放（设置页里也能改）。只管视频，直播一直是 1 倍速
    @Published var speed = UserDefaults.standard.object(forKey: "bilibiliSpeed") as? Double ?? 1.0 {
        didSet {
            UserDefaults.standard.set(speed, forKey: "bilibiliSpeed")
            guard !isLive else { return }
            player.defaultRate = Float(speed)
            if player.timeControlStatus != .paused, player.rate > 0 { player.rate = Float(speed) }
        }
    }
    /// 有字幕时自动打开（在面板里选了"关闭"或某种语言，这个也跟着变）
    @Published var subtitlesOn = UserDefaults.standard.object(forKey: "bilibiliSubtitles") as? Bool ?? true {
        didSet { UserDefaults.standard.set(subtitlesOn, forKey: "bilibiliSubtitles") }
    }
    /// 弹幕开关：记住上次的选择（面板里、设置页里都能改）。打开时这个视频还没取过弹幕就现取；
    /// 直播间是打开就连弹幕服务器、关上就断开
    @Published var danmakuOn = UserDefaults.standard.object(forKey: "bilibiliDanmaku") as? Bool ?? true {
        didSet {
            guard danmakuOn != oldValue else { return }
            UserDefaults.standard.set(danmakuOn, forKey: "bilibiliDanmaku")
            if let video = current, video.isLive {
                if danmakuOn { connectLiveDanmaku(video) } else { disconnectLiveDanmaku() }
            } else if danmakuOn, danmakuAll.isEmpty, let video = current, let cid = stream?.cid {
                loadDanmaku(video, cid: cid)
            }
        }
    }
    /// 这个视频的弹幕，已经按弹幕设置排好了行（见 BiliDanmakuLayout）。单独放一个对象里：只有画弹幕的那一层看着它
    let danmaku = BiliDanmakuTrack()
    /// 取回来的全部弹幕（改弹幕设置时从它重新排）；直播间是最近一分钟来的
    private var danmakuAll: [BiliDanmaku] = []
    /// 直播间：连着弹幕服务器的那个任务；一行一行排到哪了（来一条排一条）；画面上这一秒已经放了几条
    private var liveDanmakuTask: Task<Void, Never>?
    private var danmakuLanes = BiliDanmakuLayout.Lanes(BiliDanmakuLayout())
    private var liveDanmakuSecond = (second: -1, shown: 0)
    /// 直播间一秒最多放几条：热闹的房间一秒来几十条，多的直接扔掉（不攒着）。满屏时一行一秒多也就进一条，十五条够了
    private static let liveDanmakuPerSecond = 15
    /// 弹幕设置：显示区域、字号、速度、不透明度、固定弹幕、彩色弹幕。改了马上重新排
    @Published var danmakuStyle = BiliDanmakuStyle.load() {
        didSet {
            guard danmakuStyle != oldValue else { return }
            danmakuStyle.save()
            danmakuLayout = BiliDanmakuLayout(style: danmakuStyle)
            relayoutDanmaku()
        }
    }
    @Published private(set) var danmakuLayout = BiliDanmakuLayout(style: BiliDanmakuStyle.load())
    @Published private(set) var subtitleTracks: [BiliSubtitleTrack] = []
    @Published private(set) var subtitleTrack: BiliSubtitleTrack?
    @Published private(set) var subtitleCues: [BiliSubtitleCue] = []

    let player = AVPlayer()
    var cookie: () async -> String = { "" }
    /// 签名用的密钥（取字幕要用），由外面接上
    var signingKey: () async -> String? = { nil }
    /// 登录的账号编号（0 = 没登录）：没登录时面板里不放点赞、投币、收藏；收藏要用它找收藏夹
    var accountMid: () -> Int = { 0 }
    /// 去 UP 主的主页（由外面接上：关掉播放器、打开主页）。带上正在看的视频和看到的位置，返回时回来接着放
    var openUp: ((BiliUser, BiliVideo) -> Void)?
    var keepAwake: (Bool) -> Void = { _ in }
    /// 显示一句提示（由外面接到应用的提示条上）
    var toast: ((String) -> Void)?
    var noteActivity: () -> Void = {}

    private var warmed: (video: BiliVideo, item: AVPlayerItem, stream: BiliStream)?
    private var warming: (video: BiliVideo, task: Task<Void, Never>)?
    /// 正在取流的（点开一个没准备好的视频、换清晰度）、正在连的直播：换片、关掉时取消，免得回来得晚的把别的顶掉
    private var loading: Task<Void, Never>?
    private var liveConnect: Task<Void, Never>?
    /// 放着的时候每 15 秒报一次看到哪
    private var heartbeat: Timer?
    /// 这次是不是指定了就放这一集、这一 P（见 play 的 exact）
    private var exactOpen = false
    private var observers: Set<AnyCancellable> = []
    private var timeObserver: Any?
    private var hideControls: Task<Void, Never>?
    /// 正在用双指左右滑拖进度：画面先停住，进度条和时间跟着手走，手指抬起才跳过去
    @Published private(set) var scrubbing = false
    private var scrubTarget = 0.0
    private var scrubWasPlaying = false
    private var lastReveal = Date.distantPast
    /// 这次打开是不是停在那一帧（见 play）
    private var startPaused = false
    /// 下面那一块是从右边面板的"选集"拉出来的（收起时回到面板）
    private var shelfFromPanel = false
    /// 这一集放完的事（接下一集 / 摆出相关视频）已经做过了：放完时系统的通知和"停在了最后"都会来，只做一次
    private var endHandled = false
    private var stream: BiliStream?
    private var loaders: [ObjectIdentifier: BiliHLS.Loader] = [:]
    /// 看着直播的那个：画面不动了就重新连（见 watchLive）
    private var liveWatchdog: Task<Void, Never>?
    /// 直播比正在直播的地方晚几秒放。实测 CDN 偶尔给 2～3 秒前的旧列表，1 秒一段的片段最慢 0.7 秒才下完，
    /// 列表本身来回 0.3 秒：最坏差 4 秒左右。晚 6 秒放还剩 2 秒余量；刚连上时列表里就有 6～7 秒，一开始就落在这个位置
    private static let liveOffset = 6.0
    /// 直播往前缓冲多少：比落后的秒数多一点，也就是"已经播出来的全缓冲上"（再往前还没有）
    private static let liveBuffer = 8.0
    /// 直播的列表经手的那个（系统播放器只弱引用它，要一直留着）、连的是哪台服务器、这次卡了几次（日志用）
    private var liveLoader: BiliHLS.LiveLoader?
    private var liveHost = ""
    private var liveStalls = 0
    /// 自己按了暂停（看门狗不把它当成卡住）
    private var userPaused = false
    private let loaderQueue = DispatchQueue(label: "bilibili.playlists")

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        player.defaultRate = Float(speed)   // 按播放就是这个倍速
        // 只在真的在放时不让显示器睡（见 blocksScreensaver）
        $current.combineLatest($paused, $failed)
            .map { current, paused, failed in current != nil && !paused && !failed }
            .removeDuplicates()
            .sink { [weak self] on in MainActor.assumeIsolated { self?.keepAwake(on) } }
            .store(in: &observers)
        player.publisher(for: \.timeControlStatus).receive(on: RunLoop.main).sink { [weak self] status in
            MainActor.assumeIsolated {
                guard let self, self.current != nil else { return }
                self.paused = status == .paused
                self.noteWaiting(status == .waitingToPlayAtSpecifiedRate)
                self.publishNowPlaying()
                // 停在了最后（有的视频放完不发通知，只是停住）：和放完一样处理
                if status == .paused, !self.scrubbing, self.duration > 1, self.displayTime() >= self.duration - 0.6 { self.reachedEnd() }
            }
        }.store(in: &observers)
        wireMediaKeys()
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] now in
            MainActor.assumeIsolated {
                guard let self, self.current != nil, !self.scrubbing else { return }
                self.time = now.seconds.isFinite ? now.seconds : 0
                if let total = self.player.currentItem?.duration.seconds, total.isFinite { self.duration = total }
                if self.time < self.duration - 2 { self.endHandled = false }   // 放完后又往回拖了：再放完还要接着处理
                if !self.showing, self.time > 0.05 { self.showing = true; self.publishNowPlaying() }
                if Int(self.time) % 20 == 0 { self.noteActivity() }   // 别让屏保在看视频时跳出来
            }
        }
        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification).receive(on: RunLoop.main).sink { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.current != nil, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.reachedEnd()
            }
        }.store(in: &observers)
        // 直播卡了一下：记一笔（缓冲了几秒、哪台服务器），下次知道是哪里不够
        NotificationCenter.default.publisher(for: AVPlayerItem.playbackStalledNotification).receive(on: RunLoop.main).sink { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let video = self.current, video.isLive, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.liveStalls += 1
                Log.playback.info("bilibili live \(video.liveRoom, privacy: .public): stalled (#\(self.liveStalls, privacy: .public)), \(self.bufferedAhead(), format: .fixed(precision: 1), privacy: .public)s buffered, host \(self.liveHost, privacy: .public)")
            }
        }.store(in: &observers)
    }

    // MARK: 预加载

    /// 焦点停在这个视频上了：提前准备好。换了焦点就丢掉上一个。
    func warm(_ video: BiliVideo?) {
        guard current == nil else { return }
        // 直播间不提前准备（在播的挂上去就是在拉直播流；没在播的没有东西可放）
        guard let video, !video.isRoom else {
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
        item.audioTimePitchAlgorithm = .spectral   // 倍速时声音不变调，听着最自然
        loaders[ObjectIdentifier(item)] = loader   // 播放期间要一直留着它
        if loaders.count > 4, let stale = loaders.keys.first(where: { $0 != ObjectIdentifier(item) && $0 != player.currentItem.map(ObjectIdentifier.init) }) {
            loaders[stale] = nil
        }
        return (item, stream)
    }

    // MARK: 播放

    /// startPaused：打开后停在那一帧不放（从 UP 主主页返回到刚才那个视频时），按播放才接着放。
    /// exact：就放这一集、这一 P（在选集里挑的、自动接下一集）；不是的话（从卡片点进来）照上次看到哪来：
    /// 分 P 视频跳到上次看的那一 P，合集跳到上次看的那一集（见 BiliResume）
    func play(_ video: BiliVideo, startPaused: Bool = false, exact: Bool = false) {
        // 看过的直播间、现在没在播：没有东西可放（选它是进主播的主页，见 BilibiliStore.perform）
        guard video.endedRoom == 0 else { return }
        leaveCurrent()   // 从相关视频里直接换片：先把上一个的进度记下
        // 换到同一个选集里的另一集：选集那一排留着；换到别的视频就清掉，等新视频的信息来了再说
        if !episodes.contains(where: { $0.matches(video) }) { episodes = [] }
        // 历史记录里的那一条本身就是上次看到的地方
        exactOpen = exact || startPaused || video.progress != nil
        self.startPaused = startPaused
        if video.isLive {
            playLive(video)
            return
        }
        let alreadyPreparing = warming?.video == video
        if !alreadyPreparing {
            warming?.task.cancel()
            warming = nil
        }
        show(video, paused: startPaused)
        loadInfo(video)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let list = await BiliAPI.related(to: video.bvid, cookie: await self.cookie())
            if self.current == video { self.related = list }
        }
        if let ready = warmed, ready.video == video {
            warmed = nil
            begin(video, stream: ready.stream)
            return
        }
        warmed = nil
        player.replaceCurrentItem(with: nil)
        if alreadyPreparing { return }   // 正在准备的就是它，准备好会自己开播，不用重来一遍
        loading = Task { @MainActor [weak self] in
            guard let self else { return }
            let prepared = await self.prepare(video)
            guard !Task.isCancelled, self.current == video else { return }
            guard let prepared else { self.failed = true; return }
            self.player.replaceCurrentItem(with: prepared.item)
            self.begin(video, stream: prepared.stream)
        }
    }

    /// 播放器打开这个视频（画面出来之前先显示封面）。直播按 1 倍速放，视频按选的倍速
    private func show(_ video: BiliVideo, paused: Bool) {
        current = video
        failed = false
        showing = false
        noteWaiting(false)
        self.paused = paused
        userPaused = false
        time = 0
        duration = Double(video.duration)
        qualityID = 0
        qualities = []
        player.defaultRate = video.isLive ? 1 : Float(speed)
    }

    /// 收起正在放的这个（换片、关掉时）：记下看到哪、把还没发出去的点赞发掉；还在跑的取流、连直播、报进度都停掉；
    /// 面板、清晰度栏、下面那一块收起；这个视频的信息、字幕、弹幕清掉。选集由调用的地方决定留不留
    private func leaveCurrent() {
        report()
        flushLike()
        loading?.cancel()
        loading = nil
        liveConnect?.cancel()
        liveConnect = nil
        liveWatchdog?.cancel()
        liveWatchdog = nil
        liveLoader = nil
        heartbeat?.invalidate()
        heartbeat = nil
        stream = nil   // 上一个视频的流（分 P 编号、清晰度）不能留给下一个用
        endHandled = false
        qualityMenuVisible = false
        related = []
        relatedVisible = false
        relatedIndex = 0
        shelfFromPanel = false
        closePanel()
        info = nil
        relation = BiliRelation()
        likeConfirmed = nil
        likeSending = false
        sending = []
        subtitleTracks = []
        subtitleTrack = nil
        subtitleCues = []
        disconnectLiveDanmaku()
    }

    private func begin(_ video: BiliVideo, stream: BiliStream) {
        heartbeat?.invalidate()
        heartbeat = nil
        // 从卡片点进来（没指定哪一 P、哪一集，也不是历史记录里带着进度的那一条）：照上次看到哪换过去
        if !exactOpen {
            // 分 P 视频：哔哩哔哩记着最后看的是哪一 P（网页版的记忆播放）
            if video.cid == 0, stream.lastPlayCid > 0, stream.lastPlayCid != stream.cid {
                var part = video
                part.cid = stream.lastPlayCid
                play(part, exact: true)
                return
            }
            // 合集：点的这一集没看过（或者早就看完了），上次在看别的集 → 接着看那一集（那一集看完了就是它的下一集）。
            // 想重看这一集，在选集里挑它（挑的照挑的放）
            let own = BiliResume.position(bvid: video.bvid, cid: stream.cid)
            if stream.lastPlayTime == 0, own == nil || own == -1,
               let episode = BiliResume.continueEpisode(for: video.bvid) {
                play(episode.video, exact: true)
                return
            }
        }
        self.stream = stream
        qualityID = stream.qualityID
        qualities = stream.available
        noteSeason()   // 上面决定完放哪一集了，才把它记成合集里"上次看的那一集"
        loadSubtitles(video, cid: stream.cid)
        if danmakuOn { loadDanmaku(video, cid: stream.cid) }
        // 继续观看：从上次的位置接着放（快看完的就从头）。
        // 从 UP 主主页回来（startPaused）不一样：回到离开时的那一帧，哪怕快到结尾了（离结尾留一点，免得当成放完了）
        // 从哪接着放：历史记录里带着的 > 哔哩哔哩记的（同一 P 才算）> 这台 Mac 上记的这一 P / 这一集
        let server = stream.lastPlayCid == stream.cid && stream.lastPlayTime > 0 ? stream.lastPlayTime : nil
        if let progress = video.progress ?? server ?? BiliResume.position(bvid: video.bvid, cid: stream.cid) {
            let total = Double(video.duration > 0 ? video.duration : Int(duration))
            let resumeAt: Double? = startPaused
                ? (progress > 0 ? (total > 2 ? min(Double(progress), total - 2) : Double(progress)) : nil)
                : (progress > 5 && video.duration - progress > 15 ? Double(progress) : nil)
            if let resumeAt {
                player.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
        // 放着的时候每 15 秒把看到哪告诉哔哩哔哩一次（网页版也是这样），中途关掉 Mac TV 也丢不了多少
        heartbeat = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.current == video, self.player.timeControlStatus == .playing else { return }
                self.report()
            }
        }
        if startPaused {
            // 停在那一帧：画面准备好就把封面换成画面，控制条一直露着（暂停时本来就一直显示）
            player.pause()
            Task { @MainActor [weak self] in
                for _ in 0..<60 {
                    guard let self, self.current == video else { return }
                    if self.player.currentItem?.status == .readyToPlay { self.showing = true; self.publishNowPlaying(); return }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        } else {
            player.play()
        }
        flashControls(seconds: 4)
    }

    // MARK: 直播

    var isLive: Bool { current?.isLive == true }

    /// 直播：直接把直播流（HLS）交给系统播放器。没有进度、不能拖；暂停后再放会跳回正在直播的地方。
    /// 哔哩哔哩给的几条线路里常有连不上的节点：几条同时试，谁先答上来用谁。
    /// 放着放着画面不动了（网络抖了、节点掉了），一会儿后自己重新连上，从正在直播的地方接着放
    private func playLive(_ video: BiliVideo) {
        warming?.task.cancel()
        warming = nil
        warmed = nil
        player.replaceCurrentItem(with: nil)
        show(video, paused: false)
        connectLive(video, reconnects: 0)
        connectLiveDanmaku(video)   // 弹幕另外连，不耽误画面
        // 进了这个直播间：报给哔哩哔哩，看过的直播记进历史记录（卡住重连不算再进一次）
        Task { [cookie] in await BiliAPI.enterLiveRoom(video.liveRoom, cookie: await cookie()) }
    }

    /// 要地址、挑线路、开播。reconnects：这是第几次因为卡住重新连。
    /// 每一步等完都看一眼还是不是在看这个直播间（换了别的、关掉了，这次连接就取消了）：不然连上得晚的会在后台响，
    /// 或者把下一个视频的画面顶掉
    private func connectLive(_ video: BiliVideo, reconnects: Int) {
        liveWatchdog?.cancel()
        liveConnect?.cancel()
        liveConnect = Task { @MainActor [weak self] in
            guard let self else { return }
            let room = video.liveRoom
            let cookie = await self.cookie()
            var tried: Set<URL> = []
            var offered = 0
            // 先用登录的账号要（清晰度高）；要不到、或者那几条线路都放不了，再不带账号要一次（清晰度低一点）。
            // 卡住后重连时反过来先不带账号要：登录后给的原画常常在国内的节点上，从国外看带宽跟不上，放几秒就卡死
            let signedIn = cookie.contains("SESSDATA=")
            let accounts = signedIn ? (reconnects > 0 ? ["", cookie] : [cookie, ""]) : [cookie]
            for header in accounts {
                let urls = await BiliAPI.liveStream(room: room, cookie: header)
                guard self.current == video, !Task.isCancelled else { return }
                offered += urls.count
                Log.playback.info("bilibili live \(room, privacy: .public): \(urls.count, privacy: .public) addresses (\(header.isEmpty && signedIn ? "anonymous" : "account", privacy: .public), reconnect \(reconnects, privacy: .public)): \(urls.compactMap(\.host).joined(separator: " "), privacy: .public)")
                var left = urls.filter { !tried.contains($0) }
                while !left.isEmpty {
                    guard let url = await Self.fastest(left) else { break }   // 这一批一条都连不上
                    guard self.current == video, !Task.isCancelled else { return }
                    tried.insert(url)
                    left.removeAll { $0 == url }
                    if await self.startLive(url, video) {
                        if self.current == video, !Task.isCancelled { self.watchLive(video, reconnects: reconnects) }
                        return
                    }
                }
                tried.formUnion(left)
            }
            guard self.current == video, !Task.isCancelled else { return }
            Log.playback.error("bilibili live \(room, privacy: .public): no working address (\(offered, privacy: .public) offered)")
            if offered == 0 {
                // 一条地址都不给：主播下播了。关掉播放器回到列表，说一声
                self.toast?("主播未开播")
                self.stop()
            } else {
                self.failed = true
                self.disconnectLiveDanmaku()
                self.toast?("无法连接直播")
            }
        }
    }

    /// 几条线路同时去要播放列表，谁先答上来用谁（一条条试的话，前面一条连不上就要白等好几秒）
    private nonisolated static func fastest(_ urls: [URL]) async -> URL? {
        await withTaskGroup(of: URL?.self) { group in
            for url in urls.prefix(8) { group.addTask { await reachable(url) ? url : nil } }
            for await found in group {
                if let found {
                    group.cancelAll()
                    return found
                }
            }
            return nil
        }
    }

    /// 看着直播：画面五秒没动（又不是自己按的暂停），记下播放器说了什么，重新要地址、从正在直播的地方接着放
    /// （主播下播了的话，重新要地址时就知道了，见 connectLive）。一分钟里重连超过三次就不再硬撑，告诉人连不上。
    /// 放着的时候每 30 秒记一笔（见 logLive）
    private func watchLive(_ video: BiliVideo, reconnects: Int) {
        liveWatchdog?.cancel()
        liveWatchdog = Task { @MainActor [weak self] in
            var last = -1.0, still = 0, ticks = 0
            let started = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.current == video, !Task.isCancelled else { return }
                ticks += 1
                if ticks % 30 == 0 { await self.logLive(video) }
                // 自己按的暂停不算卡住
                if self.userPaused { still = 0; continue }
                let now = self.player.currentTime().seconds
                if now.isFinite, now > last + 0.2 { last = now; still = 0; continue }
                still += 1
                guard still >= 5 else { continue }
                let item = self.player.currentItem
                let error = item?.errorLog()?.events.last
                let access = item?.accessLog()?.events.last
                Log.playback.error("bilibili live \(video.liveRoom, privacy: .public): stalled at \(now, privacy: .public)s, status \(item?.status.rawValue ?? -1, privacy: .public), waiting \(self.player.reasonForWaitingToPlay?.rawValue ?? "-", privacy: .public), error \(error?.errorStatusCode ?? 0, privacy: .public) \(error?.errorComment ?? "", privacy: .public), host \(self.liveHost, privacy: .public), bitrate \(Int(access?.indicatedBitrate ?? 0), privacy: .public) / observed \(Int(access?.observedBitrate ?? 0), privacy: .public)")
                let count = Date().timeIntervalSince(started) > 60 ? 1 : reconnects + 1
                guard count <= 3 else {
                    self.player.pause()
                    self.failed = true
                    self.disconnectLiveDanmaku()
                    self.toast?("无法连接直播")
                    return
                }
                self.connectLive(video, reconnects: count)
                return
            }
        }
    }

    /// 直播放着时的一笔记录：卡了几次、网速、往前缓冲了几秒（就是还剩多少余量，平时 5 秒左右）、
    /// 列表取了几次（几次是旧的）、列表里留了多少秒。只记次数、秒数和服务器的名字，不记地址（地址里带着签名）
    private func logLive(_ video: BiliVideo) async {
        guard let item = player.currentItem else { return }
        let events = item.accessLog()?.events ?? []
        let stalls = events.reduce(0) { $0 + max(0, $1.numberOfStalls) }
        let observed = Int(events.last?.observedBitrate ?? 0), indicated = Int(events.last?.indicatedBitrate ?? 0)
        let ahead = bufferedAhead()
        let stats = await liveLoader?.stats() ?? BiliHLS.LiveStats()
        Log.playback.info("bilibili live \(video.liveRoom, privacy: .public): \(stalls, privacy: .public) stalls (\(self.liveStalls, privacy: .public) notified), bitrate observed \(observed, privacy: .public) / indicated \(indicated, privacy: .public), \(ahead, format: .fixed(precision: 1), privacy: .public)s buffered, host \(self.liveHost, privacy: .public), playlists \(stats.fetched, privacy: .public) fetched / \(stats.stale, privacy: .public) stale / \(stats.keptPrevious, privacy: .public) kept previous / \(stats.failed, privacy: .public) failed, window \(stats.segments, privacy: .public) segments \(stats.seconds, format: .fixed(precision: 0), privacy: .public)s")
    }

    /// 从现在放到的地方往后，已经缓冲了几秒
    private func bufferedAhead() -> Double {
        let now = player.currentTime()
        guard let range = player.currentItem?.loadedTimeRanges.map(\.timeRangeValue).first(where: { $0.containsTime(now) }) else { return 0 }
        return max(0, (range.end - now).seconds)
    }

    /// 把这条线路交给播放器，等它准备好（最多 8 秒）。播放器说放不了就返回 false，换下一条线路；
    /// 8 秒还在缓冲的（网慢）就让它接着缓冲。等的途中换了别的、关掉了，返回 true（不用再试），也不再碰播放器
    /// 列表经过 BiliHLS.LiveLoader（不让 CDN 给旧的、多留 30 秒刚滑出去的段），段由播放器直接去 CDN 取
    /// （带着来源页和浏览器标识）。落后正在直播的地方 liveOffset 秒放，卡过之后也回到这个距离
    private func startLive(_ url: URL, _ video: BiliVideo) async -> Bool {
        let loader = BiliHLS.LiveLoader(source: url)
        let asset = AVURLAsset(url: BiliHLS.LiveLoader.entry,
                               options: ["AVURLAssetHTTPHeaderFieldsKey": ["Referer": "https://live.bilibili.com/"],
                                         AVURLAssetHTTPUserAgentKey: UserAgent.safari])
        asset.resourceLoader.setDelegate(loader, queue: loaderQueue)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = Self.liveBuffer
        item.configuredTimeOffsetFromLive = CMTime(seconds: Self.liveOffset, preferredTimescale: 600)
        item.automaticallyPreservesTimeOffsetFromLive = true
        liveLoader = loader   // 播放器只弱引用它，要一直留着
        liveHost = url.host ?? ""
        liveStalls = 0
        clearDanmaku()   // 换了线路、重新连：时间轴是新的，排好的弹幕对不上了（弹幕服务器接着连着）
        player.replaceCurrentItem(with: item)
        player.play()
        for _ in 0..<32 {
            try? await Task.sleep(for: .milliseconds(250))
            guard current == video, !Task.isCancelled, player.currentItem === item else { return true }
            switch item.status {
            case .readyToPlay:
                Log.playback.info("bilibili live \(video.liveRoom, privacy: .public): playing from \(url.host ?? "", privacy: .public)")
                flashControls(seconds: 4)
                return true
            case .failed:
                Log.playback.error("bilibili live \(video.liveRoom, privacy: .public): \(url.host ?? "", privacy: .public) failed: \(item.error?.localizedDescription ?? "", privacy: .public)")
                player.replaceCurrentItem(with: nil)
                return false
            default: continue
            }
        }
        return true
    }

    /// 试线路、取直播列表（BiliHLS.LiveLoader）用的连接：不存任何东西。
    /// 直播的播放列表回复里写着"可以存 300 秒"：用系统共用的连接去试，这份列表就被存进共用的缓存，
    /// 播放器之后每次刷新列表拿到的都是这份存着的旧列表——放完开头几秒就卡死（系统报 -12888
    /// "播放列表超过 1.5 倍片段时长没变"），重连也一样。试线路必须用这个单独的、不存东西的连接
    nonisolated static let probeSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }()

    /// 这条直播线路几秒内答得上来吗（拿到播放列表就算）
    private nonisolated static func reachable(_ url: URL) async -> Bool {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 4)
        request.setValue(UserAgent.safari, forHTTPHeaderField: "User-Agent")
        request.setValue("https://live.bilibili.com/", forHTTPHeaderField: "Referer")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        guard let (data, response) = try? await probeSession.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return String(decoding: data.prefix(16), as: UTF8.self).hasPrefix("#EXTM3U")
    }

    /// 暂停 / 接着放（确认键、播放键、媒体键、点画面、面板开着时按播放键，都走这里）。
    /// 直播接着放时跳回正在直播的地方（不然停了多久就落后多久）。放不了的不理
    private func togglePause() {
        guard current != nil, !failed else { return }
        if player.timeControlStatus != .paused { userPaused = true; player.pause(); report(); return }
        userPaused = false
        if isLive, let edge = player.currentItem?.seekableTimeRanges.last?.timeRangeValue.end, edge.seconds.isFinite {
            player.seek(to: edge - CMTime(seconds: Self.liveOffset, preferredTimescale: 600))
        }
        player.play()
    }

    /// 同上，顺便把控制条露出来（画面上没有别的东西盖着时）
    private func togglePauseShowingControls() {
        guard current != nil, !failed else { return }
        togglePause()
        flashControls()
    }

    /// 把看到哪了告诉哔哩哔哩，这台 Mac 上也记一份（每一 P、每一集各记各的；直播没有进度，不记）
    private func report() {
        guard let video = current, !video.isLive else { return }
        let seconds = Int(time), cid = stream?.cid ?? video.cid
        let finished = duration > 0 && duration - time < 5
        if seconds > 3 || finished {
            BiliResume.save(bvid: video.bvid, cid: cid, seconds: finished ? -1 : seconds)
            Task { [cookie] in
                await BiliAPI.reportProgress(bvid: video.bvid, cid: cid, seconds: finished ? -1 : seconds, cookie: await cookie())
            }
        }
    }

    /// 拉出下面那一块，焦点放在想要的那一排上（没有那一排就放在有的那一排）。选集停在正在放的那一集上
    private func showShelf(_ which: Shelf) {
        let available = shelves
        guard let first = available.first else { return }
        qualityMenuVisible = false
        closePanel()
        shelfFromPanel = false
        shelf = available.contains(which) ? which : first
        episodeFocus = episodeIndex ?? 0
        relatedIndex = min(relatedIndex, max(0, related.count - 1))
        controlsVisible = false
        hideControls?.cancel()
        relatedVisible = true
    }

    /// 收起下面那一块。是从右边面板的"选集"拉出来的，就回到面板、停在"选集"上（从哪里来回哪里去）
    private func leaveShelf() {
        relatedVisible = false
        guard shelfFromPanel else { return }
        shelfFromPanel = false
        openPanel()
        panelRow = .episodes
    }

    /// 这一集放完了：选集里还有下一集就接着放；没有的话，有相关视频就摆出来接着挑，没有就回列表
    private func reachedEnd() {
        guard !endHandled, current != nil else { return }
        endHandled = true
        closePanel()               // 放完时面板、清晰度栏开着：先收起来，再接下一集或摆出相关视频
        qualityMenuVisible = false
        if let index = episodeIndex, episodes.indices.contains(index + 1) {
            play(episodes[index + 1].video, exact: true)
        } else if related.isEmpty {
            stop()
        } else {
            showShelf(.related)
        }
    }

    /// 在选集里选了一集：选的就是正在放的那一集，只收起来接着看
    private func playEpisode(_ index: Int) {
        guard episodes.indices.contains(index) else { return }
        if index == episodeIndex { relatedVisible = false; return }
        play(episodes[index].video, exact: true)   // 挑的就是这一集：放它（从它自己上次停的地方接着）
    }

    func stop() {
        guard current != nil else {
            // 播放器没开：挂着的只该是提前准备的那个。别的（比如关掉的途中才连上的直播）摘掉，免得在后台响
            if let item = player.currentItem, item !== warmed?.item {
                player.pause()
                player.replaceCurrentItem(with: nil)
            }
            return
        }
        leaveCurrent()
        episodes = []
        player.pause()
        player.replaceCurrentItem(with: nil)
        current = nil
        showing = false
        noteWaiting(false)
        controlsVisible = false
        hideControls?.cancel()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    // MARK: 键盘上的媒体键（播放 / 暂停、上一首 / 下一首）

    /// 正在看的视频告诉系统：键盘上的媒体键、控制中心都会找到这里
    /// 播放器说在等数据 / 不等了（见 buffering）
    private func noteWaiting(_ waiting: Bool) {
        guard waiting else {
            bufferingSoon?.cancel()
            bufferingSoon = nil
            if buffering { withAnimation(.easeOut(duration: 0.2)) { buffering = false } }
            return
        }
        guard bufferingSoon == nil, !buffering else { return }
        bufferingSoon = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.bufferingSoon = nil
            if self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                withAnimation(.easeOut(duration: 0.2)) { self.buffering = true }
            }
        }
    }

    private func publishNowPlaying() {
        guard let current else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: current.title,
            MPMediaItemPropertyArtist: current.owner,
            MPMediaItemPropertyPlaybackDuration: duration > 0 ? duration : Double(current.duration),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: displayTime(),
            MPNowPlayingInfoPropertyPlaybackRate: paused ? 0.0 : Double(player.defaultRate),
            MPNowPlayingInfoPropertyIsLiveStream: current.isLive,
        ]
        MPNowPlayingInfoCenter.default().playbackState = paused ? .paused : .playing
    }

    /// 播放 / 暂停键：暂停或接着放；下一首 / 上一首：快进 / 快退 10 秒（和 Apple TV 看视频时一样）
    private func wireMediaKeys() {
        let center = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor (BilibiliNativePlayer) -> Void) {
            command.addTarget { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.current != nil else { return }
                    action(self)
                }
                return .success
            }
        }
        on(center.togglePlayPauseCommand) { $0.togglePauseShowingControls() }
        on(center.playCommand) { if $0.player.timeControlStatus == .paused { $0.togglePauseShowingControls() } }
        on(center.pauseCommand) { if $0.player.timeControlStatus != .paused { $0.togglePauseShowingControls() } }
        on(center.nextTrackCommand) { $0.seek(by: 10) }
        on(center.previousTrackCommand) { $0.seek(by: -10) }
    }

    // MARK: 按键

    func handle(_ command: RemoteCommand) -> Outcome {
        if scrubbing { endScrub() }   // 拖进度时按了别的键：先在拖到的地方落下
        if panelVisible {
            handlePanel(command)
            return .stay
        }
        if qualityMenuVisible {
            switch command {
            // 清晰度是从上面下来的一横排（和下面的相关视频对称）：左右选，确认切换，按下或返回收起
            case .move(.left): withAnimation(Motion.focus) { qualityIndex = max(0, qualityIndex - 1) }
            case .move(.right): withAnimation(Motion.focus) { qualityIndex = min(qualities.count - 1, qualityIndex + 1) }
            case .select: if qualities.indices.contains(qualityIndex) { switchQuality(to: qualities[qualityIndex]) }
            // 清晰度栏是往下拉出来的：往上推回去（或返回）才收起；再往下拉不动
            case .back, .move(.down): qualityMenuVisible = false
            case .playPause: togglePause()
            default: break
            }
            return .stay
        }
        if relatedVisible {
            // 两排：上面"选集"、下面"相关视频"。左右在这一排里走；往上滑（键盘上是下）到下一排，
            // 往下滑（键盘上是上）回到上一排，在最上面那排再往下滑就收起来
            let rows = shelves, row = rows.firstIndex(of: shelf) ?? 0
            switch command {
            case .move(.left):
                if shelf == .episodes { withAnimation(BiliMotion.step()) { episodeFocus = max(0, episodeFocus - 1) } }
                else { withAnimation(BiliMotion.step()) { relatedIndex = max(0, relatedIndex - 1) } }
            case .move(.right):
                if shelf == .episodes { withAnimation(BiliMotion.step()) { episodeFocus = min(episodes.count - 1, episodeFocus + 1) } }
                else { withAnimation(BiliMotion.step()) { relatedIndex = min(related.count - 1, relatedIndex + 1) } }
            case .select:
                if shelf == .episodes { playEpisode(episodeFocus) }
                else if related.indices.contains(relatedIndex) { play(related[relatedIndex]) }
            case .move(.down): if row + 1 < rows.count { shelf = rows[row + 1] }
            case .move(.up): if row > 0 { shelf = rows[row - 1] } else { leaveShelf() }
            case .back:
                // 从右边面板的"选集"进来的：回到面板；播完后摆出来的：返回就是回列表；播放中拉出来的：返回只是收起
                if !shelfFromPanel, duration > 0, duration - time < 2 { return .close }
                leaveShelf()
            case .playPause: togglePause()
            default: break
            }
            return .stay
        }
        switch command {
        case .back: return .close
        case .select, .playPause: togglePauseShowingControls()
        case .move(.left), .seek(forward: false): seek(by: -10)
        case .move(.right), .seek(forward: true): seek(by: 10)
        case .move(.down): if shelves.isEmpty { flashControls() } else { showShelf(.episodes) }   // 有选集先停在选集上
        case .move(.up): if !openQualityMenu() { flashControls() }
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
        loading?.cancel()   // 连着换了两次：只要最后选的那一档
        loading = Task { @MainActor [weak self] in
            guard let self, let prepared = await self.prepare(video), !Task.isCancelled, self.current == video else { return }
            self.player.replaceCurrentItem(with: prepared.item)
            self.stream = prepared.stream
            self.qualityID = prepared.stream.qualityID
            self.qualities = prepared.stream.available
            await self.player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            if !wasPaused { self.player.play() }
            self.flashControls()
        }
    }

    /// 转盘用的细调：一格几秒
    func scrub(by delta: Double) { seek(by: delta) }

    // MARK: 双指左右滑拖进度、点画面暂停

    /// 进度条、时间显示用：每一帧直接问播放器（以前半秒才更新一次，进度条一跳一跳的）；拖进度时是拖到的位置
    func displayTime() -> Double {
        if scrubbing { return scrubTarget }
        let now = player.currentTime().seconds
        return now.isFinite ? now : time
    }

    /// 手指在触控板上横着滑了 points 这么远（往右为正）：进度跟着走。一次滑多远按视频长短算——
    /// 短视频滑一下几十秒，长视频滑一下几分钟
    /// 返回这一下有没有跨过一个档位（每一段响一声"嗒"）
    @discardableResult
    func scrubMove(points: Double) -> Bool {
        guard startScrubbing() else { return false }
        let perPoint = max(0.05, min(1.0, duration / 1500))
        let before = scrubTarget
        scrubTarget = max(0, min(duration - 1, scrubTarget + points * perPoint))
        time = scrubTarget
        return ScrubDetent.crossed(from: before, to: scrubTarget, duration: duration)
    }

    /// 鼠标在进度条上按住拖（或点一下）：进度跟着鼠标走，松开才跳过去接着放——和网易云的进度条一样
    func scrub(toFraction fraction: Double) {
        guard startScrubbing() else { return }
        scrubTarget = max(0, min(duration - 1, fraction * duration))
        time = scrubTarget
    }

    /// 开始拖：画面先停住，控制条一直露着。还没准备好的视频不能拖
    private func startScrubbing() -> Bool {
        guard !isLive, let item = player.currentItem, item.status == .readyToPlay, duration > 0 else { return false }
        if !scrubbing {
            scrubWasPlaying = player.timeControlStatus != .paused
            scrubTarget = displayTime()
            scrubbing = true
            player.pause()
            hideControls?.cancel()
            controlsVisible = true
        }
        return true
    }

    /// 鼠标在画面上动了：露出控制条（标题、进度条），几秒不动再收起——和平常看视频的网页一样。
    /// 面板、清晰度栏、相关视频开着时不出来
    func pointerMoved() {
        guard current != nil, !panelVisible, !qualityMenuVisible, !relatedVisible, !scrubbing else { return }
        let now = Date()
        guard now.timeIntervalSince(lastReveal) > 0.4 else { return }   // 鼠标一直在动时不用每一下都重新计时
        lastReveal = now
        flashControls()
    }

    /// 手指抬起：精确跳到拖到的那一秒，原来在放就接着放
    func endScrub() {
        guard scrubbing else { return }
        let target = scrubTarget, resume = scrubWasPlaying
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: CMTime(seconds: 0.2, preferredTimescale: 600), toleranceAfter: CMTime(seconds: 0.2, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scrubbing = false
                if resume { self.player.play() }
                self.flashControls()
                self.publishNowPlaying()
            }
        }
    }

    /// 点一下画面：清晰度栏、相关视频、右边的面板开着就先收起；不然暂停 / 继续（和网易云点封面一样）
    func tapVideo() {
        if qualityMenuVisible || relatedVisible || panelVisible {
            qualityMenuVisible = false
            relatedVisible = false
            closePanel()
            return
        }
        togglePauseShowingControls()
    }

    private func seek(by delta: Double) {
        guard !isLive else { flashControls(); return }   // 直播不能快进快退
        guard let item = player.currentItem, item.status == .readyToPlay else { return }
        let total = item.duration.seconds.isFinite ? item.duration.seconds : duration
        let target = max(0, min(total - 2, time + delta))
        time = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: CMTime(seconds: 1, preferredTimescale: 600),
                    toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600))
        flashControls()
        publishNowPlaying()
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

// MARK: - 右边的面板：长按确认拉出来

extension BilibiliNativePlayer {
    /// 面板里现在有哪几行：知道 UP 主是谁就有"UP 主"；登录了才有点赞、投币、收藏；倍速、字幕、弹幕一直有
    var panelRows: [PanelRow] {
        var rows: [PanelRow] = []
        if (info?.owner.mid ?? current?.ownerMid ?? 0) > 0 { rows.append(.up) }
        guard !isLive else { return rows + [.danmaku] }   // 直播间：主播的主页和弹幕（没有点赞投币、倍速、字幕）
        if accountMid() > 0 { rows += [.like, .coin, .favorite] }
        if !episodes.isEmpty { rows.append(.episodes) }   // 分 P、合集才有
        rows += [.speed, .subtitles, .danmaku]   // 字幕一直在（这个视频没有时写着"无"），弹幕开关一直在
        return rows
    }

    /// 还能投几个：原创最多两个、转载一个，减去已经投了的
    var coinChoices: [Int] {
        let limit = (info?.original ?? true) ? 2 : 1
        return (1...2).filter { $0 <= limit - relation.coins }
    }

    /// 展开的小列表里有几项
    var panelListCount: Int {
        switch panelList {
        case .coins: coinChoices.count
        case .speed: Self.speeds.count
        case .subtitles: subtitleTracks.count + 1
        case .unfavorite: 2
        case .danmaku: danmakuOptions.count
        case nil: 0
        }
    }

    /// 长按确认（或用鼠标在画面上按住）：从右边拉出面板。视频接着放
    @discardableResult
    func openPanel() -> Bool {
        guard current != nil, !failed, !panelVisible else { return false }
        if scrubbing { endScrub() }
        qualityMenuVisible = false
        relatedVisible = false
        controlsVisible = false
        hideControls?.cancel()
        panelList = nil
        panelRow = panelRows.first ?? .speed
        panelVisible = true
        refreshRelation()
        return true
    }

    func closePanel() {
        panelVisible = false
        panelList = nil
    }

    /// 面板是从右边拉出来的抽屉：上下挑一行，确认；往右滑（键盘上是左）推回去，返回也收起。
    /// 展开的小列表里返回是回到上一层
    func handlePanel(_ command: RemoteCommand) {
        if let list = panelList {
            switch command {
            case .move(.up): panelListIndex = max(0, panelListIndex - 1)
            case .move(.down): panelListIndex = max(0, min(panelListCount - 1, panelListIndex + 1))
            case .select: choose(in: list, panelListIndex)
            case .back: panelList = nil
            case .move(.left): closePanel()
            case .playPause: togglePause()
            default: break
            }
            return
        }
        let rows = panelRows, index = panelIndex
        switch command {
        case .move(.up): panelRow = rows[max(0, index - 1)]
        case .move(.down): panelRow = rows[min(rows.count - 1, index + 1)]
        case .select: if rows.indices.contains(index) { activate(rows[index]) }
        case .back, .move(.left): closePanel()
        case .playPause: togglePause()
        default: break
        }
    }

    /// 鼠标点面板里的某一行 / 小列表里的某一项
    func tapPanelRow(_ index: Int) {
        guard panelVisible else { return }
        if panelList != nil { panelList = nil }
        let rows = panelRows
        guard rows.indices.contains(index) else { return }
        panelRow = rows[index]
        handlePanel(.select)
    }

    func tapPanelList(_ index: Int) {
        guard panelVisible, panelList != nil else { return }
        panelListIndex = index
        handlePanel(.select)
    }

    /// 去这个视频 UP 主的主页（面板里的"UP 主"，或者用鼠标点标题下面的名字）。
    /// 带上看到的位置：在主页上返回，回到这个视频的这一帧停着，按播放接着放
    func goToUploader() {
        guard var video = current else { return }
        let owner = info?.owner ?? BiliUser(mid: video.ownerMid, name: video.owner)
        guard owner.mid > 0 else { return }
        if scrubbing { endScrub() }
        video.progress = Int(displayTime())
        if video.cid == 0, let cid = stream?.cid { video.cid = cid }
        openUp?(owner, video)
    }

    private var aid: Int { info?.aid ?? current?.aid ?? 0 }

    private func activate(_ row: PanelRow) {
        switch row {
        case .up:
            goToUploader()
        case .like:
            toggleLike()
        case .coin:
            guard !coinChoices.isEmpty else { return }   // 投满了：面板上那一格已经写着"已投"
            panelListIndex = 0
            panelList = .coins
        case .favorite:
            // 取消收藏要再确认一次，默认停在"取消"上
            if relation.favorited { panelListIndex = 0; panelList = .unfavorite } else { setFavorite(true) }
        case .speed:
            panelListIndex = Self.speeds.firstIndex(of: speed) ?? 3
            panelList = .speed
        case .subtitles:
            guard !subtitleTracks.isEmpty else { return }   // 没有字幕：面板上那一格写着"无"
            panelListIndex = subtitleTrack.flatMap { subtitleTracks.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            panelList = .subtitles
        case .danmaku:
            // 弹幕的开关和样式：在面板里换成一列，每一项按确认换到下一个值，改了马上看得到
            panelListIndex = 0
            panelList = .danmaku
        case .episodes:
            // 收起面板，拉出下面那一块，停在选集那一排正在放的这一集上；返回时回到面板
            closePanel()
            showShelf(.episodes)
            shelfFromPanel = relatedVisible
        }
    }

    private func choose(in list: PanelList, _ index: Int) {
        switch list {
        case .coins:
            if coinChoices.indices.contains(index) { addCoins(coinChoices[index]) }
        case .speed:
            if Self.speeds.indices.contains(index) { speed = Self.speeds[index] }
        case .subtitles:
            if index == 0 {
                subtitlesOn = false
                showSubtitles(nil)
            } else if subtitleTracks.indices.contains(index - 1) {
                subtitlesOn = true
                showSubtitles(subtitleTracks[index - 1])
            }
        case .unfavorite:
            if index == 1 { setFavorite(false) }
        case .danmaku:
            cycleDanmakuOption(index)
            return   // 这一列留着，可以接着改别的
        }
        panelList = nil
    }

    // MARK: 取信息、点赞、投币、收藏

    func loadInfo(_ video: BiliVideo) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let cookie = await self.cookie()
            let key = await self.signingKey()
            let edits = self.relationEdits
            async let details = BiliAPI.info(bvid: video.bvid, key: key, cookie: cookie)
            async let mine = BiliAPI.relation(bvid: video.bvid, cookie: cookie)
            let (found, relation) = await (details, mine)
            guard self.current == video else { return }
            if let found {
                self.info = found
                if !found.episodes.isEmpty { self.episodes = found.episodes }
                self.noteSeason()
            }
            if let relation, self.relationEdits == edits { self.relation = relation; self.likeConfirmed = relation.liked }
        }
    }

    /// 合集：记下这一集属于哪个合集、正在看的是哪一集（下次从合集里别的入口进来接着看它）。
    /// 要等两样都有了才记：视频的信息（有哪几集）和 begin 定下来的流（begin 先决定要不要"接着看上次那一集"，
    /// 在它之前记的话，点进来的这一集先被记成了"上次看的"，就永远接不上了）。两样谁后到谁来记
    private func noteSeason() {
        guard var watching = current, let stream, let episodes = info?.episodes, !episodes.isEmpty else { return }
        if stream.cid > 0 { watching.cid = stream.cid }
        BiliResume.noteSeason(episodes.map(\.video), watching: watching)
    }

    /// 打开面板时再问一次（可能刚在手机上点过赞）
    private func refreshRelation() {
        guard let video = current, !video.isLive, accountMid() > 0 else { return }
        let edits = relationEdits
        Task { @MainActor [weak self] in
            guard let self else { return }
            let mine = await BiliAPI.relation(bvid: video.bvid, cookie: await self.cookie())
            if self.current == video, self.relationEdits == edits, let mine { self.relation = mine; self.likeConfirmed = mine.liked }
        }
    }

    /// 点赞 / 取消：面板上马上变；连着按的话，等手停下来 0.6 秒，只把最后的样子告诉哔哩哔哩一次
    private func toggleLike() {
        guard current != nil, aid > 0 else { return }
        relationEdits += 1
        relation.liked.toggle()
        info?.likes += relation.liked ? 1 : -1
        likeSettle?.cancel()
        likeSettle = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled else { return }
            self.likeSettle = nil
            self.syncLike()
        }
    }

    /// 离开这个视频（换片、关掉）时还有点赞没落定（在等手停下来，或者发出去的途中又按了）：现在就把最后的样子发过去。
    /// 结果不再显示（人已经走了）
    private func flushLike() {
        let pending = likeSettle != nil || likeSending
        likeSettle?.cancel()
        likeSettle = nil
        let want = relation.liked, id = aid
        guard pending, id > 0, want != likeConfirmed else { return }
        Task { [cookie] in _ = await BiliAPI.setLiked(aid: id, want, cookie: await cookie()) }
    }

    /// 把面板上的点赞样子同步到账号上：已经一样就不发；在路上时不再发，等它回来再看要不要补一次
    private func syncLike() {
        guard let video = current, !likeSending else { return }
        let want = relation.liked
        guard want != likeConfirmed else { return }
        likeSending = true
        let id = aid
        Task { @MainActor [weak self] in
            guard let self else { return }
            let reply = await BiliAPI.setLiked(aid: id, want, cookie: await self.cookie())
            guard self.current == video else { return }
            self.likeSending = false
            if reply.ok {
                self.likeConfirmed = want
                if self.relation.liked != want { self.syncLike() }   // 发的途中又按了：把最新的补发过去
            } else {
                // 没成功：面板回到账号上的样子，把哔哩哔哩的原话告诉人
                let back = self.likeConfirmed ?? !want
                if self.relation.liked != back {
                    self.relation.liked = back
                    self.info?.likes += back ? 1 : -1
                }
                self.relationEdits += 1
                self.toast?(reply.message.map { "点赞失败：\($0)" } ?? "点赞失败")
            }
        }
    }

    private func addCoins(_ count: Int) {
        guard let video = current, aid > 0, !sending.contains(.coin) else { return }
        let id = aid
        sending.insert(.coin)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let reply = await BiliAPI.addCoins(aid: id, count: count, cookie: await self.cookie())
            guard self.current == video else { return }
            self.sending.remove(.coin)
            if reply.ok {
                self.relationEdits += 1
                self.relation.coins += count
                self.info?.coins += count
            } else {
                self.toast?(reply.message ?? "投币失败")
            }
        }
    }

    private func setFavorite(_ on: Bool) {
        guard let video = current, aid > 0, !sending.contains(.favorite) else { return }
        let id = aid, mid = accountMid()
        sending.insert(.favorite)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let cookie = await self.cookie()
            let ok: Bool
            if on { ok = await BiliAPI.addFavorite(aid: id, mid: mid, cookie: cookie) }
            else { ok = await BiliAPI.removeFavorite(aid: id, mid: mid, cookie: cookie) }
            guard self.current == video else { return }
            self.sending.remove(.favorite)
            if ok {
                self.relationEdits += 1
                self.relation.favorited = on
                self.info?.favorites += on ? 1 : -1
            } else {
                self.toast?("收藏失败")
            }
        }
    }

    // MARK: 弹幕

    func loadDanmaku(_ video: BiliVideo, cid: Int) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let cookie = await self.cookie()
            let all = await BiliAPI.danmaku(cid: cid, cookie: cookie)
            guard self.current == video, self.danmakuOn else { return }
            self.danmakuAll = all
            self.relayoutDanmaku()
            Log.playback.info("bilibili danmaku: \(all.count, privacy: .public) loaded, \(self.danmaku.placed.count, privacy: .public) placed")
        }
    }

    /// 按现在的弹幕设置把取回来的弹幕重新排一遍（几千条也只要一眨眼）。直播间接着从排到的地方往后排
    private func relayoutDanmaku() {
        let style = danmakuStyle
        danmakuLanes = BiliDanmakuLayout.Lanes(danmakuLayout)
        danmaku.placed = danmakuAll.filter { style.keeps($0) }.compactMap { danmakuLanes.place($0) }
    }

    /// 清掉这个视频（直播间）的弹幕
    private func clearDanmaku() {
        danmakuAll = []
        danmaku.placed = []
        danmakuLanes = BiliDanmakuLayout.Lanes(danmakuLayout)
    }

    // MARK: 直播间的弹幕

    /// 连上这个直播间的弹幕服务器（BiliLiveDanmakuConnection）。不等它：连不上画面照放，只是没有弹幕
    private func connectLiveDanmaku(_ video: BiliVideo) {
        disconnectLiveDanmaku()
        guard danmakuOn, video.isLive else { return }
        let uid = accountMid()
        liveDanmakuTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let cookie = await self.cookie()
            guard let key = await self.signingKey(), !Task.isCancelled, self.current == video else { return }
            let connection = BiliLiveDanmakuConnection(room: video.liveRoom, uid: cookie.contains("SESSDATA=") ? uid : 0, cookie: cookie, key: key) {
                [weak self] item in self?.showLive(item, in: video)
            }
            await connection.run()
        }
    }

    /// 断开直播间的弹幕（离开、换房间、关了弹幕、直播结束、连不上了），屏幕上的也清掉
    private func disconnectLiveDanmaku() {
        liveDanmakuTask?.cancel()
        liveDanmakuTask = nil
        clearDanmaku()
    }

    /// 直播间来了一条弹幕：按画面现在的时间排上（晚 0.3 秒，从屏幕右边进来）。暂停着、画面还没出来时不攒着；
    /// 一秒最多放 liveDanmakuPerSecond 条，一行都放不下的也不显示（和视频弹幕一样，宁可少几条也不叠在一起）
    private func showLive(_ incoming: BiliDanmaku, in video: BiliVideo) {
        guard current == video, danmakuOn, showing, !paused, let item = player.currentItem else { return }
        let now = item.currentTime().seconds
        guard now.isFinite else { return }
        if Int(now) != liveDanmakuSecond.second { liveDanmakuSecond = (Int(now), 0) }
        guard liveDanmakuSecond.shown < Self.liveDanmakuPerSecond else { return }
        let timed = BiliDanmaku(time: now + 0.3, kind: incoming.kind, size: incoming.size, color: incoming.color, text: incoming.text)
        danmakuAll.append(timed)
        if danmakuAll.count > 400 { danmakuAll.removeFirst(danmakuAll.count - 300) }   // 改设置时重新排用的，留最近的就够
        guard danmakuStyle.keeps(timed), let placed = danmakuLanes.place(timed) else { return }
        liveDanmakuSecond.shown += 1
        var list = danmaku.placed
        list.append(placed)
        // 飘出屏幕的不要了（攒够一批再丢，不用每来一条都挪一次）
        if list.count > 200 { list.removeAll { $0.item.time < now - danmakuLayout.scrollDuration - 2 } }
        danmaku.placed = list
    }

    /// 弹幕设置的几项和现在的值（设置页、右边面板里的"弹幕"列表都用它）。按确认换到下一个值
    var danmakuOptions: [(title: String, value: String)] {
        let style = danmakuStyle
        return [("弹幕", danmakuOn ? "打开" : "关闭"),
                ("显示区域", style.area.title),
                ("字号", style.size.title),
                ("速度", style.speed.title),
                ("不透明度", style.opacity.title),
                ("顶部/底部弹幕", style.fixed ? "打开" : "关闭"),
                ("彩色弹幕", style.colored ? "打开" : "关闭")]
    }

    func cycleDanmakuOption(_ index: Int) {
        func next<T: CaseIterable & Equatable>(_ value: T) -> T {
            let all = Array(T.allCases)
            return all[((all.firstIndex(of: value) ?? 0) + 1) % all.count]
        }
        switch index {
        case 0: danmakuOn.toggle()
        case 1: danmakuStyle.area = next(danmakuStyle.area)
        case 2: danmakuStyle.size = next(danmakuStyle.size)
        case 3: danmakuStyle.speed = next(danmakuStyle.speed)
        case 4: danmakuStyle.opacity = next(danmakuStyle.opacity)
        case 5: danmakuStyle.fixed.toggle()
        case 6: danmakuStyle.colored.toggle()
        default: break
        }
    }

    // MARK: 字幕

    func loadSubtitles(_ video: BiliVideo, cid: Int) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let cookie = await self.cookie()
            let key = await self.signingKey()
            let tracks = await BiliAPI.subtitleTracks(bvid: video.bvid, cid: cid, key: key, cookie: cookie)
            Log.playback.info("bilibili subtitles: \(tracks.count, privacy: .public) tracks, signed \(key != nil, privacy: .public)")
            guard self.current == video else { return }
            self.subtitleTracks = tracks
            if self.subtitlesOn, let pick = Self.preferredTrack(tracks) { self.showSubtitles(pick) }
        }
    }

    /// 自动打开时挑哪一条：UP 主上传的中文优先，其次自动生成的中文，都没有就第一条
    static func preferredTrack(_ tracks: [BiliSubtitleTrack]) -> BiliSubtitleTrack? {
        tracks.first { $0.language.hasPrefix("zh") } ?? tracks.first { $0.language.hasPrefix("ai-zh") } ?? tracks.first
    }

    private func showSubtitles(_ track: BiliSubtitleTrack?) {
        subtitleTrack = track
        subtitleCues = []
        guard let track, let video = current else { return }
        Task { @MainActor [weak self] in
            let cues = await BiliAPI.subtitleCues(track)
            guard let self, self.current == video, self.subtitleTrack == track else { return }
            self.subtitleCues = cues
        }
    }
}

// MARK: - 手机遥控器上的快捷键（见 RemoteShortcuts）：和按上键、面板、选集里的是同一些动作

extension BilibiliNativePlayer {
    /// 开着一个视频、没放坏：面板里的那些能用
    var remoteReady: Bool { current != nil && !failed }

    /// 弹幕开 / 关（同面板"弹幕"那一列的第一项）。开没开，手机上的按钮和屏幕上的弹幕已经看得出
    func toggleDanmaku() {
        danmakuOn.toggle()
    }

    /// 清晰度的简写（手机上的快捷键写得下）：4K、1080P60、1080P+（高码率）、720P；还没取到流时 nil
    var qualityShortName: String? {
        guard qualityID > 0 else { return nil }
        return BiliStream.name(of: qualityID).replacingOccurrences(of: " 60 帧", with: "60").replacingOccurrences(of: " 高码率", with: "+")
    }

    /// 不止一档清晰度可选（直播、还没取到流时没有）
    var canOpenQualityMenu: Bool { current != nil && qualities.count > 1 }

    /// 从上面拉下清晰度栏，停在现在这一档上（同播放时按上键）。面板、下面那一块开着就先收起
    @discardableResult
    func openQualityMenu() -> Bool {
        guard canOpenQualityMenu else { return false }
        if scrubbing { endScrub() }
        closePanel()
        relatedVisible = false
        shelfFromPanel = false
        qualityIndex = qualities.firstIndex(of: qualityID) ?? 0
        controlsVisible = false
        hideControls?.cancel()
        qualityMenuVisible = true
        return true
    }

    /// 面板里现在有这一行（直播只有 UP 主和弹幕，没登录没有点赞投币收藏）
    func panelOffers(_ row: PanelRow) -> Bool { remoteReady && panelRows.contains(row) }

    /// 拉出右边的面板，停在这一行上按一下确认：倍速、字幕、投币展开它们的小列表，收藏过的是"取消收藏？"
    /// （默认停在"取消"上）——和在面板里选它一模一样
    @discardableResult
    func openPanel(at row: PanelRow) -> Bool {
        guard panelOffers(row) else { return false }
        if scrubbing { endScrub() }
        if !panelVisible { openPanel() }
        panelList = nil
        panelRow = row
        activate(row)
        return true
    }

    /// 收藏：没收藏的直接收藏（同面板里选"收藏"）；收藏过的拉出面板问一次，不会一按就取消
    @discardableResult
    func favoriteFromRemote() -> Bool {
        guard panelOffers(.favorite) else { return false }
        if relation.favorited { return openPanel(at: .favorite) }
        setFavorite(true)
        return true
    }

    /// 分了好几 P、在合集里：有选集可挑
    var canShowEpisodes: Bool { current != nil && episodes.count > 1 }

    /// 拉出下面那一块，停在选集那一排正在放的这一集上（同播放时按下键）
    @discardableResult
    func showEpisodes() -> Bool {
        guard canShowEpisodes else { return false }
        if scrubbing { endScrub() }
        showShelf(.episodes)
        return true
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
    /// 鼠标停在进度条上（变粗一点）；按键、滑动时收起
    @State private var barHovered = false
    /// 下面那一块的卡片现在要不要建：拉出来时建，收起来滑出屏幕后拆掉（合集几百集也不在后面白白排着、下封面）
    @State private var shelfAlive = false
    @ObservedObject private var pointer = PointerActivity.shared

    var body: some View {
        ZStack {
            Color.black
            PlayerSurface(player: player.player)
            // 弹幕：盖在画面上、在字幕和控制条下面；只占屏幕上半部分（见 BiliDanmakuView）
            BilibiliDanmakuSurface(player: player)
            TVCanvas { overlay }
        }
        .ignoresSafeArea()
    }

    @Namespace private var glass

    /// 托字用的暗角：靠边最深，按缓出曲线很快衰减，尾部淡得看不出边界。
    /// 普通的线性渐变中段偏重、收尾拖得长，看起来就是"一大片阴影"；这条曲线同样的深度下显得轻得多。
    private static func scrim(strength: Double, from edge: UnitPoint) -> LinearGradient {
        let curve: [(Double, Double)] = [(0, 1), (0.19, 0.738), (0.34, 0.541), (0.47, 0.382), (0.565, 0.278), (0.65, 0.194),
                                         (0.73, 0.126), (0.802, 0.075), (0.861, 0.042), (0.91, 0.021), (0.952, 0.008),
                                         (0.982, 0.002), (1, 0)]
        return LinearGradient(stops: curve.map { .init(color: .black.opacity(strength * $0.1), location: $0.0) },
                              startPoint: edge, endPoint: edge == .top ? .bottom : .top)
    }

    private static let shelfHeight: CGFloat = 380
    private static let shelfGap: CGFloat = 40

    /// 下面那一块里的一张卡片要显示的东西
    private struct ShelfCard {
        let cover: URL?
        let duration: String?
        let title: String
        /// 左上角的小标签（选集里的"P2""第 2 集"）；正在放的那一集是粉色的
        let badge: String?
        let playing: Bool
    }

    /// 下面那一块里的一排：选集，或者相关视频
    @ViewBuilder private func shelfRow(_ shelf: BilibiliNativePlayer.Shelf, w: CGFloat) -> some View {
        let active = player.shelf == shelf
        switch shelf {
        case .episodes:
            let playing = player.episodeIndex
            let count = player.episodes.count
            cardRow(title: "选集", note: playing.map { "\($0 + 1)/\(count)" } ?? "\(count) 集",
                    count: count, focus: player.episodeFocus, active: active, w: w) { index in
                let episode = player.episodes[index]
                return ShelfCard(cover: episode.video.cover, duration: episode.video.duration > 0 ? episode.video.durationText : nil,
                                 title: episode.title.isEmpty ? episode.label : episode.title, badge: episode.label, playing: index == playing)
            }
        case .related:
            cardRow(title: "相关视频", note: nil, count: player.related.count, focus: player.relatedIndex, active: active, w: w) { index in
                let item = player.related[index]
                return ShelfCard(cover: item.cover, duration: item.duration > 0 ? item.durationText : nil, title: item.title, badge: nil, playing: false)
            }
        }
    }

    /// 一排卡片，靠左排（和列表页的卡片排一个摆法：选中的在第二个位置，前面露出一张）。
    /// 选中的卡片和列表页是同一种感觉：放大、白边、投影，标题变亮并往下让一点
    private func cardRow(title: String, note: String?, count: Int, focus: Int, active: Bool, w: CGFloat,
                         card: @escaping (Int) -> ShelfCard) -> some View {
        let cardWidth: CGFloat = 340, gap: CGFloat = 34
        return VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(title).font(.system(size: 34, weight: .bold))
                if let note { Text(note).font(.system(size: 26, weight: .semibold).monospacedDigit()).opacity(0.55) }
            }
            .padding(.leading, w * 0.05)
            HStack(alignment: .top, spacing: gap) {
                ForEach(0..<count, id: \.self) { index in
                    if abs(index - focus) <= 6 {
                        let item = card(index)
                        let focused = active && index == focus
                        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
                        VStack(alignment: .leading, spacing: 16) {
                            ZStack {
                                BiliImage(url: item.cover)
                                    .frame(width: cardWidth, height: cardWidth * 9 / 16)
                                if let duration = item.duration {
                                    Text(duration)
                                        .font(.system(size: 21, weight: .semibold).monospacedDigit())
                                        .padding(.horizontal, 10).padding(.vertical, 4)
                                        .background(.black.opacity(0.66), in: Capsule())
                                        .padding(10)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                                }
                                if let badge = item.badge {
                                    HStack(spacing: 6) {
                                        if item.playing { Image(systemName: "play.fill").font(.system(size: 15, weight: .bold)) }
                                        Text(badge).font(.system(size: 21, weight: .bold).monospacedDigit())
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(item.playing ? Color(hex: "#FB7299") : .black.opacity(0.66), in: Capsule())
                                    .padding(10)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                        .opacity(index < focus - 1 ? 0 : 1)   // 再往左的隐去，不堆在屏幕边上
                    } else {
                        Color.clear.frame(width: cardWidth, height: 1)
                    }
                }
            }
            .padding(.leading, w * 0.05)
            // 走一格的动画由按键那里给（BiliMotion.step：连着走时短一些），和列表页的卡片排一样
            .offset(x: -CGFloat(max(0, focus - 1)) * (cardWidth + gap))
        }
    }

    /// 底下的标题和进度条现在露着（字幕要往上让开）
    private var barsShown: Bool {
        !player.relatedVisible && !player.qualityMenuVisible && !player.panelVisible
            && (player.controlsVisible || player.paused) && player.showing
    }

    @ViewBuilder private var overlay: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                // 放的途中在等数据：画面正中一个转圈（和开头加载时同一个），数据一来就收起
                if player.showing, player.buffering, !player.paused, !player.failed {
                    ProgressView().controlSize(.large)
                        .padding(30)
                        .background(.black.opacity(0.4), in: Circle())
                        .transition(.opacity)
                }
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

                // 字幕：在控制条、面板下面一层；控制条出来时往上让开
                if !player.subtitleCues.isEmpty, player.showing {
                    BilibiliSubtitleView(player: player, lifted: barsShown)
                }

                if player.paused, player.showing, !player.scrubbing, !player.relatedVisible, !player.qualityMenuVisible, !player.panelVisible {
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
                    // 一条竖线把"这一栏叫什么"和"能选的档位"分开（网易云的音质栏是同样的做法）
                    Capsule().fill(.white.opacity(0.35)).frame(width: 3, height: 40)
                    HStack(spacing: 10) {
                        ForEach(Array(player.qualities.enumerated()), id: \.element) { index, id in
                            let focused = index == player.qualityIndex
                            // 现在用的那一档不打勾，只是比别的亮一点
                            Text(BiliStream.name(of: id)).font(.system(size: 29, weight: focused || id == player.qualityID ? .bold : .medium))
                            .foregroundStyle(focused ? .black : .white.opacity(id == player.qualityID ? 1 : 0.6))
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
                .animation(BiliMotion.slide, value: player.qualityMenuVisible)
                .animation(BiliMotion.slide, value: player.qualityIndex)

                // 下面拉出来的一块（从屏幕下方滑上来）：上面一排"选集"（分 P、合集才有），下面一排"相关视频"。
                // 一次露一排：焦点所在的那一排停在屏幕下方，在两排之间换时整块上下滑，上面那排淡出、下面那排在屏幕外
                let shelves = player.shelves
                let focusRow = shelves.firstIndex(of: player.shelf) ?? 0
                VStack(alignment: .leading, spacing: Self.shelfGap) {
                    Spacer(minLength: 0)
                    if shelfAlive || player.relatedVisible {
                        ForEach(Array(shelves.enumerated()), id: \.element) { position, shelf in
                            shelfRow(shelf, w: w)
                                .frame(height: Self.shelfHeight, alignment: .top)
                                .opacity(position < focusRow ? 0 : 1)
                        }
                    }
                }
                .offset(y: CGFloat(max(0, shelves.count - 1 - focusRow)) * (Self.shelfHeight + Self.shelfGap))
                .padding(.bottom, 50)
                .frame(width: w, height: h, alignment: .bottomLeading)
                .animation(BiliMotion.slide, value: player.shelf)
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
                .animation(BiliMotion.slide, value: player.relatedVisible)

                if barsShown || !player.showing && !player.panelVisible {
                    VStack(alignment: .leading, spacing: 0) {
                        Spacer()
                        Text(video.title)
                            .font(.system(size: 48, weight: .bold))
                            .lineLimit(2)
                            .frame(maxWidth: w * 0.7, alignment: .leading)
                            .shadow(color: .black.opacity(0.6), radius: 12, y: 3)
                        HStack(spacing: 16) {
                            // UP 主的名字：用鼠标点一下进他的主页（和右边面板里的"UP 主"一样），返回回到这个视频
                            Text(video.owner).font(.system(size: 27)).opacity(0.7)
                                .contentShape(Rectangle())
                                .hoverLift(scale: 1.04, brighten: 0.2)
                                .onTapGesture { player.goToUploader() }
                            // 分 P、合集：正在放的是哪一集
                            if let index = player.episodeIndex {
                                let episode = player.episodes[index]
                                // "P2 · 小标题（共 12 P）"、"第 2 集（共 12 集）"
                                let unit = episode.label.hasPrefix("P") ? "P" : "集"
                                let name = episode.title.isEmpty || episode.title == video.title ? "" : " · " + episode.title
                                Text("\(episode.label)\(name)（共 \(player.episodes.count) \(unit)）")
                                    .font(.system(size: 27)).opacity(0.7).lineLimit(1)
                            }
                        }
                        .padding(.top, 10)
                        if video.isLive {
                            // 直播没有进度条：一个"直播"标记，分区和看过的人数
                            HStack(spacing: 18) {
                                HStack(spacing: 8) {
                                    Circle().fill(.white).frame(width: 10, height: 10)
                                    Text("直播").font(.system(size: 25, weight: .bold))
                                }
                                .padding(.horizontal, 16).padding(.vertical, 6)
                                .background(Color(hex: "#FB7299"), in: Capsule())
                                if let area = video.note { Text(area).font(.system(size: 25, weight: .semibold)).opacity(0.75) }
                                if video.views > 0 { Text("\(biliCount(video.views)) 人看过").font(.system(size: 25, weight: .semibold)).opacity(0.75) }
                            }
                            .padding(.top, 26)
                        } else {
                        // 进度条和时间每一帧直接问播放器，走得平滑；拖进度时跟着手走，进度条加粗一点
                        TimelineView(.animation(minimumInterval: nil, paused: player.paused && !player.scrubbing)) { _ in
                            let now = player.displayTime()
                            VStack(spacing: 0) {
                                // 鼠标：按住拖，画面停住、进度跟着走，松开跳过去接着放；点一下就是跳到那里（和网易云一样）。
                                // 能点的范围比细细一条高一些；鼠标移上去变粗一点，提示能拖
                                GeometryReader { bar in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(.white.opacity(0.28))
                                        Capsule().fill(.white)
                                            .frame(width: max(10, bar.size.width * (player.duration > 0 ? min(1, now / player.duration) : 0)))
                                    }
                                    .frame(height: player.scrubbing || (barHovered && pointer.active) ? 16 : 10)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .contentShape(Rectangle())
                                    .gesture(DragGesture(minimumDistance: 0)
                                        .onChanged { value in player.scrub(toFraction: Double(value.location.x / max(1, bar.size.width))) }
                                        .onEnded { _ in player.endScrub() })
                                    .onHover { inside in withAnimation(Motion.focus) { barHovered = inside } }
                                }
                                .frame(height: 40)
                                .padding(.top, 19)
                                HStack {
                                    Text(clockText(now))
                                    Spacer()
                                    Text(clockText(player.duration))
                                }
                                .font(.system(size: 25, weight: .semibold).monospacedDigit())
                                .padding(.top, 11)
                            }
                        }
                        .animation(.easeOut(duration: 0.15), value: player.scrubbing)
                        }
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
            // 点一下画面（哪里都行，包括底下托字的暗角）：暂停 / 继续；清晰度栏、相关视频、右边的面板开着时先收起。
            // 按住半秒：从右边拉出面板（和长按确认一样）
            .contentShape(Rectangle())
            .onTapGesture { player.tapVideo() }
            .onLongPressGesture(minimumDuration: 0.5) { player.openPanel() }
            // 鼠标在画面上一动，标题和进度条就露出来（这样才拖得到进度条），几秒不动再收起
            .onContinuousHover { phase in if case .active = phase, PointerActivity.shared.active { player.pointerMoved() } }
            .onChange(of: player.relatedVisible) { _, visible in
                if visible { shelfAlive = true; return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(700))   // 等滑出屏幕的动画放完
                    if !player.relatedVisible { shelfAlive = false }
                }
            }
            .overlay { BilibiliPlayerPanel(player: player) }
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
