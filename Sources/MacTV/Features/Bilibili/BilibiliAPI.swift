import CryptoKit
import Foundation

/// 一个视频卡片需要的全部信息。
struct BiliVideo: Identifiable, Hashable, Sendable {
    let bvid: String
    let title: String
    let cover: URL?
    let duration: Int
    let owner: String
    var views: Int
    /// 分 P 的编号，取流要用；0 表示列表没给，播放前再查
    var cid: Int = 0
    /// 视频的数字编号（收藏要用）和 UP 主的编号（进他的主页、关注要用）；0 表示不知道
    var aid: Int = 0
    var ownerMid: Int = 0
    /// 继续观看：已看到的秒数（-1 表示看完）；其他列表为 nil
    var progress: Int? = nil
    /// 直播间号：不是 0 就是一个正在直播的房间（卡片写"直播"，取直播流，不能拖进度）
    var liveRoom: Int = 0
    /// 看过的直播间、现在没在播（历史记录里才有）：卡片写"未开播"，选它进主播的主页
    var endedRoom: Int = 0
    /// 直播间的分区（卡片、大标题下面写的）
    var note: String? = nil
    /// UP 主 / 主播的头像（主屏顶部用；列表接口有给才有）
    var face: URL? = nil
    /// 发布时间（秒，主屏顶部的"3 小时前"用；0 表示不知道）
    var published: Int = 0

    var id: String { bvid }
    var isLive: Bool { liveRoom > 0 }
    /// 是个直播间（在播或没在播），不是视频：没有收藏、稍后再看
    var isRoom: Bool { liveRoom > 0 || endedRoom > 0 }

    var durationText: String { clockText(Double(duration)) }
    var viewsText: String { biliCount(views) }
}

/// 直播间的弹幕服务器（见 BiliAPI.liveDanmakuServer）
struct BiliLiveDanmakuServer: Sendable {
    let token: String
    let hosts: [URL]
    let buvid: String
}

/// 一条热搜
struct BiliTrend: Hashable, Sendable {
    let rank: Int
    let keyword: String
    let title: String
    let icon: URL?
}

/// 搜索历史：在这台 Mac 上搜过的词，最新的在前，最多记 20 个。每个人（个人资料）各记各的（见 ProfileSpace）
enum BiliSearchHistory {
    private static let key = "bilibiliSearchHistory"
    private static var store: UserDefaults { ProfileSpace.current.defaults }
    static var all: [String] { store.stringArray(forKey: key) ?? [] }
    static func add(_ keyword: String) {
        let word = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        store.set(Array(([word] + all.filter { $0 != word }).prefix(20)), forKey: key)
    }
    static func clear() { store.removeObject(forKey: key) }
}

/// 一个 UP 主
struct BiliUser: Hashable, Sendable {
    let mid: Int
    let name: String
    var face: URL? = nil
    var fans: Int = 0
    var videos: Int = 0
    /// 签名（他写的一句简介）：搜出来的才带
    var sign: String = ""

    var fansText: String {
        fans >= 10000 ? String(format: "%.1f万粉丝", Double(fans) / 10000) : "\(fans) 粉丝"
    }
}

/// 一条轨道（画面或声音）：它在几台服务器上的地址，以及文件开头"初始化段"和"索引"的位置
struct BiliTrack: Sendable {
    let urls: [URL]
    let initRange: String
    let indexRange: String
    let codecs: String
    let bandwidth: Int
    let width: Int
    let height: Int

    init?(_ json: [String: Any]) {
        let base = (json["segment_base"] as? [String: Any]) ?? (json["SegmentBase"] as? [String: Any]) ?? [:]
        guard let initRange = (base["initialization"] ?? base["Initialization"]) as? String,
              let indexRange = (base["index_range"] ?? base["indexRange"]) as? String else { return nil }
        urls = ([json["baseUrl"] as? String ?? ""] + (json["backupUrl"] as? [String] ?? [])).compactMap(URL.init(string:))
            // 不要 P2P 节点（mcdn 之类），它们经常连不上
            .filter { !($0.host ?? "").contains("mcdn") && !($0.host ?? "").contains("szbdyd") }
        guard !urls.isEmpty else { return nil }
        self.initRange = initRange
        self.indexRange = indexRange
        codecs = json["codecs"] as? String ?? ""
        bandwidth = json["bandwidth"] as? Int ?? 0
        width = json["width"] as? Int ?? 0
        height = json["height"] as? Int ?? 0
    }
}

/// 一个视频的画面轨和声音轨（哔哩哔哩把两者分开给）
struct BiliStream: Sendable {
    let video: BiliTrack
    let audio: BiliTrack
    let cid: Int
    /// 这次实际用的清晰度，以及这个视频、这个账号能选的全部清晰度（从高到低）
    let qualityID: Int
    let available: [Int]
    /// 哔哩哔哩记的上次看到哪（网页版的记忆播放）：这个视频最后看的是哪一 P、看到第几秒。没登录、没看过是 0
    var lastPlayCid = 0
    var lastPlayTime = 0

    static func name(of id: Int) -> String {
        [120: "4K", 116: "1080P 60 帧", 112: "1080P 高码率", 80: "1080P", 74: "720P 60 帧", 64: "720P", 32: "480P", 16: "360P"][id] ?? "\(id)"
    }
}

/// 看视频时右边面板要的：UP 主、是不是原创、点赞投币收藏的数
struct BiliVideoInfo: Hashable, Sendable {
    var aid: Int
    var original: Bool
    var owner: BiliUser
    var likes: Int
    var coins: Int
    var favorites: Int
    /// 选集：一个视频分了好几 P（同一个视频、不同的分段），或者它在 UP 主的某个合集里（不同的视频）。
    /// 两样都有时按分 P 来；只有一集时为空
    var episodes: [BiliEpisode] = []
}

/// 选集里的一集：放它就是放这个视频（分 P 时是同一个视频的另一段，带着那一段的编号）
struct BiliEpisode: Hashable, Sendable {
    let video: BiliVideo
    /// 卡片上写的：分 P 是"P2"，合集是"第 2 集"
    let label: String
    /// 这一集的名字（分 P 的小标题，或者合集里这个视频的标题）
    let title: String

    /// 正在放的是这一集吗：同一个视频，分 P 时还要是同一段
    func matches(_ other: BiliVideo) -> Bool {
        video.bvid == other.bvid && (other.cid == 0 || video.cid == other.cid)
    }

