import AppKit
import Testing
@testable import MacTV

@Suite @MainActor
struct SheetStackTests {
    init() {
        _ = NSApplication.shared
        AudioCoordinator.readVolume = { VolumeLevel(level: 50, muted: false) }
    }

    @Test
    func layersDecideTheTopSheetWhateverOpenedFirst() {
        var sheets = SheetStack()
        sheets.pairing = true
        sheets.settings = SettingsPanel()
        #expect(sheets.open == [.settings, .pairing])
        #expect(sheets.top == .pairing)

        sheets.close(.pairing)
        #expect(sheets.top == .settings)
        sheets.close(.settings)
        #expect(sheets.top == nil)
    }

    @Test
    func homeClosesEverySheetButSetupAndProfiles() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let tv = TVController(library: AppLibrary(folder: folder))

        tv.adder = AppAdder()
        tv.openAudioPicker()
        tv.settings = SettingsPanel()
        tv.handle(.home)
        #expect(tv.sheets.open.isEmpty)

        tv.profilePicker = ProfilePicker()
        tv.settings = SettingsPanel()
        tv.lastHomePress = nil   // a press of its own, not the second of two (that's the App Switcher)
        tv.handle(.home)
        #expect(tv.sheets.open == [.profilePicker])
    }

    @Test
    func homeTwiceIsTheAppSwitcherAndHomeClosesIt() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let tv = TVController(library: AppLibrary(folder: folder))
        tv.movies = MoviesBrowser()   // an app to switch to: with none, there's no switcher
        tv.handle(.home)
        tv.handle(.home)
        #expect(tv.sheets.top == .appSwitcher && tv.remoteState()["sheet"] as? String == "app-switcher")
        tv.handle(.home)
        #expect(tv.sheets.open.isEmpty)
    }

    @Test
    func remotePressesGoToTheTopSheet() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let tv = TVController(library: AppLibrary(folder: folder))

        tv.settings = SettingsPanel()
        tv.openAudioPicker()
        tv.handle(.back)
        #expect(tv.audioPicker == nil)
        #expect(tv.settings != nil)
        #expect(tv.remoteState()["sheet"] as? String == "settings")
    }
}
