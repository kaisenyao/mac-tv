import SwiftUI

// The home screen follows Apple TV (tvOS 26 and 27): the focused dock app's Top Shelf fills the
// screen behind a Liquid Glass dock of 5:3 icons, with the next row peeking below. Moving
// up expands the Top Shelf; moving down scrolls into the full app grid. Everything is laid
// out on a canvas 1920 points wide (or 1080 tall, whichever fits), stretched along the
// other axis so it fills any window shape edge to edge.

/// Apple TV's Home Screen, measured from the pictures in Apple's own guide (tvOS 27) at 1920 points wide: six
/// 250×150 icons 48 apart and 90 from each side, rows 110 apart; the dock's glass 40 around the top row (so 50 from
/// each side of the screen, its corners concentric with the icons'). Home and Arrange Apps both lay out from these.
enum HomeGrid {
    static let tile = CGSize(width: 250, height: 150)
    static let tileCorner: CGFloat = 30
    static let spacing: CGFloat = 48
    static let dockPadding: CGFloat = 40
    static let rowGap: CGFloat = 110
    /// From one row's top to the next's.
    static let rowStride = tile.height + rowGap
    static let dockHeight = tile.height + dockPadding * 2
    static let dockCorner = tileCorner + dockPadding
    /// A focused icon is a fifth bigger, where it was (Apple TV's doesn't rise).
    static let focusScale: CGFloat = 1.2
    /// From the dock's bottom to the screen's, on Home.
    static let dockBottom: CGFloat = 67
    /// The first icon's left edge, where Home's content starts: the Top Shelf's text lines up with it.
    static let contentLeading: CGFloat = 90

    /// The dock's top edge on Home (it sits a fixed distance from the bottom; extra height goes to the Top Shelf).
    static func dockTop(_ canvas: CGSize) -> CGFloat { canvas.height - dockBottom - dockHeight }

    static func dockWidth(columns: Int) -> CGFloat {
        CGFloat(columns) * tile.width + CGFloat(columns - 1) * spacing + dockPadding * 2
    }
}

private struct Layout {
    /// On Home the rows under the dock sit this much closer, so the second row peeks over the bottom edge.
    static let peek: CGFloat = 28
    /// In the grid the dock's row is this far from the top, and at most this many rows are on screen above the last.
    static let gridTop: CGFloat = 97
    static let gridRowsAbove = 2

    let canvas: CGSize
    let columns: Int

    var dockFrame: CGRect {
        let width = HomeGrid.dockWidth(columns: columns)
        return CGRect(x: (canvas.width - width) / 2, y: HomeGrid.dockTop(canvas), width: width, height: HomeGrid.dockHeight)
    }

    /// How far everything moves when the Top Shelf has the screen (down, off the bottom), or focus is on a row of
    /// the grid (up: the dock's row to the top, then a row at a time once the focused row would leave the screen).
    func offset(shelfFocused: Bool, focusedRow: Int) -> CGFloat {
        if shelfFocused { return 420 }
        guard focusedRow > 0 else { return 0 }
        return Self.gridTop - top(ofRow: 0, inGrid: true) - CGFloat(max(0, focusedRow - Self.gridRowsAbove)) * HomeGrid.rowStride
    }

    /// The top of a row of apps: the dock's row in the dock, the rest below it.
    func top(ofRow row: Int, inGrid: Bool) -> CGFloat {
        let dockRowTop = dockFrame.minY + HomeGrid.dockPadding
        guard row > 0 else { return dockRowTop }
        return dockRowTop + CGFloat(row) * HomeGrid.rowStride - (inGrid ? 0 : Self.peek)
    }

    /// Where the app at a place on Home is, before the grid scrolls.
    func tileFrame(_ index: Int, inGrid: Bool) -> CGRect {
        CGRect(x: dockFrame.minX + HomeGrid.dockPadding + CGFloat(index % columns) * (HomeGrid.tile.width + HomeGrid.spacing),
               y: top(ofRow: index / columns, inGrid: inGrid), width: HomeGrid.tile.width, height: HomeGrid.tile.height)
    }
}

struct HomeView: View {
    @ObservedObject var tv: TVController
    @Environment(\.canvasSize) private var canvas

    private var shelfFocused: Bool {
        // The status row sits above the Top Shelf, so the banner stays open while it has focus.
        switch tv.focus {
        case .shelf, .status: return true
        case .app: return false
        }
    }

    private var focusedRow: Int {
        if case .app(let index) = tv.focus { return index / tv.columns }
        return 0
    }

