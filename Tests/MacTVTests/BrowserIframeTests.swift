import AppKit
import Foundation
import Testing
import WebKit
@testable import MacTV

/// 内嵌框架后面的白框（chatgpt.com 上 Google 一键登录的深色卡片外面一圈白）：网页有 <meta name="color-scheme"
/// content="light dark">、根也是 "light dark"，<iframe> 本身算出来是 "normal"（按 meta 就是深色），框架里那一页什么都没写。WebKit 按网页的深色来比，给框架垫一块白底。
/// BrowserPageScript 把 <iframe> 的 color-scheme 明确设成框架里那一页的（这里是浅色），白底就没了。
/// 没有脚本时这个角是白的（说明这一页确实会出白框），有脚本时是网页的黑色
@MainActor
struct BrowserIframeTests {
    static let child = """
        <!doctype html><html><head><style>html,body{background:transparent;margin:0}
        .card{margin:16px;height:168px;border-radius:28px;background:#202124}</style></head><body><div class=card></div></body></html>
        """

    static var parent: String {
        let escaped = child.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
        return """
            <!doctype html><html style="color-scheme: light dark"><head><meta name="color-scheme" content="light dark"></head>
            <body style="background:#000;margin:0">
            <iframe srcdoc="\(escaped)" style="color-scheme: normal; position:fixed; top:40px; left:40px; width:400px; height:200px; border:0"></iframe>
            </body></html>
            """
    }

    static func pump(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.02))) }
    }

    /// 截一张图，取 (x, y) 那一点的颜色：(r, g, b) 0–255
    static func pixel(_ web: WKWebView, x: Int, y: Int) async -> (Int, Int, Int)? {
        guard let image = try? await web.takeSnapshot(configuration: WKSnapshotConfiguration()),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        let scale = Double(cg.width) / Double(web.bounds.width)
        guard let color = rep.colorAt(x: Int(Double(x) * scale), y: Int(Double(y) * scale))?.usingColorSpace(.sRGB) else { return nil }
        return (Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
    }

    /// 返回 (框架的 color-scheme 被设成了什么, 框架左上角、卡片外面那一点的颜色)
    func load(withScript: Bool) async -> (String, (Int, Int, Int)?) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacTVTests.iframe.\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = folder.appendingPathComponent("Preferences.plist").path
        defer {
            TestDefaults.remove(suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let store = BrowserStore(storage: BrowserTabStorage(suite: suite, folder: folder))
        if withScript { BrowserPageScript.install(in: config, store: store) }
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: config)
        web.underPageBackgroundColor = .black
        web.appearance = NSAppearance(named: .darkAqua)
        // 测试的窗口看不见：让 WebKit 照样画（只在测试里）
        let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if web.responds(to: occlusion) { web.perform(occlusion, with: false) }
        let window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        web.loadHTMLString(Self.parent, baseURL: URL(string: "https://parent.test/"))
        var scheme = ""
        for _ in 0..<50 {
            Self.pump(0.1)
            scheme = (try? await web.evaluateJavaScript("document.querySelector('iframe').style.getPropertyValue('color-scheme')")) as? String ?? ""
            if !web.isLoading && (!withScript || scheme == "light") { break }
        }
        Self.pump(0.5)
        _ = await Self.pixel(web, x: 5, y: 5)   // 载好后的第一张有时是空的
        Self.pump(0.2)
        return (scheme, await Self.pixel(web, x: 43, y: 43))
    }

    @Test
    func anEmbeddedFrameGetsTheColourSchemeOfItsOwnPageSoNoWhiteBoxIsPainted() async throws {
        _ = NSApplication.shared
        let (_, before) = await load(withScript: false)
        let (scheme, after) = await load(withScript: true)
        #expect(scheme == "light")
        if let before { #expect(before.0 > 200 && before.1 > 200 && before.2 > 200) }   // 白框（这一页确实会出）
        #expect(after.map { $0.0 < 30 && $0.1 < 30 && $0.2 < 30 } == true)              // 网页的黑色，没有白框
    }
}
