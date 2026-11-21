import AppKit
import SwiftUI

// MARK: Layout

/// Movies on the 1920×1080 canvas, on 哔哩哔哩's and 得到's grid: the same margin for the collapsed sidebar, the same
/// step aside while it's open, the same 16:9 card.
enum MoviesLayout {
    static let margin: CGFloat = 176
    static let sidebarShift: CGFloat = 214
    static let wide = CGSize(width: 416, height: 234)
    static let poster = CGSize(width: 232, height: 348)
    static let gap: CGFloat = 40
    static let gridGap: CGFloat = 48
    static let wideGrid = CGSize(width: 376, height: 211.5)
    /// The detail pages' left edge (no sidebar there).
    static let pageLeft: CGFloat = 120

    static func size(_ style: MoviesRow.Style) -> CGSize {
        switch style {
        case .wide: wide
        case .poster, .posterGrid: poster
        case .wideGrid: wideGrid
        case .buttons: CGSize(width: 360, height: 78)
        }
    }

    static func spacing(_ style: MoviesRow.Style) -> CGFloat { style == .posterGrid ? gridGap : gap }

    /// A row's height on the page: its name, its cards and their captions.
    static func height(_ row: MoviesRow) -> CGFloat {
        let title: CGFloat = row.title == nil ? 0 : 72
        switch row.style {
        case .wide: return title + wide.height + 120
        case .poster: return title + poster.height + 116
        case .posterGrid: return poster.height + 128
        case .wideGrid: return wideGrid.height + 124
        case .buttons: return 120
        }
    }
}

/// The Movies app: a sidebar (Search, Home, Movies, TV Shows, Other Videos, then each source and Add Source), the
/// section it shows, and a movie's or a show's page over it. Built like 哔哩哔哩 and 得到: the sidebar from the left
/// steps the page aside, rows scroll under a fixed focus, and the focused title fills the top of Home.
struct MoviesScreen: View {
    @ObservedObject var tv: TVController
    @ObservedObject private var library: MovieLibrary
    @ObservedObject private var work: MoviesWork
    @ObservedObject private var shares: NetworkShares
    @ObservedObject private var jellyfin: JellyfinServers
    @Environment(\.canvasSize) private var canvas
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(tv: TVController) {
        _tv = ObservedObject(wrappedValue: tv)
        _library = ObservedObject(wrappedValue: tv.movieLibrary)
        _work = ObservedObject(wrappedValue: tv.moviesWork)
        _shares = ObservedObject(wrappedValue: tv.networkShares)
        _jellyfin = ObservedObject(wrappedValue: tv.jellyfin)
    }

    var body: some View {
        let browser = tv.movies ?? MoviesBrowser()
        let sidebarOpen = browser.focus == .sidebar && browser.page == nil
        // Worked out once for everything below
        let rows = browser.page == nil ? tv.movieRows(for: browser) : []
        let sources = library.sources
        let revision = library.revision
        ZStack(alignment: .topLeading) {
            Color(hex: "#0B0C10")
            Group {
                MoviesSectionView(tv: tv, browser: browser, rows: rows, sources: sources, revision: revision,
                                  scanning: library.scanning, pressed: work.pressed)
                    .offset(x: sidebarOpen ? MoviesLayout.sidebarShift : 0)
                    .opacity(sidebarOpen ? 0.4 : 1)
                    .animation(Motion.slide, value: sidebarOpen)
                MoviesSidebarView(tv: tv, browser: browser, entries: tv.movieSidebar, sources: sources, open: sidebarOpen,
                                  pressed: work.pressed == "sidebar")
            }
            .opacity(browser.page == nil ? 1 : 0)

            if let page = browser.page {
                MoviePageView(tv: tv, page: page)
                    .id(page.target)
                    .transition(.opacity)
            }
            ClockPill(twentyFour: tv.preferences.twentyFourHourTime)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, TopBar.trailing)
                .padding(.top, TopBar.top)

            if browser.menu != nil {
                DimBackdrop(close: { _ = tv.closeMoviesMenu() })
                    .transition(.opacity)
            }
            if let menu = browser.menu {
                MoviesMenuView(tv: tv, browser: browser, menu: menu, rows: rows)
                    .transition(.growing(from: .topLeading))
            }
            if let row = browser.adding, browser.shareForm == nil {
                AddSourceSheet(tv: tv, row: row)
                    .transition(Motion.sheet(reduceMotion: reduceMotion))
            }
            if let form = browser.shareForm {
                ShareFormSheet(tv: tv, form: form)
                    .transition(Motion.sheet(reduceMotion: reduceMotion))
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .clipped()
        .foregroundStyle(.white)
        .animation(Motion.navigate, value: browser.pages.count)
        .animation(Motion.appear, value: browser.adding != nil)
        .animation(Motion.appear, value: browser.shareForm != nil)
        // Its background work (pictures, a file's details) runs only while this is on screen
        .onAppear { library.active = true }
        .onDisappear {
            library.active = false
            work.stop()
        }
    }
}

// MARK: Sections

/// The section showing: Home, a section's grid, a source, or Search.
private struct MoviesSectionView: View {
    let tv: TVController
    let browser: MoviesBrowser
    let rows: [MoviesRow]
    let sources: [MovieSource]
    let revision: Int
    let scanning: Bool
    let pressed: String?
    @Environment(\.canvasSize) private var canvas

