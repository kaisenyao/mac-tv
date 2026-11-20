import Foundation
import Testing
@testable import MacTV

/// 哔哩哔哩设置里的"左边栏显示"：首页一直都在；藏起来的页左边栏里没有，上下走时跳过
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor
struct BilibiliSidebarTests {
    private let key = "bilibiliSidebarHidden"

    /// 设置那一行右边写的：显示的几页里第一个，加上一共几项；全藏了是"只有首页"
    @Test
    func summaryCountsTheShownTabs() {
        #expect(BiliSidebar.choices == [.search, .following, .live, .mine])
        #expect(BiliSidebar.summary(hidden: []) == "搜索等 4 项")
        #expect(BiliSidebar.summary(hidden: [.search, .following]) == "直播、我的")
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

    /// 搜索历史先换成 words，跑完 body 再放回原来的（热搜当作已经取过、是空的：不联网）
    private func withSearchHistory(_ words: [String], _ body: (BilibiliStore) -> Void) {
        let saved = BiliSearchHistory.all
        defer {
            BiliSearchHistory.clear()
            for word in saved.reversed() { BiliSearchHistory.add(word) }
        }
        BiliSearchHistory.clear()
        for word in words.reversed() { BiliSearchHistory.add(word) }
        let store = BilibiliStore()
        store.pretendTrends([])
        store.select(.search)
        body(store)
    }

    /// 用鼠标点搜索框：和选中它按确认一样开始打字，焦点在这一页的哪里都行；已经在打字时再点什么也不变
    @Test
    func clickingSearchFieldStartsTyping() {
        withSearchHistory([]) { store in
            #expect(store.tab == .search && !store.editing)
            store.tapSearchField()                       // 从搜索页的内容上
            #expect(store.editing && store.focus == .typing)
            store.query = "猫"
            store.tapSearchField()                       // 已经在打字
            #expect(store.editing && store.query == "猫")
            store.handle(.back)                          // 不打了：搜索框还选着
            #expect(store.focus == .searchField)
            store.tapSearchField()                       // 从选中的搜索框上（同按确认）
            #expect(store.editing)
            store.handle(.back)
            store.handle(.move(.left))                   // 从左边栏上
            #expect(store.sidebarFocused)
            store.tapSearchField()
            #expect(store.editing && store.sidebarTab == .search)
        }
    }

    /// "清空"先问一句：停在"取消"上，上下在两项之间走，返回、点暗处、选"取消"都回到"清空"上不清；选"清空"才清
    @Test
    func clearingSearchHistoryAsksFirst() {
        withSearchHistory(["甲", "乙"]) { store in
            let clear = store.rows.first?.items.firstIndex(of: .clearHistory) ?? -1
            #expect(store.showingLanding && clear == 2)
            store.tapItem(row: 0, column: clear)         // 点"清空"：问一句，默认"取消"
            #expect(store.clearConfirmOpen && store.clearChoice == .cancel)
            store.handle(.move(.up))
            #expect(store.clearChoice == .cancel)
            store.handle(.move(.down))
            #expect(store.clearChoice == .clear)
            store.handle(.move(.down))                   // 到头不动
            #expect(store.clearChoice == .clear)
            store.handle(.back)                          // 返回 = 取消
            #expect(!store.clearConfirmOpen && store.focused == .clearHistory && BiliSearchHistory.all == ["甲", "乙"])
            store.handle(.select)                        // 再选"清空"：又问，又停在"取消"上
            #expect(store.clearConfirmOpen && store.clearChoice == .cancel)
            store.handle(.select)                        // 选"取消"
            #expect(!store.clearConfirmOpen && store.focused == .clearHistory && BiliSearchHistory.all.count == 2)
            store.handle(.select)
            store.dismissClearConfirm()                  // 点后面压暗的地方
            #expect(!store.clearConfirmOpen && store.focused == .clearHistory && BiliSearchHistory.all.count == 2)
            store.handle(.select)
            store.tapClearChoice(.clear)                 // 点"清空"那一项：清掉，搜索页重新摆
            #expect(!store.clearConfirmOpen && BiliSearchHistory.all.isEmpty)
            #expect(!(store.rows.contains { $0.id == "search-history" }))
        }
    }
}
