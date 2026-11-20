import AppKit
import SwiftUI

/// Where you are in the Movies app: a section from the sidebar (Search, Home, Movies, TV Shows, Other Videos, a
/// source), the focus in it, and what's open over it (a movie's or a show's page, a menu, Add Source). A value, so
/// Home keeps it exactly as it was while Movies is in the background.
struct MoviesBrowser: Equatable {
    enum Section: Hashable {
        case search, home, movies, shows, videos
        /// A source, by its id (a folder's path, "jellyfin://<server>").
        case source(String)
        /// Add Source: the sidebar's last item; choosing it opens the panel, it's never a page.
        case add
    }

    enum Focus: Hashable {
        /// The sidebar is open, its highlight on `sidebarSection`.
        case sidebar
        /// The sort choices, or the search field.
        case header
        case rows
    }

    var section: Section = .home
    /// The sidebar's highlight. It moves at once; the page changes when it stops (see MoviesWork.sidebarCommit).
    var sidebarSection: Section = .home
    var focus: Focus = .rows
    var row = 0
    /// The column in each row, by row id, so a row keeps its place.
    var columns: [String: Int] = [:]
    /// Each section's sort choice.
    var sorts: [Section: Int] = [:]
    var query = ""
    /// The search field has the keyboard.
    var typing = false
    /// A movie's or a show's page, over the section; more than one when a show's episode is open.
    var pages: [Page] = []
    var menu: Menu?
    /// The Add Source panel, and its focused row.
    var adding: Int?
    /// Adding a network share or a Jellyfin server, over Add Source.
    var shareForm: ShareForm?

    var page: Page? {
        get { pages.last }
        set {
            guard let newValue else { if !pages.isEmpty { pages.removeLast() }; return }
            if pages.isEmpty { pages = [newValue] } else { pages[pages.count - 1] = newValue }
        }
    }

    struct Page: Equatable {
        enum Target: Hashable { case movie(String), show(String) }
        var target: Target
        /// 0 is the buttons; the page's other rows follow (see TVController.moviePageRows).
        var row = 0
        var button = 0
        /// A show's season, by index.
        var season = 0
        var columns: [Int: Int] = [:]
    }

    struct Menu: Equatable {
        enum Target: Equatable { case movie(String), source(String) }
        var target: Target
        var index = 0
        /// Remove…: asking first, Cancel focused.
        var confirming = false
    }
}

/// The TV's Add Network Share and Add Jellyfin Server form, typed with the keyboard or the phone's Type on TV.
struct ShareForm: Equatable {
    var jellyfin = false
    /// 0 address, 1 user name, 2 password, 3 Connect.
    var row = 0
    var address = ""
    var user = ""
    var password = ""
    /// Why the share or server couldn't be added.
    var message: String?
    var connecting = false
}

/// One thing in a row: a video, a show, or one of the empty page's buttons.
enum MoviesEntry: Hashable {
    case movie(String)
    case show(String)
    /// Add Folder…, Add Network Share…, Add Jellyfin Server…
    case add(Int)
}

/// A row on a Movies page.
struct MoviesRow: Equatable {
    enum Style: Equatable {
        /// 16:9 cards that scroll (Continue Watching, Other Videos)
        case wide
        /// 2:3 posters that scroll
        case poster
        /// One line of a grid of posters, or of 16:9 cards
        case posterGrid, wideGrid
        /// The empty library's buttons
        case buttons
    }

    let id: String
    let title: String?
    let style: Style
    let items: [MoviesEntry]
    /// Cards show where you stopped.
    var progress = false

    var isGrid: Bool { style == .posterGrid || style == .wideGrid }
}

/// The Movies app's moving parts that aren't state worth keeping: a press's dip, the sidebar's settle and a page's
/// scenes being made. Nothing here runs unless a press or a page started it.
@MainActor
final class MoviesWork: ObservableObject {
    /// What was just pressed, dipped for a moment.
    @Published var pressed: String?
    /// A detail page's scenes as they're made.
    @Published var scenes: [Int: NSImage] = [:]
    var scenesFor: String?
    var pressTask: Task<Void, Never>?
    var sidebarCommit: Task<Void, Never>?
    var scenesTask: Task<Void, Never>?

    func stop() {
        pressTask?.cancel()
        sidebarCommit?.cancel()
        scenesTask?.cancel()
        pressTask = nil
        sidebarCommit = nil
        scenesTask = nil
    }
}

extension TVController {
    static let moviePosterColumns = 6
    static let movieWideColumns = 4
    /// How long the sidebar's highlight rests before the page changes.
    static let movieSidebarSettle: Duration = .milliseconds(250)

    // MARK: Opening

    func openMovies() {
        movies = MoviesBrowser()
        movieLibrary.refresh()
    }

    /// The library under a movie that started from elsewhere (the phone).
    func openMoviesBrowserOnly() { movies = MoviesBrowser() }

    // MARK: The sidebar

    /// The sidebar's sections, then the sources, then Add Source. A section with nothing in it isn't there.
    var movieSidebar: [MoviesBrowser.Section] {
        let library = movieLibrary
        var list: [MoviesBrowser.Section] = [.search, .home]
        if library.movies.contains(where: { $0.category == .movie }) { list.append(.movies) }
        if library.movies.contains(where: { $0.category == .episode }) { list.append(.shows) }
        if library.movies.contains(where: { $0.category == .video }) { list.append(.videos) }
        return list + library.sources.map { .source($0.id) } + [.add]
    }

    // MARK: Pages

    /// The sort choices on a section's page.
    static func movieSorts(_ section: MoviesBrowser.Section) -> [String] {
        switch section {
        case .movies: ["Recently Added", "Title", "Year", "Unwatched"]
        case .shows, .videos: ["Recently Added", "Title"]
        default: []
        }
    }

