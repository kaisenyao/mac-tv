import Foundation
import WebKit

/// YouTube 在主屏顶部放什么：为你推荐（YouTube 首页，按你看过的东西推荐，不靠订阅）、继续观看（观看记录）、订阅更新
enum YouTubeShelfSource: String, CaseIterable {
    case recommended, history, subscriptions
    var title: String {
        switch self {
        // YouTube 不是中文应用：和系统一样用英文
        case .recommended: "Recommended"
        case .history: "Continue Watching"
        case .subscriptions: "Subscriptions"
        }
    }
    /// YouTube 电视版自己用的页面编号
    var browseID: String {
        switch self {
        case .recommended: "default"
        case .history: "FEhistory"
        case .subscriptions: "FEsubscriptions"
        }
    }
    /// 每个人（个人资料）各选各的（见 ProfileSpace）
    static var current: YouTubeShelfSource {
        get { ProfileSpace.current.defaults.string(forKey: "youtubeShelf").flatMap(YouTubeShelfSource.init) ?? .recommended }
        set { ProfileSpace.current.defaults.set(newValue.rawValue, forKey: "youtubeShelf") }
    }
}

/// 主屏上的 YouTube 是电视版界面，它登录后不用普通的 cookie，而是在自己的网页存储里存着一份登录凭证，自己定时续期。
/// 这里只读它手上那份还没过期的访问凭证（在一个看不见的、同一个 YouTube 网址下的小网页里读），
/// 不自己保存、不自己续期，也只发给 YouTube。过期了（比如一天多没开过 YouTube）就当没有
@MainActor
final class YouTubeSignIn {
    static let shared = YouTubeSignIn()
    private var pending: Task<String?, Never>?

    /// 同一时间只读一次：几处同时要（几次刷新挤在一起）时都等这一次的结果
    func accessToken(store: WKWebsiteDataStore) async -> String? {
        if let pending { return await pending.value }
        let task = Task { @MainActor in await Self.read(store) }
        pending = task
        defer { pending = nil }
        return await task.value
    }

    private static func read(_ store: WKWebsiteDataStore) async -> String? {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        let web = WKWebView(frame: .zero, configuration: configuration)
        let loader = PageLoader()
        web.navigationDelegate = loader
        await loader.load(web, baseURL: URL(string: "https://www.youtube.com/"))
        let script = "localStorage.getItem('yt.leanback.default::cached-access-tokens')"
        guard let text = try? await web.evaluateJavaScript(script) as? String else {
            Log.playback.info("youtube shelf: no saved sign-in in the TV interface")
            return nil
        }
        return token(fromStorage: text)
    }

    /// 存着的那一项里第一个账号的访问凭证，还没过期才算（提前一分钟当过期）
    nonisolated static func token(fromStorage text: String, now: Date = Date()) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let accounts = json["data"] as? [String: Any] else { return nil }
        for case let entry as [String: Any] in accounts.values {
            guard let token = entry["accessToken"] as? String, !token.isEmpty else { continue }
            let expires = (entry["accessTokenServerExpiration"] as? Double) ?? (entry["accessTokenServerExpiration"] as? Int).map(Double.init) ?? 0
            if expires / 1000 > now.timeIntervalSince1970 + 60 { return token }
        }
        return nil
    }

}

/// 等一个看不见的小网页载好（最多等 5 秒）。每次读都用自己的一个，几次读不会互相串
@MainActor
private final class PageLoader: NSObject, WKNavigationDelegate {
    private var done: CheckedContinuation<Void, Never>?

    func load(_ web: WKWebView, baseURL: URL?) async {
        await withCheckedContinuation { continuation in
            done = continuation
            web.loadHTMLString("<html></html>", baseURL: baseURL)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.finish()
            }
        }
    }

    private func finish() {
        done?.resume()
        done = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish() }
}

