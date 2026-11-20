import AppKit
import SwiftUI
import WebKit

/// 原生的哔哩哔哩登录页：左边是原生画的二维码（用哔哩哔哩 App 扫），右边嵌着哔哩哔哩自己的登录表单
/// （密码、短信、第三方，换成深色，见 BilibiliLoginPage）。
///
/// 焦点只在一边：左边的二维码，或者右边表单里的某一个东西。方向键在表单里走、走到最左边再按左回到二维码；
/// 在二维码上按右进表单。表单里能选中的东西由网页报上来（位置），往哪走由这里决定（next），
/// 所以走一格时焦点是马上变的，和别处一样有按键声。
/// 登录成功（扫码，或者在表单里登录了）都走同一条路：BilibiliStore.finishLogin
@MainActor
final class BiliLoginPage: NSObject, ObservableObject {
    enum Side: Hashable { case qr, form }

    /// 表单里一个能选中的东西（输入框、按钮、标签……）在网页里的位置
    struct Item: Equatable {
        let frame: CGRect
        let input: Bool
    }

    @Published private(set) var side = Side.qr
    @Published private(set) var items: [Item] = []
    /// 表单里选中的是第几个（只在 side 是 .form 时亮着）
    @Published private(set) var index = 0
    /// 表单载好了、样式换好了（之前右边是一个转圈，不露出白色的原版页面）
    @Published private(set) var formReady = false
    /// 表单没载出来（网络）：按确认重试
    @Published private(set) var formFailed = false
    let qr: BiliQRLogin
    /// 右边的表单（这个人自己的网页数据：登录信息就存在这里）。测试里没有
    private(set) var web: WKWebView?

    /// 在表单里登录成功了（cookie 里出现了新的登录信息，问过哔哩哔哩确实登录着）
    var signedIn: (() -> Void)?
    /// 离开登录页（返回）
    var close: (() -> Void)?
    /// 键盘交给网页、给网页发按键用
    weak var tv: TVController?

    /// 光标在输入框里时，往左 / 往右还挪不挪得动（挪不动了才是换到旁边的东西上）
    private var caret = (left: false, right: false)
    /// 进过表单了（再进来回到上次停的那一个）
    private var visited = false
    /// 表单里有弹出来的东西开着（二次校验、区号列表、人机验证）：返回键先收起它
    private var popup = false
    private let dataStore: WKWebsiteDataStore?
    private var checkingCookies: Task<Void, Never>?
    /// 上一次问过的登录信息（只记一个指纹，不记内容）：一样的就不再问
    private var checkedSession: Int?
    private var finished = false
    private static let world = WKContentWorld.world(name: "MacTVBilibiliLogin")

    /// dataStore：这个人的网页数据；nil 时不建网页（测试）
    init(qr: BiliQRLogin, dataStore: WKWebsiteDataStore?) {
        self.qr = qr
        self.dataStore = dataStore
        super.init()
        if let dataStore { web = makeWeb(dataStore) }
    }

    /// 打开：开始取二维码、载表单
    func open() {
        qr.start()
        web?.load(URLRequest(url: BilibiliLoginPage.url))
    }

    /// 关掉：不再问二维码、网页停下拆掉，键盘收回
    func shutdown() {
        finished = true
        qr.stop()
        checkingCookies?.cancel()
        dataStore?.httpCookieStore.remove(self)
        if let web {
            web.stopLoading()
            web.configuration.userContentController.removeAllScriptMessageHandlers()
            web.navigationDelegate = nil
            web.uiDelegate = nil
            if tv?.window?.firstResponder === web { tv?.window?.makeFirstResponder(nil) }
        }
        web = nil
    }

    /// 给按键音和震动用：看得见的焦点动了一格就变
    var focusKey: String { "login-\(side)-\(side == .form ? index : -1)-\(items.count)" }

    // MARK: 按键

    func handle(_ command: RemoteCommand) {
        switch side {
        case .qr: handleQR(command)
        case .form: handleForm(command)
        }
    }

    private func handleQR(_ command: RemoteCommand) {
        switch command {
        case .select: qr.refresh()   // 过期了、没取到：重新取一张
        case .move(.right): enterForm()
        case .back: close?()
        // 手机遥控器上直接打字：进表单，打进第一个输入框
        case .text(let text):
            enterForm(at: items.firstIndex(where: \.input))
            type(text)
        default: break
        }
    }

