import Foundation

/// 得到（dedao.cn）网页版自己在用的接口：扫码登录、听书的分类和书单、最近学习、我的课程、取音频地址、回报听到哪了。
///
/// - 登录：网页版的扫码登录（得到 App 或微信扫）。登录信息（得到的 cookie）和网易云一样存在这个应用的偏好设置里，只发给 dedao.cn。
/// - 分类和书单（/pc/…）不登录也能看；最近学习、书架、课程（/api/…）要登录。
/// - 音频：得到给的播放地址是普通的 HLS（标准 AES-128），交给系统播放器播，和得到网页版的播放器一样由播放器
///   自己去取钥匙；这里不碰钥匙、不解密、不保存音频。地址一天就过期，所以放之前太久的会重新要一次。
/// - 不做：电子书（要解开电子书内容的加密，电视上也不适合看书）、"免费试听"（会用掉你的试听次数）、
///   人机验证（弹得到的网页你自己做）。
/// 这些接口不是公开给第三方的，得到改版时这里可能要跟着改
enum DedaoAPI {
    static let site = URL(string: "https://www.dedao.cn")!
    private static let agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    // MARK: 请求

    /// 是不是被取消了（换了二维码、离开了得到）：这种不算出错，原样往上交，不说"连不上得到"
    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// 发一个请求：带上得到网页版会带的几个头和 cookie，收下它回的 cookie
    private static func send(_ path: String, method: String = "GET", json: [String: Any]? = nil,
                             headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: path, relativeTo: site)?.absoluteURL else { throw DedaoError.failed("地址不对") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(site.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(site.absoluteString + "/", forHTTPHeaderField: "Referer")
        request.setValue("web", forHTTPHeaderField: "Xi-DT")
        // 发出去时是谁在看：回来时换了人，收到的 cookie 不记、结果不要（见 DedaoCookies）
        let login = DedaoCookies.login
        if let csrf = login.cookies["csrfToken"], !csrf.isEmpty { request.setValue(csrf, forHTTPHeaderField: "Xi-Csrf-Token") }
        let cookie = DedaoCookies.header(login)
        if !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let json {
            request.httpBody = try? JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        } else if method == "POST" {
            // 不带内容的 POST 也要写明长度是 0，不然得到回 411
            request.httpBody = Data()
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            if isCancellation(error) { throw CancellationError() }
            throw DedaoError.offline
        }
        guard let http = response as? HTTPURLResponse else { throw DedaoError.offline }
        DedaoCookies.take(http, from: url, sent: login)
        // 换了人：这是上一个人的，当作取消（不提示出错）。指定了登录信息的（上一个人的回报）照样交回去
        guard DedaoCookies.pinned != nil || DedaoCookies.isCurrent(login) else { throw CancellationError() }
        switch http.statusCode {
        case 401: throw DedaoError.signedOut
        case 496: throw DedaoError.verification
        case 403, 429: throw DedaoError.busy
        case 200..<300: return (data, http)
        default:
            Log.playback.info("dedao: \(url.path, privacy: .public) answered \(http.statusCode, privacy: .public)")
            throw DedaoError.failed("得到出错了（\(http.statusCode)）")
        }
    }

    /// 先像网页一样打开一次首页：拿到 csrfToken 和防火墙的 cookie（每次启动一次）。
    /// 几个请求同时来（首页那几排一起取）时共用同一次，不各自去开
    private static let preparing = Preparing()

    private static func prepare(force: Bool = false) async throws {
        let login = DedaoCookies.login
        try await preparing.wait(force: force, hasToken: login.cookies["csrfToken"].map { !$0.isEmpty } ?? false) {
            var request = URLRequest(url: site)
            request.setValue(agent, forHTTPHeaderField: "User-Agent")
            request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
            let cookie = DedaoCookies.header(login)
            if !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
            let response: URLResponse
            do { (_, response) = try await session.data(for: request) } catch {
                if isCancellation(error) { throw CancellationError() }
                throw DedaoError.offline
            }
            guard let http = response as? HTTPURLResponse else { throw DedaoError.offline }
            DedaoCookies.take(http, from: site, sent: login)
        }
    }

    /// 换了人（个人资料）：之后用他的登录信息；首页要按他的 cookie 重新开一次
    static func useProfile(_ space: ProfileSpace) {
        DedaoCookies.useProfile(space)
        preparing.forget()
    }

    /// 打开首页这一步：正在开的大家一起等它；开过了（而且 csrfToken 还在）就不再开
    private final class Preparing: @unchecked Sendable {
        private let lock = NSLock()
        private var ready = false
        private var running: Task<Void, Error>?

        func wait(force: Bool, hasToken: Bool, open: @escaping @Sendable () async throws -> Void) async throws {
            let task: Task<Void, Error>? = lock.withLock {
                if let running { return running }
                if !force, ready, hasToken { return nil }
                let task = Task { try await open() }
                running = task
                return task
            }
            guard let task else { return }
            do {
                try await task.value
                lock.withLock {
                    if running == task { running = nil }
                    ready = true
                }
            } catch {
                lock.withLock { if running == task { running = nil } }
                throw error
            }
        }

        func reset() { lock.withLock { ready = false } }

        /// 换了人：正在开的那一次是上一个人的，新的请求不跟着它等
        func forget() { lock.withLock { ready = false; running = nil } }
    }

    /// 得到的业务接口：回来的是 {"h":{"c":0,"e":""},"c":{…}}，c 是 0 才算成了，返回里面的 c
    private static func call(_ path: String, _ body: [String: Any]? = nil, get: Bool = false) async throws -> [String: Any] {
        try await prepare()
        let (data, _) = try await send(path, method: get ? "GET" : "POST", json: get ? nil : (body ?? [:]))
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DedaoError.failed("得到没有回应") }
        let head = json["h"] as? [String: Any] ?? [:]
        let code = int(head["c"])
        guard code == 0 else {
            let message = head["e"] as? String ?? ""
            Log.playback.info("dedao: \(path, privacy: .public) code \(code, privacy: .public)")
            // 被别处的登录挤掉、会员过期、风控要你在网页上验证一下，都是这句
            if message.contains("user no legal") { throw DedaoError.signedOut }
            throw DedaoError.failed(message.isEmpty ? "得到出错了（\(code)）" : message)
        }
        return json["c"] as? [String: Any] ?? [:]
    }