    /// The rows of the section showing.
    var movieRows: [MoviesRow] {
        movieRows(for: movies ?? MoviesBrowser())
    }

    func movieRows(for browser: MoviesBrowser) -> [MoviesRow] {
        let library = movieLibrary
        let sort = browser.sorts[browser.section] ?? 0
        switch browser.section {
        case .home:
            guard !library.movies.isEmpty else {
                return [MoviesRow(id: "add", title: nil, style: .buttons, items: [.add(0), .add(1), .add(2)])]
            }
            var rows: [MoviesRow] = []
            let limit = 20
            let started = library.continueWatching.prefix(limit)
            if !started.isEmpty {
                rows.append(MoviesRow(id: "continue", title: "Continue Watching", style: .wide,
                                      items: started.map { .movie($0.path) }, progress: true))
            }
            let since = Date().addingTimeInterval(-30 * 24 * 3600)
            let shows = library.shows
            let recent: [(Date, MoviesEntry)] = library.films.filter { $0.added > since }.map { ($0.added, .movie($0.path)) }
                + shows.filter { $0.added > since }.map { ($0.added, .show($0.id)) }
            if !recent.isEmpty {
                rows.append(MoviesRow(id: "recent", title: "Recently Added", style: .poster,
                                      items: recent.sorted { $0.0 > $1.0 }.prefix(limit).map(\.1)))
            }
            let films = library.films
            if !films.isEmpty { rows.append(MoviesRow(id: "movies", title: "Movies", style: .poster, items: films.prefix(limit).map { .movie($0.path) })) }
            if !shows.isEmpty { rows.append(MoviesRow(id: "shows", title: "TV Shows", style: .poster, items: shows.prefix(limit).map { .show($0.id) })) }
            let videos = library.videos
            if !videos.isEmpty { rows.append(MoviesRow(id: "videos", title: "Other Videos", style: .wide, items: videos.prefix(limit).map { .movie($0.path) })) }
            return rows
        case .movies:
            var films = library.films
            switch sort {
            case 1: films.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            case 2: films.sort { ($0.year ?? 0, $0.title) > ($1.year ?? 0, $1.title) }
            case 3: films = films.filter { !$0.isWatched }
            default: break
            }
            return Self.grid(films.map { .movie($0.path) }, style: .posterGrid)
        case .shows:
            var shows = library.shows
            if sort == 1 { shows.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
            return Self.grid(shows.map { .show($0.id) }, style: .posterGrid)
        case .videos:
            var videos = library.videos
            if sort == 1 { videos.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
            return Self.grid(videos.map { .movie($0.path) }, style: .wideGrid)
        case .search:
            let found = library.search(browser.query)
            var rows: [MoviesRow] = []
            let films = found.filter { $0.category == .movie }
            if !films.isEmpty { rows.append(MoviesRow(id: "s-movies", title: "Movies", style: .poster, items: films.map { .movie($0.path) })) }
            let showIDs = Set(found.filter { $0.category == .episode }.map { MovieLibrary.simplified($0.show ?? $0.title) })
            let shows = library.shows.filter { showIDs.contains($0.id) }
            if !shows.isEmpty { rows.append(MoviesRow(id: "s-shows", title: "TV Shows", style: .poster, items: shows.map { .show($0.id) })) }
            let videos = found.filter { $0.category == .video }
            if !videos.isEmpty { rows.append(MoviesRow(id: "s-videos", title: "Other Videos", style: .wide, items: videos.map { .movie($0.path) })) }
            return rows
        case .source(let id):
            return sourceRows(id)
        case .add:
            return []
        }
    }

    /// A source's page: a row for each folder at its top (the videos right in it first); a server's by kind.
    private func sourceRows(_ id: String) -> [MoviesRow] {
        let library = movieLibrary
        guard let source = library.source(id) else { return [] }
        let inside = library.movies.filter { source.contains($0.path) }
        if source.kind == .jellyfin {
            var rows: [MoviesRow] = []
            let films = inside.filter { $0.category == .movie }
            if !films.isEmpty { rows.append(MoviesRow(id: "src-movies", title: "Movies", style: .poster, items: films.map { .movie($0.path) })) }
            let showIDs = Set(inside.filter { $0.category == .episode }.map { MovieLibrary.simplified($0.show ?? $0.title) })
            let shows = library.shows.filter { showIDs.contains($0.id) }
            if !shows.isEmpty { rows.append(MoviesRow(id: "src-shows", title: "TV Shows", style: .poster, items: shows.map { .show($0.id) })) }
            let videos = inside.filter { $0.category == .video }
            if !videos.isEmpty { rows.append(MoviesRow(id: "src-videos", title: "Other Videos", style: .wide, items: videos.map { .movie($0.path) })) }
            return rows
        }
        let prefix = id.hasSuffix("/") ? id : id + "/"
        var groups: [String: [Movie]] = [:]
        for movie in inside {
            let rest = movie.path.dropFirst(prefix.count)
            let folder = rest.contains("/") ? String(rest.split(separator: "/").first ?? "") : ""
            groups[folder, default: []].append(movie)
        }
        return groups.keys.sorted { $0.isEmpty ? true : ($1.isEmpty ? false : $0.localizedStandardCompare($1) == .orderedAscending) }
            .map { folder in
                let items = groups[folder] ?? []
                let posters = items.allSatisfy { $0.category == .movie }
                return MoviesRow(id: "src-\(folder)", title: folder.isEmpty ? source.name : folder, style: posters ? .poster : .wide,
                                 items: items.map { .movie($0.path) })
            }
    }

    static func grid(_ items: [MoviesEntry], style: MoviesRow.Style) -> [MoviesRow] {
        let columns = style == .posterGrid ? moviePosterColumns : movieWideColumns
        return stride(from: 0, to: items.count, by: columns).map { start in
            MoviesRow(id: "grid-\(start / columns)", title: nil, style: style, items: Array(items[start..<min(start + columns, items.count)]))
        }
    }

    /// The focused row and column, kept inside the rows as they change; nil when there's nothing.
    var movieFocus: (row: Int, column: Int)? {
        guard let browser = movies else { return nil }
        return Self.movieFocus(browser, rows: movieRows(for: browser))
    }

    static func movieFocus(_ browser: MoviesBrowser, rows: [MoviesRow]) -> (row: Int, column: Int)? {
        guard !rows.isEmpty else { return nil }
        let row = min(browser.row, rows.count - 1)
        let column = min(browser.columns[rows[row].id] ?? 0, rows[row].items.count - 1)
        return (row, max(0, column))
    }

    /// What has focus in the rows, if they have it.
    var focusedMovieEntry: MoviesEntry? {
        guard let focus = movieFocus else { return nil }
        return movieRows[focus.row].items[focus.column]
    }

    // MARK: A movie's or a show's page

    enum MoviePageButton: Hashable { case play, resume, startOver, watched, more }

    /// The page's buttons: Play (or Resume and Start Over), Mark as Watched, More.
    func moviePageButtons(_ page: MoviesBrowser.Page) -> [MoviePageButton] {
        switch page.target {
        case .movie(let path):
            guard let movie = movieLibrary.movie(path) else { return [] }
            return (movie.inProgress ? [.resume, .startOver] : [.play]) + [.watched, .more]
        case .show(let id):
            return [movieLibrary.show(id)?.next?.inProgress == true ? .resume : .play, .more]
        }
    }

    enum MoviePageRow: Hashable { case buttons, scenes, seasons, episodes }

    /// The page's rows that take focus, top to bottom.
    func moviePageRows(_ page: MoviesBrowser.Page) -> [MoviePageRow] {
        switch page.target {
        case .movie(let path):
            // Scenes once the page has made some (a file that can't be read has none)
            guard moviesWork.scenesFor == path, !moviesWork.scenes.isEmpty else { return [.buttons] }
            return [.buttons, .scenes]
        case .show(let id):
            guard let show = movieLibrary.show(id) else { return [.buttons] }
            return show.seasons.count > 1 ? [.buttons, .seasons, .episodes] : [.buttons, .episodes]
        }
    }

    func movieShowSeason(_ page: MoviesBrowser.Page, _ show: MovieShow) -> Int {
        let seasons = show.seasons
        return seasons.isEmpty ? 1 : seasons[min(page.season, seasons.count - 1)]
    }

    /// Opens a movie's or a show's page.
    func openMoviePage(_ target: MoviesBrowser.Page.Target) {
        var page = MoviesBrowser.Page(target: target)
        if case .show(let id) = target, let show = movieLibrary.show(id), let next = show.next {
            // The season and episode Play would open
            page.season = show.seasons.firstIndex(of: next.season ?? 1) ?? 0
            let episodes = show.episodes(in: next.season ?? 1)
            page.columns[2] = episodes.firstIndex { $0.path == next.path } ?? 0
        }
        withAnimation(Motion.navigate) { movies?.pages.append(page) }
        if case .movie(let path) = target { makeScenes(path) }
    }

    /// The page's scenes, made now if they aren't yet (only for this page, and only while it's open).
    private func makeScenes(_ path: String) {
        let work = moviesWork
        work.scenesTask?.cancel()
        work.scenes = [:]
        work.scenesFor = path
        guard let movie = movieLibrary.movie(path), !movie.isRemote else { return }
        movieLibrary.artwork.want(path)
        let library = movieLibrary
        work.scenesTask = Task { @MainActor [weak work, weak library] in
            // The duration comes from opening the file; wait for it a moment if this is the first time
            var movie = movie
            for _ in 0..<20 where movie.duration == nil {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                movie = library?.movie(path) ?? movie
            }
            await MovieArtwork.scenes(of: movie) { index, url in
                guard work?.scenesFor == path else { return }
                work?.scenes[index] = NSImage(contentsOf: url)
            }
        }
    }

    // MARK: Input

    func handleMovies(_ command: RemoteCommand) {
        guard let browser = movies else { return }
        if browser.shareForm != nil { handleShareForm(command); return }
        if browser.menu != nil { handleMoviesMenu(command); return }
        if browser.adding != nil { handleAddSource(command); return }
        if browser.page != nil { handleMoviePage(command); return }
        if browser.typing { handleMovieTyping(command); return }
        switch browser.focus {
        case .sidebar: handleMovieSidebar(command)
        case .header: handleMovieHeader(command)
        case .rows: handleMovieRows(command)
        }
    }

    private func handleMovieRows(_ command: RemoteCommand) {
        guard var browser = movies else { return }
        let rows = movieRows(for: browser)
        guard let focus = movieFocus else {
            // Nothing on this page: Left is the sidebar, Up the header
            switch command {
            case .move(.left): openMovieSidebar()
            case .move(.up) where hasMovieHeader(browser.section): withAnimation(Motion.focus) { movies?.focus = .header }
            case .back: movieBack()
            default: break
            }
            return
        }
        let row = rows[focus.row]
        switch command {
        case .move(.left):
            if focus.column > 0 { setMovieColumn(focus.column - 1, in: row) } else { openMovieSidebar() }
        case .move(.right):
            if focus.column < row.items.count - 1 { setMovieColumn(focus.column + 1, in: row) }
        case .move(.up):
            if focus.row > 0 {
                setMovieRow(focus.row - 1, from: row, column: focus.column, rows: rows)
            } else if hasMovieHeader(browser.section) {
                withAnimation(Motion.focus) { movies?.focus = .header }
            }
        case .move(.down):
            if focus.row < rows.count - 1 { setMovieRow(focus.row + 1, from: row, column: focus.column, rows: rows) }
        case .select:
            flashMovies(movieFocusID)
            activateMovieEntry(row.items[focus.column])
        case .playPause:
            playMovieEntry(row.items[focus.column])
        case .back:
            movieBack()
        case .text(let text) where browser.section == .search:
            browser.query += text.replacingOccurrences(of: "\n", with: "")
            browser.row = 0
            movies = browser
        default: break
        }
    }

    private func setMovieColumn(_ column: Int, in row: MoviesRow) {
        withAnimation(row.isGrid ? Motion.focus : BiliMotion.step()) { movies?.columns[row.id] = column }
    }

    /// Up or Down a row. In a grid the column carries over; a row that scrolls keeps its own place.
    private func setMovieRow(_ index: Int, from row: MoviesRow, column: Int, rows: [MoviesRow]) {
        let next = rows[index]
        withAnimation(Motion.navigate) {
            movies?.row = index
            if row.isGrid && next.isGrid || next.style == .buttons {
                movies?.columns[next.id] = min(column, next.items.count - 1)
            }
        }
    }

    private func hasMovieHeader(_ section: MoviesBrowser.Section) -> Bool {
        section == .search || !Self.movieSorts(section).isEmpty
    }

    private func handleMovieHeader(_ command: RemoteCommand) {
        guard let browser = movies else { return }
        let section = browser.section
        if section == .search {
            switch command {
            case .move(.left): openMovieSidebar()
            case .move(.down): if !movieRows.isEmpty { withAnimation(Motion.focus) { movies?.focus = .rows; movies?.row = 0 } }
            case .select: flashMovies("search"); withAnimation(Motion.focus) { movies?.typing = true }
            case .text, .deleteBackward:
                movies?.typing = true
                handleMovieTyping(command)
            case .back: movieBack()
            default: break
            }
            return
        }
        let sorts = Self.movieSorts(section)
        let sort = browser.sorts[section] ?? 0
        switch command {
        case .move(.left):
            if sort > 0 { setMovieSort(sort - 1) } else { openMovieSidebar() }
        case .move(.right):
            if sort < sorts.count - 1 { setMovieSort(sort + 1) }
        case .move(.down), .select:
            if case .select = command { flashMovies("sort-\(sort)") }
            if !movieRows.isEmpty { withAnimation(Motion.focus) { movies?.focus = .rows; movies?.row = 0 } }
        case .back: movieBack()
        default: break
        }
    }

    /// The sort chosen as focus moves onto it, as 哔哩哔哩's sort choices do.
    private func setMovieSort(_ sort: Int) {
        guard let section = movies?.section else { return }
        withAnimation(Motion.focus) {
            movies?.sorts[section] = sort
            movies?.columns = movies?.columns.filter { !$0.key.hasPrefix("grid-") } ?? [:]
        }
    }

    private func handleMovieTyping(_ command: RemoteCommand) {
        switch command {
        case .text(let text):
            let typed = text.replacingOccurrences(of: "\n", with: "")
            movies?.query += typed
            movies?.row = 0
            if text.hasSuffix("\n") { finishMovieTyping() }
        case .deleteBackward:
            if movies?.query.isEmpty == false { movies?.query.removeLast() }
            movies?.row = 0
        case .select: finishMovieTyping()
        case .back: withAnimation(Motion.focus) { movies?.typing = false }
        case .move(.down): finishMovieTyping()
        case .move(.left): withAnimation(Motion.focus) { movies?.typing = false }; openMovieSidebar()
        default: break
        }
    }

    /// Return in the search field: the results, if there are any.
    func finishMovieTyping() {
        withAnimation(Motion.focus) {
            movies?.typing = false
            if !movieRows.isEmpty { movies?.focus = .rows; movies?.row = 0 }
        }
    }

    // MARK: Sidebar

    func openMovieSidebar() {
        guard let section = movies?.section else { return }
        withAnimation(Motion.focus) {
            movies?.sidebarSection = section
            movies?.focus = .sidebar
            movies?.typing = false
        }
    }

    private func handleMovieSidebar(_ command: RemoteCommand) {
        guard let browser = movies else { return }
        let entries = movieSidebar
        let index = entries.firstIndex(of: browser.sidebarSection) ?? 0
        switch command {
        case .move(.up): stepMovieSidebar(to: index - 1, in: entries)
        case .move(.down): stepMovieSidebar(to: index + 1, in: entries)
        case .move(.right), .select:
            if case .select = command { flashMovies("sidebar") }
            if browser.sidebarSection == .add {
                if case .select = command { openAddSource(); return }
                movies?.sidebarSection = browser.section   // Right on Add Source: the sidebar closes on the page as it was
            }
            commitMovieSidebar()
            withAnimation(Motion.focus) {
                if movies?.section == .search { movies?.focus = .header } else { movies?.focus = movieRows.isEmpty && hasMovieHeader(movies?.section ?? .home) ? .header : .rows }
            }
        case .back:
            if browser.sidebarSection == .add { movies?.sidebarSection = browser.section }
            commitMovieSidebar()
            withAnimation(Motion.focus) { movies?.focus = movies?.section == .search ? .header : .rows }
        default: break
        }
    }

    /// The highlight moves at once; the page follows when it rests (one page's rows aren't built for every step).
    private func stepMovieSidebar(to index: Int, in entries: [MoviesBrowser.Section]) {
        guard entries.indices.contains(index) else { return }
        withAnimation(Motion.focus) { movies?.sidebarSection = entries[index] }
        let work = moviesWork
        work.sidebarCommit?.cancel()
        work.sidebarCommit = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.movieSidebarSettle)
            guard !Task.isCancelled else { return }
            self?.commitMovieSidebar()
        }
    }

