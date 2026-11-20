import Foundation
import Testing
@testable import MacTV

@Suite struct RemotePageTests {
    @Test func pageIsServedWholeWithItsStylesAndScriptInline() {
        let html = RemotePage.html
        #expect(html.hasPrefix("<!doctype html>"))
        #expect(!html.contains("remote is missing") && !html.contains("page is missing"))
        #expect(!html.contains(#"href="remote.css""#) && !html.contains(#"src="remote.js""#))
        #expect(html.contains("<style>\n:root {") || html.contains("<style>\n  :root {"))
        #expect(html.contains("const $ = s => document.querySelector(s);"))
        #expect(html.hasSuffix("</html>\n"))
    }

    /// 遥控器上的图都在页面里：每个 <use href="#…"> 和 url(#…) 都指向页面里真有的东西，
    /// 每个画出来的键都有正常和按下两套样子（顶上四个、切换条的滑块、转盘中间、四个圆键、音量的上下两半、
    /// 快捷键），点按转盘的外圈有八个方向的按下样子
    @Test func everyKeyIsDrawnInTheNormalAndPressedLook() throws {
        let html = RemotePage.html
        let ids = Set(matches(of: #"\bid="([^"]+)""#, in: html))
        #expect(ids.count == matches(of: #"\bid="([^"]+)""#, in: html).count, "ids are unique")
        let references = matches(of: ##"href="#([^"]+)""##, in: html) + matches(of: #"url\(#([^)]+)\)"#, in: html)
        #expect(!references.isEmpty)
        for reference in references { #expect(ids.contains(reference), "\(reference) is in the page") }

        let normal = Set(matches(of: ##"<use href="#(art-[^"]+)" data-state="normal""##, in: html))
        let pressed = Set(matches(of: ##"<use href="#(art-[^"]+)-pressed" data-state="pressed""##, in: html))
        #expect(normal == ["art-field", "art-apps", "art-settings", "art-power", "art-mode-thumb", "art-ring", "art-center",
                           "art-back", "art-tv", "art-play", "art-mute", "art-volup", "art-voldown", "art-chip"])
        for art in normal where art != "art-ring" { #expect(pressed.contains(art), "\(art) has a pressed look") }
        for direction in ["up", "up-right", "right", "down-right", "down", "down-left", "left", "up-left"] {
            #expect(html.contains(##"<use href="#art-ring-\##(direction)" data-state="pressed-\##(direction)""##))
        }
        // 四格快捷键，都是银色的键
        #expect(matches(of: ##"<button class="drawn (chip) empty""##, in: html).count == 4)
    }

    /// 快退、快进不在手机上了：页面里一点都不剩
    @Test func rewindAndForwardAreGone() {
        let html = RemotePage.html.lowercased()
        #expect(!html.contains("rewind") && !html.contains("forward"))
    }

    /// Mac 发来的每个快捷键图标页面里都画了（名字对不上的不画），页面按约定的地址读写快捷键
    @Test func everyShortcutIconIsDrawnAndTheShortcutRoutesAreUsed() {
        let html = RemotePage.html
        for icon in ["shortcut", "screensaver", "sleep", "files", "danmaku", "quality", "speed", "subtitles", "episodes",
                     "coin", "star", "heart", "lyrics", "mode", "daily", "transcript", "next", "previous"] {
            #expect(html.contains(#"<symbol id="icon-\#(icon)" viewBox="0 0 44 44">"#), "\(icon) is drawn")
        }
        for route in ["'/shortcuts'", "'/shortcuts/set'", "'/shortcuts/apple'", "send('shortcut', { id: item.id })"] {
            #expect(html.contains(route), "\(route) is used")
        }
    }

    /// 页面要的文件（图标）都给；只给这几个，别的名字一律没有。手机不出声，没有声音文件
    @Test func servesOnlyThePageFilesItAsksFor() throws {
        let html = RemotePage.html
        let asked = Set(matches(of: #"/page/([A-Za-z0-9.-]+)"#, in: html))
        #expect(asked == ["touch-icon.png"])
        for name in asked { #expect(RemotePage.asset(name) != nil, "\(name) is served") }
        #expect(RemotePage.asset("touch-icon.png")?.type == "image/png")
        for name in ["press-down.wav", "tick.mp3", "remote.js", "remote.html", "tick-LICENSE.txt", "../Info.plist", ""] {
            #expect(RemotePage.asset(name) == nil, "\(name) is not served")
        }
    }

    private func matches(of pattern: String, in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
