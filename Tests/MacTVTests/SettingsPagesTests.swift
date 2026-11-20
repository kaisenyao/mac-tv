import AppKit
import Foundation
import Testing
@testable import MacTV

/// Settings' pages and the pages below them: Remotes and Devices, Profiles, Screen Saver's cards, Movies.
@Suite(.timeLimit(.minutes(1))) @MainActor struct SettingsPagesTests {
    init() {
        _ = NSApplication.shared
        AudioCoordinator.readVolume = { VolumeLevel(level: 50, muted: false) }
    }

    private func withTV(_ body: (TVController, URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tv = TVController(library: AppLibrary(folder: folder), profiles: ProfileStore(folder: folder))
        tv.remoteCoordinator.pairingStore = PairingStore(folder: folder)
        try body(tv, folder)
    }

    private func rows(_ tv: TVController) -> [SettingsPanel.Row] { tv.settingsRows(tv.settings ?? SettingsPanel()) }

    // MARK: Pages below pages

    @Test func pagesOpenFromARowAndBackLandsOnIt() throws {
        try withTV { tv, _ in
            tv.settings = SettingsPanel(section: .remotes)
            tv.handleSettings(.select)
            #expect(tv.settings?.section == .remotes && tv.settings?.open == true)
            #expect(rows(tv) == [.siriRemote, .iPhone, .otherControllers])

            tv.handleSettings(.move(.down))
            tv.handleSettings(.select)
            #expect(tv.settings?.page == .iPhone && tv.settings?.row == 0)
            #expect(rows(tv) == [.phoneAccess])
            // Phone Access is a value: right is Guest, left Full Access, and neither leaves the page.
            tv.handleSettings(.move(.right))
            #expect(tv.pairingGuest && tv.settings?.page == .iPhone)
            tv.handleSettings(.move(.left))
            #expect(!tv.pairingGuest && tv.settings?.page == .iPhone)

            tv.handleSettings(.back)
            #expect(tv.settings?.page == nil && tv.settings?.row == 1)
            // Right opens a row with ›, a page deeper.
            tv.handleSettings(.move(.down))
            tv.handleSettings(.move(.right))
            #expect(tv.settings?.page == .otherControllers)
            tv.handleSettings(.back)
            #expect(tv.settings?.page == nil && tv.settings?.row == 2)
            // Left on a row with nothing to adjust goes back too.
            tv.handleSettings(.move(.left))
            #expect(tv.settings?.open == false && tv.settings?.section == .remotes)
        }
    }

    @Test func siriRemoteAndGameControllerPages() throws {
        let wasConnected = SiriRemoteStatus.shared.connected, supported = SiriRemoteSupport.available
        defer { SiriRemoteStatus.shared.connected = wasConnected; SiriRemoteSupport.available = supported }
        try withTV { tv, _ in
            SiriRemoteSupport.available = true
            SiriRemoteStatus.shared.connected = false
            tv.settings = SettingsPanel(section: .remotes, open: true)
            tv.handleSettings(.select)
            #expect(tv.settings?.page == .siriRemote)
            // No remote here: nothing to allow yet.
            #expect(rows(tv) == [.remoteStatus, .bluetooth])
            // The one hint: how to pair, only while no Siri Remote is connected.
            #expect(tv.settingsFootnote(try #require(tv.settings)) != nil)
            SiriRemoteStatus.shared.connected = true
            #expect(tv.settingsFootnote(try #require(tv.settings)) == nil)
            let root = SettingsPanel(section: .remotes, open: true)
            #expect(tv.settingsContent(.siriRemote, panel: root, focused: false).value?.hasPrefix("Connected") == true)

            tv.handleSettings(.back)
            tv.settings?.row = 2
            tv.handleSettings(.select)
            #expect(tv.settings?.page == .otherControllers)
            #expect(rows(tv) == [.controller, .bluetooth])
            #expect(tv.settingsContent(.controller, panel: try #require(tv.settings), focused: true).value == "Not Connected")
            #expect(tv.settingsContent(.otherControllers, panel: root, focused: false).value == "Not Connected")
            tv.controller = ControllerInfo(name: "DualSense", battery: 0.7)
            let page = try #require(tv.settings)
            #expect(rows(tv) == [.controller, .controllerBattery, .bluetooth])
            #expect(tv.settingsContent(.controller, panel: page, focused: true).value == "DualSense")
            #expect(tv.settingsContent(.controllerBattery, panel: page, focused: false).value == "70%")
            #expect(tv.settingsContent(.otherControllers, panel: root, focused: false).value == "DualSense · 70%")
        }
    }

    @Test func siriRemoteBatteryComesFromARegistryNumber() {
        #expect(SiriRemoteBattery.percent(in: [nil, NSNumber(value: 87)]) == 87)
        #expect(SiriRemoteBattery.percent(in: [87 as Int]) == 87)
        #expect(SiriRemoteBattery.percent(in: [NSNumber(value: true)]) == nil)   // a flag, not a charge
        #expect(SiriRemoteBattery.percent(in: [NSNumber(value: 150), NSNumber(value: 0.87)]) == nil)
        #expect(SiriRemoteBattery.percent(in: ["87"]) == nil)
        #expect(SiriRemoteBattery.percent(in: []) == nil)
    }

    // MARK: Paired phones

    @Test func iPhoneListsPairedPhonesAndRemovesOneAfterAsking() throws {
        let wasPaired = UserDefaults.standard.bool(forKey: "phonePaired")
        defer { UserDefaults.standard.set(wasPaired, forKey: "phonePaired") }
        try withTV { tv, _ in
            let store = tv.remoteCoordinator.pairingStore
            let kitchen = try store.issue(name: "Kitchen iPhone", guest: false)
            let guest = try store.issue(name: "Guest", guest: true)
            let root = SettingsPanel(section: .remotes, open: true)
            #expect(tv.settingsContent(.iPhone, panel: root, focused: false).value == "2 Paired")
            _ = store.authenticate(guest)   // the guest's remote page just asked for the TV's state
            #expect(tv.settingsContent(.iPhone, panel: root, focused: false).value == "1 Connected")

            tv.settings = SettingsPanel(section: .remotes, open: true, row: 1)
            tv.handleSettings(.select)
            let ids = store.activeDevices().map(\.id)
            #expect(rows(tv) == [.phoneAccess] + ids.map { .pairedDevice($0) })
            #expect(SettingsPanel.Row.pairedDevice(ids[0]).group == "PAIRED DEVICES")

            tv.handleSettings(.move(.down))
            tv.handleSettings(.select)
            #expect(tv.settings?.page == .pairedDevice(ids[0]))
            #expect(rows(tv) == [.removePairedDevice])
            tv.handleSettings(.select)
            // Remove Device asks first, with Cancel focused.
            let asking = try #require(tv.settings)
            #expect(asking.page == .confirmRemoval(.removePairedDevice) && rows(tv) == [.cancelRemoval, .acceptRemoval])
            #expect(asking.row == 0 && store.activeDevices().count == 2)
            #expect(tv.settingsHero(asking).title == "Remove “Kitchen iPhone”?")
            #expect(tv.settingsContent(.acceptRemoval, panel: asking, focused: true).title == "Remove Device")
            tv.handleSettings(.move(.down))
            tv.handleSettings(.select)
            // The same store the remote server checks: the phone is refused from now on.
            #expect(store.authenticate(kitchen) == nil)
            #expect(store.authenticate(guest) != nil)
            #expect(tv.settings?.page == .iPhone && rows(tv) == [.phoneAccess, .pairedDevice(ids[1])])

            tv.settings?.row = 1
            tv.handleSettings(.select)
            tv.handleSettings(.select)
            tv.handleSettings(.move(.down))
            tv.handleSettings(.select)
            #expect(store.activeDevices().isEmpty)
            #expect(rows(tv) == [.phoneAccess] && tv.settings?.row == 0)
            #expect(!tv.phonePaired)
        }
    }

    @Test func aPhoneCountsAsConnectedWhileItKeepsAsking() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var clock = Date(timeIntervalSince1970: 1_000)
        let store = PairingStore(folder: folder, now: { clock })
        let token = try store.issue(name: "iPhone", guest: false)
        #expect(store.connectedCount() == 0)
        _ = store.authenticate(token)
        #expect(store.connectedCount() == 1)
        clock = clock.addingTimeInterval(16)
        #expect(store.connectedCount() == 0)
    }

    // MARK: Connect a Remote

    @Test func connectARemoteIsTheRemotesPagesOnTheirOwnSheet() throws {
        try withTV { tv, _ in
            tv.openSettings()   // underneath: presses go to the sheet on top
            tv.pairing = true
            #expect(tv.connectRemote == .connect)
            let connect = tv.connectRemote
            #expect(tv.settingsRows(connect) == tv.settingsRows(SettingsPanel(section: .remotes, open: true)))
            #expect(tv.settingsHero(connect).title == "Connect a Remote")

            // Focus moving is a change to the sheets, which is what plays the move tick.
            let firstPage = tv.sheets.connectRemote
            tv.handlePairing(.move(.down))
            #expect(tv.sheets.connectRemote != firstPage)
            tv.handlePairing(.select)
            #expect(tv.connectRemote.page == .iPhone)
            #expect(tv.settings == SettingsPanel())
            tv.handlePairing(.back)
            #expect(tv.pairing && tv.connectRemote.page == nil && tv.connectRemote.row == 1)
            // Left has nowhere to go on the first page; Back closes the sheet.
            tv.handlePairing(.move(.left))
            #expect(tv.pairing)
            tv.handlePairing(.back)
            #expect(!tv.pairing && tv.settings != nil)

            // It opens on its first page again.
            tv.pairing = true
            #expect(tv.connectRemote == .connect)
        }
    }

    // MARK: Profiles

    @Test func profilesListsEveryoneThenAddProfile() throws {
        try withTV { tv, _ in
            let second = tv.profiles.add(named: "Second")
            tv.settings = SettingsPanel(section: .profiles)
            tv.handleSettings(.select)
            #expect(tv.profilePicker == nil)   // a page in Settings, not "Who's Watching?"
            #expect(rows(tv) == [.profile(Profile.mainID), .profile(second.id), .addProfile])
            let panel = try #require(tv.settings)
            #expect(tv.settingsContent(.profile(Profile.mainID), panel: panel, focused: false).checked)
            #expect(!tv.settingsContent(.profile(second.id), panel: panel, focused: false).checked)

            // The main profile, watching now: no Switch, no Remove.
            tv.handleSettings(.select)
            #expect(rows(tv) == [.profileName, .profilePhoto])
            tv.handleSettings(.back)
            tv.handleSettings(.move(.down))
            tv.handleSettings(.select)
            #expect(rows(tv) == [.profileName, .profilePhoto, .switchProfile, .removeProfile])
        }
    }

    @Test func addProfileTypesANameAndStaysInSettings() throws {
        try withTV { tv, folder in
            tv.settings = SettingsPanel(section: .profiles, open: true, row: 1)
            tv.handleSettings(.select)
            #expect(tv.settings?.typing == true && tv.settings?.typed == "")
            tv.handleSettings(.text("Bo"))
            tv.handleSettings(.move(.down))   // down to Create Profile
            #expect(tv.settings?.row == 1 && tv.settings?.typing == false)
            tv.handleSettings(.select)
            let added = try #require(tv.profiles.all.first { $0.name == "Bo" })
            #expect(tv.profile.id == Profile.mainID)
            #expect(tv.settings?.typing == false && tv.settings?.page == nil)
            #expect(rows(tv)[tv.settings?.row ?? 0] == .profile(added.id))
            #expect(ProfileStore(folder: folder).all.contains { $0.id == added.id && $0.name == "Bo" })

            // Back while typing leaves without adding.
            tv.settings?.row = rows(tv).count - 1
            tv.handleSettings(.select)
            tv.handleSettings(.text("Nope"))
            tv.handleSettings(.back)
            #expect(!tv.profiles.all.contains { $0.name == "Nope" })
            #expect(tv.settings?.page == nil && rows(tv)[tv.settings?.row ?? 0] == .addProfile)
        }
    }

    @Test func renameIsSaved() throws {
        try withTV { tv, folder in
            let second = tv.profiles.add(named: "Second")
            tv.settings = SettingsPanel(section: .profiles, open: true, row: 1)
            tv.handleSettings(.select)
            tv.handleSettings(.select)
            #expect(tv.settings?.page == .profileName(second.id) && tv.settings?.typed == "Second")
            #expect(tv.settings?.caret == 6)   // after the name
            for _ in 0..<6 { tv.handleSettings(.deleteBackward) }
            tv.handleSettings(.text("Ann\n"))
            #expect(tv.settings?.page == .profile(second.id) && tv.settings?.row == 0)
            #expect(tv.profiles.all.first { $0.id == second.id }?.name == "Ann")
            #expect(ProfileStore(folder: folder).all.first { $0.id == second.id }?.name == "Ann")
            // No colour to choose: a profile keeps the colour it was given.
            #expect(!rows(tv).contains { "\($0)".contains("Color") })

            // Renaming the profile watching now updates it everywhere it shows.
            tv.renameProfile(Profile.mainID, to: "Me Too")
            #expect(tv.profile.name == "Me Too")
        }
    }

    @Test func switchToThisProfileSwitchesLikeThePicker() throws {
        try withTV { tv, _ in
            let second = tv.profiles.add(named: "Second")
            tv.settings = SettingsPanel(section: .profiles, open: true, row: 1)
            tv.handleSettings(.select)
            tv.activateSetting(.switchProfile)
            #expect(tv.profile.id == second.id)
            #expect(tv.settings == nil)
            tv.switchProfile(to: Profile.mainID)   // the next tests expect the first profile's settings
        }
    }

    @Test func removeProfileAsksFirstThenRemovesItsAppsAndReturns() throws {
        try withTV { tv, folder in
            let second = tv.profiles.add(named: "Second")
            let apps = folder.appendingPathComponent("apps-\(second.id).json")
            try Data("[]".utf8).write(to: apps)
            tv.settings = SettingsPanel(section: .profiles, open: true, row: 1)
            tv.handleSettings(.select)
            tv.settings?.row = 3
            tv.handleSettings(.select)
            #expect(tv.settings?.page == .confirmRemoval(.removeProfile) && tv.settings?.row == 0)
            #expect(tv.settingsHero(try #require(tv.settings)).title == "Remove “Second”?")
            // Cancel has focus: a press goes back to the profile, on Remove Profile, and removes nothing.
            tv.handleSettings(.select)
            #expect(tv.settings?.page == .profile(second.id) && tv.settings?.row == 3 && tv.profiles.all.count == 2)
            tv.handleSettings(.select)
            tv.handleSettings(.move(.down))
            tv.handleSettings(.select)
            #expect(tv.profiles.all.map(\.id) == [Profile.mainID])
            #expect(!FileManager.default.fileExists(atPath: apps.path))
            #expect(tv.settings?.page == nil && tv.settings?.section == .profiles)
            #expect(rows(tv)[tv.settings?.row ?? 0] == .addProfile)
        }
    }

    @Test func whosWatchingAsksBeforeRemovingAProfile() throws {
        try withTV { tv, _ in
            _ = tv.profiles.add(named: "Second")
            tv.profilePicker = ProfilePicker(index: 1)
            tv.handleProfiles(.move(.down))
            tv.handleProfiles(.select)
            #expect(tv.profilePicker?.confirmingRemove == true && tv.profilePicker?.onConfirm == false)
            // Cancel has focus: back on the Remove button, and nothing is removed.
            tv.handleProfiles(.select)
            #expect(tv.profilePicker?.confirmingRemove == false && tv.profilePicker?.onRemove == true)
            #expect(tv.profiles.all.count == 2)
            tv.handleProfiles(.select)
            tv.handleProfiles(.move(.down))
            tv.handleProfiles(.select)
            #expect(tv.profiles.all.map(\.id) == [Profile.mainID] && tv.profilePicker == ProfilePicker(index: 0))
        }
    }

    @Test func removingTheProfileWatchingFallsBackToTheFirst() throws {
        try withTV { tv, _ in
            let second = tv.profiles.add(named: "Second")
            tv.switchProfile(to: second.id)
            tv.removeProfile(second.id)
            #expect(tv.profile.id == Profile.mainID)
            #expect(tv.profiles.current.id == Profile.mainID)
        }
    }

    // MARK: Screen Saver's cards

    private func withWallpaper(_ start: ScreenSaverSettings.Wallpaper, _ body: () throws -> Void) rethrows {
        let saved = (Preferences.shared.saverWallpaper, Preferences.shared.saverClock)
        defer { Preferences.shared.saverWallpaper = saved.0; Preferences.shared.saverClock = saved.1 }
        ScreenSaverSettings.wallpaper = start
        try body()
    }

    @Test func movingAlongTheTypesDoesNotChooseOne() throws {
        try withTV { tv, _ in
            withWallpaper(.photos) {
                tv.settings = SettingsPanel(section: .screenSaver, open: true)
                #expect(tv.settings?.card == nil)   // on the chosen card
                tv.handleSettings(.move(.right))
                tv.handleSettings(.move(.right))
                #expect(ScreenSaverSettings.wallpaper == .photos)
                #expect(tv.settings?.card == 3 && tv.settings?.row == 0)
                tv.handleSettings(.move(.right))           // the last card: stays
                #expect(tv.settings?.card == 3)
                tv.handleSettings(.move(.left))
                #expect(tv.settings?.card == 2 && ScreenSaverSettings.wallpaper == .photos)
            }
        }
    }

    @Test func selectChoosesTheFocusedTypeAndNeverMovesOn() throws {
        try withTV { tv, _ in
            withWallpaper(.photos) {
                tv.settings = SettingsPanel(section: .screenSaver, open: true)
                #expect(rows(tv) == [.wallpaper, .photosFolder, .saverDelay, .saverClock, .saverPreview])
                tv.handleSettings(.move(.right))
                tv.handleSettings(.select)
                #expect(ScreenSaverSettings.wallpaper == .colour)
                #expect(tv.settings?.card == nil && tv.settings?.row == 0)
                #expect(rows(tv) == [.wallpaper, .saverDelay, .saverClock, .saverPreview])
                // Return (and Space, which is Return) again: nothing moves, nothing opens.
                tv.handleSettings(.select)
                tv.handleSettings(.select)
                #expect(ScreenSaverSettings.wallpaper == .colour && tv.settings?.card == nil && tv.settings?.row == 0)
                // A click chooses any card.
                tv.chooseCard(on: .wallpaper, at: 3)
                #expect(ScreenSaverSettings.wallpaper == .flipClock)
                #expect(rows(tv) == [.wallpaper, .saverDelay, .twentyFourHour, .saverPreview])
            }
        }
    }

    @Test func backLeavesWithTheOldChoice() throws {
        try withTV { tv, _ in
            withWallpaper(.colour) {
                tv.settings = SettingsPanel(section: .screenSaver, open: true)
                tv.handleSettings(.move(.left))
                tv.handleSettings(.back)
                #expect(ScreenSaverSettings.wallpaper == .colour)
                #expect(tv.settings?.open == false && tv.settings?.card == nil)
                // Up and down leave the row as it was too, and coming back lands on the chosen card.
                tv.handleSettings(.select)
                tv.handleSettings(.move(.right))
                tv.handleSettings(.move(.down))
                tv.handleSettings(.move(.up))
                #expect(ScreenSaverSettings.wallpaper == .colour && tv.settings?.card == nil)
            }
        }
    }

    @Test func myPhotosHasChooseFolderAboveStartAfter() throws {
        try withTV { tv, _ in
            try withWallpaper(.photos) {
                tv.settings = SettingsPanel(section: .screenSaver, open: true)
                let panel = try #require(tv.settings)
                let row = tv.settingsContent(.photosFolder, panel: panel, focused: false)
                #expect(row.title == "Choose Folder…" && row.accessory == .chevron)
                #expect(row.value == ScreenSaverSettings.photosFolder.lastPathComponent)
            }
        }
    }

    @Test func spaceAndReturnActOnceOnASwitch() throws {
        try withTV { tv, _ in
            withWallpaper(.colour) {
                // Space and Return both arrive as one Select (held keys don't repeat it): a switch flips once.
                tv.settings = SettingsPanel(section: .screenSaver, open: true, row: 2)
                #expect(rows(tv)[2] == .saverClock)
                let before = ScreenSaverSettings.showClock
                tv.handleSettings(.select)
                #expect(ScreenSaverSettings.showClock == !before)
                #expect(tv.settings?.row == 2)
                tv.handleSettings(.select)
                #expect(ScreenSaverSettings.showClock == before)
            }
        }
    }

    @Test func focusStaysOnARowWhenRowsGo() throws {
        try withTV { tv, _ in
            withWallpaper(.photos) {
                tv.settings = SettingsPanel(section: .screenSaver, open: true, row: 4)
                ScreenSaverSettings.wallpaper = .flipClock   // five rows down to four, focus was on the fifth
                tv.handleSettings(.move(.up))
                #expect(tv.settings?.row == 2)
                tv.settings?.row = 9
                tv.handleSettings(.move(.right))   // no crash, no stray row
                #expect(tv.settings?.row == 3)
            }
        }
    }

    @Test func previewComesBackToSettings() throws {
        try withTV { tv, _ in
            withWallpaper(.colour) {
                tv.settings = SettingsPanel(section: .screenSaver, open: true, row: 3)
                #expect(rows(tv)[3] == .saverPreview)
                tv.handleSettings(.select)
                #expect(tv.screensaver && tv.settings != nil)
                tv.handle(.move(.down))   // any press only wakes it (and makes no sound)
                #expect(!tv.screensaver && tv.settings?.row == 3)
            }
        }
    }

    // MARK: Movies

    @Test func moviesAddsAndRemovesAFolderButNeverTheFiles() throws {
        try withTV { tv, folder in
            let library = tv.movieLibrary
            let saved = library.folders
            defer { library.folders = saved }
            let films = folder.appendingPathComponent("Films", isDirectory: true)
            try FileManager.default.createDirectory(at: films, withIntermediateDirectories: true)
            let path = films.standardizedFileURL.path

            tv.settings = SettingsPanel(section: .apps, open: true, row: 3)
            #expect(rows(tv)[3] == .movies)
            tv.handleSettings(.select)
            let movies = try #require(tv.settings)
            #expect(movies.page == .movies && tv.settingsHero(movies).title == "Movies")
            #expect(rows(tv).last == .addJellyfinServer && rows(tv).contains(.addMovieFolder))
            tv.addMovieFolders([films])
            #expect(library.isWatched(films))
            #expect(rows(tv).contains(.movieFolder(path)))
            #expect(rows(tv)[tv.settings?.row ?? 0] == .addMovieFolder)

            tv.activateSetting(.movieFolder(path))
            #expect(tv.settings?.page == .movieFolder(path))
            #expect(rows(tv) == [.homeVideos, .removeMovieSource])
            // Home Videos: the same switch as the Movies app's source menu
            tv.handleSettings(.select)
            #expect(library.isHomeVideos(path))
            tv.handleSettings(.select)
            #expect(!library.isHomeVideos(path))
            tv.handleSettings(.move(.down))
            tv.handleSettings(.select)
            #expect(tv.settings?.page == .confirmRemoval(.removeMovieSource) && library.isWatched(films))
            #expect(tv.settingsContent(.acceptRemoval, panel: try #require(tv.settings), focused: true).title == "Remove Folder")
            tv.handleSettings(.move(.down))
            tv.handleSettings(.select)
            #expect(!library.isWatched(films))
            #expect(FileManager.default.fileExists(atPath: films.path))
            #expect(tv.settings?.page == .movies && !rows(tv).contains(.movieFolder(path)))
        }
    }

    // MARK: Wording

    @Test func displayIsFullScreenInAppleWording() throws {
        try withTV { tv, _ in
            #expect(SettingsPanel.Section.videoAndAudio.title == "Video and Audio")
            let panel = SettingsPanel(section: .videoAndAudio, open: true)
            #expect(tv.settingsContent(.dedicatedTV, panel: panel, focused: false).title == "Full Screen")
            // Full Screen off: the screen Mac TV is on, never "Off" (which reads as the screen being off).
            #expect(tv.displaySummary == NSScreen.main?.localizedName && tv.displaySummary != "Off")
        }
    }
}
