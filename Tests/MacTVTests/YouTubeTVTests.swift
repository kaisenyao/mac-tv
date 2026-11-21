import Foundation
import JavaScriptCore
import Testing
@testable import MacTV

/// YouTube 电视版的打开地址和页面脚本
@Suite(.timeLimit(.minutes(1))) @MainActor
struct YouTubeTVTests {
    @Test
    func addressesSkipTheStartupPicker() throws {
        #expect(YouTubeTV.home.absoluteString == "https://www.youtube.com/tv?force_startup_screen=none")
        #expect(YouTubeTV.watch("aqz-KE-bpKQ")?.absoluteString == "https://www.youtube.com/tv?force_startup_screen=none#/watch?v=aqz-KE-bpKQ")
        // 只认视频编号的字符：别的东西拼不进地址里
        #expect(YouTubeTV.watch("") == nil)
        #expect(YouTubeTV.watch("abc&list=1") == nil)
        #expect(YouTubeTV.watch("../x") == nil)
        // Brave 打开时还是换成普通版首页
        #expect(try BraveSession.streamingURL(YouTubeTV.home).absoluteString == "https://www.youtube.com/")
    }

    /// 返回键在 YouTube 的最外层（首页、左边栏的分页、它自己的"Who's watching?"）回 Mac TV 主屏，
    /// 看视频、搜索时照旧交给 YouTube
    @Test
    func backLeavesYouTubeOnlyAtItsTopLevel() {
        let base = "https://www.youtube.com/tv?force_startup_screen=none"
        for top in [base, base + "#/", base + "#/browse?c=FEsubscriptions", base + "#/account_selector"] {
            #expect(YouTubeTV.isTopLevel(URL(string: top)), "\(top)")
        }
        for inside in [base + "#/watch?v=aqz-KE-bpKQ", base + "#/search?q=cats"] {
            #expect(!YouTubeTV.isTopLevel(URL(string: inside)), "\(inside)")
        }
        #expect(YouTubeTV.isAccountPicker(URL(string: base + "#/account_selector")))
        #expect(!YouTubeTV.isAccountPicker(URL(string: base + "#/")))
    }

    @Test
    func scriptOnlyRefusesAbsurdFrameRates() {
        let page = FakePage(width: 1920, height: 1080, ratio: 1)
        #expect(page.eval(#"MediaSource.isTypeSupported('video/webm; codecs="vp9"; framerate=9999')"#).toBool() == false)
        #expect(page.eval(#"MediaSource.isTypeSupported('video/webm; codecs="vp9"; framerate=60')"#).toBool() == true)
        #expect(page.eval(#"MediaSource.isTypeSupported('video/webm; codecs="vp9"')"#).toBool() == true)
        #expect(YouTubeTV.script.contains("#0f0f0f"))
    }

    /// 像素比只在屏幕夹在两档清晰度之间时往上抬，正好够下一档；电视和整档的显示器原样不动
    @Test
    func pixelRatioOnlyRisesToTheNextStep() {
        func ratio(_ width: Double, _ height: Double, _ real: Double) -> Double {
            FakePage(width: width, height: height, ratio: real).eval("window.devicePixelRatio").toDouble()
        }
        #expect(abs(ratio(1728, 1117, 2) - 2 * 3840 / 3456) < 0.0001)   // MacBook Pro 16 寸：1440p → 2160p
        #expect(abs(ratio(1512, 982, 2) - 3840 / 1512) < 0.0001)        // MacBook Pro 14 寸
        #expect(abs(ratio(1152, 720, 2) - 2 * 2560 / 2304) < 0.0001)    // 1080p 和 1440p 之间 → 1440p
        #expect(ratio(1920, 1080, 1) == 1)    // 1080p 电视
        #expect(ratio(1920, 1080, 2) == 2)    // 4K 电视，"看起来像 1080p"
        #expect(ratio(3840, 2160, 1) == 1)    // 4K 电视原生分辨率
        #expect(ratio(2560, 1440, 1) == 1)    // 1440p 显示器
        #expect(ratio(1280, 800, 2) == 2)     // MacBook Air 13 寸：正好 2560 宽
        #expect(ratio(2560, 1440, 2) == 2)    // 5K：已经超过 4K，不动
        #expect(ratio(1366, 768, 1) == 1)     // 1080p 以下的电视不动
    }

