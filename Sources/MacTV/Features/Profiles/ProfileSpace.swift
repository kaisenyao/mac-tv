import Foundation
import os
import Security

/// Where one profile keeps its own things. Profiles work like the Mac's user accounts: the apps on the
/// home screen are everyone's, and everything else is the profile's own: each app's sign-ins, settings,
/// history and resume positions, the browser's tabs and history, and the personal Mac TV settings.
///
/// The first profile keeps everything where Mac TV has always kept it (UserDefaults.standard, the Mac TV
/// folder in Application Support, ~/Library/Caches/Mac TV and the Keychain names Mac TV has always used),
/// so nothing moves. Every other profile has its own defaults suite, folder, caches and Keychain names.
///
/// Device settings stay on UserDefaults.standard and the Mac TV folder for everyone: the display, power,
/// phone pairing, volume, updates, the Movies library and the apps everyone shares.
/// Sendable: everything in it is immutable, and UserDefaults is documented as thread-safe (this SDK doesn't mark it).
struct ProfileSpace: @unchecked Sendable {
    let profileID: String
    /// The first profile's are UserDefaults.standard; a component that was handed its own store (a test's)
    /// uses that one for the first profile instead.
    let defaults: UserDefaults
    /// The suite `defaults` comes from; nil for the first profile's UserDefaults.standard.
    let suiteName: String?
    let folder: URL
    let caches: URL
    let keychain: ProfileKeychain
    /// Goes up every time someone else starts watching. Work started under one profile checks
    /// `ProfileSpace.isCurrent(_:)` before it saves what it brings back, so it can't land in the next one's.
    let epoch: Int

    var isMain: Bool { profileID == Profile.mainID }

    /// The Keychain service an app keeps this profile's items under: the old name for the first profile.
    func keychainService(_ base: String) -> String { ProfileSpaces.keychainService(base, for: profileID) }

    /// One app's corner of this space.
    func storage(for appID: String) -> AppStorage { AppStorage(appID: appID, space: self) }

    // MARK: Who's watching now

    private static let state = OSAllocatedUnfairLock<ProfileSpace?>(initialState: nil)

    /// The profile watching now. Mac TV sets it before it builds its stores and changes it when someone
    /// else starts watching; until then it's the first profile in the usual places.
    static var current: ProfileSpace {
        state.withLock { state in
            if let state { return state }
            let first = ProfileSpaces.live.space(for: Profile.mainID, epoch: 0)
            state = first
            return first
        }
    }

    /// Still the profile that was watching when `epoch` was read.
    static func isCurrent(_ epoch: Int) -> Bool { current.epoch == epoch }

    fileprivate static func enter(_ make: @Sendable (Int) -> ProfileSpace) -> ProfileSpace {
        state.withLock { state in
            let next = make((state?.epoch ?? 0) + 1)
            state = next
            return next
        }
    }
}

/// Where every profile's space is: the real places for Mac TV, or a test's own folder, where the other
/// profiles' defaults are plist files inside it and the Keychain is kept in memory.
struct ProfileSpaces: Sendable {
    /// The first profile's folder; the others are in Profiles/<id> inside it.
    let folder: URL
    /// The first profile's caches; the others are in Profiles/<id> inside it.
    let caches: URL
    let keychain: ProfileKeychain
    private let sandboxed: Bool
    /// Where a removed profile's folder (its photo, its apps' files) goes: the Mac's Trash, or a test's own.
    let trash: MacTrash.Mover

    static var live: ProfileSpaces {
        ProfileSpaces(folder: AppFolder.url, caches: BrowserCache.root, keychain: .system, sandboxed: false,
                      trash: MacTrash.system)
    }

    /// Everything inside `folder`, nothing in the Mac's own preferences, caches, Keychain or Trash. The first
    /// profile's defaults are still UserDefaults.standard, as for every test.
    static func sandbox(_ folder: URL) -> ProfileSpaces {
        ProfileSpaces(folder: folder, caches: folder.appendingPathComponent("Caches", isDirectory: true),
                      keychain: .inMemory(), sandboxed: true, trash: MacTrash.folder(folder))
    }

    static let suitePrefix = "local.couch.tv.profile."

    static func keychainService(_ base: String, for id: String) -> String {
        id == Profile.mainID ? base : "\(base) (\(id))"
    }

    func folder(for id: String) -> URL {
        id == Profile.mainID ? folder : folder.appendingPathComponent("Profiles/\(id)", isDirectory: true)
    }

    func caches(for id: String) -> URL {
        id == Profile.mainID ? caches : caches.appendingPathComponent("Profiles/\(id)", isDirectory: true)
    }

    /// The defaults suite of a profile after the first. A test's is a plist in the profile's folder.
    func suiteName(for id: String) -> String {
        sandboxed ? folder(for: id).appendingPathComponent("Preferences.plist").path : Self.suitePrefix + id
    }

