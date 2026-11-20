import AppKit
import Foundation
import Testing
@testable import MacTV

/// Settings' pages and the pages below them: Remotes and Devices, Profiles, Screen Saver's cards, Movies.
@Suite @MainActor struct SettingsPagesTests {
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
            tv.openSettings()
            tv.handleSettings(.move(.down))
            tv.handleSettings(.select)
            #expect(tv.settings?.section == .remotes && tv.settings?.open == true)
            #expect(rows(tv) == [.siriRemote, .iPhone, .otherControllers])

            tv.handleSettings(.move(.down))
            tv.handleSettings(.select)
            #expect(tv.settings?.page == .iPhone && tv.settings?.row == 0)
            #expect(rows(tv) == [.phoneRemote, .pairingCode, .pairedDevices, .showAtLaunch])

            // Right opens a row with ›, a page deeper.
            tv.handleSettings(.move(.down))
            tv.handleSettings(.move(.down))
            tv.handleSettings(.move(.right))
            #expect(tv.settings?.page == .pairedDevices)
            #expect(rows(tv) == [.noPairedDevices])

            tv.handleSettings(.back)
            #expect(tv.settings?.page == .iPhone && tv.settings?.row == 2)
            tv.handleSettings(.back)
            #expect(tv.settings?.page == nil && tv.settings?.open == true && tv.settings?.row == 1)
            // Left on a row with nothing to adjust goes back too.
            tv.handleSettings(.move(.left))
            #expect(tv.settings?.open == false && tv.settings?.section == .remotes)
        }
    }

    @Test func remotesPagesShowTheirRows() throws {
        try withTV { tv, _ in
            tv.settings = SettingsPanel(section: .remotes, open: true)
            tv.handleSettings(.select)
            #expect(tv.settings?.page == .siriRemote)
            #expect(rows(tv) == [.remoteStatus, .inputMonitoring, .bluetooth])
            #expect(tv.settings?.inputMonitoring == TVController.inputMonitoringAllowed)
            tv.handleSettings(.back)
            tv.handleSettings(.move(.down))
            tv.handleSettings(.move(.down))
            tv.handleSettings(.select)
            #expect(tv.settings?.page == .otherControllers)
            #expect(rows(tv) == [.controller, .bluetooth])
            let panel = try #require(tv.settings)
            #expect(tv.settingsContent(.controller, panel: panel, focused: true).value == "Not Connected")
            tv.controller = ControllerInfo(name: "DualSense", battery: 0.8)
            #expect(tv.settingsContent(.controller, panel: panel, focused: true).value == "DualSense · 80%")
        }
    }

    // MARK: Paired phones

    @Test func aPairedPhoneIsRemovedOnTheSecondPress() throws {
        let wasPaired = UserDefaults.standard.bool(forKey: "phonePaired")
        defer { UserDefaults.standard.set(wasPaired, forKey: "phonePaired") }
        try withTV { tv, _ in
            let store = tv.remoteCoordinator.pairingStore
            let kitchen = try store.issue(name: "Kitchen iPhone", guest: false)
            let guest = try store.issue(name: "Guest", guest: true)
            tv.settings = SettingsPanel(section: .remotes, open: true, row: 1)
            let iPhone = try #require(tv.settings)
            #expect(tv.settingsContent(.iPhone, panel: iPhone, focused: true).value == "2 Paired")
            tv.handleSettings(.select)
            tv.settings?.row = 2
            tv.handleSettings(.select)
            #expect(tv.settings?.page == .pairedDevices)
            #expect(rows(tv).count == 2)

            tv.handleSettings(.select)
            let asking = try #require(tv.settings)
            #expect(asking.confirming && store.activeDevices().count == 2)
            #expect(tv.settingsContent(rows(tv)[0], panel: asking, focused: true).title == "Press Again to Remove")
            // Moving away cancels the waiting press.
            tv.handleSettings(.move(.down))
            tv.handleSettings(.move(.up))
            #expect(tv.settings?.confirming == false)
            tv.handleSettings(.select)
            tv.handleSettings(.select)
            // The same store the remote server checks: the phone is refused from now on.
            #expect(store.authenticate(kitchen) == nil)
            #expect(store.authenticate(guest) != nil)
            #expect(rows(tv).count == 1 && tv.settings?.row == 0)

            tv.handleSettings(.select)
            tv.handleSettings(.select)
            #expect(store.activeDevices().isEmpty)
            #expect(rows(tv) == [.noPairedDevices])
            #expect(!tv.phonePaired)
        }
    }

    // MARK: Profiles

    @Test func profilesListsEveryoneThenAddProfile() throws {
        try withTV { tv, _ in
            let second = tv.profiles.add(named: "Second")
            tv.openSettings()
            tv.handleSettings(.select)
            #expect(tv.profilePicker == nil)   // a page in Settings, not "Who's Watching?"
            #expect(rows(tv) == [.profile(Profile.mainID), .profile(second.id), .addProfile])
            let panel = try #require(tv.settings)
            #expect(tv.settingsContent(.profile(Profile.mainID), panel: panel, focused: false).checked)
            #expect(!tv.settingsContent(.profile(second.id), panel: panel, focused: false).checked)

            // The main profile, watching now: no Switch, no Remove.
            tv.handleSettings(.select)
            #expect(rows(tv) == [.profileName, .profileColor])
            tv.handleSettings(.back)
            tv.handleSettings(.move(.down))
            tv.handleSettings(.select)
            #expect(rows(tv) == [.profileName, .profileColor, .switchProfile, .removeProfile])
        }
    }

    @Test func addProfileTypesANameAndStaysInSettings() throws {
        try withTV { tv, folder in
            tv.settings = SettingsPanel(section: .profiles, open: true, row: 1)
            tv.handleSettings(.select)
            #expect(tv.settings?.typing == true && tv.settings?.typed == "")
            tv.handleSettings(.text("Bo"))
            tv.handleSettings(.move(.down))   // arrows don't type or leave
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

    @Test func renameAndColourAreSaved() throws {
        try withTV { tv, folder in
            let second = tv.profiles.add(named: "Second")
            tv.settings = SettingsPanel(section: .profiles, open: true, row: 1)
            tv.handleSettings(.select)
            tv.handleSettings(.select)
            #expect(tv.settings?.page == .profileName(second.id) && tv.settings?.typed == "Second")
            for _ in 0..<6 { tv.handleSettings(.deleteBackward) }
            tv.handleSettings(.text("Ann\n"))
            #expect(tv.settings?.page == .profile(second.id) && tv.settings?.row == 0)
            #expect(tv.profiles.all.first { $0.id == second.id }?.name == "Ann")
            #expect(ProfileStore(folder: folder).all.first { $0.id == second.id }?.name == "Ann")

            tv.handleSettings(.move(.down))
            let colors = ProfileStore.colors
            let before = try #require(colors.firstIndex(of: second.color))
            let changes = tv.settings?.changes ?? 0
            tv.handleSettings(.move(.right))
            let after = colors[min(before + 1, colors.count - 1)]
            #expect(tv.profiles.all.first { $0.id == second.id }?.color == after)
            #expect(ProfileStore(folder: folder).all.first { $0.id == second.id }?.color == after)
            #expect(tv.settings?.changes == changes + (after == second.color ? 0 : 1))
            #expect(tv.settings?.page == .profile(second.id))   // left and right stay on the page here

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
        }
    }

    @Test func removeProfileAsksAgainThenRemovesItsAppsAndReturns() throws {
        try withTV { tv, folder in
            let second = tv.profiles.add(named: "Second")
            let apps = folder.appendingPathComponent("apps-\(second.id).json")
            try Data("[]".utf8).write(to: apps)
            tv.settings = SettingsPanel(section: .profiles, open: true, row: 1)
            tv.handleSettings(.select)
            tv.settings?.row = 3
            tv.handleSettings(.select)
            #expect(tv.settings?.confirming == true && tv.profiles.all.count == 2)
            // A click on another row cancels the waiting press.
            tv.activateSetting(.profileColor)
            #expect(tv.settings?.confirming == false && tv.settings?.row == 1)
            tv.settings?.row = 3
            tv.handleSettings(.select)
            tv.handleSettings(.select)
            #expect(tv.profiles.all.map(\.id) == [Profile.mainID])
            #expect(!FileManager.default.fileExists(atPath: apps.path))
            #expect(tv.settings?.page == nil && tv.settings?.section == .profiles)
            #expect(rows(tv)[tv.settings?.row ?? 0] == .addProfile)
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
            try withWallpaper(.photos) {
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
            try withWallpaper(.photos) {
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
                #expect(rows(tv) == [.wallpaper, .saverDelay, .saverPreview])
            }
        }
    }

    @Test func backLeavesWithTheOldChoice() throws {
        try withTV { tv, _ in
            try withWallpaper(.colour) {
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
            try withWallpaper(.colour) {
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
            try withWallpaper(.photos) {
                tv.settings = SettingsPanel(section: .screenSaver, open: true, row: 4)
                ScreenSaverSettings.wallpaper = .flipClock   // five rows down to three, focus was on the fifth
                tv.handleSettings(.move(.up))
                #expect(tv.settings?.row == 1)
                tv.settings?.row = 9
                tv.handleSettings(.move(.right))   // no crash, no stray row
                #expect(tv.settings?.row == 2)
            }
        }
    }

    @Test func previewComesBackToSettings() throws {
        try withTV { tv, _ in
            try withWallpaper(.colour) {
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

            tv.openSettings()
            tv.settings?.section = .movies
            tv.handleSettings(.select)
            #expect(rows(tv).last == .addJellyfinServer && rows(tv).contains(.addMovieFolder))
            tv.addMovieFolders([films])
            #expect(library.isWatched(films))
            #expect(rows(tv).contains(.movieFolder(path)))
            #expect(rows(tv)[tv.settings?.row ?? 0] == .addMovieFolder)

            tv.activateSetting(.movieFolder(path))
            #expect(tv.settings?.page == .movieFolder(path))
            #expect(rows(tv) == [.removeMovieSource])
            tv.handleSettings(.select)
            #expect(library.isWatched(films))
            tv.handleSettings(.select)
            #expect(!library.isWatched(films))
            #expect(FileManager.default.fileExists(atPath: films.path))
            #expect(tv.settings?.page == nil && !rows(tv).contains(.movieFolder(path)))
        }
    }

    // MARK: Wording

    @Test func displayIsFullScreenInAppleWording() throws {
        try withTV { tv, _ in
            #expect(SettingsPanel.Section.dedicatedTV.title == "Display")
            let panel = SettingsPanel(section: .dedicatedTV, open: true)
            #expect(tv.settingsContent(.dedicatedTV, panel: panel, focused: false).title == "Full Screen")
            #expect(tv.settingsDetail(.dedicatedTV) == "Off")
            #expect(tv.settingsDetail(.watching) == nil && tv.settingsDetail(.power) == nil)
            #expect(tv.settingsDetail(.profiles) == tv.profile.name)
        }
    }
}
