import Foundation
import Testing
@testable import MacTV

/// 手机"发到电视"：粘贴的链接、App 分享出来的一整段文字，都要认对
@Suite(.timeLimit(.minutes(1)))
struct PhoneLinkTests {
    private func ready(_ text: String) -> PhoneLink? {
        if case .ready(let link)? = PhoneLink.read(text) { return link }
        return nil
    }

    @Test
    func bilibiliLinksAndIDs() {
        #expect(ready("https://www.bilibili.com/video/BV1AosS6yEX9/?p=2&spm_id_from=333.1007") == .bilibili(bvid: "BV1AosS6yEX9", aid: nil, page: 2))
        #expect(ready("https://m.bilibili.com/video/BV1xx411c7mu") == .bilibili(bvid: "BV1xx411c7mu", aid: nil, page: nil))
        #expect(ready("https://www.bilibili.com/video/av170001") == .bilibili(bvid: nil, aid: 170001, page: nil))
        // 只写了 BV 号 / av 号，没有网址
        #expect(ready("BV1xx411c7mu") == .bilibili(bvid: "BV1xx411c7mu", aid: nil, page: nil))
        #expect(ready("看这个 av170001") == .bilibili(bvid: nil, aid: 170001, page: nil))
        // 直播间的链接：认成直播间，交给哔哩哔哩自己的直播播放器
        #expect(ready("https://live.bilibili.com/7734200?broadcast_type=0") == .bilibiliLive(room: 7734200))
        #expect(ready("https://live.bilibili.com/") == .web(URL(string: "https://live.bilibili.com/")!))
        // App 分享出来的一整段：短链接，要先跟一下跳转
        #expect(PhoneLink.read("【老戴《侠盗猎车手 6》初见开荒全实况流程解说-哔哩哔哩】 https://b23.tv/AbCdEf1")
                == .short(URL(string: "https://b23.tv/AbCdEf1")!))
    }

    @Test
    func neteaseLinks() {
        #expect(ready("https://music.163.com/#/song?id=1974443814") == .netease(.song, id: 1974443814))
        #expect(ready("https://y.music.163.com/m/song?id=33894312&uct2=abc&app_version=9.1") == .netease(.song, id: 33894312))
        #expect(ready("https://music.163.com/playlist?id=2829883282&userid=1") == .netease(.playlist, id: 2829883282))
        #expect(ready("https://music.163.com/#/album?id=34720827") == .netease(.album, id: 34720827))
        #expect(ready("https://music.163.com/artist?id=6452") == .netease(.artist, id: 6452))
        #expect(ready("https://music.163.com/song/186016/") == .netease(.song, id: 186016))
        #expect(PhoneLink.read("分享Joe Hisaishi的单曲《Summer》: https://163cn.tv/AbCd12 (来自@网易云音乐)")
                == .short(URL(string: "https://163cn.tv/AbCd12")!))
    }

    @Test
    func youtubeLinks() {
        #expect(ready("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=10s") == .youtube(id: "dQw4w9WgXcQ"))
        #expect(ready("https://youtu.be/dQw4w9WgXcQ?si=abc") == .youtube(id: "dQw4w9WgXcQ"))
        #expect(ready("https://m.youtube.com/shorts/dQw4w9WgXcQ") == .youtube(id: "dQw4w9WgXcQ"))
        // YouTube Music 不是视频，当普通网页
        if case .web? = ready("https://music.youtube.com/watch?v=dQw4w9WgXcQ") {} else { Issue.record("YouTube Music 应该当网页") }
    }

    @Test
    func otherPagesAndNonsense() {
        #expect(ready("https://example.com/page?x=1") == .web(URL(string: "https://example.com/page?x=1")!))
        #expect(ready("随便写的几个字") == nil)
        #expect(ready("") == nil)
        #expect(PhoneLink.bilibili(bvid: "BV1xx411c7mu", aid: nil, page: nil).title == "Bilibili video")
        #expect(PhoneLink.netease(.playlist, id: 1).title == "NetEase Cloud Music playlist")
    }
}
