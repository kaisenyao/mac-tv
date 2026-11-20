import Foundation

/// 哔哩哔哩"看到哪了"在这台 Mac 上的记录，补哔哩哔哩自己记的那份：
///
/// - 哔哩哔哩自己（取流时给的 last_play_cid / last_play_time，网页版的"记忆播放"）只记一个视频最后看的那一 P
///   和时间；分 P 视频别的 P 看到哪、合集最后看的是哪一集，它不记。这里每一 P、每一集各记一个位置。
/// - 合集：记下每一集属于哪个合集、合集按顺序有哪些集，和最后看的是哪一集（从合集里别的入口点进来时，接着看那一集）。
/// 只存在这台 Mac 的偏好设置里，最多记几百条，旧的自己丢掉。每个人（个人资料）各记各的（见 ProfileSpace）
enum BiliResume {
    private static var store: UserDefaults { ProfileSpace.current.defaults }
    private static let positionsKey = "bilibiliResumePositions"
    private static let seasonsKey = "bilibiliResumeSeasons"
    /// 合集按最近看过的排（最近的在前），留多少个按它来
    private static let seasonOrderKey = "bilibiliResumeSeasonOrder"
    private static let lastKey = "bilibiliResumeLastEpisode"
    private static let cacheKey = "bilibiliResumeEpisodes"
    /// 最多记多少个合集；合集里每一集的样子最多记多少条（一个合集特别长时，至少它自己的都记着）
    static let seasonLimit = 150
    private static let episodeLimit = 1500

    private static func key(_ bvid: String, _ cid: Int) -> String { "\(bvid)#\(cid)" }

    // MARK: 每一 P、每一集看到哪

    /// 看到第几秒；-1 是看完了；没记过是 nil
    static func position(bvid: String, cid: Int) -> Int? {
        guard cid > 0, let entry = positions[key(bvid, cid)] else { return nil }
        return Int(entry[0])
    }

    static func save(bvid: String, cid: Int, seconds: Int) {
        guard !bvid.isEmpty, cid > 0 else { return }
        var all = positions
        all[key(bvid, cid)] = [Double(seconds), Date().timeIntervalSince1970]
        if all.count > 600 {
            // 只留最近的 500 条
            let keep = all.sorted { $0.value[1] > $1.value[1] }.prefix(500)
            all = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        store.set(all, forKey: positionsKey)
    }

    private static var positions: [String: [Double]] {
        store.dictionary(forKey: positionsKey) as? [String: [Double]] ?? [:]
    }

    // MARK: 合集

    /// 合集里的一集（够重新打开它的那几样）
    struct Episode: Codable, Hashable, Sendable {
        let bvid: String
        let cid: Int
        let aid: Int
        let title: String
        let cover: String?
        let duration: Int
        let owner: String
        let ownerMid: Int

        init(_ video: BiliVideo) {
            bvid = video.bvid; cid = video.cid; aid = video.aid; title = video.title
            cover = video.cover?.absoluteString; duration = video.duration; owner = video.owner; ownerMid = video.ownerMid
        }

        var video: BiliVideo {
            BiliVideo(bvid: bvid, title: title, cover: cover.flatMap(URL.init(string:)), duration: duration, owner: owner,
                      views: 0, cid: cid, aid: aid, ownerMid: ownerMid)
        }
    }

    /// 合集按顺序的每一集（用第一集的编号当这个合集的名字），和"正在看的是哪一集"。
    /// 只留最近看过的 seasonLimit 个合集；更早的连同它的"上次看的那一集"、每一集的样子一起丢掉
    static func noteSeason(_ episodes: [BiliVideo], watching: BiliVideo) {
        guard episodes.count > 1, let first = episodes.first?.bvid,
              Set(episodes.map(\.bvid)).count == episodes.count else { return }   // 分 P 是同一个视频，不算合集
        var seasons = store.dictionary(forKey: seasonsKey) as? [String: [String]] ?? [:]
        seasons[first] = episodes.map(\.bvid)
        let order = Array(([first] + seasonOrder.filter { $0 != first && seasons[$0] != nil }).prefix(seasonLimit))
        let kept = Set(order)
        seasons = seasons.filter { kept.contains($0.key) }
        store.set(seasons, forKey: seasonsKey)
        store.set(order, forKey: seasonOrderKey)
        var last = lastEpisodes.filter { kept.contains($0.key) }
        if let episode = episodes.first(where: { $0.bvid == watching.bvid }) {
            last[first] = Episode(watching.cid > 0 ? watching : episode)
        }
        if let data = try? JSONEncoder().encode(last) { store.set(data, forKey: lastKey) }
        // 合集里每一集的样子也记下来（接着看下一集时用）：从最近的合集往前，记满为止
        var known = episodeCache
        for video in episodes { known[video.bvid] = Episode(video) }
        var needed: Set<String> = []
        for season in order where needed.count < episodeLimit { needed.formUnion(seasons[season] ?? []) }
        known = known.filter { needed.contains($0.key) }
        if let data = try? JSONEncoder().encode(known) { store.set(data, forKey: cacheKey) }
    }

    private static var seasonOrder: [String] { store.stringArray(forKey: seasonOrderKey) ?? [] }

    /// 从合集里别的入口点进来（点的这一集自己没看过）：该接着看哪一集。
    /// 上次那一集没看完就是它；看完了就是它的下一集；没记录、或者就是点的这一集，是 nil
    static func continueEpisode(for bvid: String) -> Episode? {
        let seasons = store.dictionary(forKey: seasonsKey) as? [String: [String]] ?? [:]
        guard let (season, order) = seasons.first(where: { $0.value.contains(bvid) }),
              let last = lastEpisodes[season], last.bvid != bvid else { return nil }
        guard position(bvid: last.bvid, cid: last.cid) == -1 else { return last }
        // 上次那一集看完了：下一集
        guard let at = order.firstIndex(of: last.bvid), order.indices.contains(at + 1) else { return nil }
        let next = order[at + 1]
        return next == bvid ? nil : episodeCache[next]
    }

    private static var lastEpisodes: [String: Episode] {
        store.data(forKey: lastKey).flatMap { try? JSONDecoder().decode([String: Episode].self, from: $0) } ?? [:]
    }

    private static var episodeCache: [String: Episode] {
        store.data(forKey: cacheKey).flatMap { try? JSONDecoder().decode([String: Episode].self, from: $0) } ?? [:]
    }
}
