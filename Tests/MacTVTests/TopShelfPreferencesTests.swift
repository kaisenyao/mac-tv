import Foundation
import Testing
@testable import MacTV

/// 设置 › Apps › Top Shelf：每个应用一行，往里一层勾选项。存的、规则都和各应用自己设置里的"主屏幕顶部"是同一份
@Suite(.serialized) @MainActor struct TopShelfPreferencesTests {
    private static let keys = ["bilibiliShelf", "neteaseShelfSources", "neteaseShelfNowPlaying", "dedaoShelfListening",
                               "dedaoShelfNewBooks", "dedaoShelfHiddenCategories", "dedaoShelfNowPlaying", "dedaoShelfSources",
                               "youtubeShelf", "dedaoTopics"]

    /// 一个新的主屏（自己的应用列表），Top Shelf 开着；测完把改过的设置放回去
    private func withSheet(_ body: (TVController) throws -> Void) throws {
        let defaults = UserDefaults.standard
        let saved = Self.keys.map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tv = TVController(library: AppLibrary(folder: folder))
        tv.openTopShelfPreferences()
        try body(tv)
    }

    /// 用遥控器走到这个应用那一行，按确认进去
    private func open(_ tv: TVController, _ app: String) throws {
        let row = try #require(tv.topShelfApps.firstIndex { $0.id == app })
        while (tv.topShelfPreferences?.row ?? 0) > row { tv.handleTopShelfPreferences(.move(.up)) }
        while (tv.topShelfPreferences?.row ?? 0) < row { tv.handleTopShelfPreferences(.move(.down)) }
        tv.handleTopShelfPreferences(.select)
        #expect(tv.topShelfPreferences?.app == app)
    }

    /// 在那一层走到第几项，按确认
    private func press(_ tv: TVController, _ option: Int) {
        while (tv.topShelfPreferences?.option ?? 0) > option { tv.handleTopShelfPreferences(.move(.up)) }
        while (tv.topShelfPreferences?.option ?? 0) < option { tv.handleTopShelfPreferences(.move(.down)) }
        tv.handleTopShelfPreferences(.select)
    }

    private func checked(_ tv: TVController, _ app: String) -> [String] {
        tv.topShelfOptions(app).filter(\.on).map(\.title)
    }

    @Test func oneRowPerAppInHomeOrder() throws {
        try withSheet { tv in
            let home = tv.services.map(\.id).filter(AppShelf.services.contains)
            #expect(Set(tv.topShelfApps.map(\.id)) == AppShelf.services)
            #expect(Array(tv.topShelfApps.map(\.id).prefix(home.count)) == home)
            // 主屏上挪到最前面，这里也是第一行
            #expect(tv.setPinned("youtube", true))
            #expect(tv.topShelfApps.first?.id == "youtube")
            #expect(tv.topShelfApps.map(\.name).contains("网易云音乐"))
        }
    }

    @Test func sheetChangesTheSettingsEachAppReads() throws {
        try withSheet { tv in
            BiliShelfSource.current = .following
            try open(tv, BilibiliStore.appID)
            press(tv, 2)
            #expect(BiliShelfSource.current == .popular)   // 哔哩哔哩自己的设置页读的就是它
            #expect(checked(tv, BilibiliStore.appID) == ["热门"])
            tv.handleTopShelfPreferences(.back)
            #expect(tv.topShelfSummary(BilibiliStore.appID) == "热门")

            NeteaseShelfSource.selected = [.daily, .liked]
            NeteaseShelfSource.showsNowPlaying = true
            try open(tv, NeteaseStore.appID)
            press(tv, 3)   // 正在播放、每日推荐、我喜欢的音乐、最近播放……
            #expect(NeteaseShelfSource.selected == [.daily, .liked, .recent])
            press(tv, 0)
            #expect(!NeteaseShelfSource.showsNowPlaying)
            #expect(NeteaseShelfSource.summary == "每日推荐等 3 项")
            // 反过来：网易云自己的设置里勾的，这里也看得到
            tv.neteaseStore.toggleShelf(NeteaseShelfSource.hot.rawValue)
            #expect(checked(tv, NeteaseStore.appID) == ["每日推荐", "我喜欢的音乐", "最近播放", "热歌榜"])
            tv.handleTopShelfPreferences(.back)

            YouTubeShelfSource.current = .recommended
            try open(tv, "youtube")
            press(tv, 2)
            #expect(YouTubeShelfSource.current == .subscriptions)
            #expect(tv.topShelfSummary("youtube") == "Subscriptions")
        }
    }

