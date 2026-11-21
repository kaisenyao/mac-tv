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
}
