import AppKit
import IOKit.hid
import SwiftUI

/// The TV's Settings: a list of sections, each opening a page of rows, and rows with › opening a page
/// of their own. The focused section's symbol (or the page's) is large on the left like tvOS. Driven by
/// the D-pad, the keyboard, the remotes or the mouse, all through `handleSettings`.
struct SettingsPanel: Equatable {
    enum Section: Int, CaseIterable {
        case profiles, remotes, watching, screenSaver, sounds, apps, movies, dedicatedTV, power, about
    }

    /// A page below a section's page, opened from one of its rows.
    enum Page: Hashable {
        case siriRemote, iPhone, pairedDevices, otherControllers
        /// A profile's name, colour and removal.
        case profile(String)
        /// Typing a name: an existing profile's, or nil for a new profile.
        case profileName(String?)
        /// A movie source: a folder by its path, a network share or a Jellyfin server by its id.
        case movieFolder(String), networkShare(String), jellyfinServer(String)
    }

    /// One row on a page.
    enum Row: Hashable {
        // Profiles
        case profile(String), addProfile
        case profileName, profileColor, switchProfile, removeProfile
        // Remotes and Devices
        case siriRemote, iPhone, otherControllers
        case remoteStatus, inputMonitoring, bluetooth
        case phoneRemote, pairingCode, pairedDevices, showAtLaunch
        case pairedDevice(String), noPairedDevices
        case controller
        // Playback
        case sleepTimer, autoSkip, autoNext, playbackCheck, websitePlayer
        // Screen Saver
        case wallpaper, photosFolder, aerialCategory, saverDelay, saverClock, saverPreview
        // Sounds and Haptics
        case audioOutput, feedback
        // Apps
        case addApp, arrangeApps, topShelfPreferences
        // Movies
        case movieFolder(String), addMovieFolder, networkShare(String), addNetworkShare
        case jellyfinServer(String), addJellyfinServer, removeMovieSource
        // Display
        case dedicatedTV, preferredDisplay, launchAtLogin
        // Power
        case keepMacAwake, lidOverride, screenOff, sleepMac
        // About
        case version, update, autoUpdate, source, report
    }

    /// A page opened below another, and the row on the page above to land on when it closes.
    struct Level: Equatable {
        let page: Page
        let from: Int
    }

    var section: Section = .profiles
    /// On the section's page (or a page below it) rather than the list of sections.
    var open = false
    /// The focused row on the page showing.
    var row = 0
    /// The pages opened below the section's page, deepest last.
    var path: [Level] = []
    /// Sleep Now and the Remove rows ask for a second press: this is the first. Anything else cancels it.
    var confirming = false
    /// 左右调了几次设置（真变了的才算）：焦点没动，但要和走一格一样响一声、震一下
    var changes = 0
    /// On a row of cards (screen saver types, live wallpaper categories): the focused card while it isn't
    /// the chosen one. Left and right move it; Select chooses. Nil puts focus on the chosen card.
    var card: Int?
    /// The name being typed on a name page.
    var typed = ""
    /// Input Monitoring, read when the Siri Remote page opens and when Mac TV comes back to the front.
    var inputMonitoring = false

    /// The page showing below the section's page, if any.
    var page: Page? { open ? path.last?.page : nil }

    /// Typing a name: the keyboard's letters and Space go to it.
    var typing: Bool {
        guard case .profileName = page else { return false }
        return true
    }
}

extension SettingsPanel.Section {
    var title: String {
        switch self {
        case .profiles: "Profiles"
        case .remotes: "Remotes and Devices"
        case .watching: "Playback"
        case .screenSaver: "Screen Saver"
        case .sounds: "Sounds and Haptics"
        case .apps: "Apps"
        case .movies: "Movies"
        case .dedicatedTV: "Display"
        case .power: "Power"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .profiles: "person.2.fill"
        case .remotes: "appletvremote.gen4.fill"
        case .watching: "play.tv.fill"
        case .screenSaver: "sparkles.tv.fill"
        case .sounds: "speaker.wave.2.fill"
        case .apps: "square.grid.2x2.fill"
        case .movies: "film.stack.fill"
        case .dedicatedTV: "tv.fill"
        case .power: "bolt.fill"
        case .about: "info.circle"
        }
    }

    /// The rows on its page. Profiles and Movies list what's been added (`TVController.settingsRows`).
    @MainActor var rows: [SettingsPanel.Row] {
        switch self {
        case .remotes: return [.siriRemote, .iPhone, .otherControllers]
        case .watching: return [.sleepTimer, .autoSkip, .autoNext, .playbackCheck, .websitePlayer]
        case .screenSaver:
            let wallpaper = ScreenSaverSettings.wallpaper
            var rows: [SettingsPanel.Row] = [.wallpaper]
            if wallpaper == .aerials, !Aerials.categories.isEmpty { rows.append(.aerialCategory) }
            if wallpaper == .photos { rows.append(.photosFolder) }
            rows.append(.saverDelay)
            if wallpaper != .flipClock { rows.append(.saverClock) }   // 翻页时钟自己就是钟，没有"显示时钟"
            rows.append(.saverPreview)
            return rows
        case .sounds: return [.audioOutput, .feedback]
        case .apps: return [.addApp, .arrangeApps, .topShelfPreferences]
        case .dedicatedTV: return [.dedicatedTV, .preferredDisplay, .launchAtLogin]
        case .power: return [.keepMacAwake, .lidOverride, .screenOff, .sleepMac]
        case .about: return [.version, .update, .autoUpdate, .source, .report]
        case .profiles, .movies: return []
        }
    }
}

extension SettingsPanel.Row {
    /// Left and right change this row's value in place: a switch, a stepper, colours, a row of cards.
    /// On any other row Left goes back.
    var adjustable: Bool {
        switch self {
        case .sleepTimer, .autoSkip, .autoNext, .websitePlayer, .wallpaper, .aerialCategory, .saverDelay, .saverClock,
             .feedback, .dedicatedTV, .preferredDisplay, .launchAtLogin, .keepMacAwake, .lidOverride, .autoUpdate,
             .showAtLaunch, .profileColor: true
        default: false
        }
    }