    /// 只在放广告、"跳过"按钮出现并且是选中状态、开关开着时才按确定；广告完了就不再看
    @Test
    func pressesSkipOnlyWhenYouTubeOffersIt() {
        let page = FakePage(width: 1920, height: 1080, ratio: 1)
        page.eval("window.__mactvAuto = { skip: true, next: true }")
        page.eval("__tick(0)")                                      // 找到播放器，开始盯它的 class
        #expect(page.eval("__live()").toInt32() == 0)              // 没放广告：没有在跑的计时器
        page.eval("__player.ad = true; __mutate()")
        #expect(page.eval("__live()").toInt32() == 1)
        page.eval("__tickAll()")
        #expect(page.eval("__events.length").toInt32() == 0)       // 还没有"跳过"按钮
        page.eval("__showButton = true; document.activeElement = __inner; __tickAll()")
        #expect(page.eval("__events.join(',')").toString() == "keydown:13,keyup:13")
        page.eval("__events = []; window.__mactvAuto.skip = false; __tickAll()")
        #expect(page.eval("__events.length").toInt32() == 0)       // 开关关了：不按
        page.eval("window.__mactvAuto.skip = true; document.activeElement = {}; __tickAll()")
        #expect(page.eval("__events.length").toInt32() == 0)       // 焦点不在"跳过"上：不按
        page.eval("__player.ad = false; __mutate()")
        #expect(page.eval("__live()").toInt32() == 0)              // 广告放完：计时器停了
    }
}

/// 一个最小的假网页：只有脚本用到的那几样
@MainActor
private final class FakePage {
    let context = JSContext()!

    init(width: Double, height: Double, ratio: Double) {
        context.evaluateScript("""
        var window = this;
        var screen = { width: \(width), height: \(height) };
        Object.defineProperty(window, 'devicePixelRatio', { configurable: true, enumerable: true, get: function () { return \(ratio); } });
        var MediaSource = { isTypeSupported: function () { return true; } };
        var __events = [], __timers = [], __observers = [], __showButton = false;
        var setInterval = function (f) { __timers.push(f); return __timers.length; };
        var clearInterval = function (id) { __timers[id - 1] = null; };
        var __tick = function (i) { if (__timers[i]) __timers[i](); };
        var __tickAll = function () { for (var i = 1; i < __timers.length; i++) __tick(i); };
        var __live = function () { return __timers.slice(1).filter(function (t) { return t; }).length; };
        var MutationObserver = function (cb) { this.observe = function () { __observers.push(cb); }; };
        var __mutate = function () { __observers.forEach(function (cb) { cb(); }); };
        var KeyboardEvent = function (type, init) { this.type = type; this.keyCode = init.keyCode; };
        var __player = { ad: false, classList: { contains: function (c) { return c === 'ad-showing' && __player.ad; } } };
        var __inner = { dispatchEvent: function (e) { __events.push(e.type + ':' + e.keyCode); } };
        var __button = { getBoundingClientRect: function () { return { width: 120 }; },
          contains: function (e) { return e === __inner; },
          classList: { contains: function () { return false; } }, querySelector: function () { return null; } };
        var document = {
          activeElement: null, head: { appendChild: function () {} }, documentElement: { appendChild: function () {} },
          createElement: function () { return {}; },
          querySelector: function (s) {
            if (s === '.html5-video-player') return __player;
            if (s === 'ytlr-skip-button-renderer') return __showButton ? __button : null;
            return null;
          }
        };
        """)
        context.evaluateScript(YouTubeTV.script)
    }

    @discardableResult
    func eval(_ script: String) -> JSValue {
        context.evaluateScript(script)
    }
}
