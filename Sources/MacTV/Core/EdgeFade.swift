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

    /// One gradient across the whole view, not three pieces side by side: where pieces meet on a fraction of a pixel
    /// (the canvas is scaled to the window) each softens its own edge, and the joint shows as a hairline across
    /// whatever is masked (a white focused row, most plainly).
    var body: some View {
        GeometryReader { geometry in
            let length = max(1, vertical ? geometry.size.height : geometry.size.width)
            let start = min(0.5, leading / length), end = min(0.5, trailing / length)
            // The ramp runs inwards from each end that fades; an end that doesn't is opaque to its edge
            let stops: [Gradient.Stop] =
                (leading > 0 ? Self.ramp.reversed().map { .init(color: $0.color, location: (1 - $0.location) * start) }
                             : [.init(color: .black, location: 0)])
                + (trailing > 0 ? Self.ramp.map { .init(color: $0.color, location: 1 - end + $0.location * end) }
                                : [.init(color: .black, location: 1)])
            LinearGradient(stops: stops, startPoint: vertical ? .top : .leading, endPoint: vertical ? .bottom : .trailing)
        }
    }
}

/// The mask of a list that scrolls inside its own window (a menu with more items than fit): opaque, fading to clear
/// over `length` at an end that has more beyond it. One gradient, for the same reason as EdgeFadeMask.
struct ListFadeMask: View {
    let above: Bool
    let below: Bool
    var length: CGFloat = 44

    var body: some View {
        GeometryReader { geometry in
            let part = min(0.5, length / max(1, geometry.size.height))
            LinearGradient(stops: [.init(color: above ? .clear : .black, location: 0), .init(color: .black, location: part),
                                   .init(color: .black, location: 1 - part), .init(color: below ? .clear : .black, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
    }
}
