import AppKit
import AVFoundation
import ImageIO
import SwiftUI

/// Movies' pictures and what's learnt by opening a video, made lazily and kept small.
///
/// - Pictures live in Mac TV's own folders, never beside the videos: posters and wide pictures in the library's
///   Artwork folder (Application Support), a detail page's scenes in Mac TV's caches. They're stored no bigger than
///   they're drawn, and decoded at the size a card needs, off the main thread, into a cache macOS can empty.
/// - Two kinds of job, one at a time, and only while Movies is on screen (`MovieLibrary.active`):
///   1. **Inspect** a video whose card has just shown (newest first): its tracks (size, HDR, sound), its own title,
///      cover and recording date, Apple's poster for a film when nothing better was found, and a frame for its wide
///      picture. The file is opened once, here.
///   2. **Prepare** the rest in the background: the server's pictures for a Jellyfin item, or the .nfo, poster and
///      fanart beside a file. Cheap reads; nothing is decoded.
/// - Every read of a source has a time limit, so a share that stops answering only costs that one job.
@MainActor
final class MovieArtwork {
    private unowned let library: MovieLibrary
    private let cache = NSCache<NSString, NSImage>()
    /// Videos whose cards showed, to inspect, the newest last.
    private var wanted: [String] = []
    private var running = false
    /// How long one video's job may take before it's given up for now.
    nonisolated(unsafe) static var jobTimeout: Duration = .seconds(30)

    init(library: MovieLibrary) {
        self.library = library
        cache.totalCostLimit = 400_000_000   // bytes of decoded pixels; macOS empties it sooner under pressure
    }

    /// Memory pressure: decoded pictures go; they come back from disk.
    func trim() { cache.removeAllObjects() }

    // MARK: Pictures

    func url(_ file: String) -> URL { library.artworkFolder.appendingPathComponent(file) }

    /// A picture already decoded at this size, or nil.
    func cached(_ file: String, maxPixel: Int) -> NSImage? {
        cache.object(forKey: "\(file)@\(maxPixel)" as NSString)
    }

    /// A picture at this size: from the cache, or decoded now (the Top Shelf, a handful at a time).
    func image(_ file: String, maxPixel: Int) -> NSImage? {
        if let hit = cached(file, maxPixel: maxPixel) { return hit }
        guard let box = Self.decode(url(file), maxPixel: maxPixel) else { return nil }
        return keep(box, file: file, maxPixel: maxPixel)
    }

    /// A picture at this size, decoded off the main thread.
    func load(_ file: String, maxPixel: Int) async -> NSImage? {
        if let hit = cached(file, maxPixel: maxPixel) { return hit }
        let url = url(file)
        guard let box = await Task.detached(priority: .userInitiated, operation: { Self.decode(url, maxPixel: maxPixel) }).value
        else { return nil }
        return keep(box, file: file, maxPixel: maxPixel)
    }

    private func keep(_ box: ImageBox, file: String, maxPixel: Int) -> NSImage {
        let image = NSImage(cgImage: box.image, size: NSSize(width: box.image.width, height: box.image.height))
        cache.setObject(image, forKey: "\(file)@\(maxPixel)" as NSString, cost: box.image.width * box.image.height * 4)
        return image
    }

