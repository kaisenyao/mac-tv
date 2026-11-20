import Foundation

/// What an app on Mac TV declares so that every profile gets its own copy of the app's data, the way each
/// user account on a Mac has its own. The built-in apps use it now; apps from a store later use the same one
/// and get the same separation without anything else to do.
///
/// An app keeps its settings in `AppStorage.defaults` (the profile's defaults, under the app's own key names),
/// its files in `AppStorage.folder` and its sign-ins under `AppStorage.keychainService(_:)`, always for
/// `ProfileSpace.current`, and reloads in place when `profileChanged()` is called.
@MainActor
protocol ProfileApp: AnyObject {
    /// The app's id on the home screen.
    static var appID: String { get }
    /// The settings a new profile starts with, registered into every profile's defaults.
    static var registeredDefaults: [String: Any] { get }
    /// The Keychain services (their first profile's names) the app keeps sign-ins under. Removing a profile
    /// deletes that profile's items under each of them.
    static var keychainServices: [String] { get }
    /// The shape of the app's saved data. When it goes up, `migrate(_:from:)` runs once in each profile.
    static var dataVersion: Int { get }
    static func migrate(_ storage: AppStorage, from version: Int)

    /// Someone else is about to start watching (`ProfileSpace.current` is still the last person's): stop
    /// what belongs to them and save what they were in the middle of.
    func profileWillChange()
    /// Someone else is watching now (`ProfileSpace.current` is theirs): drop the last person's state and
    /// reload this person's, in place.
    func profileChanged()
}

extension ProfileApp {
    static var registeredDefaults: [String: Any] { [:] }
    static var keychainServices: [String] { [] }
    static var dataVersion: Int { 1 }
    static func migrate(_ storage: AppStorage, from version: Int) {}
    func profileWillChange() {}

    /// This app's storage in the profile watching now.
    static var storage: AppStorage { ProfileSpace.current.storage(for: appID) }
}

/// The apps that keep data per profile, in the order they're told about a profile change.
@MainActor
final class ProfileAppRegistry {
    private(set) var apps: [any ProfileApp] = []

    /// Adds an app and gets the profile watching now ready for it.
    func register(_ app: any ProfileApp) {
        guard !apps.contains(where: { $0 === app }) else { return }
        apps.append(app)
        // UserDefaults keeps registered values for the whole process, in every suite, so registering once
        // gives every profile the app's defaults. They're never saved, so a profile reads the app's current
        // defaults until the person changes a setting.
        let defaults = type(of: app).registeredDefaults
        if !defaults.isEmpty { UserDefaults.standard.register(defaults: defaults) }
        migrate(type(of: app), in: .current)
    }

    /// The Keychain services every app uses, for removing a profile.
    var keychainServices: [String] { Array(Set(apps.flatMap { type(of: $0).keychainServices })).sorted() }

    /// The last person's space is still current: each app stops and saves what's theirs.
    func profileWillChange() {
        for app in apps { app.profileWillChange() }
    }

    /// The new profile's space is current: migrate each app's data there if it's older, then let each app reload.
    func profileChanged() {
        let space = ProfileSpace.current
        for app in apps { migrate(type(of: app), in: space) }
        for app in apps { app.profileChanged() }
    }

    static func versionKey(_ appID: String) -> String { "appDataVersion.\(appID)" }

    private func migrate(_ app: any ProfileApp.Type, in space: ProfileSpace) {
        let defaults = space.defaults
        // Data saved before apps had versions is version 1.
        let key = Self.versionKey(app.appID)
        let saved = defaults.object(forKey: key) as? Int ?? 1
        guard saved < app.dataVersion else { return }
        app.migrate(space.storage(for: app.appID), from: saved)
        defaults.set(app.dataVersion, forKey: key)
    }
}
