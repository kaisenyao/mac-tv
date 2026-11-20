import AppKit
import Foundation
import Testing
@testable import MacTV

/// 个人收藏：Web 自己的一份（第一个人从 Safari 抄一次，以后只改自己的），按住确认的菜单（Open in New Tab、Rename、
/// Edit Address…、Delete），别的几排的 Add to Favorites，网页上"⋯"里的 Add / Remove
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct BrowserFavoritesTests {
    static func storage() -> (BrowserTabStorage, cleanup: () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacTVTests.favorites.\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = folder.appendingPathComponent("Preferences.plist").path
        return (BrowserTabStorage(suite: suite, folder: folder), {
            TestDefaults.remove(suite)
            try? FileManager.default.removeItem(at: folder)
        })
    }

    static func page(_ host: String, _ title: String) -> WebPage { WebPage(url: URL(string: "https://\(host)/")!, title: title) }

    /// 开始页上，焦点在某一排的某一个
    func focusRow(_ id: String, column: Int = 0, in store: BrowserStore) throws {
        let row = try #require(store.rows.firstIndex { $0.id == id })
        store.focus(row: row, column: column)
    }

    @Test
    func favoritesAreCopiedFromSafariOnceThenOnlyWebsOwnListChanges() throws {
        let (storage, cleanup) = Self.storage()
        defer { cleanup() }
        let store = BrowserStore(storage: storage)
        #expect(storage.favorites == nil && store.favoritePages.isEmpty)
        // 第一次读到 Safari：抄一份
        var safari = SafariLibrary.Snapshot(access: .ok)
        safari.favorites = [Self.page("apple.com", "Apple"), Self.page("github.com", "GitHub")]
        store.seedFavorites(from: safari)
        #expect(storage.favorites?.map(\.title) == ["Apple", "GitHub"] && store.favoritePages.count == 2)
        // 只抄一次：Safari 以后变了，Web 的不跟着变
        safari.favorites = [Self.page("example.com", "Example")]
        store.seedFavorites(from: safari)
        #expect(storage.favorites?.map(\.title) == ["Apple", "GitHub"])
        // 读不到 Safari（没给权限）时不抄，也不留下一份空的
        let (other, cleanupOther) = Self.storage()
        defer { cleanupOther() }
        let fresh = BrowserStore(storage: other)
        fresh.seedFavorites(from: SafariLibrary.Snapshot(access: .needsPermission))
        #expect(other.favorites == nil)
        // 改的只是 Web 自己的那一份
        store.removeFavorite(URL(string: "https://www.apple.com"))   // 同一个网址（www、末尾的 / 不算）
        #expect(storage.favorites?.map(\.title) == ["GitHub"] && safari.favorites.map(\.title) == ["Example"])
        store.addFavorite(Self.page("example.org", "Example Org"))
        store.addFavorite(Self.page("example.org", "Again"))           // 已经有了不再加
        #expect(storage.favorites?.map(\.title) == ["GitHub", "Example Org"])
    }

    @Test
    func favoritesCompareSchemeHostAndPathOnly() {
        func same(_ a: String, _ b: String) -> Bool { BrowserStore.sameAddress(URL(string: a)!, URL(string: b)!) }
        #expect(same("https://www.apple.com/", "https://apple.com"))
        #expect(same("https://Apple.com/Mac/", "https://apple.com/Mac"))
        #expect(same("https://apple.com/mac?x=1#top", "https://apple.com/mac"))
        #expect(!same("http://apple.com/", "https://apple.com/"))
        #expect(!same("https://apple.com/mac", "https://apple.com/ipad"))
        #expect(!same("https://store.apple.com/", "https://apple.com/"))
    }

    @Test
    func holdingSelectOnAFavoriteRenamesEditsTheAddressAndDeletesAfterAsking() throws {
        let (storage, cleanup) = Self.storage()
        defer { cleanup() }
        storage.setFavorites([Self.page("apple.com", "Apple"), Self.page("github.com", "GitHub")])
        let store = BrowserStore(storage: storage)
        store.newBlankTab()
        store.rebuildRows()
        try focusRow("favorites", in: store)
        // 菜单：Open in New Tab、Rename、Edit Address…、Delete
        #expect(store.openItemMenu())
        #expect(store.itemMenu?.actions.map(\.title) == ["Open in New Tab", "Rename", "Edit Address…", "Delete"])
        // Rename：就地一个输入框，名字整个选中，一打字就换掉；确认改好
        store.handle(.move(.down))
        store.handle(.select)
        #expect(store.itemMenu?.stage == .rename && store.editing && !store.editingInBar && store.query == "Apple")
        store.handle(.text("Mac"))
        store.handle(.select)
        #expect(storage.favorites?.first?.title == "Mac" && store.itemMenu == nil && !store.editing)
        // 返回：不改了
        try focusRow("favorites", in: store)
        _ = store.openItemMenu()
        store.handle(.move(.down))
        store.handle(.select)
        store.handle(.text("Nope"))
        store.handle(.back)
        #expect(storage.favorites?.first?.title == "Mac" && store.itemMenu == nil && !store.editing && store.focusedPage?.title == "Mac")
        // Edit Address…：不像网址的不收（留在输入框里），像的就改
        _ = store.openItemMenu()
        store.handle(.move(.down))
        store.handle(.move(.down))
        store.handle(.select)
        #expect(store.itemMenu?.stage == .editAddress && store.query == "https://apple.com/")
        store.handle(.text("not an address"))
        store.handle(.select)
        #expect(store.itemMenu?.stage == .editAddress)
        store.typed("www.apple.com/mac")
        store.handle(.select)
        #expect(storage.favorites?.first?.url.absoluteString == "https://www.apple.com/mac" && store.itemMenu == nil)
        // Delete：先问，焦点在 Cancel 上；Cancel 不删
        _ = store.openItemMenu()
        for _ in 0..<3 { store.handle(.move(.down)) }
        store.handle(.select)
        #expect(store.itemMenu?.stage == .confirm(.delete, yes: false))
        store.handle(.select)
        #expect(storage.favorites?.count == 2 && store.itemMenu == nil)
        _ = store.openItemMenu()
        for _ in 0..<3 { store.handle(.move(.down)) }
        store.handle(.select)
        store.handle(.move(.down))                                   // Cancel 在上，Delete 在下
        #expect(store.itemMenu?.stage == .confirm(.delete, yes: true))
        store.handle(.move(.up))
        #expect(store.itemMenu?.stage == .confirm(.delete, yes: false))
        store.handle(.move(.down))
        store.handle(.select)
        #expect(storage.favorites?.map(\.title) == ["GitHub"])
        // 地址栏、说明那一行上没有菜单
        store.startEditing()
        store.stopEditing()
        #expect(!store.openItemMenu())
    }

    @Test
    func otherRowsAndThePageMenuAddToFavorites() throws {
        let (storage, cleanup) = Self.storage()
        defer { cleanup() }
        storage.setFavorites([])
        storage.addHistory(URL(string: "https://news.example/")!, title: "News")
        let store = BrowserStore(storage: storage)
        store.newBlankTab()
        store.rebuildRows()
        // 最近浏览里的一个：Open in New Tab、Add to Favorites
        try focusRow("recent", in: store)
        #expect(store.openItemMenu())
        #expect(store.itemMenu?.actions == [.openInNewTab, .addToFavorites])
        store.handle(.move(.down))
        store.handle(.select)
        #expect(storage.favorites?.map(\.title) == ["News"] && store.rows.first?.id == "favorites")
        // 已经是了：Remove from Favorites（同一个网址：www.、末尾的 /、大小写不算）。取消收藏先问，焦点在 Cancel 上
        try focusRow("recent", in: store)
        _ = store.openItemMenu()
        #expect(store.itemMenu?.actions == [.openInNewTab, .removeFromFavorites])
        store.handle(.move(.down))
        store.handle(.select)
        #expect(store.itemMenu?.stage == .confirm(.removeFromFavorites, yes: false))
        #expect(store.itemMenuTitle == "Remove “News” from Favorites?")
        store.handle(.select)                                        // Cancel：还在
        #expect(storage.favorites?.map(\.title) == ["News"] && store.itemMenu == nil)
        try focusRow("recent", in: store)
        _ = store.openItemMenu()
        store.handle(.move(.down))
        store.handle(.select)
        store.handle(.move(.down))                                   // 往下到 Remove（Cancel 在上）
        store.handle(.select)
        #expect(storage.favorites?.isEmpty == true)
        try focusRow("recent", in: store)
        _ = store.openItemMenu()
        #expect(store.itemMenu?.actions == [.openInNewTab, .addToFavorites])   // 又是 Add 了（加不用问）
        _ = store.closeItemMenu()

        // 网页上的"⋯"：Add to Favorites，加了以后是 Remove from Favorites
        let (pageStorage, cleanupPage) = Self.storage()
        defer { cleanupPage() }
        let page = BrowserTab(url: URL(string: "https://swift.org/")!, title: "Swift")
        pageStorage.save([page], active: page.id)
        let web = BrowserStore(storage: pageStorage)
        #expect(web.menuRows.contains([.addFavorite]) && !web.menuRows.contains([.removeFavorite]))
        web.activateMenu(.addFavorite)                               // 加：不用问
        #expect(pageStorage.favorites?.map(\.title) == ["Swift"] && web.itemMenu == nil)
        #expect(web.menuRows.contains([.removeFavorite]) && !web.menuRows.contains([.addFavorite]))
        // 取消收藏：先问，焦点在 Cancel 上；返回、Cancel 都不删
        web.activateMenu(.removeFavorite)
        #expect(web.itemMenu?.stage == .confirm(.removeFromFavorites, yes: false) && pageStorage.favorites?.count == 1)
        web.handleItemMenu(.back)
        #expect(web.itemMenu == nil && pageStorage.favorites?.count == 1)
        web.activateMenu(.removeFavorite)
        web.handleItemMenu(.move(.down))
        web.handleItemMenu(.select)
        #expect(pageStorage.favorites?.isEmpty == true && web.menuRows.contains([.addFavorite]))
    }
}
