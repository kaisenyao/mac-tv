import Foundation
import Testing
@testable import MacTV

/// 哔哩哔哩"看到哪了"：每一 P 各记各的；合集记得上次看的是哪一集，看完了接下一集
@Suite(.serialized)
struct BiliResumeTests {
    private func clean() {
        for key in ["bilibiliResumePositions", "bilibiliResumeSeasons", "bilibiliResumeSeasonOrder", "bilibiliResumeLastEpisode",
                    "bilibiliResumeEpisodes"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func video(_ bvid: String, cid: Int) -> BiliVideo {
        BiliVideo(bvid: bvid, title: "第 \(bvid) 集", cover: nil, duration: 600, owner: "UP", views: 0, cid: cid, aid: cid)
    }

    @Test
    func everyPartKeepsItsOwnPlace() {
        clean(); defer { clean() }
        BiliResume.save(bvid: "BV1", cid: 11, seconds: 120)
        BiliResume.save(bvid: "BV1", cid: 12, seconds: 300)
        #expect(BiliResume.position(bvid: "BV1", cid: 11) == 120)
        #expect(BiliResume.position(bvid: "BV1", cid: 12) == 300)
        #expect(BiliResume.position(bvid: "BV1", cid: 13) == nil)
        BiliResume.save(bvid: "BV1", cid: 11, seconds: -1)   // 看完了
        #expect(BiliResume.position(bvid: "BV1", cid: 11) == -1)
    }

    @Test
    func aCollectionContinuesTheLastEpisodeOrTheNextOne() throws {
        clean(); defer { clean() }
        let season = [video("A", cid: 1), video("B", cid: 2), video("C", cid: 3)]
        // 看到第二集一半
        BiliResume.noteSeason(season, watching: season[1])
        BiliResume.save(bvid: "B", cid: 2, seconds: 200)
        // 从第一集（收藏里的那张卡片）进来：接着看第二集
        #expect(BiliResume.continueEpisode(for: "A")?.bvid == "B")
        // 点的就是第二集：不用换
        #expect(BiliResume.continueEpisode(for: "B") == nil)
        // 第二集看完了：接着看第三集
        BiliResume.save(bvid: "B", cid: 2, seconds: -1)
        #expect(BiliResume.continueEpisode(for: "A")?.bvid == "C")
        // 不在任何合集里的视频：没有要接着看的
        #expect(BiliResume.continueEpisode(for: "X") == nil)
        // 分 P（同一个视频）不算合集
        BiliResume.noteSeason([video("P", cid: 1), video("P", cid: 2)], watching: video("P", cid: 2))
        #expect(BiliResume.continueEpisode(for: "P") == nil)
    }

    /// 合集只记最近看过的那些：记满了再来一个，丢掉的是最久没看的那个（又看了一次的算最近看的）
    @Test
    func collectionsAreTrimmedByRecency() {
        clean(); defer { clean() }
        func season(_ number: Int) -> [BiliVideo] { [video("S\(number)a", cid: number * 10 + 1), video("S\(number)b", cid: number * 10 + 2)] }
        for number in 0..<BiliResume.seasonLimit { BiliResume.noteSeason(season(number), watching: season(number)[1]) }
        BiliResume.noteSeason(season(0), watching: season(0)[1])       // 最早的那个又看了一次
        BiliResume.noteSeason(season(999), watching: season(999)[1])   // 记满了，再来一个
        #expect(BiliResume.continueEpisode(for: "S0a")?.bvid == "S0b")
        #expect(BiliResume.continueEpisode(for: "S1a") == nil)          // 最久没看的：丢掉了
        #expect(BiliResume.continueEpisode(for: "S2a")?.bvid == "S2b")
        #expect(BiliResume.continueEpisode(for: "S999a")?.bvid == "S999b")
    }
}
