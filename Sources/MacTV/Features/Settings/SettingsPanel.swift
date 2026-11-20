import AppKit
import IOKit.hid
import SwiftUI

/// The TV's Settings, laid out as Apple TV's: a list of sections, each opening a page of rows, and rows with ›
/// opening a page of their own. The focused section's symbol (or the page's) is large on the left like tvOS.
/// Driven by the D-pad, the keyboard, the remotes or the mouse, all through `handleSettings`.
struct SettingsPanel: Equatable {
    /// tvOS's sections, in tvOS's order, for the ones a Mac has.
    enum Section: Int, CaseIterable {
        case general, profiles, videoAndAudio, screenSaver, remotes, apps, system
    }

    /// A page below a section's page, opened from one of its rows.
    enum Page: Hashable {
        case siriRemote, iPhone, otherControllers
        /// A paired phone, to remove.
        case pairedDevice(String)
        /// A profile's name, photo and removal.
        case profile(String)
        /// Typing a name: an existing profile's, or nil for a new profile.
        case profileName(String?)
        /// Apps › Movies, like tvOS's settings for one app: its folders, network shares and Jellyfin servers.
        case movies
        /// A movie source: a folder by its path, a network share or a Jellyfin server by its id.
        case movieFolder(String), networkShare(String), jellyfinServer(String)
        /// Movies' forms: Add Network Share… and Sign In to Jellyfin….
        case addNetworkShare, addJellyfinServer
        /// System › About and System › Software Updates.
        case about, softwareUpdates
        /// System › User Guide: its sections, and one section to read.
        case userGuide, guideSection(Int)
        /// Remove Profile, Remove Photo, Remove Device or a movie source's Remove, asked about first: Cancel, then the
        /// removal. Focus starts on Cancel, so a stray press removes nothing.
        case confirmRemoval(Row)
    }

    /// One row on a page.
    enum Row: Hashable {
        // General
        case twentyFourHour, launchAtLogin, sleepTimer, autoSkip, autoNext, websitePlayer
        // Profiles and Accounts
        case profile(String), addProfile
        case profileName, profilePhoto, removePhoto, switchProfile, removeProfile
        // Video and Audio
        case dedicatedTV, preferredDisplay, audioOutput, feedback
        // Screen Saver
        case wallpaper, photosFolder, aerialCategory, saverDelay, saverClock, saverPreview
        // Remotes and Devices, and Connect a Remote
        case siriRemote, iPhone, otherControllers
        case remoteStatus, remoteBattery, bluetooth
        case phoneAccess, pairedDevice(String), removePairedDevice
        case controller, controllerBattery
        /// First-run setup's remote step: Set Up Later, or Continue once something is connected.
        case setupDone
        // Apps
        case addApp, arrangeApps, topShelfPreferences, movies
        // Apps › Movies
        case movieFolder(String), addMovieFolder, networkShare(String), addNetworkShare
        case jellyfinServer(String), addJellyfinServer, removeMovieSource
        /// A source's Home Videos switch: never looked up online, always in Other Videos (the Movies app's too)
        case homeVideos
        // Movies' forms: the text fields, then Connect or Sign In
        case formAddress, formUser, formPassword, formSubmit
        // System
        case userGuide, about, softwareUpdates, keepMacAwake, lidOverride, screenOff
        // System › User Guide
        case guideSection(Int)
        // System › About, System › Software Updates
        case version, source, report, update, autoUpdate
        // A removal's confirmation
        case cancelRemoval, acceptRemoval
    }

    /// A page opened below another, and the row on the page above to land on when it closes.
    struct Level: Equatable {
        let page: Page
        let from: Int
    }

    var section: Section = .general
    /// On the section's page (or a page below it) rather than the list of sections.
    var open = false
    /// The focused row on the page showing. On a name page, 0 is the name and 1 Done.
    var row = 0
    /// The pages opened below the section's page, deepest last.
    var path: [Level] = []
    /// 左右调了几次设置（真变了的才算）：焦点没动，但要和走一格一样响一声、震一下
    var changes = 0
    /// Select or a click: the focused control dips and settles back each time this goes up.
    var presses = 0
    /// On a row of cards (screen saver types, live wallpaper categories): the focused card while it isn't
    /// the chosen one. Left and right move it; Select chooses. Nil puts focus on the chosen card.
    var card: Int?
    /// The name being typed on a name page.
    var typed = ""
    /// Where the next letter goes in the text field with focus, in characters from its start.
    var caret = 0
    /// What's typed into Add Network Share… or Sign In to Jellyfin….
    var form = SourceForm()
    /// Connect a Remote: the same pages on a sheet of their own, whose first page is Remotes and Devices
    /// and whose Back on that page closes it.
    var connectRemote = false
    /// First-run setup's remote step: Connect a Remote's pages, with Set Up Later under the choices.
    var inSetup = false

    /// Connect a Remote, on its first page.
    static var connect: SettingsPanel { SettingsPanel(section: .remotes, open: true, connectRemote: true) }

    /// The page showing below the section's page, if any.
    var page: Page? { open ? path.last?.page : nil }

    /// Settings one page up: the page a confirmation asks about.
    var pageBelow: SettingsPanel {
        var panel = self
        _ = panel.path.popLast()
        return panel
    }

    /// A text field has focus: the keyboard's letters and Space go to it, and Left and Right move the caret.
    var typing: Bool {
        switch page {
        case .profileName: row == 0
        case .addNetworkShare, .addJellyfinServer: row < SourceForm.fields.count
        default: false
        }
    }
}

extension SettingsPanel.Section {
    var title: String {
        switch self {
        case .general: "General"
        case .profiles: "Profiles and Accounts"
        case .videoAndAudio: "Video and Audio"
        case .screenSaver: "Screen Saver"
        case .remotes: "Remotes and Devices"
        case .apps: "Apps"
        case .system: "System"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .profiles: "person.2.fill"
        case .videoAndAudio: "tv.and.hifispeaker.fill"
        case .screenSaver: "sparkles.tv.fill"
        case .remotes: "appletvremote.gen4.fill"
        case .apps: "square.grid.2x2.fill"
        case .system: "gearshape.2.fill"
        }
    }

    /// The rows on its page. Profiles lists who's been added (`TVController.settingsRows`), which also leaves
    /// out the rows this Mac has no use for.
    @MainActor var rows: [SettingsPanel.Row] {
        switch self {
        case .general: return [.twentyFourHour, .sleepTimer, .launchAtLogin, .autoSkip, .autoNext, .websitePlayer]
        case .videoAndAudio: return [.dedicatedTV, .preferredDisplay, .audioOutput, .feedback]
        case .screenSaver:
            let wallpaper = ScreenSaverSettings.wallpaper
            var rows: [SettingsPanel.Row] = [.wallpaper]
            if wallpaper == .aerials, !Aerials.categories.isEmpty { rows.append(.aerialCategory) }
            if wallpaper == .photos { rows.append(.photosFolder) }
            rows.append(.saverDelay)
            // 翻页时钟自己就是钟：没有"显示时钟"，换成 24-Hour Time（和 General 里的是同一个设置）
            rows.append(wallpaper == .flipClock ? .twentyFourHour : .saverClock)
            rows.append(.saverPreview)
            return rows
        case .remotes: return [.siriRemote, .iPhone, .otherControllers]
        case .apps: return [.addApp, .arrangeApps, .topShelfPreferences, .movies]
        case .system: return [.userGuide, .about, .softwareUpdates, .keepMacAwake, .lidOverride, .screenOff]
        case .profiles: return []
        }
    }
}

