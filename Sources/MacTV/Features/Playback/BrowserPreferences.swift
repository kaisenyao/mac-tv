import Foundation

/// A website player choice belongs to the Mac TV profile, not the system browser.
enum BrowserChoice: String {
    case embedded, brave
}

struct BrowserPreferences {
    private let defaults: UserDefaults
    private let key = "websitePlayerByProfile"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The built-in player until someone chooses Brave: installing Brave never switches a profile on its own.
    func choice(for profileID: String) -> BrowserChoice {
        let choices = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        return choices[profileID].flatMap(BrowserChoice.init(rawValue:)) ?? .embedded
    }

    func setChoice(_ choice: BrowserChoice, for profileID: String) {
        var choices = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        choices[profileID] = choice.rawValue
        defaults.set(choices, forKey: key)
    }

    /// A removed profile's choice goes with it.
    func forget(_ profileID: String) {
        var choices = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        guard choices.removeValue(forKey: profileID) != nil else { return }
        defaults.set(choices, forKey: key)
    }
}
