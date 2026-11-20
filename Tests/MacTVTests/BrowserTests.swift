import CoreGraphics
import Foundation
import Testing
@testable import MacTV

/// 浏览器：地址栏里打的字是网址还是搜索词、Safari 历史里网站的名字、在 Mac TV 里看过的页面
struct BrowserTests {
    @Test
    func addressBarTellsAddressesFromSearches() {
        #expect(BrowserStore.address("bilibili.com")?.absoluteString == "https://bilibili.com")
        #expect(BrowserStore.address("https://www.apple.com/tv/")?.host == "www.apple.com")
        // 没有点、有空格、是一句话：都当搜索词
        #expect(BrowserStore.address("猫") == nil)
        #expect(BrowserStore.address("how to cook rice") == nil)
        #expect(BrowserStore.address("hello world.com") == nil)
    }

    @Test
    func siteNamesComeFromTheLastPartOfPageTitles() {
        #expect(SafariLibrary.siteName(fromTitle: "某个视频 - 哔哩哔哩", host: "www.bilibili.com") == "哔哩哔哩")
        #expect(SafariLibrary.siteName(fromTitle: "Inbox (3) | Gmail", host: "mail.google.com") == "Gmail")
        // 取不出（没有分隔、太长）就用网址
        #expect(SafariLibrary.siteName(fromTitle: "Welcome", host: "www.example.com") == "example.com")
    }

    @Test
    func browsingHistoryKeepsOneEntryPerPageNewestFirst() throws {
        let defaults = UserDefaults.standard
        let saved = defaults.data(forKey: "browserHistory")
        defer { defaults.set(saved, forKey: "browserHistory") }
        defaults.removeObject(forKey: "browserHistory")
        let a = try #require(URL(string: "https://a.example/")), b = try #require(URL(string: "https://b.example/"))
        BrowserHistory.add(a, title: "A")
        BrowserHistory.add(b, title: "B")
        BrowserHistory.add(a, title: "A again")
        #expect(BrowserHistory.all.map(\.url) == [a, b])
        #expect(BrowserHistory.all.first?.title == "A again")
    }

    // MARK: 网站图标

