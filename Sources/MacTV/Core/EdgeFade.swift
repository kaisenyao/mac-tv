import SwiftUI

/// tvOS shelves: a row of cards that runs off the screen fades out softly at the edge where it's cut off,
/// instead of ending in a hard line. One static gradient mask: no blur, no timer, nothing redrawn while idle.
///
/// Put it on a view as wide as the visible row (the screen-wide container, not the HStack that slides),
/// so the fade sits at the screen's edges. Pass `leading` / `trailing` only where something is cut off;
/// derive them from data the row already has (the focused index, the item count), not from geometry.
extension View {
    /// Fades the leading and/or trailing `width` points to transparent. `overflow` lets the mask reach that
    /// far above and below the view, so a focused card's scale-up and shadow aren't cut off by it.
    func edgeFade(leading: Bool = false, trailing: Bool = false, width: CGFloat, overflow: CGFloat = 0) -> some View {
        modifier(EdgeFade(leading: leading ? width : 0, trailing: trailing ? width : 0, overflow: overflow))
    }
}

private struct EdgeFade: ViewModifier {
    let leading: CGFloat
    let trailing: CGFloat
    let overflow: CGFloat

    // Always masked, even with no fade, so turning a side on or off never rebuilds the row underneath.
    func body(content: Content) -> some View {
        content
            .padding(.vertical, overflow)
            .mask { EdgeFadeMask(leading: leading, trailing: trailing) }
            .padding(.vertical, -overflow)
    }
}

/// The mask itself: opaque in the middle, easing to clear over `leading` / `trailing` points at the ends.
/// For a view that already has a mask of its own, to fold the fade into that one instead of adding a second.
struct EdgeFadeMask: View {
    var leading: CGFloat = 0
    var trailing: CGFloat = 0
    /// Top and bottom instead: `leading` is the top, `trailing` the bottom (a list that scrolls up and down).
    var vertical = false

    /// Smoothstep, so the fade starts gently at the inner edge and reaches clear at the screen's edge.
    private static let ramp: [Gradient.Stop] = [.init(color: .black, location: 0), .init(color: .black.opacity(0.84), location: 0.25),
                                                .init(color: .black.opacity(0.5), location: 0.5), .init(color: .black.opacity(0.16), location: 0.75),
                                                .init(color: .clear, location: 1)]

    /// A row's fade width: about one card, but never over a card that's wholly on screen, so it only ever
    /// covers the card that's cut off. That's the space from the end of the last whole card to the screen's edge.
    /// `inset` is where the first card starts; `screen` the row's visible width.
    static func width(screen: CGFloat, inset: CGFloat, card: CGFloat, gap: CGFloat) -> CGFloat {
        let whole = ((screen - inset + gap) / (card + gap)).rounded(.down)
        return min(card, screen - inset - whole * (card + gap) + gap)
    }

    var body: some View {
        if vertical {
            VStack(spacing: 0) {
                LinearGradient(stops: Self.ramp, startPoint: .bottom, endPoint: .top).frame(height: leading)
                Color.black
                LinearGradient(stops: Self.ramp, startPoint: .top, endPoint: .bottom).frame(height: trailing)
            }
        } else {
            HStack(spacing: 0) {
                LinearGradient(stops: Self.ramp, startPoint: .trailing, endPoint: .leading).frame(width: leading)
                Color.black
                LinearGradient(stops: Self.ramp, startPoint: .leading, endPoint: .trailing).frame(width: trailing)
            }
        }
    }
}