    // MARK: 扫码登录

    /// 一张登录二维码（得到 App 或微信扫），大约十分钟有效
    struct LoginCode: Sendable, Equatable {
        let token: String
        let code: String
        /// 二维码图片（PNG）
        let image: Data
    }

    /// rejected：手机上确认了，但得到还是不认这边的登录
    enum LoginState: Sendable { case waiting, done, expired, rejected }

    static func loginCode() async throws -> LoginCode {
        try await prepare(force: true)
        let (tokenData, _) = try await send("/loginapi/getAccessToken", method: "POST")
        let token = String(decoding: tokenData, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\" \n\r\t"))
        guard !token.isEmpty, token.count < 300, !token.contains("<") else { throw DedaoError.failed("拿不到登录二维码") }
        let (data, _) = try await send("/oauth/api/embedded/qrcode", headers: ["X-Oauth-Access-Token": token])
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["data"] as? [String: Any],
              let code = payload["qrCodeString"] as? String,
              let picture = payload["qrCode"] as? String,
              let base64 = picture.split(separator: ",", maxSplits: 1).last,
              let image = Data(base64Encoded: String(base64)) else { throw DedaoError.failed("拿不到登录二维码") }
        return LoginCode(token: token, code: code, image: image)
    }

    /// 扫了没有。扫好并在手机上确认了（status 1）：像网页版一样重新打开一次首页，收下登录的 cookie，
    /// 再问一下"我是谁"——答得上来才算登录好了。被取消时答 waiting（调用的人自己看是不是取消了）
    static func loginState(_ code: LoginCode) async -> LoginState {
        let who = DedaoCookies.login   // 扫码的是这个人：中途换了人，登上的不算到下一个人身上
        let body: [String: Any] = ["keepLogin": true, "pname": "igetoauthpc", "qrCode": code.code, "scene": "registerlogin"]
        let answer: (Data, HTTPURLResponse)
        do {
            answer = try await send("/oauth/api/embedded/qrcode/check_login", method: "POST", json: body,
                                    headers: ["X-Oauth-Access-Token": code.token])
        } catch {
            if !isCancellation(error) { Log.playback.info("dedao: login check failed: \(String(describing: error), privacy: .public)") }
            return .waiting
        }
        guard let json = try? JSONSerialization.jsonObject(with: answer.0) as? [String: Any] else { return .waiting }
        let failure = int(json["errCode"])
        let status = int((json["data"] as? [String: Any])?["status"])
        if failure != 0 || status != 0 {
            Log.playback.info("dedao: login check errCode \(failure, privacy: .public) status \(status, privacy: .public)")
        }
        switch status {
        case 1:
            try? await prepare(force: true)
            if (try? await user()) != nil, DedaoCookies.isCurrent(who) {
                DedaoCookies.markSignedIn(who)
                return .done
            }
            if Task.isCancelled { return .waiting }
            // 只记 cookie 的名字（不记内容），看得到这次给了什么
            Log.playback.info("dedao: scan confirmed but not signed in; cookies: \(DedaoCookies.names, privacy: .public)")
            return .rejected
        case 2: return .expired
        default: return .waiting
        }
    }

    // MARK: 账号

    struct User: Sendable, Equatable {
        let name: String
        let avatar: URL?
        /// "VIP 会员"这样的一句，不是会员是 nil
        let membership: String?
        /// 得到给的用户编号（打乱过的），问"最近学习"要用
        let hazy: String?
    }

    static func user() async throws -> User {
        let c = try await call("/api/pc/user/info", get: true)
        let vip = c["vip_user"] as? [String: Any]
        let stat = int(vip?["stat"])
        return User(name: string(c["nickname"]) ?? "得到用户", avatar: secure(c["avatar"]),
                    membership: stat == 1 ? (string((vip?["info"] as? [String: Any])?["title"]) ?? "得到会员") : nil,
                    hazy: string(c["uid_hazy"]))
    }

    static func signOut() {
        DedaoCookies.clear()
        preparing.reset()
    }

    // MARK: 一样东西（一本书、一套名家讲书、一门课、书架上的一个分组）

    enum Shelf: String, CaseIterable, Sendable {
        case books = "odob", courses = "bauhinia"
        var title: String { self == .books ? "听书" : "课程" }
    }

    /// 首页、分类页卡片上的一样东西：一本书（每天听本书）、一套名家讲书、一门课，或者书架上你自己建的一个分组
    struct Item: Identifiable, Hashable, Sendable {
        enum Kind: Hashable, Sendable { case book, collection, course, folder(Int) }
        let kind: Kind
        let enid: String
        /// 书名（"《人类简史》"），不带后面的"| 某某解读"
        let title: String
        /// 谁解读的、谁讲的
        let author: String
        let intro: String
        let cover: URL?
        /// 听到百分之几（0–100）
        let progress: Int
        let finished: Bool
        /// 一门课有几讲、一套书有几本、一个分组里有几样
        let count: Int
        /// 上次学是什么时候（排"最近学习"用）
        let studied: Int
        let shelf: Shelf
        /// 一本书的音频编号（有它就不用先问一次详情）
        var alias = ""
        /// 评分（"4.9"），没有是空的
        var score = ""
        /// "76万次学习"
        var heat = ""
        /// 多长（秒）
        var duration: Double = 0
        /// 学到哪的一句（"学到第 3 讲"），最近学习里的课程才有
        var note = ""
        /// 什么时候上架的（秒；书单里才有，不知道是 0）
        var published = 0

        var id: String {
            if case .folder(let group) = kind { return "group-\(group)" }
            return enid
        }
    }

    /// 书架：最近学过的在前。group 是分组的编号（打开一个分组时）；一页 30 个，page 从 1 开始
    static func shelf(_ shelf: Shelf, group: Int? = nil, page: Int = 1) async throws -> [Item] {
        let body: [String: Any] = ["category": shelf.rawValue, "display_group": group == nil, "filter": "all",
                                   "group_id": group ?? 0, "order": "study", "filter_complete": 0,
                                   "page": page, "page_size": 30, "sort_type": "desc"]
        let c = try await call(group == nil ? "/api/hades/v2/product/list" : "/api/hades/v2/product/group/list", body)
        return (c["list"] as? [[String: Any]] ?? []).compactMap { item(from: $0, shelf: shelf) }
    }

    static func item(from raw: [String: Any], shelf: Shelf) -> Item? {
        let kind: Item.Kind
        if raw["is_group"] as? Bool == true || int(raw["is_group"]) == 1 {
            kind = .folder(int(raw["group_id"]))
        } else if shelf == .courses {
            kind = .course
        } else {
            kind = int(raw["type"]) == 1013 ? .collection : .book
        }
        let enid = string(raw["enid"]) ?? ""
        if case .folder = kind {} else if enid.isEmpty { return nil }
        let group = raw["odob_group_ext_info"] as? [String: Any]
        let progress = int(group?["progress_percent"] ?? raw["progress"])
        let count = int(raw["publish_num"] ?? raw["course_num"] ?? group?["progress_learned_count"])
        let (title, reader) = splitName(string(raw["title"]) ?? "")
        return Item(kind: kind, enid: enid, title: title, author: string(raw["author"]) ?? reader ?? "",
                    intro: string(raw["intro"]) ?? "", cover: secure(raw["icon"]), progress: percent(progress),
                    finished: raw["is_finished"] as? Bool == true || int(raw["is_finished"]) == 1,
                    count: count, studied: int(raw["last_action_time"] ?? raw["last_read"]), shelf: shelf)
    }

    /// "《人类简史》| 某某解读"拆成书名和解读人（竖线有半角的也有全角的）
    static func splitName(_ name: String) -> (title: String, reader: String?) {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let bar = text.lastIndex(where: { $0 == "|" || $0 == "｜" }) else { return (text, nil) }
        let title = text[..<bar].trimmingCharacters(in: .whitespaces)
        let reader = text[text.index(after: bar)...].trimmingCharacters(in: .whitespaces)
        return (title.isEmpty ? text : title, reader.isEmpty ? nil : reader)
    }

    // MARK: 听书的分类（左边栏）

    /// 网页版"全部分类"里的一项：热门、名家讲书这样的榜单，或者职场发展、自然科学这样的主题（下面再分小类）
    struct Topic: Identifiable, Hashable, Sendable, Codable {
        enum Kind: Sendable { case ranking, package, video, subject }
        struct Label: Hashable, Sendable, Codable {
            let id: String
            let name: String
        }
        let id: String
        let name: String
        /// 小分类（不含"全部"）
        let labels: [Label]

        /// 榜单（ranking:…、pkgGroupType:…）一次就把整张给齐；章鱼书场是视频，这里不放
        var kind: Kind {
            if id.hasPrefix("ranking:") { return .ranking }
            if id.hasPrefix("pkgVideoGroupType:") { return .video }
            if id.hasPrefix("pkgGroupType:") { return .package }
            return .subject
        }
    }

    /// "全部"（全部分类、一个主题下的全部小类）的编号：网页版写死的
    static let everything = "X9vmWzAl54WYrJ78ayq1VjKbDeZRxzpvnpXEBOlvko9L026gdm3AnGNMDkG1x8JR"

    /// 分类取不到时先用这两张榜单（下次打开得到再取）
    static let fallbackTopics: [Topic] = [
        Topic(id: "ranking:JdeKqvNJKmXr9WZyGB2aEOLlvYz6p1aKG12pje3n8Ro1Db05kA7qdMV4xgroWEMN", name: "热门", labels: []),
        Topic(id: "pkgGroupType:3yJdeKqvNJKmXr9WZyGB2aEOLlvYz6p1kPje3n8Ro1Db05kA7qdMV4xgroWEMNL4", name: "名家讲书", labels: []),
    ]

    /// 取到的分类记一份（不涉及账号），下次打开得到时左边栏马上就是全的
    private static let topicsKey = "dedaoTopics"

    static func topics() async throws -> [Topic] {
        let list = topics(from: try await call("/pc/sunflower/v1/label/list", ["label_count": -1, "nav_type": 1]))
        if !list.isEmpty, let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: topicsKey) }
        return list
    }

    /// 上次取到的分类（没有是 nil）
    static func savedTopics() -> [Topic]? {
        guard let data = UserDefaults.standard.data(forKey: topicsKey),
              let list = try? JSONDecoder().decode([Topic].self, from: data), !list.isEmpty else { return nil }
        return list
    }

    static func topics(from c: [String: Any]) -> [Topic] {
        (c["list"] as? [[String: Any]] ?? []).compactMap { raw in
            guard let id = string(raw["enid"]), let name = string(raw["name"]) else { return nil }
            let labels = (raw["label_list"] as? [[String: Any]] ?? []).compactMap { label -> Topic.Label? in
                guard let id = string(label["enid"]), let name = string(label["name"]), id != everything else { return nil }
                return Topic.Label(id: id, name: name)
            }
            return Topic(id: id, name: name, labels: labels)
        }
    }

    // MARK: 一个分类里的书

    enum Sort: String, Sendable { case hot = "HOT", new = "NEW" }

    /// 一页书。往下翻：page 加一，带上这次给的 requestID；more 是 false 就到头了
    struct ProductPage: Sendable {
        let items: [Item]
        let requestID: String
        let more: Bool
        let total: Int
    }

    /// 一个分类（topic、name 是左边栏那一项）、一个小类（label，"全部"是 everything）里的听书和名家讲书
    static func products(topic: String, name: String, label: String = everything, sort: Sort = .hot,
                         page: Int = 0, size: Int = 18, requestID: String = "") async throws -> ProductPage {
        let body: [String: Any] = ["classfc_name": name, "navigation_id": topic, "label_id": label, "nav_type": 0,
                                   "page": page, "page_size": size, "product_types": "13,1013",
                                   "sort_strategy": sort.rawValue, "request_id": requestID, "tags_ids": [String]()]
        return productPage(from: try await call("/pc/label/v2/algo/pc/product/list", body))
    }

    static func productPage(from c: [String: Any]) -> ProductPage {
        ProductPage(items: (c["product_list"] as? [[String: Any]] ?? []).compactMap(product(from:)),
                    requestID: string(c["request_id"]) ?? "", more: int(c["is_more"]) != 0, total: int(c["total"]))
    }

    /// 书单里的一项（13 听书、1013 名家讲书、66 课程；电子书这些不要）
    static func product(from raw: [String: Any]) -> Item? {
        let type = int(raw["product_type"])
        guard let kind = kind(type), let enid = string(raw["id_out"] ?? raw["product_enid"] ?? raw["enid"]) else { return nil }
        let (title, reader) = splitName(string(raw["name"] ?? raw["title"]) ?? "")
        let article = raw["article_info"] as? [String: Any]
        let score = string(raw["score"]) ?? ""
        return Item(kind: kind, enid: enid, title: title,
                    author: reader ?? string(raw["lecturer_name_and_title"]) ?? string(raw["lecturer_name"]) ?? "",
                    intro: string(raw["intro"]) ?? "", cover: secure(raw["index_img"] ?? raw["index_image"]),
                    progress: percent(int(raw["progress"])),
                    finished: int(raw["is_finish"] ?? raw["is_finished"] ?? raw["learn_finished"]) == 1,
                    count: int(type == 66 ? raw["phase_num"] : raw["lessons_num"]), studied: 0,
                    shelf: type == 66 ? .courses : .books,
                    alias: type == 13 ? (string(raw["alias_id"] ?? raw["audio_id"]) ?? "") : "",
                    score: double(score) > 0 ? score : "", heat: string(raw["hot_learn_desc"]) ?? "",
                    duration: double(article?["article_audio_duration"] ?? raw["duration"]),
                    published: publishedAt(raw))
    }

    /// 上架时间：书单里没有单独的字段，排序用的 sort_values 第三个是上架的那一刻（毫秒；最热、最新排序都是）。
    /// 看着不像时间的不要
    static func publishedAt(_ raw: [String: Any]) -> Int {
        guard let values = raw["sort_values"] as? [Any], values.count > 2 else { return 0 }
        let milliseconds = double(values[2])
        // 2015 年以后、2100 年以前的毫秒数才算
        guard milliseconds > 1_420_000_000_000, milliseconds < 4_100_000_000_000 else { return 0 }
        return Int(milliseconds / 1000)
    }

    private static func kind(_ productType: Int) -> Item.Kind? {
        switch productType {
        case 13: .book
        case 1013: .collection
        case 66: .course
        default: nil
        }
    }

    // MARK: 最近学习（我的学习记录，手机上学的也在）

    /// 一页最近学过的，最新的在前。往下翻：带上这次给的 cursor；more 是 false 就到头了
    struct RecentPage: Sendable {
        let items: [Item]
        let cursor: Int
        let more: Bool
    }

    static func recent(user hazy: String, after cursor: Int = 0) async throws -> RecentPage {
        let body: [String: Any] = ["filter_product_type": true, "max_id": cursor, "page_size": 20, "product_type": "",
                                   "uid": NSNull(), "uid_hazy": hazy]
        return recentPage(from: try await call("/api/pc/blade/v2/recent", body))
    }

    static func recentPage(from c: [String: Any]) -> RecentPage {
        let items = (c["list"] as? [[String: Any]] ?? []).compactMap(recentItem(from:))
        return RecentPage(items: items, cursor: int(c["timestamp"]), more: int(c["has_more"]) != 0 && !items.isEmpty)
    }

    /// 最近学习里的一项。进度先看音频的（听到百分之几、听完没有），没有再看"学到哪了"那一句
    static func recentItem(from raw: [String: Any]) -> Item? {
        let type = int(raw["product_type"])
        guard let kind = kind(type), let enid = string(raw["product_id_hazy"] ?? raw["product_enid"] ?? raw["enid"]) else { return nil }
        let resource = raw["resource"] as? [String: Any]
        let audio = resource?["audio"] as? [String: Any]
        let intro = raw["progress_intro"] as? [String: Any]
        var progress = 0
        var finished = intro?["is_finish"] as? Bool == true || int(intro?["is_finish"]) == 1
        if let audio, audio["listen_progress"] != nil || audio["listen_finished"] != nil {
            progress = percent(Int(double(audio["listen_progress"]).rounded()))
            finished = finished || audio["listen_finished"] as? Bool == true || int(audio["listen_finished"]) == 1
        } else if double(intro?["max_progress"]) > 0 {
            progress = percent(Int((double(intro?["progress"]) / double(intro?["max_progress"]) * 100).rounded()))
        }
        let (title, reader) = splitName(string(raw["title"]) ?? "")
        return Item(kind: kind, enid: enid, title: title, author: string(raw["author"]) ?? reader ?? "",
                    intro: string(raw["intro"]) ?? "",
                    cover: secure(raw["index_img"] ?? raw["square_img"] ?? raw["logo"]),
                    progress: finished ? 100 : progress, finished: finished, count: 0, studied: int(raw["timestamp"]),
                    shelf: type == 66 ? .courses : .books,
                    alias: type == 13 ? (string(audio?["alias_id"] ?? resource?["audio_id"]) ?? "") : "",
                    duration: double(audio?["duration"]), note: string(intro?["intro"]) ?? "")
    }

    // MARK: 音频

    /// 能放的一段音频：一本书的解读、合集里的一本、课程的一讲
    struct Track: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        /// 谁讲的
        let reader: String
        let cover: URL?
        /// 秒
        let duration: Double
        /// 上次听到百分之几（得到记的，手机上听的也算）
        let progress: Double
        let finished: Bool
        let address: URL?
        /// 什么时候要到的这个地址（地址一天就过期）
        let fetched: Date
        // 回报进度要用的
        let productEnid: String
        /// 13 听书，66 课程
        let productType: Int
        let itemEnid: String
        let aliasID: String
        /// 课程里这一讲的编号（往下翻页用）
        let articleID: Int
        /// 一句话介绍（没有文稿时播放界面右边放它）
        var summary = ""

        var playable: Bool { address != nil }
        /// 从哪接着听：听完了的从头来
        var resumeAt: Double { finished || progress >= 98 ? 0 : duration * progress / 100 }
    }

    /// 一本书（每天听本书）：先要它的音频编号，再要这段音频
    static func book(_ enid: String, cover: URL? = nil) async throws -> Track {
        let query = enid.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? enid
        let c = try await call("/pc/odob/pc/audio/detail?topic_id_str=\(query)", get: true)
        let detail = c["detail"] as? [String: Any] ?? c
        guard let alias = string(detail["audio_id"] ?? detail["alias_id"]) else { throw DedaoError.failed("这本书没有音频") }
        return try await bookAudio(alias: alias, itemEnid: enid, cover: cover)
    }

    static func bookAudio(alias: String, itemEnid: String, cover: URL? = nil) async throws -> Track {
        let c = try await call("/pc/odob/pc/audio/detail/alias", ["alias_id": alias])
        guard var audio = c["audio_detail"] as? [String: Any] else { throw DedaoError.failed("这本书没有音频") }
        // 有时回来的音频编号是空的：用问的那个（回报听到哪了、取文稿都要它）
        if string(audio["alias_id"]) == nil { audio["alias_id"] = alias }
        return track(audio, title: nil, productEnid: string(audio["class_enid"]) ?? itemEnid, productType: 13,
                     itemEnid: itemEnid, cover: cover)
    }

    /// 一套名家讲书里的每一本
    static func collection(_ enid: String, cover: URL? = nil) async throws -> [Track] {
        let c = try await call("/pc/sunflower/v1/depot/vip-user/topic-pkg/odob/details", ["enid": enid])
        return (c["odob_audio_detail_list"] as? [[String: Any]] ?? []).map { audio in
            let topic = string(audio["topic_encode_id"]) ?? enid
            return track(audio, title: nil, productEnid: string(audio["class_enid"]) ?? topic, productType: 13,
                         itemEnid: topic, cover: cover)
        }
    }

    struct Course: Sendable, Equatable {
        let title: String
        let lecturer: String
        let cover: URL?
        let intro: String
        /// 一共几讲（得到没给时是 0）
        let lectures: Int
    }

    static func course(_ enid: String) async throws -> Course {
        let c = try await call("/pc/bauhinia/pc/class/info", ["detail_id": enid, "is_login": 1])
        let info = c["class_info"] as? [String: Any] ?? [:]
        return Course(title: string(info["name"]) ?? "", lecturer: string(info["lecturer_name"]) ?? "",
                      cover: secure(info["logo"] ?? info["index_img"]), intro: string(info["intro"]) ?? "",
                      lectures: int(info["publish_num"]))
    }

    /// 一页有几讲
    static let lecturesPerPage = 30

    /// 一门课的讲（一次 30 讲）：after 是上一页最后一讲的编号，第一页传 0
    static func lectures(_ enid: String, after: Int = 0, cover: URL? = nil) async throws -> [Track] {
        let body: [String: Any] = ["chapter_id": "", "count": lecturesPerPage, "detail_id": enid, "include_edge": false,
                                   "is_unlearn": false, "max_id": after, "max_order_num": 0, "reverse": false,
                                   "since_id": 0, "since_order_num": 0, "unlearn_switch": false]
        let c = try await call("/api/pc/bauhinia/pc/class/purchase/article_list", body)
        return (c["article_list"] as? [[String: Any]] ?? []).map { article in
            let audio = article["audio"] as? [String: Any] ?? [:]
            return track(audio, title: string(article["title"]), productEnid: string(article["class_enid"]) ?? enid,
                         productType: 66, itemEnid: string(article["enid"]) ?? "", cover: cover,
                         articleID: int(article["id"]))
        }
    }

    /// 放之前：地址要到超过半天了就重新要一次（地址一天就过期）
    static func fresh(_ track: Track) async -> Track {
        guard Date().timeIntervalSince(track.fetched) > 12 * 3600 else { return track }
        if track.productType == 13, !track.aliasID.isEmpty,
           let again = try? await bookAudio(alias: track.aliasID, itemEnid: track.itemEnid, cover: track.cover) { return again }
        if track.productType == 66, !track.itemEnid.isEmpty,
           let c = try? await call("/pc/bauhinia/pc/article/info", ["detail_id": track.itemEnid]),
           let audio = (c["audio"] as? [String: Any]) ?? ((c["article_info"] as? [String: Any])?["audio"] as? [String: Any]) {
            return self.track(audio, title: track.title, productEnid: track.productEnid, productType: 66,
                              itemEnid: track.itemEnid, cover: track.cover, articleID: track.articleID)
        }
        return track
    }

    static func track(_ audio: [String: Any], title: String?, productEnid: String, productType: Int, itemEnid: String,
                      cover: URL?, articleID: Int = 0) -> Track {
        let alias = string(audio["alias_id"]) ?? ""
        let address = (audio["mp3_play_url"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
            .flatMap { $0.scheme == "https" || $0.scheme == "http" ? $0 : nil }
        return Track(id: alias.isEmpty ? itemEnid : alias,
                     title: title ?? string(audio["title"]) ?? "",
                     reader: string(audio["reader_name"] ?? audio["reader"]) ?? "",
                     cover: secure(audio["index_img"] ?? audio["icon"]) ?? cover,
                     duration: double(audio["duration"]), progress: double(audio["listen_progress"]),
                     finished: audio["listen_finished"] as? Bool == true, address: address, fetched: Date(),
                     productEnid: productEnid, productType: productType, itemEnid: itemEnid, aliasID: alias,
                     articleID: articleID, summary: string(audio["summary"] ?? audio["share_summary"]) ?? "")
    }

    // MARK: 文稿（听书的解读稿、课程一讲的文字）
    //
    // 和网页版一样两步：先拿这一讲 / 这本书的文稿凭证（article/info），再拿文稿（ddarticle）。
    // 文稿是一段段的（标题、正文、引用、划重点、图片），不带每段的时间，所以跟读是按字数估算的。
    // 只取文稿，不碰电子书

    /// 网页版取文稿时带的应用编号
    private static let articleApp = "1632426125495894021"

    /// 一篇文稿：一段一段的字，加上没有文稿时放的一句介绍
    struct Transcript: Sendable, Equatable {
        struct Paragraph: Sendable, Equatable, Identifiable {
            enum Kind: Sendable, Equatable { case header, text, quote, point }
            /// 一小段字；marked = 得到划了线的重点句（加粗、高亮）
            struct Run: Sendable, Equatable {
                let text: String
                let marked: Bool
            }
            let id: Int
            let kind: Kind
            let runs: [Run]
            /// 这一段从全文第几个字开始（估算念到哪用）
            let start: Int
            var text: String { runs.map(\.text).joined() }
        }
        let paragraphs: [Paragraph]
        /// 一共多少字（不算空白）
        let characters: Int
        var summary = ""

        /// 每秒念几个字以下，就当文稿不全（没买时只给开头一段）；念到哪按正常语速估
        static let partialRate = 3.0
        static let speechRate = 4.3

        /// 文稿比音频短很多（只给了开头）
        func partial(duration: Double) -> Bool {
            duration > 0 && Double(characters) / duration < Self.partialRate
        }

        /// 放到 time 秒时大概念到第几段：字数和时长成比例（语速很平），文稿不全时按正常语速往下数
        func paragraph(at time: Double, duration: Double) -> Int {
            guard !paragraphs.isEmpty, duration > 0, characters > 0, time > 0 else { return 0 }
            let position = partial(duration: duration) ? time * Self.speechRate : time / duration * Double(characters)
            return max(0, (paragraphs.lastIndex { Double($0.start) <= position }) ?? 0)
        }

        /// 第几段大概从第几秒开始念（点一段跳过去）
        func time(of index: Int, duration: Double) -> Double {
            guard paragraphs.indices.contains(index), duration > 0, characters > 0 else { return 0 }
            let start = Double(paragraphs[index].start)
            return partial(duration: duration) ? start / Self.speechRate : start / Double(characters) * duration
        }
    }

    /// 这一讲 / 这本书的文稿。没有（没买、只有音频）时段落是空的
    static func transcript(for track: Track, userName: String?) async throws -> Transcript {
        let body: [String: Any]
        if track.productType == 66, !track.itemEnid.isEmpty {
            body = ["detail_id": track.itemEnid]
        } else if !track.aliasID.isEmpty {
            body = ["audio_alias_id": track.aliasID]
        } else {
            return Transcript(paragraphs: [], characters: 0, summary: track.summary)
        }
        let info = try await call("/pc/bauhinia/pc/article/info", body)
        let summary = string((info["audio"] as? [String: Any])?["summary"])
            ?? string((info["article_info"] as? [String: Any])?["share_content"]) ?? track.summary
        guard let token = string(info["dd_article_token"]) else { return Transcript(paragraphs: [], characters: 0, summary: summary) }
        let encoded = token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? token
        let c = try await call("/pc/ddarticle/v1/article/get/v2?token=\(encoded)&appid=\(articleApp)&is_new=1", get: true)
        var parsed = transcript(fromContent: c["content"] as? String ?? "", userName: userName)
        parsed.summary = summary
        return parsed
    }

    /// 文稿的内容（一个 JSON 数组的字符串）读成一段一段：标题、正文、引用、列表、划重点、开头的问候；
    /// 图片、音频卡片这些不要
    static func transcript(fromContent content: String, userName: String?) -> Transcript {
        guard let blocks = (try? JSONSerialization.jsonObject(with: Data(content.utf8))) as? [[String: Any]] else {
            return Transcript(paragraphs: [], characters: 0)
        }
        var paragraphs: [Transcript.Paragraph] = []
        var count = 0
        func add(_ kind: Transcript.Paragraph.Kind, _ runs: [Transcript.Paragraph.Run]) {
            // 每段前后的空白、换行去掉；整段是空的不要
            var runs = runs.filter { !$0.text.isEmpty }
            guard !runs.isEmpty else { return }
            runs[0] = .init(text: String(runs[0].text.drop { $0.isWhitespace }), marked: runs[0].marked)
            let last = runs.count - 1
            runs[last] = .init(text: String(runs[last].text.reversed().drop { $0.isWhitespace }.reversed()), marked: runs[last].marked)
            runs = runs.filter { !$0.text.isEmpty }
            let length = runs.reduce(0) { $0 + $1.text.filter { !$0.isWhitespace }.count }
            guard length > 0 else { return }
            paragraphs.append(.init(id: paragraphs.count, kind: kind, runs: runs, start: count))
            count += length
        }
        /// 一段里的几小段字（contents 里 type 是 text 的）；没有就用整段的 text
        func runs(_ block: [String: Any]) -> [Transcript.Paragraph.Run] {
            let pieces = (block["contents"] as? [[String: Any]] ?? []).compactMap { piece -> Transcript.Paragraph.Run? in
                guard (piece["type"] as? String ?? "text") == "text", let text = piece["text"] as? [String: Any],
                      let words = text["content"] as? String else { return nil }
                return .init(text: words, marked: text["highlight"] as? Bool == true || text["bold"] as? Bool == true)
            }
            if !pieces.isEmpty { return pieces }
            return [.init(text: block["text"] as? String ?? "", marked: false)]
        }
        for block in blocks {
            switch block["type"] as? String {
            case "header": add(.header, [.init(text: block["text"] as? String ?? "", marked: false)])
            case "paragraph": add(.text, runs(block))
            case "blockquote": add(.quote, [.init(text: block["text"] as? String ?? "", marked: false)])
            case "elite": add(.point, [.init(text: block["text"] as? String ?? "", marked: true)])
            case "list":
                // 列表：每一项一段，前面加个点
                for item in block["contents"] as? [[[String: Any]]] ?? [] {
                    var line = runs(["contents": item])
                    if !line.isEmpty { line.insert(.init(text: "· ", marked: false), at: 0) }
                    add(.text, line)
                }
            case "salutation":
                // "$_IGET_USER_NAME_$,你好"：换成你的名字（不知道名字就只说"你好"）
                let text = (block["text"] as? String ?? "").replacingOccurrences(
                    of: "$_IGET_USER_NAME_$,", with: userName.map { "\($0)，" } ?? "")
                    .replacingOccurrences(of: "$_IGET_USER_NAME_$", with: userName ?? "")
                add(.text, [.init(text: text, marked: false)])
            default: break
            }
        }
        return Transcript(paragraphs: paragraphs, characters: count)
    }

    // MARK: 回报听到哪了（得到网页版的播放器发的是同样的三种）

    enum Report: String, Sendable { case rpoint, behavior, time }

    /// json：要报的几条（数组），先编好再交过来
    static func report(_ kind: Report, _ track: Track, json: Data) async {
        guard DedaoCookies.signedIn,
              let entries = (try? JSONSerialization.jsonObject(with: json)) as? [[String: Any]], !entries.isEmpty else { return }
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let resource: [String: Any] = ["product_id_encode": track.productEnid, "product_type": track.productType,
                                       "main_item_id_encode": track.itemEnid, "base_item_type": "audio",
                                       "base_item_id_encode": track.aliasID]
        let body: [String: Any] = ["os": "H5", "platform": 6, "send_time": now,
                                   "data": entries.map { ["resource": resource, kind.rawValue: $0] }]
        do { _ = try await send("/prime/v1/producer/\(kind.rawValue)/report", method: "POST", json: body) }
        catch { Log.playback.info("dedao: \(kind.rawValue, privacy: .public) report failed") }
    }

    // MARK: 读 JSON 的小工具（数字有时是字符串）

    static func int(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) ?? Int(Double(text) ?? 0) }
        return 0
    }
    static func double(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) ?? 0 }
        return 0
    }
    static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text.isEmpty ? nil : text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
    /// 百分比：超出 0–100 的按两头算
    static func percent(_ value: Int) -> Int { min(100, max(0, value)) }
    /// 图片地址：补上 https
    static func secure(_ value: Any?) -> URL? {
        guard var text = value as? String, !text.isEmpty else { return nil }
        if text.hasPrefix("//") { text = "https:" + text }
        text = text.replacingOccurrences(of: "http://", with: "https://")
        return URL(string: text)
    }
}