extension SettingsPanel.Row {
    /// Left and right change this row's value in place: a switch, a stepper, a row of cards.
    /// On any other row Left goes back.
    var adjustable: Bool {
        switch self {
        case .sleepTimer, .autoSkip, .autoNext, .websitePlayer, .wallpaper, .aerialCategory, .saverDelay, .saverClock,
             .feedback, .dedicatedTV, .preferredDisplay, .launchAtLogin, .keepMacAwake, .lidOverride, .autoUpdate,
             .phoneAccess, .twentyFourHour: true
        default: false
        }
    }

    /// Opens a page of Settings below this one, so Right opens it too.
    var opensPage: Bool {
        switch self {
        case .siriRemote, .iPhone, .otherControllers, .pairedDevice, .profile, .addProfile, .profileName, .movies,
             .movieFolder, .networkShare, .jellyfinServer, .addNetworkShare, .addJellyfinServer, .about, .softwareUpdates,
             .userGuide, .guideSection: true
        default: false
        }
    }

    /// The header the row is listed under; it shows above the first row of its group. Every group on a page
    /// has one, as tvOS's do, so a gap between rows always says what the next ones are; a list of like things
    /// (profiles, remotes, folders) has one even when it's the only group.
    var group: String? {
        switch self {
        case .twentyFourHour, .sleepTimer: "TIME"
        case .launchAtLogin: "STARTUP"
        case .autoSkip, .autoNext, .websitePlayer: "PLAYBACK"
        case .profile, .addProfile: "PROFILES"
        case .dedicatedTV, .preferredDisplay: "VIDEO"
        case .audioOutput, .feedback: "AUDIO"
        case .wallpaper: "TYPE"
        case .aerialCategory: "CATEGORY"
        case .siriRemote, .iPhone: "REMOTES"
        case .otherControllers: "OTHER DEVICES"
        case .addApp, .arrangeApps, .topShelfPreferences: "HOME SCREEN"
        case .movies: "APPS"
        case .userGuide, .about, .softwareUpdates: "MAC TV"
        case .guideSection: "CONTENTS"
        case .keepMacAwake, .lidOverride, .screenOff: "POWER"
        case .pairedDevice: "PAIRED DEVICES"
        case .movieFolder, .addMovieFolder: "FOLDERS"
        case .networkShare, .addNetworkShare: "NETWORK SHARES"
        case .jellyfinServer, .addJellyfinServer: "JELLYFIN"
        default: nil
        }
    }
}

/// Whether this Mac's macOS can use a Siri Remote at all.
@MainActor
enum SiriRemoteSupport {
    /// macOS's own question, "“Mac TV” would like to receive keystrokes from any application". A test puts in its own.
    static var requestAccess: () -> Void = {
        guard SystemGuard.allows("ask for Input Monitoring") else { return }
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }
}

extension TVController {
    /// A Siri Remote is here, but Mac TV may not read its buttons (Input Monitoring): its Status says so, and
    /// selecting it opens the pane where it's allowed. The only time the permission shows in Settings.
    var remoteBlocked: Bool {
        SiriRemoteStatus.shared.connected && !remoteCoordinator.inputMonitoringAllowed
    }

    /// Asks for Input Monitoring in context, the way macOS asks: when a Siri Remote first connects, or when it's chosen
    /// in setup. macOS asks once; after that Status points to System Settings.
    func askForInputMonitoring() {
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeUnknown else { return }
        SiriRemoteSupport.requestAccess()
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
    }

    /// A text field: the label is the row's title, the text follows it.
    struct Field: Equatable {
        var text: String
        var placeholder: String
        /// Where the caret is while the field has focus.
        var caret: Int?
        var secure = false
    }

    var title: String
    var value: String?
    var accessory: Accessory = .none
    var symbol: String?
    var avatar: Profile?
    var battery: String?
    /// The profile watching now.
    var checked = false
    /// Red: Press Again to Sleep, and the removal a confirmation asks about.
    var warning = false
    var field: Field?
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

    /// Opens Settings on the page that has `row` (one of a section's own rows), with focus on it: the lid's
    /// status glyph opens System on Stay Awake With Lid Closed.
    func openSettings(to row: SettingsPanel.Row) {
        guard let section = SettingsPanel.Section.allCases.first(where: { $0.rows.contains(row) }) else { return openSettings() }
        var panel = SettingsPanel(section: section, open: true)
        panel.row = settingsRows(panel).firstIndex(of: row) ?? 0
        settings = panel
    }

    // MARK: Pages and rows

    /// The rows on the page Settings shows now.
    func settingsRows(_ panel: SettingsPanel) -> [SettingsPanel.Row] {
        switch panel.page {
        case nil:
            switch panel.section {
            case .profiles:
                return profiles.all.map { .profile($0.id) } + [.addProfile]
            default:
                // A Mac without a lid has nothing to keep awake with it closed, and with only the built-in player
                // there's no website player to choose.
                return panel.section.rows.filter {
                    ($0 != .lidOverride || displayCoordinator.hasLid) && ($0 != .websitePlayer || braveInstalled)
                } + (panel.inSetup ? [.setupDone] : [])
            }
        case .siriRemote:
            let battery = SiriRemoteStatus.shared.connected && remoteCoordinator.siriRemoteBattery != nil
            // A remote whose buttons Mac TV may not read says so on its Status row (see `remoteBlocked`).
            return [.remoteStatus] + (battery ? [.remoteBattery] : []) + [.bluetooth]
        case .iPhone: return [.phoneAccess] + pairedDevices.map { .pairedDevice($0.id) }
        case .pairedDevice: return [.removePairedDevice]
        case .otherControllers: return [.controller] + (controller?.battery == nil ? [] : [.controllerBattery]) + [.bluetooth]
        case .profile(let id):
            return [.profileName, .profilePhoto] + (ProfilePhotos.shared.photo(for: id) == nil ? [] : [.removePhoto])
                + (id == profile.id ? [] : [.switchProfile]) + (id == Profile.mainID ? [] : [.removeProfile])
        case .profileName: return []
        case .movies:
            return movieFolders.map { .movieFolder($0.path) } + [.addMovieFolder]
                + networkShares.shares.map { .networkShare($0.id) } + [.addNetworkShare]
                + jellyfin.servers.map { .jellyfinServer($0.id) } + [.addJellyfinServer]
        case .movieFolder, .networkShare, .jellyfinServer: return [.homeVideos, .removeMovieSource]
        case .addNetworkShare, .addJellyfinServer: return SourceForm.fields + [.formSubmit]
        case .about: return [.version, .source, .report]
        case .userGuide: return UserGuide.sections.indices.map { .guideSection($0) }
        case .guideSection: return []
        case .softwareUpdates: return [.update, .autoUpdate]
        case .confirmRemoval: return [.cancelRemoval, .acceptRemoval]
        }
    }

    private var pairedDevices: [PairingStore.Device] { remoteCoordinator.pairingStore.activeDevices() }

