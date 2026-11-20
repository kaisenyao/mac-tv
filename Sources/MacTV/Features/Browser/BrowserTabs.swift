import AppKit
import ImageIO

/// 一个标签页。只有正在看的那一个有网页视图（一个网页的进程要一两百兆，多的近一个 G），
/// 别的只记着地址、标题和一张截图，换过去时重新载入（同一次运行里连前进后退、滚到哪一起恢复，见 BrowserStore）
struct BrowserTab: Codable, Identifiable, Equatable, Sendable {
    var id = UUID().uuidString
    var url: URL
    var title: String
    /// 无痕标签页：从来不存（不在 CodingKeys 里）
    var isPrivate = false

    private enum CodingKeys: String, CodingKey { case id, url, title }

    var page: WebPage { WebPage(url: url, title: title) }
}

/// 标签页记在哪：列表（地址、标题）在 UserDefaults，几百字节；截图是缓存文件夹里的 JPEG，一张一百 KB 上下。
/// 下次打开浏览器标签页还在（无痕的不存）。看过的页面、每个网站的缩放也在这里。
/// 每个人（个人资料）一份：第一个人是原来的地方（.standard），别的人在他自己的设置、缓存文件夹里（见 ProfileSpace）
struct BrowserTabStorage: Sendable {
    /// 测试用自己的一份 UserDefaults 和文件夹，不碰真的
    var suite: String?
    var folder: URL

    static let standard = BrowserTabStorage(suite: nil, folder: BrowserCache.folder("Browser Tabs"))

    /// 第一个人以外的人的那一份
    static func forProfile(_ space: ProfileSpace) -> BrowserTabStorage {
        BrowserTabStorage(suite: space.suiteName, folder: space.caches.appendingPathComponent("Browser Tabs", isDirectory: true))
    }

    var defaults: UserDefaults { suite.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    private static let tabsKey = "browserTabs", activeKey = "browserActiveTab", zoomKey = "browserZoom", historyKey = "browserHistory"

    // MARK: 在 Mac TV 里看过的页面（最多一百条，最新的在前）。无痕标签页的不记

    var history: [WebPage] {
        defaults.data(forKey: Self.historyKey).flatMap { try? JSONDecoder().decode([WebPage].self, from: $0) } ?? []
    }

    func addHistory(_ url: URL, title: String) {
        var pages = history.filter { $0.url != url }
        pages.insert(WebPage(url: url, title: title, visited: Date()), at: 0)
        if let data = try? JSONEncoder().encode(Array(pages.prefix(100))) { defaults.set(data, forKey: Self.historyKey) }
    }

    func load() -> (tabs: [BrowserTab], active: String?) {
        let tabs = defaults.data(forKey: Self.tabsKey).flatMap { try? JSONDecoder().decode([BrowserTab].self, from: $0) } ?? []
        let active = defaults.string(forKey: Self.activeKey)
        return (tabs, tabs.contains { $0.id == active } ? active : tabs.last?.id)
    }

    func save(_ tabs: [BrowserTab], active: String?) {
        if let data = try? JSONEncoder().encode(tabs) { defaults.set(data, forKey: Self.tabsKey) }
        defaults.set(active, forKey: Self.activeKey)
    }

    func snapshotFile(_ id: String) -> URL { folder.appendingPathComponent(id + ".jpg") }

    func loadSnapshot(_ id: String) -> NSImage? {
        let file = snapshotFile(id)
        return FileManager.default.fileExists(atPath: file.path) ? NSImage(contentsOf: file) : nil
    }

    func removeSnapshot(_ id: String) { try? FileManager.default.removeItem(at: snapshotFile(id)) }

    // MARK: 每个网站的缩放

    /// 这个网站上次调成多少（没调过是 nil，用默认的）
    func zoom(for host: String) -> Double? {
        (defaults.dictionary(forKey: Self.zoomKey)?[BrowserZoom.key(host)] as? Double).map(BrowserZoom.clamp)
    }

    /// nil：回到默认，不再记
    func setZoom(_ zoom: Double?, for host: String) {
        var all = defaults.dictionary(forKey: Self.zoomKey) ?? [:]
        all[BrowserZoom.key(host)] = zoom
        if all.count > 300 { all.removeValue(forKey: all.keys.sorted().first ?? "") }
        defaults.set(all, forKey: Self.zoomKey)
    }
}

/// 浏览器的缓存（网站图标、标签页截图）放哪：平时在 ~/Library/Caches/Mac TV 下面；
/// 设了 MACTV_DATA_DIR（开发、测试时用，和 AppFolder 一样）就放在那个文件夹里，不碰真的
enum BrowserCache {
    /// ~/Library/Caches/Mac TV: the first profile's caches; the other profiles' are in Profiles/<id> (see ProfileSpace)
    static var root: URL {
        if let path = ProcessInfo.processInfo.environment["MACTV_DATA_DIR"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("Caches", isDirectory: true)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mac TV", isDirectory: true)
    }

    static func folder(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }
}

/// 网页缩放（WKWebView.pageZoom，和 Safari 的"放大"一样：文字、图片一起变大，版式重排，不是把画面拉大）。
/// 现在只有三档（BrowserZoomLevel）；这里是记下来的缩放怎么读、按网站怎么记
enum BrowserZoom {
    /// 以前（三档之前）电视上的默认缩放：让网页以为窗口大约 1280 宽。1920 宽的电视画面是 150%，1600 宽是 125%。
    /// 只用来认出以前记下的"默认"（BrowserZoomLevel.level 把它当成"中"）
    static func standard(forWidth width: CGFloat) -> Double {
        guard width > 0 else { return 1.5 }
        return clamp(max(1, (Double(width) / 1280 * 20).rounded() / 20))
    }

    /// 以前能调的范围：75% 到 300%
    static func clamp(_ zoom: Double) -> Double { min(3, max(0.75, zoom)) }

    /// 按网站记（www.apple.com 和 apple.com 算一个）
    static func key(_ host: String) -> String {
        let host = host.lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// 标签页离开时的截图：换回来、网页还没画出来时铺在网页的位置上（占满屏幕，所以不能太小）。
/// 缩成 960 像素宽（内存里一张两兆左右，只留最近四张），存成 JPEG
enum BrowserSnapshots {
    static let width = 960

    struct Picture: @unchecked Sendable { let image: CGImage }

    static func shrink(_ image: CGImage) -> Picture? {
        let height = max(1, Int((Double(image.height) * Double(width) / Double(max(1, image.width))).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage().map(Picture.init)
    }

    static func write(_ picture: Picture, to file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, picture.image, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }
}

/// "最近浏览"卡片上的时间：英文（浏览器是系统的界面，跟系统语言走）。"Just now"、"5 min. ago"、"Yesterday"，一个星期以前的写日期
@MainActor
enum BrowserTime {
    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        return formatter
    }()
    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Just now" }
        guard seconds < 7 * 86400 else { return day.string(from: date) }
        let text = relative.localizedString(for: date, relativeTo: now)
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}
