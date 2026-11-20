import AppKit
import IOKit
import QuartzCore
import Foundation
import SwiftUI
import Testing
@testable import MacTV

/// What one Top Shelf page turn costs on Home (the whole window, as the TV shows it, with real-looking pages).
/// Off by default: the numbers depend on the Mac, and the on-screen one shows a window.
///
/// - `MACTV_BENCH=1 swift test --filter ShelfTurnBenchmark/oneTurnIsCheap`: main-thread CPU, offscreen. SwiftUI's own
///   test clock (`_renderForTest`) steps 120 frames a second, as the display would, and Core Animation commits each one.
/// - `MACTV_BENCH_SCREEN=1 swift test --filter ShelfTurnBenchmark/onScreen`: a real window on the main screen, above
///   everything, for about 15 seconds: frame pacing from the display link, main-thread CPU, the GPU's busy %, memory.
@Suite(.timeLimit(.minutes(2)))
@MainActor struct ShelfTurnBenchmark {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test(.enabled(if: env["MACTV_BENCH"] == "1")) func oneTurnIsCheap() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let (tv, root, covers) = try await Self.home()
        defer { try? FileManager.default.removeItem(at: root) }
        var results: [String] = []
        var worst = 0.0
        for (layout, pages) in Self.layouts(covers) {
            let id = pages.id
            guard Self.focus(tv, on: id, pages: pages.items) else { continue }
            let host = NSHostingView(rootView: RootView(tv: tv))   // what the app's window shows
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1920, height: 1080), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            _ = await Self.frames(host, seconds: 1)            // settle: first layout, images
            let rest = await Self.frames(host, seconds: Double(Self.env["MACTV_BENCH_REST"] ?? "") ?? 2)
            var turns: [Double] = []
            // MACTV_BENCH_TURNS=30 turns more times, long enough to `sample` the test while it runs
            for _ in 0..<(Int(Self.env["MACTV_BENCH_TURNS"] ?? "") ?? 3) {
                tv.appShelf.step(id, by: 1)
                turns.append(await Self.frames(host, seconds: 2) - rest)
            }
            let turn = turns.sorted()[turns.count / 2]
            if Self.env["MACTV_BENCH_TIMELINE"] == "1" { print("\(layout) frames µs: \(Self.timeline)") }
            worst = max(worst, turn)
            results.append("\(layout): one turn \(Int(turn * 1000)) ms of main-thread CPU (still: \(Int(rest * 1000)) ms per 2 s)")
        }
        print("ShelfTurnBenchmark\n  " + results.joined(separator: "\n  "))
        #expect(worst < 0.1, "\(results)")
    }

    @Test(.enabled(if: env["MACTV_BENCH_SCREEN"] == "1")) func onScreen() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        let (tv, root, covers) = try await Self.home()
        defer { try? FileManager.default.removeItem(at: root) }
        // Dedao (what the TV shows now) unless MACTV_BENCH_LAYOUT says 1 (video) or 2 (playlist)
        let (_, pages) = Self.layouts(covers)[Int(Self.env["MACTV_BENCH_LAYOUT"] ?? "") ?? 0]
        guard Self.focus(tv, on: pages.id, pages: pages.items) else { return }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        // A panel that never activates: it shows over Mac TV's full-screen space without taking focus from it
        let window = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                             defer: false, screen: screen)
        window.isReleasedWhenClosed = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.backgroundColor = .black
        let host = NSHostingView(rootView: RootView(tv: tv))
        window.contentView = host
        window.orderFrontRegardless()
        // macOS only counts a window as visible (and SwiftUI only animates it) once its app has been active
        NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil); window.contentView = nil; window.close(); NSApp.hide(nil) }
        // The turn's second step normally runs as the next main-actor task; this loop holds the main actor, so it runs it
        var pending: [@MainActor () -> Void] = []
        tv.appShelf.afterThisFrame = { pending.append($0) }
        var timed: [(due: Double, work: @MainActor () -> Void)] = []
        ShelfPageSchedule.later = { delay, work in timed.append((CACurrentMediaTime() + delay, work)) }
        let clock = FrameClock(host)
        defer { clock.stop() }

        func run(_ seconds: Double) async {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {   // what NSApplication.run does: events as they come, the display cycle between them
                if let event = NSApp.nextEvent(matching: .any, until: min(end, Date().addingTimeInterval(0.002)), inMode: .default, dequeue: true) {
                    NSApp.sendEvent(event)
                }
                let now = CACurrentMediaTime()   // and what the app would have queued on the main queue for later
                let due = timed.filter { $0.due <= now }
                timed.removeAll { $0.due <= now }
                due.forEach { $0.work() }
            }
        }
        func measure(_ seconds: Double, _ body: () -> Void = {}) async -> (cpu: Double, gpu: Double, frames: [Double], work: [Double]) {
            let gpu = GPUMeter()
            clock.ticks = []
            clock.work = []
            let start = Self.mainThreadCPU()
            body()
            await run(1.0 / 60)                              // the turn's first frame (the new direction)
            pending.forEach { $0() }                        // then its second step, as the app's next task would
            pending = []
            await run(seconds)
            return (Self.mainThreadCPU() - start, gpu.stop(), clock.ticks, clock.work)
        }

        await run(2)                                               // settle: first layout, images, window on screen
        let idle = await measure(3)
        var report = ["visible \(window.occlusionState.contains(.visible)), \(Int(screen.frame.width))×\(Int(screen.frame.height)) pt, "
                      + "max \(screen.maximumFramesPerSecond) fps"]
        report.append("rest: main thread \(Self.percent(idle.cpu / 3)) of a core, GPU \(Int(idle.gpu))% busy (whole Mac)")
        for turn in 1...(Int(Self.env["MACTV_BENCH_SCREEN_TURNS"] ?? "") ?? 3) {
            let result = await measure(3) { tv.appShelf.step(pages.id, by: 1) }
            let gaps = zip(result.frames.dropFirst(), result.frames).map { $0 - $1 }
            let dropped60 = gaps.filter { $0 > 1.5 / 60 }.count
            let worstGap = (gaps.max() ?? 0) * 1000
            let busy = result.frames.isEmpty ? 0 : Double(result.frames.count) / 3
            report.append("turn \(turn): main thread \(Int((result.cpu - idle.cpu) * 1000)) ms more than resting, "
                          + "display link \(Int(busy)) fps, \(dropped60) frames over 25 ms (60 fps drops), longest \(Int(worstGap)) ms, "
                          + "GPU \(Int(result.gpu))% busy; costliest frames (ms): "
                          + result.work.sorted(by: >).prefix(5).map { String(format: "%.1f", $0) }.joined(separator: ", "))
        }
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        report.append("memory: \(info.phys_footprint / 1_048_576) MB footprint (test process)")
        let webkit = Self.children().filter { $0.contains("WebKit") }
        report.append("WebKit processes started by the test: \(webkit.isEmpty ? "none" : webkit.joined(separator: ", "))")
        print("ShelfTurnBenchmark on screen\n  " + report.joined(separator: "\n  "))
    }

    /// Each display-link tick, the time it came (the main thread drew a frame).
    @MainActor final class FrameClock: NSObject {
        var ticks: [Double] = []
        /// main-thread CPU (ms) between one tick and the next
        var work: [Double] = []
        private var lastCPU = ShelfTurnBenchmark.mainThreadCPU()
        private var link: CADisplayLink?
        init(_ view: NSView) {
            super.init()
            link = view.displayLink(target: self, selector: #selector(tick(_:)))
            link?.add(to: .main, forMode: .common)
        }
        @objc func tick(_ link: CADisplayLink) {
            ticks.append(CACurrentMediaTime())
            let cpu = ShelfTurnBenchmark.mainThreadCPU()
            work.append((cpu - lastCPU) * 1000)
            lastCPU = cpu
        }
        func stop() { link?.invalidate() }
    }

    /// The GPU's own busy % (the whole Mac), read from IOKit every 0.25 s while it runs
    @MainActor final class GPUMeter {
        private var readings: [Double] = []
        private var timer: Timer?
        init() {
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { if let value = GPUMeter.read() { self?.readings.append(value) } }
            }
            RunLoop.main.add(timer!, forMode: .common)
        }
        func stop() -> Double {
            timer?.invalidate()
            return readings.isEmpty ? 0 : readings.reduce(0, +) / Double(readings.count)
        }
        nonisolated static func read() -> Double? {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
            defer { IOObjectRelease(iterator) }
            var service = IOIteratorNext(iterator)
            while service != 0 {
                defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
                if let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any], let busy = stats["Device Utilization %"] as? Int {
                    return Double(busy)
                }
            }
            return nil
        }
    }

    static func mainThreadCPU() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9 }
    private static func percent(_ fraction: Double) -> String { String(format: "%.1f%%", fraction * 100) }

    /// This test's child processes (WebKit's would be here if Home used a web view)
    private static func children() -> [String] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-o", "comm=", "-ppid", "\(getpid())"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/ps") }
    }

    /// A TVController with its own empty library, and four covers in different colours (each page has its own palette)
    private static func home() async throws -> (TVController, URL, [URL]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mactv-shelf-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let tv = TVController(library: AppLibrary(folder: root.appendingPathComponent("library")))
        var covers: [URL] = []
        for (index, hue) in [0.02, 0.33, 0.6, 0.8].enumerated() {
            let url = root.appendingPathComponent("cover-\(index).png")
            try Self.cover(hue: CGFloat(hue)).write(to: url)
            _ = await BiliImageCache.shared.load(url)
            covers.append(url)
        }
        return (tv, root, covers)
    }

    private static func layouts(_ covers: [URL]) -> [(String, (id: String, items: [AppShelfItem]))] {
        [("dedao", dedaoPages(covers)), ("video", videoPages(covers)), ("playlist", playlistPages(covers))]
    }

    /// This app first in the dock and focused: its Top Shelf is on top
    private static func focus(_ tv: TVController, on id: String, pages: [AppShelfItem]) -> Bool {
        guard tv.appOrder.contains(id), tv.moveApp(id, to: 0) else { Issue.record("No \(id) on Home"); return false }
        tv.setFocus(.app(1)); tv.setFocus(.app(0))
        #expect(tv.shelfService.id == id)
        tv.appShelf.show(id, pages: pages, label: "测试")
        return true
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