enum DedaoError: Error, Equatable {
    case offline, signedOut, verification, busy
    case failed(String)

    var message: String {
        switch self {
        case .offline: "无法连接得到，请检查网络"
        case .signedOut: "得到登录已过期，请重新扫码"
        case .verification: "请先在得到网页上完成验证"
        case .busy: "请求过于频繁，请稍后再试"
        case .failed(let text): text
        }
    }
}

/// 得到的登录信息（cookie）：和网易云的一样（NeteaseAPI 的 jar），记在内存里，并存进这个应用自己的偏好设置，
/// 只发给 dedao.cn。退出登录时删掉。
/// 每个人（个人资料）一份，在他自己的设置里（第一个人还是原来的地方，见 ProfileSpace）。每个请求带着发出去时那个人的
/// 登录信息：回来时已经换了人，回来的 cookie 不记，结果也不要
enum DedaoCookies {
    static let storeKey = "dedaoLogin"
    /// 自己记的一个标记（不发给得到）：扫码后问过"我是谁"、答上来了
    private static let marker = "__mactv_signed_in"
    /// 防火墙的 cookie 一直在换，不用存
    private static let passing: Set<String> = ["acw_tc", "aliyungf_tc", "acw_sc__v2", "ssxmod_itna", "ssxmod_itna2"]

