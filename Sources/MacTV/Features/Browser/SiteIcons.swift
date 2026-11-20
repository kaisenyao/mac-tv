import AppKit
import ImageIO
import SwiftUI

/// 一个网站的图标：解码好的小图（最长边不超过 256 像素）和画的时候要用的两件事
struct SiteIcon: @unchecked Sendable {
    let image: CGImage
    /// 短边多少像素（小图标放到大方块上会糊，大方块要求至少 64）
    let pixels: Int
    /// 四个角都不透明：是一张自带底色的方图标，铺满整块；透明底的放在中间、垫一层底色
    let opaque: Bool
    /// 透明底的图标本身是浅色的（白色的标志）：垫深色的底，不然看不见
    let light: Bool
}

/// 网站图标（开始页的方块、卡片上的小图标、工具栏和标签页上的小图标）。
///
/// 只向那个网站自己要，不经过第三方（不把你去过哪些网站告诉别人），不带 Cookie。先读网站首页里声明的图标，
/// 按好坏排：apple-touch-icon（一般 180 像素）、写了尺寸的大图标、SVG 图标、manifest 里的图标，
/// 再试常见的位置（/apple-touch-icon.png），最后才是小的 favicon。找到的存进缓存文件夹，一个网站只找一次；
/// 网站确实没有图标的记一下，过一个星期再找（断网时找不到的不记）
@MainActor
final class SiteIcons {
    static let shared = SiteIcons()

    enum State {
        case unknown, none
        case icon(SiteIcon)
    }

    private final class Box: NSObject {
        let icon: SiteIcon?
        init(_ icon: SiteIcon?) { self.icon = icon }
    }

    private let memory = NSCache<NSString, Box>()
    private var loading: [String: Task<SiteIcon?, Never>] = [:]
    private let folder: URL

    init(folder: URL? = nil) {
        self.folder = folder ?? BrowserCache.folder("Site Icons")
        // 一张图标解码后最多 256×256×4 = 256 KB；总共留 24 MB，内存紧张时系统会自己清
        memory.totalCostLimit = 24 * 1024 * 1024
        memory.countLimit = 300
    }

    /// 内存里已经有答案了（有图标 / 确实没有）；还不知道是 .unknown
    func state(for host: String) -> State {
        guard let box = memory.object(forKey: host as NSString) else { return .unknown }
        return box.icon.map(State.icon) ?? .none
    }

    /// remember: false 是无痕标签页的：找到的只放内存里，不往磁盘上写（文件名就是网址，写了就等于记下了去过哪）
    func load(_ host: String, remember: Bool = true) async -> SiteIcon? {
        if case .icon(let icon) = state(for: host) { return icon }
        if case .none = state(for: host) { return nil }
        if let running = loading[host] { return await running.value }
        let folder = folder
        let task = Task<SiteIcon?, Never>.detached(priority: .utility) {
            await IconFetch.gate.enter()
            let found = await IconFetch.resolve(host: host, folder: folder, remember: remember)
            await IconFetch.gate.leave()
            return found
        }
        loading[host] = task
        let icon = await task.value
        loading[host] = nil
        memory.setObject(Box(icon), forKey: host as NSString, cost: icon.map { $0.image.width * $0.image.height * 4 } ?? 1)
        return icon
    }
}

/// 找图标的活（不在主线程上）
enum IconFetch {
    /// 同时最多找 4 个网站
    static let gate = Gate(limit: 4)

    actor Gate {
        private var running = 0
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private let limit: Int
        init(limit: Int) { self.limit = limit }
        func enter() async {
            if running < limit { running += 1; return }
            await withCheckedContinuation { waiting.append($0) }
        }
        func leave() {
            if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
        }
    }

    /// 首页里声明的一个图标
    struct Candidate: Equatable {
        enum Kind: Int, Comparable {
            case touch, sized, vector, manifest, plain
            static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
        }
        var url: URL
        var kind: Kind
        /// 写了的尺寸（像素），没写是 0
        var size: Int
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        config.httpAdditionalHeaders = ["User-Agent": UserAgent.safari, "Accept-Language": "en-US,en;q=0.9"]
        return URLSession(configuration: config)
    }()