    /// Opens a page of Settings below this one, so Right opens it too.
    var opensPage: Bool {
        switch self {
        case .siriRemote, .iPhone, .otherControllers, .pairedDevices, .profile, .addProfile, .profileName,
             .movieFolder, .networkShare, .jellyfinServer: true
        default: false
        }
    }

    /// The header the row is listed under; it shows above the first row of its group.
    var group: String? {
        switch self {
        case .wallpaper: "TYPE"
        case .movieFolder, .addMovieFolder: "FOLDERS"
        case .networkShare, .addNetworkShare: "NETWORK SHARES"
        case .jellyfinServer, .addJellyfinServer: "JELLYFIN"
        default: nil
        }
    }
}

/// What a row shows: one layout for every row in Settings, apart from the rows of cards.
struct SettingsRowContent: Equatable {
    enum Accessory: Equatable {
        case none
        /// Opens something: a page, a sheet, a chooser.
        case chevron
        case toggle(Bool)
        /// A value stepped in place with left and right.
        case stepper
        /// The profile colours, with this one chosen.
        case colors(String)
    }

    var title: String
    var value: String?
    var accessory: Accessory = .none
    var symbol: String?
    var avatar: Profile?
    var battery: String?
    /// The profile watching now.
    var checked = false
    /// Red: press again to confirm.
    var warning = false
}

extension TVController {
    static let sleepTimerSteps = [0, 15, 30, 60, 90]

    /// Minutes left on the sleep timer; 0 when it's off.
    var sleepMinutesLeft: Int {
        sleepAt.map { max(1, Int(($0.timeIntervalSinceNow / 60).rounded(.up))) } ?? 0
    }

    func openSettings() {
        settings = SettingsPanel()
    }

    // MARK: Pages and rows

    /// The rows on the page Settings shows now.
    func settingsRows(_ panel: SettingsPanel) -> [SettingsPanel.Row] {
        switch panel.page {
        case nil:
            switch panel.section {
            case .profiles:
                return profiles.all.map { .profile($0.id) } + [.addProfile]
            case .movies:
                return movieFolders.map { .movieFolder($0.path) } + [.addMovieFolder]
                    + networkShares.shares.map { .networkShare($0.id) } + [.addNetworkShare]
                    + jellyfin.servers.map { .jellyfinServer($0.id) } + [.addJellyfinServer]
            default:
                return panel.section.rows
            }
        case .siriRemote: return [.remoteStatus, .inputMonitoring, .bluetooth]
        case .iPhone: return [.phoneRemote, .pairingCode, .pairedDevices, .showAtLaunch]
        case .pairedDevices:
            let devices = pairedDevices
            return devices.isEmpty ? [.noPairedDevices] : devices.map { .pairedDevice($0.id) }
        case .otherControllers: return [.controller, .bluetooth]
        case .profile(let id):
            return [.profileName, .profileColor] + (id == profile.id ? [] : [.switchProfile])
                + (id == Profile.mainID ? [] : [.removeProfile])
        case .profileName: return []
        case .movieFolder, .networkShare, .jellyfinServer: return [.removeMovieSource]
        }
    }

    private var pairedDevices: [PairingStore.Device] { remoteCoordinator.pairingStore.activeDevices() }

    /// Movies' folders, apart from network shares' (listed under Network Shares).
    private var movieFolders: [URL] { movieLibrary.folders.filter { networkShares.share(for: $0) == nil } }

    /// What the big picture on the left shows: the focused section, or the page showing.
    func settingsHero(_ panel: SettingsPanel) -> (title: String, symbol: String, avatar: Profile?) {
        switch panel.page {
        case nil: return (panel.section.title, panel.section.symbol, nil)
        case .siriRemote: return ("Siri Remote", "appletvremote.gen4.fill", nil)
        case .iPhone: return ("iPhone", "iphone", nil)
        case .pairedDevices: return ("Paired Devices", "iphone", nil)
        case .otherControllers: return ("Other Controllers", "gamecontroller.fill", nil)
        case .profile(let id):
            let shown = profiles.all.first { $0.id == id }
            return (shown?.name ?? "Profile", "person.fill", shown)
        case .profileName(let id):
            let base = id.flatMap { id in profiles.all.first { $0.id == id } }
            let preview = Profile(id: id ?? "new", name: panel.typed.isEmpty ? "?" : panel.typed, color: base?.color ?? profiles.nextColor)
            return (id == nil ? "New Profile" : "Name", "person.fill", preview)
        case .movieFolder(let path): return (URL(fileURLWithPath: path).lastPathComponent, "folder.fill", nil)
        case .networkShare(let id):
            return (networkShares.shares.first { $0.id == id }?.name ?? "Network Share", "externaldrive.connected.to.line.below.fill", nil)
        case .jellyfinServer(let id): return (jellyfin.servers.first { $0.id == id }?.name ?? "Jellyfin", "server.rack", nil)
        }
    }

    /// The short summary beside a section in the list; nil where there's nothing worth saying.
    func settingsDetail(_ section: SettingsPanel.Section) -> String? {
        switch section {
        case .profiles: return profile.name
        case .remotes:
            let parts = [SiriRemoteStatus.shared.connected ? "Siri Remote" : nil, pairedDevices.isEmpty ? nil : "iPhone", controller?.name]
            let connected = parts.compactMap { $0 }
            return connected.isEmpty ? nil : connected.joined(separator: ", ")
        case .screenSaver: return ScreenSaverSettings.wallpaper.title
        case .movies:
            let folders = movieFolders.count, others = networkShares.shares.count + jellyfin.servers.count
            if others == 0 { return folders == 0 ? nil : "\(folders) Folder\(folders == 1 ? "" : "s")" }
            return "\(folders + others) Sources"
        case .dedicatedTV:
            guard dedicatedTVMode else { return "Off" }
            return (["Full Screen"] + [availableTVDisplays.first(where: \.current)?.name].compactMap { $0 }).joined(separator: " · ")
        case .about: return updater.availableVersion != nil ? "Update Available" : "Version \(AppVersion.current)"
        case .watching, .sounds, .apps, .power: return nil
        }
    }

