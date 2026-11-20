import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import MacTV

@Suite(.timeLimit(.minutes(1))) @MainActor
struct AudioOutputTests {
    init() { AudioCoordinator.readVolume = { VolumeLevel(level: 50, muted: false) } }

    @Test
    func deviceSymbolMappingMatchesEndpointTypes() {
        let airPodsPro = AudioOutputDevice(id: 1, name: "Pratik’s AirPods Pro", transport: 0, isDefault: true)
        #expect(airPodsPro.symbol == "airpodspro")

        let airPodsMax = AudioOutputDevice(id: 2, name: "Living Room AirPods Max", transport: 0, isDefault: false)
        #expect(airPodsMax.symbol == "airpodsmax")

        let airPods = AudioOutputDevice(id: 3, name: "AirPods", transport: 0, isDefault: false)
        #expect(airPods.symbol == "airpods")

        let beats = AudioOutputDevice(id: 4, name: "Beats Solo", transport: 0, isDefault: false)
        #expect(beats.symbol == "headphones")

        let btHeadphones = AudioOutputDevice(id: 5, name: "WH-1000XM5", transport: kAudioDeviceTransportTypeBluetooth, isDefault: false)
        #expect(btHeadphones.symbol == "headphones")

        let hdmiTV = AudioOutputDevice(id: 6, name: "LG TV", transport: kAudioDeviceTransportTypeHDMI, isDefault: false)
        #expect(hdmiTV.symbol == "tv.fill")

        let dprtMonitor = AudioOutputDevice(id: 7, name: "DELL S2721DS", transport: 0x64707274, isDefault: false)
        #expect(dprtMonitor.symbol == "tv.fill")

        let airPlay = AudioOutputDevice(id: 8, name: "HomePod", transport: kAudioDeviceTransportTypeAirPlay, isDefault: false)
        #expect(airPlay.symbol == "airplayaudio")

        let builtIn = AudioOutputDevice(id: 9, name: "MacBook Pro Speakers", transport: kAudioDeviceTransportTypeBuiltIn, isDefault: true)
        #expect(builtIn.symbol == "speaker.wave.2.fill")
    }

    @Test
    func coordinatorDiscoversSystemOutputs() {
        // Build machines may have no sound output at all.
        let coordinator = AudioCoordinator()
        if let current = coordinator.currentDevice {
            #expect(coordinator.devices.contains(current))
        }
    }

