import SwiftUI

/// Press and hold Select on a Home Screen app, as an iPhone's Haptic Touch: first the app's own quick actions, each
/// straight to a place inside it, then, under a line, Edit Home Screen, Hide and Delete for Everyone (AppMenuCard).
/// Only places the app has today; one that depends on what's there (a film half watched, a lecture in the player, a
/// library with shows) is offered only then. Apps that can't be reached into (YouTube, websites, Mac apps) have none.
struct QuickAction: Hashable {
    let id: String
    let title: String
    let symbol: String
}

extension TVController {
    /// The quick actions an app offers on Home, in order.
    func quickActions(for id: String) -> [QuickAction] {
        switch id {
        case NeteaseStore.appID:
            return [QuickAction(id: "netease.liked", title: "我喜欢的音乐", symbol: "heart.fill"),
                    QuickAction(id: "netease.search", title: "搜索", symbol: "magnifyingglass"),
                    QuickAction(id: "netease.daily", title: "每日推荐", symbol: "calendar")]
        case BilibiliStore.appID:
            return [QuickAction(id: "bilibili.search", title: "搜索", symbol: "magnifyingglass"),
                    QuickAction(id: "bilibili.mine", title: "我的", symbol: "person.crop.circle")]
        case DedaoStore.appID:
            return dedaoStore.player.current == nil ? []
                : [QuickAction(id: "dedao.resume", title: "继续收听", symbol: "play.fill")]
        case BrowserStore.appID:
            return [QuickAction(id: "web.newTab", title: "New Tab", symbol: "plus.square.on.square"),
                    QuickAction(id: "web.history", title: "History", symbol: "clock")]
        case "movies":
            let library = movieLibrary
            return (library.continueWatching.isEmpty ? []
                    : [QuickAction(id: "movies.continue", title: "Continue Watching", symbol: "play.fill")])
                + (library.movies.contains { $0.category == .episode }
                    ? [QuickAction(id: "movies.shows", title: "TV Shows", symbol: "tv")] : [])
                + [QuickAction(id: "movies.search", title: "Search", symbol: "magnifyingglass")]
        case "add-app":
            return [QuickAction(id: "store.website", title: "Add Website", symbol: "globe"),
                    QuickAction(id: "store.macApp", title: "Add Mac App", symbol: "macwindow")]
        case "settings":
            return [QuickAction(id: "settings.screenSaver", title: "Screen Saver", symbol: "sparkles.tv"),
                    QuickAction(id: "settings.audio", title: "Audio Output", symbol: "hifispeaker.fill"),
                    QuickAction(id: "settings.remotes", title: "Remotes and Devices", symbol: "appletvremote.gen4.fill")]
        default:
            return []
        }
    }

    /// A quick action chosen: the menu goes back into the app, which opens where the action leads (as the Top Shelf
    /// opens an app and then a place in it, AppShelf.activate).
    func performQuickAction(_ action: QuickAction) {
        organizer = nil
        switch action.id {
        case "netease.liked":
            openApp(NeteaseStore.appID)
            // 我喜欢的音乐 is the first of the account's lists; until they've loaded, 网易云 just opens.
            if let liked = neteaseStore.myLists.first { neteaseStore.playFromShelf(liked, songs: []) }
        case "netease.search":
            openApp(NeteaseStore.appID)
            neteaseStore.focusSearch(typing: false)
        case "netease.daily":
            openApp(NeteaseStore.appID)
            _ = neteaseStore.openDaily()
        case "bilibili.search":
            openApp(BilibiliStore.appID)
            bilibiliStore.focusSearch()
        case "bilibili.mine":
            openApp(BilibiliStore.appID)
            bilibiliStore.select(.mine)
        case "dedao.resume":
            openApp(DedaoStore.appID)
            dedaoStore.resumeFromShelf()
        case "web.newTab":
            openApp(BrowserStore.appID)
            browserStore.newBlankTab()
        case "web.history":
            openApp(BrowserStore.appID)
            browserStore.openHistory()
        case "movies.continue":
            guard let movie = movieLibrary.continueWatching.first else { return openApp("movies") }
            openApp("movies")
            playFromMovies(movie)
        case "movies.shows":
            openApp("movies")
            tapMovieSidebar(.shows)
        case "movies.search":
            openApp("movies")
            tapMovieSidebar(.search)
        case "store.website": adder = AppAdder(tab: .website, row: 1)
        case "store.macApp": adder = AppAdder(tab: .macApp, row: 1)
        case "settings.screenSaver": openSection(.screenSaver)
        case "settings.audio": openAudioPicker()
        case "settings.remotes": openSection(.remotes)
        default: break
        }
    }
}
