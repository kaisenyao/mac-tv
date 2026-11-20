import Foundation
import Testing
@testable import MacTV

/// 哔哩哔哩的历史记录：视频和看过的直播间都要，番剧、专栏这些不要
struct BiliHistoryTests {
    @Test
    func historyKeepsVideosAndLiveRoomsOnly() throws {
        let list: [[String: Any]] = [
            ["title": "一个视频", "cover": "https://i0.hdslb.com/a.jpg", "author_name": "UP", "author_mid": 7, "duration": 300,
             "progress": 120, "history": ["business": "archive", "bvid": "BV1xx", "oid": 99, "cid": 5]],
            ["title": "正在播的直播间", "cover": "https://i0.hdslb.com/b.jpg", "author_name": "主播甲", "author_mid": 11,
             "live_status": 1, "tag_name": "单机游戏", "history": ["business": "live", "oid": 12345]],
            ["title": "下播了的直播间", "covers": ["https://i0.hdslb.com/c.jpg"], "author_name": "主播乙", "author_mid": 22,
             "live_status": 0, "history": ["business": "live", "oid": 678]],
            ["title": "一集番剧", "history": ["business": "pgc", "oid": 1, "bvid": "BV1pgc"]],
            ["title": "一篇专栏", "history": ["business": "article", "oid": 2]],
        ]
        let items = BiliAPI.historyItems(list)
        #expect(items.map(\.title) == ["一个视频", "正在播的直播间", "下播了的直播间"])
        let video = try #require(items.first)
        #expect(video.bvid == "BV1xx" && !video.isRoom && video.progress == 120)
        #expect(items[1].isLive && items[1].liveRoom == 12345 && items[1].note == "单机游戏")
        // 下播了：不能直接放，选它进主播的主页
        #expect(!items[2].isLive && items[2].endedRoom == 678 && items[2].isRoom && items[2].ownerMid == 22)
        #expect(items[2].cover?.absoluteString.contains("c.jpg") == true)
    }

    @Test
    func aStreamersRoomCountsOnlyWhileLive() throws {
        let live = try #require(BiliAPI.liveRoomInfo(["liveStatus": 1, "roomid": 7734200, "title": "决赛", "online": 411097,
                                                      "cover": "https://i0.hdslb.com/r.jpg"], mid: 50329118))
        #expect(live.isLive && live.liveRoom == 7734200 && live.ownerMid == 50329118 && live.views == 411097)
        #expect(BiliAPI.liveRoomInfo(["liveStatus": 0, "roomid": 1024, "title": "下播了"], mid: 2) == nil)
        #expect(BiliAPI.liveRoomInfo(["liveStatus": 1, "roomid": 0], mid: 2) == nil)
    }
}
