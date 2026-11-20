import Foundation
import Testing
@testable import MacTV

@Suite(.timeLimit(.minutes(1)))
struct BilibiliPanelTests {
    /// 字幕：每一刻找到正在说的那一句；两句之间的空当不显示；最后一句之后也不显示
    @Test
    func subtitleLineFollowsTime() {
        let cues = [BiliSubtitleCue(from: 1, to: 2.5, text: "第一句"),
                    BiliSubtitleCue(from: 3, to: 4, text: "第二句"),
                    BiliSubtitleCue(from: 4, to: 6, text: "第三句")]
        #expect(BiliSubtitleCue.line(at: 0.5, in: cues) == nil)
        #expect(BiliSubtitleCue.line(at: 1, in: cues) == "第一句")
        #expect(BiliSubtitleCue.line(at: 2.7, in: cues) == nil)
        #expect(BiliSubtitleCue.line(at: 3.99, in: cues) == "第二句")
        #expect(BiliSubtitleCue.line(at: 4, in: cues) == "第三句")   // 首尾相接时换到下一句
        #expect(BiliSubtitleCue.line(at: 7, in: cues) == nil)
        #expect(BiliSubtitleCue.line(at: 1, in: []) == nil)
    }

    /// 弹幕 XML：按时间排好；飘的、顶上的、底下的分开；大小、颜色、转义字符都读对；高级弹幕不要
    @Test
    func danmakuParsesTheXML() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?><i><chatserver>chat.bilibili.com</chatserver>
        <d p="12.5,1,25,16777215,1700000000,0,abc,1,10">第二条</d>
        <d p="3.0,5,36,16711680,1700000000,0,abc,2,10">顶上 &amp; 红色</d>
        <d p="4.0,4,18,65280,1700000000,0,abc,3,10">底下</d>
        <d p="5.0,7,25,16777215,1700000000,0,abc,4,10">[高级弹幕]</d>
        <d p="1.0,1,25,16777215,1700000000,0,abc,5,10">第一条</d>
        </i>
        """
        let items = BiliDanmaku.parse(xml)
        #expect(items.map(\.text) == ["第一条", "顶上 & 红色", "底下", "第二条"])
        #expect(items.map(\.kind) == [.scroll, .top, .bottom, .scroll])
        #expect(items[1].color == 0xFF0000 && items[1].size > 1)
        #expect(items[2].size < 1)
    }

    /// 排行：同一时刻来的几条各占一行，不叠在一起；前一条完全进屏幕以后，同一行才能放下一条；
    /// 一行都放不下就不显示
    @Test
    func danmakuLanesNeverOverlap() {
        let layout = BiliDanmakuLayout(style: BiliDanmakuStyle())
        let burst: [BiliDanmaku] = (0..<(layout.lanes + 3)).map { _ in BiliDanmaku(time: 10, kind: .scroll, size: 1, color: 0xFFFFFF, text: "一样的弹幕") }
        let placed = layout.place(burst)
        #expect(placed.count == layout.lanes)
        #expect(Set(placed.map(\.lane)).count == layout.lanes)
        // 一秒半后再来一条短的：第一行的那条已经完全进来了，放回第一行
        let later = layout.place(Array(burst.prefix(1)) + [BiliDanmaku(time: 11.5, kind: .scroll, size: 1, color: 0xFFFFFF, text: "短")])
        #expect(later.map(\.lane) == [0, 0])
        // 屏幕上的：按时间找出这一刻在飘的
        #expect(layout.visible(placed, at: 9).isEmpty)
        #expect(layout.visible(placed, at: 12).count == layout.lanes)
        #expect(layout.visible(placed, at: 10 + layout.scrollDuration + 0.1).isEmpty)
    }

    /// 弹幕设置：显示区域越大行越多，1/4 时只在屏幕上面四分之一里；速度、字号跟着变；
    /// 关掉固定弹幕、彩色弹幕时，那些弹幕不显示
    @Test
    func danmakuStyleShapesTheLayout() {
        var style = BiliDanmakuStyle()
        #expect(style.area == .quarter)
        let quarter = BiliDanmakuLayout(style: style)
        #expect(BiliDanmakuLayout.topInset + Double(quarter.lanes) * quarter.laneHeight <= BiliDanmakuLayout.screenHeight / 4)
        #expect(quarter.lanes >= 4)
        style.area = .half
        let half = BiliDanmakuLayout(style: style)
        #expect(half.lanes > quarter.lanes)
        style.area = .full
        #expect(BiliDanmakuLayout(style: style).lanes > half.lanes)
        style.speed = .fast
        #expect(BiliDanmakuLayout(style: style).scrollDuration < quarter.scrollDuration)
        style.size = .large
        #expect(BiliDanmakuLayout(style: style).fontSize > quarter.fontSize)

        let white = BiliDanmaku(time: 1, kind: .scroll, size: 1, color: 0xFFFFFF, text: "白")
        let red = BiliDanmaku(time: 1, kind: .scroll, size: 1, color: 0xFF0000, text: "红")
        let top = BiliDanmaku(time: 1, kind: .top, size: 1, color: 0xFFFFFF, text: "顶")
        var filter = BiliDanmakuStyle()
        #expect([white, red, top].filter(filter.keeps).count == 3)
        filter.fixed = false
        #expect([white, red, top].filter(filter.keeps) == [white, red])
        filter.colored = false
        #expect([white, red, top].filter(filter.keeps) == [white])
    }

    /// 选集：分 P 是同一个视频的几段（按段编号区分），合集是几个不同的视频；只有一集时没有选集；
    /// 两样都有时按分 P 来
    @Test
    func episodesComeFromPagesOrSeason() {
        let owner = BiliUser(mid: 7, name: "UP")
        let image: (Any?) -> URL? = { ($0 as? String).flatMap(URL.init(string:)) }
        let parts: [String: Any] = ["bvid": "BV1", "aid": 11, "title": "全流程",
                                    "pages": [["cid": 101, "page": 1, "part": "开荒", "duration": 600],
                                              ["cid": 102, "page": 2, "part": "第二章", "duration": 700]]]
        let list = BiliEpisode.list(from: parts, cover: nil, owner: owner, image: image)
        #expect(list.map(\.label) == ["P1", "P2"])
        #expect(list.map(\.title) == ["开荒", "第二章"])
        #expect(list.allSatisfy { $0.video.bvid == "BV1" && $0.video.title == "全流程" })
        // 正在放第二段：只认第二段；不知道哪段时（列表没给）算第一段
        let second = BiliVideo(bvid: "BV1", title: "全流程", cover: nil, duration: 700, owner: "UP", views: 0, cid: 102)
        let unknown = BiliVideo(bvid: "BV1", title: "全流程", cover: nil, duration: 600, owner: "UP", views: 0)
        #expect(list.firstIndex { $0.matches(second) } == 1)
        #expect(list.firstIndex { $0.matches(unknown) } == 0)

        let season: [String: Any] = ["bvid": "BV2", "aid": 22, "title": "第二期", "pages": [["cid": 201, "page": 1]],
                                     "ugc_season": ["sections": [["episodes": [
                                         ["bvid": "BV1", "aid": 21, "cid": 200, "title": "第一期", "arc": ["duration": 300, "pic": "https://a/1.jpg"]],
                                         ["bvid": "BV2", "aid": 22, "cid": 201, "title": "第二期", "arc": ["duration": 320]]]]]]]
        let episodes = BiliEpisode.list(from: season, cover: nil, owner: owner, image: image)
        #expect(episodes.map(\.label) == ["第 1 集", "第 2 集"])
        #expect(episodes.map(\.video.bvid) == ["BV1", "BV2"])
        #expect(episodes[0].video.cover?.absoluteString == "https://a/1.jpg")
        #expect(BiliEpisode.list(from: ["bvid": "BV3", "pages": [["cid": 1, "page": 1]]], cover: nil, owner: owner, image: image).isEmpty)
    }

    /// 倍速：和哔哩哔哩网页上一样的几档，写法一样
    @Test @MainActor
    func speedsMatchTheWebsite() {
        #expect(BilibiliNativePlayer.speeds == [2.0, 1.5, 1.25, 1.0, 0.75, 0.5])
        #expect(BilibiliNativePlayer.speeds.map { BilibiliNativePlayer.speedName($0) } == ["2×", "1.5×", "1.25×", "1×", "0.75×", "0.5×"])
    }

    /// 自动打开字幕时：UP 主上传的中文优先，其次自动生成的中文，都没有就第一条
    @Test @MainActor
    func preferredSubtitleIsChinese() {
        let url = URL(string: "https://example.com/a.json")!
        let ai = BiliSubtitleTrack(language: "ai-zh", name: "中文（自动生成）", url: url)
        let human = BiliSubtitleTrack(language: "zh-CN", name: "中文（中国）", url: url)
        let english = BiliSubtitleTrack(language: "en-US", name: "English", url: url)
        #expect(BilibiliNativePlayer.preferredTrack([english, ai, human]) == human)
        #expect(BilibiliNativePlayer.preferredTrack([english, ai]) == ai)
        #expect(BilibiliNativePlayer.preferredTrack([english]) == english)
        #expect(BilibiliNativePlayer.preferredTrack([]) == nil)
    }
}