    var body: some View {
        let layout = Layout(canvas: canvas, columns: tv.columns)
        let gridOffset = layout.offset(shelfFocused: shelfFocused, focusedRow: focusedRow)

        ZStack(alignment: .topLeading) {
            TopShelf(tv: tv, expanded: shelfFocused)
                .offset(y: gridOffset < 0 ? gridOffset : 0)
                .opacity(tv.inGrid ? 0 : 1)

            AppGrid(tv: tv)
                // An expanded banner takes the whole screen; the dock slides away, off the bottom.
                .offset(y: gridOffset)

            // Press and hold Select on an app: its menu, grown out of the app, over all of Home (see AppMenuLayer).
            let panel = tv.organizer
            let held = panel?.onHome == true ? panel?.selectedID.flatMap { id in tv.services.firstIndex { $0.id == id } } : nil
            AppMenuLayer(tv: tv, menu: held == nil ? nil : panel?.menu, id: held.map { tv.services[$0].id },
                         name: held.map { tv.services[$0].name } ?? "",
                         tile: held.map { layout.tileFrame($0, inGrid: tv.inGrid).offsetBy(dx: 0, dy: gridOffset) },
                         rightOfTile: (held ?? 0) % tv.columns < tv.columns - 2, size: canvas)
                .zIndex(10)
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .clipped()
        .foregroundStyle(.white)
        .animation(Motion.navigate, value: focusedRow)
        .animation(Motion.navigate, value: tv.inGrid)
        .animation(Motion.navigate, value: shelfFocused)
        .animation(Motion.appear, value: tv.shelfAppIndex)
    }
}

/// Home's status row, as tvOS 26's: a glass capsule with the time and the avatar; up into it (or a click on it), and
/// while Control Center or the profiles are open, it widens to the status glyphs and the Control Center button. Left
/// and Right move between the button and the avatar.
///
/// It's a layer of its own above Home (RootView), not part of HomeView: a panel opened from it (Control Center, the
/// profiles) dims Home under the row and never the row itself, as Apple TV's Control Center keeps its time, glyphs and
/// buttons at full brightness.
struct HomeStatusRow: View {
    @ObservedObject var tv: TVController
    @ObservedObject private var siriRemote = SiriRemoteStatus.shared
    @Environment(\.canvasSize) private var canvas

    var body: some View {
        StatusCapsule(tv: tv, glyphs: glyphs)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, TopBar.trailing)
            .padding(.top, TopBar.top)
            .modifier(ClearsCornerForNotices(notices: tv.notices, inGrid: tv.inGrid))
            .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
            .clipped()
            .foregroundStyle(.white)
            .animation(Motion.navigate, value: tv.inGrid)
    }

    /// A Siri Remote or game controller that's connected, and the lid staying awake.
    private var glyphs: [String] {
        [siriRemote.connected ? "appletvremote.gen4.fill" : nil, tv.controller == nil ? nil : "gamecontroller.fill",
         tv.lidSleepOff ? "laptopcomputer" : nil].compactMap { $0 }
    }
}

/// The status row itself: the time and the avatar in a glass capsule. It widens (the glyphs and the
/// Control Center button come in between) while focus is in it, or Control Center or the profiles are open from it;
/// the focused button grows on a white platter. While one of the two is open the row is Apple TV's Control Center
/// row: the capsule's glass is gone, the open one is big and the other small.
private struct StatusCapsule: View {
    @ObservedObject var tv: TVController
    let glyphs: [String]

    /// The open (or focused) button beside the avatar's own size, and the other one while one is open: 58 and 34
    /// points on Apple TV.
    private static let selected: CGFloat = 58 / TopBar.avatar
    private static let resting: CGFloat = 34 / TopBar.avatar