    var body: some View {
        let focus = TVController.movieFocus(browser, rows: rows)
        ZStack(alignment: .topLeading) {
            switch browser.section {
            case .home:
                if rows.first?.style == .buttons {
                    EmptyLibraryView(tv: tv, focus: browser.focus == .rows ? focus : nil, scanning: scanning, pressed: pressed)
                } else {
                    MoviesHero(tv: tv, entry: focus.map { rows[$0.row].items[$0.column] }, revision: revision)
                    MoviesRowsView(tv: tv, browser: browser, rows: rows, focus: browser.focus == .rows ? focus : nil, pressed: pressed, revision: revision,
                                   scrollRow: focus?.row ?? 0, top: 470)
                }
            case .movies, .shows, .videos:
                SectionHeader(tv: tv, browser: browser, count: rows.reduce(0) { $0 + $1.items.count }, pressed: pressed)
                MoviesRowsView(tv: tv, browser: browser, rows: rows, focus: browser.focus == .rows ? focus : nil, pressed: pressed, revision: revision,
                               scrollRow: browser.focus == .rows ? (focus?.row ?? 0) : 0, top: 290)
            case .search:
                SearchHeader(tv: tv, browser: browser, pressed: pressed == "search")
                MoviesRowsView(tv: tv, browser: browser, rows: rows, focus: browser.focus == .rows ? focus : nil, pressed: pressed, revision: revision,
                               scrollRow: browser.focus == .rows ? (focus?.row ?? 0) : 0, top: 250)
            case .source(let id):
                SourceHeader(tv: tv, source: sources.first { $0.id == id }, revision: revision)
                if rows.isEmpty, let source = sources.first(where: { $0.id == id }) {
                    Text(source.offline ?? "No Videos")
                        .font(.tv(.title3, emphasized: true))
                        .opacity(0.6)
                        .frame(width: canvas.width, height: canvas.height)
                } else {
                    MoviesRowsView(tv: tv, browser: browser, rows: rows, focus: browser.focus == .rows ? focus : nil, pressed: pressed, revision: revision,
                                   scrollRow: focus?.row ?? 0, top: 380)
                }
            case .add:
                EmptyView()
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
    }
}

/// Home's top half: the focused title, over its wide picture, sharp on the right and fading into black.
private struct MoviesHero: View {
    let tv: TVController
    let entry: MoviesEntry?
    let revision: Int
    @Environment(\.canvasSize) private var canvas

    var body: some View {
        let library = tv.movieLibrary
        let info = MovieInfo(entry: entry, library: library)
        ZStack(alignment: .topLeading) {
            HeroBackdrop(artwork: library.artwork, file: info.backdrop, poster: info.poster)
            VStack(alignment: .leading, spacing: 18) {
                Text(info.title)
                    .font(.tvHeroTitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: 1300, alignment: .leading)
                    .shadow(color: .black.opacity(0.5), radius: 14, y: 4)
                MovieMetaLine(info: info)
                if let overview = info.overview {
                    Text(overview)
                        .font(.tv(.body)).opacity(0.7).lineLimit(2)
                        .frame(width: 1000, alignment: .leading)
                }
            }
            .padding(.leading, MoviesLayout.margin)
            .frame(height: 430, alignment: .bottomLeading)
            .id(info.id)
            .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.22), value: info.id)
    }
}

/// What's said about a movie or a show at the top of Home and on its page.
struct MovieInfo {
    var id = ""
    var title = ""
    var parts: [String] = []
    var badges: [String] = []
    var overview: String?
    var backdrop: String?
    var poster: String?
    var watched = false

    @MainActor
    init(entry: MoviesEntry?, library: MovieLibrary) {
        switch entry {
        case .movie(let path)?:
            if let movie = library.movie(path) { self.init(movie: movie, library: library) } else { self.init() }
        case .show(let id)?:
            if let show = library.show(id) { self.init(show: show) } else { self.init() }
        default: self.init()
        }
    }

    init() {}

    @MainActor
    init(movie: Movie, library: MovieLibrary) {
        id = movie.path
        title = movie.category == .episode ? (movie.show ?? movie.title) : movie.title
        if movie.category == .video, let date = movie.recorded {
            parts.append(date.formatted(date: .long, time: .omitted))
        } else if let year = movie.year {
            parts.append(String(year))
        }
        if let episode = movie.episode { parts.append(episode) }
        if let genre = movie.genre { parts.append(genre) }
        if let duration = movie.duration { parts.append(Self.length(duration)) }
        if let rating = movie.rating, !rating.isEmpty { parts.append(rating) }
        badges = Self.badges(movie)
        overview = movie.overview
        backdrop = movie.backdrop
        poster = movie.poster
        watched = movie.isWatched
    }

    init(show: MovieShow) {
        id = show.id
        title = show.title
        let seasons = show.seasons.count
        parts = [seasons == 1 ? "1 Season" : "\(seasons) Seasons"] + (show.year.map { [String($0)] } ?? [])
            + (show.episodes.lazy.compactMap(\.genre).first.map { [$0] } ?? [])
        overview = show.overview
        backdrop = show.backdrop
        poster = show.poster
        watched = show.watched
    }

    /// 4K or HD, HDR or Dolby Vision, the sound's channels.
    static func badges(_ movie: Movie) -> [String] {
        var badges: [String] = []
        let long = max(movie.width ?? 0, movie.height ?? 0)
        if long >= 3800 { badges.append("4K") } else if long >= 1900 { badges.append("HD") }
        if let hdr = movie.hdr { badges.append(hdr) }
        if let audio = movie.audio, audio == "5.1" || audio == "7.1" { badges.append(audio) }
        return badges
    }

    static func length(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(max(minutes, 1)) min"
    }

    static func left(_ seconds: Double) -> String { "\(length(seconds)) left" }
}

/// "2021 · Drama · 1 hr 52 min" and its badges, with a checkmark once watched.
struct MovieMetaLine: View {
    let info: MovieInfo

