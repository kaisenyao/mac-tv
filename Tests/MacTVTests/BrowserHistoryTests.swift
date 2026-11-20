import AppKit
import Foundation
import Testing
@testable import MacTV

/// History（Show All History，⌘Y）：按天分组的标题、搜索、Remove from History、Clear History…、返回
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct BrowserHistoryTests {
    static func storage() -> (BrowserTabStorage, cleanup: () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacTVTests.history.\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = folder.appendingPathComponent("Preferences.plist").path
        return (BrowserTabStorage(suite: suite, folder: folder), {
            TestDefaults.remove(suite)
            try? FileManager.default.removeItem(at: folder)
        })
    }

    @Test
    func daysAreHeadedTodayYesterdayWeekdayThenDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 15)))   // a Friday
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: -offset, to: now)! }
        #expect(BrowserHistoryList.header(for: day(0), now: now, calendar: calendar) == "Today")
        #expect(BrowserHistoryList.header(for: day(1), now: now, calendar: calendar) == "Yesterday")
        #expect(BrowserHistoryList.header(for: day(3), now: now, calendar: calendar) == day(3).formatted(.dateTime.weekday(.wide)))
        #expect(BrowserHistoryList.header(for: day(10), now: now, calendar: calendar) == day(10).formatted(.dateTime.month(.wide).day().year()))
        // 分组：一天一组，新的在前，每一条记着它在整张表里的位置
        let pages = [0, 0, 1, 10].enumerated().map { index, offset in
            WebPage(url: URL(string: "https://\(index).example/")!, title: "Page \(index)", visited: day(offset))
        }
        let sections = BrowserHistoryList.sections(pages, now: now, calendar: calendar)
        #expect(sections.map(\.title).prefix(2) == ["Today", "Yesterday"])
        #expect(sections.count == 3 && sections[0].rows.map(\.index) == [0, 1] && sections[2].rows.map(\.index) == [3])
        // 搜索：标题、网址，不分大小写
        #expect(BrowserHistoryList.filter(pages, "page 2").map(\.title) == ["Page 2"])
        #expect(BrowserHistoryList.filter(pages, "3.EXAMPLE").count == 1)
        #expect(BrowserHistoryList.filter(pages, "  ").count == 4)
        // Clear History 的几种：从什么时候起
        #expect(BrowserHistoryClear.lastHour.since(now, calendar: calendar) == now.addingTimeInterval(-3600))
        #expect(BrowserHistoryClear.today.since(now, calendar: calendar) == calendar.startOfDay(for: now))
        #expect(BrowserHistoryClear.todayAndYesterday.since(now, calendar: calendar) == calendar.startOfDay(for: day(1)))
        #expect(BrowserHistoryClear.all.since(now, calendar: calendar) == nil)
        #expect(BrowserHistoryClear.allCases.map(\.title) == ["Cancel", "The Last Hour", "Today", "Today and Yesterday", "All History"])
    }

    @Test
    func rowTimesFollowTheTwentyFourHourSetting() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 7, minute: 53)))
        let evening = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 19, minute: 5)))
        // 和 Mac TV 别的钟一样：设置里关着 24-Hour Time 是 "7:53 AM"，开着是 "07:53"（不管这台 Mac 自己怎么设）
        let am = DateFormatter().amSymbol!, pm = DateFormatter().pmSymbol!
        #expect(BrowserHistoryList.time(morning, twentyFour: false, calendar: calendar) == "7:53 \(am)")
        #expect(BrowserHistoryList.time(evening, twentyFour: false, calendar: calendar) == "7:05 \(pm)")
        #expect(BrowserHistoryList.time(morning, twentyFour: true, calendar: calendar) == "07:53")
        #expect(BrowserHistoryList.time(evening, twentyFour: true, calendar: calendar) == "19:05")
    }

    @Test
    func historyOpensSearchesRemovesClearsAndGoesBack() throws {
        let (storage, cleanup) = Self.storage()
        defer { cleanup() }
        for name in ["alpha", "beta", "gamma"] { storage.addHistory(URL(string: "https://\(name).example/")!, title: name.capitalized) }
        let store = BrowserStore(storage: storage)
        store.newBlankTab()
        #expect(store.menuRows.flatMap { $0 }.contains(.history) && BrowserStore.MenuItem.history.name == "Show All History")
        // 打开：最新的在前，焦点在搜索框上
        store.openHistory()
        #expect(store.historyShown.map(\.title) == ["Gamma", "Beta", "Alpha"] && store.historyState?.focus == .search)
        // 往下到第一行，按住确认是 Remove from History，确认就删掉（焦点留在原来那个位置）
        store.handle(.move(.down))
        #expect(store.historyState?.focus == .row(0))
        #expect(store.openHistoryRowMenu())
        store.handle(.select)
        #expect(store.historyShown.map(\.title) == ["Beta", "Alpha"] && storage.history.count == 2 && store.historyState?.rowMenu == false)
        #expect(store.historyState?.focus == .row(0))
        // 搜索框：和地址栏一样打字，按标题、网址筛；返回收起键盘，筛的字留着
        store.handle(.move(.up))
        store.handle(.select)
        #expect(store.editing && !store.editingInBar)
        store.handle(.text("alp"))
        #expect(store.historyShown.map(\.title) == ["Alpha"])
        store.handle(.back)
        #expect(!store.editing && store.query == "alp")
        store.handle(.select)
        store.handle(.deleteBackward)
        store.handle(.deleteBackward)
        store.handle(.deleteBackward)
        store.handle(.back)
        #expect(store.historyShown.count == 2)
        // Clear History…：先问，焦点在 Cancel 上；Cancel 不删
        store.handle(.move(.right))
        #expect(store.historyState?.focus == .clear)
        store.handle(.select)
        #expect(store.historyState?.clearing == .cancel)
        store.handle(.select)
        #expect(store.historyState?.clearing == nil && storage.history.count == 2)
        // 再来一次，选 All History（Cancel 在最上面，往下四格）
        store.handle(.select)
        for _ in 0..<4 { store.handle(.move(.down)) }
        #expect(store.historyState?.clearing == .all)
        store.handle(.select)
        #expect(storage.history.isEmpty && store.historyShown.isEmpty && store.historyState?.focus == .clear)
        // 返回：回到开始页
        store.handle(.move(.left))
        store.handle(.back)
        #expect(store.historyState == nil && store.onStartPage)
    }
}
