import SwiftUI

// The home screen follows Apple TV (tvOS 26): the focused dock app's Top Shelf fills the
// screen behind a frosted glass dock of 5:3 icons, with the next row peeking below. Moving
// up expands the Top Shelf; moving down scrolls into the full app grid. Everything is laid
// out on a canvas 1920 points wide (or 1080 tall, whichever fits), stretched along the
// other axis so it fills any window shape edge to edge.

private struct Layout {
    static let tile = CGSize(width: 250, height: 150)
    static let tileSpacing: CGFloat = 28
    static let dockPadding: CGFloat = 44
    static let rowGap: CGFloat = 80

    let canvas: CGSize

    /// The dock sits a fixed distance from the bottom; extra height goes to the Top Shelf.
    var dockFrame: CGRect { CGRect(x: (canvas.width - 1728) / 2, y: canvas.height - 320, width: 1728, height: 220) }
    /// How far everything moves up when focus goes below the dock.
    var gridShift: CGFloat { dockFrame.midY - Self.tile.height / 2 - 75 }

    /// The top of a row of apps: the dock's row in the dock, the rest below it.
    func top(ofRow row: Int) -> CGFloat {
        let dockRowTop = dockFrame.midY - Self.tile.height / 2
        guard row > 0 else { return dockRowTop }
        // The second row peeks just below the dock.
        return dockFrame.maxY + 60 + CGFloat(row - 1) * (Self.tile.height + Self.rowGap)
    }

    /// Where the app at a place on Home is, before the grid scrolls.
    func tileFrame(_ index: Int, columns: Int) -> CGRect {
        CGRect(x: dockFrame.minX + Self.dockPadding + CGFloat(index % columns) * (Self.tile.width + Self.tileSpacing),
               y: top(ofRow: index / columns), width: Self.tile.width, height: Self.tile.height)
    }
}

struct HomeView: View {
    @ObservedObject var tv: TVController
    @ObservedObject private var siriRemote = SiriRemoteStatus.shared
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
        let layout = Layout(canvas: canvas)
        let rowStride = Layout.tile.height + Layout.rowGap
        // Dock (row 0) sits at rest; row 1 brings the grid up; each subsequent row scrolls by rowStride.
        let gridOffset: CGFloat = shelfFocused ? 420 : (focusedRow > 0 ? -layout.gridShift - CGFloat(focusedRow - 1) * rowStride : 0)

        ZStack(alignment: .topLeading) {
            TopShelf(tv: tv, expanded: shelfFocused)
                .offset(y: gridOffset < 0 ? gridOffset : 0)
                .opacity(tv.inGrid ? 0 : 1)

            AppGrid(tv: tv)
                // An expanded banner takes the whole screen; the dock slides away, off the bottom.
                .offset(y: gridOffset)

            // The status row, as tvOS 26's: a glass capsule with the time and the avatar; up into it (or a click on
            // it), and while Control Center or the profiles are open, it widens to the status glyphs and the Control
            // Center button. Left and Right move between the button and the avatar.
            StatusCapsule(tv: tv, glyphs: statusGlyphs)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, TopBar.trailing)
                .padding(.top, TopBar.top)
                .modifier(ClearsCornerForNotices(notices: tv.notices, inGrid: tv.inGrid))

            // Press and hold Select on an app: its menu, grown out of the app, over all of Home (see AppMenuLayer).
            let panel = tv.organizer
            let held = panel?.onHome == true ? panel?.selectedID.flatMap { id in tv.services.firstIndex { $0.id == id } } : nil
            AppMenuLayer(tv: tv, menu: held == nil ? nil : panel?.menu, id: held.map { tv.services[$0].id },
                         name: held.map { tv.services[$0].name } ?? "",
                         tile: held.map { layout.tileFrame($0, columns: tv.columns).offsetBy(dx: 0, dy: gridOffset) },
                         rightOfTile: (held ?? 0) % tv.columns < tv.columns - 2, size: canvas)
                .zIndex(10)
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .clipped()
        .foregroundStyle(.white)
        .animation(Motion.navigate, value: focusedRow)
        .animation(Motion.navigate, value: shelfFocused)
        .animation(Motion.appear, value: tv.shelfAppIndex)
    }
}

extension HomeView {
    /// The status row's glyphs: a Siri Remote or game controller that's connected, and the lid staying awake.
    private var statusGlyphs: [String] {
        [siriRemote.connected ? "appletvremote.gen4.fill" : nil, tv.controller == nil ? nil : "gamecontroller.fill",
         tv.lidSleepOff ? "laptopcomputer" : nil].compactMap { $0 }
    }
}

/// Home's status row, as tvOS 26's: the time and the avatar in a glass capsule. It widens (the glyphs and the
/// Control Center button come in between) while focus is in it, or Control Center or the profiles are open from it;
/// the focused button grows on a white platter. Everything in it is as big as the avatar (TopBar).
private struct StatusCapsule: View {
    @ObservedObject var tv: TVController
    let glyphs: [String]

