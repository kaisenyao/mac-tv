import Foundation
import Testing
@testable import MacTV

@Suite(.timeLimit(.minutes(1))) @MainActor struct StartupPairingTests {
    private func withController(_ body: (TVController) throws -> Void) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/startup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tv = TVController(library: AppLibrary(folder: folder))
        tv.remoteCoordinator.pairingStore = PairingStore(folder: folder)   // no phone ever paired
        try body(tv)
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

    @Test func pairingSheetOffersTheRemotesAndBluetoothSettings() throws {
        try withController { tv in
            tv.pairing = true
            #expect(tv.settingsRows(tv.connectRemote) == [.siriRemote, .iPhone, .otherControllers])
            tv.handlePairing(.select)
            #expect(tv.settingsRows(tv.connectRemote).contains(.bluetooth))
            tv.handlePairing(.back)
            tv.handlePairing(.back)   // no Done button: Back closes it
            #expect(!tv.pairing)
        }
    }

    @Test func aPairedPhoneCountsAsARemoteAtLaunch() throws {
        try withController { tv in
            // Paired before, its page just isn't open yet: still a remote, so no sheet.
            _ = try tv.remoteCoordinator.pairingStore.issue(name: "iPhone", guest: false)
            tv.offerStartupPairing()
            #expect(!tv.pairing)
        }
        try withController { tv in
            tv.offerStartupPairing()   // no remote at all: the sheet, as Apple TV's pairing screen
            #expect(tv.pairing)
            tv.handlePairing(.back)
            #expect(!tv.pairing)
        }
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