    var body: some View {
        HStack(spacing: 16) {
            if info.watched {
                Image(systemName: "checkmark.circle.fill").font(.tvHeroMeta).opacity(0.85)
            }
            if !info.parts.isEmpty {
                Text(info.parts.joined(separator: "  ·  ")).font(.tvHeroMeta).opacity(0.75)
            }
            ForEach(info.badges, id: \.self) { MovieBadge(text: $0) }
        }
    }
}

struct MovieBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.tvBadge)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.7), lineWidth: 1.5))
            .opacity(0.85)
    }
}

/// The focused title's wide picture behind Home: drawn sharp on the right and faded into black at the left and
/// bottom (Apple TV's hero), from a picture stored at the size it's drawn, with a plain crossfade when it changes. A
/// title with only a poster gets that poster tiny and blurred, which is cheap to draw (哔哩哔哩's way).
private struct HeroBackdrop: View {
    let artwork: MovieArtwork
    let file: String?
    let poster: String?
    @Environment(\.canvasSize) private var canvas

    var body: some View {
        ZStack {
            if let file {
                MovieImage(artwork: artwork, file: file, maxPixel: 1920) { Color.clear }
                    .frame(width: canvas.width, height: canvas.height * 0.8)
                    .clipped()
                    .mask {
                        LinearGradient(stops: [.init(color: .clear, location: 0.08), .init(color: .black.opacity(0.55), location: 0.42),
                                               .init(color: .black, location: 0.72)], startPoint: .leading, endPoint: .trailing)
                            .mask(LinearGradient(stops: [.init(color: .black, location: 0.45), .init(color: .clear, location: 1)],
                                                 startPoint: .top, endPoint: .bottom))
                    }
                    .frame(width: canvas.width, height: canvas.height, alignment: .top)
                    .id(file)
                    .transition(.opacity)
            } else if let poster {
                SmallBlur(artwork: artwork, file: poster)
                    .id(poster)
                    .transition(.opacity)
            }
            LinearGradient(colors: [.black.opacity(0.1), .clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
        }
        .frame(width: canvas.width, height: canvas.height)
        .clipped()
        .animation(.easeInOut(duration: 0.5), value: file ?? poster)
        .allowsHitTesting(false)
    }
}

/// A picture as a wash of its colours: decoded at 160 pixels, blurred at that size, then scaled up.
private struct SmallBlur: View {
    let artwork: MovieArtwork
    let file: String
    @Environment(\.canvasSize) private var canvas

    var body: some View {
        MovieImage(artwork: artwork, file: file, maxPixel: 160) { Color.clear }
            .frame(width: 160, height: 90)
            .clipped()
            .blur(radius: 7)
            .scaleEffect(x: canvas.width / 160 * 1.16, y: canvas.height / 90 * 1.16)
            .frame(width: canvas.width, height: canvas.height)
            .opacity(0.7)
    }
}

/// A section's name, its count and its sort choices (a picker: the one chosen turns white while focused).
private struct SectionHeader: View {
    let tv: TVController
    let browser: MoviesBrowser
    let count: Int
    let pressed: String?
    @Namespace private var space

    var body: some View {
        let section = browser.section
        let sorts = TVController.movieSorts(section)
        let chosen = browser.sorts[section] ?? 0
        let active = browser.focus == .header
        VStack(alignment: .leading, spacing: 30) {
            HStack(alignment: .firstTextBaseline, spacing: 22) {
                Text(title(section)).font(.tv(.title2, emphasized: true))
                Text(String(count)).font(.tv(.title3)).opacity(0.45)
            }
            HStack(spacing: 14) {
                ForEach(Array(sorts.enumerated()), id: \.offset) { index, sort in
                    let isChosen = index == chosen
                    Text(sort)
                        .font(.tv(.callout, emphasized: isChosen))
                        .foregroundStyle(isChosen && active ? .black : .white.opacity(isChosen ? 1 : 0.6))
                        .padding(.horizontal, 30)
                        .frame(height: 64)
                        .background {
                            if isChosen {
                                Capsule().fill(active ? Color.white : Color.white.opacity(0.16))
                                    .matchedGeometryEffect(id: "sort", in: space)
                            }
                        }
                        .scaleEffect(isChosen && active ? (pressed == "sort-\(index)" ? 0.94 : 1.06) : 1)
                        .contentShape(Capsule())
                        .onTapGesture { tv.tapMovieSort(index) }
                }
            }
            .padding(.leading, -30)
        }
        .padding(.leading, MoviesLayout.margin)
        .padding(.top, 64)
        .animation(Motion.focus, value: chosen)
        .animation(Motion.focus, value: active)
    }

    private func title(_ section: MoviesBrowser.Section) -> String {
        switch section {
        case .movies: "Movies"
        case .shows: "TV Shows"
        default: "Other Videos"
        }
    }
}

/// Search: one field at the top. Select types into it (a Mac keyboard, an input method, or the phone's Type on TV).
private struct SearchHeader: View {
    let tv: TVController
    let browser: MoviesBrowser
    let pressed: Bool
    @FocusState private var typing: Bool

    var body: some View {
        let focused = browser.focus == .header && !browser.typing
        HStack(spacing: 20) {
            Image(systemName: "magnifyingglass").font(.system(size: 38, weight: .semibold))
            if browser.typing {
                TextField("Search", text: Binding(get: { tv.movies?.query ?? "" },
                                                  set: { tv.movies?.query = $0; tv.movies?.row = 0 }))
                    .textFieldStyle(.plain)
                    .focused($typing)
                    .onSubmit { tv.finishMovieTyping() }
                    .onAppear { typing = true }
            } else {
                Text(browser.query.isEmpty ? "Search" : browser.query)
                    .opacity(browser.query.isEmpty ? 0.45 : 1)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .font(.tv(.headline))
        .foregroundStyle(browser.typing ? .black : .white)
        .padding(.horizontal, 34)
        .frame(width: 1100, height: 104, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(browser.typing ? Color.white : Color.white.opacity(focused ? 0.2 : 0.12))
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.white.opacity(browser.typing ? 0 : (focused ? 0.95 : 0.2)), lineWidth: focused ? 5 : 1.5)
        }
        .scaleEffect(focused ? (pressed ? 0.98 : 1.02) : 1, anchor: .leading)
        .environment(\.colorScheme, browser.typing ? .light : .dark)
        .contentShape(Rectangle())
        .onTapGesture { tv.tapMovieSearch() }
        .onChange(of: browser.typing) { _, now in typing = now }
        .padding(.leading, MoviesLayout.margin)
        .padding(.top, 64)
        .animation(Motion.focus, value: focused)
    }
}

/// A source's page: its icon, name and state above its folders' rows.
private struct SourceHeader: View {
    let tv: TVController
    let source: MovieSource?
    let revision: Int

    var body: some View {
        let library = tv.movieLibrary
        let count = library.movies.filter { source?.contains($0.path) == true }.count
        HStack(alignment: .center, spacing: 30) {
            Image(systemName: source?.symbol ?? "folder.fill")
                .font(.system(size: 52, weight: .medium))
                .frame(width: 124, height: 124)
                .tvGlass(in: Circle())
            VStack(alignment: .leading, spacing: 10) {
                Text(source?.name ?? "").font(.tv(.title2, emphasized: true)).lineLimit(1)
                HStack(spacing: 10) {
                    Circle().fill(source?.offline == nil ? Color(hex: "#3DDC84") : Color(hex: "#FF8A80")).frame(width: 12, height: 12)
                    Text(status(source, count: count)).font(.tv(.body)).opacity(0.7)
                }
            }
        }
        .padding(.leading, MoviesLayout.margin)
        .padding(.top, 120)
    }

    private func status(_ source: MovieSource?, count: Int) -> String {
        guard let source else { return "" }
        let state = source.offline ?? "Connected"
        let kind = source.homeVideos ? ["Home Videos"] : []
        return ([state] + kind + [count == 1 ? "1 video" : "\(count) videos"]).joined(separator: "  ·  ")
    }
}

/// The empty library: Add Folder…, Add Network Share…, Add Jellyfin Server…
private struct EmptyLibraryView: View {
    let tv: TVController
    let focus: (row: Int, column: Int)?
    let scanning: Bool
    let pressed: String?
    @Environment(\.canvasSize) private var canvas

    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: "film.stack")
                .font(.system(size: 72, weight: .regular))
                .frame(width: 168, height: 168)
                .tvGlass(in: Circle())
            Text(scanning ? "Looking for Videos…" : "No Videos").font(.tv(.title2, emphasized: true))
            HStack(spacing: 24) {
                ForEach(Array(TVController.movieSourceChoices.enumerated()), id: \.offset) { index, choice in
                    let focused = focus?.column == index
                    MoviesButton(title: choice.title, symbol: choice.symbol, focused: focused,
                                 pressed: focused && pressed == "0-\(index)" || focused && pressed == "add-\(index)")
                        .onTapGesture { tv.tapMovieEntry(row: 0, column: index) }
                }
            }
            .padding(.top, 24)
        }
        .frame(width: canvas.width, height: canvas.height)
        .offset(x: 44)
    }
}

