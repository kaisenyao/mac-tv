import SwiftUI

/// A shape to stroke a pill's outline with: `PillOutline()` is a Capsule, `PillOutline(shape)` any other shape.
///
/// SwiftUI strokes its own continuous Capsule and RoundedRectangle as a rounded-rectangle primitive, and once the
/// corners are close to half the height (a pill, a round card) a window capture shows a short straight bar just
/// outside each end. The same outline handed over as a plain path draws clean, so this keeps the shape exactly
/// as it is and only passes its path on as an ordinary one. Fill with the shape itself; stroke with this.
/// `tvGlass` and `tvPanel` already outline through it.
struct PillOutline<Base: InsettableShape>: InsettableShape {
    var base: Base

    init(_ base: Base) { self.base = base }

    func path(in rect: CGRect) -> Path { Path(base.path(in: rect).cgPath) }

    func inset(by amount: CGFloat) -> PillOutline<Base.InsetShape> { PillOutline<Base.InsetShape>(base.inset(by: amount)) }
}

extension PillOutline where Base == Capsule {
    /// A Capsule's outline.
    init() { self.init(Capsule()) }
}
