import AppKit
import AVFoundation

/// A video file on the Mac, or a movie or episode on a Jellyfin server.
struct Movie: Codable, Identifiable, Hashable {
    /// What a video is, from what's known about it: a film, an episode of a show, or anything else (a home video, a
    /// clip, a file nothing recognises). Unrecognised files are always `.video`: never guessed into Movies.
    enum Kind: String, Codable { case movie, episode, video }

    struct Person: Codable, Hashable {
        var name: String
        var role: String?
    }

    var path: String
    var title: String
    var year: Int?
    /// "S1 E2", for episodes.
    var episode: String?
    var added: Date
    var size: Int64
    /// The poster's file name in the Artwork folder.
    var poster: String?
    /// True once a poster has been looked for, found or not.
    var posterChecked = false
    var duration: Double?
    /// Where playback stopped, in seconds; nil once finished.
    var position: Double?
    var lastWatched: Date?
    /// The Jellyfin server it's on; nil for a file.
    var server: String?
    /// The server item whose picture is the poster (an episode's show).
    var artwork: String?

    // Everything below is optional, so a library.json from before reads as it was.

    /// Set when the library has classified it (see MovieLibrary.classify).
    var kind: Kind?
    /// The show, season and episode number of an episode.
    var show: String?
    var season: Int?
    var number: Int?
    /// What a server or a .nfo says the item is ("Movie", "Episode", "Video"), or "Movie" for a release-style name.
    var declared: String?
    var overview: String?
    var genre: String?
    /// The content rating ("PG-13").
    var rating: String?
    var cast: [Person]?
    /// A wide picture (fanart, the server's backdrop, or a frame from the video) in the Artwork folder.
    var backdrop: String?
    /// The server item whose backdrop to fetch.
    var backdropItem: String?
    /// The files beside it (or the server's pictures) have been looked at.
    var sidecarChecked: Bool?
    /// The file itself has been opened once: its tracks, its own title and cover, a frame.
    var inspected: Bool?
    var width: Int?
    var height: Int?
    /// "HDR", "Dolby Vision".
    var hdr: String?
    /// "5.1", "7.1", "Stereo".
    var audio: String?
    var codec: String?
    /// When it was recorded (a phone video's own date), and on what.
    var recorded: Date?
    var device: String?
    /// The person watching has seen it to the end, or marked it watched.
    var watched: Bool?
    /// Taken out of Continue Watching by hand; it comes back the next time it's played.
    var dismissed: Bool?

    var id: String { path }
    var isRemote: Bool { path.hasPrefix(JellyfinServers.scheme) }
    var url: URL { URL(fileURLWithPath: path) }
    var displayTitle: String { episode.map { "\(show ?? title) · \($0)" } ?? title }
    var category: Kind { kind ?? .video }
    var isWatched: Bool { watched == true }
    /// A picture taller than it is wide: a phone held upright.
    var isPortrait: Bool { (height ?? 0) > (width ?? 0) }

    /// Partly watched: more than a minute in, and not at the end credits.
    var inProgress: Bool {
        guard let position, position > 60 else { return false }
        guard let duration, duration > 0 else { return true }
        return position < duration * 0.95
    }

    /// Who it is whatever its path: a file moved within a source, or a share mounted somewhere else, is the same file
    /// (its name and size). A server's item is its path.
    var key: String { isRemote ? path : "\(url.lastPathComponent.lowercased())|\(size)" }
}

/// Persists the watched folders and adds Downloads once for existing installations.
struct MovieFolderPreferences {
    private let defaults: UserDefaults
    private let movies: URL
    private let downloads: URL
    private let foldersKey = "movieFolders"
    private let migrationKey = "movieFoldersDownloadsAdded"

    init(defaults: UserDefaults = .standard, movies: URL, downloads: URL) {
        self.defaults = defaults
        self.movies = movies.standardizedFileURL
        self.downloads = downloads.standardizedFileURL
    }

    var folders: [URL] {
        get {
            var paths = defaults.stringArray(forKey: foldersKey)
                ?? [movies.path]
            if !defaults.bool(forKey: migrationKey) {
                if !paths.contains(where: { URL(fileURLWithPath: $0).standardizedFileURL.path == downloads.path }) {
                    paths.append(downloads.path)
                }
                defaults.set(paths, forKey: foldersKey)
                defaults.set(true, forKey: migrationKey)
            }
            return paths.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        }
        nonmutating set {
            defaults.set(newValue.map { $0.standardizedFileURL.path }, forKey: foldersKey)
            defaults.set(true, forKey: migrationKey)
        }
    }
}

