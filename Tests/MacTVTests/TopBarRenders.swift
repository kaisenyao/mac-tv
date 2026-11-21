import AppKit
import SwiftUI
import Testing
@testable import MacTV

/// 1920×1080 renders, offscreen, for review: Home, and the top bar's account pills as 得到 and 哔哩哔哩 draw them beside
/// Home's status row, to compare their sizes. Only with MACTV_RENDER_TOPBAR=<folder>; everything else lives in a
/// temporary folder.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MACTV_RENDER_TOPBAR"] != nil), .timeLimit(.minutes(1)))
@MainActor struct TopBarRenders {
    private let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACTV_RENDER_TOPBAR"] ?? "/tmp", isDirectory: true)

    private func render(_ name: String, _ view: some View) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let host = NSHostingView(rootView: ZStack { Color.black; TVCanvas { view } }
            .environment(\.colorScheme, .dark).frame(width: 1920, height: 1080))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1920, height: 1080), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(900))
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(name).png"))
        window.close()
    }

    private func withTV(_ body: (TVController) async throws -> Void) async throws {
        _ = NSApplication.shared
        AudioCoordinator.readVolume = { VolumeLevel(level: 75, muted: false) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacTVTopBar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "MacTVTopBarRenders.\(UUID().uuidString)"
        let defaults = TestDefaults.named(suite)
        defer { TestDefaults.remove(suite) }
        let services = AppServices(preferences: Preferences(defaults: defaults),
                                   movieLibrary: MovieLibrary(folder: folder.appendingPathComponent("Library"), defaults: defaults))
        let tv = TVController(library: AppLibrary(folder: folder), profiles: ProfileStore(folder: folder), services: services)
        try await body(tv)
    }

    @Test func home() async throws {
        try await withTV { tv in try await render("topbar-home", HomeView(tv: tv)) }
    }

    @Test func pills() async throws {
        try await withTV { tv in
            let rows = VStack(alignment: .trailing, spacing: 60) {
                HStack(spacing: 20) {
                    Text("17:17").font(TopBar.clock)
                    Image(systemName: "switch.2").font(.system(size: 27, weight: .semibold))
                        .frame(width: TopBar.height, height: TopBar.height).tvGlass(in: Circle())
                    ProfileAvatar(profile: tv.profile, size: TopBar.height)
                }
                AccountPill(name: "Yooks", detail: "电子书VIP", detailColor: .orange, focused: false) { Color.gray }
                AccountPill(name: "yks森", focused: false) { Color.pink }
                AccountPill(name: "yks森", focused: true) { Color.pink }
                Circle().fill(.gray).frame(width: TopBar.height, height: TopBar.height)
            }
            .foregroundStyle(.white)
            .padding(.trailing, TopBar.trailing).padding(.top, TopBar.top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .background(Color(hex: "#3A2333"))
            try await render("topbar-pills", rows)
        }
    }
}