    /// What a row shows. `focused` puts a waiting "Press Again" on it.
    func settingsContent(_ row: SettingsPanel.Row, panel: SettingsPanel, focused: Bool) -> SettingsRowContent {
        typealias Content = SettingsRowContent
        let confirming = focused && panel.confirming
        func onOff(_ title: String, _ on: Bool) -> Content { Content(title: title, accessory: .toggle(on)) }
        func remove(_ title: String) -> Content { Content(title: confirming ? "Press Again to Remove" : title, warning: confirming) }
        switch row {
        case .profile(let id):
            let shown = profiles.all.first { $0.id == id }
            return Content(title: shown?.name ?? "", accessory: .chevron, avatar: shown, checked: id == profile.id)
        case .addProfile: return Content(title: "Add Profile…", accessory: .chevron, symbol: "plus")
        case .profileName:
            return Content(title: "Name", value: editedProfile(panel)?.name, accessory: .chevron)
        case .profileColor:
            return Content(title: "Color", accessory: .colors(editedProfile(panel)?.color ?? ""))
        case .switchProfile: return Content(title: "Switch to This Profile")
        case .removeProfile: return remove("Remove Profile")
        case .siriRemote:
            return Content(title: "Siri Remote", value: SiriRemoteStatus.shared.connected ? "Connected" : "Not Connected",
                           accessory: .chevron, symbol: "appletvremote.gen4.fill")
        case .iPhone:
            let count = pairedDevices.count
            return Content(title: "iPhone", value: count == 0 ? "Not Paired" : "\(count) Paired", accessory: .chevron, symbol: "iphone")
        case .otherControllers:
            return Content(title: "Other Controllers", value: controller?.name ?? "None", accessory: .chevron, symbol: "gamecontroller.fill")
        case .remoteStatus: return Content(title: "Status", value: SiriRemoteStatus.shared.connected ? "Connected" : "Not Connected")
        case .inputMonitoring: return Content(title: "Input Monitoring", value: panel.inputMonitoring ? "Allowed" : "Not Allowed")
        case .bluetooth: return Content(title: "Bluetooth Settings…")
        case .phoneRemote: return Content(title: "Show QR Code", accessory: .chevron)
        case .pairingCode: return Content(title: "Pairing Code", value: remoteToken)
        case .pairedDevices: return Content(title: "Paired Devices", accessory: .chevron)
        case .showAtLaunch: return onOff("Show at Launch", preferences.showPairingAtLaunch)
        case .pairedDevice(let id):
            let device = pairedDevices.first { $0.id == id }
            var content = remove(device?.name ?? "iPhone")
            if !confirming, device?.isGuest == true { content.value = "Guest" }
            return content
        case .noPairedDevices: return Content(title: "No Paired Devices")
        case .controller:
            guard let controller else { return Content(title: "Game Controller", value: "Not Connected") }
            let charge = controller.battery.map { " · \(Int($0 * 100))%" } ?? ""
            return Content(title: "Game Controller", value: controller.name + charge,
                           battery: controller.battery != nil || controller.charging ? controller.batterySymbol : nil)
        case .sleepTimer:
            let minutes = sleepMinutesLeft
            return Content(title: "Sleep Timer", value: minutes == 0 ? "Off" : "\(minutes) Minute\(minutes == 1 ? "" : "s") Left",
                           accessory: .stepper)
        case .autoSkip: return onOff("Skip Intros, Recaps and Ads", autoSkip)
        case .autoNext: return onOff("Autoplay Next Episode", autoNext)
        case .playbackCheck: return Content(title: "Playback Check", accessory: .chevron)
        case .websitePlayer: return Content(title: "Website Player", value: websitePlayerName, accessory: .stepper)
        case .wallpaper, .aerialCategory: return Content(title: "")   // drawn as cards
        case .photosFolder:
            return Content(title: "Choose Folder…", value: ScreenSaverSettings.photosFolder.lastPathComponent, accessory: .chevron)
        case .saverDelay: return Content(title: "Start After", value: "\(ScreenSaverSettings.delayMinutes) Minutes", accessory: .stepper)
        case .saverClock: return onOff("Show Clock", ScreenSaverSettings.showClock)
        case .saverPreview: return Content(title: "Preview", accessory: .chevron)
        case .audioOutput: return Content(title: "Audio Output", value: currentAudioDevice?.name ?? "Speakers", accessory: .chevron)
        case .feedback: return onOff("Sounds and Haptics", feedback.enabled)
        case .addApp: return Content(title: "Add App", accessory: .chevron)
        case .arrangeApps: return Content(title: "Arrange Apps", accessory: .chevron)
        case .topShelfPreferences: return Content(title: "Top Shelf", accessory: .chevron)
        case .movieFolder(let path):
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            let parent = folder.deletingLastPathComponent()
            let place = parent.path == NSHomeDirectory() ? "Home" : (parent.path as NSString).abbreviatingWithTildeInPath
            return Content(title: folder.lastPathComponent, value: place, accessory: .chevron, symbol: "folder.fill")
        case .addMovieFolder: return Content(title: "Add Folder…", accessory: .chevron, symbol: "plus")
        case .networkShare(let id):
            let share = networkShares.shares.first { $0.id == id }
            return Content(title: share?.name ?? "", value: share?.host, accessory: .chevron,
                           symbol: "externaldrive.connected.to.line.below.fill")
        case .addNetworkShare: return Content(title: "Add Network Share…", accessory: .chevron, symbol: "plus")
        case .jellyfinServer(let id):
            let server = jellyfin.servers.first { $0.id == id }
            return Content(title: server?.name ?? "", value: server.map { URL(string: $0.address)?.host ?? $0.address },
                           accessory: .chevron, symbol: "server.rack")
        case .addJellyfinServer: return Content(title: "Sign In to Jellyfin…", accessory: .chevron, symbol: "plus")
        case .removeMovieSource:
            switch panel.page {
            case .networkShare: return remove("Remove Share")
            case .jellyfinServer: return remove("Remove Server")
            default: return remove("Remove Folder")
            }
        case .dedicatedTV: return onOff("Full Screen", dedicatedTVMode)
        case .preferredDisplay: return Content(title: "Preferred Display", value: preferredTVDisplayName, accessory: .stepper)
        case .launchAtLogin:
            return loginNeedsApproval ? Content(title: "Open at Login", value: "Approval Needed") : onOff("Open at Login", launchAtLogin)
        case .keepMacAwake: return onOff("Keep Mac Awake", keepMacAwake)
        case .lidOverride: return onOff("Stay Awake With Lid Closed", lidOverride)
        case .screenOff: return Content(title: "Turn Off Display")
        case .sleepMac: return Content(title: confirming ? "Press Again to Sleep" : "Sleep Now", warning: confirming)
        case .version: return Content(title: "Version", value: AppVersion.current)
        case .update:
            let state: String
            switch updater.state {
            case .failed(let message): state = message
            case .available(let version, _), .ready(let version, _): state = "Install \(version)"
            case .downloading(let fraction): state = "Downloading \(Int(fraction * 100))%"
            case .installing: state = "Installing…"
            case .checking: state = "Checking…"
            case .upToDate: state = "Up to Date"
            case .idle: state = "Check Now"
            }
            return Content(title: "Software Update", value: state)
        case .autoUpdate: return onOff("Automatic Updates", updater.automatic)
        case .source: return Content(title: "Source Code", value: "github.com/kaisenyao/mac-tv")
        case .report: return Content(title: "Copy Diagnostics Report")
        }
    }