    @Test
    func iconLinksArePickedBestFirst() throws {
        let base = try #require(URL(string: "https://example.com/"))
        let html = """
            <html><head>
            <link rel="icon" href="/favicon-32.png" sizes="32x32">
            <link rel="mask-icon" href="/pinned.svg" color="#000">
            <link rel='apple-touch-icon' sizes="120x120" href="/touch-120.png">
            <link rel="apple-touch-icon" sizes="180x180" href="https://cdn.example.com/touch-180.png?v=1&amp;x=2">
            <link rel="icon" type="image/svg+xml" href="/icon.svg">
            <link rel="icon" sizes="192x192" href="/icon-192.png">
            </head><body><link rel="icon" href="/not-in-head.png"></body></html>
            """
        let links = IconFetch.links(in: html, base: base)
        #expect(!links.contains { $0.url.path.hasSuffix("pinned.svg") })            // 单色的 mask-icon 不要
        #expect(!links.contains { $0.url.path.hasSuffix("not-in-head.png") })       // 只看 <head>
        let ranked = IconFetch.ranked(links, host: "example.com").map(\.absoluteString)
        #expect(ranked == [
            "https://cdn.example.com/touch-180.png?v=1&x=2",
            "https://example.com/touch-120.png",
            "https://example.com/icon-192.png",
            "https://example.com/icon.svg",
            "https://example.com/apple-touch-icon.png",
            "https://example.com/favicon-32.png",
            "https://example.com/favicon.ico",
        ])
        // 首页什么都没写：常见的两个位置
        #expect(IconFetch.ranked([], host: "a.example").map(\.absoluteString)
                == ["https://a.example/apple-touch-icon.png", "https://a.example/favicon.ico"])
        #expect(IconFetch.largestSize("16x16 32x32 48x48") == 48)
        #expect(IconFetch.largestSize("any") == 512)
        #expect(IconFetch.largestSize(nil) == 0)
    }

    @Test
    func iconsKnowWhetherToFillTheTileOrSitOnABackground() throws {
        // 自带底色的方图标：铺满；透明底的白色标志：垫深色；透明底的黑色标志：垫白色
        let solid = try #require(Self.image(background: CGColor(red: 1, green: 0, blue: 0, alpha: 1), mark: nil))
        let whiteMark = try #require(Self.image(background: .clear, mark: .white))
        let blackMark = try #require(Self.image(background: .clear, mark: .black))
        #expect(IconFetch.analyse(solid) == (opaque: true, light: false))
        #expect(IconFetch.analyse(whiteMark) == (opaque: false, light: true))
        #expect(IconFetch.analyse(blackMark) == (opaque: false, light: false))
    }

    private static func image(background: CGColor, mark: CGColor?) -> CGImage? {
        guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        if let mark {
            context.setFillColor(mark)
            context.fillEllipse(in: CGRect(x: 16, y: 16, width: 32, height: 32))
        }
        return context.makeImage()
    }

    @Test
    func monogramUsesTheFirstLetterOfTheName() throws {
        let url = try #require(URL(string: "https://github.com/"))
        #expect(Monogram.letter(for: WebPage(url: url, title: "GitHub")) == "G")
        #expect(Monogram.letter(for: WebPage(url: url, title: "(3) inbox")) == "I")
        #expect(Monogram.letter(for: WebPage(url: url, title: "")) == "G")   // 没有标题：网址的
        #expect(Monogram.letter(for: WebPage(url: url, title: "哔哩哔哩")) == "哔")
    }

    // MARK: 缩放

    @Test
    func defaultZoomFitsTheTV() {
        #expect(BrowserZoom.standard(forWidth: 1920) == 1.5)   // 1080p 的电视：150%
        #expect(BrowserZoom.standard(forWidth: 1600) == 1.25)
        #expect(BrowserZoom.standard(forWidth: 1024) == 1)     // 小窗口不缩小
        #expect(BrowserZoom.standard(forWidth: 3840) == 3)
        #expect(BrowserZoom.step(from: 1.5, larger: true) == 1.75)
        #expect(BrowserZoom.step(from: 1.5, larger: false) == 1.25)
        #expect(BrowserZoom.step(from: 1.3, larger: false) == 1.25)
        #expect(BrowserZoom.step(from: 3, larger: true) == 3)
        #expect(BrowserZoom.step(from: 0.75, larger: false) == 0.75)
        #expect(BrowserZoom.percent(1.25) == "125%")
        #expect(BrowserZoom.key("WWW.Apple.com") == "apple.com")
    }

    // MARK: 标签页

    private static func storage() -> (BrowserTabStorage, cleanup: () -> Void) {
        let suite = "MacTVTests.browser.\(UUID().uuidString)"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        return (BrowserTabStorage(suite: suite, folder: folder), {
            UserDefaults().removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        })
    }

    @Test
    func tabsAndZoomAreRememberedAcrossVisits() throws {
        let (storage, cleanup) = Self.storage()
        defer { cleanup() }
        let a = BrowserTab(url: try #require(URL(string: "https://a.example/")), title: "A")
        let b = BrowserTab(url: try #require(URL(string: "https://b.example/page")), title: "B")
        storage.save([a, b], active: a.id)
        let loaded = storage.load()
        #expect(loaded.tabs == [a, b])
        #expect(loaded.active == a.id)
        // 记下的那个不见了：停在最后一个
        storage.save([b], active: a.id)
        #expect(storage.load().active == b.id)

        #expect(storage.zoom(for: "www.apple.com") == nil)
        storage.setZoom(1.75, for: "www.apple.com")
        #expect(storage.zoom(for: "apple.com") == 1.75)
        storage.setZoom(nil, for: "apple.com")
        #expect(storage.zoom(for: "www.apple.com") == nil)
    }

    @Test @MainActor
    func keepsAtMostTwelveTabsAndNoTabsRowOnTheStartPage() throws {
        let (storage, cleanup) = Self.storage()
        defer { cleanup() }
        let store = BrowserStore(storage: storage)
        for index in 0..<14 {
            store.newTab(try #require(URL(string: "https://site\(index).example/")))
        }
        #expect(store.tabs.count == BrowserStore.maxTabs)
        #expect(store.tabs.last?.url.host == "site13.example")      // 最早开的那几个关掉了
        #expect(store.tabs.first?.url.host == "site2.example")
        // 同一个网址已经开着：换到那个，不再开一个
        store.open(try #require(URL(string: "https://site13.example/")))
        #expect(store.tabs.count == BrowserStore.maxTabs)
        store.closeTab(try #require(store.tabs.first?.id))
        #expect(store.tabs.count == BrowserStore.maxTabs - 1)
        #expect(BrowserTabStorage(suite: storage.suite, folder: storage.folder).load().tabs == store.tabs)
        // 标签页只在网页上面的标签栏里，开始页不再有"Tabs"一排
        store.rebuildRows()
        #expect(!store.rows.contains { $0.id == "tabs" })
    }

    @Test @MainActor
    func privateTabsAreNeverSavedAndDropTheirDataWithTheLastOne() throws {
        let (storage, cleanup) = Self.storage()
        defer { cleanup() }
        let store = BrowserStore(storage: storage)
        store.newTab(try #require(URL(string: "https://normal.example/")))
        store.newTab(try #require(URL(string: "https://secret.example/")), isPrivate: true)
        store.newTab(try #require(URL(string: "https://secret2.example/")), isPrivate: true)
        #expect(store.hasPrivateSession)
        // 存下来的只有普通的；无痕的编码出来也没有"isPrivate"（读回来一律是普通的，所以从来不存）
        let saved = BrowserTabStorage(suite: storage.suite, folder: storage.folder).load().tabs
        #expect(saved.map(\.url.host) == ["normal.example"])
        let encoded = String(decoding: try JSONEncoder().encode(store.tabs), as: UTF8.self)
        #expect(!encoded.contains("isPrivate"))

        let privateIDs = store.tabs.filter(\.isPrivate).map(\.id)
        store.closeTab(privateIDs[0])
        #expect(store.hasPrivateSession)          // 还有一个无痕的：数据留着
        store.closeTab(privateIDs[1])
        #expect(!store.hasPrivateSession)         // 最后一个也关了：那份数据扔掉
        // 离开浏览器时还开着的无痕标签页也一起关掉
        store.newTab(try #require(URL(string: "https://secret3.example/")), isPrivate: true)
        store.leave()
        #expect(store.tabs.filter(\.isPrivate).isEmpty)
        #expect(!store.hasPrivateSession)
    }

    @Test
    func tabBarFocusSkipsUnavailableButtonsAndStopsAtTheEnds() {
        let items = BrowserStore.barItems(tabs: ["a", "b"], canGoBack: false, canGoForward: true)
        #expect(items == [.forward, .tab("a"), .tab("b"), .newTab, .more])   // 不能后退：后退跳过
        #expect(BrowserStore.step(in: items, from: .tab("a"), by: -1) == .forward)
        #expect(BrowserStore.step(in: items, from: .forward, by: -1) == nil)
        #expect(BrowserStore.step(in: items, from: .tab("b"), by: 1) == .newTab)
        #expect(BrowserStore.step(in: items, from: .more, by: 1) == nil)
        #expect(BrowserStore.barItems(tabs: [], canGoBack: true, canGoForward: false) == [.back, .newTab, .more])
    }

    @Test
    func moreMenuMovesByRowsAndAcrossTheZoomButtons() {
        typealias Item = BrowserStore.MenuItem
        #expect(BrowserStore.menuStep(from: .newPrivateTab, .up) == nil)        // 第一行再往上：收起菜单
        #expect(BrowserStore.menuStep(from: .newPrivateTab, .down) == .reload)
        #expect(BrowserStore.menuStep(from: .reload, .down) == .zoomReset)      // 进缩放那一行停在中间
        #expect(BrowserStore.menuStep(from: .zoomReset, .left) == .zoomOut)
        #expect(BrowserStore.menuStep(from: .zoomOut, .left) == nil)
        #expect(BrowserStore.menuStep(from: .zoomIn, .right) == nil)
        #expect(BrowserStore.menuStep(from: .zoomIn, .down) == .closeTab)
        #expect(BrowserStore.menuStep(from: .startPage, .down) == nil)
        #expect(BrowserStore.menuStep(from: .reload, .right) == nil)
        #expect(Item.allCases.allSatisfy { !$0.name.isEmpty })
        // 开始页上的菜单只有两行
        let start = Item.startPageRows
        #expect(BrowserStore.menuStep(from: .newPrivateTab, .down, rows: start) == .closeTab)
        #expect(BrowserStore.menuStep(from: .closeTab, .down, rows: start) == nil)
    }

    @Test
    func closingATabGoesRightThenLeftThenToTheStartPage() {
        // 关的不是正在看的：还是原来那个
        #expect(BrowserStore.currentAfterClosing("a", in: ["a", "b", "c"], current: "b") == "b")
        // 关正在看的：右边那个；没有右边就左边那个；一个都不剩回开始页（nil）
        #expect(BrowserStore.currentAfterClosing("b", in: ["a", "b", "c"], current: "b") == "c")
        #expect(BrowserStore.currentAfterClosing("c", in: ["a", "b", "c"], current: "c") == "b")
        #expect(BrowserStore.currentAfterClosing("a", in: ["a"], current: "a") == nil)
        // 开始页自己是最后一个标签：关掉它回到左边那个；关掉别的，开始页还是正在看的
        let start = BrowserStore.startTabID
        #expect(BrowserStore.currentAfterClosing(start, in: ["a", "b", start], current: start) == "b")
        #expect(BrowserStore.currentAfterClosing("a", in: ["a", "b", start], current: start) == start)
        #expect(BrowserStore.currentAfterClosing(start, in: [start], current: start) == nil)
    }

    @Test
    func closeButtonIsOneStepLeftOfTheFocusedTabAndNeverInTheWayGoingRight() {
        let items = BrowserStore.barItems(tabs: ["a", "b"], canGoBack: true, canGoForward: false)
        #expect(BrowserStore.barStep(in: items, from: .tab("b"), .left) == .close("b"))   // 往左先到它的 ×
        #expect(BrowserStore.barStep(in: items, from: .close("b"), .right) == .tab("b"))  // 往右回到标签
        #expect(BrowserStore.barStep(in: items, from: .close("b"), .left) == .tab("a"))   // 再往左是前一个标签
        #expect(BrowserStore.barStep(in: items, from: .tab("a"), .right) == .tab("b"))    // 往右不经过 ×
        #expect(BrowserStore.barStep(in: items, from: .close("a"), .left) == .back)
        #expect(BrowserStore.barStep(in: items, from: .back, .left) == nil)
        #expect(BrowserStore.barStep(in: items, from: .tab("b"), .right) == .newTab)
        #expect(BrowserStore.barStep(in: items, from: .newTab, .left) == .tab("b"))
        #expect(BrowserStore.barStep(in: items, from: .more, .right) == nil)
        #expect(BrowserStore.barStep(in: items, from: .tab("a"), .up) == nil)
        #expect(BrowserStore.barStep(in: items, from: .tab("gone"), .left) == nil)        // 已经关掉的
    }

    @Test
    func tabsShareTheBarAndOnlyScrollWhenTheyCannotFit() {
        let available: CGFloat = 1584, gap: CGFloat = 12
        func total(_ widths: [CGFloat]) -> CGFloat { widths.reduce(0, +) + gap * CGFloat(max(0, widths.count - 1)) }
        for count in [1, 3, 4, 8] {
            let widths = BrowserTopBar.tabWidths(count: count, current: count - 1, available: available, gap: gap)
            #expect(widths.count == count)
            #expect(abs(total(widths) - available) < 0.5)                     // 放得下：占满这一条，不滚
            #expect(widths[count - 1] == widths.max())                        // 正在看的最宽
            #expect(Set(widths.dropLast()).count <= 1)                        // 别的一样宽
            #expect(widths.allSatisfy { $0 >= 150 })
        }
        #expect(BrowserTopBar.tabWidths(count: 1, current: 0, available: available, gap: gap) == [available])   // 一个：一整条地址栏
        // 十二个放不下：别的窄到 150 为止，横着滚
        let many = BrowserTopBar.tabWidths(count: 12, current: 5, available: available, gap: gap)
        #expect(total(many) > available)
        #expect(many.min() == 150)
        #expect(many[5] == 420)
    }

    @Test @MainActor
    func startPageShowsTheTabBarAndTucksItAwayInTheRows() throws {
        let defaults = UserDefaults.standard
        let saved = defaults.data(forKey: "browserHistory")
        defer { defaults.set(saved, forKey: "browserHistory") }
        defaults.removeObject(forKey: "browserHistory")
        BrowserHistory.add(try #require(URL(string: "https://a.example/")), title: "A")   // 一排"最近浏览"
        let (storage, cleanup) = Self.storage()
        defer { cleanup() }
        let store = BrowserStore(storage: storage)
        store.opened()
        let start = BrowserStore.startTabID
        // 一进来：标签栏露着，焦点在地址栏；开始页自己是标签栏上正在看的那个
        #expect(store.onStartPage && store.startBarShown && store.focus == .field && store.barFocus == nil)
        #expect(store.barTabs.map(\.id) == [start])
        #expect(store.barCurrentID == start)
        #expect(store.barItems == [.tab(start), .newTab, .more])          // 没有网页：没有后退、前进
        // 下到那几排里：标签栏收上去；回到地址栏还收着
        store.handle(.move(.down))
        #expect(store.focus == .item(row: 0, column: 0) && !store.startBarShown)
        store.handle(.move(.up))
        #expect(store.focus == .field && !store.startBarShown && store.barFocus == nil)
        // 再按上：回到一进来的样子；再按上进标签栏，停在开始页自己那个标签上
        #expect(store.canMove(.up))
        store.handle(.move(.up))
        #expect(store.focus == .field && store.startBarShown && store.barFocus == nil)
        store.handle(.move(.up))
        #expect(store.barFocus == .tab(start))
        #expect(store.startWheelRunsHorizontally)
        // 往左是它的 ×，往右回来；按下回到地址栏
        store.handle(.move(.left))
        #expect(store.barFocus == .close(start))
        store.handle(.move(.right))
        #expect(store.barFocus == .tab(start))
        store.handle(.move(.down))
        #expect(store.barFocus == nil && store.focus == .field && store.startBarShown)
        // 在那几排里按返回：回到地址栏，标签栏也回来
        store.handle(.move(.down))
        store.handle(.back)
        #expect(store.focus == .field && store.startBarShown)
        // 在标签栏里选开始页自己那个标签：它就是地址栏，直接打字
        store.handle(.move(.up))
        store.handle(.select)
        #expect(store.editing && store.barFocus == nil)
    }

    @Test @MainActor
    func closingATabOnTheStartPageKeepsFocusOnTheCurrentTab() throws {
        let (storage, cleanup) = Self.storage()
        defer { cleanup() }
        let store = BrowserStore(storage: storage)
        store.opened()
        store.newTab(try #require(URL(string: "https://a.example/")))
        store.newTab(try #require(URL(string: "https://b.example/")))
        let start = BrowserStore.startTabID
        let ids = store.tabs.map(\.id)
        #expect(store.barTabs.map(\.id) == ids + [start])                  // 开始页自己在最后
        store.focusBar(on: .close(ids[0]))
        store.handle(.select)
        #expect(store.tabs.map(\.id) == [ids[1]])
        #expect(store.barFocus == .tab(start))                             // 关的不是正在看的：焦点回正在看的那个
        // "⋯"菜单：开始页上只有 New Private Tab、Close Tab
        #expect(store.openMenu())
        #expect(store.menu == .newPrivateTab)
        store.handle(.select)                                              // New Private Tab：开始页换成无痕的
        #expect(store.startsPrivate && store.barIsPrivate && store.barFocus == nil && store.menu == nil)
    }

    @Test
    func tabPillShowsTheAddressWithoutSchemeOrWWW() throws {
        let home = try #require(URL(string: "https://www.github.com/"))
        let repo = try #require(URL(string: "https://github.com/apple/swift?tab=readme"))
        #expect(BrowserTopBar.address(home) == "github.com")
        #expect(BrowserTopBar.address(repo) == "github.com/apple/swift")
    }

    @Test @MainActor
    func recentTimesAreInEnglish() throws {
        let now = try #require(DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .current,
                                              year: 2026, month: 11, day: 19, hour: 15).date)
        #expect(BrowserTime.ago(now.addingTimeInterval(-20), now: now) == "Just now")
        #expect(BrowserTime.ago(now.addingTimeInterval(-5 * 60), now: now).contains("min"))
        #expect(BrowserTime.ago(now.addingTimeInterval(-26 * 3600), now: now) == "Yesterday")
        #expect(BrowserTime.ago(now.addingTimeInterval(-10 * 86400), now: now) == "Nov 9")
    }
}
