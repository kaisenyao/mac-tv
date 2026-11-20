import Foundation

/// 手机遥控页上"发到电视"：粘贴进来的一段文字——可能只是一个网址，也可能是 App 分享出来的一整段
/// （"【标题】 https://b23.tv/xxxx"、"分享 xxx 的单曲《…》: https://163cn.tv/xxxx (来自@网易云音乐)"）。
/// 从里面找出链接、认出是什么：哔哩哔哩视频、网易云的歌 / 歌单 / 专辑 / 歌手、YouTube 视频交给对应的应用打开，
/// 其余的网页在网页播放器里打开。
enum PhoneLink: Equatable {
    enum Netease: String, CaseIterable, Sendable { case song, playlist, album, artist }

    case bilibili(bvid: String?, aid: Int?, page: Int?)
    /// 哔哩哔哩的直播间（live.bilibili.com/房间号）
    case bilibiliLive(room: Int)
    case netease(Netease, id: Int)
    case youtube(id: String)
    case web(URL)

    /// 读一段文字的结果：已经认出来了，或者是要先跟一下跳转才知道是什么的短链接
    enum Reading: Equatable {
        case ready(PhoneLink)
        case short(URL)
    }

    /// 分享出来的短链接：跟着跳转走一下才知道指向哪个视频 / 哪首歌
    static let shortHosts: Set<String> = ["b23.tv", "bili2233.cn", "bili22.cn", "bili33.cn", "163cn.tv", "163cn.link"]

    /// 告诉手机打开的是什么（手机遥控页是英文的）："Bilibili video""NetEase Cloud Music playlist""website"
    var title: String {
        switch self {
        case .bilibili: "Bilibili video"
        case .bilibiliLive: "Bilibili live room"
        case .netease(let kind, _): "NetEase Cloud Music \(kind.rawValue)"
        case .youtube: "YouTube video"
        case .web: "website"
        }
    }

    /// 读一段文字。里面有网址就按网址认；没有网址、但写着 BV 号或 av 号，当成哔哩哔哩视频；都没有返回 nil
    static func read(_ text: String) -> Reading? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 4096 else { return nil }
        if let url = firstURL(in: trimmed) {
            if shortHosts.contains((url.host ?? "").lowercased()) { return .short(url) }
            return .ready(classify(url))
        }
        if let bvid = match("BV[0-9A-Za-z]{10}", in: trimmed) { return .ready(.bilibili(bvid: bvid, aid: nil, page: nil)) }
        if let av = match("(?i)\\bav([0-9]{1,12})\\b", in: trimmed, group: 1).flatMap(Int.init) {
            return .ready(.bilibili(bvid: nil, aid: av, page: nil))
        }
        return nil
    }

    /// 文字里的第一个 http / https 网址（分享文字里常常前后夹着标题、说明）
    static func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for found in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = found.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { continue }
            return url
        }
        return nil
    }

    /// 认出一个网址是什么
    static func classify(_ url: URL) -> PhoneLink {
        let host = (url.host ?? "").lowercased()
        let page = query(url, "p").flatMap(Int.init)
        if host == "live.bilibili.com", let room = url.pathComponents.dropFirst().first.flatMap(Int.init), room > 0 {
            return .bilibiliLive(room: room)
        }
        if host == "bilibili.com" || host.hasSuffix(".bilibili.com") || shortHosts.contains(host) && host.hasPrefix("b") {
            let text = url.absoluteString
            if let bvid = match("BV[0-9A-Za-z]{10}", in: text) { return .bilibili(bvid: bvid, aid: nil, page: page) }
            if let av = match("(?i)/av([0-9]{1,12})", in: text, group: 1).flatMap(Int.init) { return .bilibili(bvid: nil, aid: av, page: page) }
        }
        if host == "music.163.com" || host.hasSuffix(".music.163.com") {
            // 网页版把路径写在 # 后面：music.163.com/#/song?id=123；手机分享是 y.music.163.com/m/song?id=123
            var path = url.path, id = query(url, "id")
            if let fragment = url.fragment, fragment.hasPrefix("/"), let inner = URLComponents(string: fragment) {
                path = inner.path
                id = inner.queryItems?.first { $0.name == "id" }?.value ?? id
            }
            let parts = path.split(separator: "/").map(String.init)
            for kind in Netease.allCases {
                guard let at = parts.lastIndex(of: kind.rawValue) else { continue }
                // 也有把编号写在路径里的：/song/123
                let number = id.flatMap(Int.init) ?? (at + 1 < parts.count ? Int(parts[at + 1]) : nil)
                if let number, number > 0 { return .netease(kind, id: number) }
            }
        }
        if host == "youtu.be", let id = url.pathComponents.dropFirst().first, valid(youtube: id) { return .youtube(id: id) }
        if host == "youtube.com" || host.hasSuffix(".youtube.com"), host != "music.youtube.com" {
            if let id = query(url, "v"), valid(youtube: id) { return .youtube(id: id) }
            let parts = url.pathComponents
            if let at = parts.firstIndex(where: { ["shorts", "live", "embed"].contains($0) }), at + 1 < parts.count, valid(youtube: parts[at + 1]) {
                return .youtube(id: parts[at + 1])
            }
        }
        return .web(url)
    }

    /// 短链接跟着跳转走到底，看最后落在哪个网址上（不带任何登录信息）
    static func resolve(_ url: URL) async -> URL? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue(UserAgent.safari, forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let (_, response) = try? await session.data(for: request) else { return nil }
        return response.url
    }

    private static func valid(youtube id: String) -> Bool {
        id.count == 11 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    private static func query(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    private static func match(_ pattern: String, in text: String, group: Int = 0) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(found.range(at: group), in: text) else { return nil }
        return String(text[range])
    }
}

extension TVController {
    /// 手机发来一段文字：认出是什么就交给对应的应用打开，返回给手机看的名字（"哔哩哔哩视频"）；
    /// 认不出、也不是网址时返回 nil（手机那边按普通网址再试一次）
    @discardableResult
    func openPhoneLink(_ text: String) -> String? {
        guard let reading = PhoneLink.read(text) else { return nil }
        switch reading {
        case .ready(let link):
            open(link)
            return link.title
        case .short(let url):
            showToast("Opening Link…")
            Task { @MainActor in
                let target = await PhoneLink.resolve(url) ?? url
                self.open(PhoneLink.classify(target))
            }
            return "shared link"
        }
    }

    private func open(_ link: PhoneLink) {
        switch link {
        case .bilibili(let bvid, let aid, let page):
            if !bilibiliOpen, let app = services.first(where: { $0.id == BilibiliStore.appID }) { open(app) }
            bilibiliStore.openLinked(bvid: bvid, aid: aid, page: page)
        case .bilibiliLive(let room):
            if !bilibiliOpen, let app = services.first(where: { $0.id == BilibiliStore.appID }) { open(app) }
            bilibiliStore.openLinkedLive(room: room)
        case .netease(let kind, let id):
            if !neteaseOpen, let app = services.first(where: { $0.id == NeteaseStore.appID }) { open(app) }
            neteaseStore.openLinked(kind, id: id)
        case .youtube(let id):
            // YouTube 用电视版打开（遥控器操作、全屏），直接跳到这个视频
            openYouTubeVideo(id)
        case .web(let url):
            open(Service.website(url))
        }
    }
}
