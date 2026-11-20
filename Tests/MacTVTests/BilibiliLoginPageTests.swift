import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import MacTV

/// 假的扫码登录接口：按顺序给出这几个回答，不联网、不登录真的账号
private actor FakeQR: BiliQRService {
    private var answers: [BiliQRPoll]
    private let fails: Bool
    private(set) var generated = 0
    private(set) var polls = 0

    init(_ answers: [BiliQRPoll] = [], fails: Bool = false) {
        self.answers = answers
        self.fails = fails
    }

    func generate() async -> BiliQRCode? {
        generated += 1
        return fails ? nil : BiliQRCode(url: "https://account.bilibili.com/h5/account-h5/auth/scan-web?qrcode_key=k\(generated)", key: "k\(generated)")
    }

    func poll(_ key: String) async -> BiliQRPoll {
        polls += 1
        return answers.isEmpty ? .waiting : answers.removeFirst()
    }
}

/// 一个假的登录信息（值是随便写的，不是真的）
private func cookie(_ name: String, domain: String = ".bilibili.com") -> HTTPCookie {
    HTTPCookie(properties: [.domain: domain, .path: "/", .name: name, .value: "test-\(name)", .expires: Date().addingTimeInterval(3600)])!
}

@MainActor
private func waitUntil(_ timeout: Duration = .seconds(3), _ condition: @MainActor () async -> Bool) async -> Bool {
    let clock = ContinuousClock(), end = clock.now + timeout
    while await !condition() {
        if clock.now > end { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct BilibiliLoginPageTests {
    // MARK: 头像

    /// 没登录、也没有登录过的账号：选"未登录"直接打开登录页，不先出一个只有"扫码登录"的菜单；返回回到头像上
    @Test
    func pillOpensLoginWhenNothingSaved() {
        let store = BilibiliStore()
        store.qrService = FakeQR()
        store.pretendSavedAccounts([])
        store.handle(.move(.up))
        #expect(store.focus == .account)
        store.handle(.select)
        #expect(store.login != nil && !store.accountMenuOpen)
        #expect(store.module(horizontal: true) == .picker && store.module(horizontal: false) == .picker)
        store.handle(.back)
        #expect(store.login == nil && store.focus == .account)
        // 触控板点头像也一样
        store.tapAccount()
        #expect(store.login != nil && !store.accountMenuOpen)
        store.closeLogin()
    }

    /// 有登录过的账号：选头像出菜单，上面是这几个账号（点一下换过去），下面一项"登录其他账号"
    @Test
    func pillShowsSavedAccountsAndSignInRow() {
        let store = BilibiliStore()
        store.qrService = FakeQR()
        store.pretendSavedAccounts([BiliSavedAccount(mid: 1, name: "甲"), BiliSavedAccount(mid: 2, name: "乙")])
        store.handle(.move(.up))
        store.handle(.select)
        #expect(store.accountMenuOpen && store.login == nil)
        #expect(store.accountActions == [.useAccount(1), .useAccount(2), .login])
        #expect(store.accountIndex == 0)   // 停在第一个账号上
        store.handle(.back)
        #expect(store.focus == .account && !store.accountMenuOpen)
    }

    // MARK: 扫码登录

    /// 等着扫 → 扫了 → 手机上确认：登录信息原样交出去，之后不再问
    @Test
    func qrGoesFromWaitingToScannedToSignedIn() async {
        let fake = FakeQR([.waiting, .scanned, .scanned, .signedIn([cookie("SESSDATA"), cookie("bili_jct"), cookie("DedeUserID")])])
        let qr = BiliQRLogin(service: fake, interval: .milliseconds(5))
        var seen: [BiliQRLogin.State] = []
        let watch = qr.$state.sink { if seen.last != $0 { seen.append($0) } }
        var received: [String] = []
        qr.signedIn = { cookies in received = cookies.map(\.name) }
        qr.start()
        #expect(await waitUntil { qr.state == .done && !received.isEmpty })
        let link = "https://account.bilibili.com/h5/account-h5/auth/scan-web?qrcode_key=k1"
        #expect(seen == [.loading, .waiting(link), .scanned(link), .done])
        #expect(received == ["SESSDATA", "bili_jct", "DedeUserID"])
        #expect(qr.matrix != nil && !qr.running)
        let polls = await fake.polls
        try? await Task.sleep(for: .milliseconds(40))
        #expect(await fake.polls == polls)
        watch.cancel()
    }

    /// 过期了：停下不再问，写"二维码已失效"；按确认取一张新的接着问
    @Test
    func qrExpiresStopsAndRefreshes() async {
        let fake = FakeQR([.waiting, .expired])
        let qr = BiliQRLogin(service: fake, interval: .milliseconds(5))
        qr.start()
        #expect(await waitUntil { qr.state == .expired })
        #expect(!qr.running)
        let polls = await fake.polls
        try? await Task.sleep(for: .milliseconds(40))
        #expect(await fake.polls == polls)
        qr.refresh()
        #expect(await waitUntil { if case .waiting(let link) = qr.state { link.hasSuffix("k2") } else { false } })
        #expect(await fake.generated == 2)
        qr.stop()
    }

    /// 哔哩哔哩一直不说过期，到了二维码的有效期也当过期，不一直问下去
    @Test
    func qrExpiresAfterItsLifetime() async {
        let qr = BiliQRLogin(service: FakeQR(), interval: .milliseconds(5), lifetime: .milliseconds(40))
        qr.start()
        #expect(await waitUntil { qr.state == .expired })
    }

    /// 页面关了（stop）就不再问；取不到二维码写"无法获取"，按确认重试
    @Test
    func qrStopsWhenClosedAndRetriesWhenFailed() async {
        let fake = FakeQR()
        let qr = BiliQRLogin(service: fake, interval: .milliseconds(5))
        qr.start()
        #expect(await waitUntil { await fake.polls >= 2 })
        qr.stop()
        try? await Task.sleep(for: .milliseconds(20))
        let polls = await fake.polls
        try? await Task.sleep(for: .milliseconds(40))
        #expect(await fake.polls == polls)
        #expect(!qr.running)

        let failing = FakeQR(fails: true)
        let broken = BiliQRLogin(service: failing, interval: .milliseconds(5))
        broken.start()
        #expect(await waitUntil { broken.state == .failed })
        broken.refresh()
        #expect(await waitUntil { await failing.generated == 2 })
        broken.stop()
    }

    /// 在登录页上扫码登录成功：登录页关掉（和在网页里登录成功走同一条路）
    @Test
    func signingInByQRClosesThePage() async {
        let store = BilibiliStore()
        store.qrService = FakeQR([.scanned, .signedIn([cookie("SESSDATA")])])
        store.pretendSavedAccounts([])
        store.handle(.move(.up))
        store.handle(.select)
        #expect(store.login != nil)
        // 真的接口两秒问一次：这里不等，直接看它最后把登录页关掉
        #expect(await waitUntil(.seconds(8)) { store.login == nil })
    }

    // MARK: 登录信息

    /// 哔哩哔哩回答里的 Set-Cookie 原样收下（只要哔哩哔哩自己的）；几种状态码各是什么
    @Test
    func pollAnswersAndCookies() throws {
        let url = try #require(URL(string: "https://passport.bilibili.com/x/passport-login/web/qrcode/poll?qrcode_key=k"))
        let headers = ["Set-Cookie": "SESSDATA=abc%2C123%2Cxyz; Path=/; Domain=bilibili.com; Expires=Wed, 01 Jan 2031 00:00:00 GMT; HttpOnly; Secure, "
                       + "bili_jct=def; Path=/; Domain=bilibili.com, DedeUserID=42; Path=/; Domain=bilibili.com"]
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
        func answer(_ code: Int, url: String = "") -> [String: Any] {
            ["code": 0, "data": ["code": code, "url": url, "refresh_token": "", "timestamp": 0, "message": ""]]
        }
        guard case .signedIn(let found) = BiliQRWeb.poll(from: answer(0), cookies: cookies) else { Issue.record("没认出登录成功"); return }
        #expect(Set(found.map(\.name)) == ["SESSDATA", "bili_jct", "DedeUserID"])
        #expect(found.allSatisfy { $0.isBilibili && $0.domain.hasSuffix("bilibili.com") })
        #expect(found.first { $0.name == "SESSDATA" }?.value == "abc%2C123%2Cxyz")   // 值保持原样，和网页版存的一样

        #expect(BiliQRWeb.poll(from: answer(86101), cookies: []) == .waiting)
        #expect(BiliQRWeb.poll(from: answer(86090), cookies: []) == .scanned)
        #expect(BiliQRWeb.poll(from: answer(86038), cookies: []) == .expired)
        #expect(BiliQRWeb.poll(from: answer(0), cookies: []) == .unknown)   // 说成功了却没有登录信息：不算
        #expect(BiliQRWeb.poll(from: ["code": -412, "message": "请求被拦截"], cookies: []) == .unknown)
        #expect(BiliQRWeb.code(from: ["code": 0, "data": ["url": "https://account.bilibili.com/x", "qrcode_key": "k"]])
                == BiliQRCode(url: "https://account.bilibili.com/x", key: "k"))
        #expect(BiliQRWeb.code(from: ["code": -1]) == nil)
    }

    /// 回答里万一没有 Set-Cookie：从网页版接着要去的地址里取，做成和网页版一样的 .bilibili.com 的 cookie
    @Test
    func cookiesFromTheRedirectAddress() {
        let address = "https://passport.biligame.com/x/passport-login/web/crossDomain?DedeUserID=42&DedeUserID__ckMd5=ab&Expires=1900000000"
            + "&SESSDATA=abc%2C1900000000%2Cxyz&bili_jct=def&gourl=https%3A%2F%2Fwww.bilibili.com"
        let answer: [String: Any] = ["code": 0, "data": ["code": 0, "url": address]]
        guard case .signedIn(let found) = BiliQRWeb.poll(from: answer, cookies: []) else { Issue.record("没认出登录成功"); return }
        #expect(Set(found.map(\.name)) == ["DedeUserID", "DedeUserID__ckMd5", "SESSDATA", "bili_jct"])
        #expect(found.allSatisfy { $0.domain == ".bilibili.com" && $0.path == "/" && $0.isBilibili })
        #expect(found.first { $0.name == "SESSDATA" }?.value == "abc%2C1900000000%2Cxyz")
        // 过期时间照地址里写的（系统最多让 cookie 活 400 天，远的会被截到 400 天）
        #expect((found.first { $0.name == "SESSDATA" }?.expiresDate ?? .distantPast) > Date().addingTimeInterval(300 * 24 * 3600))
    }

    /// 扫码登录的登录信息存进网页数据的 cookie 仓库（和网页里登录存的同一个地方）：
    /// 名字、域名不变，读出来拼成的请求头里有它们；不是哔哩哔哩的不存
    @Test
    func cookiesAreSavedInTheWebsiteDataStore() async {
        let store = WKWebsiteDataStore.nonPersistent()
        await BiliQRLogin.save([cookie("SESSDATA"), cookie("bili_jct"), cookie("DedeUserID"), cookie("other", domain: ".example.com")],
                               in: store.httpCookieStore)
        let saved = await store.httpCookieStore.allCookies()
        let bilibili = saved.filter(\.isBilibili)
        #expect(Set(bilibili.map(\.name)) == ["SESSDATA", "bili_jct", "DedeUserID"])
        #expect(bilibili.allSatisfy { $0.domain == ".bilibili.com" })
        #expect(!saved.contains { $0.name == "other" })
        #expect(bilibili.first { $0.name == "SESSDATA" }?.value == "test-SESSDATA")
    }

    // MARK: 二维码

    /// CoreImage 生成的点阵：三个定位角在左上、右上、左下（方向对），没有多余的空白边
    @Test
    func qrMatrixIsUpright() throws {
        let matrix = try #require(BiliQRMatrix("https://account.bilibili.com/h5/account-h5/auth/scan-web?navhide=1&callback=close&qrcode_key=0123456789abcdef0123456789abcdef&from="))
        #expect(matrix.size >= 21 && (matrix.size - 21) % 4 == 0)
        #expect(BiliQRMatrix.finder(in: matrix.dark, size: matrix.size, x: 0, y: 0))
        #expect(BiliQRMatrix.finder(in: matrix.dark, size: matrix.size, x: matrix.size - 7, y: 0))
        #expect(BiliQRMatrix.finder(in: matrix.dark, size: matrix.size, x: 0, y: matrix.size - 7))
        #expect(!BiliQRMatrix.finder(in: matrix.dark, size: matrix.size, x: matrix.size - 7, y: matrix.size - 7))
        #expect(!BiliQRShape(matrix: matrix).path(in: CGRect(x: 0, y: 0, width: 400, height: 400)).isEmpty)
    }

    // MARK: 方向键

    /// 表单里的样子（位置照哔哩哔哩的密码登录页）：两个标签、账号、密码和"忘记密码"、两个按钮、五个第三方
    private static let form: [BiliLoginPage.Item] = {
        var items: [BiliLoginPage.Item] = [
            .init(frame: CGRect(x: 109, y: 5, width: 72, height: 28), input: false),    // 0 密码登录
            .init(frame: CGRect(x: 221, y: 5, width: 72, height: 28), input: false),    // 1 短信登录
            .init(frame: CGRect(x: 68, y: 57, width: 312, height: 20), input: true),    // 2 账号
            .init(frame: CGRect(x: 68, y: 101, width: 200, height: 20), input: true),   // 3 密码
            .init(frame: CGRect(x: 320, y: 101, width: 64, height: 20), input: false),  // 4 忘记密码
            .init(frame: CGRect(x: 0, y: 142, width: 196, height: 46), input: false),   // 5 注册
            .init(frame: CGRect(x: 206, y: 142, width: 196, height: 46), input: false), // 6 登录
        ]
        for column in 0..<5 {                                                            // 7…11 第三方
            items.append(.init(frame: CGRect(x: 21 + CGFloat(column) * 74, y: 248, width: 72, height: 58), input: false))
        }
        return items
    }()

    @Test
    func formNavigationFollowsTheLayout() {
        let form = Self.form
        func next(_ from: Int, _ direction: RemoteCommand.Direction) -> Int? { BiliLoginPage.next(from: from, in: form, toward: direction) }
        #expect(next(0, .right) == 1 && next(1, .left) == 0)
        #expect(next(0, .left) == nil && next(0, .up) == nil)          // 最左边再往左：回二维码；最上面不动
        #expect(next(0, .down) == 2 && next(2, .down) == 3 && next(3, .down) == 5)
        #expect(next(2, .left) == nil && next(3, .left) == nil)        // 输入框是一行最左边的
        #expect(next(3, .right) == 4 && next(4, .down) == 6 && next(4, .left) == 3)
        #expect(next(5, .right) == 6 && next(6, .left) == 5 && next(5, .left) == nil)
        #expect(next(5, .down) == 8 && next(6, .down) == 10)          // 往下到正下方的那个第三方
        #expect(next(7, .right) == 8 && next(11, .right) == nil && next(9, .up) == 6)
        #expect(next(3, .up) == 2 && next(2, .up) == 1)                // 账号往上：离得最近的那个标签
        #expect(next(7, .left) == nil)                                  // 第三方最左边一个再往左：回二维码
    }

    /// 在二维码上按右进表单，停在第一个输入框（账号）；走到最左边再按左回二维码；再进来回到刚才那一个。
    /// 每走一格 focusKey 都变（有按键声），走不动时不变
    @Test
    func focusMovesBetweenQRAndForm() {
        let page = BiliLoginPage(qr: BiliQRLogin(service: FakeQR()), dataStore: nil)
        var closed = false
        page.close = { closed = true }
        page.pretendForm(Self.form)
        #expect(page.side == .qr)
        let start = page.focusKey
        page.handle(.move(.up))
        #expect(page.focusKey == start)
        page.handle(.move(.right))
        #expect(page.side == .form && page.index == 2 && page.focusKey != start)
        page.handle(.move(.down))
        #expect(page.index == 3)
        page.handle(.move(.right))
        #expect(page.index == 4)
        let atForgot = page.focusKey
        page.handle(.move(.right))
        #expect(page.index == 4 && page.focusKey == atForgot)
        page.handle(.move(.left))
        page.handle(.move(.left))
        #expect(page.side == .qr)
        page.handle(.move(.right))
        #expect(page.side == .form && page.index == 3)
        #expect(page.canMove(.down) && !page.canMove(.left))
        page.handle(.move(.left))
        page.handle(.back)
        #expect(closed)
    }

    /// 截图：MACTV_RENDER_BILI_LOGIN=<文件夹> 时把登录页画成 1920×1080 的三张图（二维码选中、表单选中、二维码过期）。
    /// 右边载的是哔哩哔哩真的登录页（不登录，用不落盘的网页数据）；左边的二维码是假的地址。平时跳过
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACTV_RENDER_BILI_LOGIN"] != nil))
    func renderLoginPage() async throws {
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MACTV_RENDER_BILI_LOGIN"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let page = BiliLoginPage(qr: BiliQRLogin(service: FakeQR(), interval: .seconds(60)), dataStore: .nonPersistent())
        page.open()
        let size = NSSize(width: 1920, height: 1080)
        let host = NSHostingView(rootView: BilibiliLoginScreen(page: page).environment(\.colorScheme, .dark).frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFrontRegardless()
        defer { page.shutdown(); window.close() }
        #expect(await waitUntil(.seconds(30)) { page.formReady && !page.items.isEmpty })
        try await Task.sleep(for: .milliseconds(800))

        func capture(_ name: String) async throws {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(600))
            let native = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: native)
            let web = try #require(page.web)
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = true
            let snapshot = try await web.takeSnapshot(configuration: configuration)
            let rect = BiliLoginLayout(canvas: CGSize(width: size.width, height: size.height)).web
            let image = NSImage(size: size)
            image.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .high
            native.draw(in: NSRect(origin: .zero, size: size))
            snapshot.draw(in: NSRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height))
            image.unlockFocus()
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            image.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
        }

        page.qr.pretend(.waiting("https://account.bilibili.com/h5/account-h5/auth/scan-web?navhide=1&callback=close&qrcode_key=0123456789abcdef0123456789abcdef&from="))
        try await capture("1-qr-focused")
        page.handle(.move(.right))
        try await capture("2-form-focused")
        page.handle(.move(.down))
        try await capture("3-form-password")
        page.handle(.move(.down))   // 注册
        page.handle(.move(.down))   // 第三方那一排
        page.handle(.move(.right))  // 微信登录
        try await capture("6-form-wechat")
        page.handle(.move(.up))     // 登录
        page.handle(.move(.up))     // 忘记密码
        page.handle(.move(.left))   // 密码
        page.handle(.move(.left))   // 回到二维码
        #expect(page.side == .qr)
        page.qr.pretend(.expired)
        try await capture("4-qr-expired")
        page.qr.pretend(.scanned("https://account.bilibili.com/h5/account-h5/auth/scan-web?qrcode_key=0123456789abcdef0123456789abcdef"))
        try await capture("5-qr-scanned")
    }

    /// 二维码过期了：在左边按确认刷新
    @Test
    func selectRefreshesAnExpiredCode() async {
        let fake = FakeQR()
        let page = BiliLoginPage(qr: BiliQRLogin(service: fake, interval: .seconds(30)), dataStore: nil)
        page.qr.pretend(.expired)
        page.handle(.select)
        #expect(await waitUntil { if case .waiting = page.qr.state { true } else { false } })
        #expect(await fake.generated == 1)
        page.shutdown()
        #expect(!page.qr.running)
    }
}