/// Where one profile after the first stopped in a movie (the first profile's is in the library itself), and whether
/// they've seen it. Kept by the movie's key (see Movie.key), so it follows a file that moves.
struct MoviePlace: Codable, Equatable, Sendable {
    var position: Double?
    var lastWatched: Date?
    var watched: Bool?
    var dismissed: Bool?
}

/// A place Movies finds videos: a folder on the Mac or a drive, a network share, or a Jellyfin server.
struct MovieSource: Identifiable, Equatable {
    enum Kind: Equatable { case folder, drive, share, jellyfin }
    /// The folder's path, or the server's "jellyfin://<id>".
    let id: String
    let name: String
    let kind: Kind
    /// Why it can't be reached right now ("Offline"), or nil.
    var offline: String?
    /// Home videos: never looked up online, always in Other Videos.
    var homeVideos: Bool

    var symbol: String {
        switch kind {
        case .folder: "folder.fill"
        case .drive: "externaldrive.fill"
        case .share: "externaldrive.connected.to.line.below.fill"
        case .jellyfin: "server.rack"
        }
    }

    /// A video at this path is in this source.
    func contains(_ path: String) -> Bool {
        path.hasPrefix(id.hasSuffix("/") ? id : id + "/")
    }
}

/// The sources marked Home Videos, the same for everyone (like the folders).
struct MovieSourcePreferences {
    var defaults: UserDefaults = .standard
    private let key = "movieHomeVideoSources"

    var homeVideos: Set<String> {
        get { Set(defaults.stringArray(forKey: key) ?? []) }
        nonmutating set { defaults.set(newValue.sorted(), forKey: key) }
    }
}

/// A show: its episodes from every source, by season.
struct MovieShow: Identifiable, Equatable {
    let id: String
    let title: String
    var episodes: [Movie]

    var seasons: [Int] { Array(Set(episodes.map { $0.season ?? 1 })).sorted() }
    func episodes(in season: Int) -> [Movie] { episodes.filter { ($0.season ?? 1) == season } }
    var added: Date { episodes.map(\.added).max() ?? .distantPast }
    var year: Int? { episodes.compactMap(\.year).min() }
    var watched: Bool { episodes.allSatisfy(\.isWatched) }
    var poster: String? { episodes.lazy.compactMap(\.poster).first }
    var backdrop: String? { episodes.lazy.compactMap(\.backdrop).first }
    var overview: String? { episodes.lazy.compactMap(\.overview).first }

    /// What Resume or Play opens: the episode in progress watched last, or else the first one not yet seen after the
    /// last one watched; the first episode when nothing's been watched.
    var next: Movie? {
        if let current = episodes.filter(\.inProgress).max(by: { ($0.lastWatched ?? .distantPast) < ($1.lastWatched ?? .distantPast) }) {
            return current
        }
        if let last = episodes.lastIndex(where: \.isWatched) {
            return episodes[(last + 1)...].first { !$0.isWatched } ?? episodes.first { !$0.isWatched } ?? episodes.first
        }
        return episodes.first
    }

    /// The episode after this one, for Autoplay Next Episode.
    func episode(after movie: Movie) -> Movie? {
        guard let index = episodes.firstIndex(where: { $0.path == movie.path }), index + 1 < episodes.count else { return nil }
        return episodes[index + 1]
    }
}

/// The videos in the sources you choose (the Movies and Downloads folders to begin with, network shares and Jellyfin
/// servers), kept in ~/Library/Application Support/Mac TV/Movies. Nothing is ever written in a source: pictures and
/// what's learnt about a video stay in Mac TV's own folders.
///
/// Adding a source only lists its files. What's beside a video (a .nfo, a poster, fanart) is read in the background,
/// one video at a time, while Movies is open; the file itself is opened only when its card first shows or its page
/// opens (see MovieArtwork). Pictures come, best first, from Jellyfin, the files beside the video, the video's own
/// cover, Apple's catalogue (films only, never a Home Videos source) and finally a frame of the video.
///
/// The library is this Mac's, the same for everyone; where you stopped is each profile's own. The first profile's
/// places stay in library.json as they always have; another profile's are in movie-positions.json in its own folder,
/// laid over the library while they're watching.
@MainActor
final class MovieLibrary: ObservableObject {
    static let shared = MovieLibrary()

    nonisolated static let extensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv", "flv", "ts", "m2ts", "mts", "mpg", "mpeg", "3gp"]

