import SwiftUI

/// Mac TV's motion, built from Apple's system springs so everything moves with one feel.
/// With Reduce Motion on, views fade instead of moving, scaling or tilting.
enum Motion {
    /// Focus moving between tiles, rows and buttons. The same curve and length as `navigate`, so a
    /// focused tile lifts in step with its row scrolling, instead of moving on its own.
    static let focus = Animation.smooth(duration: 0.32)
    /// Scrolling between the Top Shelf, dock and grid.
    static let navigate = Animation.smooth(duration: 0.32)
    /// Sheets, toasts and pills arriving and leaving.
    static let appear = Animation.smooth(duration: 0.35)
    /// A control pressed: quick, settling without a bounce.
    static let press = Animation.smooth(duration: 0.18)
    /// 从屏幕边上拉出来、收回去的东西（侧边栏、头像菜单、卡片菜单、右边的面板），各个应用里都是这一条，带一点弹性
    static let slide = Animation.spring(response: 0.42, dampingFraction: 0.84)
    /// Tiles following the pointer.
    static let tilt = Animation.interactiveSpring(response: 0.25, dampingFraction: 0.85)

    /// A sheet settles into place from slightly larger, like tvOS modals.
    static func sheet(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .scale(scale: 1.04)),
                                              removal: .opacity.combined(with: .scale(scale: 1.02)))
    }
}

extension View {
    /// Apple TV's Liquid Glass, for Mac TV's controls layer only (see the rules in Layers.swift): the dock, pills,
    /// buttons, Control Center, sidebars, menus and notices, never content. Following Apple's guidance it's the
    /// regular variant (these carry text), applied after the view's other appearance modifiers; `interactive` makes a
    /// control respond to the pointer, and `tint` colours it. Before macOS 26 there is no Liquid Glass: `FrostedGlass`
    /// stands in, the backdrop blurred with the same lit rim.
    /// `enabled: false` keeps the modifier in place (`.identity`), so switching glass off never changes the view's identity.
    @ViewBuilder
    func tvGlass<S: InsettableShape>(in shape: S, interactive: Bool = false, tint: Color? = nil, enabled: Bool = true) -> some View {
        if #available(macOS 26, *) {
            glassEffect(enabled ? .regular.tint(tint).interactive(interactive) : .identity, in: shape)
        } else {
            background { if enabled { FrostedGlass(shape: shape, tint: tint) } }
        }
    }

    /// tvOS focus on a control: a solid white platter when focused, the control's glass otherwise. Tinting the
    /// glass white instead reads milky grey over dark artwork, and dark text on it loses contrast. The glass
    /// switches to `.identity` rather than going away, so focus moving never changes the view's identity.
    func focusPlatter<S: InsettableShape>(_ shape: S, focused: Bool, color: Color = .white, glass: Bool = true) -> some View {
        background { shape.fill(color).opacity(focused ? 1 : 0) }
            .tvGlass(in: shape, enabled: glass && !focused)
    }

    /// A plain panel for sheets that sit on the frosted backdrop. Glass there would have only blur to
    /// refract and read as a flat grey slab, so these group their content with a quiet fill instead.
    func tvPanel<S: InsettableShape>(in shape: S) -> some View {
        background(.white.opacity(0.07), in: shape)
            .overlay(PillOutline(shape).strokeBorder(.white.opacity(0.12)))
    }

    /// Related glass in one GlassGroup morphs between shapes when one appears or leaves.
    @ViewBuilder
    func tvGlassID(_ id: String, in namespace: Namespace.ID) -> some View {
        if #available(macOS 26, *) {
            glassEffectID(id, in: namespace)
        } else {
            self
        }
    }

    /// Glass appearing and disappearing materializes, as Apple recommends, rather than fading.
    @ViewBuilder
    func tvGlassTransition() -> some View {
        if #available(macOS 26, *) {
            glassEffectTransition(.materialize)
        } else {
            transition(.opacity)
        }
    }
}

/// Liquid Glass's stand-in before macOS 26: the backdrop blurred, lit a little from above, and the rim that catches
/// the light at the top-left and again, fainter, at the bottom-right, as the real glass's edge does. One material,
/// one fill and one stroke: nothing here is blurred or redrawn while it rests.
private struct FrostedGlass<S: InsettableShape>: View {
    let shape: S
    let tint: Color?

    private static var rim: LinearGradient {
        LinearGradient(stops: [.init(color: .white.opacity(0.5), location: 0), .init(color: .white.opacity(0.14), location: 0.3),
                               .init(color: .white.opacity(0.07), location: 0.7), .init(color: .white.opacity(0.28), location: 1)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        ZStack {
            shape.fill(.ultraThinMaterial)
            if let tint { shape.fill(tint) }
            shape.fill(LinearGradient(colors: [.white.opacity(0.09), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom))
            PillOutline(shape).strokeBorder(Self.rim, lineWidth: 1.5)
        }
    }
}

/// Groups nearby glass so it renders in one pass and samples the same backdrop (GlassEffectContainer);
/// a plain stack before macOS 26. `spacing` is how close two shapes must come before they melt into
/// one another: 0 keeps every shape separate, so a focused tile growing or a pressed button
/// shrinking never pulls its neighbours' glass towards it. Raise it only where merging is the point.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 0
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