    /// 一个人的登录信息，和它属于哪一次换人以后（ProfileSpace.epoch）
    struct Login: Sendable {
        var cookies: [String: String]
        var epoch: Int
    }

    private struct Jar {
        var cookies: [String: String]
        let epoch: Int
        let defaults: UserDefaults
        init(_ space: ProfileSpace) {
            defaults = space.defaults
            epoch = space.epoch
            cookies = space.defaults.dictionary(forKey: DedaoCookies.storeKey) as? [String: String] ?? [:]
        }
    }

    /// 内存里的和存下来的都在这把锁里改（几个请求同时回来时，不会存进一份半新半旧的）
    private static let lock = NSLock()
    nonisolated(unsafe) private static var jar = Jar(ProfileSpace.current)
    /// 这个任务里的请求用这一份登录信息、不用现在在看的人的：换人时上一个人还没报完的"听到哪了"用他自己的
    @TaskLocal static var pinned: Login?

    /// 换了人（个人资料）：之后的请求用他的登录信息
    static func useProfile(_ space: ProfileSpace) {
        lock.withLock { jar = Jar(space) }
    }

    /// 现在的登录信息（任务里指定了一份就是那一份）
    static var login: Login {
        if let pinned { return pinned }
        return lock.withLock { Login(cookies: jar.cookies, epoch: jar.epoch) }
    }

