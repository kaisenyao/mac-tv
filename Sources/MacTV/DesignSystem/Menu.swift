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

/// A sidebar's measures, the same in every app: Apple TV's own, measured on the TV app's sidebar (tvOS 27, the guide's
/// picture 6acc7afb, 1 pixel = 1.681 points):
/// - the row in focus is a whole white capsule 71 tall and 320 wide; rows are 78 apart;
/// - it sits 7 in from the panel, whose corner is the capsule's radius plus that (the two curves run side by side);
/// - a row's symbol is centred on the middle of the capsule's round end, and its title starts 75 in;
/// - the title is 24 points, the symbol a little smaller (Font.tvSidebarItem, .tvSidebarSymbol);
/// - the panel is 37 from the screen's left edge, which puts the symbols' column 80 in: Apple's content margin.
enum TVSidebar {
    /// The capsule on the row in focus, and from one row to the next.
    static let row: CGFloat = 71
    static let step: CGFloat = 78
    /// The capsule's width while the sidebar is open.
    static let width: CGFloat = 320
    /// From the panel's edge to the capsule, on every side.
    static let inset: CGFloat = 7
    /// From the capsule's end to the symbols' column, the column, and from it to the title.
    static let leading: CGFloat = 14
    static let symbolColumn: CGFloat = 43
    static let symbolGap: CGFloat = 18
    /// From the title's box to the capsule's other end.
    static let trailing: CGFloat = 24
    /// A title's box.
    static let titleWidth: CGFloat = width - leading - symbolColumn - symbolGap - trailing
    /// A row while the sidebar is closed: its symbol alone.
    static let rail: CGFloat = leading * 2 + symbolColumn
    /// From the screen's left edge to the panel.
    static let edge: CGFloat = 37
    /// The small white dot beside the current symbol while the sidebar is closed, and where it is in a row.
    static let dot: CGFloat = 10
    static let dotLeading: CGFloat = -5

    /// The panel's shape.
    static var panel: RoundedRectangle { RoundedRectangle(cornerRadius: row / 2 + inset, style: .continuous) }
}
