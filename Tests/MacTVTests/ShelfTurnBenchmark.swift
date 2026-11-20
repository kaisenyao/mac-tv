import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MacTV

/// How much main-thread CPU one Top Shelf page turn costs on Home: two seconds of 120 Hz frames after a turn, minus two
/// seconds of frames with nothing turning. The banner's window is never shown: SwiftUI's own test clock
/// (`_renderForTest`) steps each frame, as the display would on the TV, and Core Animation commits it.
/// Only runs with MACTV_BENCH=1 (it takes a few seconds and the number depends on the Mac):
/// `MACTV_BENCH=1 swift test --filter ShelfTurnBenchmark`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MACTV_BENCH"] == "1"), .timeLimit(.minutes(2)))
@MainActor struct ShelfTurnBenchmark {
    @Test func oneTurnIsCheap() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mactv-shelf-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tv = TVController(library: AppLibrary(folder: root.appendingPathComponent("library")))
        // Covers in different colours, so each page has its own palette like real covers do.
        let hues: [CGFloat] = [0.02, 0.33, 0.6, 0.8]
        var covers: [URL] = []
        for (index, hue) in hues.enumerated() {
            let url = root.appendingPathComponent("cover-\(index).png")
            try Self.cover(hue: hue).write(to: url)
            _ = await BiliImageCache.shared.load(url)
            covers.append(url)
        }

        var results: [String] = []
        var worst = 0.0
        for (layout, pages) in [("dedao", Self.dedaoPages(covers)), ("video", Self.videoPages(covers)), ("playlist", Self.playlistPages(covers))] {
            let id = pages.id
            // The whole window, as the TV shows it, with this app first in the dock and focused (its Top Shelf on top)
            guard tv.appOrder.contains(id), tv.moveApp(id, to: 0) else { Issue.record("No \(id) on Home"); continue }
            tv.setFocus(.app(1)); tv.setFocus(.app(0))
            #expect(tv.shelfService.id == id)
            tv.appShelf.show(id, pages: pages.items, label: "测试")
            let host = NSHostingView(rootView: RootView(tv: tv))   // what the app's window shows
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1920, height: 1080), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            _ = await Self.frames(host, seconds: 1)            // settle: first layout, images
            let rest = await Self.frames(host, seconds: 2)
            var turns: [Double] = []
            // MACTV_BENCH_TURNS=30 turns more times, long enough to `sample` the test while it runs
            for _ in 0..<(Int(ProcessInfo.processInfo.environment["MACTV_BENCH_TURNS"] ?? "") ?? 3) {
                tv.appShelf.step(id, by: 1)
                turns.append(await Self.frames(host, seconds: 2) - rest)
            }
            let turn = turns.sorted()[1]
            if ProcessInfo.processInfo.environment["MACTV_BENCH_TIMELINE"] == "1" { print("\(layout) frames µs: \(Self.timeline)") }
            worst = max(worst, turn)
            results.append("\(layout): one turn \(Int(turn * 1000)) ms of main-thread CPU (still: \(Int(rest * 1000)) ms per 2 s)")
        }
        print("ShelfTurnBenchmark\n  " + results.joined(separator: "\n  "))
        #expect(worst < 0.1, "\(results)")
    }

    /// Main-thread CPU seconds for `seconds` of frames at 120 per second.
    static var timeline: [Int] = []
    private static func frames<V: View>(_ host: NSHostingView<V>, seconds: Double) async -> Double {
        var spent = 0.0
        timeline = []
        for _ in 0..<Int(seconds * 120) {
            await Task.yield()   // the turn itself runs in a task on the main actor
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            host._renderForTest(interval: 1.0 / 120)
            CATransaction.flush()
            let cost = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e9
            timeline.append(Int(cost * 1e6))
            spent += cost
        }
        return spent
    }

    private static func cover(hue: CGFloat) -> Data {
        let size = 800
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGradient(starting: NSColor(hue: hue, saturation: 0.8, brightness: 0.9, alpha: 1),
                   ending: NSColor(hue: hue + 0.1, saturation: 0.7, brightness: 0.3, alpha: 1))!
            .draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: 45)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    private static func dedaoPages(_ covers: [URL]) -> (id: String, items: [AppShelfItem]) {
        let items = covers.enumerated().map { index, cover in
            DedaoStore.shelfCard(DedaoAPI.Item(kind: .book, enid: "b\(index)", title: "《一本很好听的书第\(index)本》", author: "某某解读",
                                               intro: "这是一段介绍，两三行长，讲这本书说了什么、为什么值得听，还有它的作者是谁。再多写几句，让它够三行。",
                                               cover: cover, progress: index * 20, finished: false, count: 0, studied: 0,
                                               shelf: .books, duration: 1800),
                                 tag: "新书 · 历史", resume: false)
        }
        return (DedaoStore.appID, items)
    }

    private static func videoPages(_ covers: [URL]) -> (id: String, items: [AppShelfItem]) {
        let items = covers.enumerated().map { index, cover in
            let video = BiliVideo(bvid: "BV\(index)", title: "一个视频的标题，长到要占两行的那种，第\(index)个", cover: cover, duration: 600,
                                  owner: "UP 主", views: 12345)
            return AppShelfItem(id: "bv-\(index)", kind: .video(video), title: video.title, subtitle: "UP 主", detail: "3 小时前 · 1.2万播放",
                                image: cover, thumbnail: cover, avatar: nil)
        }
        return (BilibiliStore.appID, items)
    }

    private static func playlistPages(_ covers: [URL]) -> (id: String, items: [AppShelfItem]) {
        let items = covers.enumerated().map { index, cover in
            AppShelfItem(id: "pl-\(index)",
                         kind: .collection(NeteasePlaylist(id: index, name: "一个歌单\(index)", cover: cover, count: 30),
                                           songs: (0..<4).map { NeteaseSong(id: index * 10 + $0, name: "一首歌 \($0)", artist: "歌手", cover: cover) }),
                         title: "一个歌单\(index)", subtitle: "30 首 · 某人", detail: "", image: cover, thumbnail: cover, avatar: nil)
        }
        return (NeteaseStore.appID, items)
    }
}