    /// The profile a profile page (or its name page) is about.
    private func editedProfile(_ panel: SettingsPanel) -> Profile? {
        switch panel.page {
        case .profile(let id), .profileName(let id?): profiles.all.first { $0.id == id }
        default: nil
        }
    }

    // MARK: Remote presses

    func handleSettings(_ command: RemoteCommand) {
        guard var panel = settings else { return }
        guard panel.open else {
            let sections = SettingsPanel.Section.allCases
            switch command {
            case .back:
                settings = nil
                return
            case .move(.up):
                panel.section = sections[max(0, panel.section.rawValue - 1)]
            case .move(.down):
                panel.section = sections[min(sections.count - 1, panel.section.rawValue + 1)]
            case .move(.right), .select:
                settings = panel
                openSection(panel.section)
                return
            default:
                break
            }
            settings = panel
            return
        }
        if panel.typing {
            typeName(command, panel)
            return
        }

        let rows = settingsRows(panel)
        panel.row = min(panel.row, max(rows.count - 1, 0))
        // Anything but a second press cancels a waiting "Press Again".
        if case .select = command {} else { panel.confirming = false }
        guard rows.indices.contains(panel.row) else {
            if case .back = command { closeSettingsPage(&panel) }
            settings = panel
            return
        }
        let row = rows[panel.row]
        switch command {
        case .back:
            closeSettingsPage(&panel)
        case .move(.left) where !row.adjustable:
            closeSettingsPage(&panel)
        case .move(let direction) where direction == .up || direction == .down:
            let next = direction == .up ? max(0, panel.row - 1) : min(rows.count - 1, panel.row + 1)
            if next != panel.row {
                panel.row = next
                panel.card = nil   // into a row of cards, focus lands on the chosen one
            }
        case .move(.right) where row.opensPage:
            settings = panel
            activateSetting(row)
            return
        case .move(let direction) where direction == .left || direction == .right:
            settings = panel
            adjustSetting(row, forward: direction == .right)
            return
        case .select:
            settings = panel
            activateSetting(row)
            return
        default:
            break
        }
        settings = panel
    }

    /// Opens a section's page from the list.
    func openSection(_ section: SettingsPanel.Section) {
        settings = SettingsPanel(section: section, open: true)
    }

    private func openSettingsPage(_ page: SettingsPanel.Page) {
        guard var panel = settings, panel.open else { return }
        panel.path.append(.init(page: page, from: panel.row))
        panel.row = 0
        panel.card = nil
        panel.confirming = false
        switch page {
        case .siriRemote: panel.inputMonitoring = Self.inputMonitoringAllowed
        case .profileName(let id): panel.typed = id.flatMap { id in profiles.all.first { $0.id == id }?.name } ?? ""
        default: break
        }
        settings = panel
    }

    /// Back: up a page, landing on the row it was opened from, or back to the list of sections.
    private func closeSettingsPage(_ panel: inout SettingsPanel) {
        if let level = panel.path.popLast() {
            panel.row = level.from
        } else {
            panel.open = false
            panel.row = 0
        }
        panel.card = nil
        panel.confirming = false
        panel.typed = ""
    }

    /// Puts focus on a row of the page showing, if it's there.
    private func focusSetting(_ row: SettingsPanel.Row) {
        guard let panel = settings, let index = settingsRows(panel).firstIndex(of: row) else { return }
        settings?.row = index
    }

    /// Sleep Now and Remove: the first press asks again, the second does it. True on the second.
    private func confirmSetting() -> Bool {
        if settings?.confirming == true {
            settings?.confirming = false
            return true
        }
        settings?.confirming = true
        return false
    }