    /// The page becomes the highlighted section (Add Source isn't a page: the page stays).
    func commitMovieSidebar() {
        moviesWork.sidebarCommit?.cancel()
        moviesWork.sidebarCommit = nil
        guard let target = movies?.sidebarSection, target != movies?.section, target != .add else { return }
        withAnimation(Motion.navigate) {
            movies?.section = target
            movies?.row = 0
        }
    }

    /// The pointer chose a section in the sidebar.
    func tapMovieSidebar(_ section: MoviesBrowser.Section) {
        guard movies != nil else { return }
        flashMovies("sidebar")
        if section == .add { openAddSource(); return }
        withAnimation(Motion.navigate) {
            movies?.sidebarSection = section
            movies?.section = section
            movies?.row = 0
            movies?.focus = section == .search ? .header : .rows
            movies?.pages = []
        }
    }

    // MARK: Back

    /// Back in a section: a search being typed stops; a section goes back to Home; Home's lower rows go back to its
    /// first; and at the top, Movies goes to the background and the Home Screen shows (Apple TV's rule).
    func movieBack() {
        guard let browser = movies else { return }
        if browser.section != .home {
            withAnimation(Motion.navigate) {
                movies?.section = .home
                movies?.sidebarSection = .home
                movies?.focus = .rows
                movies?.row = 0
            }
        } else if browser.row > 0 || browser.focus != .rows {
            withAnimation(Motion.navigate) {
                movies?.row = 0
                movies?.focus = .rows
            }
        } else {
            goHome()
        }
    }

