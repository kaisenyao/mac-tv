import CommonCrypto
import Foundation

struct NeteaseSong: Hashable, Sendable {
    let id: Int
    let name: String
    var artist = ""
    var cover: URL? = nil
    /// 秒
    var duration = 0
}

struct NeteaseLyricLine: Hashable, Sendable {
    /// 逐字歌词里的一个字（或一个英文单词）：从第几秒开始唱
    struct Word: Hashable, Sendable {
        let time: Double
        let text: String
        /// 这个字唱多久
        var duration = 0.3
    }
    let time: Double
    let text: String
    /// 有逐字歌词的歌才有；没有就是空的，整句一起亮
    var words: [Word] = []
}

struct NeteasePlaylist: Hashable, Sendable {
    let id: Int
    let name: String
    var cover: URL? = nil
    var count = 0
    /// 建这个歌单的人
    var creator = 0
}

struct NeteaseAccount: Hashable, Sendable {
    let id: Int
    let name: String
    var avatar: URL? = nil
}

/// 网易云音乐网页版自己在用的接口。登录信息由系统的网络库自己保存和携带（这个应用自己的那一份），
/// 这里的代码不读也不存账号密码；登录由你在官方网页上自己完成。
/// 这些接口不是公开给第三方的，网易云改版时这里可能需要跟着改。
enum NeteaseAPI {
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
    private static let home = URL(string: "https://music.163.com/")!
    // 网页版给请求内容加密的固定参数（公开的，每个网页访客都一样）
    private static let presetKey = "0CoJUm6Qyw8W8jud"
    private static let vector = "0102030405060708"
    // 第二层加密的密钥本该每次随机；固定用一个，它对应的"加密后的密钥"也就可以事先算好
    private static let secondKey = "mactvmactvmactv1"
    private static let encryptedSecondKey = "b9022e0a42e80e43efcc52346f29b0ceaae4de8930bb071f6dd523c35019a8c06067e52f2701572bb4560f56e6bc28e6ce9ba4e902c69f7882ea10b091e43eaf4dc0e7802158beca2e1c383f6307583691f31cdbafdf278583f454dbe743a6ec2d8f55b14776156ea0f4009bfd1f1b18f5866d53cc52850428f6b60d33127ed0"