    static func resolve(host: String, folder: URL, remember: Bool = true) async -> SiteIcon? {
        let name = String(host.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" })
        guard !name.isEmpty else { return nil }
        let file = folder.appendingPathComponent(name + ".png"), miss = folder.appendingPathComponent(name + ".none")
        if let data = try? Data(contentsOf: file), let icon = decode(data) { return icon }
        if let date = (try? miss.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           Date().timeIntervalSince(date) < 7 * 86400 { return nil }

        guard let home = URL(string: "https://\(host)/") else { return nil }
        var candidates: [Candidate] = []
        var reached = false
        if let (data, response) = try? await session.data(from: home), let http = response as? HTTPURLResponse {
            reached = true
            let base = http.url ?? home
            if (200..<300).contains(http.statusCode) {
                let html = String(decoding: data.prefix(600_000), as: UTF8.self)
                candidates = links(in: html, base: base)
                // 网站给了 manifest（PWA）：里面常有 192、512 像素的图标
                if !candidates.contains(where: { $0.kind == .touch || ($0.kind == .sized && $0.size >= 120) }),
                   let manifest = manifestURL(in: html, base: base) {
                    candidates += await manifestIcons(manifest)
                }
            }
        }
        var best: SiteIcon?
        for url in ranked(candidates, host: host).prefix(7) {
            guard let (data, response) = try? await session.data(from: url) else { continue }
            reached = true
            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
                  data.count < 3_000_000, let icon = decode(data) else { continue }
            if icon.pixels > (best?.pixels ?? 0) { best = icon }
            if icon.pixels >= 64 { break }   // 够大了，后面的（更小的）不用试
        }
        guard remember else { return best }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let best, let png = png(best.image) {
            try? png.write(to: file, options: .atomic)
        } else if reached {
            FileManager.default.createFile(atPath: miss.path, contents: nil)
        }
        return best
    }

    /// 要试的地址，好的在前：apple-touch-icon（大的在前）、写了尺寸的大图标、SVG、manifest 里的、
    /// 常见位置的 apple-touch-icon，然后是小图标、/favicon.ico
    static func ranked(_ candidates: [Candidate], host: String) -> [URL] {
        let large = candidates.filter { $0.kind == .touch || $0.kind == .vector || $0.kind == .manifest || ($0.kind == .sized && $0.size >= 64) }
            .sorted { a, b in
                a.kind == b.kind ? (a.size == 0 ? 180 : a.size) > (b.size == 0 ? 180 : b.size) : a.kind < b.kind
            }
        let small = candidates.filter { !large.contains($0) }.sorted { $0.size > $1.size }
        var urls = large.map(\.url)
        if let touch = URL(string: "https://\(host)/apple-touch-icon.png") { urls.append(touch) }
        urls += small.map(\.url)
        if let favicon = URL(string: "https://\(host)/favicon.ico") { urls.append(favicon) }
        var seen = Set<URL>()
        return urls.filter { seen.insert($0).inserted }
    }

    /// 首页 <head> 里的 <link rel="…icon…">
    static func links(in html: String, base: URL) -> [Candidate] {
        let head = html.range(of: "</head>", options: .caseInsensitive).map { String(html[..<$0.lowerBound]) } ?? html
        return tags(in: head).compactMap { attributes -> Candidate? in
            let rel = attributes["rel", default: ""].lowercased()
            guard rel.contains("icon"), !rel.contains("mask-icon"), let href = attributes["href"],
                  let url = resolve(href, base: base) else { return nil }
            let size = largestSize(attributes["sizes"])
            let svg = attributes["type", default: ""].contains("svg") || url.path.lowercased().hasSuffix(".svg")
            let kind: Candidate.Kind = rel.contains("apple-touch-icon") ? .touch
                : svg ? .vector : size >= 64 ? .sized : .plain
            return Candidate(url: url, kind: kind, size: size)
        }
    }

    static func manifestURL(in html: String, base: URL) -> URL? {
        let head = html.range(of: "</head>", options: .caseInsensitive).map { String(html[..<$0.lowerBound]) } ?? html
        return tags(in: head).first { $0["rel", default: ""].lowercased() == "manifest" }
            .flatMap { $0["href"] }.flatMap { resolve($0, base: base) }
    }

    private static func manifestIcons(_ url: URL) async -> [Candidate] {
        guard let (data, _) = try? await session.data(from: url), data.count < 500_000,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let icons = json["icons"] as? [[String: Any]] else { return [] }
        return icons.compactMap { icon in
            guard let src = icon["src"] as? String, let full = resolve(src, base: url),
                  !(icon["purpose"] as? String ?? "").contains("monochrome") else { return nil }
            return Candidate(url: full, kind: .manifest, size: largestSize(icon["sizes"] as? String))
        }
    }

    /// "16x16 32x32" → 32；"any" 当成很大（矢量图）
    static func largestSize(_ sizes: String?) -> Int {
        guard let sizes = sizes?.lowercased() else { return 0 }
        if sizes.contains("any") { return 512 }
        return sizes.split(separator: " ").compactMap { Int($0.split(separator: "x").first ?? "") }.max() ?? 0
    }

    private static func resolve(_ href: String, base: URL) -> URL? {
        let clean = href.replacingOccurrences(of: "&amp;", with: "&").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.hasPrefix("data:"), let url = URL(string: clean, relativeTo: base)?.absoluteURL,
              url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }

    private static let tagPattern = try! NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive])
    private static let attributePattern = try! NSRegularExpression(
        pattern: "([a-zA-Z_:][-a-zA-Z0-9_:.]*)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'=<>`]+))")