    /// The library with the places of the person watching.
    @Published private(set) var movies: [Movie] = [] { didSet { reindex() } }
    /// What the screen asks for over and over, worked out once each time the library changes.
    private var byPath: [String: Int] = [:]
    private var showIndex: [String: Int] = [:]
    /// Goes up every time the library changes: views that take values instead of watching it redraw on it.
    private(set) var revision = 0
    private(set) var films: [Movie] = []
    private(set) var videos: [Movie] = []
    private(set) var shows: [MovieShow] = []
    private(set) var continueWatching: [Movie] = []
    /// Folders and servers that didn't answer at the last look (a source shows Offline from this, never from asking a
    /// share that might not answer).
    @Published private(set) var unreachable: Set<String> = []
    /// The library as saved, with the first profile's places.
    private var library: [Movie] = [] { didSet { publish() } }
    /// Another profile's places while they're watching, by key; nil for the first profile.
    private var places: [String: MoviePlace]?
    private var placesFile: URL?
    @Published private(set) var scanning = false

    let folder: URL
    var artworkFolder: URL { folder.appendingPathComponent("Posters", isDirectory: true) }
    private var listFile: URL { folder.appendingPathComponent("library.json") }
    private var offlineFile: URL { folder.appendingPathComponent("offline.json") }
    /// A refresh asked for while one was running, done when it finishes.
    private var refreshAgain = false
    /// Videos on a drive, share or server that isn't there right now, kept with where you stopped so they come back
    /// as they were.
    private var offline: [Movie] = []
    /// Movies is on screen: the background work only runs then (see MovieArtwork).
    var active = false { didSet { if active, !oldValue { artwork.resume() } } }
    /// Whether Mac TV may ask the network about a video (Apple's catalogue). Off in a test run.
    var lookUpOnline = !SystemGuard.fake
    private(set) lazy var artwork = MovieArtwork(library: self)
    private let sourcePreferences: MovieSourcePreferences
    /// The folders to look in.
    private let defaults: UserDefaults

    /// `folder` is the Mac TV folder's Movies; tests use their own, and their own defaults.
    init(folder: URL = AppFolder.url.appendingPathComponent("Movies", isDirectory: true), defaults: UserDefaults = .standard) {
        self.folder = folder
        self.defaults = defaults
        sourcePreferences = MovieSourcePreferences(defaults: defaults)
        try? FileManager.default.createDirectory(at: artworkFolder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: listFile), let saved = try? JSONDecoder().decode([Movie].self, from: data) {
            library = saved.map { classify(Self.named($0)) }
        }
        if let data = try? Data(contentsOf: offlineFile), let saved = try? JSONDecoder().decode([Movie].self, from: data) {
            offline = saved
        }
        publish()   // setting `library` in here doesn't run its didSet
    }

    // MARK: Each profile's places