    /// Select, Return, Space or a click on a row.
    func activateSetting(_ row: SettingsPanel.Row) {
        guard let panel = settings else { return }
        // A click focuses the row first, and cancels a "Press Again" waiting on another.
        if let index = settingsRows(panel).firstIndex(of: row), index != panel.row {
            settings?.row = index
            settings?.confirming = false
            settings?.card = nil
        }
        switch row {
        case .profile(let id): openSettingsPage(.profile(id))
        case .addProfile: openSettingsPage(.profileName(nil))
        case .profileName: if let edited = editedProfile(panel) { openSettingsPage(.profileName(edited.id)) }
        case .profileColor: stepProfileColor(by: 1, wrap: true)
        case .switchProfile: if let edited = editedProfile(panel) { switchProfile(to: edited.id) }
        case .removeProfile:
            guard let edited = editedProfile(panel), confirmSetting() else { return }
            removeProfile(edited.id)
            closeSettingsPage()
        case .siriRemote: openSettingsPage(.siriRemote)
        case .iPhone: openSettingsPage(.iPhone)
        case .otherControllers: openSettingsPage(.otherControllers)
        case .pairedDevices: openSettingsPage(.pairedDevices)
        case .inputMonitoring:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                NSWorkspace.shared.open(url)
            }
        case .bluetooth: PairSheet.openBluetoothSettings()
        case .phoneRemote: pairing = true
        case .showAtLaunch: preferences.showPairingAtLaunch.toggle()
        case .pairedDevice(let id): if confirmSetting() { remoteCoordinator.removePairedDevice(id) }
        case .remoteStatus, .pairingCode, .noPairedDevices, .controller, .version, .source: break
        case .wallpaper, .aerialCategory: chooseCard(on: row, at: settings?.card ?? cards(on: row).chosen)
        case .photosFolder: ScreenSaverSettings.choosePhotosFolder()
        case .saverDelay: ScreenSaverSettings.stepDelay(1, wrap: true)
        case .saverClock: ScreenSaverSettings.showClock.toggle()
        case .saverPreview: showScreensaver()   // over Settings; any press comes back here
        case .sleepTimer: stepSleepTimer(by: 1, wrap: true)
        case .autoSkip: autoSkip.toggle()
        case .autoNext: autoNext.toggle()
        case .playbackCheck: openPlaybackCheck()
        case .websitePlayer: stepWebsitePlayer()
        case .audioOutput: openAudioPicker()   // over Settings, like the other sheets it opens
        case .feedback: feedback.enabled.toggle()
        case .addApp:
            // Adding closes on Home with the new app focused, so Settings goes first.
            settings = nil
            adder = AppAdder()
        case .arrangeApps: openOrganizer()
        case .topShelfPreferences: openTopShelfPreferences()
        case .movieFolder(let path): openSettingsPage(.movieFolder(path))
        case .networkShare(let id): openSettingsPage(.networkShare(id))
        case .jellyfinServer(let id): openSettingsPage(.jellyfinServer(id))
        case .addMovieFolder: chooseMovieFolders()
        case .addNetworkShare: openMoviesForm(jellyfin: false)
        case .addJellyfinServer: openMoviesForm(jellyfin: true)
        case .removeMovieSource:
            guard let page = panel.page, confirmSetting() else { return }
            removeMovieSource(page)
            closeSettingsPage()
        case .dedicatedTV: setDedicatedTVMode(!dedicatedTVMode)
        case .preferredDisplay: stepTVDisplay(1, wrap: true)
        case .launchAtLogin: setLaunchAtLogin(!launchAtLogin)
        case .keepMacAwake: keepMacAwake.toggle()
        case .lidOverride: lidOverride.toggle()
        case .screenOff: SystemControl.displayOff()
        case .sleepMac:
            guard confirmSetting() else { return }
            goHome()
            SystemControl.sleepNow()
        case .update: updater.activate()
        case .autoUpdate: updater.automatic.toggle()
        case .report: DiagnosticReport.copy(from: self)
        }
    }

    private func closeSettingsPage() {
        guard var panel = settings else { return }
        closeSettingsPage(&panel)
        settings = panel
    }

    /// Left and right: step a value, switch a setting off and on, or move along a row of cards.
    private func adjustSetting(_ row: SettingsPanel.Row, forward: Bool) {
        let step = forward ? 1 : -1
        guard let panel = settings else { return }
        let before = settingsContent(row, panel: panel, focused: true)
        switch row {
        case .wallpaper, .aerialCategory:
            // Only the focus moves (and the move sounds): the chosen card changes with Select.
            let cards = cards(on: row)
            let next = min(max((panel.card ?? cards.chosen) + step, 0), cards.count - 1)
            settings?.card = next == cards.chosen ? nil : next
            return
        case .dedicatedTV: setDedicatedTVMode(forward)
        case .preferredDisplay: stepTVDisplay(step)
        case .launchAtLogin: setLaunchAtLogin(forward)
        case .sleepTimer: stepSleepTimer(by: step, wrap: false)
        case .websitePlayer:
            let choice: BrowserChoice = forward ? .brave : .embedded
            if browserPreferences.choice(for: profile.id) != choice, !setWebsitePlayer(choice.rawValue) {
                showToast("Brave Browser Isn’t Installed")
            }
        case .saverDelay: ScreenSaverSettings.stepDelay(step)
        case .saverClock: ScreenSaverSettings.showClock = forward
        case .feedback: feedback.enabled = forward
        case .autoSkip: autoSkip = forward
        case .autoNext: autoNext = forward
        case .keepMacAwake: keepMacAwake = forward
        case .lidOverride: lidOverride = forward
        case .autoUpdate: updater.automatic = forward
        case .showAtLaunch: preferences.showPairingAtLaunch = forward
        case .profileColor: stepProfileColor(by: step, wrap: false)
        default: return
        }
        // 值真变了才响（到头了、开关本来就是这样、没装 Brave 换不过去的，不响）
        if let now = settings, settingsContent(row, panel: now, focused: true) != before { settings?.changes += 1 }
    }

    /// Moves the sleep timer to the next or previous step: Off, 15, 30, 60, 90 minutes.
    func stepSleepTimer(by step: Int, wrap: Bool) {
        let steps = Self.sleepTimerSteps
        let current = steps.firstIndex { $0 >= sleepMinutesLeft } ?? 0
        var next = current + step
        next = wrap ? (next + steps.count) % steps.count : min(max(next, 0), steps.count - 1)
        guard next != current else { return }
        setSleepTimer(minutes: steps[next])
    }

    // MARK: Rows of cards

    private var aerialChoices: [String?] { [nil] + Aerials.categories.map(\.id) }

    /// How many cards a row of cards has, and which one is chosen.
    func cards(on row: SettingsPanel.Row) -> (count: Int, chosen: Int) {
        switch row {
        case .wallpaper:
            let all = ScreenSaverSettings.Wallpaper.allCases
            return (all.count, all.firstIndex(of: ScreenSaverSettings.wallpaper) ?? 0)
        case .aerialCategory:
            let choices = aerialChoices
            return (choices.count, choices.firstIndex(of: ScreenSaverSettings.aerialCategory) ?? 0)
        default:
            return (0, 0)
        }
    }

    /// Chooses a card: Select on the focused one, or a click on any. Choosing the chosen one does nothing.
    func chooseCard(on row: SettingsPanel.Row, at index: Int) {
        focusSetting(row)
        settings?.card = nil
        switch row {
        case .wallpaper:
            let all = ScreenSaverSettings.Wallpaper.allCases
            guard all.indices.contains(index), all[index] != ScreenSaverSettings.wallpaper else { return }
            ScreenSaverSettings.wallpaper = all[index]
        case .aerialCategory:
            let choices = aerialChoices
            guard choices.indices.contains(index), choices[index] != ScreenSaverSettings.aerialCategory else { return }
            ScreenSaverSettings.aerialCategory = choices[index]
        default:
            break
        }
    }

    // MARK: Profiles, remotes, movie sources

    private func stepProfileColor(by step: Int, wrap: Bool) {
        guard let edited = editedProfile(settings ?? SettingsPanel()) else { return }
        let colors = ProfileStore.colors
        let current = colors.firstIndex(of: edited.color) ?? 0
        var next = current + step
        next = wrap ? (next + colors.count) % colors.count : min(max(next, 0), colors.count - 1)
        if next != current { setProfileColor(colors[next], for: edited.id) }
    }

    /// Typing on a name page: the same keys as "Who's Watching?". Return saves; Back leaves the name as it was.
    private func typeName(_ command: RemoteCommand, _ panel: SettingsPanel) {
        var panel = panel
        guard case .profileName(let id) = panel.page else { return }
        if case .back = command {
            closeSettingsPage(&panel)
            settings = panel
            return
        }
        let done = ProfileName.apply(command, to: &panel.typed)
        settings = panel
        let name = panel.typed.trimmingCharacters(in: .whitespaces)
        guard done, !name.isEmpty else { return }
        var added: Profile?
        if let id { renameProfile(id, to: name) } else { added = profiles.add(named: name) }
        closeSettingsPage(&panel)
        settings = panel
        if let added { focusSetting(.profile(added.id)) }
    }

    static var inputMonitoringAllowed: Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }

    /// Back from System Settings: Input Monitoring may have just been allowed.
    func refreshInputMonitoring() {
        guard settings?.page == .siriRemote else { return }
        let allowed = Self.inputMonitoringAllowed
        if settings?.inputMonitoring != allowed { settings?.inputMonitoring = allowed }
    }

    /// The Mac's folder chooser, as the Movies app's Add Folder… opens it.
    private func chooseMovieFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders with movies for Mac TV"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            MainActor.assumeIsolated { self?.addMovieFolders(panel.urls) }
        }
    }

    /// Adds folders to Movies, which the Movies app and the phone show too. Focus stays on Add Folder….
    func addMovieFolders(_ folders: [URL]) {
        folders.forEach(movieLibrary.add)
        objectWillChange.send()
        focusSetting(.addMovieFolder)
    }

    /// Add Network Share… and Sign In to Jellyfin… are the Movies app's own forms, over its Folders sheet,
    /// where the share or server shows up once it's added.
    private func openMoviesForm(jellyfin server: Bool) {
        settings = nil
        openMovies()
        movies?.folderRow = movieLibrary.suggestedFolders.count + jellyfin.servers.count + (server ? 1 : 0)
        movies?.shareForm = ShareForm(jellyfin: server)
    }

    /// Takes a source out of Movies. A folder stays on disk; a share stays connected in Finder.
    private func removeMovieSource(_ page: SettingsPanel.Page) {
        switch page {
        case .movieFolder(let path):
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            if movieLibrary.isWatched(folder) { movieLibrary.toggle(folder) }
        case .networkShare(let id): networkShares.remove(id)
        case .jellyfinServer(let id): jellyfin.remove(id)
        default: return
        }
        objectWillChange.send()
    }
}

