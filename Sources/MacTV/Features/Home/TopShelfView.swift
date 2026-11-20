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

/// 没有轮播的应用（网站、Mac 应用、Steam 游戏、影片）选中时的主屏顶部：这个应用的颜色铺满，左上角写名字；
/// 影片是片库里的海报 / 剧照，Steam 游戏是它自己的图。从底下往上进来是"Open"。
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
                    return (pick.path, movieLibrary.movie(pick.path)?.displayTitle ?? "Movies",
                            image, image.size.height > image.size.width, false)
                }
            }
        }
        if let art = steamArt {
            return (art.id, service.name, art.image, false, true)
        }
        return nil
    }

    var body: some View {
        let show = backdrop
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
            // Legibility: a soft top-left wash for the name, a bottom wash for the dock or button.
            LinearGradient(stops: [.init(color: .black.opacity(expanded ? 0.8 : (show == nil ? 0.55 : 0.18)), location: 0),
                                   .init(color: .black.opacity(expanded ? 0.4 : 0.15), location: 0.4),
                                   .init(color: .clear, location: 0.65)],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: .clear, location: 0.45),
                                   .init(color: .black.opacity(show == nil ? 0.75 : 0.85), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            if show != nil {
                LinearGradient(colors: [.black.opacity(0.25), .clear], startPoint: .top, endPoint: .center)
            }

            VStack(alignment: .leading, spacing: 12) {
                if show == nil {
                    // The artwork alone carries it; nothing is drawn over it. Without art, the app's name.
                    Text(service.name)
                        .font(.tv(.title1, emphasized: true))
                        .lineLimit(2)
                        .minimumScaleFactor(0.5)
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                }
                if expanded {
                    ShelfButton(title: "Open \(service.name)", systemImage: "arrow.up.right", focused: tv.focus == .shelf(0)) {
                        tv.setFocus(.shelf(0)); tv.activateShelf(0)
                    }
                    .padding(.top, 20)
                    .tvGlassTransition()
                }
            }
            .frame(width: 1100, alignment: .leading)
            .padding(.leading, 96)
            .frame(maxHeight: .infinity, alignment: expanded ? .bottomLeading : .topLeading)
            .padding(.top, 96)
            .padding(.bottom, 110)
        }
    }
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