    var body: some View {
        let controlCenterOpen = tv.controlCenter != nil, profilesOpen = tv.profilePicker?.dropdown == true
        let open = controlCenterOpen || profilesOpen
        let expanded = open || { if case .status = tv.focus { true } else { false } }()
        HStack(spacing: 13) {
            StatusClock(twentyFour: tv.preferences.twentyFourHourTime)
                .padding(.trailing, expanded ? 6 : 0)
                .contentShape(Rectangle())
                .onTapGesture { tv.setFocus(.status(.controlCenter)) }   // a click on the time opens the row up
            if expanded {
                ForEach(glyphs, id: \.self) { symbol in
                    Image(systemName: symbol).font(.system(size: 22, weight: .medium)).opacity(0.9)
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
                // Control Center, like Apple TV's: white with focus; while it's open (focus is in its tiles) a pale disc
                let focused = tv.focus == .status(.controlCenter) && !controlCenterOpen
                let lit = focused || controlCenterOpen
                Button { tv.controlCenter == nil ? tv.activateStatus(.controlCenter) : (tv.controlCenter = nil) } label: {
                    Image(systemName: "switch.2")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(focused ? .black : .white)
                        .frame(width: TopBar.avatar, height: TopBar.avatar)
                        .background(Circle().fill(.white).opacity(focused ? 1 : controlCenterOpen ? 0.3 : 0))
                        .contentShape(Circle())
                        .scaleEffect(lit ? Self.selected : 1)
                        .shadow(color: .black.opacity(focused ? 0.3 : 0), radius: 10, y: 6)
                }
                .buttonStyle(PressDip())
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
            Button { tv.activateStatus(.profile) } label: {
                ProfileAvatar(profile: tv.profile, size: TopBar.avatar)
                    .avatarFocus(focused: tv.focus == .status(.profile), lit: profilesOpen)
                    .scaleEffect(controlCenterOpen ? Self.resting : 1)
                    .contentShape(Circle())
            }
            .buttonStyle(PressDip())
        }
        .padding(.leading, 26)
        .padding(.trailing, TopBar.inset)
        .frame(height: TopBar.height)
        .tvGlass(.clear, in: Capsule(), enabled: !open)
        .animation(Motion.focus, value: tv.focus)
        .animation(Motion.focus, value: expanded)
        .animation(Motion.focus, value: open)
        .animation(Motion.appear, value: glyphs)
    }
}

/// The status row's time, plain like Apple TV's, 12- or 24-hour as Settings › General says.
private struct StatusClock: View {
    let twentyFour: Bool

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(TimeOfDay.text(context.date, twentyFour: twentyFour))
                .font(TopBar.clock)
                .monospacedDigit()
                .shadow(color: .black.opacity(0.35), radius: 5, y: 1)
        }
    }
}

/// Slides the status row up off the screen while the grid, the volume or a controller banner has
/// the corner. It slides rather than fading, so the glass never goes translucent.
private struct ClearsCornerForNotices: ViewModifier {
    @ObservedObject var notices: Notices
    let inGrid: Bool

    func body(content: Content) -> some View {
        content.offset(y: inGrid || notices.volume != nil || notices.controller != nil ? -200 : 0)
    }
}

/// The time in a glass pill (Movies' corner), 12- or 24-hour as Settings › General says.
struct ClockPill: View {
    let twentyFour: Bool

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(TimeOfDay.text(context.date, twentyFour: twentyFour))
                .font(TopBar.text)
                .monospacedDigit()
                .padding(.horizontal, 24)
                .frame(height: TopBar.height)
                .tvGlass(in: Capsule())
        }
    }
}

// MARK: Dock and app grid

struct AppGrid: View {
    @ObservedObject var tv: TVController
    @Environment(\.canvasSize) private var canvas

    var body: some View {
        let layout = Layout(canvas: canvas, columns: tv.columns)
        // Each cell carries its own app, keyed by id, so a cell never reads a list that has
        // since changed (removing an app shortens it).
        let cells = tv.services.enumerated().map { AppCell.Item(index: $0.offset, service: $0.element) }
        let rows = stride(from: 0, to: cells.count, by: tv.columns).map {
            Array(cells[$0..<min($0 + tv.columns, cells.count)])
        }
        ZStack(alignment: .topLeading) {
            GlassDock()
                .frame(width: layout.dockFrame.width, height: layout.dockFrame.height)
                .offset(x: layout.dockFrame.minX, y: layout.dockFrame.minY)

            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(spacing: HomeGrid.spacing) {
                    ForEach(row) { item in
                        AppCell(tv: tv, item: item, showsLabel: rowIndex > 0 || tv.inGrid)
                    }
                }
                .offset(x: layout.dockFrame.minX + HomeGrid.dockPadding, y: layout.top(ofRow: rowIndex, inGrid: tv.inGrid))
            }
        }
    }
}

/// tvOS 26's dock: Liquid Glass around the top row, its corners concentric with the icons'. It stays around the top
/// row in the grid too, as Apple TV's does, and scrolls away with that row.
struct GlassDock: View {
    var body: some View {
        Color.clear.tvGlass(.clear, in: RoundedRectangle(cornerRadius: HomeGrid.dockCorner, style: .continuous))
    }
}

struct AppCell: View {
    struct Item: Identifiable {
        let index: Int
        let service: Service
        var id: String { service.id }
    }

    @ObservedObject var tv: TVController
    let item: Item
    let showsLabel: Bool