    /// The header above a row's group on this page. On the Screen Saver page, Flip Clock's 24-Hour Time is one of
    /// the screen saver's own options, under no header of its own.
    func settingsHeader(_ row: SettingsPanel.Row, panel: SettingsPanel) -> String? {
        if panel.page == nil, panel.section == .screenSaver, row == .twentyFourHour { return nil }
        return row.group
    }

    /// The page footnote: how to pair a Siri Remote while none is connected, or why a movie source couldn't be added.
    func settingsFootnote(_ panel: SettingsPanel) -> String? {
        switch panel.page {
        case .siriRemote:
            !SiriRemoteStatus.shared.connected
                ? "To pair, hold Back and Volume Up on the remote for 5 seconds." : nil
        case .addNetworkShare, .addJellyfinServer: panel.form.message
        default: nil
        }
    }

    /// "Connected · 87%" for the Siri Remote, "DualSense · 70%" for a game controller.
    private func withBattery(_ text: String, _ level: Int?) -> String { level.map { "\(text) · \($0)%" } ?? text }

    /// Movies' folders, apart from network shares' (listed under Network Shares).
    private var movieFolders: [URL] { movieLibrary.folders.filter { networkShares.share(for: $0) == nil } }

    /// What the big picture on the left shows: the focused section, the focused remote, or the page showing.
    func settingsHero(_ panel: SettingsPanel) -> (title: String, symbol: String, avatar: Profile?) {
        switch panel.page {
        case nil where panel.open && panel.section == .remotes:
            // Remotes and Devices (and Connect a Remote): the remote with focus.
            let rows = settingsRows(panel)
            let focused = rows.indices.contains(panel.row) ? rows[panel.row] : .siriRemote
            let symbol = focused == .iPhone ? "iphone" : focused == .otherControllers ? "gamecontroller.fill" : "appletvremote.gen4.fill"
            return (panel.connectRemote ? "Connect a Remote" : panel.section.title, symbol, nil)
        case nil: return (panel.section.title, panel.section.symbol, nil)
        case .siriRemote: return ("Siri Remote", "appletvremote.gen4.fill", nil)
        case .iPhone: return ("iPhone", "iphone", nil)
        case .pairedDevice(let id): return (pairedDevices.first { $0.id == id }?.name ?? "iPhone", "iphone", nil)
        case .otherControllers: return ("Game Controller", "gamecontroller.fill", nil)
        case .profile(let id):
            let shown = profiles.all.first { $0.id == id }
            return (shown?.name ?? "Profile", "person.fill", shown)
        case .profileName(let id):
            let base = id.flatMap { id in profiles.all.first { $0.id == id } }
            let preview = Profile(id: id ?? "new", name: panel.typed.isEmpty ? "?" : panel.typed, color: base?.color ?? profiles.nextColor)
            return (id == nil ? "New Profile" : "Name", "person.fill", preview)
        case .movies: return ("Movies", "film.stack.fill", nil)
        case .movieFolder(let path): return (URL(fileURLWithPath: path).lastPathComponent, "folder.fill", nil)
        case .networkShare(let id):
            return (networkShares.shares.first { $0.id == id }?.name ?? "Network Share", "externaldrive.connected.to.line.below.fill", nil)
        case .jellyfinServer(let id): return (jellyfin.servers.first { $0.id == id }?.name ?? "Jellyfin", "server.rack", nil)
        case .addNetworkShare: return ("Add Network Share", "externaldrive.connected.to.line.below.fill", nil)
        case .addJellyfinServer: return ("Sign In to Jellyfin", "server.rack", nil)
        case .about: return ("About", "info.circle", nil)
        case .userGuide: return (UserGuide.title, "book.fill", nil)
        case .guideSection(let index):
            let section = UserGuide.sections.indices.contains(index) ? UserGuide.sections[index] : nil
            return (section?.title ?? UserGuide.title, section?.symbol ?? "book.fill", nil)
        case .softwareUpdates: return ("Software Updates", "arrow.down.circle", nil)
        case .confirmRemoval(let removal):
            // The question, over the picture of the page it asks about.
            let below = panel.pageBelow, hero = settingsHero(below)
            return (removal == .removePhoto ? "Remove Photo?" : "Remove “\(hero.title)”?", hero.symbol, hero.avatar)
        }
    }

    /// What Movies' row says: how many folders, or sources once there's a share or a server.
    private var moviesSummary: String? {
        let folders = movieFolders.count, others = networkShares.shares.count + jellyfin.servers.count
        if others == 0 { return folders == 0 ? nil : "\(folders) Folder\(folders == 1 ? "" : "s")" }
        return "\(folders + others) Sources"
    }

    /// What Display says, in Settings' list and on Control Center's tile: "Full Screen", or the name of the
    /// screen Mac TV is on. Never "Off", which would read as the screen being off.
    var displaySummary: String? {
        dedicatedTVMode ? "Full Screen" : window?.screen?.localizedName ?? NSScreen.main?.localizedName
    }