    private func handleForm(_ command: RemoteCommand) {
        let item = items.indices.contains(index) ? items[index] : nil
        switch command {
        case .move(let direction):
            // 输入框里：光标还能往这边挪就挪光标（真的按键交给网页）
            if item?.input == true, (direction == .left && caret.left) || (direction == .right && caret.right) {
                send(.direction(direction))
            } else if let next = Self.next(from: index, in: items, toward: direction) {
                focus(next)
            } else if direction == .left {
                leaveForm()
            }
        case .select:
            if formFailed { reloadForm(); return }
            guard let item else { return }
            if item.input {
                // 输入框里按回车交给网页（哔哩哔哩的表单自己决定是不是提交）。空格不算：它的输入框会把空白去掉
                if NSApp.currentEvent?.type == .keyDown || NSApp.currentEvent?.type == .keyUp, NSApp.currentEvent?.keyCode == 49 { return }
                send(.enter)
            } else {
                run("return __tvLogin.activate(i)", ["i": index])
            }
        case .text(let text):
            if item?.input != true, let first = items.firstIndex(where: \.input) { focus(first) }
            type(text)
        case .deleteBackward: send(.delete)
        case .scroll(let dy): web?.evaluateJavaScript("window.scrollBy(0, \(Int(dy)))", in: nil, in: Self.world)
        case .back:
            // 先收起表单里弹出来的东西（二次校验、区号列表、人机验证）；点进了别的页面（微信、QQ、注册、找回密码）
            // 先回到登录表单；都没有才离开登录页
            if popup { run("return __tvLogin.back()"); return }
            if let web, web.canGoBack, web.url?.host() != BilibiliLoginPage.url.host() || web.url?.path() != BilibiliLoginPage.url.path() {
                web.goBack()
                return
            }
            close?()
        default: break
        }
    }

    /// 用鼠标、手机触控板点了左边的二维码：焦点回到这边；过期了顺便刷新
    func tapQR() {
        if side == .form { leaveForm() }
        qr.refresh()
    }

    private func enterForm(at preferred: Int? = nil) {
        withAnimation(Motion.focus) { side = .form }
        if let web, tv?.window?.firstResponder !== web { tv?.window?.makeFirstResponder(web) }
        // 回到上次停的那一个；第一次进来停在第一个输入框（账号）上
        let target = preferred ?? (visited && items.indices.contains(index) ? index : items.firstIndex(where: \.input) ?? 0)
        if items.indices.contains(target) { visited = true; focus(target) }
    }

    private func leaveForm() {
        withAnimation(Motion.focus) { side = .qr }
        run("__tvLogin.leave()")
        caret = (false, false)
        if let web, tv?.window?.firstResponder === web { tv?.window?.makeFirstResponder(nil) }
    }

    private func focus(_ target: Int) {
        index = target
        caret = (false, false)   // 网页那边换好了会再报
        run("return __tvLogin.focus(i)", ["i": target])
    }

    private func type(_ text: String) {
        for character in text { send(character == "\n" ? .enter : Key(code: 0, chars: String(character))) }
    }

    private func send(_ key: Key) {
        guard let web, let tv else { return }
        tv.playbackCoordinator.sendKey(key, to: web)
    }

    private func run(_ script: String, _ arguments: [String: Any] = [:]) {
        guard let web else { return }
        web.callAsyncJavaScript(script, arguments: arguments, in: nil, in: Self.world, completionHandler: nil)
    }

    private func reloadForm() {
        formFailed = false
        formReady = false
        web?.load(URLRequest(url: BilibiliLoginPage.url))
    }

    // MARK: 方向键在表单里怎么走

    /// 从第 index 个往 direction 走到哪一个：只看那个方向上的，先比离得多远，再比偏了多少（同一排、同一列的优先）。
    /// 左右只在同一排里走（不斜着跳到下面几排去）。那个方向上没有了就是 nil（往左没有了就回到二维码）
    static func next(from index: Int, in items: [Item], toward direction: RemoteCommand.Direction) -> Int? {
        guard items.indices.contains(index) else { return items.isEmpty ? nil : 0 }
        let from = items[index].frame
        let slack: CGFloat = 4
        var best: (index: Int, score: CGFloat)?
        for (candidate, item) in items.enumerated() where candidate != index {
            let to = item.frame
            let gap: CGFloat, overlap: CGFloat, center: CGFloat
            switch direction {
            case .left, .right:
                guard direction == .left ? to.maxX <= from.minX + slack : to.minX >= from.maxX - slack else { continue }
                gap = direction == .left ? from.minX - to.maxX : to.minX - from.maxX
                overlap = max(0, max(from.minY, to.minY) - min(from.maxY, to.maxY))
                guard overlap <= 8 else { continue }   // 不在同一排
                center = abs(from.midY - to.midY)
            case .up, .down:
                guard direction == .up ? to.maxY <= from.minY + slack : to.minY >= from.maxY - slack else { continue }
                gap = direction == .up ? from.minY - to.maxY : to.minY - from.maxY
                overlap = max(0, max(from.minX, to.minX) - min(from.maxX, to.maxX))
                center = abs(from.midX - to.midX)
            }
            let score = max(0, gap) + overlap * 2 + center * 0.1
            if score < best?.score ?? .infinity { best = (candidate, score) }
        }
        return best?.index
    }

    /// 转盘这一格能不能走：只在表单里走，到头就停（回二维码要按方向键）
    func canMove(_ direction: RemoteCommand.Direction) -> Bool {
        side == .form && Self.next(from: index, in: items, toward: direction) != nil
    }

    /// 测试用：当作表单已经载好、报上来了这几样（不建网页）
    func pretendForm(_ items: [Item]) {
        self.items = items
        formReady = true
    }

