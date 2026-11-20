import Foundation
import Testing
@testable import MacTV

@Suite @MainActor struct StartupPairingTests {
    private func withController(_ body: (TVController) throws -> Void) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/startup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(TVController(library: AppLibrary(folder: folder)))
    }

    @Test func guestsCannotNavigateOwnerSettingsOrTypeIntoTheMac() throws {
        try withController { tv in
            tv.settings = SettingsPanel()
            #expect(!tv.handleGuestCommand(.move(.down)))
            #expect(!tv.handleGuestCommand(.select))
            #expect(!tv.handleGuestCommand(.text("private setting")))
            #expect(!tv.handleGuestCommand(.setting("keepMacAwake", false)))
            #expect(tv.settings != nil)
        }
    }

    @Test func reconnectDismissesStartupQRButKeepsManuallyOpenedQR() throws {
        try withController { tv in
            tv.offerStartupPairing()
            #expect(tv.pairing)
            _ = tv.remoteState()
            #expect(!tv.pairing)
            tv.pairing = true
            _ = tv.remoteState()
            #expect(tv.pairing)
        }
    }

    @Test func waitsForSetupAndProfileSelection() throws {
        try withController { tv in
            tv.setup = SetupFlow(step: .remote)
            tv.profilePicker = ProfilePicker()
            tv.offerStartupPairing()
            #expect(!tv.pairing)
            tv.finishSetup()
            #expect(!tv.pairing)
            tv.handleProfiles(.back)
            #expect(tv.pairing)
        }
    }

    @Test func phoneConnectingDuringProfileSelectionCancelsDeferredQR() throws {
        try withController { tv in
            tv.profilePicker = ProfilePicker()
            tv.offerStartupPairing()
            _ = tv.remoteState()
            tv.handleProfiles(.back)
            #expect(!tv.pairing)
        }
    }

    @Test func aSiriRemoteOrControllerAlreadyConnectedSkipsStartupPairing() throws {
        try withController { tv in
            SiriRemoteStatus.shared.connected = true
            defer { SiriRemoteStatus.shared.connected = false }
            tv.offerStartupPairing()
            #expect(!tv.pairing)
        }
        try withController { tv in
            tv.controller = ControllerInfo(name: "DualSense Wireless Controller")
            tv.offerStartupPairing()
            #expect(!tv.pairing)
        }
    }

    @Test func aSiriRemoteOrControllerConnectingDismissesStartupQRButKeepsManuallyOpenedQR() throws {
        try withController { tv in
            tv.offerStartupPairing()
            #expect(tv.pairing)
            tv.siriRemote(.playPause)                 // 用 Siri Remote 按了一下
            #expect(!tv.pairing)
            tv.pairing = true                         // 自己打开的配对页：不会被关掉
            tv.siriRemote(.playPause)
            #expect(tv.pairing)
        }
        try withController { tv in
            tv.offerStartupPairing()
            #expect(tv.pairing)
            tv.controllerChanged(ControllerInfo(name: "Xbox Wireless Controller"), connected: true)
            #expect(!tv.pairing)
        }
    }

    @Test func pairingSheetOffersBluetoothSettings() throws {
        try withController { tv in
            #expect(tv.pairingRows.contains(.bluetooth))
            #expect(tv.pairingRows.last == .done)
        }
    }

    @Test func optOutSkipsStartupPairing() throws {
        let suite = "MacTV.StartupPairing.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.showPairingAtLaunch = false
        var services = AppServices()
        services.preferences = preferences
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/startup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tv = TVController(library: AppLibrary(folder: folder), services: services)
        tv.offerStartupPairing()
        #expect(!tv.pairing)
    }

    @Test func openingSettingsDoesNotForcePairing() throws {
        // "Phone paired" lives in the app's real settings: put it back afterwards.
        let saved = UserDefaults.standard.object(forKey: "phonePaired")
        defer { UserDefaults.standard.set(saved, forKey: "phonePaired") }
        try withController { tv in
            tv.phonePaired = false
            tv.openSettings()
            #expect(tv.settings != nil)
            #expect(!tv.pairing)
        }
    }
}