    private static func aes(_ data: Data, key: String) -> Data? {
        let keyBytes = Array(key.utf8), ivBytes = Array(vector.utf8), input = [UInt8](data)
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var length = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                             keyBytes, keyBytes.count, ivBytes, input, input.count, &output, output.count, &length)
        return status == kCCSuccess ? Data(output.prefix(length)) : nil
    }

    // 登录信息自己管：系统自带的那份存储在应用被关掉时不一定来得及写盘，重启后就成了"没登录"。
    // 这里把服务器发回来的登录信息记在内存里，并存进这个应用自己的偏好设置（退出登录时删掉）。
    private static let lock = NSLock()
    nonisolated(unsafe) private static var jar: [String: String] = UserDefaults.standard.dictionary(forKey: storeKey) as? [String: String] ?? [:]
    private static let storeKey = "neteaseLogin"

    private static func value(_ name: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return jar[name] ?? ""
    }

    private static func snapshot() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return jar
    }

    private static func remember(_ response: URLResponse, for url: URL) {
        guard let http = response as? HTTPURLResponse, let fields = http.allHeaderFields as? [String: String] else { return }
        let fresh = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        guard !fresh.isEmpty else { return }
        lock.lock()
        for cookie in fresh { jar[cookie.name] = cookie.value.isEmpty ? nil : cookie.value }
        let snapshot = jar
        lock.unlock()
        UserDefaults.standard.set(snapshot, forKey: storeKey)
    }

    private static var csrf: String { value("__csrf") }

    /// 是否有登录信息（不代表一定还有效）
    static var hasLogin: Bool { !value("MUSIC_U").isEmpty }

    /// 退出登录：把这个应用里网易云的登录信息全部删掉
    static func forgetLogin() {
        lock.lock(); jar = [:]; lock.unlock()
        UserDefaults.standard.removeObject(forKey: storeKey)
    }

    private static func call(_ path: String, _ payload: [String: Any]) async -> [String: Any]? {
        var body = payload
        let token = csrf
        body["csrf_token"] = token
        guard let json = try? JSONSerialization.data(withJSONObject: body),
              let first = aes(json, key: presetKey)?.base64EncodedData(),
              let second = aes(first, key: secondKey)?.base64EncodedString(),
              let params = second.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "https://music.163.com/weapi/\(path)" + (token.isEmpty ? "" : "?csrf_token=\(token)")) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpShouldHandleCookies = false
        var sent = snapshot()
        // 告诉服务器这是电脑端（取歌曲地址时要）。只在登录之后带：登录前带着它，要二维码的请求会被风控拒绝。
        if sent["MUSIC_U"] != nil { sent["os"] = "pc" } else { sent["os"] = nil }
        if !sent.isEmpty { request.setValue(sent.map { "\($0.key)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie") }
        request.httpBody = Data("params=\(params)&encSecKey=\(encryptedSecondKey)".utf8)
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        remember(response, for: url)
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func image(_ value: Any?, size: Int = 500) -> URL? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return URL(string: text.replacingOccurrences(of: "http://", with: "https://") + "?param=\(size)y\(size)")
    }

    private static func song(_ item: [String: Any]) -> NeteaseSong? {
        guard let id = item["id"] as? Int, let name = item["name"] as? String else { return nil }
        let artists = (item["ar"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        return NeteaseSong(id: id, name: name, artist: artists.joined(separator: " / "),
                           cover: image((item["al"] as? [String: Any])?["picUrl"]), duration: (item["dt"] as? Int ?? 0) / 1000)
    }

    // MARK: 登录

    /// 登录在网易云官方网页上完成（应用里打开的网页）。登录好以后，把网页那边的登录信息交到这里，
    /// 之后取歌单、取歌就用它。直接调接口扫码登录会被网易云拒绝（8821），所以不走那条路。
    static func importLogin(_ cookies: [String: String]) {
        lock.lock(); jar = cookies; lock.unlock()
        UserDefaults.standard.set(cookies, forKey: storeKey)
    }

    static func account() async -> NeteaseAccount? {
        guard let profile = (await call("w/nuser/account/get", [:]))?["profile"] as? [String: Any],
              let id = profile["userId"] as? Int else { return nil }
        return NeteaseAccount(id: id, name: profile["nickname"] as? String ?? "", avatar: image(profile["avatarUrl"], size: 160))
    }

    // MARK: 内容

    /// 每日推荐
    static func daily() async -> [NeteaseSong] {
        let data = (await call("v3/discovery/recommend/songs", [:]))?["data"] as? [String: Any]
        return (data?["dailySongs"] as? [[String: Any]] ?? []).compactMap(song)
    }

    /// 我的歌单；第一个是"我喜欢的音乐"
    static func playlists(user: Int) async -> [NeteasePlaylist] {
        ((await call("user/playlist", ["uid": user, "limit": 60, "offset": 0, "includeVideo": false]))?["playlist"] as? [[String: Any]] ?? []).compactMap(playlist)
    }

    /// 歌单里的歌（最多前 limit 首）
    static func songs(playlist: Int, limit: Int = 500) async -> [NeteaseSong] {
        let detail = (await call("v6/playlist/detail", ["id": playlist, "n": 100000, "s": 8]))?["playlist"] as? [String: Any]
        let tracks = (detail?["tracks"] as? [[String: Any]] ?? []).compactMap(song)
        if tracks.count >= limit { return Array(tracks.prefix(limit)) }
        // 列表里只带了前一部分歌的完整信息，其余只有编号：补齐
        let ids = (detail?["trackIds"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? Int }.prefix(limit)
        let missing = ids.filter { id in !tracks.contains { $0.id == id } }
        guard !missing.isEmpty else { return tracks }
        let query = "[" + missing.map { "{\"id\":\($0)}" }.joined(separator: ",") + "]"
        let more = ((await call("v3/song/detail", ["c": query]))?["songs"] as? [[String: Any]] ?? []).compactMap(song)
        let all = Dictionary((tracks + more).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { all[$0] }
    }

    /// 带时间的歌词。优先用逐字歌词（每个字什么时候唱都有，卡拉 OK 那种）；没有就用普通的按句歌词。
    /// 没有歌词（纯音乐）返回空。
    static func lyrics(song: Int) async -> [NeteaseLyricLine] {
        let data = await call("song/lyric/v1", ["id": song, "cp": false, "tv": 0, "lv": 0, "rv": 0, "kv": 0, "yv": 0, "ytv": 0, "yrv": 0])
        let byWord = wordLines((data?["yrc"] as? [String: Any])?["lyric"] as? String ?? "")
        if byWord.count > 2 { return byWord }
        let text = (data?["lrc"] as? [String: Any])?["lyric"] as? String ?? ""
        var lines: [NeteaseLyricLine] = []
        for raw in text.split(separator: "\n") {
            // 一行开头可以有一个或几个 [分:秒] 标记，后面是这句词
            var rest = Substring(raw)
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let parts = rest[rest.index(after: rest.startIndex)..<close].split(separator: ":")
                if parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) { times.append(minutes * 60 + seconds) }
                rest = rest[rest.index(after: close)...]
            }
            let words = rest.trimmingCharacters(in: .whitespaces)
            guard !words.isEmpty else { continue }
            for time in times { lines.append(NeteaseLyricLine(time: time, text: words)) }
        }
        // 没有词的歌，网易云会给一句"纯音乐，请欣赏"之类的话：那不是歌词，当作没有
        let real = lines.filter { !$0.text.contains("纯音乐") }
        return real.count > 2 ? real.sorted { $0.time < $1.time } : []
    }

    /// 逐字歌词的格式：`[句子开始毫秒,时长](字开始毫秒,时长,0)字(…)字`
    private static func wordLines(_ text: String) -> [NeteaseLyricLine] {
        var lines: [NeteaseLyricLine] = []
        for raw in text.split(separator: "\n") where raw.hasPrefix("[") {
            guard let close = raw.firstIndex(of: "]"),
                  let start = Double(raw[raw.index(after: raw.startIndex)..<close].split(separator: ",").first ?? "") else { continue }
            var words: [NeteaseLyricLine.Word] = []
            var rest = raw[raw.index(after: close)...]
            while let open = rest.firstIndex(of: "("), let shut = rest[open...].firstIndex(of: ")") {
                let numbers = rest[rest.index(after: open)..<shut].split(separator: ",").compactMap { Double($0) }
                let time = numbers.first ?? start
                let after = rest[rest.index(after: shut)...]
                let end = after.firstIndex(of: "(") ?? after.endIndex
                words.append(.init(time: time / 1000, text: String(after[..<end]), duration: (numbers.count > 1 ? numbers[1] : 300) / 1000))
                rest = after[end...]
            }
            let whole = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            if !whole.isEmpty { lines.append(NeteaseLyricLine(time: start / 1000, text: whole, words: words)) }
        }
        return lines
    }

    /// 这首歌的播放地址（约 20 分钟内有效），以及实际给到的音质。
    /// level：standard 标准、higher 较高、exhigh 极高、lossless 无损、hires Hi-Res、jymaster 超清母带；
    /// 账号或这首歌没有那一档时，服务器会给它能给的最高一档。没有版权、需要会员或地区不可用时返回 nil。
    static func address(song: Int, level: String) async -> (url: URL, level: String)? {
        let lossless = ["lossless", "hires", "jymaster"].contains(level)
        let list = (await call("song/enhance/player/url/v1", ["ids": "[\(song)]", "level": level, "encodeType": lossless ? "flac" : "aac"]))?["data"] as? [[String: Any]]
        guard let item = list?.first, let text = item["url"] as? String, !text.isEmpty,
              let url = URL(string: text.replacingOccurrences(of: "http://", with: "https://")) else { return nil }
        return (url, item["level"] as? String ?? level)
    }

    // MARK: 发现

    private static func playlist(_ item: [String: Any]) -> NeteasePlaylist? {
        guard let id = item["id"] as? Int, let name = item["name"] as? String else { return nil }
        return NeteasePlaylist(id: id, name: name, cover: image(item["coverImgUrl"] ?? item["picUrl"]), count: item["trackCount"] as? Int ?? 0,
                               creator: (item["creator"] as? [String: Any])?["userId"] as? Int ?? item["userId"] as? Int ?? 0)
    }

    /// 推荐歌单（登录后是按你的口味推荐的）
    static func recommendedPlaylists() async -> [NeteasePlaylist] {
        ((await call("personalized/playlist", ["limit": 30, "total": true, "n": 1000]))?["result"] as? [[String: Any]] ?? []).compactMap(playlist)
    }

    /// 排行榜（飙升榜、新歌榜、热歌榜……每个榜是一个歌单）
    static func charts() async -> [NeteasePlaylist] {
        Array(((await call("toplist", [:]))?["list"] as? [[String: Any]] ?? []).compactMap(playlist).prefix(20))
    }

    static func searchSongs(_ keyword: String) async -> [NeteaseSong] {
        let result = (await call("cloudsearch/pc", ["s": keyword, "type": 1, "limit": 40, "offset": 0, "total": true]))?["result"] as? [String: Any]
        return (result?["songs"] as? [[String: Any]] ?? []).compactMap(song)
    }

    static func searchPlaylists(_ keyword: String) async -> [NeteasePlaylist] {
        let result = (await call("cloudsearch/pc", ["s": keyword, "type": 1000, "limit": 20, "offset": 0, "total": true]))?["result"] as? [String: Any]
        return (result?["playlists"] as? [[String: Any]] ?? []).compactMap(playlist)
    }

    // MARK: 往账号里写东西：喜欢、收藏（和在手机上操作的效果一样）

    private static func done(_ result: [String: Any]?) -> Bool { (result?["code"] as? Int) == 200 }

    /// 我喜欢的歌（只有编号）
    static func likedSongs(user: Int) async -> Set<Int> {
        Set((await call("song/like/get", ["uid": user]))?["ids"] as? [Int] ?? [])
    }

    static func setLiked(song: Int, _ on: Bool) async -> Bool {
        done(await call("radio/like", ["alg": "itembased", "trackId": song, "like": on, "time": "3"]))
    }

    /// 把一首歌加进歌单。已经在里面也算成功。
    static func add(song: Int, to playlist: Int) async -> Bool {
        let result = await call("playlist/manipulate/tracks", ["op": "add", "pid": playlist, "trackIds": "[\(song)]", "imme": "true"])
        return done(result) || (result?["code"] as? Int) == 502
    }

    static func createPlaylist(_ name: String) async -> NeteasePlaylist? {
        ((await call("playlist/create", ["name": name, "privacy": 0, "type": "NORMAL"]))?["playlist"] as? [String: Any]).flatMap(playlist)
    }

    /// 收藏 / 取消收藏别人的歌单
    static func setSubscribed(playlist: Int, _ on: Bool) async -> Bool {
        done(await call(on ? "playlist/subscribe" : "playlist/unsubscribe", ["id": playlist]))
    }
}