    func defaults(for id: String) -> UserDefaults {
        guard id != Profile.mainID else { return .standard }
        // A test's plist needs its folder to be there; the real folders are made when something is saved in them.
        if sandboxed { try? FileManager.default.createDirectory(at: folder(for: id), withIntermediateDirectories: true) }
        // Only the global domain and the app's own bundle identifier are refused, and these are neither.
        return UserDefaults(suiteName: suiteName(for: id))!
    }

    func space(for id: String, epoch: Int) -> ProfileSpace {
        ProfileSpace(profileID: id, defaults: defaults(for: id), suiteName: id == Profile.mainID ? nil : suiteName(for: id),
                     folder: folder(for: id), caches: caches(for: id), keychain: keychain, epoch: epoch)
    }

    /// Makes `id` the profile watching now (`ProfileSpace.current`), with a new epoch.
    @discardableResult
    func enter(_ id: String) -> ProfileSpace {
        let spaces = self
        return ProfileSpace.enter { spaces.space(for: id, epoch: $0) }
    }

    /// Deletes everything a removed profile kept: its defaults suite, folder, caches and the Keychain items
    /// under each of `keychainServices`. The first profile is never removed.
    func remove(_ id: String, keychainServices: [String]) {
        guard id != Profile.mainID, !id.isEmpty, !id.contains("/") else { return }
        let name = suiteName(for: id)
        if let defaults = UserDefaults(suiteName: name) {
            defaults.removePersistentDomain(forName: name)
            // A plist suite (a test's) isn't cleared that way; removing its keys one by one is. A key that's
            // only in the global domain isn't touched: removing works on the suite's own domain.
            for key in defaults.dictionaryRepresentation().keys { defaults.removeObject(forKey: key) }
        }
        // Emptied, a suite still leaves its (empty) file in ~/Library/Preferences. A test's is in the folder below.
        if !sandboxed, let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: library.appendingPathComponent("Preferences/\(name).plist"))
        }
        // Its folder holds what the person made or chose (their photo, their apps' files): it goes to the Trash,
        // never straight away; if it can't, it stays. Caches are only caches.
        if FileManager.default.fileExists(atPath: folder(for: id).path) {
            Log.app.attempt("Moving a removed profile's folder to the Trash") { _ = try trash(folder(for: id)) }
        }
        try? FileManager.default.removeItem(at: caches(for: id))
        for base in keychainServices { keychain.deleteAll(service: Self.keychainService(base, for: id)) }
    }
}

/// One app's corner of a profile's space: its settings in the profile's defaults (under the app's own key
/// names), its files in Apps/<appID> in the profile's folder, and its Keychain items under the profile's names.
struct AppStorage: @unchecked Sendable {
    let appID: String
    let space: ProfileSpace

    var defaults: UserDefaults { space.defaults }

    /// Apps/<appID> in the profile's folder, made the first time it's asked for.
    var folder: URL {
        let folder = space.folder.appendingPathComponent("Apps/\(appID)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func keychainService(_ base: String) -> String { space.keychainService(base) }
    var keychain: ProfileKeychain { space.keychain }
}

/// Generic passwords in the login Keychain, or, for tests, in memory.
final class ProfileKeychain: Sendable {
    /// The login Keychain; in memory under the tests (SystemKeychain).
    static let system = ProfileKeychain(memory: SystemKeychain.inMemory ? OSAllocatedUnfairLock(initialState: [:]) : nil)
    static func inMemory() -> ProfileKeychain { ProfileKeychain(memory: OSAllocatedUnfairLock(initialState: [:])) }

    private struct Key: Hashable, Sendable { let service: String, account: String }
    private let memory: OSAllocatedUnfairLock<[Key: Data]>?

    private init(memory: OSAllocatedUnfairLock<[Key: Data]>?) { self.memory = memory }

    func data(service: String, account: String) -> Data? {
        if let memory { return memory.withLock { $0[Key(service: service, account: account)] } }
        var query = Self.query(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SystemKeychain.copyMatching(query, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Adds or replaces an item. True once it's saved.
    @discardableResult
    func set(_ data: Data, service: String, account: String, label: String) -> Bool {
        if let memory {
            memory.withLock { $0[Key(service: service, account: account)] = data }
            return true
        }
        let query = Self.query(service: service, account: account)
        let update = [kSecValueData as String: data, kSecAttrLabel as String: label] as [String: Any]
        let status = SystemKeychain.update(query, update)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = label
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SystemKeychain.add(item) == errSecSuccess
    }

    func delete(service: String, account: String) {
        if let memory { memory.withLock { _ = $0.removeValue(forKey: Key(service: service, account: account)) }; return }
        SystemKeychain.delete(Self.query(service: service, account: account))
    }

    /// Deletes every item under a service.
    func deleteAll(service: String) {
        if let memory { memory.withLock { $0 = $0.filter { $0.key.service != service } }; return }
        let query = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as [String: Any]
        SystemKeychain.delete(query)
    }

    private static func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}
