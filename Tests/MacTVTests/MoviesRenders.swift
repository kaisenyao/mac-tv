import AppKit
import SwiftUI
import Testing
@testable import MacTV

/// 1920×1080 renders of the Movies app's states, offscreen, for review: Home with the sidebar collapsed and open, a
/// section's grid, a source, a film's page with full details and with only a file's, a home video's page, a show's
/// page, Search, the empty library and a card's menu. Only with MACTV_RENDER_MOVIES=<folder>. The pictures are
/// placeholders made here (from MACTV_MOVIES_ART=<folder of .jpg>, or plain colour), with made-up titles; everything
/// lives in a temporary folder.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MACTV_RENDER_MOVIES"] != nil), .timeLimit(.minutes(1)))
@MainActor struct MoviesRenders {
    private let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACTV_RENDER_MOVIES"] ?? "/tmp", isDirectory: true)
    private let art = ProcessInfo.processInfo.environment["MACTV_MOVIES_ART"].map { URL(fileURLWithPath: $0, isDirectory: true) }

    private func render(_ name: String, _ tv: TVController) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let view = ZStack { Color.black; TVCanvas { MoviesScreen(tv: tv) } }
            .environment(\.colorScheme, .dark).frame(width: 1920, height: 1080)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1920, height: 1080), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(900))
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1920, pixelsHigh: 1080, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = NSSize(width: 1920, height: 1080)
        host.cacheDisplay(in: host.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(name).png"))
        window.close()
    }

    // MARK: Placeholder pictures

    private func picture(_ name: String) -> NSImage {
        if let art, let image = NSImage(contentsOf: art.appendingPathComponent(name + ".jpg")) { return image }
        return NSImage(size: NSSize(width: 1600, height: 900), flipped: false) { rect in
            NSGradient(colors: [.systemIndigo, .black])?.draw(in: rect, angle: -60); return true
        }
    }

    /// A made-up poster: a picture, a gradient and a title.
    private func poster(_ title: String, _ image: String, hue: Double, year: Int, into library: MovieLibrary) -> String? {
        let view = ZStack(alignment: .bottom) {
            Image(nsImage: picture(image)).resizable().aspectRatio(contentMode: .fill).frame(width: 600, height: 900).clipped()
                .hueRotation(.degrees(hue))
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
            VStack(spacing: 14) {
                Text(title.uppercased()).font(.system(size: 72, weight: .heavy)).tracking(3).multilineTextAlignment(.center)
                Text("A FILM · \(String(year))").font(.system(size: 26, weight: .semibold)).tracking(6).opacity(0.75)
            }
            .foregroundStyle(.white).padding(40).padding(.bottom, 40)
        }
        .frame(width: 600, height: 900)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.cgImage, let data = MovieArtwork.jpeg(image) else { return nil }
        return MovieArtwork.store(data, name: "render-\(MovieArtwork.hash(title))-poster.jpg", maxPixel: 900, in: library.artworkFolder)
    }

    private func wide(_ name: String, into library: MovieLibrary) -> String? {
        guard let tiff = picture(name).tiffRepresentation else { return nil }
        return MovieArtwork.store(tiff, name: "render-\(name)-wide.jpg", maxPixel: 1920, in: library.artworkFolder)
    }

    // MARK: The library

    private func withTV(empty: Bool = false, _ body: (TVController, MovieLibrary, URL) async throws -> Void) async throws {
        _ = NSApplication.shared
        AudioCoordinator.readVolume = { VolumeLevel(level: 75, muted: false) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacTVMovieRenders-\(UUID().uuidString)", isDirectory: true)
        let store = folder.appendingPathComponent("Library", isDirectory: true)
        let media = folder.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "MacTVMovieRenders.\(UUID().uuidString)"
        let defaults = TestDefaults.named(suite)
        defer { TestDefaults.remove(suite) }
        defaults.set(empty ? [] : [media.path], forKey: "movieFolders")
        defaults.set(true, forKey: "movieFoldersDownloadsAdded")
        try JSONEncoder().encode([Movie]()).write(to: store.appendingPathComponent("library.json"))
        let library = MovieLibrary(folder: store, defaults: defaults)
        if !empty { try JSONEncoder().encode(movies(media, library)).write(to: store.appendingPathComponent("library.json")) }
        let loaded = MovieLibrary(folder: store, defaults: defaults)
        let services = AppServices(preferences: Preferences(defaults: defaults), movieLibrary: loaded)
        let tv = TVController(library: AppLibrary(folder: folder), profiles: ProfileStore(folder: folder), services: services)
        tv.openMoviesBrowserOnly()
        try await body(tv, loaded, media)
    }

    private func movies(_ media: URL, _ library: MovieLibrary) -> [Movie] {
        let now = Date()
        func item(_ title: String, _ year: Int, _ image: String, hue: Double = 0, minutes: Double, left: Double? = nil,
                  folder: String = "Films", days: Double = 1) -> Movie {
            var movie = Movie(path: media.appendingPathComponent("\(folder)/\(title) (\(year)).mkv").path, title: title, year: year,
                              added: now.addingTimeInterval(-days * 86400), size: 2_400_000_000)
            movie.declared = "Movie"
            movie.duration = minutes * 60
            movie.poster = poster(title, image, hue: hue, year: year, into: library)
            movie.backdrop = wide(image, into: library)
            movie.sidecarChecked = true
            movie.inspected = true
            movie.width = 3840
            movie.height = 1600
            movie.audio = "5.1"
            if let left {
                movie.position = movie.duration! - left * 60
                movie.lastWatched = now.addingTimeInterval(-days * 3600)
            }
            return movie
        }
        var coast = item("The Long Coast", 2021, "Sonoma-Horizon-0", minutes: 112, left: 38, days: 2)
        coast.overview = "A lighthouse keeper's daughter returns to the coast she left twenty years ago, and finds the town waiting for an answer she never gave."
        coast.genre = "Drama"
        coast.rating = "PG-13"
        coast.hdr = "HDR"
        coast.cast = [.init(name: "Ana Ruiz", role: "Mara"), .init(name: "Tom Hale", role: "Elias"), .init(name: "Iris Moon", role: "Young Mara"),
                      .init(name: "Sam Ode", role: "Harbourmaster"), .init(name: "Lea Park", role: "Director"), .init(name: "Jon Bell", role: "Writer")]
        var driftwood = item("Driftwood", 2022, "aerial2", hue: 28, minutes: 95, days: 3)
        driftwood.overview = "Two brothers rebuild their late father's boat over one long summer, and argue about everything except the thing that matters."
        driftwood.genre = "Drama"
        driftwood.width = 1920
        driftwood.height = 800
        driftwood.codec = "avc1"
        let films = [coast, item("Copper Sky", 2019, "aerial5", hue: -18, minutes: 98, left: 65, days: 4), driftwood,
                     item("Second Summer", 2023, "Sonoma-0", minutes: 104, days: 5), item("Glass Harbor", 2018, "Radial-Sky-Blue-0", minutes: 121, days: 6),
                     item("The Quiet Hour", 2024, "aerial6", hue: 200, minutes: 131, days: 7), item("Lumen", 2020, "Sonoma-1", hue: 140, minutes: 89, days: 8),
                     item("Low Tide", 2017, "Sequoia-Sunrise-0", hue: 175, minutes: 102, days: 9), item("Afterglow", 2016, "aerial7", hue: -40, minutes: 117, days: 10),
                     item("Paper Moons", 2015, "Radial-Sky-Blue-0", hue: 150, minutes: 93, days: 11),
                     item("The Cartographer", 2023, "Sonoma-Horizon-0", hue: 200, minutes: 126, days: 12),
                     item("North of Here", 2019, "aerial0", minutes: 108, days: 13)]
        var episodes: [Movie] = []
        for (season, count) in [(1, 6), (2, 4)] {
            for number in 1...count {
                var episode = Movie(path: media.appendingPathComponent("Field Notes/Season \(season)/Field Notes S\(season)E\(number).mkv").path,
                                    title: "Field Notes", episode: "S\(season) E\(number)", added: now.addingTimeInterval(-86400 * 2), size: 900_000_000)
                episode.show = "Field Notes"
                episode.season = season
                episode.number = number
                episode.duration = 44 * 60
                episode.poster = poster("Field Notes", "Sequoia-Sunrise-0", hue: 12, year: 2024, into: library)
                episode.backdrop = wide(["aerial1", "aerial3", "aerial4", "aerial6", "aerial0", "aerial7"][number % 6], into: library)
                episode.overview = "A naturalist spends a year in an old-growth forest, one season at a time."
                episode.genre = "Documentary"
                episode.sidecarChecked = true
                episode.inspected = true
                if season == 1, number < 3 { episode.watched = true }
                if season == 1, number == 3 { episode.position = 32 * 60; episode.lastWatched = now.addingTimeInterval(-3600) }
                episodes.append(episode)
            }
        }
        func homeVideo(_ title: String, _ image: String, minutes: Double, portrait: Bool = false, days: Double, left: Double? = nil) -> Movie {
            var movie = Movie(path: media.appendingPathComponent("2024 徒步/\(title).mov").path, title: title,
                              added: now.addingTimeInterval(-days * 86400), size: 1_100_000_000)
            movie.duration = minutes * 60
            movie.backdrop = wide(image, into: library)
            movie.sidecarChecked = true
            movie.inspected = true
            movie.width = portrait ? 2160 : 3840
            movie.height = portrait ? 3840 : 2160
            movie.hdr = "HDR"
            movie.device = "iPhone"
            movie.recorded = now.addingTimeInterval(-days * 86400 - 400 * 86400)
            if let left { movie.position = movie.duration! - left * 60; movie.lastWatched = now.addingTimeInterval(-days * 1800) }
            return movie
        }
        let videos = [homeVideo("红杉林 · 徒步", "aerial5", minutes: 6, days: 1), homeVideo("山顶日出", "Sonoma-Horizon-0", minutes: 3, days: 2),
                      homeVideo("钢琴练习 03", "aerial3", minutes: 4, portrait: true, days: 3, left: 2), homeVideo("周末", "aerial1", minutes: 11, days: 4),
                      homeVideo("晨雾", "aerial4", minutes: 2, portrait: true, days: 5), homeVideo("下山的路", "aerial0", minutes: 5, days: 6)]
        return films + episodes + videos
    }

    @Test func renderTheStates() async throws {
        try await withTV { tv, library, media in
            try await render("01-home", tv)
            tv.openMovieSidebar()
            try await render("02-home-sidebar", tv)
            tv.tapMovieSidebar(.movies)
            tv.handleMovies(.move(.right))
            tv.handleMovies(.move(.right))
            try await render("03-movies-grid", tv)
            tv.tapMovieSidebar(.source(media.path))
            tv.handleMovies(.move(.down))
            tv.handleMovies(.move(.right))
            try await render("04-source", tv)
            tv.tapMovieSidebar(.home)
            let coast = try #require(library.films.first { $0.title == "The Long Coast" })
            tv.openMoviePage(.movie(coast.path))
            try await render("05-detail-movie", tv)
            tv.handleMovies(.back)
            let driftwood = try #require(library.films.first { $0.title == "Driftwood" })
            tv.openMoviePage(.movie(driftwood.path))
            try await render("05b-detail-local", tv)
            tv.handleMovies(.back)
            let hike = try #require(library.videos.first { $0.title == "红杉林 · 徒步" })
            tv.openMoviePage(.movie(hike.path))
            // Its scenes, as the page makes them from the file (here, from the placeholder pictures)
            tv.moviesWork.scenesTask?.cancel()
            for (index, name) in ["aerial0", "aerial2", "aerial3", "aerial5", "aerial6", "aerial7"].enumerated() {
                tv.moviesWork.scenes[index] = picture(name)
            }
            try await render("06-detail-home-video", tv)
            tv.handleMovies(.back)
            let show = try #require(library.shows.first)
            tv.openMoviePage(.show(show.id))
            tv.handleMovies(.move(.down))
            tv.handleMovies(.move(.down))
            try await render("07b-show", tv)
            tv.handleMovies(.back)
            tv.tapMovieSidebar(.search)
            tv.handleMovies(.select)
            tv.handleMovies(.text("co"))
            tv.finishMovieTyping()
            try await render("07-search", tv)
            tv.tapMovieSidebar(.home)
            tv.handleMovies(.move(.right))
            #expect(tv.openHoldMenu())
            tv.handleMovies(.move(.down))
            try await render("09-hold-menu", tv)
        }
        try await withTV(empty: true) { tv, _, _ in
            try await render("08-empty", tv)
        }
    }

    // MARK: CPU

    /// Mac TV's process CPU (all threads) while Movies sits idle and while focus moves, in an offscreen window with the
    /// main run loop running. Only with MACTV_BENCH_MOVIES=1. Each case runs three times; min and median are printed.
    /// GPU compositing happens in WindowServer and isn't counted.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACTV_BENCH_MOVIES"] == "1"))
    func cpu() async throws {
        try await withTV { tv, _, _ in
            let keepAlive = Timer(timeInterval: 3600, repeats: true) { _ in }
            RunLoop.main.add(keepAlive, forMode: .common)
            defer { keepAlive.invalidate() }
            let host = NSHostingView(rootView: ZStack { Color.black; TVCanvas { MoviesScreen(tv: tv) } }
                .environment(\.colorScheme, .dark).frame(width: 1920, height: 1080))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1920, height: 1080), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            // As the browser's CPU check: invisible (alpha 0) and behind everything, or else far off screen
            if ProcessInfo.processInfo.environment["MACTV_BENCH_BEHIND"] == "1" {
                window.alphaValue = 0
                window.ignoresMouseEvents = true
                window.orderBack(nil)
            } else {
                window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
                window.orderFront(nil)
            }
            defer { window.close() }
            func cpu() -> Double {
                var time = timespec()
                clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time)
                return Double(time.tv_sec) + Double(time.tv_nsec) / 1e9
            }
            func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
            func measure(_ label: String, _ body: () -> Void) -> String {
                var percents: [Double] = []
                for _ in 0..<3 {
                    let start = cpu(), wall = Date()
                    body()
                    percents.append((cpu() - start) / Date().timeIntervalSince(wall) * 100)
                }
                percents.sort()
                return String(format: "%@: min %.1f%%, median %.1f%% of one core", label, percents[0], percents[1])
            }
            pump(2)
            var lines: [String] = []
            lines.append(measure("Home idle, 2 s") { pump(2) })
            lines.append(measure("along Continue Watching, 3 moves a second") {
                for _ in 0..<3 { tv.handleMovies(.move(.right)); pump(0.34) }
                for _ in 0..<3 { tv.handleMovies(.move(.left)); pump(0.34) }
            })
            lines.append(measure("down a row and back") {
                tv.handleMovies(.move(.down)); pump(0.6); tv.handleMovies(.move(.up)); pump(0.6)
            })
            lines.append(measure("sidebar out and back") {
                tv.openMovieSidebar(); pump(0.6); tv.handleMovies(.back); pump(0.6)
            })
            lines.append(measure("a page opens and closes") {
                tv.handleMovies(.select); pump(0.8); tv.handleMovies(.back); pump(0.8)
            })
            tv.tapMovieSidebar(.movies)
            pump(1)
            lines.append(measure("Movies grid, 3 moves a second") {
                for _ in 0..<3 { tv.handleMovies(.move(.right)); pump(0.34) }
                for _ in 0..<3 { tv.handleMovies(.move(.down)); pump(0.34) }
                for _ in 0..<3 { tv.handleMovies(.move(.up)); pump(0.34) }
                for _ in 0..<3 { tv.handleMovies(.move(.left)); pump(0.34) }
            })
            lines.append(measure("Movies grid idle, 2 s") { pump(2) })
            print("MoviesCPU\n  " + lines.joined(separator: "\n  "))
        }
    }

    /// The same measure on 哔哩哔哩's screen (its sidebar out and back, with nothing loaded), for comparison.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACTV_BENCH_MOVIES"] == "1"))
    func bilibiliBaseline() async throws {
        try await withTV(empty: true) { tv, _, _ in
            let keepAlive = Timer(timeInterval: 3600, repeats: true) { _ in }
            RunLoop.main.add(keepAlive, forMode: .common)
            defer { keepAlive.invalidate() }
            let host = NSHostingView(rootView: ZStack { Color.black; TVCanvas { BilibiliScreen(store: tv.bilibiliStore) } }
                .environment(\.colorScheme, .dark).frame(width: 1920, height: 1080))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1920, height: 1080), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            window.orderFront(nil)
            defer { window.close() }
            func cpu() -> Double {
                var time = timespec()
                clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time)
                return Double(time.tv_sec) + Double(time.tv_nsec) / 1e9
            }
            func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
            pump(2)
            var percents: [Double] = []
            for _ in 0..<3 {
                let start = cpu(), wall = Date()
                tv.bilibiliStore.handle(.move(.left)); pump(0.6); tv.bilibiliStore.handle(.back); pump(0.6)
                percents.append((cpu() - start) / Date().timeIntervalSince(wall) * 100)
            }
            percents.sort()
            print(String(format: "BilibiliCPU sidebar out and back (focus %@): min %.1f%%, median %.1f%%", "\(tv.bilibiliStore.sidebarFocused)", percents[0], percents[1]))
        }
    }
}
