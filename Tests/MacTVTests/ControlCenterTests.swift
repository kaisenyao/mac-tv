import AppKit
import Foundation
import Testing
@testable import MacTV

/// Control Center as tvOS lays it out: Sleep Now, the Remotes / Display / Audio / Sleep Timer tiles, and four
/// round buttons, the third depending on whether the Mac has a lid.
@Suite(.timeLimit(.minutes(1))) @MainActor struct ControlCenterTests {
    init() {
        _ = NSApplication.shared
        AudioCoordinator.readVolume = { VolumeLevel(level: 50, muted: false) }
    }

    private func withTV(_ body: (TVController) throws -> Void) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tv = TVController(library: AppLibrary(folder: folder), profiles: ProfileStore(folder: folder))
        tv.remoteCoordinator.pairingStore = PairingStore(folder: folder)
        try body(tv)
    }

    @Test func everyMoveHasAWayBack() {
        let opposite: [RemoteCommand.Direction: RemoteCommand.Direction] = [.up: .down, .down: .up, .left: .right, .right: .left]
        let controls = ControlCenterPanel.Item.standardControls
        let shown = ControlCenterPanel.Item.allCases.filter { $0 != .done && (!ControlCenterPanel.Item.controls.contains($0) || controls.contains($0)) }
        for item in shown {
            for (direction, back) in opposite {
                guard let next = ControlCenterPanel.neighbour(of: item, direction, controls: controls) else { continue }
                // Coming back lands on the item, or (from the wide Sleep Now tile, or a short row) on one beside it.
                let returned = ControlCenterPanel.neighbour(of: next, back, controls: controls)
                #expect(returned != nil, "\(item) → \(direction) → \(next) has no way back")
            }
        }
        // The grid, in Apple's order: Sleep Now, Remotes, Display, Audio, Sleep Timer, then the round buttons, four to
        // a row, then Edit.
        func next(_ item: ControlCenterPanel.Item, _ direction: RemoteCommand.Direction) -> ControlCenterPanel.Item? {
            ControlCenterPanel.neighbour(of: item, direction, controls: controls)
        }
        #expect(next(.sleepNow, .right) == .remotes)
        #expect(next(.remotes, .down) == .display)
        #expect(next(.sleepNow, .down) == .audio)
        #expect(next(.audio, .right) == .sleepTimer)
        #expect(next(.audio, .down) == .jasmine)
        #expect(next(.sleepTimer, .down) == .screenSaver)
        #expect(next(.jasmine, .right) == .screenOff)
        #expect(next(.mute, .right) == nil)                   // four to a row
        #expect(next(.jasmine, .down) == .playPause)          // the second row
        #expect(next(.screenOff, .down) == .search)
        #expect(next(.settings, .down) == .edit)
        #expect(next(.edit, .up) == .settings)
        #expect(!ControlCenterPanel.Item.allCases.contains { "\($0)" == "skipIntros" || "\($0)" == "phone" || "\($0)" == "controller" })
    }

    /// Edit, as an iPhone's Control Center: pick a round button up and move it, hold to take one out, add one back.
    /// The order is the person's, kept.
    @Test func editRearrangesRemovesAndAddsRoundButtons() throws {
        try withTV { tv in
            defer { tv.preferences.controlCenterControls = nil }
            tv.preferences.controlCenterControls = nil
            tv.openControlCenter()
            #expect(tv.controlCenterControls == [.jasmine, .screenOff, .screenSaver, .mute, .playPause, .search, .appSwitcher, .settings])
            #expect(tv.controlCenterAvailable == [.stayAwake, .profiles, .arrangeApps, .store, .fullScreen, .userGuide])
            tv.controlCenter?.item = .edit
            tv.handleControlCenter(.select)
            #expect(tv.controlCenter?.editing == true && tv.controlCenter?.item == .jasmine)
            // The tiles rest: up from the first row goes nowhere.
            tv.handleControlCenter(.move(.up))
            #expect(tv.controlCenter?.item == .jasmine)

            // Picked up, moved right twice, put down: the others make room.
            tv.handleControlCenter(.select)
            #expect(tv.controlCenter?.lifted == .jasmine)
            tv.handleControlCenter(.move(.right))
            tv.handleControlCenter(.move(.right))
            tv.handleControlCenter(.select)
            #expect(tv.controlCenter?.lifted == nil)
            #expect(tv.controlCenterControls == [.screenOff, .screenSaver, .jasmine, .mute, .playPause, .search, .appSwitcher, .settings])

            // Held: out, to Add a Control; focus on the one that took its place.
            tv.controlCenter?.item = .search
            #expect(tv.holdSelect(from: .keyboard))
            #expect(tv.controlCenterControls == [.screenOff, .screenSaver, .jasmine, .mute, .playPause, .appSwitcher, .settings])
            #expect(tv.controlCenter?.item == .appSwitcher)
            #expect(tv.controlCenterAvailable.first == .search)

            // Its "−" clicked: out too, focus staying where it is.
            #expect(tv.removeControlCenterControl(.settings))
            #expect(tv.controlCenterControls == [.screenOff, .screenSaver, .jasmine, .mute, .playPause, .appSwitcher])
            #expect(tv.controlCenter?.item == .appSwitcher)

            // Down to Add a Control, Select: in again, last.
            tv.handleControlCenter(.move(.down))
            #expect(tv.controlCenter?.item == .search)
            tv.handleControlCenter(.select)
            #expect(tv.controlCenterControls == [.screenOff, .screenSaver, .jasmine, .mute, .playPause, .appSwitcher, .search])

            // Back finishes, on Edit; the order stays.
            tv.handleControlCenter(.back)
            #expect(tv.controlCenter?.editing == false && tv.controlCenter?.item == .edit)
            #expect(tv.preferences.controlCenterControls == ["screenOff", "screenSaver", "jasmine", "mute", "playPause", "appSwitcher", "search"])
        }
    }

    @Test func sleepTimerOpensItsListAndBackReturnsToTheTiles() throws {
        try withTV { tv in
            defer { tv.setSleepTimer(minutes: 0) }
            tv.openControlCenter()
            tv.controlCenter?.item = .sleepTimer
            tv.handleControlCenter(.select)
            #expect(tv.controlCenter?.list == .sleepTimer)
            #expect(tv.controlCenterChoices(.sleepTimer) == [.timer(0), .timer(15), .timer(30), .timer(60), .timer(90)])
            #expect(tv.controlCenter?.listRow == 0)   // on Off, the choice in use
            tv.handleControlCenter(.back)
            #expect(tv.controlCenter?.list == nil && tv.controlCenter?.item == .sleepTimer)

            tv.handleControlCenter(.select)
            tv.handleControlCenter(.move(.down))
            tv.handleControlCenter(.move(.down))
            tv.handleControlCenter(.select)
            #expect(tv.sleepMinutesLeft == 30)
            #expect(tv.controlCenter?.list == nil)
            // Running: the list offers Cancel Timer first.
            tv.handleControlCenter(.select)
            #expect(tv.controlCenterChoices(.sleepTimer).first == .cancelTimer)
            tv.controlCenter?.listRow = 0
            tv.handleControlCenter(.select)
            #expect(tv.sleepMinutesLeft == 0)
        }
    }

    @Test func displayOpensItsSheetWithFullScreenAndTheDisplays() throws {
        try withTV { tv in
            tv.openControlCenter()
            tv.activateControl(.display)
            #expect(tv.displayPicker != nil && tv.activeSheet == .displayPicker)   // as Audio opens its sheet
            #expect(Array(tv.controlCenterChoices(.display).prefix(2)) == [.fullScreen, .automaticDisplay])
            #expect(tv.controlCenterChoice(.fullScreen).accessory == .toggle(tv.dedicatedTVMode))
        }
    }

    @Test func remotesOpensConnectARemoteOverControlCenter() throws {
        try withTV { tv in
            tv.openControlCenter()
            tv.handleControlCenter(.select)   // Remotes has focus first
            #expect(tv.pairing && tv.controlCenter != nil && tv.activeSheet == .pairing)
            tv.handlePairing(.back)
            #expect(!tv.pairing && tv.activeSheet == .controlCenter)
            // Holding TV again closes Control Center with whatever it opened over itself.
            tv.handleControlCenter(.select)
            tv.handle(.controlCenter)
            #expect(tv.sheets.open.isEmpty)
            // Home over a sheet opened from it goes home, rather than closing the hidden Control Center alone.
            tv.openControlCenter()
            tv.activateControl(.remotes)
            tv.handle(.home)
            #expect(tv.sheets.open.isEmpty)
        }
    }

    @Test func remotesSaysWhatIsConnected() throws {
        let wasConnected = SiriRemoteStatus.shared.connected
        defer { SiriRemoteStatus.shared.connected = wasConnected }
        try withTV { tv in
            SiriRemoteStatus.shared.connected = false
            #expect(tv.remotesSummary.text == "Not Connected" && !tv.remotesSummary.connected)
            tv.controller = ControllerInfo(name: "DualSense Wireless Controller", battery: 0.7)
            #expect(tv.remotesSummary.text == "Game Controller · 70%" && tv.remotesSummary.symbol == "gamecontroller.fill")
            SiriRemoteStatus.shared.connected = true
            #expect(tv.remotesSummary.text.hasPrefix("Siri Remote"))
            #expect(tv.remotesSummary.symbol == "appletvremote.gen4.fill")
            let token = try tv.remoteCoordinator.pairingStore.issue(name: "iPhone", guest: false)
            _ = tv.remoteCoordinator.pairingStore.authenticate(token)
            #expect(tv.remotesSummary.text.contains(", iPhone, Game Controller · 70%"))
        }
    }

    @Test func aDesktopKeepsTheMacAwakeAndNeverOverridesTheLid() throws {
        try withTV { tv in
            tv.displayCoordinator.hasLid = false
            let awake = tv.keepMacAwake
            defer { tv.keepMacAwake = awake }
            tv.lidOverride = true
            #expect(!tv.lidOverride && !tv.lidSleepOff)
            tv.openControlCenter()
            tv.activateControl(.stayAwake)
            #expect(tv.keepMacAwake == !awake && !tv.lidOverride)
            // Settings › System has no lid row either.
            #expect(!tv.settingsRows(SettingsPanel(section: .system, open: true)).contains(.lidOverride))
            tv.displayCoordinator.hasLid = true
            #expect(tv.settingsRows(SettingsPanel(section: .system, open: true)).contains(.lidOverride))
            // The lid's status glyph opens System on that row.
            tv.openSettings(to: .lidOverride)
            let system = try #require(tv.settings)
            #expect(system.section == .system && system.open && tv.settingsRows(system)[system.row] == .lidOverride)
        }
    }

    @Test func screenSaverStartsNowAndSleepNowIsTVStandby() throws {
        try withTV { tv in
            tv.openControlCenter()
            tv.activateControl(.sleepNow)   // at once, no second press: standby, never the Mac's sleep
            #expect(tv.standby && tv.controlCenter == nil)
            tv.handle(.press(.select, .tap), from: .remote)   // Select wakes it, and does nothing else
            #expect(!tv.standby && tv.controlCenter == nil)
            tv.openControlCenter()
            tv.activateControl(.screenSaver)
            #expect(tv.screensaver && tv.controlCenter == nil)
            tv.screensaverOff()
        }
    }

    // MARK: 24-Hour Time

    @Test func clocksFollowTwentyFourHourTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let evening = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 23, minute: 32)))
        #expect(TimeOfDay.text(evening, twentyFour: true) == "23:32")
        #expect(TimeOfDay.text(evening, twentyFour: false, meridiem: false) == "11:32")
        #expect(TimeOfDay.text(evening, twentyFour: false).hasPrefix("11:32"))

        // Until it's changed, it's this Mac's own setting.
        let suite = "MacTV.Clock.\(UUID().uuidString)"
        let defaults = TestDefaults.named(suite)
        defer { TestDefaults.remove(suite) }
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.twentyFourHourTime == FlipClockTime.systemTwentyFour)
        preferences.twentyFourHourTime = !FlipClockTime.systemTwentyFour
        #expect(Preferences(defaults: defaults).twentyFourHourTime == !FlipClockTime.systemTwentyFour)

        try withTV { tv in
            let saved = tv.preferences.twentyFourHourTime
            defer { tv.preferences.twentyFourHourTime = saved }
            tv.settings = SettingsPanel(section: .general, open: true)
            let general = try #require(tv.settings)
            #expect(tv.settingsRows(general)[0] == .twentyFourHour)   // General, first, as the owner asked
            tv.handleSettings(.select)
            #expect(tv.preferences.twentyFourHourTime == !saved)
        }
    }
}
