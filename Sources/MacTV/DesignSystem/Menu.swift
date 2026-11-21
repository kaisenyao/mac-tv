import SwiftUI

/// A menu's measures, the same in every app: the card that grows out of an app pressed and held, an account menu, a
/// "⋯" menu. Apple's own proportions, measured on the menu an iPhone opens when an app is pressed and held (iOS 27)
/// and scaled to our text:
/// - a row is 2.5 times as tall as its text, and rows touch: no gap between them;
/// - the highlight is a whole capsule, as tall as the row, set in from the panel's edge by 0.28 of a row;
/// - the panel's corner is the capsule's radius plus that inset, so the two curves run side by side;
/// - the symbols share one column, its middle three quarters of a row in from the highlight's end, and every title
///   starts on one line 1.35 rows in, whether its row has a symbol or not.
enum TVMenu {
    /// A row, and the highlight on it (Font.tvMenuItem is 27).
    static let row: CGFloat = 68
    /// From the panel's edge to the highlight, on every side.
    static let inset: CGFloat = 19
    /// The panel's corner.
    static let corner: CGFloat = row / 2 + inset
    /// From the highlight's end to what's in the row, at both ends: clear of the capsule's curve.
    static let leading: CGFloat = 33
    /// The symbols' column, and from it to the title.
    static let symbolColumn: CGFloat = 36
    static let symbolGap: CGFloat = 23
    /// A thin line between two groups of rows, with this much above and below it.
    static let divider: CGFloat = 6

    /// The panel's shape.
    static var panel: RoundedRectangle { RoundedRectangle(cornerRadius: corner, style: .continuous) }

    /// How tall a panel of that many rows is.
    static func height(rows: Int) -> CGFloat { CGFloat(rows) * row + inset * 2 }
}

/// The line between two groups of rows in a menu.
struct TVMenuDivider: View {
    var body: some View {
        Rectangle().fill(.white.opacity(0.18)).frame(height: 1)
            .padding(.horizontal, TVMenu.leading)
            .padding(.vertical, TVMenu.divider)
    }
}
