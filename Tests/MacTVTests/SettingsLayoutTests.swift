import AppKit
import Foundation
import Testing
@testable import MacTV

/// Settings laid out as Apple TV's: tvOS's sections and names, Connect a Remote's picture following focus, profile
/// photos, text fields with a caret, and Movies' forms inside Settings.
@Suite(.timeLimit(.minutes(1))) @MainActor struct SettingsLayoutTests {
    init() {
        _ = NSApplication.shared
        AudioCoordinator.readVolume = { VolumeLevel(level: 50, muted: false) }
    }

    /// A TV with everything in a scratch folder and its own defaults, both removed afterwards.
    private func withTV(_ body: (TVController, URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacTVTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "MacTVTests.Settings.\(UUID().uuidString)"
        defer {
            TestDefaults.remove(suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let tv = TVController(library: AppLibrary(folder: folder), profiles: ProfileStore(folder: folder),
                              services: AppServices(preferences: Preferences(defaults: TestDefaults.named(suite))))
        tv.remoteCoordinator.pairingStore = PairingStore(folder: folder)
        try body(tv, folder)
    }

    private func rows(_ tv: TVController) -> [SettingsPanel.Row] { tv.settingsRows(tv.settings ?? SettingsPanel()) }

    // MARK: Sections

    @Test func sectionsAreTvOSsInTvOSsOrder() throws {
        try withTV { tv, _ in
            #expect(SettingsPanel.Section.allCases.map(\.title)
                    == ["General", "Profiles and Accounts", "Video and Audio", "Screen Saver", "Remotes and Devices", "Apps", "System"])
            tv.openSettings()
            #expect(tv.settings?.section == .general)
            tv.handleSettings(.select)
            // 24-Hour Time first; Website Player only when there's Brave to choose.
            let general: [SettingsPanel.Row] = [.twentyFourHour, .sleepTimer, .launchAtLogin, .autoSkip, .autoNext]
            #expect(rows(tv) == general + (tv.braveInstalled ? [.websitePlayer] : []))
            let panel = try #require(tv.settings)
            #expect(rows(tv).map { tv.settingsContent($0, panel: panel, focused: false).title }.prefix(5)
                    == ["24-Hour Time", "Sleep Timer", "Open at Login", "Skip Intros, Recaps and Ads", "Autoplay Next Episode"])
            // Each group under its own header, as tvOS's pages have them.
            #expect(rows(tv).map { tv.settingsHeader($0, panel: panel) }.prefix(5) == ["TIME", "TIME", "STARTUP", "PLAYBACK", "PLAYBACK"])

            #expect(tv.settingsRows(SettingsPanel(section: .videoAndAudio, open: true))
                    == [.dedicatedTV, .preferredDisplay, .audioOutput, .feedback])
            #expect(tv.settingsContent(.feedback, panel: panel, focused: false).title == "Navigation Clicks")
            tv.displayCoordinator.hasLid = true
            #expect(tv.settingsRows(SettingsPanel(section: .system, open: true))
                    == [.userGuide, .about, .softwareUpdates, .keepMacAwake, .lidOverride, .screenOff])
        }
    }

    @Test func aboutAndSoftwareUpdatesArePagesInSystem() throws {
        try withTV { tv, _ in
            tv.settings = SettingsPanel(section: .system, open: true, row: 1)   // User Guide, then About
            tv.handleSettings(.select)
            #expect(tv.settings?.page == .about && rows(tv) == [.version, .source, .report])
            tv.handleSettings(.back)
            tv.handleSettings(.move(.down))
            tv.handleSettings(.move(.right))
            #expect(tv.settings?.page == .softwareUpdates && rows(tv) == [.update, .autoUpdate])
            let page = try #require(tv.settings)
            #expect(tv.settingsContent(.update, panel: page, focused: false).title == "Update Software")
            #expect(tv.settingsContent(.autoUpdate, panel: page, focused: false).title == "Automatically Update")
            tv.handleSettings(.move(.left))
            #expect(tv.settings?.page == nil && tv.settings?.row == 2)
        }
    }

    @Test func connectARemotesPictureFollowsFocus() throws {
        try withTV { tv, _ in
            tv.pairing = true
            #expect(tv.settingsHero(tv.connectRemote).symbol == "appletvremote.gen4.fill")
            tv.handlePairing(.move(.down))
            #expect(tv.settingsHero(tv.connectRemote).symbol == "iphone")
            tv.handlePairing(.move(.down))
            #expect(tv.settingsHero(tv.connectRemote).symbol == "gamecontroller.fill")
            #expect(tv.settingsHero(tv.connectRemote).title == "Connect a Remote")
            // The same in Settings › Remotes and Devices.
            let remotes = SettingsPanel(section: .remotes, open: true, row: 1)
            #expect(tv.settingsHero(remotes).symbol == "iphone" && tv.settingsHero(remotes).title == "Remotes and Devices")
        }
    }

    // MARK: 24-Hour Time

    @Test func flipClockHasTwentyFourHourTimeAndItIsGeneralsSetting() throws {
        let saved = Preferences.shared.saverWallpaper
        defer { Preferences.shared.saverWallpaper = saved }
        try withTV { tv, _ in
            ScreenSaverSettings.wallpaper = .colour
            #expect(!tv.settingsRows(SettingsPanel(section: .screenSaver, open: true)).contains(.twentyFourHour))
            ScreenSaverSettings.wallpaper = .flipClock
            let saver = SettingsPanel(section: .screenSaver, open: true, row: 2)
            #expect(tv.settingsRows(saver) == [.wallpaper, .saverDelay, .twentyFourHour, .saverPreview])
            #expect(tv.settingsContent(.twentyFourHour, panel: saver, focused: false).title == "24-Hour Time")

            // Changed on the Screen Saver page, it's changed in General, and the other way round.
            let before = tv.preferences.twentyFourHourTime
            tv.settings = saver
            tv.handleSettings(.select)
            #expect(tv.preferences.twentyFourHourTime == !before)
            let general = SettingsPanel(section: .general, open: true)
            #expect(tv.settingsContent(.twentyFourHour, panel: general, focused: false).accessory == .toggle(!before))
            tv.settings = general
            tv.handleSettings(.move(before ? .right : .left))
            #expect(tv.preferences.twentyFourHourTime == before)
            #expect(tv.settingsContent(.twentyFourHour, panel: saver, focused: false).accessory == .toggle(before))
            // Opening Settings at the row finds General's, first in the first section.
            tv.openSettings(to: .twentyFourHour)
            #expect(tv.settings?.section == .general && tv.settings?.row == 0)
        }
    }

    @Test func theFlipClockAndTheOtherClocksSayTheTimeEitherWay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let evening = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 23, minute: 5)))
        let morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 9, minute: 41)))
        // The flip clock: 24-hour pads the hour and has no AM / PM; 12-hour puts AM / PM on the hour plate.
        let late24 = FlipClockTime(evening, twentyFour: true, calendar: calendar)
        #expect(late24.hour == "23" && late24.minute == "05" && late24.meridiem == nil)
        let late12 = FlipClockTime(evening, twentyFour: false, calendar: calendar)
        #expect(late12.hour == "11" && late12.minute == "05" && late12.meridiem == "PM")
        #expect(FlipClockTime(morning, twentyFour: true, calendar: calendar).hour == "09")
        #expect(FlipClockTime(morning, twentyFour: false, calendar: calendar).meridiem == "AM")
        // The status bar (above Control Center too) and the screen saver's small clock.
        #expect(TimeOfDay.text(evening, twentyFour: true, calendar: calendar) == "23:05")
        #expect(TimeOfDay.text(evening, twentyFour: false, calendar: calendar).hasPrefix("11:05"))
        #expect(TimeOfDay.text(evening, twentyFour: false, meridiem: false, calendar: calendar) == "11:05")
    }

    // MARK: Back, one level at a time

    /// Back from everything Settings and Control Center open lands where it came from, on the row or tile that
    /// opened it. The keyboard's Esc, the remotes' Back and a controller's B all arrive as `.back`.
    @Test func backGoesBackOneLevelEverywhere() throws {
        try withTV { tv, _ in
            @MainActor func back() { tv.handle(.back) }
            @MainActor func at(_ section: SettingsPanel.Section, _ row: SettingsPanel.Row, page: SettingsPanel.Page? = nil) -> Bool {
                guard let panel = tv.settings, panel.open, panel.section == section, panel.page == page else { return false }
                let rows = tv.settingsRows(panel)
                return rows.indices.contains(panel.row) && rows[panel.row] == row
            }
            @MainActor func open(_ section: SettingsPanel.Section, _ row: SettingsPanel.Row) {
                tv.settings = SettingsPanel(section: section, open: true)
                tv.focusSetting(row)
                tv.handle(.select)
            }

            // Apps › Add App, Arrange Apps, Top Shelf (and a Top Shelf app's page)
            open(.apps, .addApp)
            #expect(tv.adder != nil && tv.settings != nil)
            back()
            #expect(tv.adder == nil && at(.apps, .addApp))
            open(.apps, .arrangeApps)
            #expect(tv.organizer != nil)
            back()
            #expect(tv.organizer == nil && at(.apps, .arrangeApps))
            open(.apps, .topShelfPreferences)
            tv.handle(.move(.down))
            tv.handle(.select)
            #expect(tv.topShelfPreferences?.app != nil)
            back()
            #expect(tv.topShelfPreferences?.app == nil && tv.topShelfPreferences?.row == 1)
            back()
            #expect(tv.topShelfPreferences == nil && at(.apps, .topShelfPreferences))

            // Apps › Movies › Add Network Share…
            open(.apps, .movies)
            tv.focusSetting(.addNetworkShare)
            tv.handle(.select)
            #expect(tv.settings?.page == .addNetworkShare)
            back()
            #expect(at(.apps, .addNetworkShare, page: .movies))
            back()
            #expect(at(.apps, .movies))
            back()
            #expect(tv.settings?.open == false && tv.settings?.section == .apps)
            back()
            #expect(tv.settings == nil)

            // Video and Audio › Audio Output
            open(.videoAndAudio, .audioOutput)
            #expect(tv.audioPicker != nil)
            back()
            #expect(tv.audioPicker == nil && at(.videoAndAudio, .audioOutput))

            // Profiles and Accounts › a profile › Name, and a removal's confirmation
            let second = tv.profiles.add(named: "Second")
            open(.profiles, .profile(second.id))
            tv.focusSetting(.profileName)
            tv.handle(.select)
            back()
            #expect(at(.profiles, .profileName, page: .profile(second.id)))
            tv.focusSetting(.removeProfile)
            tv.handle(.select)
            #expect(tv.settings?.page == .confirmRemoval(.removeProfile))
            back()
            #expect(at(.profiles, .removeProfile, page: .profile(second.id)) && tv.profiles.all.contains { $0.id == second.id })
            back()
            #expect(at(.profiles, .profile(second.id)))
            tv.settings = nil

            // Control Center: Settings, Display, Sleep Timer, Audio and Connect a Remote all come back to their tile.
            tv.openControlCenter()
            tv.activateControl(.settings)
            #expect(tv.settings != nil && tv.activeSheet == .settings)
            back()
            #expect(tv.settings == nil && tv.controlCenter?.item == .settings)
            for item in [ControlCenterPanel.Item.display, .sleepTimer] {
                tv.activateControl(item)
                #expect(tv.controlCenter?.list != nil)
                back()
                #expect(tv.controlCenter?.list == nil && tv.controlCenter?.item == item)
            }
            tv.activateControl(.audio)
            back()
            #expect(tv.audioPicker == nil && tv.controlCenter?.item == .audio)
            tv.activateControl(.remotes)
            tv.handle(.move(.down))
            tv.handle(.select)
            #expect(tv.connectRemote.page == .iPhone)
            back()
            #expect(tv.pairing && tv.connectRemote.page == nil && tv.connectRemote.row == 1)
            back()
            #expect(!tv.pairing && tv.controlCenter?.item == .remotes)
            back()
            #expect(tv.controlCenter == nil)
        }
    }

    // MARK: Headers

    @Test func everyGroupHasAHeader() throws {
        try withTV { tv, _ in
            tv.displayCoordinator.hasLid = true
            @MainActor func headers(_ panel: SettingsPanel) -> [String?] { tv.settingsRows(panel).map { tv.settingsHeader($0, panel: panel) } }
            #expect(headers(SettingsPanel(section: .videoAndAudio, open: true)) == ["VIDEO", "VIDEO", "AUDIO", "AUDIO"])
            #expect(headers(SettingsPanel(section: .remotes, open: true)) == ["REMOTES", "REMOTES", "OTHER DEVICES"])
            #expect(headers(SettingsPanel(section: .apps, open: true)) == ["HOME SCREEN", "HOME SCREEN", "HOME SCREEN", "APPS"])
            #expect(headers(SettingsPanel(section: .system, open: true)) == ["MAC TV", "MAC TV", "MAC TV", "POWER", "POWER", "POWER"])
            #expect(headers(SettingsPanel(section: .profiles, open: true)).allSatisfy { $0 == "PROFILES" })
            // Top Shelf: its list of apps, and every group on an app's page.
            #expect(TVController.topShelfAppsHeader == "APPS")
            for app in tv.topShelfApps.map(\.id) {
                let options = tv.topShelfOptions(app)
                #expect(options.first?.header != nil, "\(app)'s first group has a header")
            }
            #expect(tv.topShelfOptions(NeteaseStore.appID).compactMap(\.header) == ["播放", "歌单"])
        }
    }

    // MARK: Siri Remote

    @Test func theSiriRemotePageAsksOnlyWhatMatters() throws {
        let wasConnected = SiriRemoteStatus.shared.connected
        defer { SiriRemoteStatus.shared.connected = wasConnected }
        try withTV { tv, _ in
            let page = SettingsPanel(section: .remotes, open: true, path: [.init(page: .siriRemote, from: 0)])
            // On any macOS, never "Not Supported": none here, it's Not Connected, with how to pair, and no Input
            // Monitoring to ask about. The day a Siri Remote connects to this Mac, it works.
            SiriRemoteStatus.shared.connected = false
            #expect(tv.settingsContent(.siriRemote, panel: SettingsPanel.connect, focused: false).value == "Not Connected")
            #expect(tv.settingsContent(.remoteStatus, panel: page, focused: false).value == "Not Connected")
            #expect(tv.settingsRows(page) == [.remoteStatus, .bluetooth])
            #expect(tv.settingsFootnote(page) != nil)
            // A remote that's here: no row of its own for Input Monitoring. While it isn't allowed, Status says so and
            // opens System Settings.
            SiriRemoteStatus.shared.connected = true
            #expect(tv.settingsRows(page).filter { $0 != .remoteBattery } == [.remoteStatus, .bluetooth])
            let status = tv.settingsContent(.remoteStatus, panel: page, focused: false)
            #expect(status.value == (tv.remoteCoordinator.inputMonitoringAllowed ? "Connected" : "Needs Input Monitoring"))
        }
    }

    // MARK: First-run setup

    @Test func setupOffersAChoiceOfRemotes() throws {
        let request = SiriRemoteSupport.requestAccess
        defer { SiriRemoteSupport.requestAccess = request }
        SiriRemoteSupport.requestAccess = {}   // never macOS's own prompt in a test
        try withTV { tv, _ in
            tv.setup = SetupFlow(step: .remote)
            let connect = try #require(tv.setup?.connect)
            #expect(tv.settingsRows(connect) == [.siriRemote, .iPhone, .otherControllers, .setupDone])
            #expect(tv.settingsHero(connect).title == "Connect a Remote")
            let later = tv.settingsContent(.setupDone, panel: connect, focused: false).title
            #expect(later == "Set Up Later" || later == "Continue")
            // Each choice opens its pairing page; Back comes back to the choice, on it.
            tv.handle(.move(.down))
            tv.handle(.select)
            #expect(tv.setup?.connect.page == .iPhone)
            tv.handle(.back)
            #expect(tv.setup?.connect.page == nil && tv.setup?.connect.row == 1)
            tv.handle(.move(.down))
            tv.handle(.select)
            #expect(tv.setup?.connect.page == .otherControllers)
            tv.handle(.back)
            // Siri Remote: choosing it is when Mac TV asks for Input Monitoring.
            tv.setup?.connect.row = 0
            tv.handle(.select)
            #expect(tv.setup?.connect.page == .siriRemote)
            tv.handle(.back)
            // Back from the choice is the step before.
            tv.handle(.back)
            #expect(tv.setup?.step == .apps)
        }
    }

    // MARK: User Guide

    @Test func theUserGuideIsInSystemAndReadsWithTheRemote() throws {
        try withTV { tv, _ in
            #expect(tv.settingsRows(SettingsPanel(section: .system, open: true)).first == .userGuide)
            #expect(!UserGuide.sections.isEmpty)
            #expect(Set(UserGuide.sections.map(\.title)).count == UserGuide.sections.count)
            #expect(UserGuide.sections.allSatisfy { !$0.blocks.isEmpty })
            tv.openUserGuide()   // Help › Mac TV Help
            #expect(tv.settings?.page == .userGuide)
            let guide = try #require(tv.settings)
            #expect(tv.settingsHero(guide).title == "Mac TV User Guide")
            #expect(rows(tv) == UserGuide.sections.indices.map { .guideSection($0) })
            tv.handle(.move(.down))
            tv.handle(.select)
            #expect(tv.settings?.page == .guideSection(1) && tv.settings?.row == 0)
            tv.handle(.move(.down))
            tv.handle(.move(.down))
            #expect(tv.settings?.row == 2)
            tv.handle(.move(.up))
            #expect(tv.settings?.row == 1)
            tv.handle(.back)
            #expect(tv.settings?.page == .userGuide && tv.settings?.row == 1)
            tv.handle(.back)
            #expect(tv.settings?.page == nil && rows(tv)[tv.settings?.row ?? 0] == .userGuide)
        }
    }

    // MARK: Text fields

    @Test func textEntryTypesAtTheCaret() {
        var text = "Kaisn", caret = 5
        #expect(TextEntry.apply(.move(.left), to: &text, caret: &caret) && caret == 4)
        TextEntry.apply(.text("e"), to: &text, caret: &caret)
        #expect(text == "Kaisen" && caret == 5)
        TextEntry.apply(.deleteBackward, to: &text, caret: &caret)
        #expect(text == "Kaisn" && caret == 4)
        for _ in 0..<9 { TextEntry.apply(.move(.left), to: &text, caret: &caret) }
        #expect(caret == 0 && !TextEntry.apply(.move(.left), to: &text, caret: &caret))
        #expect(!TextEntry.apply(.deleteBackward, to: &text, caret: &caret))
        // Return isn't typed, and nothing goes past the limit.
        TextEntry.apply(.text("Hi \n"), to: &text, caret: &caret, limit: 7)
        #expect(text == "HiKaisn" && caret == 2)
        var short = "", at = 0
        TextEntry.apply(.text("abcdef"), to: &short, caret: &at, limit: 4)
        #expect(short == "abcd" && at == 4)
    }

    @Test func theNameFieldMovesItsCaretAndDownGoesToDone() throws {
        try withTV { tv, _ in
            let second = tv.profiles.add(named: "Bo")
            tv.settings = SettingsPanel(section: .profiles, open: true, row: 1)
            tv.handleSettings(.select)
            tv.handleSettings(.select)
            #expect(tv.settings?.page == .profileName(second.id) && tv.settings?.typing == true && tv.settings?.caret == 2)
            tv.handleSettings(.move(.left))
            tv.handleSettings(.text("e"))
            #expect(tv.settings?.typed == "Beo" && tv.settings?.caret == 2)
            tv.handleSettings(.move(.right))
            tv.handleSettings(.move(.right))   // at the end already: stays
            #expect(tv.settings?.caret == 3 && tv.settings?.page == .profileName(second.id))
            tv.handleSettings(.move(.down))
            #expect(tv.settings?.row == 1 && tv.settings?.typing == false)
            tv.handleSettings(.move(.up))
            #expect(tv.settings?.row == 0 && tv.settings?.typing == true)
            tv.handleSettings(.move(.down))
            tv.handleSettings(.select)
            #expect(tv.profiles.all.first { $0.id == second.id }?.name == "Beo")
            #expect(tv.settings?.page == .profile(second.id))
        }
    }

    // MARK: Profile photos

    @Test func aPhotoIsTheMiddleSquareAndShowsUntilRemoved() throws {
        try withTV { tv, folder in
            // A wide picture: red on the left and right quarters, green in the middle.
            let source = folder.appendingPathComponent("wide.png")
            let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: 800, bitsPerSample: 8,
                                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                     bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 1600, height: 800).fill()
            NSColor.green.setFill(); NSRect(x: 400, y: 0, width: 800, height: 800).fill()
            NSGraphicsContext.restoreGraphicsState()
            try #require(rep.representation(using: .png, properties: [:])).write(to: source)

            let jpeg = try #require(ProfilePhotos.squareJPEG(from: source))
            let square = try #require(NSBitmapImageRep(data: jpeg))
            #expect(square.pixelsWide == 512 && square.pixelsHigh == 512)
            for x in [8, 256, 503] {
                let color = try #require(square.colorAt(x: x, y: 256)?.usingColorSpace(.deviceRGB))
                #expect(color.greenComponent > 0.8 && color.redComponent < 0.3, "only the green middle is kept")
            }

            tv.settings = SettingsPanel(section: .profiles, open: true)
            tv.handleSettings(.select)
            #expect(rows(tv) == [.profileName, .profilePhoto])
            let panel = try #require(tv.settings)
            #expect(tv.settingsContent(.profilePhoto, panel: panel, focused: false).title == "Choose Photo…")
            #expect(ProfilePhotos.shared.set(jpeg, for: Profile.mainID))
            let file = folder.appendingPathComponent(ProfilePhotos.fileName)   // the first profile's folder
            #expect(FileManager.default.fileExists(atPath: file.path))
            #expect(ProfilePhotos.shared.photo(for: Profile.mainID) != nil)
            #expect(rows(tv) == [.profileName, .profilePhoto, .removePhoto])

            // Remove Photo asks first, with Cancel focused; then the letter is back.
            tv.settings?.row = 2
            tv.handleSettings(.select)
            #expect(tv.settings?.page == .confirmRemoval(.removePhoto) && tv.settings?.row == 0)
            #expect(tv.settingsHero(try #require(tv.settings)).title == "Remove Photo?" && FileManager.default.fileExists(atPath: file.path))
            tv.handleSettings(.move(.down))
            tv.handleSettings(.select)
            #expect(!FileManager.default.fileExists(atPath: file.path) && ProfilePhotos.shared.photo(for: Profile.mainID) == nil)
            // To the Trash (this test's own, inside its folder), never straight out of existence.
            let trashed = (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("Trash").path)) ?? []
            #expect(trashed.contains { $0.hasSuffix(ProfilePhotos.fileName) })
            #expect(rows(tv) == [.profileName, .profilePhoto] && rows(tv)[tv.settings?.row ?? 0] == .profilePhoto)

            // Another profile's photo is in its own folder.
            let second = tv.profiles.add(named: "Second")
            #expect(ProfilePhotos.shared.file(for: second.id).path.hasPrefix(folder.appendingPathComponent("Profiles/\(second.id)").path))
        }
    }

    // MARK: Movies' forms

    @Test func addNetworkShareIsAFormInSettings() throws {
        try withTV { tv, _ in
            let shares = tv.networkShares.shares
            tv.settings = SettingsPanel(section: .apps, open: true, row: 3)
            tv.handleSettings(.select)
            tv.settings?.row = try #require(rows(tv).firstIndex(of: .addNetworkShare))
            tv.handleSettings(.select)
            #expect(tv.movies == nil)   // not the Movies app's form
            #expect(tv.settings?.page == .addNetworkShare && rows(tv) == [.formAddress, .formUser, .formPassword, .formSubmit])
            #expect(tv.settings?.typing == true)

            tv.handleSettings(.text("nas.lcal/Movies"))
            for _ in 0..<10 { tv.handleSettings(.move(.left)) }
            tv.handleSettings(.text("o"))
            #expect(tv.settings?.form.address == "nas.local/Movies")
            let field = tv.settingsContent(.formAddress, panel: try #require(tv.settings), focused: true)
            #expect(field.title == "Server" && field.field?.caret == 6)

            tv.handleSettings(.move(.down))
            tv.handleSettings(.move(.down))
            tv.handleSettings(.text("hunter2"))
            #expect(tv.settings?.form.password == "hunter2")
            let password = tv.settingsContent(.formPassword, panel: try #require(tv.settings), focused: true)
            #expect(password.field?.secure == true)
            // Wherever the sheets are described, the password isn't.
            #expect(!String(describing: tv.sheets).contains("hunter2"))

            tv.handleSettings(.move(.down))
            let onButton = try #require(tv.settings)
            #expect(!onButton.typing && tv.settingsContent(.formSubmit, panel: onButton, focused: true).title == "Connect")

            // Not a share address: it says why, and nothing is added.
            tv.settings?.form.address = "nas"
            tv.handleSettings(.select)
            #expect(tv.settingsFootnote(try #require(tv.settings)) == "Use an address like nas.local/Movies.")
            #expect(tv.networkShares.shares == shares)

            tv.handleSettings(.back)
            #expect(tv.settings?.page == .movies && rows(tv)[tv.settings?.row ?? 0] == .addNetworkShare)
            #expect(tv.settings?.form == SourceForm())
        }
    }

    @Test func signInToJellyfinSaysWhatsMissing() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacTVTests-\(UUID().uuidString)", isDirectory: true)
        let suite = "MacTVTests.Settings.\(UUID().uuidString)"
        defer {
            TestDefaults.remove(suite)
            try? FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tv = TVController(library: AppLibrary(folder: folder), profiles: ProfileStore(folder: folder),
                              services: AppServices(preferences: Preferences(defaults: TestDefaults.named(suite))))
        tv.settings = SettingsPanel(section: .apps, open: true, row: 3)
        tv.handleSettings(.select)
        tv.settings?.row = try #require(rows(tv).firstIndex(of: .addJellyfinServer))
        tv.handleSettings(.select)
        let form = try #require(tv.settings)
        #expect(form.page == .addJellyfinServer && tv.settingsHero(form).title == "Sign In to Jellyfin")
        let user = tv.settingsContent(.formUser, panel: try #require(tv.settings), focused: false)
        #expect(user.title == "User Name" && user.field?.placeholder == "Required")
        // Select goes field by field, then signs in: with no address it stops before going anywhere.
        tv.handleSettings(.select)
        tv.handleSettings(.select)
        #expect(tv.settings?.row == 2)
        tv.handleSettings(.select)
        #expect(tv.settings?.form.connecting == true && tv.settings?.row == 3)
        tv.handleSettings(.move(.up))   // waits while it works
        #expect(tv.settings?.row == 3)
        for _ in 0..<50 where tv.settings?.form.connecting == true { try await Task.sleep(for: .milliseconds(20)) }
        #expect(tv.settings?.form.connecting == false)
        #expect(tv.settingsFootnote(try #require(tv.settings)) == "Type the server's address first.")
    }
}