// MARK: Views

struct SettingsSheet: View {
    @ObservedObject var tv: TVController
    @ObservedObject private var updater: Updater
    @ObservedObject private var siriRemote = SiriRemoteStatus.shared
    @Environment(\.canvasSize) private var canvas
    @Namespace private var focusSpace

    init(tv: TVController) {
        _tv = ObservedObject(wrappedValue: tv)
        _updater = ObservedObject(wrappedValue: tv.updater)
    }

    var body: some View {
        let panel = tv.settings ?? SettingsPanel()
        HStack(spacing: 0) {
            hero(panel)
                .frame(width: 780, alignment: .leading)
                .padding(.leading, 120)
            Group {
                if !panel.open {
                    sections(panel)
                } else if panel.typing {
                    nameEntry(panel).id(panel.page)
                } else {
                    // A page opened from a row cross-fades in place, as a section's page does from the list.
                    page(panel).id(panel.page)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.trailing, 120)
            .padding(.leading, 20)
        }
        .foregroundStyle(.white)
        .frame(width: canvas.width, height: canvas.height)
        .animation(Motion.focus, value: panel)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            tv.refreshInputMonitoring()
        }
    }

    private func hero(_ panel: SettingsPanel) -> some View {
        let hero = tv.settingsHero(panel)
        return VStack(alignment: .leading, spacing: 34) {
            Text("SETTINGS").font(.tv(.caption2, emphasized: true)).tracking(1.6).opacity(0.5)
            ZStack {
                if let avatar = hero.avatar {
                    ProfileAvatar(profile: avatar, size: 300)
                        .transition(.opacity)
                } else {
                    Image(systemName: hero.symbol)
                        .font(.system(size: 130, weight: .regular))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 300, height: 300)
                        // A plain tile, not glass: Settings sits on a frosted backdrop, and glass there would read flat.
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 72, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 72, style: .continuous).strokeBorder(.white.opacity(0.14)))
                        .transition(.opacity)
                }
            }
            Text(hero.title).font(.tv(.title2, emphasized: true)).lineLimit(1)
                .id(hero.title)
                .transition(.opacity)
        }
        .animation(Motion.appear, value: hero.title)
        .animation(Motion.appear, value: hero.symbol)
    }

    private func sections(_ panel: SettingsPanel) -> some View {
        VStack(spacing: 10) {
            ForEach(SettingsPanel.Section.allCases, id: \.self) { section in
                let content = SettingsRowContent(title: section.title, value: tv.settingsDetail(section),
                                                 accessory: .chevron, symbol: section.symbol)
                SettingsRow(content: content, focused: panel.section == section, focusSpace: focusSpace) {
                    tv.openSection(section)
                }
                .equatable()
            }
        }
    }

    private func page(_ panel: SettingsPanel) -> some View {
        let rows = tv.settingsRows(panel)
        let focus = min(panel.row, rows.count - 1)
        return ScrollViewReader { scroller in
            // Scrolls only when a list is longer than the screen (many paired phones, say), and only to keep
            // the focused row in view.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    // 按行本身认（不按第几行）：换了屏保类型、少了一行"显示时钟"时，那一行淡出、下面的平滑往上挪，
                    // 不会变成"第三行的字突然换成预览、最后一行一下子没了"
                    ForEach(Array(rows.enumerated()), id: \.element) { index, row in
                        VStack(alignment: .leading, spacing: 12) {
                            if let group = row.group, index == 0 || rows[index - 1].group != group {
                                Text(group).font(.tv(.caption2, emphasized: true)).tracking(1.4).opacity(0.5)
                                    .padding(.leading, 6).padding(.top, index == 0 ? 0 : 14)
                            }
                            rowView(row, focused: index == focus, panel: panel)
                        }
                        .id(row)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                    }
                }
                .padding(.vertical, 60)
                .frame(minHeight: canvas.height)
            }
            .scrollDisabled(true)
            .scrollClipDisabled()
            .onAppear { if rows.indices.contains(focus) { scroller.scrollTo(rows[focus], anchor: .center) } }
            .onChange(of: focus) { _, focus in
                guard rows.indices.contains(focus) else { return }
                withAnimation(Motion.focus) { scroller.scrollTo(rows[focus], anchor: .center) }
            }
        }
        .animation(Motion.focus, value: rows)
    }

    @ViewBuilder
    private func rowView(_ row: SettingsPanel.Row, focused: Bool, panel: SettingsPanel) -> some View {
        switch row {
        case .wallpaper:
            WallpaperCards(chosen: ScreenSaverSettings.wallpaper, focused: focused ? panel.card ?? -1 : nil,
                           aerialCategory: ScreenSaverSettings.aerialCategory, photos: ScreenSaverSettings.photosFolder.path) {
                tv.chooseCard(on: .wallpaper, at: $0)
            }
            .equatable()
        case .aerialCategory:
            AerialCards(chosen: ScreenSaverSettings.aerialCategory, focused: focused ? panel.card ?? -1 : nil) {
                tv.chooseCard(on: .aerialCategory, at: $0)
            }
            .equatable()
        default:
            SettingsRow(content: tv.settingsContent(row, panel: panel, focused: focused), focused: focused, focusSpace: focusSpace) {
                tv.activateSetting(row)
            }
            .equatable()
        }
    }

    /// Typing a profile's name: the keyboard, or the phone's Type on TV. Return saves.
    private func nameEntry(_ panel: SettingsPanel) -> some View {
        let renaming = panel.page != .profileName(nil)
        return VStack(spacing: 30) {
            ProfileNameField(name: panel.typed)
            ShelfButton(title: renaming ? "Done" : "Create Profile", focused: !panel.typed.isEmpty, glass: false) {
                tv.handle(.select)
            }
        }
    }
}

