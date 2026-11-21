import SwiftUI

/// The row along the top of Home and of every app (得到, 哔哩哔哩, 网易云, Movies): the same distance from the top and
/// from the right edge, and the same height for everything in it — pills, round buttons and avatars on their own — so
/// nothing in the corner changes size or jumps when you move between them.
enum TopBar {
    /// The row's top edge.
    static let top: CGFloat = 56
    /// The row's height: Home's capsule (the time and the avatar, as tvOS 26's), the pills in an app's row.
    static let height: CGFloat = 60
    /// From the right edge of the screen to the row's end.
    static let trailing: CGFloat = 96
    /// An app's own mark at the row's left (得到's owl, 哔哩哔哩's and 网易云's wordmarks): the same height in each.
    static let brand: CGFloat = 56
    /// An avatar: in Home's capsule, and on its own at the end of an app's row, in the same place on screen.
    static let avatar: CGFloat = 48
    /// From the capsule's edge to the avatar in it (and to its round buttons, as big as the avatar).
    static var inset: CGFloat { (height - avatar) / 2 }
    /// Text in a pill: the song playing, Search, the time in Movies.
    static let text = Font.system(size: TVText.caption1.size, weight: .semibold)
    /// Home's time, in its capsule.
    static let clock = Font.system(size: TVText.caption1.size, weight: .semibold)
}

/// An app's account at the end of its top bar: the avatar alone, round, the size of Home's and where Home's is (the
/// end of the row), ringed in white while focused or while its menu is open.
struct AccountAvatar<Avatar: View>: View {
    let focused: Bool
    var lit = false
    @ViewBuilder var avatar: Avatar

    var body: some View {
        avatar
            .frame(width: TopBar.avatar, height: TopBar.avatar)
            .clipShape(Circle())
            .avatarFocus(focused: focused, lit: lit)
            .frame(width: TopBar.height, height: TopBar.height)   // centred where Home's sits in its capsule
            .contentShape(Circle())
    }
}

extension View {
    /// An avatar's focus, the same everywhere (Home's capsule, an app's row): a white ring around it, and it grows.
    func avatarFocus(focused: Bool, lit: Bool = false) -> some View {
        overlay(Circle().strokeBorder(.white, lineWidth: 3).padding(-5).opacity(focused || lit ? 1 : 0))
            .scaleEffect(focused ? 1.12 : 1)
            .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: 14, y: 8)
    }
}
