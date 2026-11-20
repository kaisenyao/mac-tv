import Foundation
import Testing
@testable import MacTV

@Suite(.timeLimit(.minutes(1))) @MainActor
struct AppServicesTests {
    init() { AudioCoordinator.readVolume = { VolumeLevel(level: 50, muted: false) } }

    @Test func settingsGoToThePreferencesTheTVWasGiven() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "MacTV.AppServicesTests.\(UUID().uuidString)"
        let defaults = TestDefaults.named(suite)
        defer { TestDefaults.remove(suite) }

        let preferences = Preferences(defaults: defaults)
        var services = AppServices()
        services.preferences = preferences
        let tv = TVController(library: AppLibrary(folder: folder), services: services)
        let sharedSkip = Preferences.shared.autoSkip

        tv.autoSkip = !preferences.autoSkip
        #expect(defaults.object(forKey: "autoSkip") as? Bool == tv.autoSkip)
        #expect(Preferences.shared.autoSkip == sharedSkip)
        #expect(tv.preferences === preferences)
    }
}