    /// What a row shows. `focused` puts the caret in a text field.
    func settingsContent(_ row: SettingsPanel.Row, panel: SettingsPanel, focused: Bool) -> SettingsRowContent {
        typealias Content = SettingsRowContent
        func onOff(_ title: String, _ on: Bool) -> Content { Content(title: title, accessory: .toggle(on)) }
        switch row {
        case .twentyFourHour: return onOff("24-Hour Time", preferences.twentyFourHourTime)
        case .launchAtLogin:
            return loginNeedsApproval ? Content(title: "Open at Login", value: "Approval Needed") : onOff("Open at Login", launchAtLogin)
        case .sleepTimer:
            let minutes = sleepMinutesLeft
            return Content(title: "Sleep Timer", value: minutes == 0 ? "Off" : "\(minutes) Minute\(minutes == 1 ? "" : "s") Left",
                           accessory: .stepper)
        case .autoSkip: return onOff("Skip Intros, Recaps and Ads", autoSkip)
        case .autoNext: return onOff("Autoplay Next Episode", autoNext)
        case .websitePlayer: return Content(title: "Website Player", value: websitePlayerName, accessory: .stepper)
        case .profile(let id):
            let shown = profiles.all.first { $0.id == id }
            return Content(title: shown?.name ?? "", accessory: .chevron, avatar: shown, checked: id == profile.id)
        case .addProfile: return Content(title: "Add Profile…", accessory: .chevron, symbol: "plus")
        case .profileName:
            return Content(title: "Name", value: editedProfile(panel)?.name, accessory: .chevron)
        case .profilePhoto: return Content(title: "Choose Photo…", accessory: .chevron)
        case .removePhoto: return Content(title: "Remove Photo")
        case .switchProfile: return Content(title: "Switch to This Profile")
        case .removeProfile: return Content(title: "Remove Profile")
        case .dedicatedTV: return onOff("Full Screen", dedicatedTVMode)
        case .preferredDisplay: return Content(title: "Preferred Display", value: preferredTVDisplayName, accessory: .stepper)
        case .audioOutput: return Content(title: "Audio Output", value: currentAudioDevice?.name ?? "Speakers", accessory: .chevron)
        case .feedback: return onOff("Navigation Clicks", feedback.enabled)
        case .wallpaper, .aerialCategory: return Content(title: "")   // drawn as cards
        case .photosFolder:
            return Content(title: "Choose Folder…", value: ScreenSaverSettings.photosFolder.lastPathComponent, accessory: .chevron)
        case .saverDelay: return Content(title: "Start After", value: "\(ScreenSaverSettings.delayMinutes) Minutes", accessory: .stepper)
        case .saverClock: return onOff("Show Clock", ScreenSaverSettings.showClock)
        case .saverPreview: return Content(title: "Preview", accessory: .chevron)
        case .siriRemote:
            let connected = SiriRemoteStatus.shared.connected
            let value = connected ? withBattery("Connected", remoteCoordinator.siriRemoteBattery) : "Not Connected"
            return Content(title: "Siri Remote", value: value, accessory: .chevron, symbol: "appletvremote.gen4.fill")
        case .iPhone:
            let connected = remoteCoordinator.pairingStore.connectedCount(), paired = pairedDevices.count
            let value = connected > 0 ? "\(connected) Connected" : paired > 0 ? "\(paired) Paired" : "Not Connected"
            return Content(title: "iPhone", value: value, accessory: .chevron, symbol: "iphone")
        case .otherControllers:
            let value = controller.map { withBattery($0.name, $0.percent) } ?? "Not Connected"
            return Content(title: "Game Controller", value: value, accessory: .chevron, symbol: "gamecontroller.fill")
        case .remoteStatus:
            if remoteBlocked { return Content(title: "Status", value: "Needs Input Monitoring", accessory: .chevron) }
            let value = SiriRemoteStatus.shared.connected ? "Connected" : "Not Connected"
            return Content(title: "Status", value: value)
        case .remoteBattery:
            let level = remoteCoordinator.siriRemoteBattery
            return Content(title: "Battery", value: level.map { "\($0)%" }, battery: level.map(ControllerInfo.batterySymbol))
        case .setupDone:
            let connected = SiriRemoteStatus.shared.connected || controller != nil || remoteCoordinator.pairingStore.connectedCount() > 0
            return Content(title: connected ? "Continue" : "Set Up Later")
        case .bluetooth: return Content(title: "Bluetooth Settings…")
        case .phoneAccess:
            return Content(title: "Phone Access", value: pairingGuest ? "Guest (24 Hours)" : "Full Access", accessory: .stepper)
        case .pairedDevice(let id):
            let device = pairedDevices.first { $0.id == id }
            return Content(title: device?.name ?? "iPhone", value: device?.isGuest == true ? "Guest" : nil, accessory: .chevron)
        case .removePairedDevice: return Content(title: "Remove Device")
        case .controller:
            guard let controller else { return Content(title: "Status", value: "Not Connected") }
            return Content(title: "Name", value: controller.name)
        case .controllerBattery:
            return Content(title: "Battery", value: controller?.percent.map { "\($0)%" },
                           battery: controller.map { $0.batterySymbol })
        case .addApp: return Content(title: "Add App", accessory: .chevron)
        case .arrangeApps: return Content(title: "Arrange Apps", accessory: .chevron)
        case .topShelfPreferences: return Content(title: "Top Shelf", accessory: .chevron)
        case .movies: return Content(title: "Movies", value: moviesSummary, accessory: .chevron)
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
        case .homeVideos: return onOff("Home Videos", movieSourceID(panel.page).map(movieLibrary.isHomeVideos) ?? false)
        case .removeMovieSource:
            switch panel.page {
            case .networkShare: return Content(title: "Remove Share")
            case .jellyfinServer: return Content(title: "Remove Server")
            default: return Content(title: "Remove Folder")
            }
        case .cancelRemoval: return Content(title: "Cancel")
        case .acceptRemoval:
            // The removal's own name, as Apple's confirmations repeat it.
            guard case .confirmRemoval(let removal)? = panel.page else { return Content(title: "") }
            return Content(title: settingsContent(removal, panel: panel.pageBelow, focused: false).title, warning: true)
        case .formAddress, .formUser, .formPassword, .formSubmit:
            return formContent(row, panel: panel, focused: focused)
        case .userGuide: return Content(title: "User Guide", accessory: .chevron)
        case .guideSection(let index):
            let section = UserGuide.sections.indices.contains(index) ? UserGuide.sections[index] : nil
            return Content(title: section?.title ?? "", accessory: .chevron, symbol: section?.symbol)
        case .about: return Content(title: "About", accessory: .chevron)
        case .softwareUpdates:
            return Content(title: "Software Updates", value: updater.availableVersion != nil ? "Update Available" : nil, accessory: .chevron)
        case .keepMacAwake: return onOff("Keep Mac Awake", keepMacAwake)
        case .lidOverride: return onOff("Stay Awake With Lid Closed", lidOverride)
        case .screenOff: return Content(title: "Turn Off Display")
        case .version: return Content(title: "Version", value: AppVersion.current)
        case .source: return Content(title: "Source Code", value: "github.com/kaisenyao/mac-tv")
        case .report: return Content(title: "Copy Diagnostics Report")
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
            return Content(title: "Update Software", value: state)
        case .autoUpdate: return onOff("Automatically Update", updater.automatic)
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

    /// The pages presses and clicks act on: Connect a Remote while it's the sheet on top, otherwise Settings.
    /// Both are the same pages, so everything below serves both.
    var pages: SettingsPanel? {
        get {
            if sheets.top == .setup { return setup?.step == .remote ? setup?.connect : nil }
            return sheets.top == .pairing ? connectRemote : settings
        }
        set {
            if sheets.top == .setup {
                if let newValue, setup?.step == .remote { setup?.connect = newValue }
            } else if sheets.top == .pairing {
                if let newValue { connectRemote = newValue }
            } else {
                settings = newValue
            }
        }
    }

    func handleSettings(_ command: RemoteCommand) {
        guard var panel = pages else { return }
        guard panel.open else {
            let sections = SettingsPanel.Section.allCases
            switch command {
            case .back:
                pages = nil
                return
            case .move(.up):
                panel.section = sections[max(0, panel.section.rawValue - 1)]
            case .move(.down):
                panel.section = sections[min(sections.count - 1, panel.section.rawValue + 1)]
            case .move(.right), .select:
                pages = panel
                openSection(panel.section)
                return
            default:
                break
            }
            pages = panel
            return
        }
        switch panel.page {
        case .profileName:
            typeName(command, panel)
            return
        case .addNetworkShare, .addJellyfinServer:
            typeInForm(command, panel)
            return
        case .guideSection:
            readGuide(command, panel)
            return
        default:
            break
        }

        let rows = settingsRows(panel)
        panel.row = min(panel.row, max(rows.count - 1, 0))
        guard rows.indices.contains(panel.row) else {
            if case .back = command { closeSettingsPage(&panel) }
            pages = panel
            return
        }
        let row = rows[panel.row]
        // Connect a Remote's first page: Back closes the sheet; Left has nowhere to go.
        let sheetRoot = panel.connectRemote && panel.path.isEmpty
        switch command {
        case .back where sheetRoot:
            if panel.inSetup { setupBack() } else { pairing = false }
            return
        case .back:
            closeSettingsPage(&panel)
        case .move(.left) where !row.adjustable:
            if !sheetRoot { closeSettingsPage(&panel) }
        case .move(let direction) where direction == .up || direction == .down:
            let next = direction == .up ? max(0, panel.row - 1) : min(rows.count - 1, panel.row + 1)
            if next != panel.row {
                panel.row = next
                panel.card = nil   // into a row of cards, focus lands on the chosen one
            }
        case .move(.right) where row.opensPage:
            pages = panel
            activateSetting(row)
            return
        case .move(let direction) where direction == .left || direction == .right:
            pages = panel
            adjustSetting(row, forward: direction == .right)
            return
        case .select:
            pages = panel
            activateSetting(row)
            return
        default:
            break
        }
        pages = panel
    }

    /// Opens a section's page from the list.
    func openSection(_ section: SettingsPanel.Section) {
        settings = SettingsPanel(section: section, open: true)
        if section == .remotes { remoteCoordinator.refreshRemoteStatus() }
    }

    func openSettingsPage(_ page: SettingsPanel.Page) {
        guard var panel = pages, panel.open else { return }
        panel.path.append(.init(page: page, from: panel.row))
        panel.row = 0
        panel.card = nil
        switch page {
        case .siriRemote, .otherControllers: remoteCoordinator.refreshRemoteStatus()
        case .iPhone: pairingGuest = false   // a full-access code each time
        case .profileName(let id):
            panel.typed = id.flatMap { id in profiles.all.first { $0.id == id }?.name } ?? ""
            panel.caret = panel.typed.count
        case .addNetworkShare, .addJellyfinServer:
            panel.form = SourceForm()
            panel.caret = 0
        default: break
        }
        pages = panel
    }

    /// Back: up a page, landing on the row it was opened from, or back to the list of sections.
    func closeSettingsPage(_ panel: inout SettingsPanel) {
        if let level = panel.path.popLast() {
            // The row it came from, or the last one when the page lost rows meanwhile (a removed phone, say).
            panel.row = min(level.from, max(settingsRows(panel).count - 1, 0))
        } else {
            panel.open = false
            panel.row = 0
        }
        panel.card = nil
        panel.typed = ""
        panel.caret = 0
        panel.form = SourceForm()
    }

    /// Puts focus on a row of the page showing, if it's there.
    func focusSetting(_ row: SettingsPanel.Row) {
        guard let panel = pages, let index = settingsRows(panel).firstIndex(of: row) else { return }
        pages?.row = index
    }

    /// Select, Return, Space or a click on a row.
    func activateSetting(_ row: SettingsPanel.Row) {
        // A form that's connecting waits; only Back leaves it.
        guard let panel = pages, !panel.form.connecting else { return }
        // A click focuses the row first.
        if let index = settingsRows(panel).firstIndex(of: row), index != panel.row {
            pages?.row = index
            pages?.card = nil
        }
        pages?.presses += 1
        switch row {
        case .profile(let id): openSettingsPage(.profile(id))
        case .addProfile: openSettingsPage(.profileName(nil))
        case .profileName: if let edited = editedProfile(panel) { openSettingsPage(.profileName(edited.id)) }
        case .profilePhoto: if let edited = editedProfile(panel) { chooseProfilePhoto(for: edited.id) }
        case .switchProfile: if let edited = editedProfile(panel) { switchProfile(to: edited.id) }
        case .removePhoto, .removeProfile, .removePairedDevice, .removeMovieSource: openSettingsPage(.confirmRemoval(row))
        case .cancelRemoval: closeSettingsPage()
        case .acceptRemoval: acceptRemoval(panel)
        case .siriRemote:
            // Choosing the Siri Remote in setup is when Mac TV asks to read its buttons (see `askForInputMonitoring`).
            if panel.inSetup { askForInputMonitoring() }
            openSettingsPage(.siriRemote)
        case .iPhone: openSettingsPage(.iPhone)
        case .otherControllers: openSettingsPage(.otherControllers)
        case .pairedDevice(let id): openSettingsPage(.pairedDevice(id))
        case .remoteStatus where remoteBlocked:
            // System Settings › Privacy & Security › Input Monitoring. Status says Connected once it's allowed there.
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                SystemGuard.open(url)
            }
        case .setupDone: advanceSetup()
        case .bluetooth: PairSheet.openBluetoothSettings()
        case .phoneAccess: pairingGuest.toggle()
        case .remoteStatus, .remoteBattery, .controller, .controllerBattery, .version, .source: break
        case .wallpaper, .aerialCategory: chooseCard(on: row, at: pages?.card ?? cards(on: row).chosen)
        case .photosFolder: ScreenSaverSettings.choosePhotosFolder()
        case .saverDelay: ScreenSaverSettings.stepDelay(1, wrap: true)
        case .saverClock: ScreenSaverSettings.showClock.toggle()
        case .saverPreview: showScreensaver()   // over Settings; any press comes back here
        case .sleepTimer: stepSleepTimer(by: 1, wrap: true)
        case .autoSkip: autoSkip.toggle()
        case .autoNext: autoNext.toggle()
        case .websitePlayer: stepWebsitePlayer()
        case .audioOutput: openAudioPicker()   // over Settings, like the other sheets it opens
        case .feedback: feedback.enabled.toggle()
        case .addApp:
            // Over Settings, so Back comes back to Add App; adding one goes Home, on the new app.
            adder = AppAdder()
        case .arrangeApps: openOrganizer()
        case .topShelfPreferences: openTopShelfPreferences()
        case .movies: openSettingsPage(.movies)
        case .movieFolder(let path): openSettingsPage(.movieFolder(path))
        case .networkShare(let id): openSettingsPage(.networkShare(id))
        case .jellyfinServer(let id): openSettingsPage(.jellyfinServer(id))
        case .addMovieFolder: chooseMovieFolders()
        case .homeVideos:
            if let id = movieSourceID(panel.page) { movieLibrary.setHomeVideos(id, !movieLibrary.isHomeVideos(id)) }
            objectWillChange.send()
        case .addNetworkShare: openSettingsPage(.addNetworkShare)
        case .addJellyfinServer: openSettingsPage(.addJellyfinServer)
        case .formAddress, .formUser, .formPassword: focusFormField(row)
        case .formSubmit: pressFormRow(SourceForm.fields.count)
        case .dedicatedTV: setDedicatedTVMode(!dedicatedTVMode)
        case .preferredDisplay: stepTVDisplay(1, wrap: true)
        case .launchAtLogin: setLaunchAtLogin(!launchAtLogin)
        case .twentyFourHour: preferences.twentyFourHourTime.toggle()
        case .about: openSettingsPage(.about)
        case .userGuide: openSettingsPage(.userGuide)
        case .guideSection(let index): openSettingsPage(.guideSection(index))
        case .softwareUpdates: openSettingsPage(.softwareUpdates)
        case .keepMacAwake: keepMacAwake.toggle()
        case .lidOverride: lidOverride.toggle()
        case .screenOff: enterStandby(reason: "Turn Off Display")
        case .update: updater.activate()
        case .autoUpdate: updater.automatic.toggle()
        case .report: DiagnosticReport.copy(from: self)
        }
    }

    func closeSettingsPage() {
        guard var panel = pages else { return }
        closeSettingsPage(&panel)
        pages = panel
    }

    /// The removal on a confirmation page: back to the page it asked about, then the removal. A removed profile,
    /// phone or movie source takes its page with it.
    private func acceptRemoval(_ panel: SettingsPanel) {
        guard case .confirmRemoval(let removal)? = panel.page else { return }
        let below = panel.pageBelow
        closeSettingsPage()
        switch removal {
        case .removePhoto:
            guard let edited = editedProfile(below) else { return }
            if !ProfilePhotos.shared.remove(for: edited.id) {
                showToast("Couldn’t move “\(edited.name)”’s photo to the Trash. Nothing was deleted.")
            }
            focusSetting(.profilePhoto)
        case .removeProfile:
            guard let edited = editedProfile(below) else { return }
            removeProfile(edited.id)
            ProfilePhotos.shared.forget(edited.id)
            closeSettingsPage()
        case .removePairedDevice:
            guard case .pairedDevice(let id) = below.page else { return }
            remoteCoordinator.removePairedDevice(id)
            closeSettingsPage()
        case .removeMovieSource:
            guard let page = below.page else { return }
            removeMovieSource(page)
            closeSettingsPage()
        default:
            break
        }
    }

    /// Left and right: step a value, switch a setting off and on, or move along a row of cards.
    private func adjustSetting(_ row: SettingsPanel.Row, forward: Bool) {
        let step = forward ? 1 : -1
        guard let panel = pages else { return }
        let before = settingsContent(row, panel: panel, focused: true)
        switch row {
        case .wallpaper, .aerialCategory:
            // Only the focus moves (and the move sounds): the chosen card changes with Select.
            let cards = cards(on: row)
            let next = min(max((panel.card ?? cards.chosen) + step, 0), cards.count - 1)
            pages?.card = next == cards.chosen ? nil : next
            return
        case .dedicatedTV: setDedicatedTVMode(forward)
        case .preferredDisplay: stepTVDisplay(step)
        case .launchAtLogin: setLaunchAtLogin(forward)
        case .twentyFourHour: preferences.twentyFourHourTime = forward
        case .sleepTimer: stepSleepTimer(by: step, wrap: false)
        case .websitePlayer: _ = setWebsitePlayer((forward ? BrowserChoice.brave : .embedded).rawValue)
        case .saverDelay: ScreenSaverSettings.stepDelay(step)
        case .saverClock: ScreenSaverSettings.showClock = forward
        case .feedback: feedback.enabled = forward
        case .autoSkip: autoSkip = forward
        case .autoNext: autoNext = forward
        case .keepMacAwake: keepMacAwake = forward
        case .lidOverride: lidOverride = forward
        case .autoUpdate: updater.automatic = forward
        case .phoneAccess: pairingGuest = forward   // left Full Access, right Guest
        default: return
        }
        // 值真变了才响（到头了、开关本来就是这样的，不响）
        if let now = pages, settingsContent(row, panel: now, focused: true) != before { pages?.changes += 1 }
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
        pages?.card = nil
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

    // MARK: Profiles, movie sources

    /// Typing on a name page: letters go in at the caret, Left and Right move it, Down goes to Done and Up back.
    /// Return or Select saves; Back leaves the name as it was.
    private func typeName(_ command: RemoteCommand, _ panel: SettingsPanel) {
        var panel = panel
        guard case .profileName(let id) = panel.page else { return }
        var done = false
        switch command {
        case .back:
            closeSettingsPage(&panel)
            pages = panel
            return
        case .move(.up): panel.row = 0
        case .move(.down): panel.row = 1
        case .move(.left), .move(.right):
            if panel.row == 0 { _ = TextEntry.apply(command, to: &panel.typed, caret: &panel.caret, limit: ProfileName.maxLength) }
        case .text(let text):
            panel.row = 0
            _ = TextEntry.apply(command, to: &panel.typed, caret: &panel.caret, limit: ProfileName.maxLength)
            done = text.hasSuffix("\n")
        case .deleteBackward:
            panel.row = 0
            _ = TextEntry.apply(command, to: &panel.typed, caret: &panel.caret, limit: ProfileName.maxLength)
        case .select:
            panel.presses += 1
            done = true
        default: break
        }
        pages = panel
        let name = panel.typed.trimmingCharacters(in: .whitespaces)
        guard done, !name.isEmpty else { return }
        var added: Profile?
        if let id { renameProfile(id, to: name) } else { added = profiles.add(named: name) }
        closeSettingsPage(&panel)
        pages = panel
        if let added { focusSetting(.profile(added.id)) }
    }

    /// The Mac's folder chooser, for Movies' sources: what's chosen goes to `done` (Settings adds the folders and keeps
    /// focus on Add Folder…; the Movies app just adds them).
    func chooseMovieFolders(_ done: (([URL]) -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders with movies for Mac TV"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            MainActor.assumeIsolated {
                if let done { done(panel.urls) } else { self?.addMovieFolders(panel.urls) }
            }
        }
    }

    /// Adds folders to Movies, which the Movies app and the phone show too. Focus stays on Add Folder….
    func addMovieFolders(_ folders: [URL]) {
        folders.forEach(movieLibrary.add)
        objectWillChange.send()
        focusSetting(.addMovieFolder)
    }

    /// The Movies source a Settings page is about, as the Movies app names it.
    private func movieSourceID(_ page: SettingsPanel.Page?) -> String? {
        switch page {
        case .movieFolder(let path): path
        case .networkShare(let id): networkShares.shares.first { $0.id == id }?.folder?.path
        case .jellyfinServer(let id): JellyfinServers.scheme + id
        default: nil
        }
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

/// Settings' sizes, matched to Apple TV's own Settings at 1080p: a row about 6% of the screen's height and 41% of
/// its width, its title in tvOS's Headline (38 points, as Apple's measure) and its value a step smaller.
enum SettingsMetrics {
    static let title = Font.tv(.headline)
    static let value = Font.tv(.callout)
    static let rowHeight: CGFloat = 66
    static let rowSpacing: CGFloat = 12
    static let listWidth: CGFloat = 790
    static let corner: CGFloat = 20
    static let inset: CGFloat = 26
    /// The bottom of Home's status bar (the time, Control Center and the avatar), which a scrolling page stays below.
    static let belowStatusBar: CGFloat = 104
}

extension View {
    /// A Settings page that scrolls: what goes up past the status bar fades out before it reaches the time, Control
    /// Center and the avatar, and fades the same way at the bottom (EdgeFade, top and bottom). Only the vertical
    /// edges are masked; the focus platter's lift and shadow still reach out at the sides.
    func belowStatusBar() -> some View {
        mask {
            VStack(spacing: 0) {
                Color.clear.frame(height: SettingsMetrics.belowStatusBar)
                EdgeFadeMask(leading: 50, trailing: 50, vertical: true)
            }
            .padding(.horizontal, -60)
        }
    }
}

struct SettingsSheet: View {
    @ObservedObject var tv: TVController

    var body: some View {
        SettingsPages(tv: tv, panel: tv.settings ?? SettingsPanel())
    }
}

/// Settings' pages: the big picture on the left, the list of sections or a page on the right. Settings and
/// Connect a Remote (`PairSheet`, the Remotes and Devices pages on a sheet of their own) both draw with it.
struct SettingsPages: View {
    @ObservedObject var tv: TVController
    let panel: SettingsPanel
    @ObservedObject private var updater: Updater
    @ObservedObject private var siriRemote = SiriRemoteStatus.shared
    /// Movies' shares and servers, added or removed here, in the Movies app or from the phone, show at once.
    @ObservedObject private var shares: NetworkShares
    @ObservedObject private var servers: JellyfinServers
    @ObservedObject private var photos = ProfilePhotos.shared
    @Environment(\.canvasSize) private var canvas
    @Namespace private var focusSpace

    init(tv: TVController, panel: SettingsPanel) {
        _tv = ObservedObject(wrappedValue: tv)
        self.panel = panel
        _updater = ObservedObject(wrappedValue: tv.updater)
        _shares = ObservedObject(wrappedValue: tv.networkShares)
        _servers = ObservedObject(wrappedValue: tv.jellyfin)
    }

    var body: some View {
        HStack(spacing: 0) {
            hero(panel)
                .padding(.leading, 120)
                .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if !panel.open {
                    sections(panel)
                } else if case .profileName = panel.page {
                    nameEntry(panel).id(panel.page)
                } else if case .guideSection(let index) = panel.page, UserGuide.sections.indices.contains(index) {
                    UserGuidePage(section: UserGuide.sections[index], top: panel.row).id(panel.page)
                } else {
                    // A page opened from a row cross-fades in place, as a section's page does from the list.
                    page(panel).id(panel.page)
                }
            }
            .frame(width: SettingsMetrics.listWidth)
            .padding(.trailing, 100)
        }
        .foregroundStyle(.white)
        .frame(width: canvas.width, height: canvas.height)
        .animation(Motion.focus, value: panel)
        // The remotes' battery and Input Monitoring: read again when a remote comes or goes, and on coming back
        // from System Settings. Never on a timer.
        .onReceive(siriRemote.$connected.dropFirst()) { _ in refreshRemotes() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshRemotes() }
    }

    private func refreshRemotes() {
        if panel.open, panel.section == .remotes { tv.remoteCoordinator.refreshRemoteStatus() }
    }

    private func hero(_ panel: SettingsPanel) -> some View {
        let hero = tv.settingsHero(panel)
        return VStack(alignment: .leading, spacing: 28) {
            Text("SETTINGS").font(.tv(.caption2, emphasized: true)).tracking(1.6).opacity(panel.connectRemote ? 0 : 0.5)
            ZStack {
                if let avatar = hero.avatar {
                    ProfileAvatar(profile: avatar, size: 280)
                        .transition(.opacity)
                } else {
                    // A quick crossfade as focus moves between sections, or between the remotes.
                    Image(systemName: hero.symbol)
                        .font(.system(size: 120, weight: .regular))
                        .frame(width: 280, height: 280)
                        .id(hero.symbol)
                        .transition(.opacity)
                }
            }
            .frame(width: 280, height: 280)
            // A plain tile, not glass: Settings sits on a frosted backdrop, and glass there would read flat.
            .background(.white.opacity(hero.avatar == nil ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 66, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 66, style: .continuous).strokeBorder(.white.opacity(hero.avatar == nil ? 0.14 : 0)))
            .animation(.easeInOut(duration: 0.18), value: hero.symbol)
            Text(hero.title).font(.tv(.title2, emphasized: true)).lineLimit(1)
                .id(hero.title)
                .transition(.opacity)
        }
        .animation(Motion.appear, value: hero.title)
        .animation(Motion.appear, value: hero.avatar == nil)
    }

    private func sections(_ panel: SettingsPanel) -> some View {
        VStack(spacing: SettingsMetrics.rowSpacing) {
            ForEach(SettingsPanel.Section.allCases, id: \.self) { section in
                // Apple's list of sections shows no values: those are on the pages.
                let content = SettingsRowContent(title: section.title, accessory: .chevron, symbol: section.symbol)
                SettingsRow(content: content, focused: panel.section == section, presses: panel.presses, focusSpace: focusSpace) {
                    tv.openSection(section)
                }
                .equatable()
            }
        }
    }

    private func page(_ panel: SettingsPanel) -> some View {
        let rows = tv.settingsRows(panel)
        let focus = min(panel.row, rows.count - 1)
        let form = panel.page == .addNetworkShare || panel.page == .addJellyfinServer
        return ScrollViewReader { scroller in
            // Scrolls only when a list is longer than the screen (many paired phones, say), and only to keep
            // the focused row in view.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
                    if panel.page == .iPhone { PhonePairingCodes(tv: tv).padding(.bottom, 22) }
                    // 按行本身认（不按第几行）：换了屏保类型、少了一行"显示时钟"时，那一行淡出、下面的平滑往上挪，
                    // 不会变成"第三行的字突然换成预览、最后一行一下子没了"
                    ForEach(Array(rows.enumerated()), id: \.element) { index, row in
                        VStack(alignment: .leading, spacing: 10) {
                            if let group = tv.settingsHeader(row, panel: panel),
                               index == 0 || tv.settingsHeader(rows[index - 1], panel: panel) != group {
                                Text(group).font(.tv(.caption1, emphasized: true)).tracking(1.4).opacity(0.5)
                                    .padding(.leading, 6).padding(.top, index == 0 ? 0 : 12)
                            }
                            rowView(row, focused: index == focus, panel: panel)
                        }
                        .id(row)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                    }
                    if let note = tv.settingsFootnote(panel) {
                        // A form's footnote is why it couldn't add the source; the only other one is how to pair.
                        Text(note).font(.tv(.caption1, emphasized: form))
                            .foregroundStyle(form ? Color(hex: "#FF8A80") : .white.opacity(0.55))
                            .lineLimit(2)
                            .padding(.horizontal, SettingsMetrics.inset).padding(.top, 6)
                    }
                }
                // Starts below the status bar, so a long list's first row is never under it.
                .padding(.top, SettingsMetrics.belowStatusBar + 50)
                .padding(.bottom, 60)
                .frame(minHeight: canvas.height)
            }
            .scrollDisabled(true)
            .scrollClipDisabled()
            .belowStatusBar()
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
            SettingsRow(content: tv.settingsContent(row, panel: panel, focused: focused), focused: focused,
                        presses: panel.presses, focusSpace: focusSpace) {
                tv.activateSetting(row)
            }
            .equatable()
        }
    }