    private var expanded: Bool {
        if case .status = tv.focus { return true }
        return tv.controlCenter != nil || tv.profilePicker?.dropdown == true
    }

    var body: some View {
        let expanded = expanded
        HStack(spacing: 16) {
            StatusClock(twentyFour: tv.preferences.twentyFourHourTime)
                .padding(.trailing, expanded ? 6 : 0)
                .contentShape(Rectangle())
                .onTapGesture { tv.setFocus(.status(.controlCenter)) }   // a click on the time opens the row up
            if expanded {
                ForEach(glyphs, id: \.self) { symbol in
                    Image(systemName: symbol).font(.system(size: 22, weight: .medium)).opacity(0.9)
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
                // Control Center: white while it's open or focused, like Apple TV's
                let focused = tv.focus == .status(.controlCenter)
                let lit = focused || tv.controlCenter != nil
                Button { tv.controlCenter == nil ? tv.activateStatus(.controlCenter) : (tv.controlCenter = nil) } label: {
                    Image(systemName: "switch.2")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(lit ? .black : .white)
                        .frame(width: TopBar.avatar, height: TopBar.avatar)
                        .background(Circle().fill(.white).opacity(lit ? 1 : 0))
                        .contentShape(Circle())
                        .scaleEffect(focused ? 1.15 : 1)
                        .shadow(color: .black.opacity(focused ? 0.3 : 0), radius: 10, y: 6)
                }
                .buttonStyle(PressDip())
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
            Button { tv.activateStatus(.profile) } label: {
                ProfileAvatar(profile: tv.profile, size: TopBar.avatar)
                    .avatarFocus(focused: tv.focus == .status(.profile), lit: tv.profilePicker?.dropdown == true)
                    .contentShape(Circle())
            }
            .buttonStyle(PressDip())
        }
        .padding(.leading, 22)
        .padding(.trailing, TopBar.inset)
        .frame(height: TopBar.height)
        .tvGlass(in: Capsule())
        .animation(Motion.focus, value: tv.focus)
        .animation(Motion.focus, value: expanded)
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
        let layout = Layout(canvas: canvas)
        // Each cell carries its own app, keyed by id, so a cell never reads a list that has
        // since changed (removing an app shortens it).
        let cells = tv.services.enumerated().map { AppCell.Item(index: $0.offset, service: $0.element) }
        let rows = stride(from: 0, to: cells.count, by: tv.columns).map {
            Array(cells[$0..<min($0 + tv.columns, cells.count)])
        }
        ZStack(alignment: .topLeading) {
            GlassDock(visible: !tv.inGrid)
                .frame(width: layout.dockFrame.width, height: layout.dockFrame.height)
                .offset(x: layout.dockFrame.minX, y: layout.dockFrame.minY)

            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(spacing: Layout.tileSpacing) {
                    ForEach(row) { item in
                        AppCell(tv: tv, item: item, showsLabel: rowIndex > 0 || tv.inGrid)
                    }
                }
                .offset(x: layout.dockFrame.minX + Layout.dockPadding, y: top(ofRow: rowIndex, in: layout))
            }
        }
    }

    private func top(ofRow row: Int, in layout: Layout) -> CGFloat { layout.top(ofRow: row) }
}

/// tvOS 26 dock: frosted Liquid Glass with a lit top edge.
struct GlassDock: View {
    /// In the grid the dock's glass dissolves to nothing (`.identity`) instead of fading, which would flatten it.
    var visible = true

    var body: some View {
        Color.clear
            .shadow(color: .black.opacity(visible ? 0.25 : 0), radius: 30, y: 16)
            .tvGlass(in: RoundedRectangle(cornerRadius: 48, style: .continuous), enabled: visible)
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
                    tv.hover(index, tilt: CGSize(width: location.x / Layout.tile.width - 0.5,
                                                 height: location.y / Layout.tile.height - 0.5))
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
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        let tilt = reduceMotion ? .zero : tilt
        artwork
            .frame(width: Layout.tile.width, height: Layout.tile.height)
            .clipShape(shape)
            // tvOS light: a soft glare on the focused tile that slides with the pointer.
            .overlay {
                RadialGradient(colors: [.white.opacity(0.32), .white.opacity(0)],
                               center: UnitPoint(x: 0.5 + tilt.width * 1.2, y: 0.05 + tilt.height * 1.2),
                               startRadius: 0, endRadius: Layout.tile.width * 0.75)
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
            .scaleEffect(focused ? (reduceMotion ? 1.06 : 1.14) : 1)
            .offset(y: focused && !reduceMotion ? -10 : 0)
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
/// （够放大到聚焦时的 1.14 倍、Retina），主屏动画时不再反复画矢量。
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
