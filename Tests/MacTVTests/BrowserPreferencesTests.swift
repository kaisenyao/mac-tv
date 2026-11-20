import Foundation
import Testing
@testable import MacTV

@Suite(.timeLimit(.minutes(1)))
struct BrowserPreferencesTests {
    @Test
    func choicesArePersistedPerProfileAndDefaultToBuiltIn() throws {
        let suite = "MacTV.BrowserPreferencesTests.\(UUID().uuidString)"
        let defaults = TestDefaults.named(suite)
        defer { TestDefaults.remove(suite) }
        let preferences = BrowserPreferences(defaults: defaults)
        #expect(preferences.choice(for: "main") == .embedded)
        preferences.setChoice(.brave, for: "main")
        preferences.setChoice(.embedded, for: "other")
        let reloaded = BrowserPreferences(defaults: defaults)
        #expect(reloaded.choice(for: "main") == .brave)
        #expect(reloaded.choice(for: "other") == .embedded)
        #expect(reloaded.choice(for: "new") == .embedded)
    }
}
