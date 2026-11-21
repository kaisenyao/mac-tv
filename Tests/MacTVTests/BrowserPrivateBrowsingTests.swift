import AppKit
import SwiftUI
import Testing
@testable import MacTV

/// 无痕浏览是这一个浏览器的一种状态（标签栏换成另一组），⌘N / ⇧⌘N，和标签多到放不下时这一排横着滚到哪
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct BrowserPrivateBrowsingTests {
    /// 测试自己的一份：设置是临时文件夹里的一个 plist，测完连文件夹一起删
    private static func storage() -> (BrowserTabStorage, cleanup: () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacTVTests.private.\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = folder.appendingPathComponent("Preferences.plist").path
        return (BrowserTabStorage(suite: suite, folder: folder), {
            TestDefaults.remove(suite)
            try? FileManager.default.removeItem(at: folder)
        })
    }

    /// 一个开着浏览器的 TVController（标签页存在 UserDefaults.standard 里：测试里是临时文件夹里的一份，见 TestSandbox.m；
    /// 用完原样放回去）。只开空白标签页和无痕的网页：普通的网页会用这个人真的网站数据，这里不开
    private static func withTV(_ body: (TVController, BrowserStore) throws -> Void) throws {
        _ = NSApplication.shared
        AudioCoordinator.readVolume = { VolumeLevel(level: 50, muted: false) }
        let keys = ["browserTabs", "browserActiveTab", "browserZoom", "browserHistory"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacTVTests.private.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tv = TVController(library: AppLibrary(folder: folder))
        let store = tv.browserStore
        store.tv = tv
        defer { store.closePrivateTabs(); tv.playbackCoordinator.closeWebPlayback() }
        try body(tv, store)
    }

    // MARK: ⌘N、⇧⌘N

    @Test
    func commandNIsNewTabAndShiftCommandNIsPrivateBrowsing() throws {
        typealias Shortcut = BrowserStore.Shortcut
        // ⌘T 和 ⌘N 都是新标签页（⌘N 在菜单里不显示）；⇧⌘N 是 Private Browsing
        #expect(Shortcut.newTab.key.0 == "t" && Shortcut.newTab.key.1 == [.command])
        #expect(Shortcut.newTab.hiddenKeys == ["n"])
        #expect(Shortcut.privateBrowsing.key.0 == "N" && Shortcut.privateBrowsing.key.1 == [.command, .shift])
        #expect(Shortcut.privateBrowsing.title == "Private Browsing")
        // 每一个键只做一件事（⌘N 和 ⇧⌘N 不撞：一个是小写 n，一个是大写 N 加 ⇧）
        let all = Shortcut.allCases.flatMap { shortcut in
            ([shortcut.key.0] + shortcut.hiddenKeys).map { "\($0)|\(shortcut.key.1.rawValue)" }
        }
        #expect(Set(all).count == all.count)

        try Self.withTV { tv, store in
            store.newBlankTab()
            #expect(tv.browserOpen && store.canPerform(.newTab) && store.canPerform(.privateBrowsing))
            // ⌘N：和按"+"一样，标签栏最后多一个 Start Page，焦点留在"+"上
            store.perform(.newTab)
            #expect(store.tabs.count == 2 && store.tabs.allSatisfy(\.isBlank) && store.barCurrentID == store.tabs.last?.id)
            #expect(store.barFocus == .newTab)
            let normal = store.tabs
            // ⇧⌘N：进无痕浏览，一个无痕的 Start Page，焦点在它的搜索框；标签栏上 Private 在"+"前面
            store.perform(.privateBrowsing)
            #expect(store.privateBrowsing && store.tabs.count == 1 && store.tabs[0].isPrivate && store.tabs[0].isBlank)
            #expect(store.onStartPage && store.focus == .field && store.barFocus == nil)
            #expect(store.barItems.suffix(3) == [.privateBrowsing, .newTab, .more])
            // 无痕浏览时 ⌘N 开的也是无痕的
            store.perform(.newTab)
            #expect(store.tabs.count == 2 && store.tabs.allSatisfy(\.isPrivate))
            // 再按 ⇧⌘N：出来，普通的两个原样回来
            store.perform(.privateBrowsing)
            #expect(!store.privateBrowsing && store.tabs == normal && !store.hasPrivateSession)
            #expect(!store.barItems.contains(.privateBrowsing))
        }
    }

    @Test
    func thePrivateControlLeavesPrivateBrowsingAndFocusMovesToPlus() throws {
        try Self.withTV { _, store in
            store.newBlankTab()
            let normal = store.tabs
            store.perform(.privateBrowsing)
            // 遥控器走得到它：从无痕的那个标签往右一格
            store.focusBar()
            store.handle(.move(.right))
            #expect(store.barFocus == .privateBrowsing)
            store.handle(.select)
            #expect(!store.privateBrowsing && store.tabs == normal && store.barFocus == .newTab)
            // 不在无痕浏览时没有它：选它（比如鼠标点到一个刚消失的）什么都不做
            store.activate(.privateBrowsing)
            #expect(!store.privateBrowsing)
        }
    }

    // MARK: 进、出

    @Test
    func leavingPrivateBrowsingBringsTheNormalTabsBackExactly() throws {
        let (storage, cleanup) = Self.storage()
        defer { cleanup() }
        let a = BrowserTab(url: try #require(URL(string: "https://a.example/one")), title: "A")
        let b = BrowserTab(url: try #require(URL(string: "https://b.example/two")), title: "B")
        let c = BrowserTab(url: BrowserStore.blankURL, title: "")
        storage.save([a, b, c], active: b.id)
        let store = BrowserStore(storage: storage)
        store.togglePrivateBrowsing()
        #expect(store.privateBrowsing && store.hasPrivateSession)
        #expect(store.tabs.count == 1 && store.tabs[0].isPrivate && store.tabs[0].isBlank)
        // 无痕的里面开、关、换：普通的那一组不动，存下来的还是它们
        store.newTab(try #require(URL(string: "https://secret.example/")))
        store.newBlankTab()
        store.closeTab(store.tabs[0].id)
        #expect(store.tabs.count == 2 && store.tabs.allSatisfy(\.isPrivate))
        let saved = storage.load()
        #expect(saved.tabs == [a, b, c] && saved.active == b.id)
        // 只剩一个开着网站的无痕标签、关掉它：它变回一个无痕的 Start Page，还在无痕浏览
        store.closeTab(store.tabs[1].id)
        #expect(store.tabs.count == 1 && store.tabs[0].url.host == "secret.example")
        store.closeTab(store.tabs[0].id)
        #expect(store.privateBrowsing && store.hasPrivateSession)
        #expect(store.tabs.count == 1 && store.tabs[0].isPrivate && store.tabs[0].isBlank)
        // 出来：一样的标签、一样的顺序、正在看的还是 b；无痕的那份数据没了
        store.togglePrivateBrowsing()
        #expect(!store.privateBrowsing && !store.hasPrivateSession)
        #expect(store.tabs == [a, b, c] && store.activeID == b.id)
        #expect(storage.load().tabs == [a, b, c])
        // 退出 Web、换人、退出 Mac TV（closePrivateTabs）：一样回来，什么都不打开
        store.togglePrivateBrowsing()
        store.closePrivateTabs()
        #expect(!store.privateBrowsing && store.tabs == [a, b, c] && store.activeID == b.id && !store.hasPrivateSession)
    }

    @Test
    func privateBrowsingRemembersNothing() throws {
        try Self.withTV { tv, store in
            store.newBlankTab()
            let normal = store.tabs
            store.perform(.privateBrowsing)
            let privateID = try #require(store.tabs.first?.id)
            // 无痕的开始页只有个人收藏：最近、常去的不摆出来
            #expect(store.rows.allSatisfy { $0.id == "favorites" })
            // 在无痕的 Start Page 上打开一个网址（本机一个没人听的端口：不出这台 Mac，马上就失败）
            let url = try #require(URL(string: "http://127.0.0.1:9/private-page"))
            store.open(url)
            let web = try #require(tv.webView)
            // 网页用的是不落盘的那一份网站数据
            #expect(!web.configuration.websiteDataStore.isPersistent)
            #expect(store.tabs.count == 1 && store.tabs[0].isPrivate && store.tabs[0].url == url)
            store.pageLoaded(web)
            #expect(store.stepZoom(1))
            // 什么都没记：历史、标签页、缩放
            let storage = store.profileStorage
            #expect(!storage.history.contains { $0.url.host == "127.0.0.1" })
            #expect(storage.load().tabs == normal)
            #expect(storage.zoom(for: "127.0.0.1") == nil)
            // 出来：网页视图关了，那份数据扔了，没有截图留在磁盘上，普通的开始页回来
            store.perform(.privateBrowsing)
            #expect(tv.webView == nil && !store.hasPrivateSession && store.tabs == normal && store.onStartPage)
            #expect(!FileManager.default.fileExists(atPath: storage.snapshotFile(privateID).path))
            #expect(!storage.history.contains { $0.url.host == "127.0.0.1" })
        }
    }

    // MARK: 横着滚

    @Test
    func theStripScrollsTheLeastToKeepTheSelectedTabInView() {
        let available = BrowserTopBar.trackWidth(canvas: 1920, privateBrowsing: false) - BrowserTopBar.inset * 2
        let gap = BrowserTopBar.tabGap, fade = BrowserTopBar.fade
        // 十五个标签，正在看的是第八个（440 宽），别的 180
        let widths = BrowserTopBar.tabWidths(count: 15, current: 7, available: available, gap: gap)
        let viewport = BrowserTopBar.capsuleWidth(widths: widths, available: available + BrowserTopBar.inset * 2) - BrowserTopBar.inset * 2
        let limit = BrowserTopBar.stripLength(widths) - viewport
        #expect(limit > 0 && abs(viewport - available) < 0.5)
        func visible(_ index: Int, at offset: CGFloat) -> Bool {
            let start = widths.prefix(index).reduce(0, +) + gap * CGFloat(index)
            let end = start + widths[index]
            let lead = index == 0 ? 0 : fade, trail = index == widths.count - 1 ? 0 : fade
            return start - lead >= offset - 0.5 && end + trail <= offset + viewport + 0.5
        }
        func scroll(_ index: Int?, from offset: CGFloat) -> CGFloat {
            BrowserTopBar.scrollOffset(keeping: index, widths: widths, gap: gap, viewport: viewport, from: offset, fade: fade)
        }
        // 从头开始，焦点一格一格往右走到最后：选中的总整个露着，而且只往前挪（不来回跳）
        var offset: CGFloat = 0
        for index in 0..<widths.count {
            let next = scroll(index, from: offset)
            #expect(visible(index, at: next), "tab \(index) at \(next)")
            #expect(next >= offset - 0.5)
            #expect(next >= 0 && next <= limit + 0.5)
            offset = next
        }
        #expect(abs(offset - limit) < 0.5)                 // 最后一个：滚到头，那一头不淡
        // 往左走回来：已经露着的不动；露不全了才挪，挪到它整个露出来为止
        #expect(scroll(13, from: offset) == offset)
        let back = scroll(3, from: offset)
        #expect(visible(3, at: back) && back < offset)
        #expect(scroll(0, from: back) == 0)                 // 第一个：滚到最前面
        // 正在看的第八个在中间：两头都还有被截掉的（两头都淡出去）
        let middle = scroll(7, from: 0)
        #expect(middle > 0 && middle < limit && visible(7, at: middle))
        // 鼠标滚过的地方超出了范围（标签关掉了）：收回到范围里；没有选中的就不动
        #expect(scroll(nil, from: 99_999) == limit)
        #expect(scroll(nil, from: -40) == 0)
        // 放得下：不滚
        let three = BrowserTopBar.tabWidths(count: 3, current: 0, available: available, gap: gap)
        let fits = BrowserTopBar.capsuleWidth(widths: three, available: available + BrowserTopBar.inset * 2) - BrowserTopBar.inset * 2
        #expect(BrowserTopBar.scrollOffset(keeping: 2, widths: three, gap: gap, viewport: fits, from: 0, fade: fade) == 0)
    }

    @Test
    func thePageStartsOnAWholePixelUnderTheBar() {
        // 1920×1080 的窗口：正好 80；1280×720（比例 2/3）：53.33 往下取到像素，2 倍屏上是 53.5
        #expect(BrowserPageView.pageTop(window: CGSize(width: 1920, height: 1080), displayScale: 2) == 80)
        #expect(BrowserPageView.pageTop(window: CGSize(width: 1280, height: 720), displayScale: 2) == 53.5)
        #expect(BrowserPageView.pageTop(window: CGSize(width: 1280, height: 720), displayScale: 1) == 54)
    }

    // MARK: 标签栏的样子（只有 MACTV_RENDER_BROWSER=<文件夹> 时才画）

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACTV_RENDER_BROWSER"] != nil))
    func renderTheTabStrip() throws {
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACTV_RENDER_BROWSER"] ?? "/tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let names = ["Apple", "GitHub", "Wikipedia", "The Verge", "Hacker News", "BBC News", "Weather", "Maps", "Swift Forums",
                     "Developer Documentation", "Music", "Photos", "Calendar", "Reminders", "Notes"]
        func tabs(_ count: Int) throws -> [BrowserTab] {
            try (0..<count).map { BrowserTab(url: try #require(URL(string: "https://site\($0).example/")), title: "\(names[$0]) – Site") }
        }
        func render(_ name: String, _ store: BrowserStore) throws {
            let view = VStack(spacing: 0) {
                BrowserTopBar(store: store, surface: .solid)
                Color.white.frame(height: 120)   // 网页从标签栏下面开始
            }
            .environment(\.canvasSize, CGSize(width: 1920, height: 1080))
            .environment(\.colorScheme, .dark)
            .frame(width: 1920, height: 200)
            .background(Color.black)
            // An NSHostingView drawn into a bitmap, in no window (ImageRenderer would draw the strip's invisible
            // scroll-wheel view as a placeholder)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 1920, height: 200)
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try #require(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(name).png"))
        }
        for (name, count, active) in [("tabs-3", 3, 1), ("tabs-15-middle", 15, 7)] {
            let (storage, cleanup) = Self.storage()
            defer { cleanup() }
            let all = try tabs(count)
            storage.save(all, active: all[active].id)
            try render(name, BrowserStore(storage: storage))
        }
        let (storage, cleanup) = Self.storage()
        defer { cleanup() }
        let all = try tabs(3)
        storage.save(all, active: all[0].id)
        let store = BrowserStore(storage: storage)
        store.togglePrivateBrowsing()
        store.newTab(try #require(URL(string: "https://private.example/")))
        store.newBlankTab()
        try render("tabs-private", store)
    }
}
