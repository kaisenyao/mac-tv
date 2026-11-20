import Foundation
import os
import Security

/// The only place Mac TV calls the Keychain (SecItem): profiles' sign-ins (ProfileKeychain), network share passwords
/// (ShareKeychain) and Jellyfin tokens (JellyfinKeychain) all come through here.
///
/// Under the tests (TestSandbox sets MACTV_KEYCHAIN to "memory" before any test runs) each of them keeps its items
/// in memory instead, and these refuse every call, so a test never reads, writes or deletes a real item, whatever
/// order the tests run in. The app always uses the real Keychain.
enum SystemKeychain {
    /// Under the tests: every Keychain user keeps its items in memory.
    static let inMemory = ProcessInfo.processInfo.environment["MACTV_KEYCHAIN"] == "memory"

    private static let refusedCalls = OSAllocatedUnfairLock(initialState: 0)
    /// Calls refused under the tests because they would have reached the real Keychain. A test checks it stays 0.
    static var refused: Int { refusedCalls.withLock { $0 } }

    static func copyMatching(_ query: [String: Any], _ result: inout CFTypeRef?) -> OSStatus {
        guard allowed() else { return errSecNotAvailable }
        return SecItemCopyMatching(query as CFDictionary, &result)
    }

    static func add(_ item: [String: Any]) -> OSStatus {
        guard allowed() else { return errSecNotAvailable }
        return SecItemAdd(item as CFDictionary, nil)
    }

    static func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        guard allowed() else { return errSecNotAvailable }
        return SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    @discardableResult
    static func delete(_ query: [String: Any]) -> OSStatus {
        guard allowed() else { return errSecNotAvailable }
        return SecItemDelete(query as CFDictionary)
    }

    private static func allowed() -> Bool {
        guard inMemory else { return true }
        refusedCalls.withLock { $0 += 1 }
        Log.app.error("Refused a Keychain call under the tests")
        return false
    }

    /// Items kept in memory under the tests, by a key each Keychain user makes from its own attributes.
    static func memoryStore() -> OSAllocatedUnfairLock<[String: Data]>? {
        inMemory ? OSAllocatedUnfairLock(initialState: [:]) : nil
    }
}
