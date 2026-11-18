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

struct NeteasePlaylist: Hashable, Sendable {
    let id: Int
    let name: String
    var cover: URL? = nil
    var count = 0
}

struct NeteaseAccount: Hashable, Sendable {
    let id: Int
    let name: String
    var avatar: URL? = nil
}

/// 网易云音乐网页版自己在用的接口。登录信息由系统的网络库自己保存和携带（这个应用自己的那一份），
/// 这里的代码不读也不存账号密码；登录只有扫码一种方式。
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

    private static var csrf: String {
        HTTPCookieStorage.shared.cookies(for: home)?.first { $0.name == "__csrf" }?.value ?? ""
    }

    /// 是否有登录信息（不代表一定还有效）
    static var hasLogin: Bool {
        HTTPCookieStorage.shared.cookies(for: home)?.contains { $0.name == "MUSIC_U" && !$0.value.isEmpty } ?? false
    }

    /// 退出登录：把这个应用里网易云的登录信息全部删掉
    static func forgetLogin() {
        for cookie in HTTPCookieStorage.shared.cookies ?? [] where cookie.domain.hasSuffix("163.com") {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
    }

    private static func call(_ path: String, _ payload: [String: Any]) async -> [String: Any]? {
        // 告诉服务器这是电脑端（取歌曲地址时要）。只在登录之后带：登录前带着它，要二维码的请求会被风控拒绝。
        let marked = HTTPCookieStorage.shared.cookies(for: home)?.first { $0.name == "os" }
        if hasLogin {
            if marked == nil, let cookie = HTTPCookie(properties: [.domain: ".music.163.com", .path: "/", .name: "os", .value: "pc"]) {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
        } else if let marked {
            HTTPCookieStorage.shared.deleteCookie(marked)
        }
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
        request.httpBody = Data("params=\(params)&encSecKey=\(encryptedSecondKey)".utf8)
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
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

    // MARK: 扫码登录

    /// 要一个新的二维码；返回二维码里的网址和它的编号
    static func loginCode() async -> (key: String, address: String)? {
        guard let key = (await call("login/qrcode/unikey", ["type": 3, "noCheckToken": true]))?["unikey"] as? String else { return nil }
        return (key, "https://music.163.com/login?codekey=\(key)")
    }

    /// 800 二维码过期、801 等待扫码、802 已扫码等确认、803 登录成功（登录信息这时已经由系统存好）
    static func loginState(key: String) async -> Int {
        (await call("login/qrcode/client/login", ["key": key, "type": 3]))?["code"] as? Int ?? 0
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
        let list = (await call("user/playlist", ["uid": user, "limit": 60, "offset": 0, "includeVideo": false]))?["playlist"] as? [[String: Any]] ?? []
        return list.compactMap { item in
            guard let id = item["id"] as? Int, let name = item["name"] as? String else { return nil }
            return NeteasePlaylist(id: id, name: name, cover: image(item["coverImgUrl"]), count: item["trackCount"] as? Int ?? 0)
        }
    }

    /// 歌单里的歌（最多前 limit 首）
    static func songs(playlist: Int, limit: Int = 200) async -> [NeteaseSong] {
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

    /// 这首歌的播放地址（约 20 分钟内有效）。没有版权、需要会员或地区不可用时返回 nil。
    static func address(song: Int) async -> URL? {
        let list = (await call("song/enhance/player/url/v1", ["ids": "[\(song)]", "level": "exhigh", "encodeType": "aac"]))?["data"] as? [[String: Any]]
        guard let text = list?.first?["url"] as? String, !text.isEmpty else { return nil }
        return URL(string: text.replacingOccurrences(of: "http://", with: "https://"))
    }
}