// MARK: Rows

/// A page's rows. The focused row stays at the top and the rows scroll under it; rows above it fade away. A row that
/// scrolls keeps its focused card second from the left, the one before peeking; only cards near focus are drawn.
private struct MoviesRowsView: View {
    let tv: TVController
    let browser: MoviesBrowser
    let rows: [MoviesRow]
    let focus: (row: Int, column: Int)?
    let pressed: String?
    let revision: Int
    let scrollRow: Int
    let top: CGFloat
    @Environment(\.canvasSize) private var canvas

    var body: some View {
        let offsets = rows.reduce(into: [CGFloat]()) { result, row in result.append((result.last ?? 0) + MoviesLayout.height(row)) }
        let scrolled = scrollRow > 0 ? offsets[scrollRow - 1] : 0
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                // Only the rows near focus are drawn
                if abs(index - scrollRow) <= 3 {
                    MoviesRowView(tv: tv, row: row, index: index, column: browser.columns[row.id] ?? 0,
                                  focusedColumn: focus?.row == index ? focus?.column : nil,
                                  current: index == (focus?.row ?? scrollRow), pressed: pressed, revision: revision)
                        .frame(height: MoviesLayout.height(row), alignment: .top)
                        .opacity(index < scrollRow ? 0 : (index == scrollRow || row.isGrid ? 1 : 0.55))
                } else {
                    Color.clear.frame(height: MoviesLayout.height(row))
                }
            }
        }
        .offset(y: top - scrolled)
        .animation(Motion.navigate, value: scrollRow)
    }
}

private struct MoviesRowView: View {
    let tv: TVController
    let row: MoviesRow
    let index: Int
    let column: Int
    let focusedColumn: Int?
    let current: Bool
    let pressed: String?
    let revision: Int
    @Environment(\.canvasSize) private var canvas

