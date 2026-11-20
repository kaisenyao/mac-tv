import Foundation
import Testing
@testable import MacTV

/// 哔哩哔哩的登录：没登录和问不到要分开；只认哔哩哔哩自己的 cookie
@Suite(.timeLimit(.minutes(1)))
struct BilibiliLoginTests {
    /// 哔哩哔哩明说没登录（-101、isLogin 是 false）才算没登录；看不懂的回答（接口出错、被风控）不能当成没登录
    @Test
    func loginAnswerTellsSignedOutFromUnknown() {
        let signedIn = BiliAPI.login(from: ["code": 0, "data": ["isLogin": true, "uname": "我", "mid": 42, "face": "//i0.hdslb.com/f.jpg"]])
        #expect(signedIn == .signedIn(BiliAccount(name: "我", mid: 42, face: URL(string: "https://i0.hdslb.com/f.jpg@120w_120h_1c.webp"))))
        #expect(BiliAPI.login(from: ["code": -101, "message": "账号未登录", "data": ["isLogin": false]]) == .signedOut)
        #expect(BiliAPI.login(from: ["code": 0, "data": ["isLogin": false]]) == .signedOut)
        #expect(BiliAPI.login(from: ["code": -412, "message": "请求被拦截"]) == .unknown)
        #expect(BiliAPI.login(from: [:]) == .unknown)
    }

    /// cookie 只认 bilibili.com 和它的子域名：名字里带着 bilibili.com 的别的站不算（登录信息不能带到别处去）
    @Test
    func onlyBilibiliCookiesCount() throws {
        func cookie(_ domain: String) throws -> HTTPCookie {
            try #require(HTTPCookie(properties: [.domain: domain, .path: "/", .name: "SESSDATA", .value: "x"]))
        }
        #expect(try cookie(".bilibili.com").isBilibili)
        #expect(try cookie("bilibili.com").isBilibili)
        #expect(try cookie("passport.bilibili.com").isBilibili)
        #expect(try !cookie("notbilibili.com").isBilibili)
        #expect(try !cookie(".bilibili.com.example.org").isBilibili)
    }

    /// 同一张图换尺寸：换掉 "@" 后面的那一段；没有 "@" 的原样
    @Test
    func imagesResize() {
        let card = URL(string: "https://i0.hdslb.com/bfs/archive/a.jpg@800w_450h_1c.webp")
        #expect(BiliAPI.resized(card, to: "160w_90h_1c")?.absoluteString == "https://i0.hdslb.com/bfs/archive/a.jpg@160w_90h_1c.webp")
        let plain = URL(string: "https://i0.hdslb.com/bfs/archive/a.jpg")
        #expect(BiliAPI.resized(plain, to: "160w_90h_1c") == plain)
    }

    /// 焦点同一时刻只在一处：从卡片往左是左边栏，Esc 回来；往上是头像，确认打开菜单，返回回到头像，往下回到卡片。
    /// 焦点不在卡片上时没有"选中的卡片"（长按确认不会弹出卡片菜单、不会提前准备视频）。
    /// （有登录过的账号才有菜单；一个都没有时选头像直接打开登录页，见 BilibiliLoginPageTests）
    @Test @MainActor
    func focusMovesBetweenAreas() {
        let store = BilibiliStore()
        store.pretendSavedAccounts([BiliSavedAccount(mid: 1, name: "甲")])
        #expect(store.focus == .rows && store.module(horizontal: true) == .strip)
        store.handle(.move(.left))
        #expect(store.focus == .sidebar && store.module(horizontal: true) == .drawer && store.module(horizontal: false) == .picker)
        store.handle(.back)
        #expect(store.focus == .rows)
        store.handle(.move(.up))
        #expect(store.focus == .account && store.focused == nil)
        store.handle(.select)
        #expect(store.accountMenuOpen && store.accountFocused && store.module(horizontal: false) == .picker)
        store.handle(.back)
        #expect(store.focus == .account && !store.accountMenuOpen)
        store.handle(.move(.down))
        #expect(store.focus == .rows)
        #expect(!store.openCardMenu())   // 没有视频卡片：没有菜单
    }
}