    // MARK: 网页

    private func makeWeb(_ dataStore: WKWebsiteDataStore) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        let scripts = config.userContentController
        scripts.addUserScript(WKUserScript(source: BilibiliLoginPage.chinese, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        scripts.addUserScript(WKUserScript(source: BilibiliLoginPage.form, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.world))
        scripts.add(WeakMessages(self), contentWorld: Self.world, name: "tvLogin")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: config)
        web.customUserAgent = UserAgent.safari
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsMagnification = false
        web.underPageBackgroundColor = NSColor(Color(hex: BilibiliLoginPage.background))
        dataStore.httpCookieStore.add(self)
        return web
    }

    fileprivate func received(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "items":
            let list = (message["items"] as? [[Double]] ?? []).compactMap { values -> Item? in
                guard values.count >= 5 else { return nil }
                return Item(frame: CGRect(x: values[0], y: values[1], width: values[2], height: values[3]), input: values[4] != 0)
            }
            items = list
            popup = message["popup"] as? Bool ?? false
            if let focus = message["focus"] as? Int, list.indices.contains(focus) {
                index = focus
            } else if side == .form, !list.isEmpty {
                // 选中的那个没了（换了一个标签页、弹窗收起了）：停在第一个输入框上
                focus(list.firstIndex(where: \.input) ?? 0)
            }
        case "focus":
            guard let focus = message["index"] as? Int, items.indices.contains(focus) else { return }
            index = focus
            if side != .form {
                withAnimation(Motion.focus) { side = .form }
                if let web, tv?.window?.firstResponder !== web { tv?.window?.makeFirstResponder(web) }
            }
        case "caret":
            caret = (message["left"] as? Bool ?? false, message["right"] as? Bool ?? false)
        case "ready":
            withAnimation(.easeOut(duration: 0.2)) { formReady = true }
        default: break
        }
    }

    /// 网页数据里的 cookie 变了：出现了新的哔哩哔哩登录信息（SESSDATA）就问一次是不是登录了。
    /// 稍等一下再看（登录时一下子写好几个），同一份登录信息只问一次
    private func checkLogin(after delay: Duration = .milliseconds(400)) {
        guard !finished, let dataStore else { return }
        checkingCookies?.cancel()
        checkingCookies = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let cookies = await dataStore.httpCookieStore.allCookies().filter(\.isBilibili)
            guard let self, !Task.isCancelled, !self.finished, self.qr.state != .done,
                  let session = cookies.first(where: { $0.name == "SESSDATA" }), session.value.hashValue != self.checkedSession else { return }
            self.checkedSession = session.value.hashValue
            let header = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            guard case .signedIn = await BiliAPI.account(cookie: header), !Task.isCancelled, !self.finished else { return }
            self.finished = true
            self.signedIn?()
        }
    }
}

extension BiliLoginPage: WKHTTPCookieStoreObserver {
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor [weak self] in self?.checkLogin() }
    }
}

extension BiliLoginPage: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard navigationAction.targetFrame?.isMainFrame ?? true, let host = navigationAction.request.url?.host() else { return .allow }
        // 登录完哔哩哔哩会把页面带到首页：不去，登录信息已经写好了，直接看是不是登录了
        if ["www.bilibili.com", "bilibili.com", "m.bilibili.com"].contains(host) {
            checkLogin(after: .zero)
            return .cancel
        }
        // Google 的登录页不认嵌在应用里的浏览器，只在它的页面上装成 Firefox（和网页播放器一样）
        let google = host == "accounts.google.com" || host.hasSuffix(".accounts.google.com")
        let agent = google ? UserAgent.googleSignIn : UserAgent.safari
        if webView.customUserAgent != agent { webView.customUserAgent = agent }
        return .allow
    }

    /// 到了别的页面（第三方登录、注册）：表单里那几样都不在了，方向键不再在里面走（用鼠标、键盘）；回到登录页时脚本会重新报
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        items = []
        popup = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        formFailed = false
        // 第三方的登录页没有我们的脚本，载完就显示
        if webView.url?.host() != "passport.bilibili.com" { withAnimation(.easeOut(duration: 0.2)) { formReady = true } }
    }

    /// 表单本身没载出来（网络）：右边写"无法载入"。之后点进别的页面失败（第三方）不算，留在那一页上
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let error = error as NSError
        guard !formReady, error.code != NSURLErrorCancelled, error.domain != "WebKitErrorDomain" else { return }
        formFailed = true
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { reloadForm() }

    /// 第三方登录要开新窗口时，在同一块里打开（不弹出别的窗口）
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        webView.load(navigationAction.request)
        return nil
    }
}

/// 网页发来的消息转给登录页。网页那边对它是强引用，所以这里只弱引用着登录页（不然关了也放不掉）
private final class WeakMessages: NSObject, WKScriptMessageHandler {
    weak var page: BiliLoginPage?
    init(_ page: BiliLoginPage) { self.page = page }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { page?.received(body) }
    }
}