    /// Typing a profile's name: the keyboard, or the phone's Type on TV. Down goes to Done; Return saves.
    private func nameEntry(_ panel: SettingsPanel) -> some View {
        let renaming = panel.page != .profileName(nil)
        let onField = panel.row == 0
        return VStack(spacing: 28) {
            CaretText(text: panel.typed, placeholder: "Name", caret: onField ? panel.caret : nil)
                .font(.tv(.headline, emphasized: true))
                .padding(.horizontal, 34)
                .frame(minWidth: 480, minHeight: 76)
                .background(.white.opacity(onField ? 0.14 : 0.07), in: Capsule())
                .overlay(PillOutline().strokeBorder(.white.opacity(onField ? 0.85 : 0.12), lineWidth: onField ? 3 : 1))
                .contentShape(Capsule())
                .onTapGesture { tv.pages?.row = 0 }
            SettingsButton(title: renaming ? "Done" : "Create Profile", focused: !onField, presses: panel.presses) {
                tv.pages?.row = 1
                tv.handleSettings(.select)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(Motion.focus, value: onField)
    }
}

/// One row of Settings, the same everywhere: height, leading icon column, value colour, switches, steppers,
/// chevrons and text fields, and the focus platter. Focus lifts the platter out around the row and the text stays
/// in its column, so a focused row never sits out of line with the rest. A press dips it.
struct SettingsRow: View, Equatable {
    let content: SettingsRowContent
    let focused: Bool
    var presses = 0
    /// Control Center's lists: a row at Control Center's own scale, in a panel as wide as its tiles.
    var compact = false
    let focusSpace: Namespace.ID
    let action: () -> Void

    nonisolated static func == (lhs: SettingsRow, rhs: SettingsRow) -> Bool {
        lhs.content == rhs.content && lhs.focused == rhs.focused && lhs.presses == rhs.presses && lhs.compact == rhs.compact
            && lhs.focusSpace == rhs.focusSpace
    }

    private var titleFont: Font { compact ? .tv(.body) : SettingsMetrics.title }
    private var valueFont: Font { compact ? .tv(.caption1) : SettingsMetrics.value }

    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, SettingsMetrics.inset)
                .frame(height: SettingsMetrics.rowHeight)
                // tvOS focus: a bright white platter with dark text; a row asking to press again turns red.
                .foregroundStyle(focused && !content.warning ? .black : .white)
                .background {
                    let shape = RoundedRectangle(cornerRadius: SettingsMetrics.corner, style: .continuous)
                    if focused {
                        // One platter that glides from row to row as focus moves, like tvOS. Its shadow is the
                        // platter's alone, not cast by the text on it.
                        shape.fill(content.warning ? Color(hex: "#FF453A") : .white)
                            .padding(.horizontal, -8)
                            .padding(.vertical, -4)
                            .shadow(color: .black.opacity(0.4), radius: 16, y: 10)
                            .matchedGeometryEffect(id: "focus", in: focusSpace)
                    } else {
                        shape.fill(.white.opacity(0.07))
                    }
                }
                .animation(Motion.focus, value: focused)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressDip(presses: presses, focused: focused))
    }

    @ViewBuilder
    private var label: some View {
        if let field = content.field {
            // A text field: its label, then what's typed (or the placeholder) with the caret while it has focus.
            HStack(spacing: 0) {
                Text(content.title).font(SettingsMetrics.title).lineLimit(1)
                    .frame(width: 230, alignment: .leading)
                CaretText(text: field.secure ? String(repeating: "•", count: field.text.count) : field.text,
                          placeholder: field.placeholder, caret: field.caret)
                    .font(SettingsMetrics.title)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack(spacing: 18) {
                if let avatar = content.avatar {
                    ProfileAvatar(profile: avatar, size: 44)
                } else if let symbol = content.symbol {
                    Image(systemName: symbol).font(.system(size: 30, weight: .medium)).frame(width: 44)
                }
                Text(content.title).font(titleFont).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let value = content.value {
                    HStack(spacing: 12) {
                        if content.accessory == .stepper, focused { Image(systemName: "chevron.left") }
                        // 数字（"15 Minutes"）逐位滚动；名字（显示器、"Full Access"）整段淡入淡出，不能逐字飞，
                        // 否则新旧两段字会叠在一起、还会伸出这一行
                        Text(value).font(valueFont).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                            .contentTransition(value.first?.isNumber == true ? .numericText() : .opacity)
                        if content.accessory == .stepper, focused { Image(systemName: "chevron.right") }
                    }
                    .font(.system(size: 22, weight: .semibold))
                    .opacity(0.55)
                    .layoutPriority(1)   // a long value (a controller's name) keeps its room; the title gives way first
                }
                if let battery = content.battery { Image(systemName: battery).font(.system(size: 30)) }
                if content.checked { Image(systemName: "checkmark").font(.system(size: 25, weight: .bold)) }
                switch content.accessory {
                case .toggle(let on): SettingSwitch(on: on)
                case .chevron: Image(systemName: "chevron.right").font(.system(size: 24, weight: .semibold)).opacity(0.4)
                case .none, .stepper: EmptyView()
                }
            }
        }
    }
}

