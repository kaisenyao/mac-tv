import AppKit
import Foundation
import Testing
@testable import MacTV

/// Each profile's own Mac TV settings, Top Shelf choices and remote shortcuts, with this Mac's settings
/// shared. The first profile keeps reading and writing where it always has.
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct ProfileSettingsTests {
    init() {
        _ = NSApplication.shared
        AudioCoordinator.readVolume = { VolumeLevel(level: 50, muted: false) }
    }

    /// A folder of its own and a plist-backed defaults inside it standing in for the first profile's.
    private func withFolder(_ body: (URL, UserDefaults) throws -> Void) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            ProfileSpaces.sandbox(folder).enter(Profile.mainID)
            try? FileManager.default.removeItem(at: folder)
        }
        let defaults = try #require(UserDefaults(suiteName: folder.appendingPathComponent("main.plist").path))
        try body(folder, defaults)
    }

    // MARK: Preferences

    @Test func personalSettingsArePerProfileAndTheMacsAreShared() throws {
        try withFolder { folder, defaults in
            let spaces = ProfileSpaces.sandbox(folder)
            let main = spaces.space(for: Profile.mainID, epoch: 1), other = spaces.space(for: "other", epoch: 2)
            let preferences = Preferences(defaults: defaults)
            preferences.autoSkip = false
            preferences.saverClock = false
            preferences.twentyFourHourTime = true
            preferences.navigationSoundVolume = 0.2
            preferences.keepMacAwake = false
            #expect(defaults.object(forKey: "autoSkip") as? Bool == false)
            #expect(defaults.object(forKey: "twentyFourHourTime") as? Bool == true)

            // A new profile starts with the defaults, and the Mac's settings are the same.
            preferences.use(other)
            #expect(preferences.autoSkip && preferences.saverClock && preferences.navigationSoundVolume == 0.7)
            #expect(preferences.twentyFourHourTime == FlipClockTime.systemTwentyFour)
            #expect(!preferences.keepMacAwake)
            #expect(other.defaults.object(forKey: "autoSkip") == nil)   // reading them in saves nothing

            preferences.autoNext = false
            preferences.saverWallpaper = "flipClock"
            preferences.lidOverride = true
            #expect(other.defaults.object(forKey: "autoNext") as? Bool == false)
            #expect(other.defaults.string(forKey: "saverWallpaper") == "flipClock")
            #expect(defaults.object(forKey: "autoNext") == nil && defaults.string(forKey: "saverWallpaper") == nil)
            #expect(defaults.bool(forKey: "lidOverride") && other.defaults.object(forKey: "lidOverride") == nil)

            // Back to the first profile: everything as it was, and the Mac's change is still there.
            preferences.use(main)
            #expect(!preferences.autoSkip && preferences.autoNext && !preferences.saverClock)
            #expect(preferences.saverWallpaper == nil && preferences.twentyFourHourTime && preferences.navigationSoundVolume == 0.2)
            #expect(preferences.lidOverride && !preferences.keepMacAwake)
        }
    }

    @Test func theScreenSaverReadsThePersonWatchingsSettings() throws {
        try withFolder { folder, _ in
            let spaces = ProfileSpaces.sandbox(folder)
            let shared = Preferences.shared
            let before = (shared.saverClock, shared.saverDelay, UserDefaults.standard.object(forKey: "saverClock"))
            shared.use(spaces.space(for: "other", epoch: 1))
            defer { shared.use(spaces.space(for: Profile.mainID, epoch: 1)) }
            #expect(ScreenSaverSettings.showClock && ScreenSaverSettings.delayMinutes == 5)
            ScreenSaverSettings.showClock = false
            ScreenSaverSettings.delayMinutes = 15
            #expect(!ScreenSaverSettings.showClock && ScreenSaverSettings.delayMinutes == 15)
            shared.use(spaces.space(for: Profile.mainID, epoch: 1))
            #expect(shared.saverClock == before.0 && shared.saverDelay == before.1)
            #expect(UserDefaults.standard.object(forKey: "saverClock") as? Bool == before.2 as? Bool)
        }
    }

    @Test func switchingProfilesOnTheTVSwapsTheirSettings() throws {
        try withFolder { folder, defaults in
            var services = AppServices()
            services.preferences = Preferences(defaults: defaults)
            let profiles = ProfileStore(folder: folder)
            let second = profiles.add(named: "Second")
            let tv = TVController(library: AppLibrary(folder: folder), profiles: profiles, services: services)
            tv.autoSkip = false
            tv.switchProfile(to: second.id)
            #expect(tv.autoSkip)
            tv.autoNext = false
            tv.switchProfile(to: Profile.mainID)
            #expect(!tv.autoSkip && tv.autoNext)
            #expect(defaults.object(forKey: "autoSkip") as? Bool == false)

            // Starting Mac TV with the second profile watching reads theirs from the start.
            profiles.select(second.id)
            let again = TVController(library: AppLibrary(profileID: second.id, folder: folder), profiles: profiles,
                                     services: services)
            #expect(again.autoSkip && !again.autoNext)
            again.switchProfile(to: Profile.mainID)
        }
    }

    // MARK: Top Shelf

    @Test func topShelfChoicesArePerProfile() throws {
        try withFolder { folder, _ in
            let spaces = ProfileSpaces.sandbox(folder)
            let standard = UserDefaults.standard
            let keys = ["bilibiliShelf", "youtubeShelf", "neteaseShelfSources", "neteaseShelfNowPlaying", "dedaoShelfNewBooks",
                        "dedaoShelfHiddenCategories"]
            let before = keys.map { standard.object(forKey: $0) as? NSObject }
            let other = spaces.enter("other")
            #expect(BiliShelfSource.current == .following && YouTubeShelfSource.current == .recommended)
            #expect(NeteaseShelfSource.selected == NeteaseShelfSource.defaults && NeteaseShelfSource.showsNowPlaying)
            #expect(DedaoShelfSource.showsNewBooks && DedaoShelfSource.hiddenCategories.isEmpty)

            BiliShelfSource.current = .live
            YouTubeShelfSource.current = .history
            NeteaseShelfSource.selected = [.hot]
            NeteaseShelfSource.showsNowPlaying = false
            DedaoShelfSource.showsNewBooks = false
            DedaoShelfSource.hiddenCategories = ["历史"]
            #expect(other.defaults.string(forKey: "bilibiliShelf") == "live")
            #expect(other.defaults.string(forKey: "youtubeShelf") == "history")
            #expect(keys.map { standard.object(forKey: $0) as? NSObject } == before)

            spaces.enter(Profile.mainID)
            #expect(BiliShelfSource.current.rawValue == (before[0] as? String ?? "following"))
            spaces.enter("other")
            #expect(BiliShelfSource.current == .live && YouTubeShelfSource.current == .history)
            #expect(NeteaseShelfSource.selected == [.hot] && !NeteaseShelfSource.showsNowPlaying)
            #expect(!DedaoShelfSource.showsNewBooks && DedaoShelfSource.hiddenCategories == ["历史"])
        }
    }

    // MARK: Remote shortcuts

    @Test func remoteShortcutsArePerProfile() throws {
        try withFolder { folder, defaults in
            let spaces = ProfileSpaces.sandbox(folder)
            let remote = RemoteCoordinator()
            remote.shortcutDefaults = defaults
            var mine = remote.shortcutChoice
            let refused = mine.choose(["files", "screensaver"], for: RemoteShortcuts.home)
            let named = mine.chooseAppleShortcut("Movie Night")
            #expect(refused == nil && named)
            remote.shortcutChoice = mine

            let other = spaces.space(for: "other", epoch: 1)
            remote.shortcutsProfileChanged(other)
            #expect(remote.shortcutChoice == RemoteShortcutChoice())
            var theirs = remote.shortcutChoice
            let refusedTheirs = theirs.choose(["screensaver"], for: RemoteShortcuts.home)
            #expect(refusedTheirs == nil)
            remote.shortcutChoice = theirs
            #expect(RemoteShortcutChoice.load(from: other.defaults).picked(in: RemoteShortcuts.home) == ["screensaver"])
            #expect(RemoteShortcutChoice.load(from: defaults) == mine)

            remote.shortcutsProfileChanged(spaces.space(for: Profile.mainID, epoch: 2))
            #expect(remote.shortcutChoice == mine)
            #expect(remote.shortcutChoice.appleShortcut == "Movie Night")
        }
    }
}
