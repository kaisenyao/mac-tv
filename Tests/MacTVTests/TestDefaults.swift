import Foundation

/// UserDefaults for a test that leave nothing behind on the Mac. A named suite lives in ~/Library/Preferences and
/// `removePersistentDomain` empties it but leaves its file; these are plist files in the test's temporary folder
/// instead, and `remove` empties and deletes them. UserDefaults.standard is one of these too, for the whole run
/// (Tests/TestSandbox/TestSandbox.m).
enum TestDefaults {
    private static let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("MacTVTests-defaults", isDirectory: true)

    /// Where the store named `name` is kept: pass this wherever a suite name is wanted.
    static func path(_ name: String) -> String {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(name + ".plist").path
    }

    /// The store for `name` (a fresh name per test, like "MacTVTests.<uuid>").
    static func named(_ name: String) -> UserDefaults {
        UserDefaults(suiteName: path(name))!
    }

    /// Empties the store and deletes its file. Takes the name given to `named`, or a path from `path`.
    static func remove(_ name: String) {
        let suite = name.hasPrefix("/") ? name : path(name)
        if let defaults = UserDefaults(suiteName: suite) {
            for key in (defaults.persistentDomain(forName: suite) ?? [:]).keys { defaults.removeObject(forKey: key) }
        }
        try? FileManager.default.removeItem(atPath: suite)
    }
}
