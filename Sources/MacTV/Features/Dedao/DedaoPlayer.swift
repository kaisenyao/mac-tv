import AVFoundation
import Combine
import SwiftUI

/// 得到的音频播放：系统播放器放得到给的地址（和得到网页版的播放器一样），接着你上次听到的地方放
///（手机上听的也算），一讲放完接下一讲（课程还没取到的讲，放到头时接着取）。
/// 听的进度照得到网页版的样子回报给得到，手机上能接着听：开始、暂停、听完时各报一次听到哪了，
/// 放着的时候每两分钟报一次；拖进度、快进快退停下来以后报一次
@MainActor
final class DedaoPlayer: ObservableObject {
    @Published private(set) var queue: [DedaoAPI.Track] = []
    @Published private(set) var index = 0
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var paused = true
    @Published private(set) var loading = false
    @Published private(set) var failure: String?
    /// 拖进度时停在哪（拖完才真的跳过去）
    @Published private(set) var scrubbing = false
    @Published private(set) var scrubTarget: Double = 0
    /// 倍速，记着下次还用
    @Published private(set) var speed: Float = UserDefaults.standard.object(forKey: "dedaoSpeed") as? Float ?? 1
    /// 一本书、一讲放完了接着放下一个（设置里能关；关了就停在最后）
    @Published var autoNext: Bool = UserDefaults.standard.object(forKey: "dedaoAutoNext") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoNext, forKey: "dedaoAutoNext") }
    }

    /// 能选的倍速：0.75 到 2，每档差 0.25
    static let speeds: [Float] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var itemWatch: Set<AnyCancellable> = []
    private var reportTimer: Timer?
    private var seekReport: Task<Void, Never>?
    /// 这一段从什么时候开始放的（回报"听了多久"用）
    private var segmentStart: Date?
    private var started = Set<String>()
    private var loadTask: Task<Void, Never>?
    /// 载入中按了暂停 / 播放：载好以后照这个来
    private var wantsPlay = true
    /// 这次打开以来每一讲听到第几秒（换一讲再回来从这里接着；比列表里带的旧进度新）
    private var positions: [String: Double] = [:]
    /// 后面还没取到的（课程的讲、那一排里的下一本书）：放到最后一个时问它要（取不到会抛错：留着它，下次再要）
    private var more: (@MainActor () async throws -> [DedaoAPI.Track])?
    /// 正在问 more 要后面的讲
    private var fetchingMore = false
    /// 第几次 play()：等着的事回来时，已经换成别的书了就不算数
    private var session = 0
    /// 还没发完的回报（退出登录前要等它们发完，不然登录信息先清掉了）
    private var reports: [Task<Void, Never>] = []
    /// 定时关闭（没开是 nil）。放在播放器里：播放界面收起、在主屏后台放着时也照样到点停
    @Published private(set) var sleep: DedaoSleepTimer?
    private var sleepTask: Task<Void, Never>?
    /// 定时到了：声音慢慢收掉（约 3 秒）再停
    private var fadeTask: Task<Void, Never>?

    var current: DedaoAPI.Track? { queue.indices.contains(index) ? queue[index] : nil }
    /// 进度条、文稿用的时间：拖的时候是要去的地方
    var shownTime: Double { scrubbing ? scrubTarget : time }

    /// 正在跳（拖完、按住快进快退松手、±几秒、换一讲载入）：跳完之前播放器报上来的还是旧位置，这段时间不用它
    ///（不然进度条和文稿会先弹回旧的地方，再跳到新的地方，看着像对不上）
    private var seeking = false
    private var seekCount = 0
    /// 拖进度、按住快进快退时：拖之前在不在放（松手后接着放）
    private var scrubWasPlaying = false

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let seconds = time.seconds
                if seconds.isFinite, !self.seeking, !self.scrubbing { self.time = seconds }
                if let length = self.player.currentItem?.duration.seconds, length.isFinite, length > 0 { self.duration = length }
                if self.loading, self.player.timeControlStatus == .playing { self.loading = false }
            }
        }
    }

    // MARK: 放

    /// 放这一串里的第几个（课程的讲、合集的书；一本书就是一个）。more：放到最后一个以后怎么接着取
    ///（课程还没取到的讲、那一排里的下一本书；给空的就是没有了；抛错是这次没取到，下次放到头、按"下一讲"时再取）
    func play(_ tracks: [DedaoAPI.Track], from start: Int, more: (@MainActor () async throws -> [DedaoAPI.Track])? = nil) {
        guard tracks.indices.contains(start) else { return }
        finishSegment(reason: "pause")
        session += 1
        queue = tracks
        index = start
        self.more = more
        wantsPlay = true
        load()
    }

    /// 载入当前这一讲（地址太旧就重新要），从 at 秒开始；没给就接着这次打开以来听到的地方、再不然是得到记的进度
    private func load(at override: Double? = nil) {
        guard let track = current else { return }
        loadTask?.cancel()
        cancelFade()
        // 上一讲先停下、摘掉：新的载不出来时不会还在后台响着
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemWatch.removeAll()
        failure = nil
        loading = true
        paused = !wantsPlay
        if scrubbing { scrubbing = false }
        let resume = override ?? positions[track.id] ?? track.resumeAt
        time = resume
        duration = track.duration
        // 载好、跳到接着听的地方之前，播放器报的是 0：不用它（不然文稿先跳回开头）
        seekCount += 1
        let count = seekCount
        seeking = true
        loadTask = Task { @MainActor in
            defer { if count == seekCount { seeking = false } }
            let fresh = await DedaoAPI.fresh(track)
            guard !Task.isCancelled, current?.id == track.id else { return }
            if queue.indices.contains(index) { queue[index] = fresh }
            guard let address = fresh.address else {
                fail("此讲无法播放")
                return
            }
            let item = AVPlayerItem(asset: AVURLAsset(url: address))
            watch(item)
            player.replaceCurrentItem(with: item)
            let at = resume >= max(0, fresh.duration - 2) ? 0 : resume   // 听完了的从头来
            if at > 1 { await player.seek(to: CMTime(seconds: at, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
            guard !Task.isCancelled, current?.id == track.id else { return }
            time = at
            if wantsPlay { begin() } else { loading = false }
        }
    }

    /// 盯着这一讲：放完了接下一讲；中途放不下去（网断了、地址过期）就停下说一声，按确认重新载入
    private func watch(_ item: AVPlayerItem) {
        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.trackEnded() } }
            .store(in: &itemWatch)
        NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.fail("播放中断，按确认重试") } }
            .store(in: &itemWatch)
        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                MainActor.assumeIsolated { if status == .failed { self?.fail("无法载入，按确认重试") } }
            }
            .store(in: &itemWatch)
    }

    private func fail(_ message: String) {
        if !paused { finishSegment(reason: "pause") }
        player.pause()
        loading = false
        paused = true
        failure = message
    }

    private func begin() {
        cancelFade()
        loading = player.timeControlStatus != .playing
        player.playImmediately(atRate: speed)
        paused = false
        segmentStart = Date()
        guard let track = current else { return }
        let first = started.insert(track.id).inserted
        report(.behavior, [["action": first ? "start" : "resume", "timestamp": Self.now, "extra": ""]])
        reportPosition()
        reportTimer?.invalidate()
        reportTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportPosition() }
        }
    }

    func togglePause() {
        guard let track = current else { return }
        // 还在载入：记下想不想放，载好了照这个来
        if loading, loadTask != nil, player.currentItem == nil {
            wantsPlay.toggle()
            paused = !wantsPlay
            return
        }
        guard paused else { pause(); return }
        wantsPlay = true
        // 出过错、地址要到超过半天（一天就过期）、或者还没载：重新载入，从刚才的地方接着
        let stale = Date().timeIntervalSince(track.fetched) > 12 * 3600
        if failure != nil || stale || player.currentItem == nil || player.currentItem?.status == .failed {
            load(at: time)
            return
        }
        // 已经放到头了：从头再来
        if duration > 0, time >= duration - 1 { seek(to: 0) }
        begin()
    }

    func pause() {
        cancelFade()
        guard !paused else { return }
        wantsPlay = false
        player.pause()
        paused = true
        finishSegment(reason: "pause")
    }

    /// 离开得到：停下，报一下听到哪了（下次进来、手机上都从这里接着听）
    func stop() {
        cancelFade()
        loadTask?.cancel()
        loadTask = nil
        if !paused { player.pause(); paused = true; finishSegment(reason: "pause") }
        wantsPlay = false
        loading = false
    }

    /// 退出登录：停下，等最后几次回报发完（要用登录信息），然后什么都不留
    func reset() async {
        stop()
        setSleep(.off)
        session += 1
        for report in reports { await report.value }
        reports = []
        player.replaceCurrentItem(with: nil)
        itemWatch.removeAll()
        queue = []
        index = 0
        time = 0
        duration = 0
        failure = nil
        positions = [:]
        more = nil
    }

    func skip(_ seconds: Double) {
        guard current != nil, duration > 0 else { return }
        seek(to: time + seconds)
    }

    /// 精确跳到某一刻（暂停着也行）。进度条、文稿马上到新位置；跳完之前播放器报上来的旧位置不用
    func seek(to target: Double, resume: Bool = false) {
        let clamped = max(0, min(duration > 0 ? duration - 1 : target, target))
        time = clamped
        seekCount += 1
        let count = seekCount
        seeking = true
        Task { @MainActor in
            await player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            guard count == seekCount else { return }   // 中途又跳了一次：以最后那次为准
            seeking = false
            // 拖完、按住快进快退松手：从那里接着放（这期间按了暂停就不放）
            if resume, !paused, !scrubbing { player.rate = speed }
        }
        guard !paused else { return }
        // 连着快进快退（按住、转盘）时不每一下都报，停下来 1.5 秒以后报一次
        seekReport?.cancel()
        seekReport = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            self.reportPosition()
        }
    }

    func setSpeed(_ value: Float) {
        speed = value
        UserDefaults.standard.set(value, forKey: "dedaoSpeed")
        if !paused { player.rate = value }
    }

    /// 上一讲 / 下一讲（跳过放不了的）
    func step(_ delta: Int) {
        guard let next = playable(from: index, by: delta) else {
            if delta > 0 { Task { @MainActor in await self.fetchMore(thenPlay: true) } }
            return
        }
        remember()
        finishSegment(reason: "pause")
        index = next
        wantsPlay = true
        load()
    }

    /// 讲目列表里选了一讲：直接放它
    func jump(toTrack target: Int) {
        guard queue.indices.contains(target), target != index, queue[target].playable else { return }
        remember()
        finishSegment(reason: "pause")
        index = target
        wantsPlay = true
        load()
    }

    var hasNext: Bool { playable(from: index, by: 1) != nil || more != nil }
    var hasPrevious: Bool { playable(from: index, by: -1) != nil }

    /// 从 at 往前 / 往后第一个放得了的
    private func playable(from at: Int, by delta: Int) -> Int? {
        var next = at + delta
        while queue.indices.contains(next) {
            if queue[next].playable { return next }
            next += delta
        }
        return nil
    }

    /// 课程放到最后一讲了：再要后面的讲接上（要到了、而且说了接着放，就放下一讲）。
    /// 这次没取到（网络）：more 留着，下次放到头、按"下一讲"时再取
    private func fetchMore(thenPlay: Bool) async {
        guard let more, !fetchingMore else { return }
        let asked = session
        fetchingMore = true
        defer { fetchingMore = false }
        let found: [DedaoAPI.Track]
        do { found = try await more() } catch {
            Log.playback.info("dedao: next lectures not fetched: \(String(describing: error), privacy: .public)")
            return
        }
        guard session == asked else { return }   // 这期间换了别的书
        let known = Set(queue.map(\.id))
        let fresh = found.filter { !known.contains($0.id) }
        if fresh.isEmpty { self.more = nil; return }
        queue += fresh
        if thenPlay, let next = playable(from: index, by: 1) {
            finishSegment(reason: "pause")
            index = next
            wantsPlay = true
            load()
        }
    }

    private func trackEnded() {
        guard let track = current else { return }
        report(.rpoint, [["model": 1, "value": 100, "timestamp": Self.now]])
        finishSegment(reason: "over")
        positions[track.id] = track.duration   // 听完了：再选它从头来
        paused = true
        time = duration
        // 定时关闭选的是"播完本讲"：这一讲放完就停在这里，定时也到此为止
        if sleep?.choice == .endOfTrack { setSleep(.off); return }
        guard autoNext else { return }         // 设置里关了"自动接着放"：停在这里
        if let next = playable(from: index, by: 1) {
            index = next
            wantsPlay = true
            load()
        } else {
            Task { @MainActor in await self.fetchMore(thenPlay: true) }
        }
    }

    /// 记下这一讲听到哪了（换讲、停下时）
    private func remember() {
        if let track = current { positions[track.id] = time }
    }

    // MARK: 定时关闭

    /// 开 / 改 / 关定时。按分钟的到点时声音在约 3 秒里收掉、停下（和平常暂停一样报听到哪了），定时清掉；
    /// "播完本讲"在这一讲放完时停。中途手动放 / 停不影响定时
    func setSleep(_ choice: DedaoSleepTimer.Choice, now: Date = Date()) {
        sleepTask?.cancel()
        sleepTask = nil
        sleep = DedaoSleepTimer(choice, now: now)
        guard let deadline = sleep?.deadline else { return }
        sleepTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            self.sleepTask = nil
            self.sleep = nil
            if !self.paused { self.fadeOutAndPause() }
        }
    }

    private func fadeOutAndPause() {
        fadeTask?.cancel()
        fadeTask = Task { @MainActor [weak self] in
            for step in 1...30 {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                self.player.volume = Float(1 - Double(step) / 30)
            }
            guard let self, !Task.isCancelled else { return }
            self.fadeTask = nil
            self.pause()
            self.player.volume = 1
        }
    }

    /// 收声音的途中按了放 / 停、换了一讲：不收了，音量回来
    private func cancelFade() {
        guard let fadeTask else { return }
        fadeTask.cancel()
        self.fadeTask = nil
        player.volume = 1
    }

    // MARK: 拖进度（双指横着滑、拖进度条、按住左右键快进快退；同网易云）

    /// 开始拖：声音先停（不算暂停，不报），进度条和文稿跟着要去的地方走，松手才真的跳过去接着放
    func beginScrub() {
        guard current != nil, duration > 0, !scrubbing else { return }
        scrubWasPlaying = !paused
        scrubTarget = time
        scrubbing = true
        if !paused { player.pause() }
        seekCount += 1   // 还没跳完的那一次作废：松手时按拖到的地方重新跳
        seeking = false
    }

    func scrub(to seconds: Double) {
        guard scrubbing, duration > 0 else { return }
        scrubTarget = max(0, min(duration - 1, seconds))
    }

    /// 双指横滑：手指滑了多远（往右为正）。返回这一下有没有跨过一个档位（响一声"嗒"）
    func scrubMove(points: Double) -> Bool {
        guard current != nil, duration > 0 else { return false }
        if !scrubbing { beginScrub() }
        let before = scrubTarget
        scrub(to: scrubTarget + points * max(0.1, min(2, duration / 1200)))
        return ScrubDetent.crossed(from: before, to: scrubTarget, duration: duration)
    }

    func endScrub() {
        guard scrubbing else { return }
        time = scrubTarget   // 先把时间放到拖到的地方再收手：文稿一刻也不会回到拖之前
        scrubbing = false
        seek(to: scrubTarget, resume: scrubWasPlaying)
    }

    // MARK: 回报

    private static var now: Int { Int(Date().timeIntervalSince1970 * 1000) }

    private var percent: Int {
        guard duration > 0 else { return 0 }
        let value = Int(time / duration * 100)
        return value >= 98 ? 100 : max(0, value)
    }

    private func reportPosition() {
        report(.rpoint, [["model": 1, "value": percent, "timestamp": Self.now]])
    }

    /// 一段放完了（暂停、听完、换一讲、离开）：报听到哪了、这一段听了多久
    private func finishSegment(reason: String) {
        reportTimer?.invalidate()
        reportTimer = nil
        seekReport?.cancel()
        remember()
        guard let start = segmentStart, current != nil else { return }
        segmentStart = nil
        let from = Int(start.timeIntervalSince1970), to = Int(Date().timeIntervalSince1970)
        if reason != "over" { reportPosition() }
        report(.behavior, [["action": reason, "timestamp": Self.now, "extra": ""]])
        if to > from { report(.time, [["model": 2, "speed": Double(speed), "scope": "\(from)-\(to)", "extra": ""]]) }
    }

    private func report(_ kind: DedaoAPI.Report, _ entries: [[String: Any]]) {
        guard let track = current, let json = try? JSONSerialization.data(withJSONObject: entries) else { return }
        reports.removeAll { $0.isCancelled }
        let task = Task.detached { await DedaoAPI.report(kind, track, json: json) }
        reports.append(task)
        if reports.count > 20 { reports.removeFirst(reports.count - 20) }
    }
}

