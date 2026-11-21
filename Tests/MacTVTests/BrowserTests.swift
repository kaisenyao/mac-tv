import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import MacTV

/// 浏览器：地址栏里打的字是网址还是搜索词、Safari 历史里网站的名字、在 Mac TV 里看过的页面
@Suite(.timeLimit(.minutes(1)))
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
        let (storage, cleanup) = Self.storage()
        defer { cleanup() }
        let a = try #require(URL(string: "https://a.example/")), b = try #require(URL(string: "https://b.example/"))
        storage.addHistory(a, title: "A")
        storage.addHistory(b, title: "B")
        storage.addHistory(a, title: "A again")
        #expect(storage.history.map(\.url) == [a, b])
        #expect(storage.history.first?.title == "A again")
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

    @Test
    func blankIconsGetTheLetterTileInstead() throws {
        // 全透明、一整块纯色、只有一个小点、淡得几乎看不见：都当没有图标（画字母），decode 不要它
        let clear = try #require(Self.image(background: .clear, mark: nil))
        let solid = try #require(Self.image(background: CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1), mark: nil))
        let speck = try #require(Self.image(background: .clear, square: CGRect(x: 30, y: 30, width: 4, height: 4)))
        let faint = try #require(Self.image(background: .clear, mark: CGColor(red: 0, green: 0, blue: 0, alpha: 0.1)))
        for (image, opaque) in [(clear, false), (solid, true), (speck, false), (faint, false)] {
            #expect(IconFetch.blank(image, opaque: opaque))
            #expect(IconFetch.decode(try #require(Self.png(image))) == nil)
        }
        // 有东西的照常：透明底上一个标志、白底上一块黑、满版的
        let mark = try #require(Self.image(background: .clear, mark: .black))
        let plain = try #require(Self.image(background: CGColor(red: 1, green: 1, blue: 1, alpha: 1), square: CGRect(x: 8, y: 40, width: 16, height: 16)))
        let split = try #require(Self.image(background: CGColor(red: 1, green: 0, blue: 0, alpha: 1), square: CGRect(x: 32, y: 0, width: 32, height: 64)))
        #expect(!IconFetch.blank(mark, opaque: false) && !IconFetch.blank(plain, opaque: true) && !IconFetch.blank(split, opaque: true))
        #expect(IconFetch.decode(try #require(Self.png(mark))) != nil)
    }

    @Test @MainActor
    func aSiteWithoutAnIconStaysKnownAsNone() async throws {
        // 确实没有图标的网站记在 NSCache 外面（缓存扔东西时不会变回"还不知道"，方块不会变成空的）。不联网：先放好"没有"的记号
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacTVTests.icons.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder.appendingPathComponent("no-icon.test.none").path, contents: nil)
        let icons = SiteIcons(folder: folder)
        #expect(await icons.load("no-icon.test") == nil)
        if case .none = icons.state(for: "no-icon.test") {} else { Issue.record("expected .none") }
    }

    private static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    @Test
    func logosAreFoundInsideTheirIconsSoTheyCanBeCentred() throws {
        // 白底、左上方一块黑：标志的位置（左上角为原点）和底色
        let plain = try #require(Self.image(background: CGColor(red: 1, green: 1, blue: 1, alpha: 1), square: CGRect(x: 8, y: 40, width: 16, height: 16)))
        let found = try #require(IconFetch.layout(plain, opaque: true))
        #expect(abs(found.content.minX - 8) <= 1 && abs(found.content.minY - 8) <= 1)
        #expect(abs(found.content.width - 16) <= 2 && abs(found.content.height - 16) <= 2)
        #expect(found.plate != nil)
        // 透明底：不透明的那一块，不垫自带的底色
        let mark = try #require(Self.image(background: .clear, mark: .black))
        let free = try #require(IconFetch.layout(mark, opaque: false))
        #expect(abs(free.content.midX - 32) <= 1 && abs(free.content.width - 32) <= 2 && free.plate == nil)
        // 满版的（四边不是一种颜色）：照原样铺满
        let split = try #require(Self.image(background: CGColor(red: 1, green: 0, blue: 0, alpha: 1), square: CGRect(x: 32, y: 0, width: 32, height: 64)))
        #expect(IconFetch.layout(split, opaque: true) == nil)
    }

    private static func image(background: CGColor, square: CGRect) -> CGImage? {
        guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(square)   // CG 的原点在左下角
        return context.makeImage()
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

    @Test @MainActor
    func zoomHasThreeLevelsAndMediumIsTheDefault() throws {
        #expect(BrowserZoomLevel.allCases.map(\.zoom) == [1.5, 1.75, 2])
        #expect(BrowserZoomLevel.allCases.map(\.name) == ["Small", "Medium", "Large"])
        // 以前记下的百分比：换成最近的一档，正好在中间的算"中"
        #expect(BrowserZoomLevel.nearest(1.25) == .small)
        #expect(BrowserZoomLevel.nearest(1.6) == .small)
        #expect(BrowserZoomLevel.nearest(1.625) == .medium)
        #expect(BrowserZoomLevel.nearest(1.9) == .large)
        #expect(BrowserZoomLevel.nearest(3) == .large)
        // 没记过、记的是以前的默认值（这台电视上是 200%）：中
        #expect(BrowserZoomLevel.level(stored: nil, oldDefault: 2) == .medium)
        #expect(BrowserZoomLevel.level(stored: 2, oldDefault: 2) == .medium)
        #expect(BrowserZoomLevel.level(stored: 2, oldDefault: 1.5) == .large)
        #expect(BrowserZoomLevel.level(stored: 1.25, oldDefault: 2) == .small)
        #expect(BrowserZoom.key("WWW.Apple.com") == "apple.com")
        // 每个网站：默认中；记下的照样按网站读（存在哪不变）
        let (storage, cleanup) = Self.storage()
        defer { cleanup() }
        let store = BrowserStore(storage: storage)
        #expect(store.zoom(for: "a.example", isPrivate: false) == 1.75)
        storage.setZoom(2, for: "b.example")
        storage.setZoom(1.25, for: "c.example")
        #expect(store.zoom(for: "www.b.example", isPrivate: false) == 2)
        #expect(store.zoom(for: "c.example", isPrivate: false) == 1.5)
        #expect(store.page.zoom == 1.75)
    }

    // MARK: 标签页

    /// 测试自己的一份：设置是临时文件夹里的一个 plist（不在 ~/Library/Preferences 里留文件），测完连文件夹一起删
    private static func storage() -> (BrowserTabStorage, cleanup: () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacTVTests.browser.\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = folder.appendingPathComponent("Preferences.plist").path
        return (BrowserTabStorage(suite: suite, folder: folder), {
            TestDefaults.remove(suite)
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
    func tabsAreNotCappedAndNoTabsRowOnTheStartPage() throws {
        let (storage, cleanup) = Self.storage()
        defer { cleanup() }
        let store = BrowserStore(storage: storage)
        for index in 0..<15 {
            store.newTab(try #require(URL(string: "https://site\(index).example/")))
        }
        // 不限个数：最早开的那几个还在（只有正在看的那个有网页视图），放不下就横着滚
        #expect(store.tabs.count == 15)
        #expect(store.tabs.first?.url.host == "site0.example" && store.tabs.last?.url.host == "site14.example")
        // 同一个网址已经开着：换到那个，不再开一个
        store.open(try #require(URL(string: "https://site13.example/")))
        #expect(store.tabs.count == 15)
        store.closeTab(try #require(store.tabs.first?.id))
        #expect(store.tabs.count == 14)
        #expect(BrowserTabStorage(suite: storage.suite, folder: storage.folder).load().tabs == store.tabs)
        // 标签页只在网页上面的标签栏里，开始页不再有"Tabs"一排
        store.rebuildRows()
        #expect(!store.rows.contains { $0.id == "tabs" })
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
        // 无痕浏览："+"前面是 Private
        #expect(BrowserStore.barItems(tabs: ["p"], canGoBack: false, canGoForward: false, privateBrowsing: true)
                == [.tab("p"), .privateBrowsing, .newTab, .more])
        #expect(BrowserStore.barStep(in: [.tab("p"), .privateBrowsing, .newTab, .more], from: .tab("p"), .right) == .privateBrowsing)
    }

    @Test
    func moreMenuMovesByRowsAndZoomIsAStepper() {
        typealias Item = BrowserStore.MenuItem
        #expect(BrowserStore.menuStep(from: .privateBrowsing, .up) == nil)      // 第一行再往上：收起菜单
        #expect(BrowserStore.menuStep(from: .privateBrowsing, .down) == .reload)
        #expect(BrowserStore.menuStep(from: .reload, .down) == .zoom)           // Zoom 是一行（步进）
        #expect(BrowserStore.menuStep(from: .zoom, .down) == .addFavorite)    // Add to Favorites
        #expect(BrowserStore.menuStep(from: .addFavorite, .down) == .history) // Show All History
        #expect(BrowserStore.menuStep(from: .history, .down) == .closeTab)
        #expect(BrowserStore.menuStep(from: .closeTab, .up) == .history)
        #expect(BrowserStore.menuStep(from: .zoom, .left) == nil)               // 左右不换行：换一档
        // 一档一档地走，到头停住，不绕回去
        #expect(BrowserStore.zoomStep(from: .medium, by: -1) == .small)
        #expect(BrowserStore.zoomStep(from: .medium, by: 1) == .large)
        #expect(BrowserStore.zoomStep(from: .small, by: -1) == nil)
        #expect(BrowserStore.zoomStep(from: .large, by: 1) == nil)
        #expect(BrowserZoomLevel.allCases.map(\.name) == ["Small", "Medium", "Large"])
        #expect(BrowserStore.menuStep(from: .startPage, .down) == nil)
        #expect(BrowserStore.menuStep(from: .reload, .right) == nil)
        #expect(Item.allCases.allSatisfy { !$0.name.isEmpty })
        // 开始页上的菜单：Private Browsing、Show All History、Close Tab
        let start = Item.startPageRows
        #expect(BrowserStore.menuStep(from: .privateBrowsing, .down, rows: start) == .history)
        #expect(BrowserStore.menuStep(from: .history, .down, rows: start) == .closeTab)
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
    }

    @Test @MainActor
    func closingTabsFollowsSafariAndEmptyTabsAreTabsToo() throws {
        let (storage, cleanup) = Self.storage()
        defer { cleanup() }
        let store = BrowserStore(storage: storage)
        store.newBlankTab()
        let b1 = try #require(store.blankID)
        // "+" 在空白标签页上也再开一个；焦点留在"+"上
        store.focusBar(on: .newTab)
        store.handle(.select)
        store.handle(.select)
        #expect(store.tabs.count == 3 && store.tabs.allSatisfy(\.isBlank))
        #expect(store.barFocus == .newTab)
        let ids = store.tabs.map(\.id)
        #expect(ids[0] == b1 && store.barCurrentID == ids[2])
        #expect(store.barTabs.map(\.id) == ids)                       // 标签栏上就是这些标签，没有另外的"开始页"
        // 换到中间那个，再关掉它（正在看的）：换到右边那个；按下的那个 × 沉一下
        store.focusBar(on: .tab(ids[1]))
        store.handle(.select)
        #expect(store.barCurrentID == ids[1] && store.barFocus == .tab(ids[1]))
        store.handle(.move(.left))
        #expect(store.barFocus == .close(ids[1]))
        store.handle(.select)
        #expect(store.pressed == .close(ids[1]))
        #expect(store.tabs.map(\.id) == [ids[0], ids[2]])
        #expect(store.barCurrentID == ids[2] && store.barFocus == .tab(ids[2]))
        // 再关正在看的（最右边）：换到左边那个
        store.closeTab(ids[2])
        #expect(store.tabs.map(\.id) == [ids[0]] && store.barCurrentID == ids[0])
        // 关掉一个不是正在看的：正在看的不变，焦点回到它上面
        store.focusBar(on: .newTab)
        store.handle(.select)
        let b4 = try #require(store.blankID)
        store.focusBar(on: .close(ids[0]))
        store.handle(.select)
        // 只剩一个了：焦点离开标签栏（回开始页的搜索框），剩下的那个不留成白的
        #expect(store.tabs.map(\.id) == [b4] && store.barCurrentID == b4 && store.barFocus == nil && store.focus == .field)
    }

    @Test @MainActor
    func backOnAFreshEmptyTabUndoesThePlus() throws {
        let (storage, cleanup) = Self.storage()
        defer { cleanup() }
        let store = BrowserStore(storage: storage)
        store.newBlankTab()
        let first = try #require(store.blankID)
        store.focusBar(on: .newTab)
        store.handle(.select)
        let fresh = try #require(store.blankID)
        #expect(fresh != first)
        store.handle(.move(.down))            // 回到地址栏
        #expect(store.barFocus == nil && store.focus == .field)
        store.handle(.back)                   // 当没开过：关掉它，回到开它时看着的那个
        #expect(store.tabs.map(\.id) == [first] && store.blankID == first)
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
    func theCapsuleHugsTheTabsAndTheCurrentOneIsWider() {
        let available: CGFloat = 1584, gap: CGFloat = 6
        func total(_ widths: [CGFloat]) -> CGFloat { widths.reduce(0, +) + gap * CGFloat(max(0, widths.count - 1)) }
        // 一个标签：胶囊就是它，720
        #expect(BrowserTopBar.tabWidths(count: 1, current: 0, available: available, gap: gap) == [BrowserTopBar.editWidth])
        // 两三个：正在看的 560，别的 360，胶囊裹着它们（没撑满）
        #expect(BrowserTopBar.tabWidths(count: 2, current: 1, available: available, gap: gap) == [360, 560])
        let three = BrowserTopBar.tabWidths(count: 3, current: 0, available: available, gap: gap)
        #expect(three == [560, 360, 360] && total(three) < available)
        // 四个撑满：别的变窄，正在看的还是 560
        let four = BrowserTopBar.tabWidths(count: 4, current: 2, available: available, gap: gap)
        #expect(four[2] == 560 && four[0] == four[1] && four[1] == four[3] && abs(total(four) - available) < 0.5)
        // 七个：正在看的让到 440，别的变窄，正好撑满，不滚
        let seven = BrowserTopBar.tabWidths(count: 7, current: 3, available: available, gap: gap)
        #expect(seven[3] == 440 && seven[0] > BrowserTopBar.minWidth && abs(total(seven) - available) < 0.5)
        // 再多：别的最窄 180（还看得见图标和标题的开头，不缩成一颗颗图标），放不下就横着滚
        let eight = BrowserTopBar.tabWidths(count: 8, current: 3, available: available, gap: gap)
        #expect(eight.enumerated().allSatisfy { $0.offset == 3 || $0.element == BrowserTopBar.minWidth } && total(eight) > available)
        let many = BrowserTopBar.tabWidths(count: 24, current: 3, available: available, gap: gap)
        #expect(many.enumerated().allSatisfy { $0.offset == 3 || $0.element == 180 } && total(many) > available)
        // 改地址的那个要 720（不让），别的让一让
        let editing = BrowserTopBar.tabWidths(count: 3, current: 1, editing: true, available: available, gap: gap)
        #expect(editing == [360, BrowserTopBar.editWidth, 360])
        #expect(BrowserTopBar.tabWidths(count: 12, current: 11, editing: true, available: available, gap: gap).dropLast()
                    .allSatisfy { $0 == BrowserTopBar.minWidth })
        // 从网页回到开始页（没有正在看的）：一样宽
        #expect(Set(BrowserTopBar.tabWidths(count: 3, current: nil, available: available, gap: gap)) == [360])
    }

    @Test @MainActor
    func theCurrentTabEditsItsAddressInPlace() throws {
        let (storage, cleanup) = Self.storage()
        defer { cleanup() }
        let page = BrowserTab(url: try #require(URL(string: "https://a.example/page")), title: "A")
        storage.save([page], active: page.id)
        let store = BrowserStore(storage: storage)                    // 正在看一个网页
        #expect(store.barCurrentID == page.id)
        store.activate(.tab(page.id))                                 // 选正在看的那个：就在标签栏上改，不去开始页
        #expect(store.editing && store.editingInBar && !store.onStartPage && store.barFocus == .tab(page.id))
        #expect(store.query == "https://a.example/page" && store.replaceQuery)   // 整个网址选中
        _ = store.handleBar(.text("n"))                               // 手机上打的字：换掉选中的网址
        #expect(store.query == "n")
        _ = store.handleBar(.text("ews.example"))
        _ = store.handleBar(.deleteBackward)
        #expect(store.query == "news.exampl")
        _ = store.handleBar(.back)                                    // 返回：不改了，标签还是原来的样子，焦点回网页（标签不会一下变白）
        #expect(!store.editing && !store.editingInBar && store.barFocus == nil && store.tabs == [page] && store.query.isEmpty)
        // 打的字去哪：像网址的就是它，别的去搜
        #expect(BrowserStore.destination("apple.com")?.absoluteString == "https://apple.com")
        #expect(BrowserStore.destination("how to cook rice")?.host == "www.google.com")

        // 空白标签页：选它也是就地改，一开始是空的
        store.newBlankTab()
        let blank = try #require(store.blankID)
        store.focusBar()
        #expect(store.barFocus == .tab(blank))
        store.handle(.select)
        #expect(store.editing && store.editingInBar && store.query.isEmpty && !store.replaceQuery)
        store.handle(.text("example.com"))
        #expect(store.query == "example.com")
        store.handle(.back)
        #expect(!store.editing && store.barFocus == nil && store.focus == .field)   // 开始页上：回地址栏
    }

    @Test @MainActor
    func startPageShowsTheTabBarAndTucksItAwayInTheRows() throws {
        let (storage, cleanup) = Self.storage()
        defer { cleanup() }
        storage.addHistory(try #require(URL(string: "https://a.example/")), title: "A")   // 一排"最近浏览"
        let store = BrowserStore(storage: storage)
        store.resumeLastTab()                                           // 一个标签页都没有：开一个空白的
        let start = try #require(store.blankID)
        // 一进来：标签栏露着，焦点在地址栏；空白标签页是标签栏上正在看的那个
        #expect(store.onStartPage && store.startBarShown && store.focus == .field && store.barFocus == nil)
        #expect(store.barTabs.map(\.id) == [start] && store.tabs.first?.isBlank == true)
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
        // 只有这一个标签：没有 ×，往左走不到它
        store.handle(.move(.left))
        #expect(store.barFocus == .tab(start))
        store.handle(.move(.down))
        #expect(store.barFocus == nil && store.focus == .field && store.startBarShown)
        // 在那几排里按返回：回到地址栏，标签栏也回来
        store.handle(.move(.down))
        store.handle(.back)
        #expect(store.focus == .field && store.startBarShown)
        // 在标签栏里选正在看的那个：它就地变成地址栏
        store.handle(.move(.up))
        store.handle(.select)
        #expect(store.editing && store.editingInBar && store.barFocus == .tab(start))
    }

    @Test @MainActor
    func theLastTabTurnsIntoAStartPageAndAStartPageAloneHasNoClose() throws {
        let (storage, cleanup) = Self.storage()
        defer { cleanup() }
        let page = BrowserTab(url: try #require(URL(string: "https://a.example/")), title: "A")
        storage.save([page], active: page.id)
        let store = BrowserStore(storage: storage)
        // 只剩一个、开着网站：有 ×，菜单里有 Close Tab，往左到它的 ×
        #expect(store.tabsClosable && store.menuRows.flatMap { $0 }.contains(.closeTab))
        let one = BrowserStore.barItems(tabs: [page.id], canGoBack: true, canGoForward: false)
        #expect(BrowserStore.barStep(in: one, from: .tab(page.id), .left, closable: true) == .close(page.id))
        // 关掉它：不离开浏览器，同一个标签（同一块胶囊）变成空白的开始页，焦点在搜索框
        store.focusBar(on: .close(page.id))
        store.activate(.close(page.id))
        #expect(store.tabs.count == 1 && store.tabs[0].id == page.id && store.tabs[0].isBlank)
        #expect(store.onStartPage && store.blankID == page.id && store.focus == .field && store.barFocus == nil && !store.editing)
        // 只剩一个空白标签页：没有可关的（没有 ×，菜单里没有 Close Tab，往左不到 ×，关也关不掉）
        #expect(!store.tabsClosable && !store.menuRows.flatMap { $0 }.contains(.closeTab))
        #expect(BrowserStore.barStep(in: one, from: .tab(page.id), .left, closable: store.tabsClosable) == .back)
        #expect(BrowserStore.barStep(in: BrowserStore.barItems(tabs: [page.id], canGoBack: false, canGoForward: false),
                                     from: .tab(page.id), .left, closable: false) == nil)
        store.closeTab(page.id)
        #expect(store.tabs.count == 1 && store.tabs[0].isBlank)
        // 两个标签：都能关，× 在往左一格；关掉一个只剩一个时，焦点离开标签栏（剩下的那个不是白的）
        store.newBlankTab()
        #expect(store.tabsClosable && store.menuRows.flatMap { $0 }.contains(.closeTab))
        let two = BrowserStore.barItems(tabs: store.tabs.map(\.id), canGoBack: false, canGoForward: false)
        #expect(BrowserStore.barStep(in: two, from: .tab(page.id), .left, closable: true) == .close(page.id))
        let added = try #require(store.blankID)
        store.focusBar(on: .close(added))
        store.activate(.close(added))
        #expect(store.tabs.count == 1 && store.barFocus == nil && store.focus == .field)
    }

    @Test @MainActor
    func aClickOutsideTheAddressFieldEndsEditingLikeBack() throws {
        let (storage, cleanup) = Self.storage()
        defer { cleanup() }
        let page = BrowserTab(url: try #require(URL(string: "https://a.example/")), title: "A")
        let other = BrowserTab(url: try #require(URL(string: "https://b.example/")), title: "B")
        storage.save([page, other], active: page.id)
        let store = BrowserStore(storage: storage)
        // 网页上，在标签栏里改地址：点了外面就不改了，标签回到原来的样子，焦点离开标签栏，没去别的网址
        store.activate(.tab(page.id))
        _ = store.handleBar(.text("news"))
        #expect(store.editing && store.editingInBar)
        store.endEditingByClick()
        #expect(!store.editing && !store.editingInBar && store.barFocus == nil && store.query.isEmpty && store.tabs == [page, other])
        // 开始页上（一个、几个标签都一样）：标签栏里的地址栏、开始页自己的搜索框
        store.newBlankTab()
        let blank = try #require(store.blankID)
        store.focusBar(on: .tab(blank))
        store.handle(.select)
        #expect(store.editing && store.editingInBar)
        store.endEditingByClick()
        #expect(!store.editing && store.barFocus == nil && store.focus == .field)
        store.startEditing()
        #expect(store.editing && !store.editingInBar)
        store.endEditingByClick()
        #expect(!store.editing)
    }

    @Test @MainActor
    func holdingBackLeavesTheBrowserFromEveryStateOfTheBar() throws {
        _ = NSApplication.shared
        AudioCoordinator.readVolume = { VolumeLevel(level: 50, muted: false) }
        // 浏览器把标签页存在 UserDefaults.standard 里（测试里是临时文件夹里的一份，见 TestSandbox.m）：用完原样放回去
        let keys = ["browserTabs", "browserActiveTab", "browserZoom", "browserHistory"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacTVTests.library.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tv = TVController(library: AppLibrary(folder: folder))
        let store = tv.browserStore
        store.tv = tv

        /// 开着浏览器的开始页（一个空白标签页，没有网页、不联网），再摆成某个样子
        func open(_ arrange: () -> Void) {
            store.newBlankTab()
            tv.browserOpen = true
            arrange()
            #expect(tv.browserOpen && store.onStartPage)
        }
        let states: [(String, () -> Void)] = [
            ("search field", {}),
            ("tab focused", { store.focusBar() }),
            ("editing the address in the bar", { store.focusBar(); store.handle(.select) }),
            ("the ⋯ menu", { _ = store.openMenu() }),
        ]
        for (name, arrange) in states {
            // 手机、Siri Remote：按住返回是回主屏，浏览器留在后台（按住 Esc 也是，见 AppQuit）
            open(arrange)
            tv.handle(.press(.back, .hold), from: .remote)
            tv.handle(.press(.back, .release), from: .remote)
            #expect(!tv.browserOpen && tv.backgroundApps.first?.id == BrowserStore.appID, "hold Back from \(name)")
            // TV 键：一样（两次之间隔开，免得算成连按两下）
            open(arrange)
            tv.lastTVPress = nil
            tv.handle(.home)
            #expect(!tv.browserOpen, "Home from \(name)")
            tv.lastTVPress = nil
        }
        // 按一下返回还是原来那样：改地址时是不改了（回地址栏），不离开浏览器
        open { store.focusBar(); store.handle(.select) }
        #expect(store.editing)
        tv.handle(.press(.back, .tap), from: .remote)
        #expect(tv.browserOpen && !store.editing && store.barFocus == nil)
        tv.handle(.home)
    }

    @Test @MainActor
    func startPageMenuTurnsOnPrivateBrowsing() throws {
        let (storage, cleanup) = Self.storage()
        defer { cleanup() }
        let store = BrowserStore(storage: storage)
        store.newBlankTab()
        let normal = store.tabs
        // "⋯"菜单：开始页上是 Private Browsing、Show All History、Close Tab；只有一个空白标签页时没有 Close Tab
        #expect(store.openMenu())
        #expect(store.menu == .privateBrowsing)
        #expect(store.menuRows == [[.privateBrowsing], [.history]])
        store.handle(.select)                                              // Private Browsing：标签栏换成一个无痕的 Start Page
        #expect(store.privateBrowsing && store.tabs.count == 1 && store.tabs[0].isPrivate && store.tabs[0].isBlank)
        #expect(store.barFocus == nil && store.menu == nil && store.focus == .field && store.onStartPage)
        // 再选一次：出来，原来的标签回来
        #expect(store.openMenu())
        store.handle(.select)
        #expect(!store.privateBrowsing && store.tabs == normal)
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
