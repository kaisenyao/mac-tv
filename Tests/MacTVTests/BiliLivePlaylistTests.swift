import Foundation
import Testing
@testable import MacTV

/// 直播的播放列表经我们的手：段和初始化段的地址改成绝对的；和上一份接起来留得更长；旧的不交出去
struct BiliLivePlaylistTests {
    /// 列表的地址（带着签名，段的地址按它补全时签名不带过去）
    private let base = URL(string: "https://d1--ov-gotcha207.bilivideo.com/live-bvc/123/live_1_2/index.m3u8?expires=1&sign=abc")!

    /// 和实测的一样：1 秒一段，哔哩哔哩自己的 EXT-BILI-AUX 夹在 EXTINF 前面
    private func list(from first: Int, count: Int, age: String = "", ended: Bool = false, map: String = "h100.m4s") -> String {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-START:TIME-OFFSET=0", "#EXT-X-MEDIA-SEQUENCE:\(first)",
                     "#EXT-X-TARGETDURATION:1", "#EXT-X-MAP:URI=\"\(map)\""]
        for sequence in first..<(first + count) {
            lines += ["#EXT-BILI-AUX:\(sequence)|K|1|abc", "#EXTINF:1.00,1|abc", "\(sequence).m4s"]
        }
        if ended { lines.append("#EXT-X-ENDLIST") }
        return lines.joined(separator: "\n") + "\n"
    }

    @Test
    func segmentAndMapAddressesBecomeAbsolute() throws {
        let playlist = try #require(BiliLivePlaylist.parse(list(from: 100, count: 3), base: base))
        #expect(playlist.segments.map(\.sequence) == [100, 101, 102])
        #expect(playlist.segments[0].uri == "https://d1--ov-gotcha207.bilivideo.com/live-bvc/123/live_1_2/100.m4s")
        #expect(playlist.segments[0].map == "#EXT-X-MAP:URI=\"https://d1--ov-gotcha207.bilivideo.com/live-bvc/123/live_1_2/h100.m4s\"")
        let text = playlist.text
        #expect(text.contains("#EXT-X-MEDIA-SEQUENCE:100\n"))
        #expect(!text.contains("EXT-X-START"))   // 从哪开始放由播放器定
        #expect(!text.contains("sign="))          // 签名只在列表的地址里，不带到段上
        #expect(text.components(separatedBy: "#EXT-X-MAP").count == 2)   // 初始化段只写一次，在第一段前面
        #expect(text.contains("#EXT-BILI-AUX:100|K|1|abc\n#EXTINF:1.00,1|abc\nhttps://"))
        #expect(BiliLivePlaylist.parse("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nlow.m3u8\n", base: base) == nil)
    }

    /// 接在上一份后面：滑出去的段留着（最多 keep 秒），新的段接在后面；接不上就从新的这一份开始
    @Test
    func windowGrowsAndSlides() throws {
        let first = try #require(BiliLivePlaylist.parse(list(from: 100, count: 7), base: base))
        let next = try #require(BiliLivePlaylist.parse(list(from: 103, count: 7), base: base))
        let merged = try #require(next.merged(after: first))
        #expect(merged.segments.map(\.sequence) == Array(100...109))
        #expect(merged.text.contains("#EXT-X-MEDIA-SEQUENCE:100\n"))
        // 超过 keep 秒：从最早的丢
        let capped = try #require(next.merged(after: first, keep: 8))
        #expect(capped.segments.map(\.sequence) == Array(102...109))
        // 中间断了（停太久）：上一份接不上，从这一份重新开始
        let later = try #require(BiliLivePlaylist.parse(list(from: 200, count: 7), base: base))
        #expect(later.merged(after: merged)?.segments.first?.sequence == 200)
        // 结束了：ENDLIST 照样交出去
        let ended = try #require(BiliLivePlaylist.parse(list(from: 104, count: 7, ended: true), base: base))
        #expect(ended.merged(after: merged)?.text.hasSuffix("110.m4s\n#EXT-X-ENDLIST\n") == true)
    }

    /// CDN 给了旧的：存了一秒以上（age），或者最后一段比交出去的还早。比交出去的还早的不接（不往回走）
    @Test
    func stalePlaylistIsRefused() throws {
        let handedOut = try #require(BiliLivePlaylist.parse(list(from: 100, count: 7), base: base))
        let older = try #require(BiliLivePlaylist.parse(list(from: 98, count: 7), base: base))
        let same = try #require(BiliLivePlaylist.parse(list(from: 100, count: 7), base: base))
        #expect(BiliLivePlaylist.isStale(older, age: 0, comparedTo: handedOut))
        #expect(BiliLivePlaylist.isStale(same, age: 2, comparedTo: handedOut))
        #expect(!BiliLivePlaylist.isStale(same, age: 1, comparedTo: handedOut))
        #expect(!BiliLivePlaylist.isStale(older, age: 0, comparedTo: nil))
        #expect(older.merged(after: handedOut) == nil)
        #expect(same.merged(after: handedOut)?.segments.map(\.sequence) == Array(100...106))
    }

    /// 换了初始化段（流重新开始）：新的 MAP 写在换的那一段前面
    @Test
    func mapChangesAreKept() throws {
        let first = try #require(BiliLivePlaylist.parse(list(from: 100, count: 3), base: base))
        let next = try #require(BiliLivePlaylist.parse(list(from: 103, count: 2, map: "h200.m4s"), base: base))
        let text = try #require(next.merged(after: first)).text
        #expect(text.components(separatedBy: "#EXT-X-MAP").count == 3)
        #expect(text.contains("h200.m4s\"\n#EXT-BILI-AUX:103|"))
    }

    /// 总表：每一种清晰度的列表地址换成走我们这里的，真的地址按顺序记下来
    @Test
    func masterVariantsAreRouted() throws {
        let master = "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",URI=\"audio/index.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=2000000\nhigh/index.m3u8?sign=x\n"
        let routed = try #require(BiliLivePlaylist.rewriteMaster(master, base: base))
        #expect(routed.variants.map(\.absoluteString) == ["https://d1--ov-gotcha207.bilivideo.com/live-bvc/123/live_1_2/audio/index.m3u8",
                                                          "https://d1--ov-gotcha207.bilivideo.com/live-bvc/123/live_1_2/high/index.m3u8?sign=x"])
        #expect(routed.text.contains("URI=\"bililive://live/variant-0.m3u8\""))
        #expect(routed.text.contains("\nbililive://live/variant-1.m3u8\n"))
        #expect(BiliLivePlaylist.rewriteMaster(list(from: 1, count: 1), base: base) == nil)
    }
}
