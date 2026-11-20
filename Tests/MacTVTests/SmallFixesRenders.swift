import AppKit
import SwiftUI
import Testing
@testable import MacTV

/// 1920×1080 renders of the Audio Output sheet's Volume row, the 得到 Top Shelf checklist with its section headers,
/// and the flip clock. Only with MACTV_RENDER_SMALL=<folder>; everything it sets up lives in a temporary folder, and
/// the 得到 categories are registered in memory only.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MACTV_RENDER_SMALL"] != nil), .timeLimit(.minutes(1))) @MainActor
struct SmallFixesRenders {
    private let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACTV_RENDER_SMALL"] ?? "/tmp", isDirectory: true)

    private func render(_ name: String, _ view: some View) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark).frame(width: 1920, height: 1080))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1920, height: 1080), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(name).png"))
        window.close()
    }

    /// A TV with its own app list, preferences and movie library in a temporary folder.
    private func withTV(movies: [Movie], _ body: (TVController) async throws -> Void) async throws {
        _ = NSApplication.shared
        AudioCoordinator.readVolume = { VolumeLevel(level: 75, muted: false) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacTVRenders-\(UUID().uuidString)")
        let library = folder.appendingPathComponent("Movies", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try JSONEncoder().encode(movies).write(to: library.appendingPathComponent("library.json"))
        let suite = "MacTVRenders.\(UUID().uuidString)"
        defer { TestDefaults.remove(suite) }
        let services = AppServices(preferences: Preferences(defaults: TestDefaults.named(suite)),
                                   movieLibrary: MovieLibrary(folder: library))
        try await body(TVController(library: AppLibrary(folder: folder), services: services))
    }

    @Test func audioOutputVolumeRow() async throws {
        try await withTV(movies: []) { tv in
            let sheet = { ZStack { Wallpaper(); SheetBackdrop(); TVCanvas { AudioPickerSheet(tv: tv) } } }
            tv.openAudioPicker()
            tv.audioPicker?.row = tv.audioDevices.count
            try await render("audio-volume-available", sheet())

            // Just switched to a display that hasn't answered yet: the slider waits, it doesn't say Not Available.
            let fixed = tv.audioCoordinator.fixedOutput
            fixed.findDisplay = { _ in try? await Task.sleep(for: .seconds(3)); return nil }
            fixed.update(AudioOutputDevice(id: 9_999, name: "XG27UCS", transport: 0x64707274, isDefault: true, uid: "render"),
                         systemControls: false)
            fixed.perform(.refresh, showHUD: false)
            fixed.onChange(fixed.volume, false)
            #expect(tv.audioCoordinator.volumePending)
            try await render("audio-volume-pending", sheet())
        }
    }

    @Test func dedaoTopShelfHeaders() async throws {
        let standard = UserDefaults.standard
        let registered = standard.volatileDomain(forName: UserDefaults.registrationDomain)
        defer { standard.setVolatileDomain(registered, forName: UserDefaults.registrationDomain) }
        let names = ["职场发展", "财富投资", "商业经管", "身心关系", "教育成长", "历史", "人文艺术", "社会观察", "自然科学", "AI"]
        let topics = names.enumerated().map { DedaoAPI.Topic(id: "t\($0.offset)", name: $0.element, labels: []) }
        standard.register(defaults: ["dedaoTopics": try JSONEncoder().encode(topics)])

        try await withTV(movies: []) { tv in
            let sheet = { ZStack { Wallpaper(); SheetBackdrop(); TVCanvas { TopShelfPreferencesSheet(tv: tv) } } }
            tv.openTopShelfPreferences()
            tv.openTopShelfApp(try #require(tv.topShelfApps.firstIndex { $0.id == DedaoStore.appID }))
            try await render("dedao-top-shelf", sheet())
            tv.topShelfPreferences?.option = 5
            try await render("dedao-top-shelf-categories", sheet())
        }
    }

    /// Fliqlo's places: AM at the top-left of the hour plate, PM at the bottom-left; full screen and the card's size.
    @Test func flipClockMeridiem() async throws {
        let calendar = Calendar(identifier: .gregorian)
        let morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 7, minute: 27)))
        let evening = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 19, minute: 29)))
        for (name, date) in [("am", morning), ("pm", evening)] {
            let full = CGSize(width: 1920, height: 1080), card = CGSize(width: 480, height: 270)
            try await render("flip-clock-\(name)", ZStack { Color.black; FlipClockFace(date: date, twentyFour: false, size: full) })
            try await render("flip-clock-card-\(name)", ZStack {
                Color(white: 0.2)
                FlipClockFace(date: date, twentyFour: false, size: card)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .frame(width: card.width, height: card.height)
            })
        }
    }
}
