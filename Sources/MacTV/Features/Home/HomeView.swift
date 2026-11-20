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
}

struct HomeView: View {
    @ObservedObject var tv: TVController
    @ObservedObject private var siriRemote = SiriRemoteStatus.shared
    @Environment(\.canvasSize) private var canvas
    @Namespace private var pills

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

            // The status row, as Apple TV's: the time, small status glyphs (a connected remote, the lid staying
            // awake), the Control Center button and the profile. Up from the Top Shelf focuses it; Left and Right
            // move between the button and the profile.
            // At Apple TV's own sizes: the time in 24-point type, a 52-point button and a small avatar.
            GlassGroup { HStack(spacing: 16) {
                StatusClock(twentyFour: tv.preferences.twentyFourHourTime)
                    .padding(.trailing, 4)
                ForEach(statusGlyphs, id: \.self) { symbol in
                    Image(systemName: symbol)
                        .font(.system(size: 20, weight: .medium))
                        .opacity(0.9)
                        .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                        .transition(.opacity)
                }
                // Control Center: white while it's open or focused, like Apple TV's.
                let lit = tv.focus == .status(.controlCenter) || tv.controlCenter != nil
                Button { tv.controlCenter == nil ? tv.activateStatus(.controlCenter) : (tv.controlCenter = nil) } label: {
                    Image(systemName: "switch.2")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(lit ? .black : .white)
                        .frame(width: 52, height: 52)
                        .focusPlatter(Circle(), focused: lit)
                        .contentShape(Circle())
                        .scaleEffect(lit ? 1.08 : 1)
                        .tvGlassID("control-center", in: pills)
                }
                .buttonStyle(PressDip())
                let profileFocused = tv.focus == .status(.profile)
                Button { tv.activateStatus(.profile) } label: {
                    ProfileAvatar(profile: tv.profile, size: 38)
                        .overlay(Circle().strokeBorder(.white, lineWidth: profileFocused ? 2.5 : 0).padding(-4))
                        .contentShape(Circle())
                }
                .buttonStyle(PressDip())
            } }
                .animation(Motion.focus, value: tv.focus)
                .animation(Motion.appear, value: statusGlyphs)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 80)
                .padding(.top, 48)
                .modifier(ClearsCornerForNotices(notices: tv.notices, inGrid: tv.inGrid))
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

/// The status row's time, plain like Apple TV's, 12- or 24-hour as Settings › General says.
private struct StatusClock: View {
    let twentyFour: Bool

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(TimeOfDay.text(context.date, twentyFour: twentyFour))
                .font(.system(size: 24, weight: .semibold))
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
                .font(.tv(.caption1))
                .monospacedDigit()
                .padding(.horizontal, 20)
                .frame(height: 50)
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

    private func top(ofRow row: Int, in layout: Layout) -> CGFloat {
        let dockRowTop = layout.dockFrame.midY - Layout.tile.height / 2
        guard row > 0 else { return dockRowTop }
        // The second row peeks just below the dock.
        return layout.dockFrame.maxY + 60 + CGFloat(row - 1) * (Layout.tile.height + Layout.rowGap)
    }
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
                    Image(nsImage: glyph).resizable().interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 78)
                }
            }
        } else if case .movies = service.kind {
            ZStack {
                LinearGradient(colors: [Color(hex: "#5E5CE6"), Color(hex: "#1F1A6B")],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "film.stack")
                    .font(.system(size: 70, weight: .medium))
                    .foregroundStyle(.white)
            }
        } else if case .settings = service.kind {
            // Settings, as on Apple TV: the gears on a dark disc (Icons/settings.svg), on silver.
            ZStack {
                LinearGradient(colors: [Color(hex: "#DEDEE1"), Color(hex: "#A2A2A7")],
                               startPoint: .top, endPoint: .bottom)
                if let gears = SettingsTile.gears {
                    Image(nsImage: gears).resizable().interpolation(.high)
                        .frame(width: 111, height: 111)
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
        } else if service.id == DedaoStore.appID, let owl = DedaoTile.owl {
            // 得到那只完整的猫头鹰（耳朵、翅膀、爪子都在；Icons/dedao-owl.png，去掉了底色），
            // 直接站在得到的那种橙色上，看不出边界
            ZStack {
                LinearGradient(colors: [Color(hex: "#FF8A1C"), Color(hex: "#F26C00")], startPoint: .top, endPoint: .bottom)
                Image(nsImage: owl).resizable().interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(.vertical, 9)
            }
        } else if service.id == NeteaseStore.appID, let art = Icons.image(for: service) {
            // 你给的红底白标图：铺满卡片，多出来的红边裁掉
            Color(hex: "#E60012")
                .overlay { Image(nsImage: art).resizable().interpolation(.high).aspectRatio(contentMode: .fill) }
                .clipped()
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

/// 得到在主屏上的那只猫头鹰（去掉了底色的，见上面的卡片）
@MainActor
enum DedaoTile {
    static let owl: NSImage? = Bundle.main.url(forResource: "dedao-owl.png", withExtension: nil, subdirectory: "Icons")
        .flatMap(NSImage.init(contentsOf:))
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