/// One row of Settings, the same everywhere: height, leading icon column, value colour, switches, steppers
/// and chevrons, and the focus platter. Focus lifts the platter out around the row and the text stays in
/// its column, so a focused row never sits out of line with the rest.
struct SettingsRow: View, Equatable {
    let content: SettingsRowContent
    let focused: Bool
    let focusSpace: Namespace.ID
    let action: () -> Void

    nonisolated static func == (lhs: SettingsRow, rhs: SettingsRow) -> Bool {
        lhs.content == rhs.content && lhs.focused == rhs.focused && lhs.focusSpace == rhs.focusSpace
    }

    var body: some View {
        HStack(spacing: 22) {
            if let avatar = content.avatar {
                ProfileAvatar(profile: avatar, size: 40)
            } else if let symbol = content.symbol {
                Image(systemName: symbol).font(.system(size: 27, weight: .medium)).frame(width: 40)
            }
            Text(content.title).font(.tv(.body)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let value = content.value {
                HStack(spacing: 14) {
                    if content.accessory == .stepper, focused { Image(systemName: "chevron.left") }
                    Text(value).font(.tv(.caption1)).monospacedDigit().lineLimit(1).contentTransition(.numericText())
                    if content.accessory == .stepper, focused { Image(systemName: "chevron.right") }
                }
                .font(.system(size: 20, weight: .semibold))
                .opacity(0.55)
                .layoutPriority(1)   // a long value (a controller's name) keeps its room; the title gives way first
            }
            if let battery = content.battery { Image(systemName: battery).font(.system(size: 26)) }
            if content.checked { Image(systemName: "checkmark").font(.system(size: 22, weight: .bold)) }
            switch content.accessory {
            case .toggle(let on): SettingSwitch(on: on)
            case .chevron: Image(systemName: "chevron.right").font(.system(size: 20, weight: .semibold)).opacity(0.4)
            case .colors(let chosen): ProfileColors(chosen: chosen, focused: focused)
            case .none, .stepper: EmptyView()
            }
        }
        .padding(.horizontal, 30)
        .frame(height: 78)
        // tvOS focus: a bright white platter with dark text; a row asking to press again turns red.
        .foregroundStyle(focused && !content.warning ? .black : .white)
        .background {
            let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
            if focused {
                // One platter that glides from row to row as focus moves, like tvOS. Its shadow is the
                // platter's alone, not cast by the text on it.
                shape.fill(content.warning ? Color(hex: "#FF453A") : .white)
                    .padding(.horizontal, -10)
                    .padding(.vertical, -4)
                    .shadow(color: .black.opacity(0.4), radius: 20, y: 12)
                    .matchedGeometryEffect(id: "focus", in: focusSpace)
            } else {
                shape.fill(.white.opacity(0.07))
            }
        }
        .animation(Motion.focus, value: focused)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

/// The six profile colours as dots, the chosen one ringed; left and right choose.
private struct ProfileColors: View {
    let chosen: String
    let focused: Bool

    var body: some View {
        HStack(spacing: 16) {
            ForEach(ProfileStore.colors, id: \.self) { color in
                Circle().fill(Color(hex: color))
                    .frame(width: 30, height: 30)
                    .overlay {
                        if color == chosen {
                            Circle().strokeBorder(focused ? Color.black : .white, lineWidth: 3).padding(-6)
                        }
                    }
            }
        }
        .animation(Motion.focus, value: chosen)
    }
}

/// The checkmark on a chosen card. It moves at once when a card is chosen: fading or growing it in left a
/// small see-through blob over the card for a moment, which read as a purple square flashing on Drifting Color.
private struct ChosenMark: View {
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: "checkmark.circle.fill").font(.system(size: size))
            .symbolRenderingMode(.palette).foregroundStyle(.black, .white)
            .padding(size / 3)
            .transition(.identity)
    }
}

/// The screen saver's types side by side. Left and right move focus (the card lifts, with the white
/// border); Select or a click chooses one, and only then the checkmark moves and the type changes.
private struct WallpaperCards: View, Equatable {
    let chosen: ScreenSaverSettings.Wallpaper
    /// The focused card while the row has focus (-1 for the chosen card); nil when focus is elsewhere.
    let focused: Int?
    /// What the Aerials and My Photos cards show; a change draws them again.
    let aerialCategory: String?
    let photos: String
    let choose: (Int) -> Void

