import AppKit
import Foundation
import Testing
@testable import MacTV

/// Where each profile keeps its things, the app contract and the switch order. Everything here is in a
/// folder of its own: other profiles' defaults are plists inside it and the Keychain is in memory.
@Suite(.timeLimit(.minutes(1))) @MainActor struct ProfileSpaceTests {
    init() {
        _ = NSApplication.shared
        AudioCoordinator.readVolume = { VolumeLevel(level: 50, muted: false) }
    }

    private func withFolder(_ body: (URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder)
    }

    // MARK: Spaces

    @Test func theFirstProfileKeepsEverythingWhereItWas() throws {
        try withFolder { folder in
            let spaces = ProfileSpaces.sandbox(folder)
            let main = spaces.space(for: Profile.mainID, epoch: 1)
            #expect(main.isMain)
            #expect(main.defaults === UserDefaults.standard)
            #expect(main.folder == folder)
            #expect(main.caches == folder.appendingPathComponent("Caches", isDirectory: true))
            #expect(main.keychainService("Mac TV Bilibili") == "Mac TV Bilibili")
            #expect(main.storage(for: "netease").folder == folder.appendingPathComponent("Apps/netease", isDirectory: true))
            // Nothing else is made for it.
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Profiles").path))
        }
    }

    @Test func otherProfilesHaveTheirOwnDefaultsFolderCachesAndKeychainNames() throws {
        try withFolder { folder in
            let spaces = ProfileSpaces.sandbox(folder)
            let other = spaces.space(for: "a1b2c3d4", epoch: 1)
            let key = "profileSpaceTest.\(UUID().uuidString)"
            other.defaults.set("theirs", forKey: key)
            #expect(other.defaults.string(forKey: key) == "theirs")
            #expect(UserDefaults.standard.object(forKey: key) == nil)
            #expect(spaces.suiteName(for: "a1b2c3d4").hasPrefix(folder.path))
            #expect(other.folder == folder.appendingPathComponent("Profiles/a1b2c3d4", isDirectory: true))
            #expect(other.caches == folder.appendingPathComponent("Caches/Profiles/a1b2c3d4", isDirectory: true))
            #expect(other.keychainService("Mac TV Bilibili") == "Mac TV Bilibili (a1b2c3d4)")
            #expect(ProfileSpaces.keychainService("Mac TV Bilibili", for: Profile.mainID) == "Mac TV Bilibili")
            #expect(ProfileSpaces.suitePrefix + "a1b2c3d4" == "local.couch.tv.profile.a1b2c3d4")
            other.defaults.removePersistentDomain(forName: spaces.suiteName(for: "a1b2c3d4"))
        }
    }

    @Test func enteringAProfileMakesItCurrentWithANewEpoch() throws {
        try withFolder { folder in
            let spaces = ProfileSpaces.sandbox(folder)
            let first = spaces.enter(Profile.mainID)
            let second = spaces.enter("second")
            #expect(second.epoch == first.epoch + 1)
            #expect(ProfileSpace.current.profileID == "second")
            #expect(!ProfileSpace.isCurrent(first.epoch))
            #expect(ProfileSpace.isCurrent(second.epoch))
            spaces.enter(Profile.mainID)
            #expect(ProfileSpace.current.isMain)
        }
    }

    @Test func removingAProfileDeletesItsDefaultsFilesCachesAndKeychainItems() throws {
        try withFolder { folder in
            let spaces = ProfileSpaces.sandbox(folder)
            let other = spaces.space(for: "gone", epoch: 1)
            let main = spaces.space(for: Profile.mainID, epoch: 1)
            other.defaults.set(true, forKey: "autoSkip")
            let file = other.storage(for: "netease").folder.appendingPathComponent("queue.json")
            try Data("[]".utf8).write(to: file)
            try FileManager.default.createDirectory(at: other.caches, withIntermediateDirectories: true)
            spaces.keychain.set(Data("theirs".utf8), service: other.keychainService("Mac TV Bilibili"), account: "1", label: "t")
            spaces.keychain.set(Data("mine".utf8), service: main.keychainService("Mac TV Bilibili"), account: "1", label: "t")

            spaces.remove("gone", keychainServices: ["Mac TV Bilibili"])

            #expect(UserDefaults(suiteName: spaces.suiteName(for: "gone"))?.object(forKey: "autoSkip") == nil)
            #expect(!FileManager.default.fileExists(atPath: other.folder.path))
            #expect(!FileManager.default.fileExists(atPath: other.caches.path))
            #expect(spaces.keychain.data(service: other.keychainService("Mac TV Bilibili"), account: "1") == nil)
            #expect(spaces.keychain.data(service: "Mac TV Bilibili", account: "1") == Data("mine".utf8))
            // The first profile is never removed.
            spaces.remove(Profile.mainID, keychainServices: ["Mac TV Bilibili"])
            #expect(FileManager.default.fileExists(atPath: folder.path))
            #expect(spaces.keychain.data(service: "Mac TV Bilibili", account: "1") != nil)
        }
    }

    @Test func aTestKeychainStaysInMemory() {
        let keychain = ProfileKeychain.inMemory()
        #expect(keychain.set(Data("a".utf8), service: "s", account: "1", label: "l"))
        #expect(keychain.set(Data("b".utf8), service: "s", account: "1", label: "l"))
        keychain.set(Data("c".utf8), service: "s", account: "2", label: "l")
        keychain.set(Data("d".utf8), service: "t", account: "1", label: "l")
        #expect(keychain.data(service: "s", account: "1") == Data("b".utf8))
        keychain.delete(service: "s", account: "1")
        #expect(keychain.data(service: "s", account: "1") == nil)
        keychain.deleteAll(service: "s")
        #expect(keychain.data(service: "s", account: "2") == nil)
        #expect(keychain.data(service: "t", account: "1") == Data("d".utf8))
        #expect(ProfileKeychain.inMemory().data(service: "t", account: "1") == nil)
    }

    // MARK: The app contract

    @Test func appsGetTheirDefaultsAndMigrateOncePerProfile() throws {
        try withFolder { folder in
            let spaces = ProfileSpaces.sandbox(folder)
            defer { spaces.enter(Profile.mainID) }
            VersionedApp.migrations = []
            spaces.enter("first")
            let registry = ProfileAppRegistry()
            let app = VersionedApp()
            registry.register(app)
            #expect(ProfileSpace.current.defaults.string(forKey: VersionedApp.greetingKey) == "hello")
            #expect(VersionedApp.migrations == ["first:1"])
            #expect(registry.keychainServices == ["Versioned Test"])

            spaces.enter("second")
            registry.profileChanged()
            #expect(ProfileSpace.current.defaults.string(forKey: VersionedApp.greetingKey) == "hello")
            #expect(ProfileSpace.current.defaults.integer(forKey: ProfileAppRegistry.versionKey(VersionedApp.appID)) == 2)
            spaces.enter("first")
            registry.profileChanged()
            #expect(VersionedApp.migrations == ["first:1", "second:1"])
            #expect(app.changes == ["second", "first"])
        }
    }

    // MARK: Mac TV

    @Test func theFirstProfileWatchingIsCurrentBeforeTheAppsAreBuilt() throws {
        try withFolder { folder in
            let tv = TVController(library: AppLibrary(folder: folder), profiles: ProfileStore(folder: folder))
            #expect(ProfileSpace.current.isMain)
            #expect(ProfileSpace.current.defaults === UserDefaults.standard)
            #expect(ProfileSpace.current.folder == folder)
            #expect(tv.spaces.folder == folder)
        }
        try withFolder { folder in
            let profiles = ProfileStore(folder: folder)
            let second = profiles.add(named: "Second")
            profiles.select(second.id)
            let tv = TVController(library: AppLibrary(profileID: second.id, folder: folder), profiles: profiles)
            #expect(ProfileSpace.current.profileID == second.id)
            #expect(tv.profile.id == second.id)
            tv.switchProfile(to: Profile.mainID)
        }
    }

    @Test func switchingSavesTheLastPersonsThingsBeforeTheNextPersonsSpaceIsCurrent() throws {
        try withFolder { folder in
            let profiles = ProfileStore(folder: folder)
            let second = profiles.add(named: "Second")
            let tv = TVController(library: AppLibrary(folder: folder), profiles: profiles)
            let app = RecordingApp()
            tv.profileApps.register(app)
            let before = ProfileSpace.current.epoch

            tv.switchProfile(to: second.id)
            #expect(app.events == ["leave:main", "enter:\(second.id)"])
            #expect(ProfileSpace.current.profileID == second.id)
            #expect(ProfileSpace.current.epoch > before)
            #expect(!ProfileSpace.isCurrent(before))

            tv.switchProfile(to: second.id)   // already watching: nothing happens
            #expect(app.events.count == 2)

            tv.switchProfile(to: Profile.mainID)
            #expect(app.events == ["leave:main", "enter:\(second.id)", "leave:\(second.id)", "enter:main"])
            #expect(ProfileSpace.current.defaults === UserDefaults.standard)
        }
    }
}

@MainActor private final class VersionedApp: ProfileApp {
    static let appID = "versioned-test"
    static let greetingKey = "profileSpaceTests.greeting"
    static var registeredDefaults: [String: Any] { [greetingKey: "hello"] }
    static var keychainServices: [String] { ["Versioned Test"] }
    static var dataVersion: Int { 2 }
    static var migrations: [String] = []
    static func migrate(_ storage: AppStorage, from version: Int) {
        migrations.append("\(storage.space.profileID):\(version)")
    }

    var changes: [String] = []
    func profileChanged() { changes.append(ProfileSpace.current.profileID) }
}

@MainActor private final class RecordingApp: ProfileApp {
    static let appID = "recording-test"
    var events: [String] = []
    func profileWillChange() { events.append("leave:\(ProfileSpace.current.profileID)") }
    func profileChanged() { events.append("enter:\(ProfileSpace.current.profileID)") }
}