    // MARK: Choosing

    func activateMovieEntry(_ entry: MoviesEntry) {
        switch entry {
        case .movie(let path): openMoviePage(.movie(path))
        case .show(let id): openMoviePage(.show(id))
        case .add(let index): addMovieSource(index)
        }
    }

    /// Play/Pause on a card: straight to playing (where you stopped, or a show's next episode).
    func playMovieEntry(_ entry: MoviesEntry) {
        switch entry {
        case .movie(let path): if let movie = movieLibrary.movie(path) { playFromMovies(movie) }
        case .show(let id): if let next = movieLibrary.show(id)?.next { playFromMovies(next) }
        case .add: break
        }
    }

    /// Plays from where you stopped (a few seconds back, to pick up the thread), or from the start.
    func playFromMovies(_ movie: Movie, startOver: Bool = false, at seconds: Double? = nil) {
        let from = seconds ?? (startOver || !movie.inProgress ? 0 : max(0, (movie.position ?? 0) - 5))
        playMovie(movie, from: from)
    }

    /// The pointer clicked a card: focus moves there and it opens.
    func tapMovieEntry(row: Int, column: Int) {
        let rows = movieRows
        guard rows.indices.contains(row), rows[row].items.indices.contains(column) else { return }
        withAnimation(Motion.focus) {
            movies?.focus = .rows
            movies?.typing = false
            movies?.row = row
            movies?.columns[rows[row].id] = column
        }
        flashMovies(movieFocusID)
        activateMovieEntry(rows[row].items[column])
    }