/// 定时关闭：到第几分钟停，或者这一讲放完停
struct DedaoSleepTimer: Equatable, Sendable {
    enum Choice: Equatable, Sendable {
        case off, endOfTrack
        case minutes(Int)

        var title: String {
            switch self {
            case .off: "关闭"
            case .endOfTrack: "播完本讲"
            case .minutes(let count): "\(count) 分钟"
            }
        }
    }
    /// 能选的几种（播放界面里那一排）
    static let choices: [Choice] = [.off, .endOfTrack, .minutes(15), .minutes(30), .minutes(60)]

    let choice: Choice
    /// 按分钟的：几点停；"播完本讲"是 nil
    let deadline: Date?

    /// 不开启是 nil
    init?(_ choice: Choice, now: Date = Date()) {
        switch choice {
        case .off: return nil
        case .endOfTrack: deadline = nil
        case .minutes(let count): deadline = now.addingTimeInterval(Double(count) * 60)
        }
        self.choice = choice
    }

    /// 还剩几秒（"播完本讲"是 nil）
    func remaining(at now: Date) -> TimeInterval? {
        deadline.map { max(0, $0.timeIntervalSince(now)) }
    }

    /// 按钮上写的：还剩"14:59"，或者"本讲结束"
    func label(at now: Date) -> String {
        guard let left = remaining(at: now) else { return "本讲结束" }
        let seconds = Int(left.rounded(.up))
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}
