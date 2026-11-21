import SwiftUI

/// A movie's, an episode's, a video's or a show's page: one layout, filled from what's known, whatever the source.
/// The wide picture fills the screen (a frame from the video when nothing better is known); the title, what's known
/// about it and the buttons sit on the left; below them only the rows there's something for: a show's seasons and
/// episodes, the scenes of a file, its cast, its details.
struct MoviePageView: View {
    @ObservedObject var tv: TVController
    let page: MoviesBrowser.Page
    @ObservedObject private var library: MovieLibrary
    @ObservedObject private var work: MoviesWork
    @Environment(\.canvasSize) private var canvas

    init(tv: TVController, page: MoviesBrowser.Page) {
        _tv = ObservedObject(wrappedValue: tv)
        self.page = page
        _library = ObservedObject(wrappedValue: tv.movieLibrary)
        _work = ObservedObject(wrappedValue: tv.moviesWork)
    }

    var body: some View {
        let rows = tv.moviePageRows(page)
        let current = min(page.row, rows.count - 1)
        // The lower rows scroll up under the buttons once focus goes down to them
        let lifted = current >= 2 || (current == 1 && rows.count > 2)
        ZStack(alignment: .topLeading) {
            backdrop
            VStack(alignment: .leading, spacing: 0) {
                header
                buttons(focused: current == 0)
                    .padding(.top, 34)
                lower(rows: rows, current: current)
                    .padding(.top, 60)
            }
            .padding(.leading, MoviesLayout.pageLeft)
            .padding(.top, lifted ? 90 : 200)
            .animation(Motion.navigate, value: lifted)
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .clipped()
        .foregroundStyle(.white)
    }

    // MARK: What it is

    private var movie: Movie? {
        if case .movie(let path) = page.target { return library.movie(path) }
        return nil
    }

    private var show: MovieShow? {
        if case .show(let id) = page.target { return library.show(id) }
        return nil
    }

    private var info: MovieInfo {
        if let movie { return MovieInfo(movie: movie, library: library) }
        if let show { return MovieInfo(show: show) }
        return MovieInfo(entry: nil, library: library)
    }

    @ViewBuilder private var backdrop: some View {
        let info = info
        ZStack {
            Color(hex: "#0B0C10")
            if let file = info.backdrop {
                MovieImage(artwork: library.artwork, file: file, maxPixel: 1920) { Color.clear }
                    .frame(width: canvas.width, height: canvas.height)
                    .clipped()
            } else if let poster = info.poster {
                MovieImage(artwork: library.artwork, file: poster, maxPixel: 160) { Color.clear }
                    .frame(width: 160, height: 90).clipped().blur(radius: 7)
                    .scaleEffect(x: canvas.width / 160 * 1.16, y: canvas.height / 90 * 1.16)
                    .frame(width: canvas.width, height: canvas.height)
                    .opacity(0.7)
            }
            LinearGradient(stops: [.init(color: .black.opacity(0.9), location: 0), .init(color: .black.opacity(0.55), location: 0.42),
                                   .init(color: .clear, location: 0.75)], startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: .clear, location: 0.4), .init(color: .black.opacity(0.92), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .frame(width: canvas.width, height: canvas.height)
        .allowsHitTesting(false)
    }

    private var eyebrow: String {
        var parts: [String] = []
        if let movie {
            let kind = switch movie.category {
            case .movie: "MOVIE"
            case .episode: "EPISODE"
            case .video: library.isHomeVideo(movie.path) ? "HOME VIDEO" : "VIDEO"
            }
            parts.append(kind)
            if let source = library.source(of: movie) { parts.append(source.name.uppercased()) }
        } else if show != nil {
            parts.append("TV SHOW")
        }
        return parts.joined(separator: "  ·  ")
    }

    private var header: some View {
        let info = info
        return VStack(alignment: .leading, spacing: 22) {
            Text(eyebrow).font(.tv(.caption2, emphasized: true)).tracking(1.5).opacity(0.6)
            Text(info.title)
                .font(.tvHeroTitle)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: 1400, alignment: .leading)
                .shadow(color: .black.opacity(0.5), radius: 14, y: 4)
            MovieMetaLine(info: info)
            if let overview = info.overview {
                Text(overview)
                    .font(.tv(.body)).opacity(0.78).lineSpacing(4)
                    .lineLimit(3)
                    .frame(width: 900, alignment: .leading)
            } else if let movie, movie.category == .video, let line = recordedLine(movie) {
                Text(line).font(.tv(.body)).opacity(0.6)
            }
        }
    }

    /// "Recorded on iPhone 15 Pro · 3840×2160 · 1.1 GB", what's known of it.
    private func recordedLine(_ movie: Movie) -> String? {
        var parts: [String] = []
        if let device = movie.device { parts.append("Recorded on \(device)") }
        if let width = movie.width, let height = movie.height { parts.append("\(width)×\(height)") }
        if movie.size > 0 { parts.append(ByteCountFormatter.string(fromByteCount: movie.size, countStyle: .file)) }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    // MARK: Buttons

    private func buttons(focused rowFocused: Bool) -> some View {
        let buttons = tv.moviePageButtons(page)
        let target = tv.moviePageMovie(page)
        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 22) {
                ForEach(Array(buttons.enumerated()), id: \.offset) { index, button in
                    let focused = rowFocused && page.button == index
                    let (title, symbol) = describe(button, target: target)
                    MoviesButton(title: title, symbol: symbol, focused: focused,
                                 pressed: focused && work.pressed == "page-0-\(index)-0")
                        .onTapGesture { tv.tapMoviePage(row: 0, index: index) }
                        .accessibilityLabel(title ?? (button == .watched ? (target?.isWatched == true ? "Mark as Unwatched" : "Mark as Watched") : "More"))
                }
            }
            if let target, target.inProgress, let position = target.position, let duration = target.duration, duration > 0 {
                HStack(spacing: 18) {
                    Capsule().fill(.white.opacity(0.3)).frame(width: 340, height: 6)
                        .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: 340 * min(1, position / duration), height: 6) }
                    Text("\(clockText(position)) of \(clockText(duration))").font(.tv(.caption2)).monospacedDigit().opacity(0.6)
                }
            }
        }
    }

    private func describe(_ button: TVController.MoviePageButton, target: Movie?) -> (String?, String) {
        let episode = show != nil ? target?.episode.map { " " + $0.replacingOccurrences(of: " ", with: ", ") } ?? "" : ""
        switch button {
        case .play: return ("Play" + episode, "play.fill")
        case .resume: return ("Resume" + episode, "play.fill")
        case .startOver: return ("Start Over", "arrow.counterclockwise")
        case .watched: return (nil, target?.isWatched == true ? "checkmark.circle.fill" : "checkmark")
        case .more: return (nil, "ellipsis")
        }
    }

    // MARK: Below the buttons

    @ViewBuilder
    private func lower(rows: [TVController.MoviePageRow], current: Int) -> some View {
        VStack(alignment: .leading, spacing: 44) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, kind in
                switch kind {
                case .buttons: EmptyView()
                case .seasons: seasons(focused: current == index)
                case .episodes: episodes(row: index, focused: current == index)
                case .scenes: scenes(row: index, focused: current == index)
                }
            }
            if let cast = movie?.cast, !cast.isEmpty { castRow(cast) }
            if let movie, !movie.isRemote, movie.cast?.isEmpty ?? true { details(movie) }
        }
    }

    private func seasons(focused: Bool) -> some View {
        let seasons = show?.seasons ?? []
        return HStack(spacing: 14) {
            ForEach(Array(seasons.enumerated()), id: \.offset) { index, season in
                let chosen = index == page.season
                Text(season == 0 ? "Specials" : "Season \(season)")
                    .font(.tv(.callout, emphasized: chosen))
                    .foregroundStyle(chosen && focused ? .black : .white.opacity(chosen ? 1 : 0.6))
                    .padding(.horizontal, 30)
                    .frame(height: 64)
                    .background { if chosen { Capsule().fill(focused ? Color.white : Color.white.opacity(0.16)) } }
                    .scaleEffect(chosen && focused ? 1.06 : 1)
                    .contentShape(Capsule())
                    .onTapGesture { tv.tapMoviePage(row: 1, index: index) }
            }
        }
        .padding(.leading, -30)
        .animation(Motion.focus, value: page.season)
        .animation(Motion.focus, value: focused)
    }

    private func episodes(row: Int, focused: Bool) -> some View {
        let episodes = show.map { $0.episodes(in: tv.movieShowSeason(page, $0)) } ?? []
        let column = page.columns[row] ?? 0
        let size = MoviesLayout.wideGrid
        return VStack(alignment: .leading, spacing: 22) {
            Text("Episodes").font(.tv(.headline, emphasized: true)).opacity(focused ? 1 : 0.7)
            HStack(alignment: .top, spacing: 30) {
                ForEach(Array(episodes.enumerated()), id: \.element.path) { index, episode in
                    if abs(index - column) <= 6 {
                        let isFocused = focused && index == column
                        EpisodeCard(artwork: library.artwork, episode: episode, size: size, focused: isFocused,
                                    pressed: isFocused && work.pressed == "page-\(row)-\(page.button)-\(index)")
                            .pointerLift()
                            .onTapGesture { tv.tapMoviePage(row: row, index: index) }
                            .opacity(index < column - 1 ? 0 : 1)
                            .onAppear { library.artwork.want(episode.path) }
                    } else {
                        Color.clear.frame(width: size.width, height: 1)
                    }
                }
            }
            .offset(x: -CGFloat(max(0, column - 1)) * (size.width + 30))
        }
    }

    private func scenes(row: Int, focused: Bool) -> some View {
        let column = page.columns[row] ?? 0
        let duration = movie?.duration ?? 0
        return VStack(alignment: .leading, spacing: 22) {
            Text("Scenes").font(.tv(.headline, emphasized: true)).opacity(focused ? 1 : 0.7)
            HStack(spacing: 30) {
                ForEach(0..<6, id: \.self) { index in
                    let isFocused = focused && index == column
                    let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
                    VStack(alignment: .leading, spacing: 12) {
                        ZStack {
                            Color.white.opacity(0.06)
                            if let image = work.scenes[index] {
                                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                            }
                        }
                        .frame(width: 252, height: 142)
                        .clipShape(shape)
                        .overlay(shape.strokeBorder(.white.opacity(isFocused ? 0.95 : 0.1), lineWidth: isFocused ? 4 : 1.5))
                        .scaleEffect(isFocused ? (work.pressed == "page-\(row)-\(page.button)-\(index)" ? 1.02 : 1.09) : 1)
                        .shadow(color: .black.opacity(isFocused ? 0.6 : 0), radius: 20, y: 14)
                        Text(clockText(MovieArtwork.sceneTime(index, duration: duration)))
                            .font(.tv(.caption2)).monospacedDigit().opacity(0.6)
                            .offset(y: isFocused ? 8 : 0)
                    }
                    .zIndex(isFocused ? 1 : 0)
                    .pointerLift()
                    .onTapGesture { tv.tapMoviePage(row: row, index: index) }
                }
            }
            .animation(Motion.focus, value: column)
            .animation(Motion.focus, value: focused)
        }
    }

    private func castRow(_ cast: [Movie.Person]) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            Text("Cast & Crew").font(.tv(.headline, emphasized: true)).opacity(0.7)
            HStack(alignment: .top, spacing: 46) {
                ForEach(Array(cast.prefix(8).enumerated()), id: \.offset) { _, person in
                    VStack(spacing: 14) {
                        Text(person.name.split(separator: " ").prefix(2).map { String($0.prefix(1)) }.joined())
                            .font(.system(size: 40, weight: .semibold, design: .rounded)).opacity(0.85)
                            .frame(width: 132, height: 132)
                            .background(Color.white.opacity(0.12), in: Circle())
                        VStack(spacing: 4) {
                            Text(person.name).font(.tv(.caption1, emphasized: true)).lineLimit(1)
                            if let role = person.role { Text(role).font(.tv(.caption2)).opacity(0.55).lineLimit(1) }
                        }
                        .frame(width: 170)
                    }
                }
            }
        }
        .opacity(0.8)
    }

    /// A file's details, what's known of them.
    @ViewBuilder
    private func details(_ movie: Movie) -> some View {
        let source = library.source(of: movie)
        let items: [(String, String)] = [
            ("File", movie.url.lastPathComponent),
            ("Source", [source?.name, movie.size > 0 ? ByteCountFormatter.string(fromByteCount: movie.size, countStyle: .file) : nil]
                .compactMap { $0 }.joined(separator: " · ")),
            ("Video", [movie.codec.map(Self.codecName), movie.width.flatMap { width in movie.height.map { "\(width)×\($0)" } }]
                .compactMap { $0 }.joined(separator: " · ")),
            ("Audio", movie.audio ?? ""),
        ].filter { !$0.1.isEmpty }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 26) {
                Text("Details").font(.tv(.headline, emphasized: true)).opacity(0.7)
                HStack(alignment: .top, spacing: 70) {
                    ForEach(items, id: \.0) { label, value in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(label.uppercased()).font(.tv(.caption2, emphasized: true)).tracking(1).opacity(0.5)
                            Text(value).font(.tv(.caption1)).lineLimit(1).frame(maxWidth: 520, alignment: .leading)
                        }
                    }
                }
            }
            .opacity(0.8)
        }
    }

    static func codecName(_ code: String) -> String {
        switch code {
        case "hvc1", "hev1": "HEVC"
        case "avc1", "avc3": "H.264"
        case "dvh1", "dvhe": "HEVC (Dolby Vision)"
        case "ap4h", "apch", "apcn", "apcs", "apco": "ProRes"
        default: code.uppercased()
        }
    }
}

