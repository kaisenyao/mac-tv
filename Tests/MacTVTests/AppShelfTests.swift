import Foundation
import Testing
@testable import MacTV

/// 主屏顶部的哔哩哔哩、网易云轮播，以及哔哩哔哩的直播卡片
struct AppShelfTests {
    @Test
    func publishedTimeReadsLikeBilibili() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let at = { (secondsAgo: Int) in AppShelf.ago(1_800_000_000 - secondsAgo, now: now) }
        #expect(at(20) == "刚刚")
        #expect(at(5 * 60) == "5 分钟前")
        #expect(at(3 * 3600 + 10) == "3 小时前")
        #expect(at(30 * 3600) == "昨天")
        #expect(at(4 * 86400) == "4 天前")
        #expect(AppShelf.ago(0, now: now) == nil)   // 不知道什么时候发的：不写
    }

    @Test
    func largeCoverAsksForTheFullScreenSize() {
        let card = URL(string: "https://i0.hdslb.com/bfs/archive/abc.jpg@800w_450h_1c.webp")
        #expect(BiliAPI.largeCover(card)?.absoluteString == "https://i0.hdslb.com/bfs/archive/abc.jpg@1920w_1080h_1c.webp")
        #expect(BiliAPI.largeCover(nil) == nil)
    }

    @Test
    func liveRoomsAreNotOrdinaryVideos() {
        let live = BiliVideo(bvid: "live-123", title: "直播", cover: nil, duration: 0, owner: "主播", views: 5218, liveRoom: 123)
        #expect(live.isLive)
        let video = BiliVideo(bvid: "BV1xx411c7mu", title: "视频", cover: nil, duration: 60, owner: "UP", views: 1)
        #expect(!video.isLive)
    }

    @Test
    func shelfSourcesDefaultToFollowingAndFourNeteaseKinds() {
        let defaults = UserDefaults.standard
        let savedBili = defaults.string(forKey: "bilibiliShelf"), savedNetease = defaults.stringArray(forKey: "neteaseShelfSources")
        let savedNow = defaults.object(forKey: "neteaseShelfNowPlaying")
        let savedSplit = defaults.object(forKey: "neteaseShelfSplitLists")
        defer {
            defaults.set(savedBili, forKey: "bilibiliShelf")
            defaults.set(savedNetease, forKey: "neteaseShelfSources")
            defaults.set(savedNow, forKey: "neteaseShelfNowPlaying")
            defaults.set(savedSplit, forKey: "neteaseShelfSplitLists")
        }
        defaults.removeObject(forKey: "bilibiliShelf")
        defaults.removeObject(forKey: "neteaseShelfSources")
        defaults.removeObject(forKey: "neteaseShelfNowPlaying")
        #expect(BiliShelfSource.current == .following)
        #expect(NeteaseShelfSource.selected == [.daily, .liked, .dailyLists, .playlists])
        // "正在播放"默认开着，排在最前面，也算一项
        #expect(NeteaseShelfSource.showsNowPlaying)
        #expect(NeteaseShelfSource.summary == "正在播放 等 5 项")
        // 多选：存的顺序不重要，轮播按固定的顺序来
        NeteaseShelfSource.selected = [.hot, .daily]
        #expect(NeteaseShelfSource.selected == [.daily, .hot])
        NeteaseShelfSource.selected = [.recent]
        #expect(NeteaseShelfSource.summary == "正在播放 等 2 项")
        NeteaseShelfSource.showsNowPlaying = false
        #expect(NeteaseShelfSource.summary == "最近播放")

        // 推荐歌单拆成两种以前勾过推荐歌单的：每日歌单也勾上，只做一次（之后自己取消了不再加回来）
        defaults.removeObject(forKey: "neteaseShelfSplitLists")
        NeteaseShelfSource.selected = [.playlists, .daily]
        NeteaseShelfSource.migrateSplitLists()
        #expect(NeteaseShelfSource.selected == [.daily, .dailyLists, .playlists])
        NeteaseShelfSource.selected = [.daily, .playlists]
        NeteaseShelfSource.migrateSplitLists()
        #expect(NeteaseShelfSource.selected == [.daily, .playlists])
    }

    @MainActor @Test
    func dedaoShelfIsTheBookYouAreOnPlusNewBooksFromCheckedCategories() {
        let defaults = UserDefaults.standard
        let keys = ["dedaoShelfSources", "dedaoShelfNowPlaying", "dedaoShelfListening", "dedaoShelfNewBooks", "dedaoShelfHiddenCategories"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        for key in keys { defaults.removeObject(forKey: key) }
        #expect(AppShelf.services.contains(DedaoStore.appID))
        #expect(DedaoShelfSource.showsListening && DedaoShelfSource.showsNewBooks)
        #expect(DedaoShelfSource.summary == "正在播放、新书推荐")
        #expect(DedaoShelfSource.newBookCount == 6)
        #expect(DedaoShelfSource.newBookCount + 2 <= AppShelf.limit)     // 加上正在听的书、网易云式的"正在播放"也放得下

        // 以前的两个开关：正在播放、继续学习有一个开着，"正在听的书"就开着
        defaults.set(false, forKey: "dedaoShelfNowPlaying")
        defaults.set(["newBooks"], forKey: "dedaoShelfSources")
        #expect(!DedaoShelfSource.showsListening && DedaoShelfSource.showsNewBooks)
        defaults.set(["continue"], forKey: "dedaoShelfSources")
        #expect(DedaoShelfSource.showsListening && !DedaoShelfSource.showsNewBooks)
        #expect(DedaoShelfSource.summary == "正在播放")
        defaults.set(true, forKey: "dedaoShelfNowPlaying")
        defaults.set(["recent", "hot"], forKey: "dedaoShelfSources")   // 更早的几种认不出：都开着
        #expect(DedaoShelfSource.showsListening && DedaoShelfSource.showsNewBooks)
        // 改过以后就按新存的
        DedaoShelfSource.showsListening = false
        #expect(!DedaoShelfSource.showsListening)

        // 分类：默认全勾；勾掉的按名字记（得到新加的分类默认勾着）
        let all = ["职场发展", "历史", "自然科学", "AI"]
        #expect(DedaoShelfSource.categorySummary(all) == "全部分类")
        DedaoShelfSource.hiddenCategories = ["历史"]
        #expect(DedaoShelfSource.categorySummary(all) == "3 个分类")
        #expect(DedaoShelfSource.categorySummary(all + ["新的分类"]) == "4 个分类")
    }
}