    var body: some View {
        let size = MoviesLayout.size(row.style)
        let spacing = MoviesLayout.spacing(row.style)
        let column = focusedColumn ?? min(self.column, max(0, row.items.count - 1))
        let library = tv.movieLibrary
        let scrolls = row.style == .wide || row.style == .poster
        let shift = scrolls ? -CGFloat(max(0, column - 1)) * (size.width + spacing) : 0
        VStack(alignment: .leading, spacing: 26) {
            if let title = row.title {
                Text(title)
                    .font(.tv(.headline, emphasized: true))
                    .foregroundStyle(.white.opacity(current ? 1 : 0.7))
                    .padding(.leading, MoviesLayout.margin)
            }
            HStack(alignment: .top, spacing: spacing) {
                ForEach(Array(row.items.enumerated()), id: \.element) { position, entry in
                    if !scrolls || abs(position - column) <= 6 {
                        MovieCard(artwork: library.artwork, entry: entry, movie: library.movie(entry), show: library.show(entry),
                                  style: row.style, progress: row.progress, focused: focusedColumn == position,
                                  pressed: focusedColumn == position && pressed == "\(row.id)-\(position)")
                            .pointerLift()
                            .onTapGesture { tv.tapMovieEntry(row: index, column: position) }
                            .onLongPressGesture(minimumDuration: 0.5) { tv.holdMovieEntry(row: index, column: position) }
                            .opacity(scrolls && position < column - 1 ? 0 : 1)
                    } else {
                        Color.clear.frame(width: size.width, height: 1)
                    }
                }
            }
            .padding(.leading, MoviesLayout.margin)
            .offset(x: shift)
            .frame(width: canvas.width, alignment: .leading)
            .padding(.vertical, 40)
            .mask {
                EdgeFadeMask(trailing: scrolls ? EdgeFadeMask.width(screen: canvas.width, inset: MoviesLayout.margin,
                                                                   card: size.width, gap: spacing) : 0)
            }
            .padding(.vertical, -40)
        }
    }
}

/// A card: a 2:3 poster (films, shows) or a 16:9 picture (Continue Watching, Other Videos). Focused, it grows a
/// little and takes a white frame, and its caption steps down out of the way; pressed, it dips.
struct MovieCard: View {
    let artwork: MovieArtwork
    let entry: MoviesEntry
    /// The card's movie or show, as they are now (values, so a card that hasn't changed isn't drawn again).
    let movie: Movie?
    let show: MovieShow?
    let style: MoviesRow.Style
    var progress = false
    let focused: Bool
    var pressed = false

    var body: some View {
        let size = MoviesLayout.size(style)
        let wide = style == .wide || style == .wideGrid
        let shape = RoundedRectangle(cornerRadius: wide ? 22 : 20, style: .continuous)
        VStack(alignment: .leading, spacing: 18) {
            ZStack(alignment: .bottom) {
                if let movie {
                    if wide {
                        WideArt(artwork: artwork, movie: movie)
                    } else {
                        PosterArt(artwork: artwork, file: movie.poster, title: movie.title)
                    }
                    overlay(movie, wide: wide)
                } else if let show {
                    PosterArt(artwork: artwork, file: show.poster, title: show.title)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(focused ? 0.95 : 0.1), lineWidth: focused ? 5 : 1.5))
            .shadow(color: .black.opacity(focused ? 0.65 : 0), radius: 30, y: 22)
            .scaleEffect(focused ? (pressed ? 1.02 : 1.09) : 1)

            caption
                .frame(width: size.width, alignment: .leading)
                .offset(y: focused ? 12 : 0)
        }
        .zIndex(focused ? 1 : 0)
        .animation(Motion.focus, value: focused)
        .animation(Motion.press, value: pressed)
        .onAppear { if let movie, movie.inspected != true { artwork.want(movie.path) } }
    }

    /// Where you stopped, over Continue Watching's cards; a video's length on its picture.
    @ViewBuilder
    private func overlay(_ movie: Movie, wide: Bool) -> some View {
        if progress, let position = movie.position, let duration = movie.duration, duration > 0 {
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 10) {
                Spacer()
                HStack {
                    Text(movie.episode ?? "").font(.tvBadge).opacity(0.85)
                    Spacer()
                    Text(MovieInfo.left(duration - position)).font(.tvBadge.monospacedDigit()).opacity(0.85)
                }
                Capsule().fill(.white.opacity(0.3)).frame(height: 6)
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in
                            Capsule().fill(.white).frame(width: geo.size.width * min(1, position / duration))
                        }
                    }
            }
            .padding(.horizontal, 18).padding(.bottom, 16)
        } else if wide, let duration = movie.duration {
            HStack {
                Spacer()
                Text(clockText(duration))
                    .font(.tvBadge.monospacedDigit())
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(.black.opacity(0.66), in: Capsule())
            }
            .padding(12)
        }
        if movie.isWatched, !progress {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 30))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.black, .white)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(12)
        }
    }

    @ViewBuilder private var caption: some View {
        let (title, subtitle): (String, String) = {
            if let movie {
                switch movie.category {
                case .movie: return (movie.title, movie.year.map(String.init) ?? "")
                case .episode:
                    return (movie.show ?? movie.title, [movie.episode, movie.duration.map(MovieInfo.length)].compactMap { $0 }.joined(separator: " · "))
                case .video:
                    return (movie.title, (movie.recorded ?? movie.added).formatted(date: .abbreviated, time: .omitted))
                }
            }
            if let show {
                let seasons = show.seasons.count
                return (show.title, seasons == 1 ? "\(show.episodes.count) Episodes" : "\(seasons) Seasons")
            }
            return ("", "")
        }()
        VStack(alignment: .leading, spacing: 6) {
            // One weight, and brightness as the layer's opacity: a weight or colour animating would redraw the
            // text's glyphs every frame
            Text(title)
                .font(.tvCardTitle)
                .lineLimit(1)
                .opacity(focused ? 1 : 0.78)
            if !subtitle.isEmpty {
                Text(subtitle).font(.tvCardDetail).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
        }
    }
}