/// An episode on a show's page: its picture, where you stopped, its number and length.
private struct EpisodeCard: View {
    let artwork: MovieArtwork
    let episode: Movie
    let size: CGSize
    let focused: Bool
    let pressed: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .bottom) {
                WideArt(artwork: artwork, movie: episode)
                if let position = episode.position, let duration = episode.duration, duration > 0, episode.inProgress {
                    Capsule().fill(.white.opacity(0.3)).frame(height: 6)
                        .overlay(alignment: .leading) {
                            GeometryReader { geo in Capsule().fill(.white).frame(width: geo.size.width * min(1, position / duration)) }
                        }
                        .padding(.horizontal, 16).padding(.bottom, 14)
                }
                if episode.isWatched {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 28))
                        .symbolRenderingMode(.palette).foregroundStyle(.black, .white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(10)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(focused ? 0.95 : 0.1), lineWidth: focused ? 5 : 1.5))
            .shadow(color: .black.opacity(focused ? 0.6 : 0), radius: 24, y: 16)
            .scaleEffect(focused ? (pressed ? 1.02 : 1.09) : 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(episode.number.map { "Episode \($0)" } ?? episode.title)
                    .font(.tvCardTitle).lineLimit(1)
                if let duration = episode.duration {
                    Text(MovieInfo.length(duration)).font(.tvCardDetail).opacity(0.5)
                }
            }
            .frame(width: size.width, alignment: .leading)
            .offset(y: focused ? 10 : 0)
        }
        .zIndex(focused ? 1 : 0)
        .animation(Motion.focus, value: focused)
        .animation(Motion.press, value: pressed)
    }
}