    /// 从视频信息里读出选集
    static func list(from data: [String: Any], cover: URL?, owner: BiliUser, image: (Any?) -> URL?) -> [BiliEpisode] {
        let bvid = data["bvid"] as? String ?? ""
        let title = data["title"] as? String ?? ""
        let aid = data["aid"] as? Int ?? 0
        let pages = data["pages"] as? [[String: Any]] ?? []
        if pages.count > 1 {
            return pages.compactMap { page in
                guard let cid = page["cid"] as? Int else { return nil }
                let number = page["page"] as? Int ?? 0
                let video = BiliVideo(bvid: bvid, title: title, cover: image(page["first_frame"]) ?? cover,
                                      duration: page["duration"] as? Int ?? 0, owner: owner.name, views: 0,
                                      cid: cid, aid: aid, ownerMid: owner.mid)
                return BiliEpisode(video: video, label: "P\(number)", title: page["part"] as? String ?? "")
            }
        }
        let sections = (data["ugc_season"] as? [String: Any])?["sections"] as? [[String: Any]] ?? []
        let episodes = sections.flatMap { $0["episodes"] as? [[String: Any]] ?? [] }
        guard episodes.count > 1 else { return [] }
        return episodes.enumerated().compactMap { index, episode in
            guard let id = episode["bvid"] as? String, !id.isEmpty else { return nil }
            let arc = episode["arc"] as? [String: Any] ?? [:]
            let name = episode["title"] as? String ?? arc["title"] as? String ?? ""
            let video = BiliVideo(bvid: id, title: name, cover: image(arc["pic"]), duration: arc["duration"] as? Int ?? 0,
                                  owner: owner.name, views: (arc["stat"] as? [String: Any])?["view"] as? Int ?? 0,
                                  cid: episode["cid"] as? Int ?? 0, aid: episode["aid"] as? Int ?? 0, ownerMid: owner.mid)
            return BiliEpisode(video: video, label: "第 \(index + 1) 集", title: name)
        }
    }
}

/// 我和正在看的视频：点过赞没有、投了几个币、收藏了没有
struct BiliRelation: Hashable, Sendable {
    var liked = false
    var coins = 0
    var favorited = false
}

/// 一条字幕（某种语言）和它的句子
struct BiliSubtitleTrack: Hashable, Sendable {
    let language: String
    let name: String
    let url: URL
}

struct BiliSubtitleCue: Hashable, Sendable {
    let from: Double
    let to: Double
    let text: String

    /// 这一刻该显示哪一句（没有就是 nil）
    static func line(at time: Double, in cues: [BiliSubtitleCue]) -> String? {
        var low = 0, high = cues.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if cues[mid].to <= time { low = mid + 1 } else if cues[mid].from > time { high = mid - 1 } else { return cues[mid].text }
        }
        return nil
    }
}

/// 数字写成"1.2万"这样
func biliCount(_ value: Int) -> String {
    value >= 100_000_000 ? String(format: "%.1f亿", Double(value) / 100_000_000)
        : value >= 10000 ? String(format: "%.1f万", Double(value) / 10000) : "\(value)"
}

struct BiliAccount: Hashable, Sendable {
    let name: String
    var mid: Int = 0
    /// 头像
    var face: URL? = nil
}

/// 问哔哩哔哩"现在登录的是谁"的回答：登录着（是谁）、确实没登录、问不到（网络不通、接口出错——不能当成没登录）
enum BiliLogin: Equatable, Sendable {
    case signedIn(BiliAccount)
    case signedOut
    case unknown
}

/// 哔哩哔哩网页自己在用的接口：取列表、取视频流（交给系统播放器播），以及关注、收藏、稍后再看。
/// 这些接口不是公开给第三方的，B 站改版时这里可能需要跟着改。
enum BiliAPI {
    private static let userAgent = UserAgent.safari

