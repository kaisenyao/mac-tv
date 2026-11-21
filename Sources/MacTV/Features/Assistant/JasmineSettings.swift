import Foundation
import os
import SwiftUI

/// An API key Jasmine uses. The owner types it in Settings › General › Jasmine; it's kept in this Mac's Keychain,
/// only ever sent to its own service, and never shown, logged or given to the phone.
enum JasmineKey: String, CaseIterable, Hashable {
    case openAI, elevenLabs

    var title: String {
        switch self {
        case .openAI: "OpenAI API Key"
        case .elevenLabs: "ElevenLabs API Key"
        }
    }
}

/// The Keychain items: service "Mac TV Jasmine", one account per key. Under the tests, in memory.
enum JasmineKeychain {
    private static let memory = SystemKeychain.memoryStore()

    private static func query(_ key: JasmineKey) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "Mac TV Jasmine",
         kSecAttrAccount as String: key.rawValue]
    }

    static func save(_ value: String, for key: JasmineKey) {
        if let memory { memory.withLock { $0[key.rawValue] = Data(value.utf8) }; return }
        SystemKeychain.delete(query(key))
        var item = query(key)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrLabel as String] = "Mac TV Jasmine \(key.title)"
        _ = SystemKeychain.add(item)
    }

    /// What reading a key found: the key, no key, or a Keychain (or keys helper) that couldn't be read.
    enum Read: Equatable {
        case found(String), missing, unreadable(OSStatus)
    }

    static func read(_ key: JasmineKey) -> Read {
        if let memory { return remembered(key, memory) }
        var result: CFTypeRef?
        let status = SystemKeychain.copyMatching(readQuery(key), &result)
        return read(status, result as? Data)
    }

    /// The same read, without holding the caller's thread while the Keychain answers.
    static func read(_ key: JasmineKey) async -> Read {
        if let memory { return remembered(key, memory) }
        let (status, data) = await SystemKeychain.copyMatching(readQuery(key))
        return read(status, data)
    }

    private static func remembered(_ key: JasmineKey, _ memory: OSAllocatedUnfairLock<[String: Data]>) -> Read {
        memory.withLock { $0[key.rawValue] }.flatMap { String(data: $0, encoding: .utf8) }.map(Read.found) ?? .missing
    }

    private static func readQuery(_ key: JasmineKey) -> [String: Any] {
        var item = query(key)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        return item
    }

    private static func read(_ status: OSStatus, _ data: Data?) -> Read {
        switch status {
        case errSecSuccess:
            guard let data, let value = String(data: data, encoding: .utf8) else { return .unreadable(status) }
            return .found(value)
        case errSecItemNotFound: return .missing
        default: return .unreadable(status)
        }
    }

    static func value(_ key: JasmineKey) -> String? {
        if case .found(let value) = read(key) { value } else { nil }
    }

    static func delete(_ key: JasmineKey) {
        if let memory { memory.withLock { _ = $0.removeValue(forKey: key.rawValue) }; return }
        SystemKeychain.delete(query(key))
    }
}

/// The voices the owner chose for PianaSoul (ElevenLabs voice IDs; ids aren't secrets). Ladaisy is Jasmine's.
struct JasmineVoice: Equatable {
    let name: String
    let id: String

    static let all = [
        JasmineVoice(name: "Ladaisy", id: "8RCmdqih4CKjJ7Bd3ZxT"),
        JasmineVoice(name: "Yating Lin", id: "5eoK8NqMBsMdqUmImHNs"),
        JasmineVoice(name: "Arthur", id: "xQsp9uyB3OResmXFYuFx"),
        JasmineVoice(name: "Ethan Zhang", id: "brChkoggsUHF1stW6omH"),
        JasmineVoice(name: "Hope", id: "tnSpp4vdxKPjI9w0GnoV"),
        JasmineVoice(name: "Jessica", id: "r1KmysJdVYZjJCm4mL3b"),
        JasmineVoice(name: "Mark", id: "1SM7GgM6IMuvQlz2BwM3"),
        JasmineVoice(name: "Adam", id: "s3TPKV1kjDlVtZbl4Ksh"),
    ]
}

/// Jasmine's settings, the same for everyone on this Mac.
@MainActor
final class JasmineSettings: ObservableObject {
    static let shared = JasmineSettings()

    private let defaults: UserDefaults
    private enum Key {
        static let enabled = "jasmineEnabled", voice = "jasmineVoice", microphone = "jasmineMicrophone"
    }

