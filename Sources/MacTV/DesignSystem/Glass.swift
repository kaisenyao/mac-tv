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

/// Liquid Glass's two looks, as tvOS uses them. `clear` lets what's behind it show through nearly untouched (the
/// Home Screen's dock and status capsule, over the Top Shelf's artwork); `regular` blurs it so text on the glass
/// always reads (everything else).
enum TVGlass {
    case regular, clear
}

extension View {
    /// Apple TV's Liquid Glass, for Mac TV's controls layer only (see the rules in Layers.swift): the dock, pills,
    /// buttons, Control Center, sidebars, menus and notices, never content. Applied after the view's other appearance
    /// modifiers; `interactive` makes a control respond to the pointer, and `tint` colours it. Before macOS 26 there
    /// is no Liquid Glass: `FrostedGlass` stands in for both looks, the backdrop blurred. Either way the glass has
    /// Apple TV's lit rim (GlassRim), which goes with it when it's switched off.
    /// `enabled: false` keeps the modifier in place (`.identity`), so switching glass off never changes the view's identity.
    @ViewBuilder
    func tvGlass<S: InsettableShape>(_ kind: TVGlass = .regular, in shape: S, interactive: Bool = false, tint: Color? = nil,
                                     enabled: Bool = true) -> some View {
        if #available(macOS 26, *) {
            let glass: Glass = kind == .clear ? .clear : .regular
            // The rim is part of what's on the glass, drawn before glassEffect: laid over the view afterwards, a
            // GlassEffectContainer (GlassGroup) would draw its glass on top of it.
            overlay { if enabled { GlassRim(shape: shape, missing: kind == .clear ? .sides : .topAndSides) } }
                .glassEffect(enabled ? glass.tint(tint).interactive(interactive) : .identity, in: shape)
        } else {
            background { if enabled { FrostedGlass(shape: shape, tint: tint) } }
        }
    }

    /// tvOS focus on a control: a solid white platter when focused, the control's glass otherwise. Tinting the
    /// glass white instead reads milky grey over dark artwork, and dark text on it loses contrast. The glass
    /// switches to `.identity` rather than going away, so focus moving never changes the view's identity.
    func focusPlatter<S: InsettableShape>(_ shape: S, focused: Bool, color: Color = .white, glass: Bool = true) -> some View {
        // Filled as a plain path (PillOutline): SwiftUI's own Capsule leaves a short straight bar just outside each end
        background { PillOutline(shape).fill(color).opacity(focused ? 1 : 0) }
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

/// The lit rim of Apple TV's glass, as measured on the pictures in Apple's guide (tvOS 27): brightest along the top,
/// nearly as bright down the sides, faint along the bottom (about 45, 30 and 12 of 255 brighter than the glass inside
/// it). macOS's own glass lights its top and bottom and leaves its sides dark, so this draws only what each is missing:
/// the top and sides of regular glass, the sides of clear glass, and all of it on the stand-in before macOS 26.
private struct GlassRim<S: InsettableShape>: View {
    enum Missing { case all, topAndSides, sides }

    let shape: S
    let missing: Missing

    var body: some View {
        PillOutline(shape).strokeBorder(LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom), lineWidth: 2)
            .allowsHitTesting(false)
    }

    private var stops: [Gradient.Stop] {
        func white(_ opacity: Double, at location: Double) -> Gradient.Stop { .init(color: .white.opacity(opacity), location: location) }
        switch missing {
        case .all: return [white(0.42, at: 0), white(0.28, at: 0.55), white(0.12, at: 1)]
        case .topAndSides: return [white(0.3, at: 0), white(0.25, at: 0.55), white(0.04, at: 1)]
        case .sides: return [white(0, at: 0), white(0.34, at: 0.25), white(0.34, at: 0.75), white(0, at: 1)]
        }
    }
}

/// Liquid Glass's stand-in before macOS 26: the backdrop blurred, lit a little from above, and the same lit rim
/// (GlassRim). One material, one fill and one stroke: nothing here is blurred or redrawn while it rests.
private struct FrostedGlass<S: InsettableShape>: View {
    let shape: S
    let tint: Color?

    var body: some View {
        ZStack {
            shape.fill(.ultraThinMaterial)
            if let tint { shape.fill(tint) }
            shape.fill(LinearGradient(colors: [.white.opacity(0.09), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom))
            GlassRim(shape: shape, missing: .all)
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
