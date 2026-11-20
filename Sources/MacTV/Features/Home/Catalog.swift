import AppKit
import ImageIO

struct Service: Identifiable, Hashable {
    enum Kind: Hashable {
        case web(URL)
        case app(bundleID: String)
        /// A Steam game, or Steam Big Picture, launched through Steam.
        case steam(appID: String)
        /// The movies in folders on this Mac.
        case movies
        case addApp
        case settings
    }

    let id: String
    let name: String
    let kind: Kind
    /// The service's square app icon, a file in Icons/ for built-in apps…
    var icon: String? = nil
    /// …or a file the user's app library saved, for apps they added.
    var iconFile: URL? = nil
    /// 手机遥控器上用的另一张图标（Icons/ 里的 PNG），电视主屏的图和手机上的应用图标不一样时才有
    var phoneIcon: String? = nil
    var accent = "#8E8E93"
    var deep = "#16171B"
    var userAgent: String = UserAgent.safari
    /// Inject D-pad focus navigation for sites that were built for a mouse.
    var dpadNavigation = true
    /// 随便一个网页（手机发来的链接、启动参数里给的）：用网页播放器打开，不算哪个应用
    static func website(_ url: URL) -> Service {
        Service(id: "browser-session", name: url.host ?? "Web Page", kind: .web(url))
    }

    /// Can be opened here: a Mac app or Steam has to be installed; websites always can.
    var isAvailable: Bool { isInstalled }

    var isInstalled: Bool {
        switch kind {
        case .app(let bundleID): return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        case .steam: return SteamLibrary.isInstalled
        default: return true
        }
    }

    /// Steam games bring a ready-made wide tile (background and logo) instead of a square icon.
    var hasWideArt: Bool {
        if case .steam(let appID) = kind { return appID != SteamLibrary.bigPicture.appID }
        return false
    }
}

enum UserAgent {
    /// Streaming sites gate DRM and quality on the browser; present as Safari.
    static let safari = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Safari/605.1.15"
    /// youtube.com/tv only serves its 10-foot interface to TV browsers.
    static let smartTV = "Mozilla/5.0 (Linux; Tizen 2.3) AppleWebKit/538.1 (KHTML, like Gecko)Version/2.3 TV Safari/538.1"
    /// Google's sign-in turns away browsers embedded in apps ("browser unsupported"); on its
    /// pages only, present as desktop Firefox, which it accepts.
    static let googleSignIn = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:144.0) Gecko/20100101 Firefox/144.0"
}

enum Catalog {
    /// The home screen, in order: the first six sit in the dock under the Top Shelf.
    /// Mac app tiles only appear when the app is installed.
    static let services: [Service] = [
        // 原生页面（Features/Bilibili），不是直接打开这个网址；见 TVController.open
        Service(id: "bilibili", name: "哔哩哔哩", kind: .web(URL(string: "https://www.bilibili.com")!),
                icon: "bilibili.png", accent: "#FB7299", deep: "#3A0F1E"),
        // 原生页面（Features/Netease）
        Service(id: "netease", name: "网易云音乐", kind: .web(URL(string: "https://music.163.com")!),
                icon: "netease.png", phoneIcon: "netease-app.png", accent: "#E60026", deep: "#2B0206"),
        // 原生页面（Features/Dedao）：得到的听书和课程
        Service(id: "dedao", name: "得到", kind: .web(URL(string: "https://www.dedao.cn")!),
                icon: "dedao.png", accent: "#FF6A00", deep: "#3A1600"),
        Service(id: "youtube", name: "YouTube", kind: .web(YouTubeTV.home),
                icon: "youtube.png", accent: "#FF2D2D", deep: "#2B0606",
                userAgent: UserAgent.smartTV, dpadNavigation: false),
        // 原生页面（Features/Browser）：电视上的 Safari，开始页有 Safari 的收藏、常去网站和历史
        Service(id: "browser", name: "Browser", kind: .web(URL(string: "https://www.google.com")!),
                icon: "browser.png", accent: "#2A6CF0", deep: "#0A1F45"),
        Service(id: "movies", name: "Movies", kind: .movies, accent: "#5E5CE6", deep: "#14133A"),
        Service(id: "iina", name: "IINA", kind: .app(bundleID: "com.colliderli.iina"),
                icon: "iina.png"),
        Service(id: "add-app", name: "Add App", kind: .addApp),
        Service(id: "settings", name: "Settings", kind: .settings),
    ]
}

/// Icon artwork for tiles and for the phone remote's app list.
@MainActor
enum Icons {
    private static var images: [String: NSImage] = [:]
    private static var pngs: [String: Data] = [:]

    static func image(for service: Service) -> NSImage? {
        if let cached = images[service.id] { return cached }
        var image: NSImage?
        if let file = service.iconFile {
            image = decoded(file)
        } else if let file = service.icon,
           let url = Bundle.main.url(forResource: file, withExtension: nil, subdirectory: "Icons") {
            image = decoded(url)
        }
        images[service.id] = image
        return image
    }

    /// Icons are often 1024 px; tiles draw them about 250 points wide, so 512 px is plenty sharp.
    private static func decoded(_ url: URL) -> NSImage? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 512]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return NSImage(contentsOf: url) }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private static var tiles: [String: NSImage] = [:]

    /// Drops cached artwork, after an app's icon arrives or the app is removed.
    static func forget(_ id: String) {
        images[id] = nil
        tiles[id] = nil
        pngs[id] = nil
    }

    static func tile(for service: Service) -> NSImage? {
        if let cached = tiles[service.id] { return cached }
        let tile = service.hasWideArt ? image(for: service)
            : image(for: service)?.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap { TileArt.make(from: $0) }
        tiles[service.id] = tile
        return tile
    }

    /// 手机遥控器应用列表里的图标。有专门的手机图标（phoneIcon，官方的正方形图标）就用它，
    /// 否则和电视主屏用同一张
    static func png(for service: Service) -> Data? {
        if let cached = pngs[service.id] { return cached }
        if let file = service.phoneIcon,
           let url = Bundle.main.url(forResource: file, withExtension: nil, subdirectory: "Icons"),
           let data = try? Data(contentsOf: url) {
            pngs[service.id] = data
            return data
        }
        guard let image = image(for: service), let tiff = image.tiffRepresentation,
              let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return nil }
        pngs[service.id] = data
        return data
    }
}