    var body: some View {
        let index = item.index, service = item.service
        let focused = tv.focus == .app(index)
        TiltingAppTile(pointer: tv.pointerTilt, service: service, focused: focused)
            .overlay(alignment: .bottom) {
                Text(service.name)
                    .font(.tv(.caption1))
                    .fixedSize()
                    .offset(y: 50)
                    .opacity(focused && showsLabel ? 1 : 0)
                    .offset(y: focused && showsLabel ? 0 : -8)
                    .animation(Motion.focus, value: focused)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    tv.hover(index, tilt: CGSize(width: location.x / HomeGrid.tile.width - 0.5,
                                                 height: location.y / HomeGrid.tile.height - 0.5))
                case .ended:
                    tv.tilt = .zero
                }
            }
            .onTapGesture {
                // With an app's menu open on Home, a click elsewhere just closes it.
                if tv.organizer?.onHome == true { tv.organizer = nil; return }
                tv.setFocus(.app(index))
                tv.open(service)
            }
            .zIndex(focused ? 1 : 0)
    }
}

/// The pointer over the focused tile, apart from `TVController` so following it redraws only tiles.
final class PointerTilt: ObservableObject {
    @Published var value: CGSize = .zero
}

/// An app tile that leans towards the pointer while it has focus.
private struct TiltingAppTile: View {
    @ObservedObject var pointer: PointerTilt
    let service: Service
    let focused: Bool

    var body: some View {
        AppTile(service: service, focused: focused, tilt: focused ? pointer.value : .zero)
    }
}

struct AppTile: View {
    let service: Service
    let focused: Bool
    let tilt: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: HomeGrid.tileCorner, style: .continuous)
        let tilt = reduceMotion ? .zero : tilt
        artwork
            .frame(width: HomeGrid.tile.width, height: HomeGrid.tile.height)
            .clipShape(shape)
            // tvOS light: a soft glare on the focused tile that slides with the pointer.
            .overlay {
                RadialGradient(colors: [.white.opacity(0.32), .white.opacity(0)],
                               center: UnitPoint(x: 0.5 + tilt.width * 1.2, y: 0.05 + tilt.height * 1.2),
                               startRadius: 0, endRadius: HomeGrid.tile.width * 0.75)
                    .blendMode(.plusLighter)
                    .clipShape(shape)
                    .opacity(focused ? 1 : 0)
                    .allowsHitTesting(false)
            }
            // A glass edge: a faint rim at rest, a bright top highlight when focused.
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(focused ? 0.55 : 0.14), .white.opacity(focused ? 0.08 : 0.03)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: focused ? 1.5 : 1)
            }
            .rotation3DEffect(.degrees(-tilt.height * 10), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .rotation3DEffect(.degrees(tilt.width * 12), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .scaleEffect(focused ? (reduceMotion ? 1.06 : HomeGrid.focusScale) : 1)
            // Resting icons sit flat on the glass; only the focused one casts a shadow.
            .shadow(color: .black.opacity(focused ? 0.6 : 0), radius: focused ? 28 : 0, y: focused ? 24 : 0)
            .animation(Motion.focus, value: focused)
            .animation(Motion.tilt, value: tilt)
    }

    @ViewBuilder private var artwork: some View {
        if case .addApp = service.kind {
            // Store: the white "A" (Icons/store.svg) on App Store's blue.
            ZStack {
                LinearGradient(colors: [Color(hex: "#1BC7FC"), Color(hex: "#027AFF")],
                               startPoint: .top, endPoint: .bottom)
                if let glyph = StoreTile.glyph {
                    let mark = TileArt.markSize(aspect: glyph.size.width / max(1, glyph.size.height))
                    Image(nsImage: glyph).resizable().interpolation(.high)
                        .frame(width: mark.width, height: mark.height)
                }
            }
        } else if case .movies = service.kind {
            ZStack {
                LinearGradient(colors: [Color(hex: "#5E5CE6"), Color(hex: "#1F1A6B")],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                let mark = TileArt.markSize(aspect: 1)
                Image(systemName: "film.stack")
                    .resizable().fontWeight(.medium).scaledToFit()
                    .frame(width: mark.width, height: mark.height)
                    .foregroundStyle(.white)
            }
        } else if case .settings = service.kind {
            // Settings, as on Apple TV: the gears on a dark disc (Icons/settings.svg), on silver.
            ZStack {
                LinearGradient(colors: [Color(hex: "#DEDEE1"), Color(hex: "#A2A2A7")],
                               startPoint: .top, endPoint: .bottom)
                if let gears = SettingsTile.gears {
                    let mark = TileArt.markSize(aspect: 1)
                    Image(nsImage: gears).resizable().interpolation(.high)
                        .frame(width: mark.width, height: mark.height)
                }
            }
        } else if service.id == BilibiliStore.appID, let icon = Icons.image(for: service) {
            // 整个方形图标完整放进卡片（小电视轮廓不裁掉），四周用图标自己的底色补满。
            // 图标四角是白的，裁成圆角后和底色接上，看不出边界。
            ZStack {
                Color(hex: "#EC5D85")
                Image(nsImage: icon).resizable().interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 126, height: 126)
                    .clipShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
            }
        } else if service.id == DedaoStore.appID, let icon = DedaoTile.icon {
            // 得到的官方图标（Icons/dedao-icon.png）：写着"得到"的那本书是图案，和别的 App 的图案一样大
            // （TileArt.markSize）；图标底边贴着卡片底边，猫头鹰从下面探出头，和官方图标一样；底色是图标自己的橙色
            let side = TileArt.markSize(aspect: DedaoTile.book.width / DedaoTile.book.height).width / DedaoTile.book.width
            Color(hex: "#FF6B00").overlay(alignment: .bottom) {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: side, height: side)
            }
        } else if let tile = Icons.tile(for: service) {
            Image(nsImage: tile).resizable().interpolation(.high)
        } else {
            ZStack {
                Color(hex: "#2C2C2E")
                Text(service.name).font(.tv(.body, emphasized: true))
            }
        }
    }
}

