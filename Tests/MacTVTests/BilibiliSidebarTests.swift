import Foundation
import Testing
@testable import MacTV

/// 哔哩哔哩设置里的"左边栏显示"：首页一直都在；藏起来的页左边栏里没有，上下走时跳过
@Suite(.serialized) @MainActor
struct BilibiliSidebarTests {
    private let key = "bilibiliSidebarHidden"

    /// 设置那一行右边写的：显示的几页里第一个，加上一共几项；全藏了是"只有首页"
    @Test
    func summaryCountsTheShownTabs() {
        #expect(BiliSidebar.choices == [.search, .following, .live, .mine])
        #expect(BiliSidebar.summary(hidden: []) == "搜索 等 4 项")
        #expect(BiliSidebar.summary(hidden: [.search, .following]) == "直播 等 2 项")
        #expect(BiliSidebar.summary(hidden: [.search, .following, .mine]) == "直播")
        #expect(BiliSidebar.summary(hidden: Set(BiliSidebar.choices)) == "仅首页")
    }

    /// 记的是藏起来的几页；首页、认不出的写不进去
    @Test
    func hiddenTabsAreStored() {
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(["live", "home", "nonsense"], forKey: key)
        #expect(BiliSidebar.hidden == [.live])
        BiliSidebar.hidden = [.search, .home]
        #expect(UserDefaults.standard.stringArray(forKey: key) == ["search"])
        UserDefaults.standard.removeObject(forKey: key)
        #expect(BiliSidebar.hidden.isEmpty)   // 默认全都显示
    }

    /// 勾掉"搜索"：左边栏里没有它，从首页往上走不动（不出声），往下照常到"关注"
    @Test
    func stepSkipsHiddenTabs() {
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        let store = BilibiliStore()
        store.chooseSetting(.sidebar, BiliSidebar.choices.firstIndex(of: .search) ?? 0)
        #expect(store.visibleTabs == [.home, .following, .live, .mine])
        store.handle(.move(.left))
        #expect(store.sidebarFocused && store.sidebarTab == .home)
        let before = store.focusKey
        store.handle(.move(.up))
        #expect(store.sidebarTab == .home && store.focusKey == before)
        store.handle(.move(.down))
        #expect(store.sidebarTab == .following && store.focusKey != before)
        store.chooseSetting(.sidebar, BiliSidebar.choices.firstIndex(of: .search) ?? 0)   // 再勾上
        #expect(store.visibleTabs == BilibiliStore.Tab.allCases)
    }
}