    /// 每个 <link> 的属性（名字小写）
    private static func tags(in html: String) -> [[String: String]] {
        let text = html as NSString
        return tagPattern.matches(in: html, range: NSRange(location: 0, length: text.length)).prefix(200).map { match in
            let tag = text.substring(with: match.range) as NSString
            var attributes: [String: String] = [:]
            for attribute in attributePattern.matches(in: tag as String, range: NSRange(location: 0, length: tag.length)) {
                let name = tag.substring(with: attribute.range(at: 1)).lowercased()
                let value = (2...4).map { attribute.range(at: $0) }.first { $0.location != NSNotFound }.map { tag.substring(with: $0) } ?? ""
                if attributes[name] == nil { attributes[name] = value }
            }
            return attributes
        }
    }

    // MARK: 解码

    /// 解码成最长边不超过 256 像素的位图（.ico 里有几张的取最大的；SVG 画成 256×256）
    static func decode(_ data: Data) -> SiteIcon? {
        var image: CGImage?
        if let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 {
            var index = 0, widest = 0
            for i in 0..<CGImageSourceGetCount(source) {
                let properties = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
                let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
                if width > widest { widest = width; index = i }
            }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceShouldCacheImmediately: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: 256]
            image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
        }
        if image == nil, let vector = NSImage(data: data), vector.isValid, vector.size.width > 0 {
            image = render(vector, side: 256)
        }
        guard let image, min(image.width, image.height) >= 16 else { return nil }
        let look = analyse(image)
        return SiteIcon(image: image, pixels: min(image.width, image.height), opaque: look.opaque, light: look.light)
    }

    private static func render(_ image: NSImage, side: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    /// 缩到 24×24 看一眼：四个角透不透明、图标本身深还是浅
    static func analyse(_ image: CGImage) -> (opaque: Bool, light: Bool) {
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return (true, false) }
        func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * side + x) * 4 + 3] }
        let opaque = [alpha(0, 0), alpha(side - 1, 0), alpha(0, side - 1), alpha(side - 1, side - 1)].allSatisfy { $0 > 230 }
        var total = 0.0, count = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 128 {
            let a = Double(pixels[i + 3])
            let r = Double(pixels[i]) / a, g = Double(pixels[i + 1]) / a, b = Double(pixels[i + 2]) / a
            total += 0.299 * r + 0.587 * g + 0.114 * b
            count += 1
        }
        return (opaque, count > 0 && total / count > 0.8)
    }

    private static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// 一块圆角方块上的网站图标：有够大的图标就画它（自带底色的铺满整块，透明底的放在中间、垫白色或深色的底），
/// 没有就是网站名的第一个字母，底色按网站固定一种颜色。只画一样，不会两样叠在一起；
/// 还在找的时候是一块素色，不先画字母再换成图标
struct SiteTile: View {
    let page: WebPage
    let size: CGFloat
    var corner: CGFloat
    /// 这么大的地方至少要多大的图标（像素），小了宁可画字母（大方块 64，小图标 16）
    var minPixels = 64
    /// 无痕标签页的：图标只放内存里，不写磁盘
    var remember = true
    @State private var found: (host: String, icon: SiteIcon?)?

    var body: some View {
        let host = page.url.host ?? ""
        var state = SiteIcons.shared.state(for: host)
        if case .unknown = state, let found, found.host == host { state = found.icon.map(SiteIcons.State.icon) ?? .none }
        return ZStack {
            switch state {
            case .unknown:
                Color.white.opacity(0.08)
            case .icon(let icon) where icon.pixels >= minPixels:
                if icon.opaque {
                    Image(decorative: icon.image, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                } else {
                    (icon.light ? Color(hex: "#2C2C2E") : Color.white)
                    Image(decorative: icon.image, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .padding(size * 0.17)
                }
            default:
                Monogram(page: page, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .task(id: host) {
            guard !host.isEmpty, case .unknown = SiteIcons.shared.state(for: host) else { return }
            let icon = await SiteIcons.shared.load(host, remember: remember)
            if !Task.isCancelled { withAnimation(Motion.appear) { found = (host, icon) } }
        }
    }
}

/// 没有图标时：一块纯色，中间一个字母
struct Monogram: View {
    let page: WebPage
    let size: CGFloat

    nonisolated static let palette = ["#2A6CF0", "#E5484D", "#30A46C", "#F76B15", "#8E4EC6", "#0091FF", "#D6409F", "#12A594"]

    /// 名字里第一个字母（"(3) Inbox" 是 I），没有就用网址的；都没有字母才用数字
    nonisolated static func letter(for page: WebPage) -> String {
        let first = page.name.first(where: \.isLetter) ?? page.host.first(where: \.isLetter) ?? page.host.first(where: \.isNumber)
        return first.map { String($0).uppercased() } ?? "•"
    }

    nonisolated static func color(for page: WebPage) -> String {
        palette[abs(page.host.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) }) % palette.count]
    }

    var body: some View {
        ZStack {
            Color(hex: Self.color(for: page))
            Text(Self.letter(for: page))
                .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}