    /// Someone else is watching: their places from now on (none yet for a new profile).
    func use(_ space: ProfileSpace) {
        if space.isMain {
            places = nil
            placesFile = nil
        } else {
            let file = space.folder.appendingPathComponent("movie-positions.json")
            placesFile = file
            places = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: MoviePlace].self, from: $0) } ?? [:]
        }
        publish()
    }

    private func publish() {
        guard let places else { movies = library; return }
        movies = library.map { movie in
            var shown = movie
            let place = places[movie.key] ?? places[movie.path]
            shown.position = place?.position
            shown.lastWatched = place?.lastWatched
            shown.watched = place?.watched
            shown.dismissed = place?.dismissed
            return shown
        }
    }

    private func savePlaces() {
        guard let places, let placesFile else { return }
        Log.movies.attempt("Saving where you stopped") {
            try FileManager.default.createDirectory(at: placesFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(places).write(to: placesFile, options: .atomic)
        }
    }

    /// Changes the person watching's place in a movie: in the library for the first profile, in their own places for
    /// another.
    private func changePlace(_ path: String, _ change: (inout MoviePlace) -> Void) {
        guard let index = library.firstIndex(where: { $0.path == path }) else { return }
        let movie = library[index]
        if places != nil {
            var place = places?[movie.key] ?? places?[movie.path] ?? MoviePlace()
            change(&place)
            places?[movie.path] = nil
            places?[movie.key] = place
            savePlaces()
            publish()
        } else {
            var place = MoviePlace(position: movie.position, lastWatched: movie.lastWatched, watched: movie.watched,
                                   dismissed: movie.dismissed)
            change(&place)
            var changed = movie
            changed.position = place.position
            changed.lastWatched = place.lastWatched
            changed.watched = place.watched
            changed.dismissed = place.dismissed
            library[index] = changed
        }
        save()
    }

    // MARK: Folders and sources

    private var folderPreferences: MovieFolderPreferences {
        MovieFolderPreferences(defaults: defaults, movies: Self.systemFolder(.moviesDirectory, fallback: "Movies"),
                               downloads: Self.systemFolder(.downloadsDirectory, fallback: "Downloads"))
    }

    /// The folders Mac TV looks in.
    var folders: [URL] {
        get { folderPreferences.folders }
        set {
            folderPreferences.folders = newValue
            objectWillChange.send()
        }
    }

    /// Folders worth offering: the usual places, drives, and any you chose yourself.
    var suggestedFolders: [URL] {
        var list = [Self.systemFolder(.moviesDirectory, fallback: "Movies"),
                    Self.systemFolder(.downloadsDirectory, fallback: "Downloads"),
                    Self.home("Desktop"), Self.home("Documents")].map(\.standardizedFileURL)
        let volumes = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: [.volumeIsInternalKey],
            options: .skipsHiddenFiles)) ?? []
        list += volumes.filter { (try? $0.resourceValues(forKeys: [.volumeIsInternalKey]).volumeIsInternal) != true }
        for share in NetworkShares.shared.shares {
            if let folder = share.folder, !list.contains(folder) { list.append(folder) }
        }
        for chosen in folders where !list.contains(chosen) { list.append(chosen) }
        return list
    }

    func isWatched(_ folder: URL) -> Bool { folders.contains(folder.standardizedFileURL) }

    func toggle(_ folder: URL) {
        var list = folders
        let folder = folder.standardizedFileURL
        if let index = list.firstIndex(of: folder) { list.remove(at: index) } else { list.append(folder) }
        folders = list
        refresh()
    }

    func add(_ folder: URL) {
        let folder = folder.standardizedFileURL
        guard !folders.contains(folder) else { return }
        folders = folders + [folder]
        refresh()
    }

    /// A share came back mounted somewhere else ("Media-1"): the folder it was watched under moves with it, so its
    /// videos (and where you stopped in them) carry on.
    func move(_ old: URL, to new: URL) {
        let old = old.standardizedFileURL, new = new.standardizedFileURL
        guard old != new, let index = folders.firstIndex(of: old) else { return }
        var list = folders
        list[index] = new
        folders = list
        if sourcePreferences.homeVideos.contains(old.path) {
            sourcePreferences.homeVideos = sourcePreferences.homeVideos.subtracting([old.path]).union([new.path])
        }
        refresh()
    }

    /// Every source Movies looks in, in the order the sidebar lists them: folders and drives, shares, servers.
    var sources: [MovieSource] {
        let shares = NetworkShares.shared, servers = JellyfinServers.shared
        let home = sourcePreferences.homeVideos
        var local: [MovieSource] = [], network: [MovieSource] = []
        for folder in folders {
            if let share = shares.share(for: folder) {
                let status = shares.status[share.id]
                network.append(MovieSource(id: folder.path, name: share.name, kind: .share,
                                           offline: status == .connected ? nil : (status?.text ?? "Offline"),
                                           homeVideos: home.contains(folder.path)))
            } else {
                let drive = folder.path.hasPrefix("/Volumes/")
                let missing = unreachable.contains(folder.path)
                local.append(MovieSource(id: folder.path, name: FileManager.default.displayName(atPath: folder.path),
                                         kind: drive ? .drive : .folder, offline: missing ? "Not Connected" : nil,
                                         homeVideos: home.contains(folder.path)))
            }
        }
        for server in servers.servers where server.on {
            let id = JellyfinServers.scheme + server.id
            let status = servers.status[server.id]
            let offline: String? = switch status {
            case .offline: status?.text
            default: nil
            }
            network.append(MovieSource(id: id, name: server.name, kind: .jellyfin, offline: offline, homeVideos: home.contains(id)))
        }
        return local + network
    }

    func source(_ id: String) -> MovieSource? { sources.first { $0.id == id } }
    func source(of movie: Movie) -> MovieSource? { sources.first { $0.contains(movie.path) } }

    /// Marks a source as Home Videos, or not: its videos move between Other Videos and the other sections, and a Home
    /// Videos source is never looked up online.
    func setHomeVideos(_ id: String, _ on: Bool) {
        var set = sourcePreferences.homeVideos
        if on { set.insert(id) } else { set.remove(id) }
        sourcePreferences.homeVideos = set
        library = library.map(classify)
        save()
    }

    func isHomeVideos(_ id: String) -> Bool { sourcePreferences.homeVideos.contains(id) }

    /// Takes a source out of Movies. Nothing in it is touched: a folder stays on disk, a share stays connected, and a
    /// server keeps its library.
    func removeSource(_ id: String) {
        if id.hasPrefix(JellyfinServers.scheme) {
            JellyfinServers.shared.remove(String(id.dropFirst(JellyfinServers.scheme.count)))
        } else if let share = NetworkShares.shared.share(for: URL(fileURLWithPath: id, isDirectory: true)) {
            NetworkShares.shared.remove(share.id)
        } else {
            let folder = URL(fileURLWithPath: id, isDirectory: true)
            if isWatched(folder) { toggle(folder) }
        }
        sourcePreferences.homeVideos = sourcePreferences.homeVideos.subtracting([id])
    }

    nonisolated static func systemFolder(_ directory: FileManager.SearchPathDirectory, fallback: String) -> URL {
        // A test run never looks in the real Movies and Downloads folders.
        if SystemGuard.fake { return home(fallback) }
        return FileManager.default.urls(for: directory, in: .userDomainMask).first ?? home(fallback)
    }

    private nonisolated static func home(_ name: String) -> URL {
        if SystemGuard.fake { return AppFolder.url.appendingPathComponent("Test Home/\(name)", isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(name, isDirectory: true)
    }

    // MARK: Scanning

    /// How long a source has to list its files before it counts as unreachable this time.
    nonisolated(unsafe) static var scanTimeout: Duration = .seconds(20)

    /// Looks through the folders and servers again, keeping what's known about videos still there. Each source is
    /// listed on its own, so a slow or dead share never holds up the others (or the screen).
    func refresh() {
        guard !scanning else { refreshAgain = true; return }
        scanning = true
        let roots = folders
        let servers = JellyfinServers.shared.servers.filter(\.on)
        let timeout = Self.scanTimeout
        Task {
            async let remote = JellyfinServers.movies(on: servers)
            var found: [(url: URL, added: Date, size: Int64)] = []
            var missing: [String] = []
            for root in roots {
                if let files = await Self.list(root, timeout: timeout) { found += files } else { missing.append(root.path) }
            }
            let (served, unreachable) = await remote
            self.merge(found, served: served, missing: missing + unreachable)
        }
    }

    /// A folder's video files, or nil when it isn't there or doesn't answer in time.
    nonisolated static func list(_ root: URL, timeout: Duration) async -> [(url: URL, added: Date, size: Int64)]? {
        let listing = Task.detached(priority: .utility) { () -> [(url: URL, added: Date, size: Int64)]? in
            guard FileManager.default.fileExists(atPath: root.path) else { return nil }
            return scan(root)
        }
        return await withTaskGroup(of: [(url: URL, added: Date, size: Int64)]?.self) { group in
            group.addTask { await listing.value }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Every video under a folder. Nothing is opened: a name, a size and a date each.
    nonisolated static func scan(_ root: URL) -> [(url: URL, added: Date, size: Int64)] {
        var found: [(URL, Date, Int64)] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .addedToDirectoryDateKey, .creationDateKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        for case let file as URL in walker where extensions.contains(file.pathExtension.lowercased()) {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            guard size > 0, !isSample(file, size: size) else { continue }
            found.append((file, values.addedToDirectoryDate ?? values.creationDate ?? .distantPast, size))
        }
        return found
    }

    /// A release's sample clip ("movie-sample.mkv", a "Sample" folder): small, and named so. A short clip of your own
    /// is shown, whatever its size.
    nonisolated static func isSample(_ file: URL, size: Int64) -> Bool {
        guard size < 300_000_000 else { return false }
        let name = file.deletingPathExtension().lastPathComponent.lowercased()
        let folder = file.deletingLastPathComponent().lastPathComponent.lowercased()
        return folder == "sample" || folder == "samples"
            || name.range(of: #"(^|[\s._\-\[(])sample($|[\s._\-\])])"#, options: .regularExpression) != nil
    }

    /// `missing` are folders that aren't there and servers that didn't answer, as path prefixes.
    func merge(_ found: [(url: URL, added: Date, size: Int64)], served: [Movie], missing: [String]) {
        let known = Dictionary((library + offline).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        // A file that moved, or a share mounted under a new name: the same name and size is the same file.
        let byKey = Dictionary((library + offline).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let missingPrefixes = missing.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        unreachable = Set(missing)
        let foundPaths = Set(found.map(\.url.path) + served.map(\.path))
        let files = found.map { file -> Movie in
            if var movie = known[file.url.path] {
                movie.size = file.size
                return Self.named(movie)
            }
            let fresh = Self.named(Movie(path: file.url.path, title: "", added: file.added, size: file.size))
            if var moved = byKey[fresh.key], !foundPaths.contains(moved.path) {
                moved.path = fresh.path
                return moved
            }
            return fresh
        }
        let foundKeys = Set(files.map(\.key))
        // A drive unplugged, a share offline or a server that's down: set its videos aside, don't forget them.
        offline = known.values.filter { movie in
            !foundPaths.contains(movie.path) && !foundKeys.contains(movie.key) && missingPrefixes.contains { movie.path.hasPrefix($0) }
        }
        // On the Mac running the server (or one with its own copy), the file plays here directly.
        let local = Set(files.map(Self.matchKey))
        let fromServers = served.filter { !local.contains(Self.matchKey($0)) }
        library = (files + fromServers.map { Self.update(known[$0.path], from: $0) }).map(classify)
            .sorted { $0.added != $1.added ? $0.added > $1.added : $0.title < $1.title }
        scanning = false
        save()
        artwork.resume()
        if refreshAgain {
            refreshAgain = false
            refresh()
        }
    }

    /// A local file's title, show and episode from its name and folders, unless a .nfo has said better.
    nonisolated static func named(_ movie: Movie) -> Movie {
        guard !movie.isRemote, movie.sidecarChecked != true || movie.title.isEmpty else { return movie }
        var movie = movie
        let name = MovieName(movie.url)
        if movie.declared == nil || movie.declared == "Movie" || movie.title.isEmpty {
            movie.title = name.title
            movie.year = name.year ?? movie.year
            movie.episode = name.episode
            movie.show = name.show
            movie.season = name.season
            movie.number = name.number
            movie.declared = name.release ? "Movie" : nil
        }
        return movie
    }

    /// A server's item as the server describes it now, keeping the pictures already here and whichever place you
    /// stopped at is newer: watched here, or in another Jellyfin app. An older place here never overwrites a newer one
    /// on the server.
    nonisolated static func update(_ known: Movie?, from served: Movie) -> Movie {
        guard let known else { return served }
        var movie = served
        movie.poster = known.poster
        movie.posterChecked = known.posterChecked || served.posterChecked
        movie.backdrop = known.backdrop
        movie.sidecarChecked = known.sidecarChecked
        movie.inspected = known.inspected
        movie.width = known.width ?? served.width
        movie.height = known.height ?? served.height
        movie.hdr = known.hdr ?? served.hdr
        movie.audio = known.audio ?? served.audio
        movie.dismissed = known.dismissed
        if (known.lastWatched ?? .distantPast) > (served.lastWatched ?? .distantPast) {
            movie.position = known.position
            movie.lastWatched = known.lastWatched
            movie.watched = known.watched
        }
        return movie
    }

    /// Sorts a video into Movies, TV Shows or Other Videos from what's known for sure: a server or a .nfo saying so,
    /// a clear episode name, a release-style name. Anything else, and everything in a Home Videos source, is a video.
    func classify(_ movie: Movie) -> Movie {
        var movie = movie
        movie.kind = Self.kind(of: movie, homeVideos: isHomeVideo(movie.path))
        return movie
    }

    nonisolated static func kind(of movie: Movie, homeVideos: Bool) -> Movie.Kind {
        if homeVideos { return .video }
        if movie.episode != nil, movie.declared != "Movie" || movie.show != nil { return .episode }
        return movie.declared == "Movie" ? .movie : .video
    }

    func isHomeVideo(_ path: String) -> Bool {
        sourcePreferences.homeVideos.contains { id in path.hasPrefix(id.hasSuffix("/") ? id : id + "/") }
    }

    // MARK: What Movies shows

    /// Movies and Other Videos, newest first, and the shows, from every source; Continue Watching.
    private func reindex() {
        revision &+= 1
        byPath = Dictionary(movies.enumerated().map { ($1.path, $0) }, uniquingKeysWith: { first, _ in first })
        films = movies.filter { $0.category == .movie }
        videos = movies.filter { $0.category == .video }
        shows = Self.shows(movies)
        showIndex = Dictionary(shows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        continueWatching = movies.filter { $0.inProgress && $0.dismissed != true }
            .sorted { ($0.lastWatched ?? .distantPast) > ($1.lastWatched ?? .distantPast) }
    }

    /// Shows, newest first, their episodes in order. Every source's episodes of a show are one show.
    private static func shows(_ movies: [Movie]) -> [MovieShow] {
        var groups: [String: MovieShow] = [:]
        var order: [String] = []
        for movie in movies where movie.category == .episode {
            let title = movie.show ?? movie.title
            let id = simplified(title)
            if groups[id] == nil { groups[id] = MovieShow(id: id, title: title, episodes: []); order.append(id) }
            groups[id]?.episodes.append(movie)
        }
        return order.compactMap { id in
            groups[id].map { show in
                var show = show
                show.episodes.sort { ($0.season ?? 1, $0.number ?? 0) < ($1.season ?? 1, $1.number ?? 0) }
                return show
            }
        }
        .sorted { $0.added > $1.added }
    }

    func show(_ id: String) -> MovieShow? { showIndex[id].map { shows[$0] } }

    /// A row's movie or show.
    func movie(_ entry: MoviesEntry) -> Movie? { if case .movie(let path) = entry { movie(path) } else { nil } }
    func show(_ entry: MoviesEntry) -> MovieShow? { if case .show(let id) = entry { show(id) } else { nil } }
    func show(of movie: Movie) -> MovieShow? { movie.category == .episode ? show(Self.simplified(movie.show ?? movie.title)) : nil }

    /// The Movies app's Top Shelf: what you're watching, then what's newest, that has a picture (a wide one first).
    /// Only names: the Top Shelf decodes the one it shows (see MovieArtwork.image).
    var shelf: [(path: String, file: String)] {
        var seen = Set<String>()
        var list: [(path: String, file: String)] = []
        for movie in continueWatching + movies where list.count < 8 && seen.insert(movie.path).inserted {
            guard let file = movie.backdrop ?? movie.poster else { continue }
            list.append((movie.path, file))
        }
        return list
    }

    /// Added in the last month, newest first.
    var recentlyAdded: [Movie] {
        let since = Date().addingTimeInterval(-30 * 24 * 3600)
        return movies.filter { $0.added > since }
    }

    func movie(_ path: String) -> Movie? { byPath[path].map { movies[$0] } }

    /// Titles, file names and folders that contain every word typed.
    func search(_ query: String) -> [Movie] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return movies.filter { movie in
            let haystack = [movie.title, movie.show ?? "", movie.isRemote ? "" : movie.path].joined(separator: " ").lowercased()
            return words.allSatisfy(haystack.contains)
        }
    }

    // MARK: Watching

    /// Where the person watching stopped. Finishing marks it watched; playing it brings it back to Continue Watching.
    func record(position: Double, duration: Double, for movie: Movie) {
        guard let index = library.firstIndex(where: { $0.path == movie.path }) else { return }
        let finished = duration > 0 && position >= duration * 0.95
        if duration > 0, library[index].duration != duration { library[index].duration = duration }
        changePlace(movie.path) { place in
            place.position = finished ? nil : position
            place.lastWatched = Date()
            place.dismissed = nil
            if finished { place.watched = true }
        }
        if library[index].isRemote { JellyfinServers.shared.progress(library[index], at: position, paused: false) }
    }

    /// Mark as Watched / Mark as Unwatched. Watched clears where you stopped, as finishing does.
    func setWatched(_ path: String, _ watched: Bool) {
        changePlace(path) { place in
            place.watched = watched ? true : nil
            if watched { place.position = nil }
            place.lastWatched = Date()
        }
        if let movie = library.first(where: { $0.path == path }), movie.isRemote {
            JellyfinServers.shared.setPlayed(movie, watched)
        }
    }

    /// Remove from Continue Watching: only that row forgets it; where you stopped stays.
    func dismiss(_ path: String) {
        changePlace(path) { $0.dismissed = true }
    }

    /// Clear Progress: back to the beginning, as if never started.
    func clearProgress(_ path: String) {
        changePlace(path) { place in
            place.position = nil
            place.dismissed = nil
        }
        if let movie = library.first(where: { $0.path == path }), movie.isRemote {
            JellyfinServers.shared.clearPosition(movie)
        }
    }

    private func save() {
        let library = library, offline = offline, listFile = listFile, offlineFile = offlineFile
        Log.movies.attempt("Saving the movie list") {
            try JSONEncoder().encode(library).write(to: listFile, options: .atomic)
            try JSONEncoder().encode(offline).write(to: offlineFile, options: .atomic)
        }
    }

    /// What the background work learnt about a video, kept.
    func learnt(_ path: String, _ change: (inout Movie) -> Void) {
        guard let index = library.firstIndex(where: { $0.path == path }) else { return }
        var movie = library[index]
        change(&movie)
        guard movie != library[index] else { return }
        library[index] = classify(movie)
        save()
    }

    /// The saved library, for the background work (MovieArtwork) to pick its next job from.
    var saved: [Movie] { library }

    /// The same film or episode, wherever it comes from.
    nonisolated static func matchKey(_ movie: Movie) -> String {
        "\(simplified(movie.show ?? movie.title))|\(movie.year ?? 0)|\(movie.episode ?? "")"
    }

    nonisolated static func simplified(_ title: String) -> String {
        title.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

/// A file name tidied into a title: "www.site.com - Dorothy (2026) Tamil 1080p x264.mkv" → Dorothy, 2026, a release;
/// "Show.Name.S01E02.720p.mkv" or "Show 1x02.mkv" → Show Name, S1 E2; "Season 1/03 - Pilot.mkv" in a show's folder →
/// that show, S1 E3. A name that isn't clearly one of these (a home video, "IMG_1234") stays as it is.
struct MovieName {
    var title: String
    var year: Int?
    var episode: String?
    var show: String?
    var season: Int?
    var number: Int?
    /// Named like a film's release: a year in brackets, a dotted name with a year, or quality tags.
    var release = false

    init(_ file: URL) {
        self.init(file.deletingPathExtension().lastPathComponent, folder: file.deletingLastPathComponent())
    }

    init(_ fileName: String, folder: URL? = nil) {
        var name = fileName
        // Leading release-site tags: "www.example.com - ", "[Group] ".
        name = name.replacingOccurrences(of: #"^\s*(www\.\S+|\[[^\]]*\])\s*[-–:]?\s*"#, with: "", options: .regularExpression)
        let dotted = !name.contains(" ") && name.contains(".")
        if dotted { name = name.replacingOccurrences(of: ".", with: " ") }
        name = name.replacingOccurrences(of: "_", with: " ")

        // S01E02, or 1x02
        if let match = Self.match(#"^(.*?)[\s\-]*(?:\b[Ss](\d{1,2})[\s\-]?[Ee](\d{1,3})|\b(\d{1,2})x(\d{2,3})\b)"#, in: name) {
            let season = Int(match[2].isEmpty ? match[4] : match[2]) ?? 1
            let number = Int(match[3].isEmpty ? match[5] : match[3]) ?? 0
            var show = Self.trim(match[1])
            if show.isEmpty, let folder { show = Self.showFolder(folder) ?? "" }
            if !show.isEmpty {
                title = show
                self.show = show
                self.season = season
                self.number = number
                episode = "S\(season) E\(number)"
                return
            }
        }
        // A "Season 2" folder in a show's folder, and a clear episode number at the start of the name
        if let folder, let season = Self.seasonNumber(folder.lastPathComponent), let show = Self.showFolder(folder),
           let match = Self.match(#"(?i)^(?:e|ep|episode)?\s*(\d{1,3})(?:\s*[-–.]\s+|\s+|$)"#, in: name), let number = Int(match[1]) {
            title = show
            self.show = show
            self.season = season
            self.number = number
            episode = "S\(season) E\(number)"
            return
        }
        let quality = #"(?i)\b(2160p|1080p|720p|576p|480p|4k|uhd|x264|x265|h\.?264|h\.?265|hevc|web[- ]?dl|webrip|bluray|brrip|bdrip|hdrip|dvdrip|predvd|hdtv|hdcam|aac|ac3|ddp?5|10bit|remux)\b"#
        let tagged = name.range(of: quality, options: .regularExpression) != nil
        if let match = Self.match(#"^(.+?)[\s(\[]+((?:19|20)\d{2})(?:[)\]\s]|$)"#, in: name), !Self.trim(match[1]).isEmpty {
            title = Self.trim(match[1])
            year = Int(match[2])
            // "Birthday 2019" is a home video; "Dune (2021)", "Dune.2021.mkv" and "Dune 2021 1080p" are releases
            let bracketed = fileName.range(of: #"[(\[]\s*(?:19|20)\d{2}\s*[)\]]"#, options: .regularExpression) != nil
            release = bracketed || dotted || tagged
            return
        }
        if let range = name.range(of: quality, options: .regularExpression), !Self.trim(String(name[..<range.lowerBound])).isEmpty {
            name = String(name[..<range.lowerBound])
        }
        title = Self.trim(name)
        release = tagged
        if title.isEmpty { title = fileName }
    }

    /// "Season 2", "Season 02", "S2", "Specials" (season 0).
    static func seasonNumber(_ folder: String) -> Int? {
        if folder.lowercased() == "specials" { return 0 }
        guard let match = match(#"(?i)^(?:season|s)\s*(\d{1,2})$"#, in: folder.trimmingCharacters(in: .whitespaces)) else { return nil }
        return Int(match[1])
    }

    /// The show a season folder belongs to: its parent's name, without a year.
    private static func showFolder(_ folder: URL) -> String? {
        guard seasonNumber(folder.lastPathComponent) != nil else { return nil }
        let show = folder.deletingLastPathComponent()
        let name = show.lastPathComponent
            .replacingOccurrences(of: #"\s*[(\[]\s*(?:19|20)\d{2}\s*[)\]]\s*$"#, with: "", options: .regularExpression)
        let trimmed = trim(name)
        return trimmed.isEmpty || trimmed == "/" ? nil : trimmed
    }

    private static func trim(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: " -–([{.,:"))
    }

    private static func match(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<result.numberOfRanges).map { index in
            Range(result.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
