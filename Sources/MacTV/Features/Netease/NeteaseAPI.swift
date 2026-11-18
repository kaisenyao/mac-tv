import CommonCrypto
import CryptoKit
import Foundation

struct NeteaseArtist: Hashable, Sendable {
    let id: Int
    let name: String
}

struct NeteaseSong: Hashable, Sendable {
    let id: Int
    let name: String
    var artist = ""
    var cover: URL? = nil
    /// 秒
    var duration = 0
    var artists: [NeteaseArtist] = []
    var album = 0
    var albumName = ""

    // 同一首歌从不同地方取来，附带的信息可能略有不同：只按编号认
    static func == (a: NeteaseSong, b: NeteaseSong) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
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
    /// 歌单页也用来显示歌手的热门歌曲、专辑里的歌
    enum Kind: Hashable, Sendable { case playlist, artist, album }
    let id: Int
    let name: String
    var cover: URL? = nil
    var count = 0
    /// 建这个歌单的人
    var creator = 0
    var kind = Kind.playlist
    /// 卡片第二行：专辑是歌手名；歌手页是"多少首歌 · 多少张专辑"
    var subtitle = ""
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
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            return hasLogin ? await clientCall(path, payload) : nil
        }
        remember(response, for: url)
        let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        // 读取平时走网页版（快一点）；一旦被风控拦下，登录了的话就改走客户端接口再试一次
        if let code = result?["code"] as? Int, [-460, -462, 405, 406].contains(code), hasLogin,
           let retry = await clientCall(path, payload), (retry["code"] as? Int) == 200 {
            return retry
        }
        return result
    }

    private static func image(_ value: Any?, size: Int = 500) -> URL? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return URL(string: text.replacingOccurrences(of: "http://", with: "https://") + "?param=\(size)y\(size)")
    }

    private static func song(_ item: [String: Any]) -> NeteaseSong? {
        guard let id = item["id"] as? Int, let name = item["name"] as? String else { return nil }
        let artists = (item["ar"] as? [[String: Any]] ?? []).compactMap { artist -> NeteaseArtist? in
            guard let name = artist["name"] as? String else { return nil }
            return NeteaseArtist(id: artist["id"] as? Int ?? 0, name: name)
        }
        let album = item["al"] as? [String: Any]
        return NeteaseSong(id: id, name: name, artist: artists.map(\.name).joined(separator: " / "),
                           cover: image(album?["picUrl"]), duration: (item["dt"] as? Int ?? 0) / 1000,
                           artists: artists.filter { $0.id > 0 }, album: album?["id"] as? Int ?? 0, albumName: album?["name"] as? String ?? "")
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
    static func songs(playlist: Int, limit: Int = 3000) async -> [NeteaseSong] {
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
        let payload: [String: Any] = ["ids": "[\(song)]", "level": level, "encodeType": "flac"]
        // 先走客户端那套接口（网页版最高只给到无损）；它不通再退回网页版
        var list = (await clientCall("song/enhance/player/url/v1", payload))?["data"] as? [[String: Any]]
        if list?.first?["url"] as? String == nil {
            list = (await call("song/enhance/player/url/v1", payload))?["data"] as? [[String: Any]]
        }
        let item = list?.first
        note("取歌 \(song) 要=\(level) 给=\(item?["level"] ?? "无") 码率=\(item?["br"] ?? "无") 格式=\(item?["type"] ?? "无") code=\(item?["code"] ?? "无") fee=\(item?["fee"] ?? "无")")
        guard let item, let text = item["url"] as? String, !text.isEmpty,
              let url = URL(string: text.replacingOccurrences(of: "http://", with: "https://")) else { return nil }
        return (url, item["level"] as? String ?? level)
    }

    // MARK: 官方客户端用的那套接口（eapi）

    // 网页版的取歌接口最高只给到无损；Hi-Res、超清母带只从客户端这套接口给。
    // 用的仍是你自己的登录、你账号本来就有的权限，和官方电脑客户端发出的请求一样。
    private static let clientKey = "e82ckenh8dichen8"
    private static let clientAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36 Chrome/91.0.4472.164 NeteaseMusicDesktop/3.1.17.204416"

    private static func aesECB(_ data: Data, key: String) -> Data? {
        let keyBytes = Array(key.utf8), input = [UInt8](data)
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var length = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                             keyBytes, keyBytes.count, nil, input, input.count, &output, output.count, &length)
        return status == kCCSuccess ? Data(output.prefix(length)) : nil
    }

    /// 登录信息的名字里有下划线（MUSIC_U、__csrf）：下划线一编码，服务器就认不出登录，按未登录处理
    private static let cookieSafe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    private static func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: cookieSafe) ?? text
    }

    private static func clientCall(_ path: String, _ payload: [String: Any]) async -> [String: Any]? {
        let jar = snapshot()
        guard let token = jar["MUSIC_U"] else { return nil }
        let now = Date().timeIntervalSince1970
        let header: [String: String] = [
            "os": "pc", "appver": "3.1.17.204416", "osver": "Microsoft-Windows-10", "versioncode": "140",
            "buildver": "\(Int(now))", "resolution": "1920x1080", "__csrf": jar["__csrf"] ?? "", "MUSIC_U": token,
            "requestId": "\(Int(now * 1000))_\(String(format: "%04d", Int.random(in: 0..<1000)))",
        ]
        var body = payload
        body["header"] = header
        guard let json = try? JSONSerialization.data(withJSONObject: body, options: .withoutEscapingSlashes),
              let text = String(data: json, encoding: .utf8) else { return nil }
        let api = "/api/" + path
        let digest = Insecure.MD5.hash(data: Data("nobody\(api)use\(text)md5forencrypt".utf8)).map { String(format: "%02x", $0) }.joined()
        guard let sealed = aesECB(Data("\(api)-36cd479b6b5-\(text)-36cd479b6b5-\(digest)".utf8), key: clientKey),
              let url = URL(string: "https://interface.music.163.com/eapi/" + path) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue(clientAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(header.map { "\(escape($0.key))=\(escape($0.value))" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        request.httpShouldHandleCookies = false
        request.httpBody = Data("params=\(sealed.map { String(format: "%02X", $0) }.joined())".utf8)
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// 这首歌最高有哪一档音质（song），以及这个账号最高能听到哪一档（account）
    static func levels(song: Int) async -> (song: String, account: String)? {
        let data = await call("v3/song/detail", ["c": "[{\"id\":\(song)}]"])
        guard let privilege = (data?["privileges"] as? [[String: Any]])?.first else { return nil }
        note("权限 \(song) 歌曲最高=\(privilege["maxBrLevel"] ?? "无") 账号可听=\(privilege["plLevel"] ?? "无") 可下载=\(privilege["dlLevel"] ?? "无") fee=\(privilege["fee"] ?? "无")")
        guard let top = privilege["maxBrLevel"] as? String, let mine = privilege["plLevel"] as? String else { return nil }
        return (top, mine)
    }

    /// 排查用的记录（~/Library/Logs/MacTV-netease.log）：只记音质档位这类信息，不记任何登录内容
    private static func note(_ line: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MacTV-netease.log")
        let text = "\(Date()) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(text.utf8)); try? handle.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
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

    static func searchArtists(_ keyword: String) async -> [NeteasePlaylist] {
        let result = (await call("cloudsearch/pc", ["s": keyword, "type": 100, "limit": 12, "offset": 0, "total": true]))?["result"] as? [String: Any]
        return (result?["artists"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? Int, let name = item["name"] as? String else { return nil }
            return NeteasePlaylist(id: id, name: name, cover: image(item["picUrl"] ?? item["img1v1Url"]), count: 0, kind: .artist)
        }
    }

    static func searchAlbums(_ keyword: String) async -> [NeteasePlaylist] {
        let result = (await call("cloudsearch/pc", ["s": keyword, "type": 10, "limit": 20, "offset": 0, "total": true]))?["result"] as? [String: Any]
        return (result?["albums"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? Int, let name = item["name"] as? String else { return nil }
            let artist = (item["artist"] as? [String: Any])?["name"] as? String ?? ""
            return NeteasePlaylist(id: id, name: name, cover: image(item["picUrl"]), count: item["size"] as? Int ?? 0, kind: .album, subtitle: artist)
        }
    }

    static func searchPlaylists(_ keyword: String) async -> [NeteasePlaylist] {
        let result = (await call("cloudsearch/pc", ["s": keyword, "type": 1000, "limit": 20, "offset": 0, "total": true]))?["result"] as? [String: Any]
        return (result?["playlists"] as? [[String: Any]] ?? []).compactMap(playlist)
    }

    // MARK: 歌手、专辑

    /// 歌手：名字、照片和热门歌曲
    static func artist(_ id: Int) async -> (info: NeteasePlaylist, songs: [NeteaseSong])? {
        guard let data = await call("v1/artist/\(id)", [:]), let artist = data["artist"] as? [String: Any],
              let name = artist["name"] as? String else { return nil }
        let songs = (data["hotSongs"] as? [[String: Any]] ?? []).compactMap(song)
        let counts = [(artist["musicSize"] as? Int).map { "\($0) 首歌" }, (artist["albumSize"] as? Int).map { "\($0) 张专辑" }]
            .compactMap { $0 }.joined(separator: " · ")
        return (NeteasePlaylist(id: id, name: name, cover: image(artist["picUrl"] ?? artist["img1v1Url"]), count: songs.count,
                                kind: .artist, subtitle: counts), songs)
    }

    /// 专辑：名字、封面和里面的歌
    static func album(_ id: Int) async -> (info: NeteasePlaylist, songs: [NeteaseSong])? {
        guard let data = await call("v1/album/\(id)", [:]), let album = data["album"] as? [String: Any],
              let name = album["name"] as? String else { return nil }
        let songs = (data["songs"] as? [[String: Any]] ?? []).compactMap(song)
        return (NeteasePlaylist(id: id, name: name, cover: image(album["picUrl"]), count: songs.count, kind: .album), songs)
    }

    // MARK: 往账号里写东西：喜欢、收藏（和在手机上操作的效果一样）

    private static func done(_ result: [String: Any]?) -> Bool { (result?["code"] as? Int) == 200 }

    /// 往账号里写东西：网页版接口会被风控拦下（-460），先走客户端接口，不行再试网页版
    private static func write(_ path: String, _ payload: [String: Any]) async -> [String: Any]? {
        let client = await clientCall(path, payload)
        if done(client) { return client }
        return await call(path, payload) ?? client
    }

    /// 我喜欢的歌（只有编号）
    static func likedSongs(user: Int) async -> Set<Int> {
        Set((await call("song/like/get", ["uid": user]))?["ids"] as? [Int] ?? [])
    }

    static func setLiked(song: Int, _ on: Bool) async -> Bool {
        done(await write("radio/like", ["alg": "itembased", "trackId": song, "like": on, "time": "3"]))
    }

    /// 把一首歌加进歌单。已经在里面也算成功。
    static func add(song: Int, to playlist: Int) async -> Bool {
        let result = await write("playlist/manipulate/tracks", ["op": "add", "pid": playlist, "trackIds": "[\(song)]", "imme": "true"])
        return done(result) || (result?["code"] as? Int) == 502
    }

    static func createPlaylist(_ name: String) async -> NeteasePlaylist? {
        ((await write("playlist/create", ["name": name, "privacy": 0, "type": "NORMAL"]))?["playlist"] as? [String: Any]).flatMap(playlist)
    }

    static func rename(playlist: Int, to name: String) async -> Bool {
        done(await write("playlist/update/name", ["id": playlist, "name": name]))
    }

    static func deletePlaylist(_ id: Int) async -> Bool {
        done(await write("playlist/remove", ["ids": "[\(id)]"]))
    }

    /// 收藏 / 取消收藏别人的歌单
    static func setSubscribed(playlist: Int, _ on: Bool) async -> Bool {
        done(await write(on ? "playlist/subscribe" : "playlist/unsubscribe", ["id": playlist]))
    }
}
