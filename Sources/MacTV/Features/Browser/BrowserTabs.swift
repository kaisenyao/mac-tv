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
/// 下次打开浏览器标签页还在（无痕的不存）
struct BrowserTabStorage: Sendable {
    /// 测试用自己的一份 UserDefaults 和文件夹，不碰真的
    var suite: String?
    var folder: URL

    static let standard = BrowserTabStorage(suite: nil, folder: BrowserCache.folder("Browser Tabs"))

    var defaults: UserDefaults { suite.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    private static let tabsKey = "browserTabs", activeKey = "browserActiveTab", zoomKey = "browserZoom"

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
    static func folder(_ name: String) -> URL {
        if let path = ProcessInfo.processInfo.environment["MACTV_DATA_DIR"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("Caches/\(name)", isDirectory: true)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mac TV/\(name)", isDirectory: true)
    }
}

/// 网页缩放（WKWebView.pageZoom，和 Safari 的"放大"一样：文字、图片一起变大，版式重排，不是把画面拉大）
enum BrowserZoom {
    static let steps: [Double] = [0.75, 0.85, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    /// 电视上的默认缩放：让网页以为窗口大约 1280 宽（笔记本上最常见的版式，字和按钮在沙发上看得清）。
    /// 1920 宽的电视画面是 150%，1600 宽是 125%，窗口小到 1280 以下就不放大
    static func standard(forWidth width: CGFloat) -> Double {
        guard width > 0 else { return 1.5 }
        return clamp(max(1, (Double(width) / 1280 * 20).rounded() / 20))
    }

    static func clamp(_ zoom: Double) -> Double { min(steps.last!, max(steps.first!, zoom)) }

    /// 放大 / 缩小一档
    static func step(from zoom: Double, larger: Bool) -> Double {
        larger ? steps.first { $0 > zoom + 0.001 } ?? steps.last!
               : steps.last { $0 < zoom - 0.001 } ?? steps.first!
    }

    static func percent(_ zoom: Double) -> String { "\(Int((zoom * 100).rounded()))%" }

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