/// A 2:3 poster; until there is one, the title on graphite.
struct PosterArt: View {
    let artwork: MovieArtwork
    let file: String?
    let title: String

    var body: some View {
        MovieImage(artwork: artwork, file: file, maxPixel: 600) {
            ZStack {
                LinearGradient(colors: [Color(hex: "#3A3A3C"), Color(hex: "#1C1C1E")], startPoint: .top, endPoint: .bottom)
                VStack(spacing: 14) {
                    Image(systemName: "film").font(.system(size: 44, weight: .light)).opacity(0.5)
                    Text(title).font(.tvCardTitle).multilineTextAlignment(.center).lineLimit(3)
                        .padding(.horizontal, 18).opacity(0.85)
                }
            }
        }
    }
}

/// A 16:9 picture: the video's wide picture, or its poster's top; an upright phone video sits in the middle on its
/// own picture, blurred.
struct WideArt: View {
    let artwork: MovieArtwork
    let movie: Movie

    var body: some View {
        let file = movie.backdrop ?? movie.poster
        let placeholder = ZStack {
            LinearGradient(colors: [Color(hex: "#3A3A3C"), Color(hex: "#1C1C1E")], startPoint: .top, endPoint: .bottom)
            Image(systemName: movie.category == .video ? "video" : "film").font(.system(size: 48, weight: .light)).opacity(0.45)
        }
        if movie.isPortrait || (movie.backdrop == nil && movie.poster != nil) {
            GeometryReader { geo in
                ZStack {
                    MovieImage(artwork: artwork, file: file, maxPixel: 160) { placeholder }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .blur(radius: 18)
                        .overlay(Color.black.opacity(0.5))
                    MovieImage(artwork: artwork, file: file, maxPixel: 640) { Color.clear }
                        .frame(width: geo.size.height * (movie.isPortrait ? 9.0 / 16 : 2.0 / 3), height: geo.size.height)
                        .clipped()
                }
            }
        } else {
            MovieImage(artwork: artwork, file: file, maxPixel: 640) { placeholder }
        }
    }
}

/// A capsule button: white when focused, glass otherwise; it dips when pressed.
struct MoviesButton: View {
    let title: String?
    let symbol: String
    var focused = false
    var pressed = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 26, weight: .semibold))
            if let title { Text(title).font(.tv(.callout, emphasized: true)).lineLimit(1) }
        }
        .foregroundStyle(focused ? .black : .white)
        .padding(.horizontal, title == nil ? 0 : 34)
        .frame(width: title == nil ? 78 : nil, height: 78)
        .focusPlatter(Capsule(), focused: focused)
        .scaleEffect(focused ? (pressed ? 1.0 : 1.08) : 1)
        .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: 18, y: 10)
        .animation(Motion.focus, value: focused)
        .animation(Motion.press, value: pressed)
        .contentShape(Capsule())
    }
}

// MARK: Sidebar

/// The sidebar, as 得到's and 哔哩哔哩's: collapsed, a column of faint icons with a dot by the current one; open, a
/// glass panel slides out under the same icons with their names, the white highlight follows Up and Down, and the
/// sources follow under their heading. When there are more items than fit, the highlight rests mid-way and the list
/// scrolls under it, fading at the ends.
private struct MoviesSidebarView: View {
    let tv: TVController
    let browser: MoviesBrowser
    let entries: [MoviesBrowser.Section]
    let sources: [MovieSource]
    let open: Bool
    let pressed: Bool
    @Environment(\.canvasSize) private var canvas

    private static let item = TVSidebar.row, step = TVSidebar.step, heading: CGFloat = 40, visible = 11

    var body: some View {
        let firstSource = entries.firstIndex { if case .source = $0 { true } else { $0 == .add } } ?? entries.count
        let current = entries.firstIndex(of: open ? browser.sidebarSection : browser.section) ?? 1
        let y: (Int) -> CGFloat = { CGFloat($0) * Self.step + ($0 >= firstSource ? Self.heading : 0) }
        let shown = min(entries.count, Self.visible)
        let first = max(0, min(current - shown / 2, entries.count - shown))
        let window = y(first + shown - 1) - y(first) + Self.item
        let bar = PillOutline()   // a whole capsule: every app's sidebar has the same measures (TVSidebar)
        let barSize = CGSize(width: open ? TVSidebar.width : TVSidebar.dot, height: open ? Self.item : TVSidebar.dot)
        let barY = y(current) + (open ? 0 : (Self.item - TVSidebar.dot) / 2)
        ZStack(alignment: .topLeading) {
            bar.fill(.white).frame(width: barSize.width, height: barSize.height).offset(x: open ? 0 : TVSidebar.dotLeading, y: barY)
                .scaleEffect(pressed && open ? 0.97 : 1)
            ForEach(Array(entries.enumerated()), id: \.offset) { index, section in
                if index == firstSource {
                    ZStack(alignment: .leading) {
                        Text("SOURCES").font(.tv(.caption2, emphasized: true)).tracking(1.2)
                            .foregroundStyle(.white.opacity(0.45)).opacity(open ? 1 : 0).padding(.leading, TVSidebar.leading + 6)
                        Capsule().fill(.white.opacity(0.22)).frame(width: 34, height: 2).padding(.leading, TVSidebar.leading + 4).opacity(open ? 0 : 1)
                    }
                    .frame(height: Self.heading)
                    .offset(y: y(index) - Self.heading + 2)
                }
                let (symbol, title, status) = describe(section)
                let isCurrent = index == current
                HStack(spacing: TVSidebar.symbolGap) {
                    Image(systemName: symbol).font(.tvSidebarSymbol).frame(width: TVSidebar.symbolColumn)
                    if open {
                        Text(title).font(.tvSidebarItem).lineLimit(1).minimumScaleFactor(0.75)
                        Spacer(minLength: 0)
                        if let status { Text(status).font(.tvMenuDetail).opacity(0.6).lineLimit(1) }
                    }
                }
                .foregroundStyle(open && isCurrent ? Color.black
                                 : Color.white.opacity(open ? (status == nil ? 0.78 : 0.5) : (isCurrent ? 1 : 0.38)))
                .padding(.leading, TVSidebar.leading).padding(.trailing, TVSidebar.trailing)
                .frame(width: open ? TVSidebar.width : TVSidebar.rail, height: Self.item, alignment: .leading)
                .contentShape(Rectangle())
                .offset(y: y(index))
                .onTapGesture { tv.tapMovieSidebar(section) }
                .onLongPressGesture(minimumDuration: 0.5) { if case .source(let id) = section { tv.openMoviesMenu(.source(id)) } }
            }
        }
        .offset(y: -y(first))
        .frame(width: open ? TVSidebar.width : TVSidebar.rail, height: window, alignment: .topLeading)
        .clipped()
        .mask { ListFadeMask(above: first > 0, below: first + shown < entries.count) }
        .padding(TVSidebar.inset)
        .background {
            Color.clear
                .tvPanelSurface(in: TVSidebar.panel)
                .tvShadow(.float)
                .opacity(open ? 1 : 0)
                .scaleEffect(x: open ? 1 : 0.35, y: open ? 1 : 0.96, anchor: .leading)
                .offset(x: open ? 0 : -150)
        }
        .padding(.leading, TVSidebar.edge)
        .frame(height: canvas.height, alignment: .center)
        .animation(Motion.slide, value: open)
        .animation(Motion.slide, value: current)
    }