    /// Holding the Siri button talks to Jasmine and dictates. Off, it does nothing (a press still opens Search).
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: Key.enabled) } }
    @Published var voice: String { didSet { defaults.set(voice, forKey: Key.voice) } }
    /// The microphone chosen in Settings, by its UID; nil is Automatic (see AudioInputs.choose).
    @Published var microphone: String? { didSet { defaults.set(microphone, forKey: Key.microphone) } }
    /// Which keys are added. Only that is kept here; the keys themselves are read from the Keychain when used.
    @Published private(set) var added: Set<JasmineKey>
    /// Keys the Keychain (through the keys helper) couldn't be read for, and its status: said in the log and by her.
    @Published private(set) var unreadable: [JasmineKey: OSStatus] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        voice = defaults.string(forKey: Key.voice) ?? JasmineVoice.all[0].id
        microphone = defaults.string(forKey: Key.microphone)
        added = []
        // Which keys are added, read in the background: the Keychain may ask first ("Always Allow"), and Mac TV
        // goes on starting meanwhile
        checking = Set(JasmineKey.allCases)
        Task { [weak self] in
            for key in JasmineKey.allCases {
                let read = await JasmineKeychain.read(key)
                self?.checked(key, read)
            }
        }
    }

    /// Keys not read yet since Mac TV started.
    private var checking: Set<JasmineKey>

    private func checked(_ key: JasmineKey, _ read: JasmineKeychain.Read) {
        guard checking.remove(key) != nil else { return }   // read, saved or removed since
        switch read {
        case .found: added.insert(key)
        case .missing: break
        case .unreadable(let status):
            unreadable[key] = status
            Log.app.error("Jasmine: couldn't read the \(key.title, privacy: .public) from the Keychain (\(status, privacy: .public))")
        }
    }

    /// The key, read now; nil when there's none or it can't be read (`problem` says which).
    func key(_ key: JasmineKey) -> String? {
        guard added.contains(key) || unreadable[key] != nil || checking.remove(key) != nil else { return nil }
        switch JasmineKeychain.read(key) {
        case .found(let value):
            unreadable[key] = nil
            added.insert(key)
            return value
        case .missing:
            unreadable[key] = nil
            added.remove(key)
            return nil
        case .unreadable(let status):
            unreadable[key] = status
            Log.app.error("Jasmine: couldn't read the \(key.title, privacy: .public) from the Keychain (\(status, privacy: .public))")
            return nil
        }
    }

    /// Why a key can't be used, in her caption.
    func problem(_ key: JasmineKey) -> String {
        if let status = unreadable[key] { return "Can’t read the \(key.title) from the Keychain (\(status))." }
        return key == .openAI ? "Add an OpenAI API key in Settings › General › Jasmine." : "Add an ElevenLabs API key in Settings › General › Jasmine."
    }

    func save(_ value: String, for key: JasmineKey) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        JasmineKeychain.save(value, for: key)
        checking.remove(key)
        added.insert(key)
        unreadable[key] = nil
    }

    func remove(_ key: JasmineKey) {
        JasmineKeychain.delete(key)
        checking.remove(key)
        added.remove(key)
    }

    var voiceName: String { JasmineVoice.all.first { $0.id == voice }?.name ?? JasmineVoice.all[0].name }

    func stepVoice(_ step: Int) {
        let all = JasmineVoice.all
        let index = all.firstIndex { $0.id == voice } ?? 0
        voice = all[(index + step + all.count) % all.count].id
    }
}

/// What's typed into an API key field: never in a description, so it can't reach a log or a comparison's output.
struct SecretText: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    var text = ""
    var description: String { "SecretText(\(text.count) characters)" }
    var debugDescription: String { description }
}

// MARK: - Settings › General › Jasmine

/// Jasmine's pages in Settings.
enum JasminePage: Hashable {
    case main, microphones, key(JasmineKey)
}

/// Jasmine's rows in Settings.
enum JasmineRow: Hashable {
    /// General's row that opens Jasmine's page
    case open
    case enabled, voice, microphone, key(JasmineKey)
    /// Microphones: Automatic, then each one connected
    case automaticInput, input(String)
    /// An API key's page: the field, Done, and Remove API Key once one is added
    case keyField, keyDone, keyRemove

    var adjustable: Bool { self == .enabled || self == .voice }
    var opensPage: Bool {
        switch self {
        case .open, .microphone, .key: true
        default: false
        }
    }
    var group: String? {
        switch self {
        case .open: "ASSISTANT"
        case .enabled: "JASMINE"
        case .voice, .microphone: "VOICE"
        case .key(.openAI): "API KEYS"
        case .automaticInput: "MICROPHONE"
        default: nil
        }
    }
}

extension TVController {
    var jasmineSettings: JasmineSettings { JasmineSettings.shared }

    func jasmineRows(_ page: JasminePage) -> [SettingsPanel.Row] {
        let settings = jasmineSettings
        switch page {
        case .main:
            return [.jasmine(.enabled), .jasmine(.voice), .jasmine(.microphone), .jasmine(.key(.openAI)), .jasmine(.key(.elevenLabs))]
        case .microphones:
            return [.jasmine(.automaticInput)] + AudioInputs.list().map { .jasmine(.input($0.uid)) }
        case .key(let key):
            return [.jasmine(.keyField), .jasmine(.keyDone)] + (settings.added.contains(key) ? [.jasmine(.keyRemove)] : [])
        }
    }

    func jasmineHero(_ page: JasminePage) -> (title: String, symbol: String, avatar: Profile?) {
        switch page {
        case .main: ("Jasmine", "waveform.circle.fill", nil)
        case .microphones: ("Microphone", "mic.fill", nil)
        case .key(let key): (key.title, "key.fill", nil)
        }
    }

