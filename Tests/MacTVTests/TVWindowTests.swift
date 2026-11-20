import AppKit
import Foundation
import Testing
import WebKit
@testable import MacTV

/// Back in a web page that moves with its own keys (YouTube's TV page) goes in as Escape. At the page's top level
/// the page lets it through; AppKit's NSWindow would take that to leave full screen (the bug: Back over and over in
/// YouTube took Mac TV out of full screen, then TV mode put it back). Now it's Back at the app's top level: Home,
/// with the app kept, and the window's full screen is never the page's to change.
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct TVWindowTests {
    init() {
        _ = NSApplication.shared
        AudioCoordinator.readVolume = { VolumeLevel(level: 50, muted: false) }
    }

    @Test func anEscapeNothingWantedNeverLeavesFullScreen() {
        let window = TVWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        var passed = 0
        window.unhandledCancel = { passed += 1 }
        window.cancelOperation(nil)
        #expect(passed == 1 && !window.styleMask.contains(.fullScreen))
        window.close()
    }

    @Test func pagesCantUseTheFullscreenAPI() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacTVTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let tv = TVController(library: AppLibrary(folder: folder))
        for service in [Catalog.services.first { $0.id == "youtube" }, Catalog.services.first { $0.id == BrowserStore.appID }].compactMap({ $0 }) {
            #expect(!tv.playbackCoordinator.makeWebView(for: service).configuration.preferences.isElementFullscreenEnabled, "\(service.id)")
        }
    }

    /// The real path: Back → Escape into the page. A page that uses Escape keeps it; at the top level it comes back
    /// unhandled and Back goes Home, with the page kept in the background.
    @Test func backAtAPagesTopLevelGoesHomeAndAPageThatUsesEscapeKeepsIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacTVTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "MacTVTests.Window.\(UUID().uuidString)"
        defer {
            TestDefaults.remove(suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let tv = TVController(library: AppLibrary(folder: folder), profiles: ProfileStore(folder: folder),
                              services: AppServices(preferences: Preferences(defaults: TestDefaults.named(suite))))
        let window = TVWindow(contentRect: NSRect(x: -10000, y: -10000, width: 640, height: 360), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.unhandledCancel = { [weak tv] in tv?.pageLetBackThrough() }
        window.orderFront(nil)
        defer { window.close() }
        tv.window = window

        // A website app that moves with its own keys, as YouTube's TV page does: Back goes in as Escape.
        let site = Service(id: "test-tv-page", name: "TV Page", kind: .web(URL(string: "about:blank")!), accent: "#333333", deep: "#111111",
                           dpadNavigation: false)
        tv.open(site)
        let web = try #require(tv.webView)
        web.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(web)
        func settle() async { for _ in 0..<20 where web.isLoading { try? await Task.sleep(for: .milliseconds(50)) } }
        await settle()

        // The page closes something with Escape: it keeps it, nothing else happens.
        _ = try await web.callAsyncJavaScript("""
            window.escapes = 0;
            document.addEventListener('keydown', e => { if (e.key === 'Escape') { e.preventDefault(); window.escapes += 1 } });
            """, contentWorld: .page)
        tv.handle(.back)
        var used = 0
        for _ in 0..<40 where used == 0 {
            try? await Task.sleep(for: .milliseconds(50))
            used = (try? await web.callAsyncJavaScript("return window.escapes", contentWorld: .page) as? Int) ?? 0
        }
        #expect(used == 1 && tv.mode == .player(site), "the page used it")

        // At its top level (nothing listening): Back goes Home with the page kept, and the window stays as it was.
        _ = try await web.callAsyncJavaScript("location.reload()", contentWorld: .page)
        try? await Task.sleep(for: .milliseconds(200))
        await settle()
        tv.handle(.back)
        for _ in 0..<40 where tv.mode != .launcher { try? await Task.sleep(for: .milliseconds(50)) }
        #expect(tv.mode == .launcher && tv.playbackCoordinator.parkedWebIDs == [site.id])
        #expect(!window.styleMask.contains(.fullScreen))
        web.removeFromSuperview()
        tv.playbackCoordinator.dropParkedWeb()
    }
}
