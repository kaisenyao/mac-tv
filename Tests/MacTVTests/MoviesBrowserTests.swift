import AppKit
import Foundation
import Testing
@testable import MacTV

/// The Movies app's library and its screen, against a library in a temporary folder with its own defaults: nothing
/// here reads the Mac's real Movies or Downloads folders, a real share or a server, or the network.
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct MoviesBrowserTests {
    init() {
        _ = NSApplication.shared
        AudioCoordinator.readVolume = { VolumeLevel(level: 50, muted: false) }
    }

    /// A library (and a TV that shows it) in a scratch folder, with its own defaults; both go afterwards.
    private func withTV(_ movies: [Movie] = [], folders: [URL] = [],
                        _ body: (TVController, MovieLibrary, URL) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacTVMovies-\(UUID().uuidString)", isDirectory: true)
        let store = folder.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let suite = "MacTVTests.Movies.\(UUID().uuidString)"
        let defaults = TestDefaults.named(suite)
        defaults.set(folders.map(\.path), forKey: "movieFolders")
        defaults.set(true, forKey: "movieFoldersDownloadsAdded")
        defer {
            TestDefaults.remove(suite)
            try? FileManager.default.removeItem(at: folder)
        }
        try JSONEncoder().encode(movies).write(to: store.appendingPathComponent("library.json"))
        let library = MovieLibrary(folder: store, defaults: defaults)
        let tv = TVController(library: AppLibrary(folder: folder), profiles: ProfileStore(folder: folder),
                              services: AppServices(preferences: Preferences(defaults: defaults), movieLibrary: library))
        tv.remoteCoordinator.pairingStore = PairingStore(folder: folder)
        try await body(tv, library, folder)
        tv.goHome()
    }

    private func film(_ title: String, year: Int = 2020, position: Double? = nil) -> Movie {
        var movie = Movie(path: "/test/Films/\(title) (\(year)).mkv", title: title, year: year, added: .now, size: 1_000_000)
        movie.declared = "Movie"
        movie.duration = 6000
        movie.position = position
        if position != nil { movie.lastWatched = .now }
        return movie
    }

    private func video(_ title: String) -> Movie {
        var movie = Movie(path: "/test/Home/\(title).mp4", title: title, added: .now, size: 5_000_000)
        movie.duration = 240
        return movie
    }

    private func episode(_ show: String, _ season: Int, _ number: Int) -> Movie {
        var movie = Movie(path: "/test/Shows/\(show) S\(season)E\(number).mkv", title: show, episode: "S\(season) E\(number)",
                          added: .now, size: 2_000_000 + Int64(season * 100 + number))
        movie.show = show
        movie.season = season
        movie.number = number
        movie.duration = 2400
        return movie
    }

    // MARK: Names

    @Test func namesTellFilmsEpisodesAndHomeVideosApart() {
        #expect(MovieName("Dune (2021)").release && MovieName("Dune (2021)").year == 2021)
        #expect(MovieName("Dune.2021.1080p.BluRay.x264").release && MovieName("Dune.2021.1080p.BluRay.x264").title == "Dune")
        #expect(!MovieName("Birthday 2019").release)          // a year in a home video's name isn't a film
        #expect(!MovieName("IMG_1234").release && !MovieName("钢琴练习 03").release)
        let episode = MovieName("Show.Name.S01E02.720p")
        #expect(episode.show == "Show Name" && episode.season == 1 && episode.number == 2)
        let crossed = MovieName("Show Name 2x05")
        #expect(crossed.show == "Show Name" && crossed.season == 2 && crossed.number == 5)
        // A "Season 1" folder in a show's folder, and a clear number at the start
        let folder = URL(fileURLWithPath: "/test/Shows/Field Notes (2024)/Season 1", isDirectory: true)
        let numbered = MovieName("03 - Pilot", folder: folder)
        #expect(numbered.show == "Field Notes" && numbered.season == 1 && numbered.number == 3)
        // Without a season folder, a number alone is nothing
        #expect(MovieName("03 - Pilot", folder: URL(fileURLWithPath: "/test/Clips", isDirectory: true)).episode == nil)
        // 1920x1080 is a size, not an episode
        #expect(MovieName("Clip 1920x1080").episode == nil)
    }

    @Test func unrecognisedFilesAreOtherVideosAndAHomeVideosSourceIsAlwaysOtherVideos() async throws {
        let home = URL(fileURLWithPath: "/test/Home", isDirectory: true)
        try await withTV([film("Dune"), video("钢琴练习 03"), episode("Field Notes", 1, 1)], folders: [home]) { _, library, _ in
            #expect(library.films.map(\.title) == ["Dune"])
            #expect(library.videos.map(\.title) == ["钢琴练习 03"])
            #expect(library.shows.map(\.title) == ["Field Notes"])
            // A film-like name in a Home Videos source is a home video, and never looked up
            let named = MovieLibrary.named(Movie(path: "/test/Home/Holiday (2019).mp4", title: "", added: .now, size: 3))
            #expect(MovieLibrary.kind(of: named, homeVideos: false) == .movie)
            #expect(MovieLibrary.kind(of: named, homeVideos: true) == .video)
            library.setHomeVideos(home.path, true)
            #expect(library.isHomeVideo("/test/Home/x.mp4") && !library.isHomeVideo("/test/Homework/x.mp4"))
        }
    }

    @Test func samplesAreSkippedButShortClipsOfYourOwnAreShown() {
        #expect(MovieLibrary.isSample(URL(fileURLWithPath: "/m/Dune/dune-sample.mkv"), size: 40_000_000))
        #expect(MovieLibrary.isSample(URL(fileURLWithPath: "/m/Dune/Sample/dune.mkv"), size: 40_000_000))
        #expect(!MovieLibrary.isSample(URL(fileURLWithPath: "/m/Home/clip.mp4"), size: 3_000_000))
        #expect(!MovieLibrary.isSample(URL(fileURLWithPath: "/m/Home/Sampler Show.mp4"), size: 3_000_000))
        #expect(!MovieLibrary.isSample(URL(fileURLWithPath: "/m/Big/sample.mkv"), size: 4_000_000_000))
    }

    // MARK: Scanning

    @Test func scanningListsFilesWithoutOpeningThemAndAMissingFolderIsUnreachable() async throws {
        try await withTV { _, _, folder in
            let media = folder.appendingPathComponent("Media", isDirectory: true)
            try FileManager.default.createDirectory(at: media.appendingPathComponent("Sample"), withIntermediateDirectories: true)
            try Data(count: 1024).write(to: media.appendingPathComponent("short clip.mp4"))
            try Data(count: 1024).write(to: media.appendingPathComponent("Sample/clip.mkv"))
            try Data("notes".utf8).write(to: media.appendingPathComponent("notes.txt"))
            let found = try #require(await MovieLibrary.list(media, timeout: .seconds(5)))
            #expect(found.map(\.url.lastPathComponent) == ["short clip.mp4"])
            #expect(await MovieLibrary.list(folder.appendingPathComponent("Gone"), timeout: .seconds(5)) == nil)
        }
    }

    /// A file moved inside a source, or a share that came back under another name: the same name and size keep
    /// where you stopped. A source that's offline keeps its videos' history until it's back.
    @Test func progressFollowsAFileThatMovesAndSurvivesAnOfflineShare() async throws {
        try await withTV { _, library, _ in
            let added = Date(timeIntervalSince1970: 1_000_000)
            library.merge([(URL(fileURLWithPath: "/Volumes/Media/Films/Dune (2021).mkv"), added, 9_000)], served: [], missing: [])
            let first = try #require(library.movies.first)
            library.record(position: 1200, duration: 6000, for: first)
            // Mounted again as Media-1, in another folder
            library.merge([(URL(fileURLWithPath: "/Volumes/Media-1/Archive/Dune (2021).mkv"), added, 9_000)], served: [], missing: [])
            #expect(library.movies.count == 1 && library.movies.first?.position == 1200)
            #expect(library.movies.first?.path == "/Volumes/Media-1/Archive/Dune (2021).mkv")
            // The share goes offline: its videos leave the rows but keep their place
            library.merge([], served: [], missing: ["/Volumes/Media-1"])
            #expect(library.movies.isEmpty)
            library.merge([(URL(fileURLWithPath: "/Volumes/Media-1/Archive/Dune (2021).mkv"), added, 9_000)], served: [], missing: [])
            #expect(library.movies.first?.position == 1200 && library.continueWatching.count == 1)
        }
    }

    /// Jellyfin: whichever place is newer wins; an older one here never overwrites the server's.
    @Test func theNewerPlaceWinsBetweenHereAndTheServer() {
        var known = Movie(path: "jellyfin://srv/a", title: "A", added: .now, size: 0)
        known.position = 100
        known.lastWatched = Date(timeIntervalSince1970: 1000)
        var served = known
        served.position = 900
        served.lastWatched = Date(timeIntervalSince1970: 2000)
        #expect(MovieLibrary.update(known, from: served).position == 900)
        known.lastWatched = Date(timeIntervalSince1970: 3000)
        #expect(MovieLibrary.update(known, from: served).position == 100)
        // The server's description comes from the server; the pictures already here stay
        known.poster = "p.jpg"
        served.overview = "Story"
        let merged = MovieLibrary.update(known, from: served)
        #expect(merged.poster == "p.jpg" && merged.overview == "Story")
    }

    @Test func jellyfinItemsCarryTheirKindShowAndWatchedState() {
        let server = JellyfinServers.Server(id: "srv", name: "Living Room", address: "http://127.0.0.1:1", userID: "u", user: "me", on: true)
        let episode: [String: Any] = ["Id": "e1", "Name": "Pilot", "Type": "Episode", "SeriesName": "Field Notes", "IndexNumber": 3,
                                      "ParentIndexNumber": 1, "SeriesId": "s1", "SeriesPrimaryImageTag": "t",
                                      "UserData": ["Played": true], "ParentBackdropItemId": "s1"]
        let movie = JellyfinServers.movie(from: episode, server: server)
        #expect(movie?.declared == "Episode" && movie?.show == "Field Notes" && movie?.number == 3 && movie?.watched == true)
        #expect(movie?.backdropItem == "s1" && movie?.artwork == "s1")
        let other: [String: Any] = ["Id": "v1", "Name": "Holiday", "Type": "Video"]
        #expect(JellyfinServers.movie(from: other, server: server).map { MovieLibrary.kind(of: $0, homeVideos: false) } == .video)
        let film: [String: Any] = ["Id": "m1", "Name": "Dune", "Type": "Movie", "ProductionYear": 2021, "Overview": "Spice",
                                   "Genres": ["Science Fiction"], "OfficialRating": "PG-13",
                                   "People": [["Name": "A Person", "Role": "Paul", "Type": "Actor"]]]
        let dune = JellyfinServers.movie(from: film, server: server)
        #expect(dune?.declared == "Movie" && dune?.genre == "Science Fiction" && dune?.rating == "PG-13")
        #expect(dune?.cast?.first?.role == "Paul")
    }

    // MARK: Watching

    @Test func continueWatchingProgressAndWatchedAreThreeSeparateThings() async throws {
        try await withTV([film("Dune", position: 1200)]) { _, library, _ in
            let path = try #require(library.movies.first?.path)
            #expect(library.continueWatching.count == 1)
            // Remove from Continue Watching: only the row forgets it
            library.dismiss(path)
            #expect(library.continueWatching.isEmpty && library.movie(path)?.position == 1200)
            // Playing it again brings it back
            library.record(position: 1500, duration: 6000, for: try #require(library.movie(path)))
            #expect(library.continueWatching.count == 1)
            // Clear Progress: back to the beginning
            library.clearProgress(path)
            #expect(library.movie(path)?.position == nil && library.continueWatching.isEmpty && library.movie(path)?.isWatched == false)
            // Mark as Watched / Unwatched
            library.setWatched(path, true)
            #expect(library.movie(path)?.isWatched == true)
            library.setWatched(path, false)
            #expect(library.movie(path)?.isWatched == false)
            // Finishing it marks it watched
            library.record(position: 5990, duration: 6000, for: try #require(library.movie(path)))
            #expect(library.movie(path)?.isWatched == true && library.movie(path)?.position == nil)
        }
    }

    @Test func aShowsNextEpisodeIsTheOneInProgressOrTheOneAfterTheLastWatched() async throws {
        var second = episode("Field Notes", 1, 2)
        second.watched = true
        try await withTV([episode("Field Notes", 1, 1), second, episode("Field Notes", 1, 3), episode("Field Notes", 2, 1)]) { _, library, _ in
            let show = try #require(library.shows.first)
            #expect(show.seasons == [1, 2] && show.episodes.count == 4)
            #expect(show.next?.number == 3 && show.next?.season == 1)
            #expect(show.episode(after: try #require(show.next))?.season == 2)
            let started = try #require(show.episodes.first)
            library.record(position: 600, duration: 2400, for: started)
            #expect(library.shows.first?.next?.number == 1)
        }
    }

    // MARK: Pictures and what's beside a file

    @Test func aNfoNamesAFilmAndItsCast() throws {
        let nfo = """
        <?xml version="1.0" encoding="UTF-8"?>
        <movie><title>The Long Coast</title><year>2021</year><plot>A keeper's daughter returns.</plot><genre>Drama</genre>
        <mpaa>Rated PG-13</mpaa><actor><name>Ana Ruiz</name><role>Mara</role></actor><actor><name>Tom Hale</name></actor></movie>
        """
        let info = try #require(NFO.parse(Data(nfo.utf8)))
        #expect(info.title == "The Long Coast" && info.year == 2021 && info.declared == "Movie" && info.rating == "PG-13")
        #expect(info.cast?.map(\.name) == ["Ana Ruiz", "Tom Hale"] && info.cast?.first?.role == "Mara")
        let xml = "<episodedetails><showtitle>Field Notes</showtitle><season>1</season><episode>3</episode></episodedetails>"
        let episode = try #require(NFO.parse(Data(xml.utf8)))
        #expect(episode.declared == "Episode" && episode.show == "Field Notes" && episode.number == 3)
    }

    /// Pictures beside a video are copied, small, into Mac TV's own folder; the media folder isn't touched.
    @Test func picturesBesideAVideoAreReadAndNothingIsWrittenThere() async throws {
        try await withTV { _, library, folder in
            let media = folder.appendingPathComponent("Media/Dune (2021)", isDirectory: true)
            try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
            let file = media.appendingPathComponent("Dune (2021).mkv")
            try Data(count: 64).write(to: file)
            let image = NSImage(size: NSSize(width: 600, height: 900), flipped: false) { rect in
                NSColor.orange.setFill(); rect.fill(); return true
            }
            let tiff = try #require(image.tiffRepresentation)
            let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try png.write(to: media.appendingPathComponent("poster.png"))
            try png.write(to: media.appendingPathComponent("fanart.png"))
            try Data("<movie><title>Dune</title><plot>Spice</plot></movie>".utf8).write(to: media.appendingPathComponent("Dune (2021).nfo"))
            let before = try FileManager.default.contentsOfDirectory(atPath: media.path).sorted()
            let movie = MovieLibrary.named(Movie(path: file.path, title: "", added: .now, size: 64))
            let learnt = MovieArtwork.sidecars(of: movie, into: library.artworkFolder)
            #expect(learnt.info?.overview == "Spice")
            let poster = try #require(learnt.poster), backdrop = try #require(learnt.backdrop)
            #expect(FileManager.default.fileExists(atPath: library.artworkFolder.appendingPathComponent(poster).path))
            #expect(FileManager.default.fileExists(atPath: library.artworkFolder.appendingPathComponent(backdrop).path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: media.path).sorted() == before)
            // Decoded at the size it's drawn
            let small = try #require(library.artwork.image(poster, maxPixel: 300))
            #expect(max(small.size.width, small.size.height) <= 300)
        }
    }

    // MARK: The screen

    @Test func theSidebarShowsOnlySectionsWithSomethingIn() async throws {
        try await withTV([video("Clip")]) { tv, _, _ in
            tv.openMoviesBrowserOnly()
            #expect(tv.movieSidebar == [.search, .home, .videos, .add])
        }
        try await withTV([film("Dune"), episode("Field Notes", 1, 1), video("Clip")]) { tv, _, _ in
            tv.openMoviesBrowserOnly()
            #expect(tv.movieSidebar == [.search, .home, .movies, .shows, .videos, .add])
        }
    }

    @Test func homeHasContinueWatchingThenTheSectionsAcrossEverySource() async throws {
        var served = Movie(path: "jellyfin://srv/m1", title: "Copper Sky", year: 2019, added: .now, size: 0)
        served.declared = "Movie"
        try await withTV([film("Dune", position: 1200), served, episode("Field Notes", 1, 1), video("Clip")]) { tv, _, _ in
            tv.openMoviesBrowserOnly()
            let rows = tv.movieRows
            #expect(rows.map(\.id) == ["continue", "recent", "movies", "shows", "videos"])
            // A file and a server's film side by side in Movies
            #expect(rows[2].items.count == 2)
            #expect(rows[0].style == .wide && rows[2].style == .poster && rows[4].style == .wide)
        }
    }

    @Test func anEmptyLibraryOffersTheThreeWaysToAddASource() async throws {
        try await withTV { tv, _, _ in
            tv.openMoviesBrowserOnly()
            #expect(tv.movieRows.map(\.style) == [.buttons])
            tv.handleMovies(.move(.right))
            tv.handleMovies(.select)
            #expect(tv.movies?.shareForm == ShareForm())   // Add Network Share…
            tv.handleMovies(.back)
            tv.handleMovies(.move(.right))
            tv.handleMovies(.select)
            #expect(tv.movies?.shareForm?.jellyfin == true)
        }
    }

    /// The sidebar, as 哔哩哔哩's: Left from the first card opens it, Up and Down move its highlight, the page
    /// follows when the highlight rests, and Right or Back closes it on that page.
    @Test func theSidebarOpensFromTheFirstCardAndTheSectionFollowsItsHighlight() async throws {
        try await withTV([film("Dune"), film("Arrival"), video("Clip")]) { tv, _, _ in
            tv.openMoviesBrowserOnly()
            tv.handleMovies(.move(.right))
            tv.handleMovies(.move(.left))
            #expect(tv.movies?.focus == .rows)
            tv.handleMovies(.move(.left))
            #expect(tv.movies?.focus == .sidebar && tv.movies?.sidebarSection == .home)
            #expect(tv.moviesModule(horizontal: true) == .drawer && tv.moviesModule(horizontal: false) == .picker)
            tv.handleMovies(.move(.down))
            #expect(tv.movies?.sidebarSection == .movies && tv.movies?.section == .home)   // not yet
            tv.handleMovies(.move(.right))
            #expect(tv.movies?.section == .movies && tv.movies?.focus == .rows)
            // A section's grid: Left and Right pick, Up reaches its sort choices
            #expect(tv.movieRows.first?.style == .posterGrid)
            #expect(tv.moviesModule(horizontal: true) == .picker && tv.moviesModule(horizontal: false) == .drawer)
            tv.handleMovies(.move(.up))
            #expect(tv.movies?.focus == .header)
            tv.handleMovies(.move(.right))
            #expect(tv.movies?.sorts[.movies] == 1)
            tv.handleMovies(.move(.down))
            #expect(tv.focusedMovieEntry == .movie("/test/Films/Arrival (2020).mkv"))   // by title now
            // Back from a section: Home
            tv.handleMovies(.back)
            #expect(tv.movies?.section == .home)
        }
    }

    @Test func theSidebarsHighlightSettlesIntoThePageAfterAMoment() async throws {
        try await withTV([film("Dune"), video("Clip")]) { tv, _, _ in
            tv.openMoviesBrowserOnly()
            tv.openMovieSidebar()
            tv.handleMovies(.move(.down))
            #expect(tv.movies?.section == .home)
            let deadline = Date().addingTimeInterval(3)
            while tv.movies?.section != .movies, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            #expect(tv.movies?.section == .movies && tv.movies?.focus == .sidebar)
        }
    }

    /// Back at Movies' top level is the Home Screen, with Movies kept in the background where it was.
    @Test func backAtTheTopGoesHomeAndMoviesStaysInTheBackground() async throws {
        try await withTV([film("Dune"), film("Arrival"), video("Clip")]) { tv, _, _ in
            let app = try #require(Catalog.services.first { $0.kind == .movies })
            tv.open(app)
            tv.handle(.move(.down))
            #expect(tv.movies?.row == 1)
            tv.handle(.back)                 // Home's lower rows: back to the first
            #expect(tv.movies?.row == 0 && tv.movies != nil)
            tv.handle(.back)                 // at the top: the Home Screen
            #expect(tv.movies == nil && tv.backgroundApps.map(\.id) == ["movies"])
            tv.open(app)
            #expect(tv.movies != nil)
        }
    }

    /// Select opens the page; Play/Pause plays at once. The page's buttons follow where you are in it.
    @Test func aPagesButtonsArePlayOrResumeAndStartOver() async throws {
        try await withTV([film("Dune", position: 1200), film("Arrival")]) { tv, library, _ in
            tv.openMoviesBrowserOnly()
            tv.handleMovies(.select)   // Continue Watching's Dune
            let page = try #require(tv.movies?.page)
            #expect(page.target == .movie("/test/Films/Dune (2020).mkv"))
            #expect(tv.moviePageButtons(page) == [.resume, .startOver, .watched, .more])
            #expect(tv.moviesModule(horizontal: true) == .picker)
            library.setWatched("/test/Films/Dune (2020).mkv", true)
            #expect(tv.moviePageButtons(page) == [.play, .watched, .more])
            tv.handleMovies(.back)
            #expect(tv.movies?.page == nil)
        }
    }

    @Test func aShowsPageHasItsSeasonsAndEpisodesAndAnEpisodeOpensItsOwnPage() async throws {
        try await withTV([episode("Field Notes", 1, 1), episode("Field Notes", 1, 2), episode("Field Notes", 2, 1)]) { tv, _, _ in
            tv.openMoviesBrowserOnly()
            tv.handleMovies(.select)   // Recently Added: the show
            let page = try #require(tv.movies?.page)
            #expect(page.target == .show("fieldnotes"))
            #expect(tv.moviePageRows(page) == [.buttons, .seasons, .episodes])
            tv.handleMovies(.move(.down))
            tv.handleMovies(.move(.right))   // Season 2
            #expect(tv.movies?.page?.season == 1)
            tv.handleMovies(.move(.down))
            #expect(tv.moviesModule(horizontal: true) == .strip)
            tv.handleMovies(.select)
            #expect(tv.movies?.pages.count == 2 && tv.movies?.page?.target == .movie("/test/Shows/Field Notes S2E1.mkv"))
            tv.handleMovies(.back)
            #expect(tv.movies?.pages.count == 1)
        }
    }

    /// Hold Select: the card's menu; the same again closes it. A source's menu asks before removing, Cancel first,
    /// and removing a folder leaves its files where they are.
    @Test func holdSelectOpensMenusAndRemovingASourceAsksFirstAndKeepsItsFiles() async throws {
        try await withTV { tv, library, folder in
            let media = folder.appendingPathComponent("Media", isDirectory: true)
            try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
            try Data(count: 64).write(to: media.appendingPathComponent("clip.mp4"))
            library.folders = [media]
            library.merge([(media.appendingPathComponent("clip.mp4"), .now, 64)], served: [], missing: [])
            tv.openMoviesBrowserOnly()
            #expect(tv.openHoldMenu())
            #expect(tv.movies?.menu?.target == .movie(media.appendingPathComponent("clip.mp4").path))
            #expect(tv.closeHoldMenu() && tv.movies?.menu == nil)
            // The source in the sidebar
            tv.openMovieSidebar()
            for _ in 0..<10 where tv.movies?.sidebarSection != .source(media.path) { tv.handleMovies(.move(.down)) }
            #expect(tv.movies?.sidebarSection == .source(media.path))
            #expect(tv.openHoldMenu())
            let menu = try #require(tv.movies?.menu)
            #expect(tv.moviesMenuItems(menu) == [.rescan, .homeVideos, .remove])
            tv.handleMovies(.move(.down))
            tv.handleMovies(.select)   // Home Videos
            #expect(library.isHomeVideos(media.path) && tv.movies?.menu != nil)
            tv.handleMovies(.move(.down))
            tv.handleMovies(.select)   // Remove…
            #expect(tv.movies?.menu?.confirming == true && tv.movies?.menu?.index == 0)
            tv.handleMovies(.select)   // Cancel
            #expect(tv.movies?.menu?.confirming == false && library.folders == [media])
            tv.handleMovies(.select)   // Remove…
            tv.handleMovies(.move(.down))
            tv.handleMovies(.select)   // Remove
            #expect(library.folders.isEmpty && tv.movies?.menu == nil)
            #expect(FileManager.default.fileExists(atPath: media.appendingPathComponent("clip.mp4").path))
        }
    }

    @Test func searchFindsTitlesFileNamesAndFolders() async throws {
        try await withTV([film("Dune"), film("Arrival"), video("Coast walk")]) { tv, _, _ in
            tv.openMoviesBrowserOnly()
            tv.tapMovieSidebar(.search)
            #expect(tv.movies?.focus == .header)
            tv.handleMovies(.select)
            #expect(tv.movies?.typing == true)
            tv.handleMovies(.text("coast"))
            #expect(tv.movieRows.map(\.id) == ["s-videos"])
            for _ in 0..<5 { tv.handleMovies(.deleteBackward) }
            tv.handleMovies(.text("films\n"))   // a folder's name
            #expect(tv.movies?.typing == false && tv.movies?.focus == .rows)
            #expect(tv.movieRows.first?.items.count == 2)
        }
    }

    /// Nothing runs in the background: the jobs need Movies on screen, and stop when it goes.
    @Test func backgroundWorkOnlyRunsWhileMoviesIsOnScreen() async throws {
        try await withTV([video("Clip")]) { tv, library, _ in
            #expect(!library.active)
            tv.openMoviesBrowserOnly()
            tv.flashMovies("x")
            #expect(tv.moviesWork.pressed == "x")
            tv.goHome()
            #expect(tv.movies == nil)
            tv.quitApp("movies", reason: "test")
            #expect(tv.moviesWork.pressTask == nil && tv.moviesWork.sidebarCommit == nil && tv.moviesWork.scenesTask == nil)
        }
    }
}