    func jasmineContent(_ row: JasmineRow, panel: SettingsPanel, focused: Bool) -> SettingsRowContent {
        let settings = jasmineSettings
        switch row {
        case .open:
            return SettingsRowContent(title: "Jasmine", value: settings.enabled ? "On" : "Off", accessory: .chevron)
        case .enabled: return SettingsRowContent(title: "Jasmine", accessory: .toggle(settings.enabled))
        case .voice: return SettingsRowContent(title: "Voice", value: settings.voiceName, accessory: .stepper)
        case .microphone:
            let chosen = settings.microphone.flatMap { uid in AudioInputs.list().first { $0.uid == uid } }
            return SettingsRowContent(title: "Microphone", value: chosen?.name ?? "Automatic", accessory: .chevron)
        case .key(let key):
            let value = settings.added.contains(key) ? "Added" : settings.unreadable[key] != nil ? "Unavailable" : "Not Added"
            return SettingsRowContent(title: key.title, value: value, accessory: .chevron)
        case .automaticInput:
            let automatic = AudioInputs.choose(nil, from: AudioInputs.list())
            return SettingsRowContent(title: "Automatic", value: automatic?.name, checked: settings.microphone == nil)
        case .input(let uid):
            let name = AudioInputs.list().first { $0.uid == uid }?.name ?? ""
            return SettingsRowContent(title: name, checked: settings.microphone == uid)
        case .keyField:
            guard case .jasmine(.key(let key))? = panel.page else { return SettingsRowContent(title: "") }
            return SettingsRowContent(title: "API Key", field: .init(
                text: panel.secret.text, placeholder: settings.added.contains(key) ? "Added" : "Required", editing: focused, secure: true,
                set: { [weak self] in self?.pages?.secret.text = $0 },
                submit: { [weak self] in if let panel = self?.pages { self?.saveJasmineKey(panel) } }))
        case .keyDone: return SettingsRowContent(title: "Done")
        case .keyRemove: return SettingsRowContent(title: "Remove API Key")
        }
    }

    func activateJasmine(_ row: JasmineRow, _ panel: SettingsPanel) {
        let settings = jasmineSettings
        switch row {
        case .open: openSettingsPage(.jasmine(.main))
        case .enabled: settings.enabled.toggle()
        case .voice: settings.stepVoice(1)
        case .microphone: openSettingsPage(.jasmine(.microphones))
        case .key(let key): openSettingsPage(.jasmine(.key(key)))
        case .automaticInput: settings.microphone = nil
        case .input(let uid): settings.microphone = uid
        case .keyField: pages?.row = 0
        case .keyDone: saveJasmineKey(panel)
        case .keyRemove: openSettingsPage(.confirmRemoval(.jasmine(.keyRemove)))
        }
        objectWillChange.send()
    }

    func adjustJasmine(_ row: JasmineRow, forward: Bool) {
        switch row {
        case .enabled: jasmineSettings.enabled = forward
        case .voice: jasmineSettings.stepVoice(forward ? 1 : -1)
        default: return
        }
        pages?.changes += 1
        objectWillChange.send()
    }

    /// Typing an API key: letters and ⌘V go in (the keyboard, or the phone's Type on TV), Delete takes one out,
    /// Down and Up move between the field, Done and Remove API Key. Return or Done saves; Back leaves the key as it was.
    func typeJasmineKey(_ command: RemoteCommand, _ panel: SettingsPanel) {
        var panel = panel
        let rows = settingsRows(panel)
        switch command {
        case .back:
            closeSettingsPage(&panel)
            pages = panel
            return
        case .move(.up): panel.row = max(0, panel.row - 1)
        case .move(.down): panel.row = min(rows.count - 1, panel.row + 1)
        case .text(let text):
            panel.row = 0
            panel.secret.text += text.filter { !$0.isNewline }
            pages = panel
            if text.hasSuffix("\n") { saveJasmineKey(panel) }
            return
        case .deleteBackward:
            panel.row = 0
            if !panel.secret.text.isEmpty { panel.secret.text.removeLast() }
        case .select:
            panel.presses += 1
            pages = panel
            if rows.indices.contains(panel.row), case .jasmine(let row) = rows[panel.row] { activateJasmine(row, panel) }
            return
        default: break
        }
        pages = panel
    }

    /// Done on a key's page: what's typed is saved (nothing typed keeps the key there is), and the page closes.
    private func saveJasmineKey(_ panel: SettingsPanel) {
        guard case .jasmine(.key(let key))? = panel.page else { return }
        if !panel.secret.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            jasmineSettings.save(panel.secret.text, for: key)
        }
        closeSettingsPage()
        objectWillChange.send()
    }

    /// Remove API Key, confirmed: the key leaves the Keychain, and its page closes.
    func removeJasmineKey(below: SettingsPanel) {
        guard case .jasmine(.key(let key))? = below.page else { return }
        jasmineSettings.remove(key)
        closeSettingsPage()
        objectWillChange.send()
    }
}