/// A button on a Settings page, such as Done under a name: the focus platter, and a press that dips it.
struct SettingsButton: View {
    let title: String
    let focused: Bool
    var presses = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.tv(.callout, emphasized: true))
                .padding(.horizontal, 36)
                .frame(height: 68)
                .foregroundStyle(focused ? .black : .white)
                .background(Capsule().fill(focused ? .white : .white.opacity(0.12)))
                .scaleEffect(focused ? 1.08 : 1)
                .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: 18, y: 12)
                .animation(Motion.focus, value: focused)
                .contentShape(Capsule())
        }
        .buttonStyle(PressDip(presses: presses, focused: focused))
    }
}

/// A control's press: it dips a little and settles back, with no bounce, while the pointer holds it down, and
/// for a moment when the remote or keyboard presses it (`presses` going up while it has focus).
struct PressDip: ButtonStyle {
    var presses = 0
    var focused = true

    func makeBody(configuration: Configuration) -> some View {
        PressDipped(label: configuration.label, held: configuration.isPressed, presses: presses, focused: focused)
    }
}

private struct PressDipped<Label: View>: View {
    let label: Label
    let held: Bool
    let presses: Int
    let focused: Bool
    @State private var flashing = false

    var body: some View {
        label
            .scaleEffect(held || flashing ? 0.96 : 1)
            .animation(Motion.press, value: held || flashing)
            .onChange(of: presses) {
                guard focused else { return }
                flashing = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(0.18))
                    flashing = false
                }
            }
    }
}

