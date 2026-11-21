import SwiftUI

// Mac TV's one language for what floats over the screen. Every overlay is one of five kinds, and each kind has one
// backdrop, one surface, one shadow and one way in and out, so nothing reads as put together from parts:
//
// | Kind   | What                                                    | Behind it        | Its surface           | Shadow  | In and out                 |
// |--------|---------------------------------------------------------|------------------|-----------------------|---------|----------------------------|
// | Sheet  | takes the screen: Settings, Add App, an app's own form  | SheetBackdrop    | none, or tvPanel      | –       | Motion.sheet               |
// | Panel  | pulled from an edge or corner: Control Center, a sidebar, a player panel | DimBackdrop | tvPanelSurface (tiles: tvGlass) | .float | slides, Motion.slide |
// | Menu   | grows out of what was pressed: press and hold, "⋯"     | DimBackdrop      | tvPanelSurface        | .float  | .growing(from:), Motion.slide |
// | Notice | a toast, the volume, a banner, Jasmine's caption       | nothing          | tvGlass capsule       | –       | tvGlassTransition, Motion.appear |
// | Edge   | controls along an edge of a video: a quality bar, a shelf | EdgeScrim     | none                  | –       | slides, Motion.slide       |
//
// A focused card lifts with `.lift`. Destructive actions are `Color.destructive`.
//
// What is Liquid Glass and what isn't, as tvOS 26 and 27 use it (Apple TV 4K User Guide, tvOS 27):
//
// - Glass is the controls layer, floating over content: Home's dock and status capsule, Control Center's tiles and
//   round buttons, a pill or a round button in an app's top bar, a button over artwork (Play, Open, "+"), a sidebar,
//   a side panel, a menu, a player's buttons and its paused mark, and every notice. All of it is `tvGlass`
//   (a panel or a menu: `tvPanelSurface`, the same glass a little darker for its text).
// - Focus on glass is `focusPlatter`: the control turns solid white with dark text, as Apple TV's do.
// - Content is never glass: app icons, posters, covers, cards, the rows of a list, text, and the small labels on
//   artwork (a duration, a count), which stay dark scrims.
// - A sheet takes the whole screen on a frosted backdrop, so there is nothing behind it for glass to bend: its
//   groups are `tvPanel`, a quiet fill, and its rows are plain until focused.
// - Glass never sits on glass: inside a glass panel or menu, a row is plain and its focus is the white platter.

/// What's behind a panel or a menu: the screen, dimmed. Not blurred: a blur can't reach a web page or a video, and a
/// dim reads the same over all of them. Clicking it closes what's open, when `close` is given.
struct DimBackdrop: View {
    var close: (() -> Void)?

    static let opacity = 0.32

    var body: some View {
        Color.black.opacity(Self.opacity)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { close?() }
            .allowsHitTesting(close != nil)
    }
}

/// Controls along one edge of a video (a quality bar at the top, a shelf at the bottom): a dark gradient from that
/// edge, eased so it has no visible end. `strength` is its darkest, at the edge.
struct EdgeScrim: View {
    let strength: Double
    let edge: VerticalEdge

    private static let curve: [(location: Double, share: Double)] = [
        (0, 1), (0.19, 0.738), (0.34, 0.541), (0.47, 0.382), (0.565, 0.278), (0.65, 0.194), (0.73, 0.126),
        (0.802, 0.075), (0.861, 0.042), (0.91, 0.021), (0.952, 0.008), (0.982, 0.002), (1, 0),
    ]

    var body: some View {
        LinearGradient(stops: Self.curve.map { .init(color: .black.opacity(strength * $0.share), location: $0.location) },
                       startPoint: edge == .top ? .top : .bottom, endPoint: edge == .top ? .bottom : .top)
    }
}

/// The two shadows. Light comes from above, so every shadow falls straight down.
enum TVShadow {
    /// A panel or a menu floating over the screen.
    case float
    /// A focused card or tile, lifted off its row.
    case lift
}

extension View {
    /// A panel's or a menu's own surface: Liquid Glass, as tvOS 26's sidebars and menus are, darkened a little so its
    /// text reads over any artwork behind it.
    func tvPanelSurface<S: InsettableShape>(in shape: S) -> some View {
        tvGlass(in: shape, tint: .black.opacity(0.3))
    }

    /// One of Mac TV's two shadows; `active` false keeps the modifier in place with no shadow (a tile losing focus).
    func tvShadow(_ kind: TVShadow, active: Bool = true) -> some View {
        switch kind {
        case .float: shadow(color: .black.opacity(active ? 0.5 : 0), radius: 30, y: 14)
        case .lift: shadow(color: .black.opacity(active ? 0.6 : 0), radius: 30, y: 22)
        }
    }
}

extension AnyTransition {
    /// A menu growing out of what was pressed and shrinking back into it. `anchor` is that place, as a point of the
    /// space the positioned menu fills (`.position` makes a view fill its parent).
    static func growing(from anchor: UnitPoint) -> AnyTransition {
        .scale(scale: 0.04, anchor: anchor).combined(with: .opacity)
    }
}

extension Color {
    /// Delete, Remove, Log Out: Apple's red on dark.
    static let destructive = Color(hex: "#FF453A")
}