    private func describe(_ section: MoviesBrowser.Section) -> (String, String, String?) {
        switch section {
        case .search: ("magnifyingglass", "Search", nil)
        case .home: ("house.fill", "Home", nil)
        case .movies: ("film.fill", "Movies", nil)
        case .shows: ("tv.fill", "TV Shows", nil)
        case .videos: ("video.fill", "Other Videos", nil)
        case .add: ("plus", "Add Source", nil)
        case .source(let id):
            if let source = sources.first(where: { $0.id == id }) { (source.symbol, source.name, source.offline == nil ? nil : "Offline") } else { ("folder.fill", "", nil) }
        }
    }
}

// MARK: Menus and panels

/// Hold Select: 哔哩哔哩's card menu (the same glass, the same white highlight), by the card, the page's buttons or
/// the source in the sidebar.
private struct MoviesMenuView: View {
    @ObservedObject var tv: TVController
    let browser: MoviesBrowser
    let menu: MoviesBrowser.Menu
    let rows: [MoviesRow]

    var body: some View {
        let items = tv.moviesMenuItems(menu)
        let library = tv.movieLibrary
        VStack(alignment: .leading, spacing: 0) {
            if menu.confirming, case .source(let id) = menu.target {
                Text("Remove “\(library.source(id)?.name ?? "")”?")
                    .font(.tv(.callout, emphasized: true))
                    .padding(.horizontal, TVMenu.leading).padding(.vertical, 12)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                let focused = index == menu.index
                let (symbol, title, on) = describe(item)
                HStack(spacing: TVMenu.symbolGap) {
                    Image(systemName: symbol).font(.tvMenuSymbol).frame(width: TVMenu.symbolColumn)
                    Text(title).font(.tvMenuItem).fixedSize()
                    Spacer(minLength: 20)
                    if let on { SettingSwitchMini(on: on) }
                }
                .foregroundStyle(focused ? (item == .confirmRemove ? .white : .black) : .white.opacity(0.8))
                .padding(.horizontal, TVMenu.leading)
                .frame(minWidth: 460, minHeight: TVMenu.row)
                .background {
                    if focused {
                        PillOutline()
                            .fill(item == .confirmRemove ? Color.destructive : .white)
                    }
                }
                .scaleEffect(focused && tv.moviesWork.pressed == "menu-\(index)" ? 0.97 : 1)
                .contentShape(Rectangle())
                .onTapGesture { tv.tapMoviesMenu(index) }
            }
        }
        .padding(TVMenu.inset)
        .tvPanelSurface(in: TVMenu.panel)
        .tvShadow(.float)
        .fixedSize()
        .animation(Motion.slide, value: menu)
        .offset(anchor)
    }

    /// Where the menu sits: on the focused card, by the page's buttons, or beside the sidebar.
    private var anchor: CGSize {
        if browser.page != nil { return CGSize(width: MoviesLayout.pageLeft + 40, height: 520) }
        if browser.focus == .sidebar { return CGSize(width: 360, height: 300) }
        guard let focus = TVController.movieFocus(browser, rows: rows) else { return CGSize(width: MoviesLayout.margin, height: 400) }
        let row = rows[focus.row]
        let size = MoviesLayout.size(row.style)
        let scrolls = row.style == .wide || row.style == .poster
        let slot = scrolls ? min(focus.column, 1) : focus.column
        let top: CGFloat = switch browser.section {
        case .home: 470
        case .source: 380
        case .search: 250
        default: 290
        }
        return CGSize(width: MoviesLayout.margin + CGFloat(slot) * (size.width + MoviesLayout.spacing(row.style)) + 36,
                      height: top + (row.title == nil ? 40 : 110))
    }

