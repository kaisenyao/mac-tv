import SwiftUI

/// Apple TV's text styles, from Apple's Human Interface Guidelines for tvOS: SF Pro, Medium for
/// nearly everything, Bold when emphasized, nothing under 23 pt. Mac TV draws on a 1920×1080
/// canvas like tvOS, so the sizes carry over point for point.
enum TVText {
    case title1, title2, title3, headline, subtitle, callout, body, caption1, caption2

    var size: CGFloat {
        switch self {
        case .title1: 76
        case .title2: 57
        case .title3: 48
        case .headline, .subtitle: 38
        case .callout: 31
        case .body: 29
        case .caption1: 25
        case .caption2: 23
        }
    }

    var weight: Font.Weight { self == .subtitle ? .regular : .medium }
    var emphasizedWeight: Font.Weight { self == .subtitle ? .medium : .bold }
}

extension Font {
    /// One of Apple TV's text styles; `emphasized` is its bold form.
    static func tv(_ style: TVText, emphasized: Bool = false) -> Font {
        .system(size: style.size, weight: emphasized ? style.emphasizedWeight : style.weight)
    }
}

// MARK: Roles every app shares

/// The same thing is the same size in every app: a focused item's title on 得到 is the size of one on 哔哩哔哩 or on
/// Home's Top Shelf, and a card's title under its artwork is the same in 得到, 哔哩哔哩, 网易云 and Movies.
extension Font {
    /// The focused item's title at the top of a screen: a book, a video, a playlist on the Top Shelf.
    static let tvHeroTitle = Font.tv(.title2, emphasized: true)
    /// The line of facts under it: who made it, how long, how many have seen it.
    static let tvHeroMeta = Font.tv(.body)
    /// A row's title above its cards.
    static let tvRowTitle = Font.tv(.headline, emphasized: true)
    /// A card's title under its artwork, or a song in a list: one weight whether focused or not (brightness goes on
    /// the layer's opacity, so focus never redraws the glyphs or changes the text's width).
    static let tvCardTitle = Font.system(size: 27, weight: .semibold)
    /// The line under a card's title.
    static let tvCardDetail = Font.tv(.caption2)

    /// A row in a list page: a song, a lecture, an episode, a setting in an app's own settings page.
    static let tvListTitle = Font.system(size: 29, weight: .semibold)
    /// The small text in such a row: an artist, a length, a setting's value.
    static let tvListDetail = Font.tv(.caption2)

    /// An item in a menu or a side panel: an account menu, the player's More panel, a card's menu, a sidebar item.
    /// One weight whether focused or not (the white highlight shows focus).
    static let tvMenuItem = Font.system(size: 27, weight: .semibold)
    /// A menu item's value at its right, and a menu's small heading ("更多", "‹ 倍速").
    static let tvMenuDetail = Font.system(size: 23, weight: .medium)
    /// The symbol at the start of a menu item.
    static let tvMenuSymbol = Font.system(size: 27, weight: .semibold)
    /// A sidebar's item and the symbol before it, the size of Apple TV's own (see TVSidebar).
    static let tvSidebarItem = Font.system(size: 24, weight: .medium)
    static let tvSidebarSymbol = Font.system(size: 22, weight: .medium)

    /// A small label on artwork: 课程, 直播, a duration, a progress.
    static let tvBadge = Font.system(size: 19, weight: .bold)
    /// A player's times (elapsed, remaining) and other numbers that tick.
    static let tvTimecode = Font.system(size: 25, weight: .medium).monospacedDigit()
}