/// 用电视版的登录向 YouTube 要内容（和电视版自己要的是同一份），只要视频，不要合集和短视频
enum YouTubeFeed {
    struct Video: Codable, Hashable, Sendable {
        let id: String
        let title: String
        let channel: String
        /// "1.2万次观看 · 3天前"、"1615人正在观看"
        let detail: String
        /// "12:34"；直播是 nil
        let length: String?
        let live: Bool
        /// YouTube 自己给的小图（320×180）
        let thumbnail: URL?
    }

    private static let agent = "Mozilla/5.0 (SMART-TV; Linux; Tizen 6.0) AppleWebKit/538.1 (KHTML, like Gecko) Version/6.0 TV Safari/538.1"

    /// nil：没要到（凭证过期、网断了）；空：要到了但没有视频
    static func videos(_ source: YouTubeShelfSource, token: String) async -> [Video]? {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        let language = Locale.preferredLanguages.first ?? "zh-CN"
        let region = Locale.current.region?.identifier ?? "US"
        let body: [String: Any] = ["context": ["client": ["clientName": "TVHTML5", "clientVersion": "7.20251101.10.00",
                                                          "hl": language, "gl": region]],
                                   "browseId": source.browseID]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Log.playback.info("youtube shelf: \(source.rawValue, privacy: .public) answered \(status, privacy: .public)")
            return nil
        }
        return parse(json)
    }

    /// 电视版页面里的一个个"格子"（tileRenderer）：只留视频，去重
    static func parse(_ json: [String: Any]) -> [Video] {
        var found: [Video] = []
        var seen = Set<String>()
        func text(_ value: Any?) -> String {
            guard let object = value as? [String: Any] else { return "" }
            if let simple = object["simpleText"] as? String { return simple }
            return (object["runs"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
        }
        func walk(_ value: Any) {
            if let object = value as? [String: Any] {
                if let tile = object["tileRenderer"] as? [String: Any] { take(tile) }
                for child in object.values { walk(child) }
            } else if let list = value as? [Any] {
                for child in list { walk(child) }
            }
        }
        func take(_ tile: [String: Any]) {
            let kind = tile["contentType"] as? String ?? "", style = tile["style"] as? String ?? ""
            guard kind == "TILE_CONTENT_TYPE_VIDEO", !style.contains("SHORT"),
                  let id = ((tile["onSelectCommand"] as? [String: Any])?["watchEndpoint"] as? [String: Any])?["videoId"] as? String,
                  !id.isEmpty, seen.insert(id).inserted else { return }
            let metadata = (tile["metadata"] as? [String: Any])?["tileMetadataRenderer"] as? [String: Any] ?? [:]
            let lines = (metadata["lines"] as? [[String: Any]] ?? []).map { line in
                ((line["lineRenderer"] as? [String: Any])?["items"] as? [[String: Any]] ?? [])
                    .map { text(($0["lineItemRenderer"] as? [String: Any])?["text"]) }
                    .filter { !$0.isEmpty && $0 != "•" }
                    .joined(separator: " · ")
            }
            let header = (tile["header"] as? [String: Any])?["tileHeaderRenderer"] as? [String: Any] ?? [:]
            let thumbnails = (header["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]] ?? []
            let small = thumbnails.max { ($0["width"] as? Int ?? 0) < ($1["width"] as? Int ?? 0) }?["url"] as? String
            var length: String?
            var live = false
            for case let overlay as [String: Any] in header["thumbnailOverlays"] as? [Any] ?? [] {
                guard let status = overlay["thumbnailOverlayTimeStatusRenderer"] as? [String: Any] else { continue }
                if (status["style"] as? String) == "LIVE" { live = true } else { length = text(status["text"]) }
            }
            found.append(Video(id: id, title: text(metadata["title"]), channel: lines.first ?? "",
                               detail: lines.dropFirst().joined(separator: " · "), length: length?.isEmpty == true ? nil : length,
                               live: live, thumbnail: small.flatMap(URL.init(string:))))
        }
        walk(json)
        return found
    }

    /// 大图：先要 1280 宽的；这个视频没有（老视频、低清的）就用 YouTube 给的那张小的
    static func largeImage(for video: Video) async -> URL? {
        let name = video.live ? "maxresdefault_live.jpg" : "maxresdefault.jpg"
        guard let large = URL(string: "https://i.ytimg.com/vi/\(video.id)/\(name)") else { return video.thumbnail }
        var request = URLRequest(url: large, timeoutInterval: 6)
        request.httpMethod = "HEAD"
        let status = ((try? await URLSession.shared.data(for: request))?.1 as? HTTPURLResponse)?.statusCode
        return status == 200 ? large : video.thumbnail
    }

    // 上一次要到的（凭证过期时主屏顶部先放这些）。每个人（个人资料）各记各的，换了人不会看到上一个人的观看记录
    private static func key(_ source: YouTubeShelfSource, profile: String) -> String { "youtubeShelfSaved.\(profile)." + source.rawValue }
    static func remember(_ videos: [Video], for source: YouTubeShelfSource, profile: String) {
        if let data = try? JSONEncoder().encode(videos) { UserDefaults.standard.set(data, forKey: key(source, profile: profile)) }
    }
    static func remembered(_ source: YouTubeShelfSource, profile: String) -> [Video] {
        UserDefaults.standard.data(forKey: key(source, profile: profile)).flatMap { try? JSONDecoder().decode([Video].self, from: $0) } ?? []
    }
    /// 删掉一个人（个人资料）时，他记着的这几排也删掉
    static func forget(profile: String) {
        for source in YouTubeShelfSource.allCases { UserDefaults.standard.removeObject(forKey: key(source, profile: profile)) }
    }
}

extension TVController {
    /// 主屏顶部 YouTube 那几页（见 AppShelf）
    func youtubeShelfItems() async -> (label: String, items: [AppShelfItem]) {
        let source = YouTubeShelfSource.current
        var videos: [YouTubeFeed.Video]?
        if let token = await YouTubeSignIn.shared.accessToken(store: profile.websiteDataStore) {
            videos = await YouTubeFeed.videos(source, token: token)
        }
        if let videos, !videos.isEmpty { YouTubeFeed.remember(videos, for: source, profile: profile.id) }
        let list = Array(((videos?.isEmpty == false ? videos : nil) ?? YouTubeFeed.remembered(source, profile: profile.id)).prefix(AppShelf.limit))
        let images = await withTaskGroup(of: (String, URL?).self) { group in
            for video in list { group.addTask { (video.id, await YouTubeFeed.largeImage(for: video)) } }
            var all: [String: URL?] = [:]
            for await (id, url) in group { all[id] = url }
            return all
        }
        let items = list.map { video in
            let detail = ([video.live ? "LIVE" : nil, video.detail.isEmpty ? nil : video.detail, video.length] as [String?])
                .compactMap { $0 }.joined(separator: " · ")
            return AppShelfItem(id: "yt-\(video.id)", kind: .youtube(video.id), title: video.title, subtitle: video.channel,
                                detail: detail, image: images[video.id] ?? video.thumbnail,
                                thumbnail: URL(string: "https://i.ytimg.com/vi/\(video.id)/mqdefault.jpg"), avatar: nil)
        }
        return (source.title, items)
    }

    /// 在 YouTube 电视版里直接放这个视频（和手机"发到电视"打开 YouTube 链接是同一条路）
    func openYouTubeVideo(_ id: String) {
        guard let base = services.first(where: { $0.id == "youtube" }) ?? Catalog.services.first(where: { $0.id == "youtube" }),
              let url = YouTubeTV.watch(id) else { return }
        // YouTube kept in the background since Home would come back as it was: the video picked here goes first
        // (the sign-in stays: it's the profile's website data, not the page)
        playbackCoordinator.dropParkedWeb(base.id)
        open(Service(id: base.id, name: base.name, kind: .web(url), icon: base.icon, iconFile: base.iconFile,
                     accent: base.accent, deep: base.deep, userAgent: base.userAgent, dpadNavigation: base.dpadNavigation))
    }
}