    /// 这份登录信息的人还在看
    static func isCurrent(_ login: Login) -> Bool { lock.withLock { jar.epoch == login.epoch } }

    /// 登录过：扫码后问过"我是谁"答上来了（标记），或者有得到自己的登录 cookie（GAT，之前的版本存的就是这样）
    static var signedIn: Bool { value(marker) != nil || value("GAT") != nil }

    /// 现在有哪些 cookie（只有名字，记日志用）
    static var names: String {
        login.cookies.keys.filter { $0 != marker }.sorted().joined(separator: ",")
    }

    /// 扫码登录好了：记下标记，连同现在的 cookie 一起存下来（扫码的时候换了人就不算）
    static func markSignedIn(_ sent: Login) {
        lock.withLock {
            guard jar.epoch == sent.epoch else { return }
            jar.cookies[marker] = "1"
            save(jar.cookies.filter { !passing.contains($0.key) })
        }
    }

    static func value(_ name: String) -> String? {
        login.cookies[name].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// 发给 dedao.cn 的 Cookie 头（网页版还会自己写一个 token = csrfToken）
    static func header(_ login: Login) -> String {
        var all = login.cookies.filter { !$0.key.hasPrefix("__") }
        if all["token"] == nil, let csrf = all["csrfToken"] { all["token"] = csrf }
        return all.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    /// 收下回应里的 Set-Cookie；登录相关的变了才存。发出去以后换了人：是上一个人的，不记
    static func take(_ response: HTTPURLResponse, from url: URL, sent: Login) {
        let fields = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        guard !cookies.isEmpty else { return }
        lock.withLock {
            guard jar.epoch == sent.epoch else { return }
            let before = jar.cookies.filter { !passing.contains($0.key) }
            for cookie in cookies {
                let expired = cookie.expiresDate.map { $0 < Date() } ?? false
                jar.cookies[cookie.name] = expired || cookie.value.isEmpty ? nil : cookie.value
            }
            let after = jar.cookies.filter { !passing.contains($0.key) }
            if before != after, after[marker] != nil || after["GAT"] != nil { save(after) }
        }
    }

    /// 退出登录（现在在看的这个人的）
    static func clear() {
        lock.withLock {
            jar.cookies = [:]
            jar.defaults.removeObject(forKey: storeKey)
        }
    }

    /// 只在锁里调
    private static func save(_ cookies: [String: String]) {
        jar.defaults.set(cookies, forKey: storeKey)
    }
}
