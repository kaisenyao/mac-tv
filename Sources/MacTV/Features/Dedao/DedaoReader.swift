import Combine
import Foundation

/// 正在放的那一讲 / 那本书的文稿（播放界面右边那一栏），和现在念到第几段。
///
/// - 换了一讲就去取它的文稿；取过的记着（最近 20 篇），来回切换不用再取。取不到（网络）不记，下次换回来再取。
/// - 念到第几段只看播放器报的媒体时间（同网易云的歌词）：每次时间一变就重算，拖进度、快进快退、换一讲、
///   暂停着跳，都马上按新的时间算。和听了多久、倍速、暂停过几次都没关系，所以 1.5 倍速、停停放放也对得上
@MainActor
final class DedaoReader: ObservableObject {
    enum State: Equatable {
        case idle, loading
        case ready(DedaoAPI.Transcript)
        /// 没有文稿（没买、只有音频、取不到）：放这一句介绍
        case missing(String)
    }
    @Published private(set) var state: State = .idle
    /// 念到第几段（估算的）
    @Published private(set) var line = 0
    /// 现在是哪一讲的
    private(set) var trackID: String?
    private var cache: [String: DedaoAPI.Transcript] = [:]
    private var order: [String] = []
    private var task: Task<Void, Never>?
    private var along = DedaoReadAlong()
    /// 最近一次报来的时间和时长：文稿晚到时马上按它算念到哪（暂停着不会再有新的时间报来）
    private var last: (time: Double, duration: Double) = (0, 0)

    /// 播放器换到了这一讲（nil：什么都没放）
    func show(_ track: DedaoAPI.Track?, userName: String?) {
        guard track?.id != trackID else { return }
        trackID = track?.id
        task?.cancel()
        guard let track else { set(.idle); return }
        if let known = cache[track.id] { set(Self.state(known, track)); return }
        set(.loading)
        task = Task { @MainActor in
            do {
                let transcript = try await DedaoAPI.transcript(for: track, userName: userName)
                guard !Task.isCancelled, trackID == track.id else { return }
                remember(transcript, for: track.id)
                set(Self.state(transcript, track))
            } catch {
                guard !Task.isCancelled, trackID == track.id, !DedaoAPI.isCancellation(error) else { return }
                Log.playback.info("dedao: transcript not loaded: \(String(describing: error), privacy: .public)")
                set(.missing(track.summary))
            }
        }
    }

    /// 播放器的时间变了（放着每半秒一次；拖、跳、换讲时马上）：time 是媒体时间（拖的时候是要去的地方）
    func follow(time: Double, duration: Double) {
        last = (time, duration)
        guard case .ready(let transcript) = state else { return }
        if along.follow(transcript, time: time, duration: duration), along.line != line { line = along.line }
    }

    /// 退出登录：别的账号的文稿不留
    func reset() {
        task?.cancel()
        cache = [:]
        order = []
        trackID = nil
        set(.idle)
    }

    private func set(_ value: State) {
        state = value
        along = DedaoReadAlong()
        if case .ready(let transcript) = value {
            _ = along.follow(transcript, time: last.time, duration: last.duration)
        }
        if along.line != line { line = along.line }
    }

    private static func state(_ transcript: DedaoAPI.Transcript, _ track: DedaoAPI.Track) -> State {
        transcript.paragraphs.isEmpty ? .missing(transcript.summary.isEmpty ? track.summary : transcript.summary) : .ready(transcript)
    }

    private func remember(_ transcript: DedaoAPI.Transcript, for id: String) {
        cache[id] = transcript
        order.removeAll { $0 == id }
        order.append(id)
        if order.count > 20 { cache[order.removeFirst()] = nil }
    }
}

/// 跟读：现在念到第几段。只由"现在放到第几秒"决定——不记之前走过哪，所以往回拖、往前跳、一路放过来，
/// 到了同一秒都是同一段
struct DedaoReadAlong: Equatable, Sendable {
    private(set) var line = 0

    /// 按这个时间重算；段落变了返回 true
    mutating func follow(_ transcript: DedaoAPI.Transcript, time: Double, duration: Double) -> Bool {
        let now = transcript.paragraph(at: time, duration: duration)
        guard now != line else { return false }
        line = now
        return true
    }
}