    nonisolated static func == (lhs: WallpaperCards, rhs: WallpaperCards) -> Bool {
        lhs.chosen == rhs.chosen && lhs.focused == rhs.focused && lhs.aerialCategory == rhs.aerialCategory && lhs.photos == rhs.photos
    }

    var body: some View {
        let all = ScreenSaverSettings.Wallpaper.allCases
        let lifted = focused.map { $0 < 0 ? all.firstIndex(of: chosen) ?? 0 : $0 }
        HStack(spacing: 18) {
            ForEach(Array(all.enumerated()), id: \.element) { index, wallpaper in
                let isChosen = wallpaper == chosen, isLifted = index == lifted
                VStack(alignment: .leading, spacing: 10) {
                    WallpaperThumb(wallpaper: wallpaper)
                        .frame(height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .strokeBorder(.white.opacity(isLifted ? 1 : isChosen && lifted == nil ? 0.6 : 0.12),
                                              lineWidth: isLifted || (isChosen && lifted == nil) ? 4 : 1)
                        }
                        .overlay(alignment: .topTrailing) { if isChosen { ChosenMark() } }
                        .scaleEffect(isLifted ? 1.05 : 1)
                        .shadow(color: .black.opacity(isLifted ? 0.45 : 0), radius: 18, y: 12)
                    Text(wallpaper.title).font(.tv(.caption2))
                        .opacity(isChosen || isLifted ? 1 : 0.6).padding(.leading, 4)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { choose(index) }
            }
        }
        .animation(Motion.focus, value: lifted)
        .padding(.bottom, 14)
    }
}

/// Apple's live wallpaper categories, the same as System Settings › Wallpaper, in two rows of four so every
/// name fits. They work like the types above: left and right move focus, Select or a click chooses.
private struct AerialCards: View, Equatable {
    let chosen: String?
    let focused: Int?
    let choose: (Int) -> Void

    nonisolated static func == (lhs: AerialCards, rhs: AerialCards) -> Bool { lhs.chosen == rhs.chosen && lhs.focused == rhs.focused }

    var body: some View {
        let choices: [(id: String?, name: String)] = [(nil, "Shuffle All")] + Aerials.categories.map { ($0.id, $0.name) }
        let lifted = focused.map { $0 < 0 ? choices.firstIndex { $0.id == chosen } ?? 0 : $0 }
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 4), spacing: 14) {
            ForEach(Array(choices.enumerated()), id: \.element.name) { index, choice in
                let isChosen = choice.id == chosen, isLifted = index == lifted
                VStack(alignment: .leading, spacing: 8) {
                    Color.clear
                        .overlay {
                            if let thumb = Aerials.thumbnail(forCategory: choice.id), let image = ScreenImages.thumbnail(thumb) {
                                Image(nsImage: image).resizable().scaledToFill()
                            }
                        }
                        .frame(height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(.white.opacity(isLifted ? 1 : isChosen && lifted == nil ? 0.6 : 0.12),
                                              lineWidth: isLifted || (isChosen && lifted == nil) ? 3 : 1)
                        }
                        .overlay(alignment: .topTrailing) { if isChosen { ChosenMark(size: 22) } }
                        .scaleEffect(isLifted ? 1.06 : 1)
                    Text(choice.name).font(.tv(.caption2)).lineLimit(1)
                        .opacity(isChosen || isLifted ? 1 : 0.6).padding(.leading, 2)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { choose(index) }
            }
        }
        .animation(Motion.focus, value: lifted)
        .padding(.bottom, 10)
    }
}

/// An on/off switch drawn like the phone remote's.
struct SettingSwitch: View {
    let on: Bool

    var body: some View {
        Capsule()
            // Mid grey when off, so it shows on a dark row and on the white focus platter alike.
            .fill(on ? Color(hex: "#3DDC84") : Color(white: 0.55, opacity: 0.5))
            .frame(width: 64, height: 36)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(.white).frame(width: 28, height: 28).padding(4)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            }
            .animation(.snappy(duration: 0.2), value: on)
    }
}