    /// The pointer held a card: focus moves there and its menu opens.
    func holdMovieEntry(row: Int, column: Int) {
        let rows = movieRows
        guard rows.indices.contains(row), rows[row].items.indices.contains(column) else { return }
        movies?.focus = .rows
        movies?.row = row
        movies?.columns[rows[row].id] = column
        _ = openMoviesMenu()
    }

    /// The pointer clicked a sort choice.
    func tapMovieSort(_ index: Int) {
        withAnimation(Motion.focus) { movies?.focus = .header }
        setMovieSort(index)
    }

    /// The pointer clicked the search field: typing.
    func tapMovieSearch() {
        withAnimation(Motion.focus) {
            movies?.focus = .header
            movies?.typing = true
        }
    }

    /// The focused control's name, for its press (see MoviesWork.pressed).
    var movieFocusID: String {
        guard let browser = movies else { return "" }
        if let page = browser.page { return "page-\(page.row)-\(page.button)-\(page.columns[page.row] ?? 0)" }
        guard let focus = movieFocus else { return "" }
        return "\(movieRows[focus.row].id)-\(focus.column)"
    }

    /// A press: the control dips and settles back (a single short animation, nothing left running).
    func flashMovies(_ id: String) {
        let work = moviesWork
        work.pressTask?.cancel()
        withAnimation(Motion.press) { work.pressed = id }
        work.pressTask = Task { @MainActor [weak work] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.press) { work?.pressed = nil }
        }
    }

    // MARK: A page's input

    private func handleMoviePage(_ command: RemoteCommand) {
        guard var page = movies?.page else { return }
        let rows = moviePageRows(page)
        page.row = min(page.row, rows.count - 1)
        let kind = rows[page.row]
        switch command {
        case .back:
            moviesWork.scenesTask?.cancel()
            withAnimation(Motion.navigate) { _ = movies?.pages.popLast() }
            if case .movie(let path)? = movies?.page?.target { makeScenes(path) }
            return
        case .move(.up):
            if page.row > 0 { page.row -= 1 }
        case .move(.down):
            if page.row < rows.count - 1, moviePageRowCount(page, kind: rows[page.row + 1]) > 0 { page.row += 1 }
        case .move(let direction) where direction == .left || direction == .right:
            let count = moviePageRowCount(page, kind: kind)
            let delta = direction == .left ? -1 : 1
            switch kind {
            case .buttons: page.button = max(0, min(count - 1, page.button + delta))
            case .seasons:
                page.season = max(0, min(count - 1, page.season + delta))
                page.columns[rows.firstIndex(of: .episodes) ?? 2] = 0
            default:
                let column = page.columns[page.row] ?? 0
                page.columns[page.row] = max(0, min(count - 1, column + delta))
            }
        case .select:
            flashMovies(movieFocusID)
            activateMoviePage(page, kind: kind)
            return
        case .playPause:
            playMoviePage(page)
            return
        default: return
        }
        let moved = page
        withAnimation(kind == .scenes || kind == .episodes ? BiliMotion.step() : Motion.focus) { movies?.page = moved }
    }

    /// How many things a page's row has.
    func moviePageRowCount(_ page: MoviesBrowser.Page, kind: MoviePageRow) -> Int {
        switch kind {
        case .buttons: return moviePageButtons(page).count
        case .scenes: return 6
        case .seasons:
            guard case .show(let id) = page.target else { return 0 }
            return movieLibrary.show(id)?.seasons.count ?? 0
        case .episodes:
            guard case .show(let id) = page.target, let show = movieLibrary.show(id) else { return 0 }
            return show.episodes(in: movieShowSeason(page, show)).count
        }
    }

    /// What a page's Play opens: the movie, or the show's next episode.
    func moviePageMovie(_ page: MoviesBrowser.Page) -> Movie? {
        switch page.target {
        case .movie(let path): movieLibrary.movie(path)
        case .show(let id): movieLibrary.show(id)?.next
        }
    }

    private func playMoviePage(_ page: MoviesBrowser.Page) {
        if let movie = moviePageMovie(page) { playFromMovies(movie) }
    }

    private func activateMoviePage(_ page: MoviesBrowser.Page, kind: MoviePageRow) {
        switch kind {
        case .buttons:
            let buttons = moviePageButtons(page)
            guard buttons.indices.contains(page.button) else { return }
            switch buttons[page.button] {
            case .play, .resume: playMoviePage(page)
            case .startOver: if let movie = moviePageMovie(page) { playFromMovies(movie, startOver: true) }
            case .watched:
                if case .movie(let path) = page.target, let movie = movieLibrary.movie(path) {
                    movieLibrary.setWatched(path, !movie.isWatched)
                    // The buttons change (Resume goes when it's watched): stay on this one
                    let index = moviePageButtons(page).firstIndex(of: .watched) ?? 0
                    movies?.page?.button = index
                }
            case .more:
                switch page.target {
                case .movie(let path): openMoviesMenu(.movie(path))
                case .show(let id): if let next = movieLibrary.show(id)?.next { openMoviesMenu(.movie(next.path)) }
                }
            }
        case .scenes:
            guard case .movie(let path) = page.target, let movie = movieLibrary.movie(path), let duration = movie.duration else { return }
            playFromMovies(movie, at: MovieArtwork.sceneTime(page.columns[page.row] ?? 0, duration: duration))
        case .seasons:
            withAnimation(Motion.focus) { movies?.page?.row = page.row + 1 }
        case .episodes:
            guard case .show(let id) = page.target, let show = movieLibrary.show(id) else { return }
            let episodes = show.episodes(in: movieShowSeason(page, show))
            let column = page.columns[page.row] ?? 0
            guard episodes.indices.contains(column) else { return }
            openMoviePage(.movie(episodes[column].path))
        }
    }

    /// The pointer clicked a page's button, scene or episode.
    func tapMoviePage(row: Int, index: Int) {
        guard var page = movies?.page else { return }
        let rows = moviePageRows(page)
        guard rows.indices.contains(row) else { return }
        page.row = row
        switch rows[row] {
        case .buttons: page.button = index
        case .seasons: page.season = index
        default: page.columns[row] = index
        }
        movies?.page = page
        flashMovies(movieFocusID)
        activateMoviePage(page, kind: rows[row])
    }

    // MARK: Menus (hold Select)

    /// The menu's items, in order.
    enum MoviesMenuItem: Hashable {
        case removeFromContinueWatching, markWatched, markUnwatched, clearProgress, goToShow
        case rescan, homeVideos, remove
        case cancel, confirmRemove
    }

    func moviesMenuItems(_ menu: MoviesBrowser.Menu) -> [MoviesMenuItem] {
        if menu.confirming { return [.cancel, .confirmRemove] }
        switch menu.target {
        case .movie(let path):
            guard let movie = movieLibrary.movie(path) else { return [] }
            var items: [MoviesMenuItem] = []
            if movie.inProgress, movie.dismissed != true { items.append(.removeFromContinueWatching) }
            items.append(movie.isWatched ? .markUnwatched : .markWatched)
            if movie.position != nil { items.append(.clearProgress) }
            let onShowPage: Bool = if case .show? = movies?.page?.target { true } else { false }
            if movie.category == .episode, !onShowPage { items.append(.goToShow) }
            return items
        case .source:
            return [.rescan, .homeVideos, .remove]
        }
    }

    /// Hold Select: the focused card's menu, or a source's in the sidebar. False when there's none to open here.
    func openMoviesMenu() -> Bool {
        guard let browser = movies, browser.menu == nil, browser.shareForm == nil, browser.adding == nil, !browser.typing else { return false }
        if let page = browser.page {
            guard let movie = moviePageMovie(page) else { return false }
            if case .show(let id) = page.target, let show = movieLibrary.show(id), moviePageRows(page)[min(page.row, moviePageRows(page).count - 1)] == .episodes {
                let episodes = show.episodes(in: movieShowSeason(page, show))
                let column = page.columns[page.row] ?? 0
                guard episodes.indices.contains(column) else { return false }
                return openMoviesMenu(.movie(episodes[column].path))
            }
            return openMoviesMenu(.movie(movie.path))
        }
        switch browser.focus {
        case .sidebar:
            guard case .source(let id) = browser.sidebarSection else { return false }
            return openMoviesMenu(.source(id))
        case .rows:
            switch focusedMovieEntry {
            case .movie(let path): return openMoviesMenu(.movie(path))
            case .show(let id): return movieLibrary.show(id)?.next.map { openMoviesMenu(.movie($0.path)) } ?? false
            default: return false
            }
        case .header: return false
        }
    }

    @discardableResult
    func openMoviesMenu(_ target: MoviesBrowser.Menu.Target) -> Bool {
        let menu = MoviesBrowser.Menu(target: target)
        guard !moviesMenuItems(menu).isEmpty else { return false }
        withAnimation(Motion.slide) { movies?.menu = menu }
        return true
    }

    /// The menu open: closes it (hold Select again, or Back).
    func closeMoviesMenu() -> Bool {
        guard movies?.menu != nil else { return false }
        withAnimation(Motion.slide) { movies?.menu = nil }
        return true
    }

    private func handleMoviesMenu(_ command: RemoteCommand) {
        guard let menu = movies?.menu else { return }
        let items = moviesMenuItems(menu)
        switch command {
        case .move(.up): withAnimation(Motion.slide) { movies?.menu?.index = max(0, menu.index - 1) }
        case .move(.down): withAnimation(Motion.slide) { movies?.menu?.index = min(items.count - 1, menu.index + 1) }
        case .select:
            guard items.indices.contains(menu.index) else { return }
            flashMovies("menu-\(menu.index)")
            chooseMoviesMenu(items[menu.index])
        case .back:
            if menu.confirming {
                withAnimation(Motion.slide) { movies?.menu?.confirming = false; movies?.menu?.index = 2 }
            } else {
                _ = closeMoviesMenu()
            }
        default: break
        }
    }

    /// The pointer clicked a menu item.
    func tapMoviesMenu(_ index: Int) {
        guard let menu = movies?.menu else { return }
        let items = moviesMenuItems(menu)
        guard items.indices.contains(index) else { return }
        movies?.menu?.index = index
        chooseMoviesMenu(items[index])
    }

    private func chooseMoviesMenu(_ item: MoviesMenuItem) {
        guard let menu = movies?.menu else { return }
        let library = movieLibrary
        switch (menu.target, item) {
        case (.movie(let path), .removeFromContinueWatching): library.dismiss(path)
        case (.movie(let path), .markWatched): library.setWatched(path, true)
        case (.movie(let path), .markUnwatched): library.setWatched(path, false)
        case (.movie(let path), .clearProgress): library.clearProgress(path)
        case (.movie(let path), .goToShow):
            _ = closeMoviesMenu()
            if let show = library.movie(path).flatMap(library.show(of:)) { openMoviePage(.show(show.id)) }
            return
        case (.source(let id), .rescan):
            if let share = NetworkShares.shared.share(for: URL(fileURLWithPath: id, isDirectory: true)),
               NetworkShares.shared.status[share.id] != .connected {
                NetworkShares.shared.connect(share, addToMovies: false)
            } else {
                library.refresh()
            }
        case (.source(let id), .homeVideos):
            library.setHomeVideos(id, !library.isHomeVideos(id))
            return   // the menu stays, showing the switch
        case (.source, .remove):
            withAnimation(Motion.slide) { movies?.menu?.confirming = true; movies?.menu?.index = 0 }
            return
        case (.source, .cancel):
            withAnimation(Motion.slide) { movies?.menu?.confirming = false; movies?.menu?.index = 2 }
            return
        case (.source(let id), .confirmRemove):
            library.removeSource(id)
            withAnimation(Motion.navigate) {
                movies?.menu = nil
                if movies?.section == .source(id) { movies?.section = .home; movies?.row = 0 }
                movies?.sidebarSection = movies?.section ?? .home
            }
            return
        default: break
        }
        _ = closeMoviesMenu()
    }

    // MARK: Add Source

    func openAddSource() {
        withAnimation(Motion.appear) { movies?.adding = 0 }
    }

    /// The Add Source panel's three choices, which the empty library shows as buttons too.
    static let movieSourceChoices: [(title: String, symbol: String)] = [
        ("Add Folder…", "folder.badge.plus"),
        ("Add Network Share…", "externaldrive.connected.to.line.below"),
        ("Add Jellyfin Server…", "server.rack"),
    ]

    private func handleAddSource(_ command: RemoteCommand) {
        guard let row = movies?.adding else { return }
        switch command {
        case .move(.up): withAnimation(Motion.focus) { movies?.adding = max(0, row - 1) }
        case .move(.down): withAnimation(Motion.focus) { movies?.adding = min(Self.movieSourceChoices.count - 1, row + 1) }
        case .select: flashMovies("add-\(row)"); addMovieSource(row)
        case .back: withAnimation(Motion.appear) { movies?.adding = nil }
        default: break
        }
    }

    /// Add Folder… opens the Mac's folder chooser; the other two, the form on the TV.
    func addMovieSource(_ index: Int) {
        switch index {
        case 0:
            withAnimation(Motion.appear) { movies?.adding = nil }
            chooseMovieFolders { [weak self] folders in
                folders.forEach { self?.movieLibrary.add($0) }
            }
        case 1: withAnimation(Motion.appear) { movies?.shareForm = ShareForm() }
        case 2: withAnimation(Motion.appear) { movies?.shareForm = ShareForm(jellyfin: true) }
        default: break
        }
    }

    // MARK: Network shares and Jellyfin servers

    private func handleShareForm(_ command: RemoteCommand) {
        guard var form = movies?.shareForm else { return }
        // While connecting, only Back does anything: it closes the form and the share keeps trying.
        if form.connecting { if case .back = command { movies?.shareForm = nil }; return }
        form.message = nil
        switch command {
        case .back:
            movies?.shareForm = nil
            return
        case .move(.up): form.row = max(0, form.row - 1)
        case .move(.down): form.row = min(3, form.row + 1)
        case .select:
            if form.row == 3 {
                movies?.shareForm = form
                form.jellyfin ? submitJellyfinForm() : submitShareForm()
                return
            }
            form.row += 1
        case .text(let text):
            let typed = text.replacingOccurrences(of: "\n", with: "")
            switch form.row {
            case 1: form.user += typed
            case 2: form.password += typed
            default: form.row = 0; form.address += typed
            }
            if text.hasSuffix("\n") { movies?.shareForm = form; handleShareForm(.select); return }
        case .deleteBackward:
            switch form.row {
            case 1: if !form.user.isEmpty { form.user.removeLast() }
            case 2: if !form.password.isEmpty { form.password.removeLast() }
            default: if !form.address.isEmpty { form.address.removeLast() }
            }
        default: break
        }
        movies?.shareForm = form
    }

    /// The form's row clicked.
    func tapShareForm(_ row: Int) {
        guard movies?.shareForm?.connecting == false else { return }
        movies?.shareForm?.row = row
        if row == 3 { handleShareForm(.select) }
    }

    /// Adds the share and waits for it to connect: closes on success, or shows why it didn't.
    private func submitShareForm() {
        guard var form = movies?.shareForm else { return }
        let shares = networkShares
        guard let share = shares.add(address: form.address, user: form.user, password: form.password) else {
            form.message = form.address.isEmpty ? "Type the shared folder's address first." : "Use an address like nas.local/Movies."
            movies?.shareForm = form
            return
        }
        form.connecting = true
        movies?.shareForm = form
        Task { @MainActor [weak self] in
            // macOS gives up on an unreachable server after about a minute.
            for _ in 0..<150 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.movies?.shareForm?.connecting == true else { return }
                switch shares.status[share.id] {
                case .connected:
                    self.closeAddSource()
                    return
                case .offline(let reason):
                    self.movies?.shareForm?.connecting = false
                    self.movies?.shareForm?.message = reason
                    return
                default: continue
                }
            }
        }
    }

    /// Signs in to the Jellyfin server: closes on success, or shows why it couldn't.
    private func submitJellyfinForm() {
        guard var form = movies?.shareForm else { return }
        form.connecting = true
        movies?.shareForm = form
        let jellyfin = jellyfin
        Task { @MainActor [weak self] in
            let error = await jellyfin.signIn(address: form.address, user: form.user, password: form.password)
            guard let self, self.movies?.shareForm?.connecting == true else { return }
            if let error {
                self.movies?.shareForm?.connecting = false
                self.movies?.shareForm?.message = error
            } else {
                self.closeAddSource()
            }
        }
    }

    private func closeAddSource() {
        withAnimation(Motion.appear) {
            movies?.shareForm = nil
            movies?.adding = nil
        }
    }

    // MARK: Swipes and the wheel (TVController.Module)

    /// The sidebar is a drawer from the left, picked in up and down; rows that scroll are strips; a grid's line is a
    /// picker, its lines a drawer; the header, the page's buttons and season choices, menus and panels are pickers.
    func moviesModule(horizontal: Bool) -> Module {
        guard let browser = movies else { return .off }
        if browser.shareForm != nil || browser.menu != nil || browser.adding != nil { return .picker }
        if let page = browser.page {
            let rows = moviePageRows(page)
            switch rows[min(page.row, rows.count - 1)] {
            case .buttons, .seasons: return horizontal ? .picker : .drawer
            case .scenes, .episodes: return horizontal ? .strip : .drawer
            }
        }
        if browser.typing { return horizontal ? .off : .drawer }
        switch browser.focus {
        case .sidebar: return horizontal ? .drawer : .picker
        case .header: return horizontal ? .picker : .drawer
        case .rows:
            guard let focus = movieFocus else { return horizontal ? .drawer : .off }
            let style = movieRows[focus.row].style
            if horizontal { return style == .wide || style == .poster ? .strip : .picker }
            return .drawer
        }
    }

    /// The wheel stays in the row or column it's in; at the end it stops (into the sidebar takes a press).
    func moviesWheelCanMove(_ direction: RemoteCommand.Direction) -> Bool {
        guard let browser = movies else { return false }
        if browser.page != nil || browser.menu != nil || browser.adding != nil || browser.shareForm != nil { return true }
        switch browser.focus {
        case .sidebar: return direction == .up || direction == .down
        case .header: return direction == .left ? (browser.sorts[browser.section] ?? 0) > 0 : true
        case .rows:
            guard let focus = movieFocus else { return false }
            switch direction {
            case .left: return focus.column > 0
            case .right: return focus.column < movieRows[focus.row].items.count - 1
            case .up: return focus.row > 0
            case .down: return focus.row < movieRows.count - 1
            }
        }
    }

    var moviesWheelRunsHorizontally: Bool {
        guard let browser = movies else { return true }
        if browser.menu != nil || browser.adding != nil || browser.shareForm != nil { return false }
        if browser.page != nil { return true }
        return browser.focus != .sidebar
    }

    /// After a movie closes: the card it was on keeps focus, wherever its row has moved to.
    func reconcileMovieBrowserPosition(for path: String) {
        guard movies?.page == nil, movies?.focus == .rows else { return }
        let rows = movieRows
        guard let focus = movieFocus, case .movie(let current) = rows[focus.row].items[focus.column], current != path else { return }
        if let column = rows[focus.row].items.firstIndex(of: .movie(path)) { movies?.columns[rows[focus.row].id] = column }
    }
}
