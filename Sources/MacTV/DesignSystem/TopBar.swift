import SwiftUI

/// The row along the top of Home and of every app (得到, 哔哩哔哩, 网易云, Movies): the same distance from the top and
/// from the right edge, and the same height for everything in it — pills, round buttons and avatars on their own — so
/// nothing in the corner changes size or jumps when you move between them.
enum TopBar {
    /// The row's top edge.
    static let top: CGFloat = 56
    /// Every control in the row: a pill, a round button (Control Center), an avatar on its own.
    static let height: CGFloat = 64
    /// From the right edge of the screen to the last control.
    static let trailing: CGFloat = 96
    /// An avatar inside an account pill.
    static let avatar: CGFloat = 48
    /// Text in a pill: a name, the song playing, Search, the time in Movies.
    static let text = Font.system(size: TVText.caption1.size, weight: .semibold)
    /// The line under a name in a pill (a membership).
    static let detail = Font.system(size: 18, weight: .semibold)
    /// Home's time, plain beside the Control Center button.
    static let clock = Font.system(size: TVText.body.size, weight: .semibold)
}

/// An account in an app's top bar: the avatar, the name and, under it, a membership if there is one. White while focused
/// or while its menu is open (`lit`), as every pill in the row.
struct AccountPill<Avatar: View>: View {
    let name: String
    var detail: String?
    var detailColor: Color = .white
    let focused: Bool
    var lit = false
    @ViewBuilder var avatar: Avatar

    var body: some View {
        let lit = focused || lit
        HStack(spacing: 14) {
            avatar.frame(width: TopBar.avatar, height: TopBar.avatar).clipShape(Circle())
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(TopBar.text).lineLimit(1)
                if let detail { Text(detail).font(TopBar.detail).foregroundStyle(detailColor) }
            }
        }
        .padding(.leading, (TopBar.height - TopBar.avatar) / 2).padding(.trailing, 26)
        .frame(height: TopBar.height)
        .foregroundStyle(lit ? .black : .white)
        .background(Capsule().fill(lit ? Color.white : .white.opacity(0.12)))
        .scaleEffect(focused ? 1.06 : 1)
        .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: 18, y: 10)
        .contentShape(Capsule())
    }
}