    @Test func dedaoListsItsCategoriesAndKeepsAtLeastOne() throws {
        try withSheet { tv in
            let topics = [DedaoAPI.Topic(id: "a", name: "AI", labels: []), DedaoAPI.Topic(id: "b", name: "历史", labels: []),
                          DedaoAPI.Topic(id: "c", name: "晨间唤醒", labels: [])]   // 场景不算分类
            UserDefaults.standard.set(try JSONEncoder().encode(topics), forKey: "dedaoTopics")
            DedaoShelfSource.showsListening = true
            DedaoShelfSource.showsNewBooks = true
            DedaoShelfSource.hiddenCategories = []
            try open(tv, DedaoStore.appID)
            #expect(tv.topShelfOptions(DedaoStore.appID).map(\.title) == ["正在播放", "新书推荐", "历史", "AI"])
            press(tv, 2)
            #expect(DedaoShelfSource.hiddenCategories == ["历史"])
            press(tv, 3)   // 最后一个分类：留着
            #expect(DedaoShelfSource.hiddenCategories == ["历史"])
            #expect(tv.notices.toast == "至少选择一项")
            press(tv, 1)
            #expect(!DedaoShelfSource.showsNewBooks)
            #expect(DedaoShelfSource.summary == "正在播放")   // 得到自己的设置页读的就是它
            press(tv, 0)   // 两个都关了主屏顶部就空了：留着
            #expect(DedaoShelfSource.showsListening)
        }
    }

    @Test func neteaseKeepsAtLeastOneList() throws {
        try withSheet { tv in
            NeteaseShelfSource.selected = [.daily]
            NeteaseShelfSource.showsNowPlaying = true
            try open(tv, NeteaseStore.appID)
            press(tv, 1)
            #expect(NeteaseShelfSource.selected == [.daily])
            press(tv, 0)   // "正在播放"不算在里面，可以关
            #expect(!NeteaseShelfSource.showsNowPlaying)
        }
    }

    @Test func youTubeAndBilibiliChooseOne() throws {
        try withSheet { tv in
            YouTubeShelfSource.current = .history
            try open(tv, "youtube")
            #expect(tv.topShelfPreferences?.option == 1)   // 焦点落在选着的那一项
            for option in [0, 2, 2, 1] {
                press(tv, option)
                #expect(checked(tv, "youtube") == [YouTubeShelfSource.allCases[option].title])
            }
            tv.handleTopShelfPreferences(.back)
            try open(tv, BilibiliStore.appID)
            press(tv, 3)
            press(tv, 3)   // 再按一次不会取消
            #expect(checked(tv, BilibiliStore.appID) == ["直播"])
        }
    }

    @Test func backReturnsFocusToTheAppsRow() throws {
        try withSheet { tv in
            YouTubeShelfSource.current = .recommended
            tv.handleTopShelfPreferences(.move(.down))
            tv.handleTopShelfPreferences(.move(.down))
            let app = tv.topShelfApps[2].id
            tv.handleTopShelfPreferences(.select)
            #expect(tv.topShelfPreferences?.app == app)
            tv.handleTopShelfPreferences(.move(.down))
            // 左右在这里不动：焦点、选项都不变
            let before = tv.topShelfPreferences
            let options = tv.topShelfOptions(app)
            tv.handleTopShelfPreferences(.move(.left))
            tv.handleTopShelfPreferences(.move(.right))
            #expect(tv.topShelfPreferences == before)
            #expect(tv.topShelfOptions(app) == options)
            tv.handleTopShelfPreferences(.back)
            #expect(tv.topShelfPreferences?.app == nil)
            #expect(tv.topShelfPreferences?.row == 2)
            tv.handleTopShelfPreferences(.move(.right))
            #expect(tv.topShelfPreferences?.app == nil)
            tv.handleTopShelfPreferences(.back)
            #expect(tv.topShelfPreferences == nil)
        }
    }
}