// MARK: Top Shelf

/// 得到在主屏上的卡片：它的官方图标，和图标里那本书的位置（见上面的卡片）
@MainActor
enum DedaoTile {
    static let icon: NSImage? = Bundle.main.url(forResource: "dedao-icon.png", withExtension: nil, subdirectory: "Icons")
        .flatMap(NSImage.init(contentsOf:))
    /// Where the book (the mark) is in the icon, as fractions of its side: measured from dedao-icon.png.
    static let book = CGRect(x: 0.117, y: 0.206, width: 0.766, height: 0.44)
}

/// Store 磁贴上的白色"A"
@MainActor
enum StoreTile {
    static let glyph: NSImage? = Bundle.main.url(forResource: "store.svg", withExtension: nil, subdirectory: "Icons")
        .flatMap(NSImage.init(contentsOf:))
}

/// Settings 磁贴上的齿轮圆盘（照 Apple TV 的设置图标）。矢量图里有几千个点，载入时画成一张位图
/// （够放大到聚焦时的 1.2 倍、Retina），主屏动画时不再反复画矢量。
@MainActor
enum SettingsTile {
    static let gears: NSImage? = {
        guard let url = Bundle.main.url(forResource: "settings.svg", withExtension: nil, subdirectory: "Icons"),
              let svg = NSImage(contentsOf: url) else { return nil }
        let side = 384
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        svg.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(bitmap)
        return image
    }()
}

// MARK: A TV press with nothing to do

/// Pressed on Home: the apps give in a little and settle back, as an iPhone's Home Screen does, with Mac TV's own
/// curves (a press in, focus's curve back). The wallpaper stays.
struct HomeBounce: ViewModifier {
    let nudge: HomeNudge
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: 1.0, trigger: nudge) { view, scale in
            view.scaleEffect(scale)
        } keyframes: { _ in
            KeyframeTrack(\.self) {
                if nudge.kind == .bounce, nudge.count > 0, !reduceMotion {
                    SpringKeyframe(0.97, duration: 0.18, spring: .smooth(duration: 0.18))
                    SpringKeyframe(1, duration: 0.32, spring: .smooth(duration: 0.32))
                } else {
                    LinearKeyframe(1, duration: 0.01)
                }
            }
        }
    }
}

/// Pressed twice with no app in the background: the frosted backdrop the App Switcher opens on comes over Home, at
/// the pace sheets appear, finds nothing to show and goes again.
struct HomeEmptySwitcher: ViewModifier {
    let nudge: HomeNudge

    func body(content: Content) -> some View {
        content.overlay {
            SheetBackdrop()
                .keyframeAnimator(initialValue: 0.0, trigger: nudge) { view, shown in
                    view.opacity(shown)
                } keyframes: { _ in
                    KeyframeTrack(\.self) {
                        if nudge.kind == .nothingInBackground, nudge.count > 0 {
                            SpringKeyframe(1, duration: 0.25, spring: .smooth(duration: 0.35))
                            LinearKeyframe(1, duration: 0.1)
                            SpringKeyframe(0, duration: 0.35, spring: .smooth(duration: 0.35))
                        } else {
                            LinearKeyframe(0, duration: 0.01)
                        }
                    }
                }
                .allowsHitTesting(false)
        }
    }
}