/// The checkmark on a chosen card. It moves at once when a card is chosen: fading or growing it in left a
/// small see-through blob over the card for a moment, which read as a purple square flashing on Drifting Color.
private struct ChosenMark: View {
    var size: CGFloat = 28

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
        HStack(spacing: 16) {
            ForEach(Array(all.enumerated()), id: \.element) { index, wallpaper in
                let isChosen = wallpaper == chosen, isLifted = index == lifted
                VStack(alignment: .leading, spacing: 8) {
                    WallpaperThumb(wallpaper: wallpaper)
                        .frame(height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(.white.opacity(isLifted ? 1 : isChosen && lifted == nil ? 0.6 : 0.12),
                                              lineWidth: isLifted || (isChosen && lifted == nil) ? 4 : 1)
                        }
                        .overlay(alignment: .topTrailing) { if isChosen { ChosenMark() } }
                        .scaleEffect(isLifted ? 1.05 : 1)
                        .shadow(color: .black.opacity(isLifted ? 0.45 : 0), radius: 16, y: 10)
                    Text(wallpaper.title).font(.tv(.caption1))
                        .opacity(isChosen || isLifted ? 1 : 0.6).padding(.leading, 4)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { choose(index) }
            }
        }
        .animation(Motion.focus, value: lifted)
        .padding(.bottom, 12)
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
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 12) {
            ForEach(Array(choices.enumerated()), id: \.element.name) { index, choice in
                let isChosen = choice.id == chosen, isLifted = index == lifted
                VStack(alignment: .leading, spacing: 8) {
                    Color.clear
                        .overlay {
                            if let thumb = Aerials.thumbnail(forCategory: choice.id), let image = ScreenImages.thumbnail(thumb) {
                                Image(nsImage: image).resizable().scaledToFill()
                            }
                        }
                        .frame(height: 74)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(.white.opacity(isLifted ? 1 : isChosen && lifted == nil ? 0.6 : 0.12),
                                              lineWidth: isLifted || (isChosen && lifted == nil) ? 3 : 1)
                        }
                        .overlay(alignment: .topTrailing) { if isChosen { ChosenMark(size: 20) } }
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
            .frame(width: 64, height: 38)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(.white).frame(width: 30, height: 30).padding(4)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            }
            .animation(.snappy(duration: 0.2), value: on)
    }
}