    /// 取一个接口，结果在回答的 data 里（回答的 code 不是 0 就当没取到）
    private static func fetch(_ address: String, cookie: String,
                              referer: String = "https://www.bilibili.com/") async -> [String: Any]? {
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        if !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        request.httpShouldHandleCookies = false
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["code"] as? Int) == 0 else {
            return nil
        }
        return json["data"] as? [String: Any]
    }

    /// 哔哩哔哩给的图片、文件地址补成 https 的（有的以 // 开头，有的是 http）。
    /// size：让图片服务器裁成多大（比如 "800w_450h_1c"），不给就是原图
    private static func link(_ value: Any?, size: String? = nil) -> URL? {
        guard var text = value as? String, !text.isEmpty else { return nil }
        if text.hasPrefix("//") { text = "https:" + text }
        text = text.replacingOccurrences(of: "http://", with: "https://")
        return URL(string: size.map { text + "@\($0).webp" } ?? text)
    }

    /// 封面：裁成 16:9 的中等尺寸
    private static func image(_ value: Any?) -> URL? { link(value, size: "800w_450h_1c") }

    private static func video(_ item: [String: Any]) -> BiliVideo? {
        guard let bvid = item["bvid"] as? String, !bvid.isEmpty, let title = item["title"] as? String else { return nil }
        let owner = (item["owner"] as? [String: Any])?["name"] as? String ?? ""
        let views = (item["stat"] as? [String: Any])?["view"] as? Int ?? 0
        return BiliVideo(bvid: bvid, title: title, cover: image(item["pic"]),
                         duration: item["duration"] as? Int ?? 0, owner: owner, views: views,
                         cid: item["cid"] as? Int ?? 0, aid: (item["aid"] as? Int) ?? (item["id"] as? Int) ?? 0,
                         ownerMid: (item["owner"] as? [String: Any])?["mid"] as? Int ?? 0,
                         face: avatar((item["owner"] as? [String: Any])?["face"]),
                         published: (item["pubdate"] as? Int) ?? (item["ctime"] as? Int) ?? 0)
    }

    /// 头像（小尺寸、裁成正方形）
    private static func avatar(_ value: Any?) -> URL? { link(value, size: "120w_120h_1c") }

    /// 同一张图换个尺寸（地址最后 "@" 后面是让图片服务器裁成多大）。没有 "@" 的原样返回
    static func resized(_ url: URL?, to size: String) -> URL? {
        guard let url else { return nil }
        let text = url.absoluteString
        guard let at = text.range(of: "@", options: .backwards) else { return url }
        return URL(string: text[..<at.lowerBound] + "@\(size).webp")
    }

    /// 封面的大图（主屏顶部铺满整个屏幕用）：卡片用的是 800 宽的，这里要 1920 宽的
    static func largeCover(_ url: URL?) -> URL? { resized(url, to: "1920w_1080h_1c") }

    /// 关注的 UP 主最近发的视频（动态里的"投稿了视频"，最新的在前；需要登录）
    static func followingFeed(cookie: String) async -> [BiliVideo] {
        guard cookie.contains("SESSDATA=") else { return [] }
        let data = await fetch("https://api.bilibili.com/x/polymer/web-dynamic/v1/feed/all?type=video&page=1&features=itemOpusStyle&web_location=333.1365",
                               cookie: cookie, referer: "https://t.bilibili.com/")
        return (data?["items"] as? [[String: Any]] ?? []).compactMap { item in
            let modules = item["modules"] as? [String: Any] ?? [:]
            let author = modules["module_author"] as? [String: Any] ?? [:]
            guard let archive = ((modules["module_dynamic"] as? [String: Any])?["major"] as? [String: Any])?["archive"] as? [String: Any],
                  let bvid = archive["bvid"] as? String, bvid.hasPrefix("BV"), let title = archive["title"] as? String else { return nil }
            let stat = archive["stat"] as? [String: Any] ?? [:]
            return BiliVideo(bvid: bvid, title: title, cover: image(archive["cover"]), duration: seconds(archive["duration_text"]),
                             owner: author["name"] as? String ?? "", views: count(stat["play"]),
                             aid: (archive["aid"] as? Int) ?? Int(archive["aid"] as? String ?? "") ?? 0,
                             ownerMid: (author["mid"] as? Int) ?? Int(author["mid"] as? String ?? "") ?? 0,
                             face: avatar(author["face"]), published: author["pub_ts"] as? Int ?? Int(author["pub_ts"] as? String ?? "") ?? 0)
        }
    }

    /// "1.2万"、"3456" 这样的数变回数字
    private static func count(_ value: Any?) -> Int {
        if let number = value as? Int { return number }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return 0 }
        if text.hasSuffix("亿") { return Int((Double(text.dropLast()) ?? 0) * 100_000_000) }
        if text.hasSuffix("万") { return Int((Double(text.dropLast()) ?? 0) * 10000) }
        return Int(text) ?? 0
    }

    /// 首页推荐（登录后是个性化的）
    static func recommended(cookie: String, page: Int = 1) async -> [BiliVideo] {
        let data = await fetch("https://api.bilibili.com/x/web-interface/wbi/index/top/feed/rcmd?ps=20&fresh_type=3&fresh_idx=\(page)&fresh_idx_1h=\(page)", cookie: cookie)
        return (data?["item"] as? [[String: Any]] ?? []).compactMap(video)
    }

    /// 综合热门
    static func popular(cookie: String, page: Int = 1) async -> [BiliVideo] {
        let data = await fetch("https://api.bilibili.com/x/web-interface/popular?ps=20&pn=\(page)", cookie: cookie)
        return (data?["list"] as? [[String: Any]] ?? []).compactMap(video)
    }

    /// 和 fetch 一样，但用于 data 直接是一个数组的接口
    private static func fetchList(_ address: String, cookie: String) async -> [[String: Any]] {
        guard let url = URL(string: address) else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        if !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        request.httpShouldHandleCookies = false
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return json["data"] as? [[String: Any]] ?? []
    }

    /// 和这个视频相关的视频（播放时按下键看）
    static func related(to bvid: String, cookie: String) async -> [BiliVideo] {
        Array(await fetchList("https://api.bilibili.com/x/web-interface/archive/related?bvid=\(bvid)", cookie: cookie).compactMap(video).prefix(20))
    }

    /// 每周必看（最新一期）
    static func weekly(cookie: String) async -> [BiliVideo] {
        let list = await fetch("https://api.bilibili.com/x/web-interface/popular/series/list", cookie: cookie)
        guard let number = (list?["list"] as? [[String: Any]])?.first?["number"] as? Int else { return [] }
        let data = await fetch("https://api.bilibili.com/x/web-interface/popular/series/one?number=\(number)", cookie: cookie)
        return (data?["list"] as? [[String: Any]] ?? []).compactMap(video)
    }

    /// 入站必刷
    static func classics(cookie: String) async -> [BiliVideo] {
        let data = await fetch("https://api.bilibili.com/x/web-interface/popular/precious", cookie: cookie)
        return Array((data?["list"] as? [[String: Any]] ?? []).compactMap(video).shuffled().prefix(30))
    }

    /// 稍后再看（需要登录）
    static func watchLater(cookie: String) async -> [BiliVideo] {
        guard !cookie.isEmpty else { return [] }
        let data = await fetch("https://api.bilibili.com/x/v2/history/toview", cookie: cookie)
        return (data?["list"] as? [[String: Any]] ?? []).compactMap(video)
    }

    /// 收藏：每个收藏夹的名字和里面的视频（需要登录）。空的收藏夹也会返回，视频为空。
    static func favorites(mid: Int, cookie: String) async -> [(title: String, videos: [BiliVideo])] {
        guard !cookie.isEmpty, mid > 0 else { return [] }
        let folders = await fetch("https://api.bilibili.com/x/v3/fav/folder/created/list-all?up_mid=\(mid)", cookie: cookie)
        var result: [(title: String, videos: [BiliVideo])] = []
        for folder in (folders?["list"] as? [[String: Any]] ?? []).prefix(6) {
            guard let id = folder["id"] as? Int else { continue }
            let title = folder["title"] as? String ?? "收藏"
            let data = await fetch("https://api.bilibili.com/x/v3/fav/resource/list?media_id=\(id)&pn=1&ps=20&platform=web", cookie: cookie)
            let videos = (data?["medias"] as? [[String: Any]] ?? []).compactMap { item -> BiliVideo? in
                guard let bvid = item["bvid"] as? String, !bvid.isEmpty, let name = item["title"] as? String,
                      name != "已失效视频" else { return nil }
                return BiliVideo(bvid: bvid, title: name, cover: image(item["cover"]), duration: item["duration"] as? Int ?? 0,
                                 owner: (item["upper"] as? [String: Any])?["name"] as? String ?? "",
                                 views: (item["cnt_info"] as? [String: Any])?["play"] as? Int ?? 0,
                                 aid: item["id"] as? Int ?? 0, ownerMid: (item["upper"] as? [String: Any])?["mid"] as? Int ?? 0)
            }
            result.append((title, videos))
        }
        return result
    }

    /// 排行榜（全站）
    static func ranking(cookie: String) async -> [BiliVideo] {
        let data = await fetch("https://api.bilibili.com/x/web-interface/ranking/v2?rid=0&type=all", cookie: cookie)
        return Array((data?["list"] as? [[String: Any]] ?? []).compactMap(video).prefix(30))
    }

    // MARK: 直播

    private static let liveReferer = "https://live.bilibili.com/"
    /// 没登录时直播的接口要一个设备标识（buvid3），不然会被风控挡掉：向哔哩哔哩要一个匿名的，记着反复用
    private static let anonymousDevice = AnonymousDevice()

    private actor AnonymousDevice {
        private var value: String?
        func cookie(_ cookie: String) async -> String {
            if cookie.contains("buvid3=") { return cookie }
            if value == nil, let url = URL(string: "https://api.bilibili.com/x/frontend/finger/spi") {
                var request = URLRequest(url: url, timeoutInterval: 8)
                request.setValue(BiliAPI.userAgent, forHTTPHeaderField: "User-Agent")
                request.httpShouldHandleCookies = false
                if let (data, _) = try? await URLSession.shared.data(for: request),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let id = (json["data"] as? [String: Any])?["b_3"] as? String, !id.isEmpty { value = id }
            }
            guard let value else { return cookie }
            return cookie.isEmpty ? "buvid3=\(value)" : cookie + "; buvid3=\(value)"
        }
    }

    /// 一个直播间（直播首页、关注的主播两个接口给的字段名不一样，两种都认）
    private static func liveRoom(_ item: [String: Any]) -> BiliVideo? {
        guard let room = (item["roomid"] ?? item["room_id"]) as? Int, room > 0,
              let title = item["title"] as? String, !title.isEmpty else { return nil }
        if let status = item["live_status"] as? Int, status != 1 { return nil }   // 关注的主播里没在播的
        let cover = ["cover", "user_cover", "room_cover", "cover_from_user", "keyframe"].lazy
            .compactMap { item[$0] as? String }.first { !$0.isEmpty }
        let watched = (item["watched_show"] as? [String: Any])?["num"] as? Int
        let area = (item["area_v2_name"] ?? item["area_name_v2"] ?? item["area_name"]) as? String
        return BiliVideo(bvid: "live-\(room)", title: title, cover: image(cover), duration: 0,
                         owner: item["uname"] as? String ?? "", views: watched ?? item["online"] as? Int ?? 0,
                         ownerMid: (item["uid"] ?? item["mid"]) as? Int ?? 0,
                         liveRoom: room, note: area.flatMap { $0.isEmpty ? nil : $0 }, face: avatar(item["face"]))
    }

    /// 关注的主播里正在直播的（需要登录）
    static func liveFollowing(cookie: String) async -> [BiliVideo] {
        guard cookie.contains("SESSDATA=") else { return [] }
        let data = await fetch("https://api.live.bilibili.com/xlive/web-ucenter/user/following?page=1&page_size=30&ignoreRecord=1&hit_ab=true",
                               cookie: cookie, referer: liveReferer)
        let rooms = (data?["list"] as? [[String: Any]] ?? []).compactMap(liveRoom)
        if !rooms.isEmpty { return rooms }
        // 另一个只列"正在播"的接口（上面那个改版时的后备）
        let backup = await fetch("https://api.live.bilibili.com/xlive/web-ucenter/v1/xfetter/GetWebList?page=1&page_size=30",
                                 cookie: cookie, referer: liveReferer)
        return (backup?["rooms"] as? [[String: Any]] ?? backup?["list"] as? [[String: Any]] ?? []).compactMap(liveRoom)
    }

    /// 直播首页：推荐直播，以及聊天室、单机游戏、虚拟主播……各分区正热的（每排十来个）
    static func liveIndex(cookie: String) async -> [(title: String, rooms: [BiliVideo])] {
        let data = await fetch("https://api.live.bilibili.com/xlive/web-interface/v1/index/getList?platform=web",
                               cookie: await anonymousDevice.cookie(cookie), referer: liveReferer)
        return (data?["room_list"] as? [[String: Any]] ?? []).compactMap { block in
            let title = (block["module_info"] as? [String: Any])?["title"] as? String ?? ""
            let rooms = (block["list"] as? [[String: Any]] ?? []).compactMap(liveRoom)
            return rooms.isEmpty || title.isEmpty ? nil : (title, rooms)
        }
    }

    /// 直播流：系统播放器能直接放的 HLS 地址，几条线路按顺序试（P2P 节点放最后，它们常连不上）
    static func liveStream(room: Int, cookie: String) async -> [URL] {
        let data = await fetch("https://api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo?room_id=\(room)&protocol=1&format=0,1,2&codec=0&qn=10000&platform=web&ptype=8",
                               cookie: await anonymousDevice.cookie(cookie), referer: liveReferer)
        let streams = ((data?["playurl_info"] as? [String: Any])?["playurl"] as? [String: Any])?["stream"] as? [[String: Any]] ?? []
        var urls: [URL] = []
        for stream in streams where stream["protocol_name"] as? String == "http_hls" {
            // ts 在前（系统播放器最稳），fmp4 其次
            let formats = (stream["format"] as? [[String: Any]] ?? []).sorted {
                ($0["format_name"] as? String == "ts" ? 0 : 1) < ($1["format_name"] as? String == "ts" ? 0 : 1)
            }
            for format in formats {
                for codec in format["codec"] as? [[String: Any]] ?? [] where codec["codec_name"] as? String == "avc" {
                    let base = codec["base_url"] as? String ?? ""
                    for info in codec["url_info"] as? [[String: Any]] ?? [] {
                        if let url = URL(string: (info["host"] as? String ?? "") + base + (info["extra"] as? String ?? "")) { urls.append(url) }
                    }
                }
            }
        }
        let p2p = { (url: URL) in (url.host ?? "").contains("mcdn") }
        return urls.filter { !p2p($0) } + urls.filter(p2p)
    }

    /// 直播间弹幕服务器：连哪几台（wss，只认哔哩哔哩自己的）、进房间要交的凭证、设备标识（buvid3）。
    /// 要签名；没登录时带上匿名的设备标识（不然会被风控挡掉，-352）
    static func liveDanmakuServer(room: Int, key: String, cookie: String) async -> BiliLiveDanmakuServer? {
        let header = await anonymousDevice.cookie(cookie)
        guard let data = await fetch("https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo?\(signed(["id": "\(room)", "type": "0"], key: key))",
                                     cookie: header, referer: liveReferer),
              let token = data["token"] as? String, !token.isEmpty else { return nil }
        let hosts = (data["host_list"] as? [[String: Any]] ?? []).compactMap { entry -> URL? in
            guard let host = entry["host"] as? String, host.hasSuffix(".bilibili.com") else { return nil }
            return URL(string: "wss://\(host):\(entry["wss_port"] as? Int ?? 443)/sub")
        }
        guard !hosts.isEmpty else { return nil }
        let buvid = header.components(separatedBy: "; ").first { $0.hasPrefix("buvid3=") }.map { String($0.dropFirst(7)) } ?? ""
        return BiliLiveDanmakuServer(token: token, hosts: hosts, buvid: buvid)
    }

    // MARK: UP 主：搜索、关注

    /// 按名字搜 UP 主；没问到（断网、被拒）是 nil
    static func searchUsers(_ keyword: String, cookie: String) async -> [BiliUser]? {
        (await searchResult("bili_user", keyword, page: 1, size: 12, cookie: cookie)).map(users(inSearch:))
    }

    static func users(inSearch list: [[String: Any]]) -> [BiliUser] {
        list.compactMap { item in
            guard let mid = item["mid"] as? Int, let name = item["uname"] as? String else { return nil }
            return BiliUser(mid: mid, name: name, face: link(item["upic"], size: "240w_240h_1c"),
                            fans: item["fans"] as? Int ?? 0, videos: item["videos"] as? Int ?? 0, sign: item["usign"] as? String ?? "")
        }
    }

    /// 搜索接口的一页结果（什么都没搜到是空的）；没问到是 nil
    private static func searchResult(_ type: String, _ keyword: String, page: Int, size: Int, cookie: String) async -> [[String: Any]]? {
        guard let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let data = await fetch("https://api.bilibili.com/x/web-interface/wbi/search/type?search_type=\(type)&page=\(page)&page_size=\(size)&keyword=\(encoded)", cookie: cookie)
        else { return nil }
        return data["result"] as? [[String: Any]] ?? []
    }

    /// 一个 UP 主的头像和粉丝数（从视频卡片进他的主页时，手上只有名字）
    static func userCard(mid: Int, name: String, cookie: String) async -> BiliUser {
        let data = await fetch("https://api.bilibili.com/x/web-interface/card?mid=\(mid)", cookie: cookie)
        let card = data?["card"] as? [String: Any]
        return BiliUser(mid: mid, name: card?["name"] as? String ?? name, face: link(card?["face"], size: "240w_240h_1c"),
                        fans: (card?["fans"] as? Int) ?? (data?["follower"] as? Int) ?? 0, videos: data?["archive_count"] as? Int ?? 0)
    }

    /// 我有没有关注这个人
    static func isFollowing(mid: Int, cookie: String) async -> Bool {
        guard !cookie.isEmpty else { return false }
        let data = await fetch("https://api.bilibili.com/x/relation?fid=\(mid)", cookie: cookie)
        let attribute = data?["attribute"] as? Int ?? 0
        return attribute == 2 || attribute == 6   // 2 已关注，6 互相关注
    }

    // MARK: 往账号里写东西：关注、收藏、稍后再看（和在手机上操作的效果一样）

    /// 这些操作都要带账号的防伪标记（在登录信息里）
    private static func post(_ address: String, form: [String: String], cookie: String) async -> Bool {
        await postReply(address, form: form, cookie: cookie).ok
    }

    private static func postReply(_ address: String, form: [String: String], cookie: String) async -> (ok: Bool, message: String?) {
        let reply = await postCoded(address, form: form, cookie: cookie)
        return (reply.ok, reply.message)
    }

    /// 账号的防伪标记：登录信息里的 bili_jct（没登录就没有）
    private static func csrf(_ cookie: String) -> String? {
        cookie.components(separatedBy: "; ").first { $0.hasPrefix("bili_jct=") }.map { String($0.dropFirst(9)) }
    }

    /// 同上，失败时带回哔哩哔哩给的错误号和那句话（比如"硬币不足"），好原样告诉人
    private static func postCoded(_ address: String, form: [String: String], cookie: String) async -> (ok: Bool, code: Int?, message: String?) {
        guard let csrf = csrf(cookie), let url = URL(string: address) else { return (false, nil, nil) }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpShouldHandleCookies = false
        var all = form
        all["csrf"] = csrf
        request.httpBody = Data(all.map { "\($0.key)=\($0.value)" }.joined(separator: "&").utf8)
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (false, nil, nil) }
        let code = json["code"] as? Int
        return (code == 0, code, code == 0 ? nil : json["message"] as? String)
    }

    static func setFollowing(mid: Int, follow: Bool, cookie: String) async -> Bool {
        await post("https://api.bilibili.com/x/relation/modify", form: ["fid": "\(mid)", "act": follow ? "1" : "2", "re_src": "11"], cookie: cookie)
    }

    static func addWatchLater(bvid: String, cookie: String) async -> Bool {
        await post("https://api.bilibili.com/x/v2/history/toview/add", form: ["bvid": bvid], cookie: cookie)
    }

    /// 加进默认收藏夹
    static func addFavorite(aid: Int, mid: Int, cookie: String) async -> Bool {
        let folders = await fetch("https://api.bilibili.com/x/v3/fav/folder/created/list-all?up_mid=\(mid)", cookie: cookie)
        guard let folder = (folders?["list"] as? [[String: Any]])?.first?["id"] as? Int else { return false }
        return await post("https://api.bilibili.com/x/v3/fav/resource/deal",
                          form: ["rid": "\(aid)", "type": "2", "add_media_ids": "\(folder)", "del_media_ids": ""], cookie: cookie)
    }

    // MARK: 看视频时右边的面板：UP 主、点赞、投币、收藏、字幕

    /// 视频本身的信息：UP 主是谁、是不是原创（原创最多投两个币，转载一个）、点赞投币收藏各多少
    /// 一个视频的详细信息（带签名的接口先试，不行换不带签名的）。bvid 和 aid 给一个就行
    private static func view(bvid: String?, aid: Int? = nil, key: String?, cookie: String) async -> [String: Any]? {
        let id = bvid.map { ["bvid": $0] } ?? ["aid": "\(aid ?? 0)"]
        var data: [String: Any]?
        if let key { data = await fetch("https://api.bilibili.com/x/web-interface/wbi/view?\(signed(id, key: key))", cookie: cookie) }
        if data == nil {
            data = await fetch("https://api.bilibili.com/x/web-interface/view?\(id.map { "\($0.key)=\($0.value)" }.joined())", cookie: cookie)
        }
        return data
    }

    /// 从手机发来的链接打开的视频：按 BV 号或 av 号取信息，组成能直接放的视频；page 是第几 P（从 1 数）
    static func video(bvid: String?, aid: Int?, page: Int?, key: String?, cookie: String) async -> BiliVideo? {
        guard bvid != nil || aid != nil, let data = await view(bvid: bvid, aid: aid, key: key, cookie: cookie),
              let id = data["bvid"] as? String, let title = data["title"] as? String else { return nil }
        let owner = data["owner"] as? [String: Any] ?? [:]
        let pages = data["pages"] as? [[String: Any]] ?? []
        let part = page.flatMap { number in pages.first { ($0["page"] as? Int) == number } }
        return BiliVideo(bvid: id, title: title, cover: image(data["pic"]),
                         duration: part?["duration"] as? Int ?? data["duration"] as? Int ?? 0,
                         owner: owner["name"] as? String ?? "", views: (data["stat"] as? [String: Any])?["view"] as? Int ?? 0,
                         cid: part?["cid"] as? Int ?? data["cid"] as? Int ?? 0, aid: data["aid"] as? Int ?? 0,
                         ownerMid: owner["mid"] as? Int ?? 0)
    }

    static func info(bvid: String, key: String?, cookie: String) async -> BiliVideoInfo? {
        guard let data = await view(bvid: bvid, key: key, cookie: cookie) else { return nil }
        let owner = data["owner"] as? [String: Any] ?? [:]
        let stat = data["stat"] as? [String: Any] ?? [:]
        let uploader = BiliUser(mid: owner["mid"] as? Int ?? 0, name: owner["name"] as? String ?? "", face: avatar(owner["face"]))
        // 只有 2 是转载（每人最多投 1 个币）；1 是自制，还有别的值（比如 3）也都按自制算，能投 2 个
        return BiliVideoInfo(aid: data["aid"] as? Int ?? 0, original: (data["copyright"] as? Int ?? 1) != 2, owner: uploader,
                             likes: stat["like"] as? Int ?? 0, coins: stat["coin"] as? Int ?? 0, favorites: stat["favorite"] as? Int ?? 0,
                             episodes: BiliEpisode.list(from: data, cover: image(data["pic"]), owner: uploader, image: image))
    }

    /// 我和这个视频的关系：点过赞没有、投了几个币、收藏了没有（需要登录）
    static func relation(bvid: String, cookie: String) async -> BiliRelation? {
        guard !cookie.isEmpty, let data = await fetch("https://api.bilibili.com/x/web-interface/archive/relation?bvid=\(bvid)", cookie: cookie) else { return nil }
        return BiliRelation(liked: data["like"] as? Bool ?? false, coins: data["coin"] as? Int ?? 0, favorited: data["favorite"] as? Bool ?? false)
    }

    /// 点赞 / 取消点赞。"已经赞过了"（65006）、"本来就没赞"（65004）也算成功：账号上已经是想要的样子
    static func setLiked(aid: Int, _ on: Bool, cookie: String) async -> (ok: Bool, message: String?) {
        let reply = await postCoded("https://api.bilibili.com/x/web-interface/archive/like", form: ["aid": "\(aid)", "like": on ? "1" : "2"], cookie: cookie)
        let already = (on && reply.code == 65006) || (!on && reply.code == 65004)
        return (reply.ok || already, reply.message)
    }

    /// 投币（1 或 2 个）。硬币不够、已经投满时，带回哔哩哔哩的原话
    static func addCoins(aid: Int, count: Int, cookie: String) async -> (ok: Bool, message: String?) {
        await postReply("https://api.bilibili.com/x/web-interface/coin/add",
                        form: ["aid": "\(aid)", "multiply": "\(count)", "select_like": "0"], cookie: cookie)
    }

    /// 取消收藏：从所有收着它的收藏夹里拿掉
    static func removeFavorite(aid: Int, mid: Int, cookie: String) async -> Bool {
        let folders = await fetch("https://api.bilibili.com/x/v3/fav/folder/created/list-all?up_mid=\(mid)&type=2&rid=\(aid)", cookie: cookie)
        let holding = (folders?["list"] as? [[String: Any]] ?? []).filter { ($0["fav_state"] as? Int) == 1 }.compactMap { $0["id"] as? Int }
        guard !holding.isEmpty else { return false }
        return await post("https://api.bilibili.com/x/v3/fav/resource/deal",
                          form: ["rid": "\(aid)", "type": "2", "add_media_ids": "",
                                 "del_media_ids": holding.map(String.init).joined(separator: "%2C")], cookie: cookie)
    }

    /// 这个视频有哪些字幕（UP 主上传的、自动生成的）。key 是签名用的密钥，没有时换不带签名的老接口
    static func subtitleTracks(bvid: String, cid: Int, key: String?, cookie: String) async -> [BiliSubtitleTrack] {
        let address = key.map { "https://api.bilibili.com/x/player/wbi/v2?\(signed(["bvid": bvid, "cid": "\(cid)"], key: $0))" }
            ?? "https://api.bilibili.com/x/player/v2?bvid=\(bvid)&cid=\(cid)"
        guard let data = await fetch(address, cookie: cookie) else { return [] }
        let list = (data["subtitle"] as? [String: Any])?["subtitles"] as? [[String: Any]] ?? []
        return list.compactMap { item in
            guard let url = link(item["subtitle_url"]) else { return nil }   // 没登录时自动生成的没有地址
            let language = item["lan"] as? String ?? ""
            return BiliSubtitleTrack(language: language, name: item["lan_doc"] as? String ?? language, url: url)
        }
    }

    /// 一条字幕的全部句子
    static func subtitleCues(_ track: BiliSubtitleTrack) async -> [BiliSubtitleCue] {
        var request = URLRequest(url: track.url, timeoutInterval: 10)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        request.httpShouldHandleCookies = false
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return (json["body"] as? [[String: Any]] ?? []).compactMap { line in
            guard let from = (line["from"] as? NSNumber)?.doubleValue, let to = (line["to"] as? NSNumber)?.doubleValue,
                  let text = line["content"] as? String, !text.isEmpty else { return nil }
            return BiliSubtitleCue(from: from, to: to, text: text)
        }
    }

    /// 弹幕：这个视频（这一 P）的弹幕。哔哩哔哩给的是压缩过的 XML（系统没自动解开时自己解）
    static func danmaku(cid: Int, cookie: String) async -> [BiliDanmaku] {
        guard cid > 0, let url = URL(string: "https://api.bilibili.com/x/v1/dm/list.so?oid=\(cid)") else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        if !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        request.httpShouldHandleCookies = false
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return [] }
        var text = String(data: data, encoding: .utf8) ?? ""
        if !text.contains("<d p=") {
            let opened = try? (data as NSData).decompressed(using: .zlib) as Data
            text = opened.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        return BiliDanmaku.parse(text)
    }

    // MARK: 关注的 UP 主

    /// 关注列表（需要登录）
    static func followings(mid: Int, cookie: String) async -> [(mid: Int, name: String)] {
        guard !cookie.isEmpty, mid > 0 else { return [] }
        let data = await fetch("https://api.bilibili.com/x/relation/followings?vmid=\(mid)&pn=1&ps=50&order=desc", cookie: cookie)
        return (data?["list"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["mid"] as? Int, let name = item["uname"] as? String else { return nil }
            return (id, name)
        }
    }

    /// 某个 UP 主最近的投稿，以及最新一条的发布时间（用来排谁在前面）。
    /// 这个接口要求带签名（见 signed），不带会被拒绝。
    /// order：pubdate 最新发布、click 最多播放、stow 最多收藏
    static func uploads(mid: Int, name: String, key: String, cookie: String, order: String = "pubdate") async -> (videos: [BiliVideo], latest: Int) {
        let query = signed(["mid": "\(mid)", "ps": "30", "pn": "1", "order": order], key: key)
        let data = await fetch("https://api.bilibili.com/x/space/wbi/arc/search?\(query)", cookie: cookie)
        let list = (data?["list"] as? [String: Any])?["vlist"] as? [[String: Any]] ?? []
        let videos = list.compactMap { item -> BiliVideo? in
            guard let bvid = item["bvid"] as? String, !bvid.isEmpty, let title = item["title"] as? String else { return nil }
            return BiliVideo(bvid: bvid, title: title, cover: image(item["pic"]), duration: seconds(item["length"]),
                             owner: name, views: item["play"] as? Int ?? 0, aid: item["aid"] as? Int ?? 0, ownerMid: mid)
        }
        return (videos, list.first?["created"] as? Int ?? 0)
    }

    /// 一个视频的播放数（历史记录的接口不带这个数，要单独问）；问不到返回 0
    static func views(bvid: String, key: String, cookie: String) async -> Int {
        let data = await fetch("https://api.bilibili.com/x/web-interface/wbi/view?\(signed(["bvid": bvid], key: key))", cookie: cookie)
        return (data?["stat"] as? [String: Any])?["view"] as? Int ?? 0
    }

    /// 签名用的密钥：从账号信息里给的两段字符串按固定顺序抽 32 个字符（哔哩哔哩网页自己的做法）
    static func signingKey(cookie: String) async -> String? {
        guard let url = URL(string: "https://api.bilibili.com/x/web-interface/nav") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        request.httpShouldHandleCookies = false
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = (json["data"] as? [String: Any])?["wbi_img"] as? [String: Any],
              let first = images["img_url"] as? String, let second = images["sub_url"] as? String else { return nil }
        func stem(_ address: String) -> String { String((address.split(separator: "/").last ?? "").split(separator: ".").first ?? "") }
        let raw = Array(stem(first) + stem(second))
        let order = [46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39,
                     12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63,
                     57, 62, 11, 36, 20, 34, 44, 52]
        guard raw.count >= 64 else { return nil }
        return String(order.map { raw[$0] }.prefix(32))
    }

    /// 给请求参数加上时间戳和签名
    private static func signed(_ parameters: [String: String], key: String) -> String {
        var all = parameters
        all["wts"] = "\(Int(Date().timeIntervalSince1970))"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        let query = all.keys.sorted().map { name in
            let value = all[name]!.filter { !"!'()*".contains($0) }
            return "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
        let digest = Insecure.MD5.hash(data: Data((query + key).utf8)).map { String(format: "%02x", $0) }.joined()
        return query + "&w_rid=" + digest
    }

    /// 热搜（搜索页下面那十个）：关键词和哔哩哔哩自己的"热""新"小标（一张小图，没有就是 nil）
    static func trending(cookie: String) async -> [BiliTrend] {
        let data = await fetch("https://api.bilibili.com/x/web-interface/search/square?limit=10&platform=web", cookie: cookie)
        let list = (data?["trending"] as? [String: Any])?["list"] as? [[String: Any]] ?? []
        return list.enumerated().compactMap { index, item in
            guard let keyword = item["keyword"] as? String, !keyword.isEmpty else { return nil }
            return BiliTrend(rank: index + 1, keyword: keyword, title: item["show_name"] as? String ?? keyword, icon: link(item["icon"]))
        }
    }

    /// 搜索视频；没问到（断网、被拒）是 nil
    static func search(_ keyword: String, cookie: String, page: Int = 1) async -> [BiliVideo]? {
        (await searchResult("video", keyword, page: page, size: 30, cookie: cookie)).map(videos(inSearch:))
    }

    static func videos(inSearch list: [[String: Any]]) -> [BiliVideo] {
        list.compactMap { item in
            guard let bvid = item["bvid"] as? String, !bvid.isEmpty, let raw = item["title"] as? String else { return nil }
            // 标题里夹着高亮关键词用的 HTML 标签和转义符
            let title = raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            return BiliVideo(bvid: bvid, title: title, cover: image(item["pic"]), duration: seconds(item["duration"]),
                             owner: item["author"] as? String ?? "", views: item["play"] as? Int ?? 0,
                             aid: item["aid"] as? Int ?? 0, ownerMid: item["mid"] as? Int ?? 0)
        }
    }

    /// "15:46"、"1:02:03" 这样的时长变成秒
    private static func seconds(_ value: Any?) -> Int {
        guard let text = value as? String else { return value as? Int ?? 0 }
        return text.split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
    }

    /// 历史记录（需要登录）：看过的视频和直播间（看过的直播也留着，下次知道主播去哪了）；番剧、专栏这些不要。
    /// 直播间现在在播的可以直接进去看；没在播的记成 endedRoom
    static func history(cookie: String, count: Int = 20) async -> [BiliVideo] {
        guard !cookie.isEmpty else { return [] }
        let data = await fetch("https://api.bilibili.com/x/web-interface/history/cursor?ps=\(count)&type=all", cookie: cookie)
        return historyItems(data?["list"] as? [[String: Any]] ?? [])
    }

    static func historyItems(_ list: [[String: Any]]) -> [BiliVideo] {
        list.compactMap { item in
            let history = item["history"] as? [String: Any] ?? [:]
            if history["business"] as? String == "live" { return endedOrLiveRoom(item, history: history) }
            guard history["business"] as? String ?? "archive" == "archive",
                  let bvid = history["bvid"] as? String, !bvid.isEmpty,
                  let title = item["title"] as? String else { return nil }
            return BiliVideo(bvid: bvid, title: title, cover: image(item["cover"]),
                             duration: item["duration"] as? Int ?? 0, owner: item["author_name"] as? String ?? "",
                             views: 0, cid: (item["history"] as? [String: Any])?["cid"] as? Int ?? 0,
                             aid: (item["history"] as? [String: Any])?["oid"] as? Int ?? 0,
                             ownerMid: item["author_mid"] as? Int ?? 0, progress: item["progress"] as? Int)
        }
    }

    /// 历史记录里的一个直播间
    private static func endedOrLiveRoom(_ item: [String: Any], history: [String: Any]) -> BiliVideo? {
        guard let room = history["oid"] as? Int, room > 0, let title = item["title"] as? String, !title.isEmpty else { return nil }
        let live = (item["live_status"] as? Int) == 1
        let cover = (item["cover"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (item["covers"] as? [String])?.first
        let area = (item["tag_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return BiliVideo(bvid: "live-\(room)", title: title, cover: image(cover), duration: 0,
                         owner: item["author_name"] as? String ?? "", views: 0, ownerMid: item["author_mid"] as? Int ?? 0,
                         liveRoom: live ? room : 0, endedRoom: live ? 0 : room, note: area, face: avatar(item["author_face"]))
    }

    /// 取流：直接要这个视频的画面和声音地址，交给系统播放器，不经过网页。
    /// limit 是想要的清晰度上限（设置里选的，最高 4K）；视频没有那么高、或者账号不够（大会员才有的几档），
    /// 就用它能给的最高一档。
    static func stream(for video: BiliVideo, cookie: String, limit: Int) async -> BiliStream? {
        var cid = video.cid
        if cid == 0 {
            // 列表没带分 P 编号时查一下
            let pages = await fetchList("https://api.bilibili.com/x/player/pagelist?bvid=\(video.bvid)", cookie: cookie)
            guard let first = pages.first?["cid"] as? Int else { return nil }
            cid = first
        }
        let query = "bvid=\(video.bvid)&cid=\(cid)&qn=112&fnval=4048&fourk=1"
        var data = await fetch("https://api.bilibili.com/x/player/wbi/playurl?\(query)", cookie: cookie)
        if data?["dash"] == nil {
            // 偶尔会被风控挡一下：换另一个等价的接口再要一次
            data = await fetch("https://api.bilibili.com/x/player/playurl?\(query)", cookie: cookie)
        }
        guard let dash = data?["dash"] as? [String: Any] else { return nil }
        let videos = dash["video"] as? [[String: Any]] ?? []
        let audios = dash["audio"] as? [[String: Any]] ?? []
        // 只要系统能硬解的编码（HEVC、AVC），不要 AV1；同一档清晰度有 HEVC 就用 HEVC
        func rank(_ track: [String: Any]) -> (Int, Int) {
            let codec = track["codecs"] as? String ?? ""
            return (track["id"] as? Int ?? 0, codec.hasPrefix("hev") || codec.hasPrefix("hvc") ? 1 : 0)
        }
        // 能选的清晰度：系统能硬解的、常规的那几档（HDR、杜比视界、8K 不列）
        let offered: Set<Int> = [120, 116, 112, 80, 74, 64, 32, 16]
        let playable = videos.filter {
            let codec = $0["codecs"] as? String ?? ""
            return (codec.hasPrefix("avc") || codec.hasPrefix("hev") || codec.hasPrefix("hvc")) && offered.contains($0["id"] as? Int ?? 0)
        }
        let available = Array(Set(playable.compactMap { $0["id"] as? Int })).sorted(by: >)
        // 不超过想要的那一档；这个视频没有那么高就用它最高的
        let usable = playable.filter { ($0["id"] as? Int ?? 0) <= limit }
        guard let picture = (usable.isEmpty ? playable : usable).max(by: { rank($0) < rank($1) }),
              let sound = audios.filter({ ($0["id"] as? Int ?? 0) <= 30280 }).max(by: { ($0["id"] as? Int ?? 0) < ($1["id"] as? Int ?? 0) }) ?? audios.first,
              let pictureTrack = BiliTrack(picture), let soundTrack = BiliTrack(sound) else { return nil }
        return BiliStream(video: pictureTrack, audio: soundTrack, cid: cid,
                          qualityID: picture["id"] as? Int ?? 0, available: available,
                          lastPlayCid: data?["last_play_cid"] as? Int ?? 0,
                          lastPlayTime: max(0, (data?["last_play_time"] as? Int ?? 0) / 1000))
    }

    /// 把看到哪了告诉哔哩哔哩，这样"继续观看"和手机上的历史记录是同步的
    static func reportProgress(bvid: String, cid: Int, seconds: Int, cookie: String) async {
        guard let csrf = csrf(cookie), let url = URL(string: "https://api.bilibili.com/x/click-interface/web/heartbeat") else { return }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpShouldHandleCookies = false
        request.httpBody = Data("bvid=\(bvid)&cid=\(cid)&played_time=\(seconds)&type=3&dt=2&play_type=0&csrf=\(csrf)".utf8)
        _ = try? await URLSession.shared.data(for: request)
    }

    /// 进了一个直播间：告诉哔哩哔哩（和网页版进直播间时一样），这样看过的直播会记进历史记录，
    /// 手机上、"我的"里都看得到。只在登录了时报；账号在哔哩哔哩那边暂停了历史记录就不会记
    static func enterLiveRoom(_ room: Int, cookie: String) async {
        guard room > 0, let csrf = csrf(cookie),
              let url = URL(string: "https://api.live.bilibili.com/xlive/web-room/v1/index/roomEntryAction?csrf=\(csrf)") else { return }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://live.bilibili.com/\(room)", forHTTPHeaderField: "Referer")
        request.setValue("https://live.bilibili.com", forHTTPHeaderField: "Origin")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpShouldHandleCookies = false
        request.httpBody = Data("room_id=\(room)&platform=pc&csrf_token=\(csrf)&csrf=\(csrf)&visit_id=".utf8)
        let status = ((try? await URLSession.shared.data(for: request))?.1 as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 { Log.playback.info("bilibili live \(room, privacy: .public): room entry answered \(status, privacy: .public)") }
    }

    /// 一个人的直播间：正在播就给这个直播间（UP 主的主页最前面放它），没在播、没有直播间都是 nil
    static func liveRoomOf(mid: Int) async -> BiliVideo? {
        guard mid > 0, let url = URL(string: "https://api.live.bilibili.com/room/v1/Room/getRoomInfoOld?mid=\(mid)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://live.bilibili.com/", forHTTPHeaderField: "Referer")
        request.httpShouldHandleCookies = false
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let room = json["data"] as? [String: Any] else { return nil }
        return liveRoomInfo(room, mid: mid)
    }

    /// 按房间号查一个直播间：(正在播的直播间, 主播的编号)。没在播时直播间是 nil、编号还在（进主播的主页用）
    static func liveRoom(id: Int) async -> (live: BiliVideo?, mid: Int) {
        guard id > 0, let url = URL(string: "https://api.live.bilibili.com/room/v1/Room/get_info?room_id=\(id)") else { return (nil, 0) }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://live.bilibili.com/", forHTTPHeaderField: "Referer")
        request.httpShouldHandleCookies = false
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let room = json["data"] as? [String: Any] else { return (nil, 0) }
        let mid = room["uid"] as? Int ?? 0
        guard room["live_status"] as? Int == 1, let real = room["room_id"] as? Int, real > 0 else { return (nil, mid) }
        let area = room["area_name"] as? String
        return (BiliVideo(bvid: "live-\(real)", title: room["title"] as? String ?? "", cover: image(room["user_cover"] ?? room["keyframe"]),
                          duration: 0, owner: "", views: room["online"] as? Int ?? 0, ownerMid: mid, liveRoom: real,
                          note: area.flatMap { $0.isEmpty ? nil : $0 }), mid)
    }

    /// 查一个人的直播间时给的那一段：正在播才算（主播的名字、头像这个接口不给，由用的地方补上）
    static func liveRoomInfo(_ room: [String: Any], mid: Int) -> BiliVideo? {
        guard room["liveStatus"] as? Int == 1, let id = room["roomid"] as? Int, id > 0 else { return nil }
        return BiliVideo(bvid: "live-\(id)", title: room["title"] as? String ?? "", cover: image(room["cover"]), duration: 0,
                         owner: "", views: room["online"] as? Int ?? 0, ownerMid: mid, liveRoom: id)
    }

    /// 现在登录的是谁。登录信息里没有 SESSDATA 就是没登录，不用问；
    /// 问了答不上来（网络不通、回答看不懂）是 unknown，哔哩哔哩明说没登录（-101、isLogin 是 false）才是 signedOut
    static func account(cookie: String) async -> BiliLogin {
        guard cookie.contains("SESSDATA=") else { return .signedOut }
        guard let url = URL(string: "https://api.bilibili.com/x/web-interface/nav") else { return .unknown }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.httpShouldHandleCookies = false
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unknown }
        return login(from: json)
    }

    /// 读 nav 接口的回答（单独拿出来好测）
    static func login(from json: [String: Any]) -> BiliLogin {
        let data = json["data"] as? [String: Any]
        guard let info = data, info["isLogin"] as? Bool == true else {
            return json["code"] as? Int == -101 || data?["isLogin"] as? Bool == false ? .signedOut : .unknown
        }
        return .signedIn(BiliAccount(name: info["uname"] as? String ?? "", mid: info["mid"] as? Int ?? 0, face: avatar(info["face"])))
    }
}
