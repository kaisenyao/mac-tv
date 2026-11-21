import Foundation

/// The sheets open over the home screen.
///
/// Several can be open at once, such as Settings under the pairing code it opened. Each kind has a
/// fixed layer, so which one is on top never depends on the order they opened in, and remote
/// presses go to the top one.
struct SheetStack {
    /// Bottom to top.
    enum Layer: Int, CaseIterable, Comparable {
        case controlCenter, settings, organizer, pairing, addApp, topShelfPreferences, audioPicker, displayPicker, appSwitcher
        case search, profilePicker, setup

        static func < (lhs: Layer, rhs: Layer) -> Bool { lhs.rawValue < rhs.rawValue }

        /// Setup and "Who's watching?" stay until they're finished. Home, Control Center and
        /// opening an app close the rest.
        var dismissible: Bool { self != .profilePicker && self != .setup }

        /// The name the phone remote knows it by.
        var remoteName: String {
            switch self {
            case .controlCenter: "control-center"
            case .settings: "settings"
            case .organizer: "arrange-apps"
            case .pairing: "pairing"
            case .addApp: "add-app"
            case .topShelfPreferences: "top-shelf"
            case .audioPicker: "audio-picker"
            case .displayPicker: "display-picker"
            case .appSwitcher: "app-switcher"
            case .search: "search"
            case .profilePicker: "profiles"
            case .setup: "setup"
            }
        }
    }

    var controlCenter: ControlCenterPanel?
    var settings: SettingsPanel?
    /// Arrange apps with the keyboard, game controller or phone's D-pad.
    var organizer: AppOrganizer?
    var pairing = false {
        didSet { if !pairing { connectRemote = .connect } }   // it opens on its first page next time
    }
    /// Connect a Remote's pages, under the pairing layer: Settings › Remotes and Devices on a sheet of their own.
    var connectRemote = SettingsPanel.connect
    var adder: AppAdder?
    var topShelfPreferences: TopShelfPreferencesPanel?
    var audioPicker: AudioPickerPanel?
    /// Control Center's Display tile: Full Screen, the displays and the brightness (see DisplayPickerSheet).
    var displayPicker: DisplayPickerPanel?
    /// Home pressed twice: the apps in the background (see AppQuit).
    var appSwitcher: AppSwitcher?
    /// Mac TV's Search (the Siri button pressed on Home; see SystemSearch).
    var search: SystemSearch?
    /// "Who's watching?"
    var profilePicker: ProfilePicker?
    /// First-run setup.
    var setup: SetupFlow?

    func isOpen(_ layer: Layer) -> Bool {
        switch layer {
        case .controlCenter: controlCenter != nil
        case .settings: settings != nil
        case .organizer: organizer != nil
        case .pairing: pairing
        case .addApp: adder != nil
        case .topShelfPreferences: topShelfPreferences != nil
        case .audioPicker: audioPicker != nil
        case .displayPicker: displayPicker != nil
        case .appSwitcher: appSwitcher != nil
        case .search: search != nil
        case .profilePicker: profilePicker != nil
        case .setup: setup != nil
        }
    }

    /// The open sheets, bottom to top.
    var open: [Layer] { Layer.allCases.filter(isOpen) }

    /// The sheet remote presses go to.
    var top: Layer? { Layer.allCases.last(where: isOpen) }

    mutating func close(_ layer: Layer) {
        switch layer {
        case .controlCenter: controlCenter = nil
        case .settings: settings = nil
        case .organizer: organizer = nil
        case .pairing: pairing = false
        case .addApp: adder = nil
        case .topShelfPreferences: topShelfPreferences = nil
        case .audioPicker: audioPicker = nil
        case .displayPicker: displayPicker = nil
        case .appSwitcher: appSwitcher = nil
        case .search: search = nil
        case .profilePicker: profilePicker = nil
        case .setup: setup = nil
        }
    }

    /// Closes every sheet the viewer can dismiss.
    mutating func closeDismissible() {
        for layer in Layer.allCases where layer.dismissible { close(layer) }
    }
}

// Each sheet's state by name, so features read and change their own sheet as before.
extension TVController {
    var controlCenter: ControlCenterPanel? {
        get { sheets.controlCenter }
        set { sheets.controlCenter = newValue }
    }
    var settings: SettingsPanel? {
        get { sheets.settings }
        set { sheets.settings = newValue }
    }
    var organizer: AppOrganizer? {
        get { sheets.organizer }
        set { sheets.organizer = newValue }
    }
    var pairing: Bool {
        get { sheets.pairing }
        set { sheets.pairing = newValue }
    }
    var connectRemote: SettingsPanel {
        get { sheets.connectRemote }
        set { sheets.connectRemote = newValue }
    }
    var adder: AppAdder? {
        get { sheets.adder }
        set { sheets.adder = newValue }
    }
    var topShelfPreferences: TopShelfPreferencesPanel? {
        get { sheets.topShelfPreferences }
        set { sheets.topShelfPreferences = newValue }
    }
    var audioPicker: AudioPickerPanel? {
        get { sheets.audioPicker }
        set { sheets.audioPicker = newValue }
    }
    var displayPicker: DisplayPickerPanel? {
        get { sheets.displayPicker }
        set { sheets.displayPicker = newValue }
    }
    var appSwitcher: AppSwitcher? {
        get { sheets.appSwitcher }
        set { sheets.appSwitcher = newValue }
    }
    var profilePicker: ProfilePicker? {
        get { sheets.profilePicker }
        set { sheets.profilePicker = newValue }
    }
    var setup: SetupFlow? {
        get { sheets.setup }
        set { sheets.setup = newValue }
    }

    /// The sheet remote presses go to, if any.
    var activeSheet: SheetStack.Layer? { sheets.top }

    func isTopSheet(_ layer: SheetStack.Layer) -> Bool {
        sheets.top == layer && !screensaver
    }
}
