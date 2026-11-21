import AppKit
import SwiftUI

struct TopShelf: View {
    @ObservedObject var tv: TVController
    /// 哔哩哔哩、网易云、YouTube 的轮播（内容到了、换了一张时这里要跟着重画）
    @ObservedObject private var appShelf: AppShelf
    let expanded: Bool
    @Environment(\.canvasSize) private var canvas

    init(tv: TVController, expanded: Bool) {
        _tv = ObservedObject(wrappedValue: tv)
        _appShelf = ObservedObject(wrappedValue: tv.appShelf)
        self.expanded = expanded
    }

    var body: some View {
        let service = tv.shelfService
        Group {
            if AppShelf.services.contains(service.id), appShelf.current(for: service.id) != nil {
                AppShelfBanner(shelf: appShelf, tv: tv, service: service, expanded: expanded)
            } else if tv.shelfCount > 0 {
                AppBanner(tv: tv, service: service, expanded: expanded)
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .id(service.id)
        .transition(.opacity)
    }
}

/// 没有轮播的应用（网站、Mac 应用、Steam 游戏、影片）选中时的主屏顶部：这个应用的颜色铺满，左下写名字；
/// 影片是片库里的海报 / 剧照，左下是这部片子的标签、片名、年份 · 类型 · 片长、简介（和别的应用同一个格子，见 ShelfGrid）；
/// Steam 游戏是它自己的图。从底下往上进来是"Open"。
///（哔哩哔哩、网易云、YouTube 的轮播见 AppShelf：那里显示的是你自己账号里的内容）
struct AppBanner: View {
    @ObservedObject var tv: TVController
    /// 影片的海报跟着主屏轮播的节拍换
    @ObservedObject private var clock: AppShelf
    @ObservedObject private var movieLibrary: MovieLibrary
    @Environment(\.canvasSize) private var canvas
    let service: Service
    let expanded: Bool

    init(tv: TVController, service: Service, expanded: Bool) {
        _tv = ObservedObject(wrappedValue: tv)
        _clock = ObservedObject(wrappedValue: tv.appShelf)
        _movieLibrary = ObservedObject(wrappedValue: tv.movieLibrary)
        self.service = service
        self.expanded = expanded
    }

    /// A Steam game's own art: its store screenshot or library hero, else its dock tile. Other apps keep
    /// their colour wash: their icons are too small to fill the screen.
    private var steamArt: (id: String, image: NSImage)? {
        guard case .steam = service.kind else { return nil }
        if let hero = SteamShelfArt.image(at: tv.library.heroFile(for: service.id)) { return ("\(service.id)-hero", hero) }
        return Icons.tile(for: service).map { ("\(service.id)-tile", $0) }
    }

    /// What the Top Shelf shows now: Movies art, or a Steam game's own art.
    private var backdrop: (id: String, name: String, image: NSImage, cover: Bool, appOwned: Bool)? {
        if case .movies = service.kind {
            let shelf = movieLibrary.shelf
            if !shelf.isEmpty {
                let pick = shelf[clock.beat % shelf.count]
                // Posters sit on the right like album covers; frames from the film fill the screen. Only the picture
                // showing is decoded, at the size it's drawn, and kept in Movies' picture cache.
                if let image = movieLibrary.artwork.image(pick.file, maxPixel: 1920) {
                    return (pick.path, movieLibrary.movie(pick.path)?.displayTitle ?? "Videos",
                            image, image.size.height > image.size.width, false)
                }
            }
        }
        if let art = steamArt {
            return (art.id, service.name, art.image, false, true)
        }
        return nil
    }

    /// The film showing in Movies' Top Shelf, and what the shelf says about it, as the Movies app does: the tag is the
    /// row it would be in (Continue Watching, Recently Added), the meta line its year, genre and length (or how much is
    /// left), then its overview.
    private func film(_ path: String) -> (tag: String, title: String, meta: String, overview: String?)? {
        guard let movie = movieLibrary.movie(path) else { return nil }
        let info = MovieInfo(movie: movie, library: movieLibrary)
        var parts = info.parts
        let watching = movieLibrary.continueWatching.contains { $0.path == path }
        if watching, let duration = movie.duration, let position = movie.position, duration > position {
            parts.removeAll { $0 == MovieInfo.length(duration) }
            parts.append(MovieInfo.left(duration - position))
        }
        let tag = watching ? "Continue Watching" : movieLibrary.recentlyAdded.contains { $0.path == path } ? "Recently Added" : "Library"
        return (tag, info.title, parts.joined(separator: " · "), info.overview)
    }

    var body: some View {
        let show = backdrop
        let about = show.flatMap { $0.appOwned ? nil : film($0.id) }
        ZStack(alignment: .topLeading) {
            // A Steam game's art is the base layer, so it can't be lost under a stale backdrop.
            if let show, show.appOwned {
                AppArtBackdrop(image: show.image)
                    .frame(width: canvas.width, height: canvas.height)
                    .clipped()
                    .id(show.id)
                    .transition(.opacity)
            } else {
                Artwork(accent: service.accent, deep: service.deep)
                    .frame(width: canvas.width, height: canvas.height)
                    .clipped()
            }
            // Films in the Movies library, cross-fading one to the next, like Apple TV's Top Shelf.
            if let show, !show.appOwned {
                if show.cover {
                    AlbumBackdrop(image: show.image)
                        .id(show.id)
                        .transition(.opacity)
                } else {
                    // One view for every film: it cross-fades to the next picture itself, in Core Animation.
                    ShowBackdrop(image: show.image, since: clock.beatStarted)
                }
            }
            // Legibility: a wash from the left for the text, a bottom wash for the dock or the button.
            LinearGradient(stops: [.init(color: .black.opacity(about != nil || show == nil ? 0.7 : (expanded ? 0.6 : 0.18)), location: 0),
                                   .init(color: .black.opacity(about != nil || expanded ? 0.35 : 0.12), location: 0.4),
                                   .init(color: .clear, location: 0.65)],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: .clear, location: 0.45),
                                   .init(color: .black.opacity(show == nil ? 0.75 : 0.85), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            if show != nil {
                LinearGradient(colors: [.black.opacity(0.25), .clear], startPoint: .top, endPoint: .center)
            }

            // The column on the Top Shelf's grid (ShelfGrid), where every app's is. A Steam game's art carries itself.
            if show?.appOwned != true {
                ShelfColumn(width: ShelfGrid.wideColumn(canvas), expanded: expanded) {
                    Group {
                        if let about {
                            ShelfInfo(title: about.title, shadow: true) {
                                ShelfTag(text: about.tag, color: Color(hex: service.accent))
                            } meta: {
                                Text(about.meta)
                            } detail: {
                                if let overview = about.overview, !overview.isEmpty {
                                    Text(overview)
                                        .font(ShelfGrid.bodyFont)
                                        .foregroundStyle(.white.opacity(ShelfGrid.bodyOpacity))
                                        .lineSpacing(ShelfGrid.bodyLineSpacing)
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .id(show?.id)
                            .transition(.opacity)
                        } else {
                            // Without art (or a film's details), the app's name, where a title goes.
                            Text(service.name)
                                .font(.tvHeroTitle)
                                .lineLimit(2)
                                .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        }
                    }
                } buttons: {
                    // Videos: Play the film showing (Resume one that's under way); otherwise the app opens
                    let film = isMovies && about != nil
                    ShelfButton(title: film ? (about?.tag == "Continue Watching" ? "Resume" : "Play") : "Open \(service.name)",
                                systemImage: film ? "play.fill" : "arrow.up.right", focused: tv.focus == .shelf(0)) {
                        tv.setFocus(.shelf(0)); tv.activateShelf(0)
                    }
                    .tvGlassTransition()
                } dots: {
                    // Movies' films turn on the Top Shelf's beat: which one is showing.
                    let count = isMovies ? movieLibrary.shelf.count : 0
                    ShelfDots(count: count, current: count > 0 ? clock.beat % count : 0)
                        .opacity(count > 1 ? 1 : 0)
                }
            }
        }
    }

    private var isMovies: Bool { if case .movies = service.kind { true } else { false } }
}

/// Full-bleed Steam art via a layer (SwiftUI `Image(nsImage:)` was unreliable for some Steam PNGs).
struct AppArtBackdrop: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        view.layer?.contentsGravity = .resizeAspectFill
        view.layer?.contents = Self.bitmap(image)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        // SwiftUI updates the view on every redraw; a new picture gets a new view (its id changes).
        guard let bitmap = Self.bitmap(image), view.layer?.contents as AnyObject? !== bitmap else { return }
        view.layer?.contents = bitmap
    }

    private static func bitmap(_ image: NSImage) -> CGImage? {
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) { return cg }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.cgImage
    }
}

/// tvOS buttons: glass at rest, white with dark text when focused.
struct ShelfButton: View {
    let title: String
    var systemImage: String? = nil
    let focused: Bool
    /// Glass over artwork, like the Top Shelf; a plain platter on a frosted sheet, where glass has nothing to refract.
    var glass = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.tv(.callout, emphasized: true))
            .padding(.horizontal, 38)
            .frame(height: 72)
            .foregroundStyle(focused ? .black : .white)
            .background {
                if !glass { Capsule().fill(.white.opacity(0.12)) }
            }
            .focusPlatter(Capsule(), focused: focused, glass: glass)
            .scaleEffect(focused ? 1.08 : 1)
            .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: 20, y: 14)
            .animation(Motion.focus, value: focused)
        }
        .buttonStyle(.plain)
    }
}

/// 一个应用自己颜色的底图（没有轮播的应用，主屏顶部铺的就是它）
struct Artwork: View {
    let accent: String
    let deep: String

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: deep), Color(hex: "#050608")], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(hex: accent).opacity(0.8), Color(hex: accent).opacity(0.2), .clear],
                           center: UnitPoint(x: 0.74, y: 0.28), startRadius: 0, endRadius: 900)
            RadialGradient(colors: [Color(hex: accent).opacity(0.36), .clear],
                           center: UnitPoint(x: 0.56, y: 0.62), startRadius: 0, endRadius: 420)
        }
    }
}