    @Test
    func audioPickerNavigationAndSheetRouting() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }

        let tv = TVController(library: AppLibrary(folder: folder))
        #expect(tv.audioPicker == nil)
        #expect(tv.activeSheet == nil)

        tv.openAudioPicker()
        #expect(tv.audioPicker != nil)
        #expect(tv.activeSheet == .audioPicker)
        #expect(tv.isTopSheet(.audioPicker))

        // Deterministic navigation check
        tv.audioPicker?.row = 0
        if tv.audioDevices.count > 1 {
            tv.handleAudioPicker(.move(.down))
            #expect(tv.audioPicker?.row == 1)
            tv.handleAudioPicker(.move(.up))
            #expect(tv.audioPicker?.row == 0)
        }

        // Boundary clamp at top
        tv.handleAudioPicker(.move(.up))
        #expect(tv.audioPicker?.row == 0)

        // Volume slider navigation
        let sliderRow = tv.audioDevices.count
        tv.audioPicker?.row = sliderRow

        // ◀ ▶ here change the Mac's real volume, so the test only checks focus can reach it.
        #expect(tv.isTopSheet(.audioPicker))

        // Navigation sound slider
        let soundSliderRow = tv.audioDevices.count + 1
        tv.audioPicker?.row = soundSliderRow

        let (savedVolume, savedEnabled) = (Feedback.shared.volume, Feedback.shared.enabled)
        defer { Feedback.shared.volume = savedVolume; Feedback.shared.enabled = savedEnabled }
        Feedback.shared.volume = 0.50
        Feedback.shared.enabled = true
        tv.handleAudioPicker(.move(.left))
        #expect(abs(Feedback.shared.volume - 0.45) < 0.01)

        tv.handleAudioPicker(.move(.right))
        #expect(abs(Feedback.shared.volume - 0.50) < 0.01)

        tv.handleAudioPicker(.select)
        #expect(Feedback.shared.isMuted)
        tv.handleAudioPicker(.select)
        #expect(!Feedback.shared.isMuted)

        // Dismiss with Back
        tv.handleAudioPicker(.back)
        #expect(tv.audioPicker == nil)
        #expect(tv.activeSheet == nil)
    }

    /// Outputs come and go while the picker is open (AirPods connect, a display's audio comes back): focus stays
    /// on the row it was on, so the highlight never ends up on another output or slider.
    @Test
    func pickerFocusFollowsItsRowAsOutputsChange() {
        let display = AudioOutputDevice(id: 89, name: "XG27UCS", transport: 0x64707274, isDefault: true, uid: "EDID-1")
        let speakers = AudioOutputDevice(id: 73, name: "MacBook Pro Speakers", transport: kAudioDeviceTransportTypeBuiltIn,
                                         isDefault: false, uid: "BuiltInSpeakerDevice")
        let airPods = AudioOutputDevice(id: 12, name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth,
                                        isDefault: false, uid: "AIRPODS")
        let before = [display, speakers]
        let after = [airPods, display, speakers]
        // The same output, wherever it is now.
        #expect(AudioPickerPanel.row(1, from: before, to: after) == 2)
        #expect(AudioPickerPanel.row(0, from: before, to: after) == 1)
        // The same slider: Volume, then Navigation Clicks.
        #expect(AudioPickerPanel.row(2, from: before, to: after) == 3)
        #expect(AudioPickerPanel.row(3, from: before, to: after) == 4)
        #expect(AudioPickerPanel.row(3, from: after, to: before) == 2)
        // The display's audio comes back with a new Core Audio ID: still the same output.
        let reborn = AudioOutputDevice(id: 95, name: "XG27UCS", transport: 0x64707274, isDefault: true, uid: "EDID-1")
        #expect(AudioPickerPanel.row(0, from: before, to: [speakers, reborn]) == 1)
        // The focused output went away: the one now in its place, or the first row when none are left.
        #expect(AudioPickerPanel.row(1, from: before, to: [display]) == 0)
        #expect(AudioPickerPanel.row(0, from: before, to: []) == 0)
    }

    @Test
    func controlCenterItemsExcludeSounds() {
        #expect(!ControlCenterPanel.Item.allCases.contains(where: { "\($0)" == "sounds" }))
        let controls = ControlCenterPanel.Item.standardControls
        #expect(ControlCenterPanel.neighbour(of: .sleepTimer, .down, controls: controls) == .stayAwake)
        #expect(ControlCenterPanel.neighbour(of: .stayAwake, .up, controls: controls) == .sleepTimer)
    }
}

/// Interface sounds across an output switch: the next press is heard, and nothing pressed meanwhile is saved up
/// and played at once. No sound is played here: the engines are never started.
@Suite(.timeLimit(.minutes(1))) @MainActor
struct FeedbackOutputTests {
    @Test
    func aStuckOutputIsReplacedAndTapsNeverPileUp() {
        typealias State = Feedback.OutputState
        #expect(Feedback.outputState(running: false, runningFor: nil, renderAge: nil) == State.idle)
        #expect(Feedback.outputState(running: true, runningFor: 0.05, renderAge: nil) == State.starting)
        #expect(Feedback.outputState(running: true, runningFor: 2, renderAge: 0.01) == State.rendering)
        // Started a while ago and silent since (the output changed under it): start over, dropping what waits.
        #expect(Feedback.outputState(running: true, runningFor: 2, renderAge: nil) == State.stalled)
        #expect(Feedback.outputState(running: true, runningFor: 2, renderAge: 1.5) == State.stalled)
    }

    @Test
    func switchingOutputsStartsAFreshEngine() async throws {
        let suite = "MacTVTests.\(UUID().uuidString)"
        defer { TestDefaults.remove(suite) }
        let feedback = Feedback(preferences: Preferences(defaults: TestDefaults.named(suite)))
        let first = feedback.engine
        let firstPlayers = feedback.players

        feedback.outputChanged()
        #expect(feedback.engine !== first)
        #expect(!feedback.engine.isRunning)   // the next sound starts it, on the output in use then
        #expect(feedback.players.count == 3)
        #expect(feedback.players.allSatisfy { $0.engine === feedback.engine })
        #expect(feedback.players.allSatisfy { player in !firstPlayers.contains { $0 === player } })
        #expect(feedback.engine.mainMixerNode.outputVolume == feedback.volume)

        // macOS changing the output's format under the engine does the same.
        let second = feedback.engine
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: second)
        #expect(await eventually { feedback.engine !== second })
    }
}