    private func describe(_ item: TVController.MoviesMenuItem) -> (String, String, Bool?) {
        switch item {
        case .removeFromContinueWatching: ("minus.circle", "Remove from Continue Watching", nil)
        case .markWatched: ("checkmark.circle", "Mark as Watched", nil)
        case .markUnwatched: ("circle", "Mark as Unwatched", nil)
        case .clearProgress: ("arrow.counterclockwise", "Clear Progress", nil)
        case .goToShow: ("tv", "Go to Show", nil)
        case .rescan: ("arrow.clockwise", "Rescan", nil)
        case .homeVideos:
            if case .source(let id) = menu.target { ("video", "Home Videos", tv.movieLibrary.isHomeVideos(id)) } else { ("video", "Home Videos", false) }
        case .remove: ("minus.circle", "Remove…", nil)
        case .cancel: ("xmark", "Cancel", nil)
        case .confirmRemove: ("minus.circle", "Remove", nil)
        }
    }
}

/// A small on/off switch for a menu row.
private struct SettingSwitchMini: View {
    let on: Bool
    var body: some View {
        Capsule()
            .fill(on ? Color(hex: "#3DDC84") : Color(white: 0.55, opacity: 0.5))
            .frame(width: 52, height: 30)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(.white).frame(width: 24, height: 24).padding(3)
            }
    }
}

/// Add Source: a folder on this Mac or a drive, a network share, or a Jellyfin server.
private struct AddSourceSheet: View {
    @ObservedObject var tv: TVController
    let row: Int
    @Environment(\.canvasSize) private var canvas
    @Namespace private var space

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add Source").font(.tv(.title3, emphasized: true)).padding(.bottom, 14)
            ForEach(Array(TVController.movieSourceChoices.enumerated()), id: \.offset) { index, choice in
                let focused = index == row
                HStack(spacing: 18) {
                    Image(systemName: choice.symbol).font(.tvMenuSymbol).frame(width: 34)
                    Text(choice.title).font(.tvMenuItem).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.tvMenuDetail).opacity(0.6)
                }
                .padding(.horizontal, 24)
                .frame(height: 64)
                .foregroundStyle(focused ? .black : .white)
                .background {
                    let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
                    if focused { shape.fill(.white).matchedGeometryEffect(id: "focus", in: space) } else { shape.fill(.white.opacity(0.08)) }
                }
                .scaleEffect(focused ? (tv.moviesWork.pressed == "add-\(index)" ? 0.98 : 1.02) : 1)
                .shadow(color: .black.opacity(focused ? 0.3 : 0), radius: 14, y: 8)
                .contentShape(Rectangle())
                .onTapGesture {
                    tv.movies?.adding = index
                    tv.addMovieSource(index)
                }
            }
        }
        .padding(56)
        .frame(width: 900, alignment: .leading)
        .tvPanel(in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .frame(width: canvas.width, height: canvas.height)
        .background(SheetBackdrop())
        .animation(Motion.focus, value: row)
    }
}

/// Add Network Share or Add Jellyfin Server on the TV: the address, a user name and password, then
/// Connect or Sign In.
struct ShareFormSheet: View {
    @ObservedObject var tv: TVController
    let form: ShareForm
    @Environment(\.canvasSize) private var canvas

    /// A field's text, typed into by its text field.
    private func binding(_ field: WritableKeyPath<ShareForm, String>) -> Binding<String> {
        Binding(get: { tv.movies?.shareForm?[keyPath: field] ?? "" }, set: { tv.movies?.shareForm?[keyPath: field] = $0 })
    }

    /// Return in a field: as Select there (the next field, or Connect).
    private func submit() { tv.handle(.select) }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(form.jellyfin ? "Add Jellyfin Server" : "Add Network Share").font(.tv(.title3, emphasized: true))
            AdderField(label: form.jellyfin ? "Server" : "Shared folder", text: binding(\.address),
                       placeholder: form.jellyfin ? "e.g. 192.168.1.5:8096" : "e.g. nas.local/Movies", focused: form.row == 0,
                       submit: submit) { tv.tapShareForm(0) }
            AdderField(label: "User name", text: binding(\.user), placeholder: form.jellyfin ? "Your Jellyfin user" : "Leave empty for guest",
                       focused: form.row == 1, submit: submit) { tv.tapShareForm(1) }
            AdderField(label: "Password", text: binding(\.password), placeholder: "Password", focused: form.row == 2, secure: true,
                       submit: submit) { tv.tapShareForm(2) }
            ShelfButton(title: buttonTitle, systemImage: form.jellyfin ? "server.rack" : "externaldrive.connected.to.line.below",
                        focused: form.row == 3, glass: false) {
                tv.tapShareForm(3)
            }
            if let message = form.message {
                Text(message)
                    .font(.tv(.caption2, emphasized: true))
                    .foregroundStyle(Color(hex: "#FF8A80"))
                    .lineLimit(2)
            }
        }
        .padding(56)
        .frame(width: 1000, alignment: .leading)
        .tvPanel(in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .foregroundStyle(.white)
        .frame(width: canvas.width, height: canvas.height)
        .background(SheetBackdrop())
        .animation(Motion.focus, value: form)
    }

    private var buttonTitle: String {
        switch (form.jellyfin, form.connecting) {
        case (true, true): "Signing In…"
        case (true, false): "Sign In"
        case (false, true): "Connecting…"
        case (false, false): "Connect"
        }
    }
}


/// The pointer's hover lift, only while the pointer is in use: hover tracking on every card would be recalculated on
/// every frame a row scrolls, for nothing, when the remote is what's moving it.
private struct PointerLift: ViewModifier {
    @ObservedObject private var pointer = PointerActivity.shared

    func body(content: Content) -> some View {
        if pointer.active { content.hoverLift() } else { content }
    }
}

extension View {
    func pointerLift() -> some View { modifier(PointerLift()) }
}
