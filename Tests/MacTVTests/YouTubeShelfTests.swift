import Foundation
import Testing
@testable import MacTV

/// 主屏顶部的 YouTube：读电视版存着的登录、读电视版给的内容
struct YouTubeShelfTests {
    @Test
    func signInIsUsedOnlyWhileItIsStillValid() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func storage(expiresAt seconds: Double) -> String {
            #"{"data":{"account||account":{"accessToken":"token-abc","accessTokenServerExpiration":\#(Int(seconds * 1000))}}}"#
        }
        #expect(YouTubeSignIn.token(fromStorage: storage(expiresAt: 1_800_003_600), now: now) == "token-abc")
        // 过期了、快过期了（一分钟内）都不用：等电视版自己续期
        #expect(YouTubeSignIn.token(fromStorage: storage(expiresAt: 1_799_999_000), now: now) == nil)
        #expect(YouTubeSignIn.token(fromStorage: storage(expiresAt: 1_800_000_030), now: now) == nil)
        #expect(YouTubeSignIn.token(fromStorage: "not json", now: now) == nil)
    }

    @Test
    func feedKeepsVideosAndSkipsPlaylistsShortsAndRepeats() throws {
        func tile(_ id: String, type: String = "TILE_CONTENT_TYPE_VIDEO", style: String = "TILE_STYLE_YTLR_DEFAULT",
                  overlay: [String: Any]) -> [String: Any] {
            ["tileRenderer": [
                "contentType": type, "style": style,
                "onSelectCommand": ["watchEndpoint": ["videoId": id]],
                "metadata": ["tileMetadataRenderer": [
                    "title": ["simpleText": "Video \(id)"],
                    "lines": [["lineRenderer": ["items": [["lineItemRenderer": ["text": ["runs": [["text": "Channel \(id)"]]]]]]]],
                              ["lineRenderer": ["items": [["lineItemRenderer": ["text": ["simpleText": "1.2万次观看"]]],
                                                          ["lineItemRenderer": ["text": ["simpleText": "•"]]],
                                                          ["lineItemRenderer": ["text": ["simpleText": "3天前"]]]]]]]]],
                "header": ["tileHeaderRenderer": [
                    "thumbnail": ["thumbnails": [["url": "https://i.ytimg.com/vi/\(id)/hqdefault.jpg", "width": 320, "height": 180]]],
                    "thumbnailOverlays": [["thumbnailOverlayTimeStatusRenderer": overlay]]]]]]
        }
        let length: [String: Any] = ["text": ["simpleText": "12:34"], "style": "DEFAULT"]
        let live: [String: Any] = ["text": ["runs": [["text": "直播"]]], "style": "LIVE"]
        let json: [String: Any] = ["contents": ["sections": [
            tile("aaa", overlay: length),
            tile("bbb", overlay: live),
            tile("aaa", overlay: length),                                        // 同一个视频又出现一次
            tile("ccc", type: "TILE_CONTENT_TYPE_PLAYLIST", overlay: length),     // 合集
            tile("ddd", style: "TILE_STYLE_YTLR_SHORTS", overlay: length),       // 短视频
        ]]]
        let videos = YouTubeFeed.parse(json)
        #expect(videos.map(\.id) == ["aaa", "bbb"])
        let first = try #require(videos.first)
        #expect(first.title == "Video aaa")
        #expect(first.channel == "Channel aaa")
        #expect(first.detail == "1.2万次观看 · 3天前")
        #expect(first.length == "12:34" && !first.live)
        #expect(videos[1].live && videos[1].length == nil)
    }

    @Test
    func defaultSourceIsRecommendations() {
        let saved = UserDefaults.standard.string(forKey: "youtubeShelf")
        defer { UserDefaults.standard.set(saved, forKey: "youtubeShelf") }
        UserDefaults.standard.removeObject(forKey: "youtubeShelf")
        #expect(YouTubeShelfSource.current == .recommended)
        #expect(YouTubeShelfSource.recommended.browseID == "default")
    }
}
