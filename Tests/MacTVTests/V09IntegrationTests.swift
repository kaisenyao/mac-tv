import AppKit
import Foundation
import Testing
@testable import MacTV

@Suite(.timeLimit(.minutes(1))) @MainActor struct V09IntegrationTests {
    private func withFolder(_ body: (URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder)
    }

    @Test func profilesKeepTheirOwnOrderAndShareTheAppsTheyAdd() throws {
        try withFolder { folder in
            let first = AppLibrary(folder: folder)
            let other = AppLibrary(profileID: "other", folder: folder)
            let a = first.add(name: "Video", url: URL(string: "https://example.com"), bundleID: nil)
            let b = other.add(name: "Video", url: URL(string: "https://example.org"), bundleID: nil)
            #expect(a.id != b.id)
            #expect(first.move("youtube", to: 0))
            #expect(other.move("netease", to: 0))
            #expect(AppLibrary(folder: folder).arrangement().first == "youtube")
            let reloaded = AppLibrary(profileID: "other", folder: folder)
            #expect(reloaded.arrangement().first == "netease")
            #expect(Array(reloaded.arrangement().suffix(2)) == [a.id, b.id])
            #expect(Array(AppLibrary(folder: folder).arrangement().suffix(2)) == [a.id, b.id])
        }
    }

    @Test func switchingProfilesPreservesFolderAndRestoresEachHomeOrder() throws {
        _ = NSApplication.shared
        try withFolder { folder in
            let profiles = ProfileStore(folder: folder)
            let second = profiles.add(named: "Second")
            let tv = TVController(library: AppLibrary(folder: folder), profiles: profiles)
            #expect(tv.moveApp("youtube", to: 0))
            tv.switchProfile(to: second.id)
            #expect(tv.profile.id == second.id)
            #expect(tv.library.storageFolder == folder)
            #expect(tv.appOrder.first != "youtube")
            #expect(tv.moveApp("netease", to: 0))
            tv.switchProfile(to: Profile.mainID)
            #expect(tv.appOrder.first == "youtube")
            #expect(tv.appOrder.firstIndex(of: "netease") != 0)
        }
    }

    @Test func sectionsRetainChildPanelsAndStatusFocus() throws {
        try withFolder { folder in
            let tv = TVController(library: AppLibrary(folder: folder))
            tv.settings = SettingsPanel(section: .apps, open: true, row: 1)
            tv.handleSettings(.select)
            #expect(tv.organizer != nil)
            tv.handleOrganizer(.back)
            #expect(tv.settings?.section == .apps && tv.settings?.row == 1)
            tv.settings?.row = 2
            tv.handleSettings(.select)
            #expect(tv.topShelfPreferences != nil)
            tv.handleTopShelfPreferences(.back)
            #expect(tv.settings?.section == .apps)
            #expect(SettingsPanel.Section.apps.rows == [.addApp, .arrangeApps, .topShelfPreferences, .movies])
            tv.setFocus(.status(.profile))
            #expect(tv.moveApp("movies", to: 0))
            #expect(tv.focus == .status(.profile))
        }
    }

    @Test func controlCenterDismissesSettingsChildrenButProtectsSetup() throws {
        _ = NSApplication.shared
        try withFolder { folder in
            let tv = TVController(library: AppLibrary(folder: folder))
            tv.settings = SettingsPanel(section: .apps, open: true, row: 1)
            tv.openOrganizer()
            tv.handle(.controlCenter)
            #expect(tv.controlCenter != nil)
            #expect(tv.settings == nil && tv.organizer == nil)
            tv.handle(.controlCenter)
            tv.setup = SetupFlow()
            tv.handle(.controlCenter)
            #expect(tv.setup != nil && tv.controlCenter == nil)
        }
    }

    @Test func anIconArrivingAfterASwitchIsEveryones() throws {
        _ = NSApplication.shared
        try withFolder { folder in
            let original = AppLibrary(folder: folder)
            let app = original.add(name: "Video", url: URL(string: "https://example.com"), bundleID: nil)
            // The icon arrives once another profile is watching.
            let active = AppLibrary(profileID: "second", folder: folder)
            let tv = TVController(library: active)
            let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
                NSColor.red.setFill(); NSBezierPath(rect: rect).fill(); return true
            }
            let tiff = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            tv.useIcon(png, for: app.id, in: original)
            #expect(FileManager.default.fileExists(atPath: original.iconFile(for: app.id).path))
            #expect(tv.services.first { $0.id == app.id }?.iconFile != nil, "the app is everyone's, icon and all")
            let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("apps.json"))) as? [String: Any])
            let added = try #require(saved["added"] as? [[String: Any]])
            #expect(added.first?["accent"] != nil)
            // Deleted for everyone: an icon arriving late doesn't bring it back.
            #expect(original.deleteForEveryone(app.id) == .deleted)
            tv.useIcon(png, for: app.id, in: original)
            #expect(!FileManager.default.fileExists(atPath: original.iconFile(for: app.id).path))
        }
    }
}
