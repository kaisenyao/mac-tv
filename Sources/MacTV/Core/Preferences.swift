import Foundation

/// The viewer's settings, saved in UserDefaults under the keys Mac TV has always used.
///
/// Some are the person's own (watching, sounds, the screen saver, the clock): each profile has its own,
/// and a new profile starts with the defaults. The rest belong to this Mac and are the same for everyone
/// (power, updates, the TV display). The first profile's own settings stay in `defaults` with the Mac's,
/// where they've always been; another profile's are in its own defaults (see ProfileSpace).
///
/// They're published, so a screen showing a setting redraws when it changes, wherever it was
/// changed: the TV, the phone remote or Control Center. Features keep their own rules on top, like
/// which screen saver delays are allowed; this only stores the values.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    /// This Mac's settings, and the first profile's own.
    private let defaults: UserDefaults
    /// The settings of the person watching: `defaults` for the first profile.
    private var personal: UserDefaults
    /// Reading someone's settings in: nothing to save.
    private var loading = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        personal = defaults
        autoSkip = true
        autoNext = true
        navigationSounds = true
        navigationSoundVolume = 0.7
        saverWallpaper = nil
        saverDelay = nil
        saverClock = true
        saverAerialCategory = nil
        saverPhotos = nil
        twentyFourHourTime = FlipClockTime.systemTwentyFour
        controlCenterControls = nil
        keepMacAwake = defaults.object(forKey: Key.keepMacAwake) as? Bool ?? true
        lidOverride = defaults.bool(forKey: Key.lidOverride)
        automaticUpdates = defaults.object(forKey: Key.automaticUpdates) as? Bool ?? false // 默认不自动装，等你在设置里按
        dedicatedTVMode = defaults.bool(forKey: Key.dedicatedTVMode)
        preferredTVDisplay = defaults.string(forKey: Key.preferredTVDisplay)
        loadPersonal()
    }

    /// Someone else is watching: their own settings from now on, the defaults if they've never changed one.
    /// The Mac's settings stay as they are.
    func use(_ space: ProfileSpace) {
        let next = space.isMain ? defaults : space.defaults
        guard next !== personal else { return }
        personal = next
        loadPersonal()
    }

    private func loadPersonal() {
        loading = true
        defer { loading = false }
        let personal = personal
        autoSkip = personal.object(forKey: Key.autoSkip) as? Bool ?? true
        autoNext = personal.object(forKey: Key.autoNext) as? Bool ?? true
        navigationSounds = personal.object(forKey: Key.navigationSounds) as? Bool ?? true
        navigationSoundVolume = personal.object(forKey: Key.navigationSoundVolume) as? Float ?? 0.7
        saverWallpaper = personal.string(forKey: Key.saverWallpaper)
        saverDelay = personal.object(forKey: Key.saverDelay) as? Int
        saverClock = personal.object(forKey: Key.saverClock) as? Bool ?? true
        saverAerialCategory = personal.string(forKey: Key.saverAerialCategory)
        saverPhotos = personal.string(forKey: Key.saverPhotos)
        twentyFourHourTime = personal.object(forKey: Key.twentyFourHourTime) as? Bool ?? FlipClockTime.systemTwentyFour
        controlCenterControls = personal.stringArray(forKey: Key.controlCenterControls)
    }

    // MARK: Watching

    /// Press the players' own Skip Intro and Skip Recap buttons.
    @Published var autoSkip: Bool { didSet { save(autoSkip, Key.autoSkip) } }
    /// Press Next Episode when the player offers it.
    @Published var autoNext: Bool { didSet { save(autoNext, Key.autoNext) } }

    // MARK: Power

    /// Keep the Mac from sleeping on its own while Mac TV is open, so the remote can reach it.
    @Published var keepMacAwake: Bool { didSet { save(keepMacAwake, Key.keepMacAwake) } }
    /// Keep running with the lid closed, even on battery or without a TV connected.
    @Published var lidOverride: Bool { didSet { save(lidOverride, Key.lidOverride) } }

    // MARK: Sounds

    @Published var navigationSounds: Bool { didSet { save(navigationSounds, Key.navigationSounds) } }
    /// 0 to 1.
    @Published var navigationSoundVolume: Float { didSet { save(navigationSoundVolume, Key.navigationSoundVolume) } }

    // MARK: Updates

    @Published var automaticUpdates: Bool { didSet { save(automaticUpdates, Key.automaticUpdates) } }

    // MARK: Screen saver

    /// `ScreenSaverSettings.Wallpaper`'s raw value; nil for the default.
    @Published var saverWallpaper: String? { didSet { save(saverWallpaper, Key.saverWallpaper) } }
    /// Minutes; nil for the default.
    @Published var saverDelay: Int? { didSet { save(saverDelay, Key.saverDelay) } }
    @Published var saverClock: Bool { didSet { save(saverClock, Key.saverClock) } }
    /// A live wallpaper category's id; nil plays all of them.
    @Published var saverAerialCategory: String? { didSet { save(saverAerialCategory, Key.saverAerialCategory) } }
    /// The Your Photos folder's path; nil for Pictures.
    @Published var saverPhotos: String? { didSet { save(saverPhotos, Key.saverPhotos) } }

    // MARK: Dedicated TV

    @Published var dedicatedTVMode: Bool { didSet { save(dedicatedTVMode, Key.dedicatedTVMode) } }
    /// The display Mac TV moves to; nil picks one automatically.
    @Published var preferredTVDisplay: String? { didSet { save(preferredTVDisplay, Key.preferredTVDisplay) } }

    // MARK: Control Center

    /// The round buttons, in order, by `ControlCenterPanel.Item` raw value; nil for the standard ones.
    @Published var controlCenterControls: [String]? { didSet { save(controlCenterControls, Key.controlCenterControls) } }

    // MARK: Clock

    /// Every clock on the TV in 24-hour time; until it's changed, as this Mac shows the time.
    @Published var twentyFourHourTime: Bool { didSet { save(twentyFourHourTime, Key.twentyFourHourTime) } }

    private func save(_ value: Any?, _ key: String) {
        guard !loading else { return }
        let store = Key.personal.contains(key) ? personal : defaults
        if let value { store.set(value, forKey: key) } else { store.removeObject(forKey: key) }
    }

    private enum Key {
        /// Each profile's own; the rest are this Mac's.
        static let personal: Set<String> = [autoSkip, autoNext, navigationSounds, navigationSoundVolume, saverWallpaper,
                                            saverDelay, saverClock, saverAerialCategory, saverPhotos, twentyFourHourTime,
                                            controlCenterControls]

        static let autoSkip = "autoSkip"
        static let autoNext = "autoNext"
        static let keepMacAwake = "keepMacAwake"
        static let lidOverride = "lidOverride"
        static let navigationSounds = "uiFeedback"
        static let navigationSoundVolume = "uiFeedbackVolume"
        static let automaticUpdates = "automaticUpdates"
        static let saverWallpaper = "saverWallpaper"
        static let saverDelay = "saverDelay"
        static let saverClock = "saverClock"
        static let saverAerialCategory = "saverAerialCategory"
        static let saverPhotos = "saverPhotos"
        static let dedicatedTVMode = "dedicatedTVMode"
        static let preferredTVDisplay = "preferredTVDisplay"
        static let twentyFourHourTime = "twentyFourHourTime"
        static let controlCenterControls = "controlCenterControls"
    }
}
