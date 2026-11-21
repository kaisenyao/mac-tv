import AppKit
import SwiftUI
import Testing
@testable import MacTV

/// 1920×1080 renders of Home's Top Shelf for each app that has one, collapsed (on the dock) and expanded (the shelf
/// focused, the dock gone), to check that every app follows the same grid (ShelfGrid): 网易云's playlists (a one-line
/// and a two-line title) and its now-playing page, 得到's new book and the book you're listening to, 哔哩哔哩, YouTube and
/// Movies (a film with a wide picture, in Continue Watching, and one with only a poster). Only with
/// MACTV_RENDER_SHELF=<folder>. The pictures are made here; everything lives in a temporary folder.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MACTV_RENDER_SHELF"] != nil), .timeLimit(.minutes(2)))
@MainActor struct TopShelfRenders {
    private let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACTV_RENDER_SHELF"] ?? "/tmp", isDirectory: true)

    private func render(_ name: String, _ tv: TVController) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let host = NSHostingView(rootView: ZStack { Color.black; TVCanvas { HomeView(tv: tv) } }
            .environment(\.colorScheme, .dark).frame(width: 1920, height: 1080))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1920, height: 1080), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(1600))
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(name).png"))
        window.close()
    }

    /// Collapsed (the app focused on the dock), then expanded (its first button focused).
    private func renderBoth(_ name: String, _ tv: TVController) async throws {
        try await render("\(name)-collapsed", tv)
        tv.setFocus(.shelf(0))
        try await render("\(name)-expanded", tv)
    }

    // MARK: Home

    private func withTV(movies: (URL, MovieLibrary) -> [Movie] = { _, _ in [] },
                        _ body: (TVController, URL) async throws -> Void) async throws {
        _ = NSApplication.shared
        AudioCoordinator.readVolume = { VolumeLevel(level: 75, muted: false) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacTVShelfRenders-\(UUID().uuidString)", isDirectory: true)
        let store = folder.appendingPathComponent("Movies", isDirectory: true)
        let media = folder.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "MacTVShelfRenders.\(UUID().uuidString)"
        let defaults = TestDefaults.named(suite)
        defer { TestDefaults.remove(suite) }
        defaults.set([media.path], forKey: "movieFolders")
        defaults.set(true, forKey: "movieFoldersDownloadsAdded")
        try JSONEncoder().encode([Movie]()).write(to: store.appendingPathComponent("library.json"))
        let empty = MovieLibrary(folder: store, defaults: defaults)
        try JSONEncoder().encode(movies(media, empty)).write(to: store.appendingPathComponent("library.json"))
        let library = MovieLibrary(folder: store, defaults: defaults)
        let services = AppServices(preferences: Preferences(defaults: defaults), movieLibrary: library)
        let tv = TVController(library: AppLibrary(folder: folder), profiles: ProfileStore(folder: folder), services: services)
        try await body(tv, folder)
    }

    /// This app first on the dock and focused: Home's Top Shelf is its.
    private func focus(_ tv: TVController, on id: String, pages: [AppShelfItem] = [], label: String = "") throws {
        try #require(tv.appOrder.contains(id) && tv.moveApp(id, to: 0))
        tv.setFocus(.app(1)); tv.setFocus(.app(0))
        #expect(tv.shelfService.id == id)
        if !pages.isEmpty { tv.appShelf.show(id, pages: pages, label: label) }
    }

    // MARK: Pictures

    /// A placeholder picture: a gradient with a white frame just inside its edges (so a cut edge shows) and a label.
    private func picture(_ name: String, size: CGSize, hue: CGFloat, in folder: URL) async throws -> URL {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let rect = NSRect(origin: .zero, size: size)
        NSGradient(starting: NSColor(hue: hue, saturation: 0.75, brightness: 0.9, alpha: 1),
                   ending: NSColor(hue: hue + 0.12, saturation: 0.8, brightness: 0.28, alpha: 1))!.draw(in: rect, angle: -60)
        NSColor.white.withAlphaComponent(0.85).setStroke()
        let frame = NSBezierPath(rect: rect.insetBy(dx: 10, dy: 10))
        frame.lineWidth = 6
        frame.stroke()
        (name.uppercased() as NSString).draw(at: NSPoint(x: 36, y: size.height - 96),
                                             withAttributes: [.font: NSFont.systemFont(ofSize: 56, weight: .heavy),
                                                              .foregroundColor: NSColor.white.withAlphaComponent(0.9)])
        NSGraphicsContext.restoreGraphicsState()
        let url = folder.appendingPathComponent("\(name).png")
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        _ = await BiliImageCache.shared.load(url)
        return url
    }

    private func png(_ name: String, size: CGSize, hue: CGFloat) throws -> Data {
        let image = NSImage(size: size, flipped: false) { rect in
            NSGradient(starting: NSColor(hue: hue, saturation: 0.7, brightness: 0.85, alpha: 1),
                       ending: NSColor(hue: hue + 0.1, saturation: 0.8, brightness: 0.2, alpha: 1))!.draw(in: rect, angle: -30)
            NSColor.white.withAlphaComponent(0.85).setStroke()
            let frame = NSBezierPath(rect: rect.insetBy(dx: 10, dy: 10))
            frame.lineWidth = 6
            frame.stroke()
            (name.uppercased() as NSString).draw(at: NSPoint(x: 40, y: rect.height - 110),
                                                 withAttributes: [.font: NSFont.systemFont(ofSize: 64, weight: .heavy),
                                                                  .foregroundColor: NSColor.white])
            return true
        }
        return try #require(image.tiffRepresentation)
    }

    // MARK: 网易云

    private func playlist(_ id: Int, _ title: String, tag: String, daily: Bool = false, cover: URL) -> AppShelfItem {
        let songs = [("晴天", "周杰伦"), ("南方姑娘", "赵雷"), ("理想三旬", "陈鸿宇"), ("Yellow", "Coldplay")].enumerated().map { index, song in
            NeteaseSong(id: id * 10 + index, name: song.0, artist: song.1, cover: cover)
        }
        return AppShelfItem(id: "pl-\(id)", kind: .collection(NeteasePlaylist(id: id, name: title, cover: cover, count: 30, kind: daily ? .daily : .playlist),
                                                            songs: songs),
                            title: title, subtitle: "30 首 · 云音乐", detail: "", image: cover, thumbnail: cover, avatar: nil, tag: tag)
    }

    @Test func netease() async throws {
        try await withTV { tv, folder in
            let cover = try await picture("sleeve", size: CGSize(width: 800, height: 800), hue: 0.95, in: folder)
            try focus(tv, on: NeteaseStore.appID, pages: [playlist(1, "每日推荐", tag: "每日推荐", daily: true, cover: cover),
                                                          playlist(2, "深夜一个人安静听的华语民谣与独立音乐", tag: "推荐歌单", cover: cover)])
            try await renderBoth("netease-playlist-1line", tv)
        }
        try await withTV { tv, folder in
            let cover = try await picture("sleeve", size: CGSize(width: 800, height: 800), hue: 0.55, in: folder)
            try focus(tv, on: NeteaseStore.appID, pages: [playlist(2, "深夜一个人安静听的华语民谣与独立音乐", tag: "推荐歌单", cover: cover),
                                                          playlist(1, "每日推荐", tag: "每日推荐", daily: true, cover: cover)])
            try await renderBoth("netease-playlist-2lines", tv)
        }
        try await withTV { tv, folder in
            let cover = try await picture("album", size: CGSize(width: 800, height: 800), hue: 0.08, in: folder)
            let song = NeteaseSong(id: 7, name: "夜空中最亮的星", artist: "逃跑计划", cover: cover, duration: 252, albumName: "世界")
            let now = AppShelfItem(id: "ne-now-7", kind: .nowPlaying(song, paused: false), title: song.name, subtitle: "逃跑计划 · 世界",
                                   detail: "", image: cover, thumbnail: cover, avatar: nil, tag: "正在播放")
            try focus(tv, on: NeteaseStore.appID, pages: [now, playlist(1, "每日推荐", tag: "每日推荐", daily: true, cover: cover)])
            try await renderBoth("netease-now-playing", tv)
        }
    }

    // MARK: 得到

    private func book(_ enid: String, cover: URL, progress: Int = 0) -> DedaoAPI.Item {
        var item = DedaoAPI.Item(kind: .book, enid: enid, title: "《置身事内：中国政府与经济发展》", author: "兰小欢 著 · 李翔解读",
                                 intro: "一本讲中国政府怎样参与经济的书：土地财政、地方债、招商引资，从一个个具体的故事里，看清楚过去四十年经济增长背后的逻辑。",
                                 cover: cover, progress: progress, finished: false, count: 0, studied: 0, shelf: .books)
        item.score = "9.1"
        item.heat = "36万次学习"
        item.duration = 1860
        return item
    }

    @Test func dedao() async throws {
        try await withTV { tv, folder in
            let cover = try await picture("book", size: CGSize(width: 600, height: 800), hue: 0.6, in: folder)
            try focus(tv, on: DedaoStore.appID, pages: [DedaoStore.shelfCard(book("b1", cover: cover), tag: "新书 · 经济", resume: false),
                                                       DedaoStore.shelfCard(book("b2", cover: cover), tag: "新书 · 历史", resume: false)])
            try await renderBoth("dedao-new-book", tv)
        }
        try await withTV { tv, folder in
            let cover = try await picture("book", size: CGSize(width: 600, height: 800), hue: 0.12, in: folder)
            try focus(tv, on: DedaoStore.appID, pages: [DedaoStore.shelfCard(book("b1", cover: cover, progress: 40), tag: "继续学习", resume: true),
                                                       DedaoStore.shelfCard(book("b2", cover: cover), tag: "新书 · 历史", resume: false)])
            try await renderBoth("dedao-continue", tv)
        }
    }

    // MARK: 哔哩哔哩, YouTube

    @Test func videos() async throws {
        try await withTV { tv, folder in
            let cover = try await picture("video", size: CGSize(width: 1600, height: 900), hue: 0.33, in: folder)
            let video = BiliVideo(bvid: "BV1", title: "【4K】用一整年拍下的四季：从冰封的湖面到盛夏的山谷", cover: cover, duration: 754,
                                  owner: "影视飓风", views: 1_234_567)
            let page = AppShelfItem(id: "bv-1", kind: .video(video), title: video.title, subtitle: "影视飓风", detail: "3 小时前 · 123.5万播放 · 12:34",
                                    image: cover, thumbnail: cover, avatar: cover)
            try focus(tv, on: BilibiliStore.appID, pages: [page, page.withID("bv-2")], label: "关注更新")
            try await renderBoth("bilibili-video", tv)
        }
        try await withTV { tv, folder in
            let cover = try await picture("youtube", size: CGSize(width: 1600, height: 900), hue: 0.02, in: folder)
            let page = AppShelfItem(id: "yt-1", kind: .youtube("abc"), title: "The Most Beautiful Train Ride in the World",
                                    subtitle: "Rail Journeys", detail: "1.2M views · 3 days ago", image: cover, thumbnail: cover, avatar: nil)
            try focus(tv, on: "youtube", pages: [page, page.withID("yt-2")], label: "Recommended")
            try await renderBoth("youtube-video", tv)
        }
    }

    // MARK: Movies

    private func film(_ media: URL, _ title: String, year: Int, minutes: Double, left: Double? = nil, days: Double) -> Movie {
        var movie = Movie(path: media.appendingPathComponent("Films/\(title) (\(year)).mkv").path, title: title, year: year,
                          added: Date().addingTimeInterval(-days * 86400), size: 2_400_000_000)
        movie.declared = "Movie"
        movie.duration = minutes * 60
        movie.sidecarChecked = true
        movie.inspected = true
        movie.genre = "Drama"
        if let left {
            movie.position = minutes * 60 - left * 60
            movie.lastWatched = Date().addingTimeInterval(-3600)
        }
        return movie
    }

    @Test func movies() async throws {
        try await withTV(movies: { media, library in
            var coast = film(media, "The Long Coast", year: 2021, minutes: 112, left: 38, days: 2)
            coast.overview = "A lighthouse keeper's daughter returns to the coast she left twenty years ago, and finds the town "
                + "waiting for an answer she never gave. Over one winter, the sea gives back what it took."
            coast.backdrop = (try? png("backdrop", size: CGSize(width: 1920, height: 1080), hue: 0.55))
                .flatMap { MovieArtwork.store($0, name: "render-coast-wide.jpg", maxPixel: 1920, in: library.artworkFolder) }
            var harbor = film(media, "Glass Harbor", year: 2018, minutes: 121, days: 6)
            harbor.overview = "Two brothers rebuild their late father's boat over one long summer."
            harbor.poster = (try? png("poster", size: CGSize(width: 600, height: 900), hue: 0.05))
                .flatMap { MovieArtwork.store($0, name: "render-harbor-poster.jpg", maxPixel: 900, in: library.artworkFolder) }
            return [coast, harbor]
        }) { tv, _ in
            try focus(tv, on: "movies")
            try #require(tv.movieLibrary.shelf.count == 2)
            try await renderBoth("movies-continue", tv)
        }
        try await withTV(movies: { media, library in
            var harbor = film(media, "Glass Harbor", year: 2018, minutes: 121, days: 6)
            harbor.overview = "Two brothers rebuild their late father's boat over one long summer, and argue about everything except the thing that matters."
            harbor.poster = (try? png("poster", size: CGSize(width: 600, height: 900), hue: 0.05))
                .flatMap { MovieArtwork.store($0, name: "render-harbor-poster.jpg", maxPixel: 900, in: library.artworkFolder) }
            return [harbor]
        }) { tv, _ in
            try focus(tv, on: "movies")
            try await renderBoth("movies-poster", tv)
        }
    }
}

private extension AppShelfItem {
    /// The same page under another id (a second page, so the dots show).
    func withID(_ id: String) -> AppShelfItem {
        AppShelfItem(id: id, kind: kind, title: title, subtitle: subtitle, detail: detail, image: image, thumbnail: thumbnail,
                     avatar: avatar, tag: tag)
    }
}