    /// A picture no bigger than `maxPixel` on its long side, decoded once at that size.
    nonisolated static func decode(_ url: URL, maxPixel: Int) -> ImageBox? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                        kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(ImageBox.init)
    }

    // MARK: Jobs

    /// A video's card is showing: inspect it soon, before the background jobs.
    func want(_ path: String) {
        guard let movie = library.movie(path), movie.inspected != true, !movie.isRemote else { return }
        wanted.removeAll { $0 == path }
        wanted.append(path)
        if wanted.count > 40 { wanted.removeFirst(wanted.count - 40) }
        resume()
    }

    /// Starts the jobs if Movies is on screen and there's something to do; they stop by themselves when there isn't,
    /// or when Movies goes away.
    func resume() {
        guard library.active, !running else { return }
        running = true
        Task { [weak self] in
            while let self, self.library.active, let job = self.nextJob() {
                await self.run(job)
            }
            self?.running = false
        }
    }

    private enum Job { case inspect(Movie), prepare(Movie) }

    private func nextJob() -> Job? {
        while let path = wanted.popLast() {
            if let movie = library.saved.first(where: { $0.path == path }), movie.inspected != true { return .inspect(movie) }
        }
        if let movie = library.saved.first(where: { $0.sidecarChecked != true }) { return .prepare(movie) }
        return nil
    }

    private func run(_ job: Job) async {
        switch job {
        case .prepare(let movie):
            let folder = library.artworkFolder
            if movie.isRemote {
                let server = JellyfinServers.shared.server(for: movie.path)
                let found = await Self.limited { () -> Learnt in
                    var learnt = Learnt()
                    guard let server else { return learnt }
                    if movie.poster == nil, let data = await JellyfinServers.poster(for: movie, on: server) {
                        learnt.poster = Self.store(data, name: Self.name(movie, "poster"), maxPixel: 900, in: folder)
                    }
                    if movie.backdrop == nil, let data = await JellyfinServers.backdrop(for: movie, on: server) {
                        learnt.backdrop = Self.store(data, name: Self.name(movie, "backdrop"), maxPixel: 1920, in: folder)
                    }
                    return learnt
                }
                apply(found, to: movie.path, checked: \.sidecarChecked)
            } else {
                let found = await Self.limited { Self.sidecars(of: movie, into: folder) }
                apply(found, to: movie.path, checked: \.sidecarChecked)
            }
        case .inspect(let movie):
            let folder = library.artworkFolder
            let lookUp = library.lookUpOnline && movie.category == .movie && !library.isHomeVideo(movie.path)
            let found = await Self.limited { await Self.inspect(movie, lookUp: lookUp, into: folder) }
            apply(found, to: movie.path, checked: \.inspected)
        }
    }

    /// What a job found, kept; the job is marked done even when it timed out, so a dead file isn't retried forever
    /// (a refresh that finds it again tries once more).
    private func apply(_ found: Learnt?, to path: String, checked: WritableKeyPath<Movie, Bool?>) {
        library.learnt(path) { movie in
            movie[keyPath: checked] = true
            guard let found else { return }
            if let poster = found.poster, movie.poster == nil { movie.poster = poster; movie.posterChecked = true }
            if let backdrop = found.backdrop, movie.backdrop == nil { movie.backdrop = backdrop }
            if let info = found.info {
                if movie.declared == nil || info.declared != nil {
                    movie.title = info.title ?? movie.title
                    movie.year = info.year ?? movie.year
                    movie.declared = info.declared ?? movie.declared
                    if info.declared == "Episode", let show = info.show, let season = info.season, let number = info.number {
                        movie.show = show
                        movie.season = season
                        movie.number = number
                        movie.episode = "S\(season) E\(number)"
                    }
                }
                movie.overview = info.overview ?? movie.overview
                movie.genre = info.genre ?? movie.genre
                movie.rating = info.rating ?? movie.rating
                movie.cast = info.cast ?? movie.cast
            }
            if let tracks = found.tracks {
                movie.duration = movie.duration ?? tracks.duration
                movie.width = tracks.width ?? movie.width
                movie.height = tracks.height ?? movie.height
                movie.hdr = tracks.hdr ?? movie.hdr
                movie.audio = tracks.audio ?? movie.audio
                movie.codec = tracks.codec ?? movie.codec
                movie.recorded = tracks.recorded ?? movie.recorded
                movie.device = tracks.device ?? movie.device
                // A video's own title, when nothing else named it
                if movie.declared == nil, let title = tracks.title { movie.title = title }
            }
        }
    }

    /// What a job learnt about one video. Sendable: it crosses from the job's thread to the library.
    struct Learnt: Sendable {
        var poster: String?
        var backdrop: String?
        var info: Info?
        var tracks: Tracks?
    }

    struct Info: Sendable {
        var title: String?
        var year: Int?
        var declared: String?
        var show: String?
        var season: Int?
        var number: Int?
        var overview: String?
        var genre: String?
        var rating: String?
        var cast: [Movie.Person]?
    }

    struct Tracks: Sendable {
        var duration: Double?
        var width: Int?
        var height: Int?
        var hdr: String?
        var audio: String?
        var codec: String?
        var title: String?
        var recorded: Date?
        var device: String?
    }

    /// Runs one job off the main thread, giving up after `jobTimeout` (the work itself may still finish later; its
    /// result is dropped).
    nonisolated static func limited<T: Sendable>(_ work: @escaping @Sendable () async -> T) async -> T? {
        let timeout = jobTimeout
        return await withTaskGroup(of: T?.self) { group in
            group.addTask { await Task.detached(priority: .utility) { await work() }.value }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: Beside the file

    /// The .nfo, poster and fanart beside a file (Kodi's names), copied small into Mac TV's own folder. A folder's
    /// own poster.jpg, folder.jpg or fanart.jpg is only this video's when it's the only video there; an episode also
    /// takes its show folder's.
    nonisolated static func sidecars(of movie: Movie, into folder: URL) -> Learnt {
        var learnt = Learnt()
        let file = movie.url, directory = file.deletingLastPathComponent()
        let base = file.deletingPathExtension().lastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let lower = Dictionary(names.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let alone = names.filter { MovieLibrary.extensions.contains(($0 as NSString).pathExtension.lowercased()) }.count == 1
        func beside(_ candidates: [String]) -> URL? {
            for candidate in candidates { if let name = lower[candidate.lowercased()] { return directory.appendingPathComponent(name) } }
            return nil
        }
        let pictures = ["jpg", "jpeg", "png"]
        var posterNames = pictures.flatMap { ["\(base)-poster.\($0)", "\(base).\($0)"] }
        var fanartNames = pictures.map { "\(base)-fanart.\($0)" }
        if alone {
            posterNames += pictures.flatMap { ["poster.\($0)", "folder.\($0)", "cover.\($0)"] }
            fanartNames += pictures.flatMap { ["fanart.\($0)", "backdrop.\($0)"] }
        }
        let nfo = beside(["\(base).nfo"] + (alone ? ["movie.nfo"] : []))
        if let nfo, let data = try? Data(contentsOf: nfo) { learnt.info = NFO.parse(data) }
        if movie.poster == nil, let poster = beside(posterNames), let data = try? Data(contentsOf: poster) {
            learnt.poster = store(data, name: name(movie, "poster"), maxPixel: 900, in: folder)
        }
        if movie.backdrop == nil, let fanart = beside(fanartNames), let data = try? Data(contentsOf: fanart) {
            learnt.backdrop = store(data, name: name(movie, "backdrop"), maxPixel: 1920, in: folder)
        }
        // An episode in "Show/Season 1/": the show's poster and fanart
        if movie.category == .episode || learnt.info?.declared == "Episode", MovieName.seasonNumber(directory.lastPathComponent) != nil {
            let show = directory.deletingLastPathComponent()
            let showNames = (try? FileManager.default.contentsOfDirectory(atPath: show.path)) ?? []
            let showLower = Dictionary(showNames.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
            func inShow(_ candidates: [String]) -> URL? {
                for candidate in candidates { if let name = showLower[candidate] { return show.appendingPathComponent(name) } }
                return nil
            }
            if movie.poster == nil, learnt.poster == nil, let poster = inShow(pictures.flatMap { ["poster.\($0)", "folder.\($0)"] }),
               let data = try? Data(contentsOf: poster) {
                learnt.poster = store(data, name: name(movie, "poster"), maxPixel: 900, in: folder)
            }
            if movie.backdrop == nil, learnt.backdrop == nil, let fanart = inShow(pictures.map { "fanart.\($0)" }),
               let data = try? Data(contentsOf: fanart) {
                learnt.backdrop = store(data, name: name(movie, "backdrop"), maxPixel: 1920, in: folder)
            }
        }
        return learnt
    }

    // MARK: Opening the file

    /// Opens the video once: its tracks, its own title, cover and date, then Apple's poster for a film when there's
    /// still none, and a frame for its wide picture.
    nonisolated static func inspect(_ movie: Movie, lookUp: Bool, into folder: URL) async -> Learnt {
        var learnt = Learnt()
        let matroska = ["mkv", "webm"].contains(movie.url.pathExtension.lowercased())
        var cover: Data?
        if matroska {
            learnt.tracks = matroskaTracks(movie.url)
        } else {
            let read = await assetTracks(movie.url)
            learnt.tracks = read.tracks
            cover = read.cover
        }
        if movie.poster == nil, let cover {
            learnt.poster = store(cover, name: name(movie, "poster"), maxPixel: 900, in: folder)
        }
        if movie.poster == nil, learnt.poster == nil, lookUp, movie.episode == nil,
           let art = await appleArtwork(title: movie.title, year: movie.year),
           let (data, response) = try? await URLSession.shared.data(from: art), (response as? HTTPURLResponse)?.statusCode == 200 {
            learnt.poster = store(data, name: name(movie, "poster"), maxPixel: 900, in: folder)
        }
        if movie.backdrop == nil {
            let fraction = movie.category == .video ? 0.12 : 0.3
            let frame = matroska ? MatroskaPlayback.frame(of: movie.url, at: fraction) : await AVPlayback.frame(of: movie.url, at: fraction)
            if let frame, let data = jpeg(frame) {
                learnt.backdrop = store(data, name: name(movie, "frame"), maxPixel: 1280, in: folder)
            }
        }
        return learnt
    }

    nonisolated static func assetTracks(_ url: URL) async -> (tracks: Tracks, cover: Data?) {
        let asset = AVURLAsset(url: url)
        var tracks = Tracks()
        if let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > 0 {
            tracks.duration = duration.seconds
        }
        if let video = try? await asset.loadTracks(withMediaType: .video).first {
            if let (size, transform) = try? await video.load(.naturalSize, .preferredTransform) {
                let shown = size.applying(transform)
                tracks.width = Int(abs(shown.width))
                tracks.height = Int(abs(shown.height))
            }
            if let format = try? await video.load(.formatDescriptions).first {
                let codec = CMFormatDescriptionGetMediaSubType(format)
                tracks.codec = fourCC(codec)
                if [kCMVideoCodecType_DolbyVisionHEVC, 0x6476_6131 /* dva1 */, 0x6476_6876 /* dvhe */].contains(codec) {
                    tracks.hdr = "Dolby Vision"
                } else if let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String,
                          [kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String,
                           kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String].contains(transfer) {
                    tracks.hdr = "HDR"
                }
            }
        }
        if let audio = try? await asset.loadTracks(withMediaType: .audio).first,
           let format = try? await audio.load(.formatDescriptions).first,
           let description = CMAudioFormatDescriptionGetStreamBasicDescription(format) {
            tracks.audio = channels(Int(description.pointee.mChannelsPerFrame))
        }
        var cover: Data?
        if let metadata = try? await asset.load(.commonMetadata) {
            for item in metadata {
                switch item.commonKey {
                case .commonKeyTitle: tracks.title = (try? await item.load(.stringValue)).flatMap { $0?.isEmpty == false ? $0 : nil }
                case .commonKeyArtwork: cover = try? await item.load(.dataValue)
                case .commonKeyModel: tracks.device = (try? await item.load(.stringValue)) ?? nil
                case .commonKeyCreationDate:
                    if let date = (try? await item.load(.dateValue)) ?? nil { tracks.recorded = date }
                default: break
                }
            }
        }
        if tracks.recorded == nil, let item = (try? await asset.load(.creationDate)) ?? nil,
           let value = (try? await item.load(.dateValue)) ?? nil {
            tracks.recorded = value
        }
        // A title that's only an address ("www.site.com") or the file's own name says nothing
        if let title = tracks.title, title.range(of: #"[A-Za-z0-9-]+\.[A-Za-z]{2,}"#, options: .regularExpression) != nil
            || title == url.deletingPathExtension().lastPathComponent {
            tracks.title = nil
        }
        return (tracks, cover)
    }

    nonisolated static func matroskaTracks(_ url: URL) -> Tracks {
        var tracks = Tracks()
        guard let reader = try? MatroskaReader(url: url) else { return tracks }
        if reader.duration > 0 { tracks.duration = Double(reader.duration) / 1e9 }
        if let video = reader.tracks.first(where: { $0.kind == .video }) {
            tracks.width = video.displayWidth ?? video.width
            tracks.height = video.displayHeight ?? video.height
            tracks.codec = video.codec.contains("HEVC") ? "hvc1" : (video.codec.contains("AVC") ? "avc1" : nil)
        }
        if let audio = reader.tracks.first(where: { $0.kind == .audio && $0.isDefault }) ?? reader.tracks.first(where: { $0.kind == .audio }) {
            tracks.audio = channels(audio.channels)
        }
        return tracks
    }

    nonisolated static func channels(_ count: Int) -> String? {
        switch count {
        case 1: "Mono"
        case 2: "Stereo"
        case 6: "5.1"
        case 8: "7.1"
        default: nil
        }
    }

    private nonisolated static func fourCC(_ code: FourCharCode) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .ascii) ?? ""
    }

    // MARK: Scenes

    /// A detail page's scenes: six frames from through the video, made when the page first opens, kept small in Mac
    /// TV's caches. Each comes back as soon as it's made.
    nonisolated static func scenes(of movie: Movie, count: Int = 6, each: @escaping @MainActor (Int, URL) -> Void) async {
        guard !movie.isRemote, let duration = movie.duration, duration > 30 else { return }
        let folder = BrowserCache.folder("Movies").appendingPathComponent("Scenes", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let matroska = ["mkv", "webm"].contains(movie.url.pathExtension.lowercased())
        for index in 0..<count {
            guard !Task.isCancelled else { return }
            let file = folder.appendingPathComponent("\(hash(movie.key))-\(index).jpg")
            if !FileManager.default.fileExists(atPath: file.path) {
                let fraction = (Double(index) + 0.5) / Double(count)
                let made = await limited { () -> Bool in
                    let frame = matroska ? MatroskaPlayback.frame(of: movie.url, at: fraction) : await AVPlayback.frame(of: movie.url, at: fraction)
                    guard let frame, let data = jpeg(frame, maxPixel: 480) else { return false }
                    return (try? data.write(to: file, options: .atomic)) != nil
                }
                guard made == true else { continue }
            }
            await each(index, file)
        }
    }

    /// Where scene `index` of a video starts, in seconds.
    nonisolated static func sceneTime(_ index: Int, count: Int = 6, duration: Double) -> Double {
        duration * (Double(index) + 0.5) / Double(count)
    }

    // MARK: Storing

    /// A picture's file name in the Artwork folder: the video's key and what it is, so a video keeps its pictures
    /// when it moves.
    nonisolated static func name(_ movie: Movie, _ kind: String) -> String { "\(hash(movie.key))-\(kind).jpg" }

    /// FNV-1a, stable from one launch to the next (Swift's own hash isn't).
    nonisolated static func hash(_ text: String) -> String {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(value, radix: 16)
    }

    /// A picture, made no bigger than `maxPixel` and written as JPEG; its file name, or nil.
    nonisolated static func store(_ data: Data, name: String, maxPixel: Int, in folder: URL) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary), let jpeg = jpeg(image) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard (try? jpeg.write(to: folder.appendingPathComponent(name), options: .atomic)) != nil else { return nil }
        return name
    }

    nonisolated static func jpeg(_ image: CGImage, maxPixel: Int? = nil) -> Data? {
        var image = image
        if let maxPixel, max(image.width, image.height) > maxPixel {
            let scale = Double(maxPixel) / Double(max(image.width, image.height))
            let size = (Int(Double(image.width) * scale), Int(Double(image.height) * scale))
            guard let context = CGContext(data: nil, width: size.0, height: size.1, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: size.0, height: size.1))
            guard let small = context.makeImage() else { return nil }
            image = small
        }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    // MARK: Apple's catalogue

    /// A poster from Apple's movie catalogue, when a film there has exactly this title (and year). The last resort,
    /// for films only, never a Home Videos source.
    nonisolated static func appleArtwork(title: String, year: Int?) async -> URL? {
        guard let term = title.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        let wanted = MovieLibrary.simplified(title)
        let region = Locale.current.region?.identifier.lowercased() ?? "us"
        for country in Set([region, "us"]) {
            guard let url = URL(string: "https://itunes.apple.com/search?term=\(term)&country=\(country)&limit=25"),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let results = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["results"] as? [[String: Any]]
            else { continue }
            let films = results.filter { $0["kind"] as? String == "feature-movie" && MovieLibrary.simplified($0["trackName"] as? String ?? "") == wanted }
            let match = films.first { film in
                guard let year, let released = (film["releaseDate"] as? String)?.prefix(4), let filmYear = Int(released) else { return true }
                return abs(filmYear - year) <= 1
            }
            if let art = match?["artworkUrl100"] as? String {
                return URL(string: art.replacingOccurrences(of: "100x100bb", with: "600x900bb"))
            }
        }
        return nil
    }
}

/// A decoded picture handed from a background thread to the main one.
struct ImageBox: @unchecked Sendable {
    let image: CGImage
}

/// Kodi's .nfo (what tinyMediaManager and Jellyfin write beside a video): title, year, plot, genre, rating, cast,
/// and a show's season and episode.
enum NFO {
    static func parse(_ data: Data) -> MovieArtwork.Info? {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse(), let root = reader.root else { return nil }
        var info = MovieArtwork.Info()
        let values = reader.values
        func value(_ key: String) -> String? { values[key].flatMap { $0.isEmpty ? nil : $0 } }
        info.title = value("title")
        info.year = value("year").flatMap(Int.init) ?? value("premiered").flatMap { Int($0.prefix(4)) }
        info.overview = value("plot") ?? value("outline")
        info.genre = value("genre")
        info.rating = value("mpaa").map { $0.replacingOccurrences(of: "Rated ", with: "") }
        if !reader.cast.isEmpty { info.cast = Array(reader.cast.prefix(12)) }
        switch root {
        case "movie": info.declared = "Movie"
        case "episodedetails":
            info.declared = "Episode"
            info.show = value("showtitle")
            info.season = value("season").flatMap(Int.init)
            info.number = value("episode").flatMap(Int.init)
            if info.show == nil { info.declared = nil }
        default: return nil
        }
        return info
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var root: String?
        var values: [String: String] = [:]
        var cast: [Movie.Person] = []
        private var path: [String] = []
        private var text = ""
        private var actor: Movie.Person?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            if root == nil { root = name.lowercased() }
            path.append(name.lowercased())
            text = ""
            if name.lowercased() == "actor" { actor = Movie.Person(name: "") }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let key = name.lowercased()
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.count >= 2, path[path.count - 2] == "actor" {
                if key == "name" { actor?.name = value }
                if key == "role" { actor?.role = value.isEmpty ? nil : value }
            } else if path.count == 2, values[key] == nil {
                values[key] = value
            }
            if key == "actor", let actor, !actor.name.isEmpty { cast.append(actor) }
            if key == "actor" { actor = nil }
            path.removeLast()
            text = ""
        }
    }
}

/// A Movies picture: shown as soon as it's decoded at the size it's drawn, with `placeholder` until then.
struct MovieImage<Placeholder: View>: View {
    let artwork: MovieArtwork
    let file: String?
    let maxPixel: Int
    @ViewBuilder var placeholder: Placeholder
    @State private var loaded: (file: String, image: NSImage)?

    var body: some View {
        let image = file.flatMap { file in loaded?.file == file ? loaded?.image : artwork.cached(file, maxPixel: maxPixel) }
        ZStack {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .task(id: file) {
            guard let file, artwork.cached(file, maxPixel: maxPixel) == nil else { return }
            if let image = await artwork.load(file, maxPixel: maxPixel), !Task.isCancelled { loaded = (file, image) }
        }
    }
}
