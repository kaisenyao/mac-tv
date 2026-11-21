import AppKit
import CoreAudio
import SwiftUI

/// An audio output endpoint (AirPods, TV HDMI, built-in speakers, etc.).
struct AudioOutputDevice: Identifiable, Equatable, Hashable {
    let id: AudioDeviceID
    let name: String
    let transport: UInt32
    let isDefault: Bool
    /// CoreAudio 的 UID。显示器的声音在 Apple 芯片上就是显示器的 EDID UUID（见 DisplayAudioLink）
    var uid = ""

    /// Speakers' symbol (anything that isn't headphones, a TV or AirPlay): Control Center draws the volume's speaker for it.
    static let speakerSymbol = "speaker.wave.2.fill"

    /// Control Center's Audio tile: speakers (the Mac's own or any others) show the volume's speaker, whose waves follow
    /// the volume; headphones, a TV, AirPlay their own symbol.
    var tileSymbol: String { transport == kAudioDeviceTransportTypeBuiltIn ? Self.speakerSymbol : symbol }

    /// Maps transport type and device name to the appropriate tvOS SF Symbol.
    var symbol: String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("beats") || lower.contains("headphone") { return "headphones" }

        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            // The Mac's own speakers: the Mac, as macOS's Sound settings show them
            if lower.contains("mac mini") { return "macmini" }
            if lower.contains("imac") { return "desktopcomputer" }
            if lower.contains("macbook") { return "macbook" }
            return Self.speakerSymbol
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "headphones"
        case kAudioDeviceTransportTypeHDMI, 0x64707274 /* 'dprt' DisplayPort */:
            return NSScreen.externalSymbol   // a TV or a monitor: the same symbol the display list and Control Center's Display show for it
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        default:
            return Self.speakerSymbol
        }
    }
}

/// The TV's audio output picker sheet state: the outputs, then the Volume and Navigation Clicks sliders.
struct AudioPickerPanel: Equatable {
    var row = 0

    /// The focused row once the outputs change: the same output, or the same slider, wherever it is now.
    /// An output that went away leaves focus on the one now in its place.
    static func row(_ row: Int, from old: [AudioOutputDevice], to new: [AudioOutputDevice]) -> Int {
        guard old.indices.contains(row) else { return new.count + max(0, min(1, row - old.count)) }
        let focused = old[row]
        if let index = new.firstIndex(where: { $0.id == focused.id || (!focused.uid.isEmpty && $0.uid == focused.uid) }) {
            return index
        }
        return max(0, min(row, new.count - 1))
    }
}

/// Manages system audio output endpoints and monitors device route changes via CoreAudio.
@MainActor
final class AudioCoordinator: ObservableObject {
    weak var tv: TVController?

    @Published private(set) var devices: [AudioOutputDevice] = []
    @Published private(set) var currentDevice: AudioOutputDevice?

    nonisolated(unsafe) private var defaultListenerBlock: AudioObjectPropertyListenerBlock?
    nonisolated(unsafe) private var devicesListenerBlock: AudioObjectPropertyListenerBlock?

    nonisolated(unsafe) private var defaultAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    nonisolated(unsafe) private var devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init(tv: TVController? = nil) {
        self.tv = tv
        fixedOutput.onChange = { [weak self] level, showHUD in
            guard let self else { return }
            currentVolume = level
            volumePending = fixedOutput.deciding
            if showHUD { tv?.showVolume(level) }
        }
        fixedOutput.reachesPlayback = { [weak self] in
            NSApplication.shared.isActive && self?.tv?.playbackCoordinator.externalBrowser == nil
        }
        refreshDevices()
        startListening()
    }

    deinit {
        stopListening()
    }

    // MARK: - CoreAudio Device Querying

    func refreshDevices() {
        let defaultID = defaultOutputDeviceID()
        var newDevices: [AudioOutputDevice] = []

        for id in allAudioDeviceIDs() {
            guard hasOutputStreams(id), !isHidden(id) else { continue }
            // Apps get a private "CADefaultDeviceAggregate-<pid>" device that isn't a real output.
            guard let name = deviceName(id), !name.hasPrefix("CADefaultDeviceAggregate") else { continue }
            let transport = transportType(id)
            let isCurrent = (id == defaultID)

            let device = AudioOutputDevice(
                id: id,
                name: name,
                transport: transport,
                isDefault: isCurrent,
                uid: deviceUID(id) ?? ""
            )
            newDevices.append(device)
        }

        // Focus stays on the same output or slider as the list changes, so the highlight never lands on another row.
        if let row = tv?.audioPicker?.row {
            tv?.audioPicker?.row = AudioPickerPanel.row(row, from: devices, to: newDevices)
        }
        self.devices = newDevices
        let previous = currentDevice
        self.currentDevice = newDevices.first(where: { $0.id == defaultID })
        fixedOutput.keep(Set(newDevices.map(\.uid)))
        refreshVolume()
        // The interface sounds start over on the new output, so the next press is heard (see Feedback.outputChanged).
        if previous != nil, currentDevice?.id != previous?.id { tv?.feedback.outputChanged() }
    }

    /// Core Audio changed the outputs or the default one: list them again, and ask a display that just
    /// became the output for its volume now, rather than at the first press.
    private func outputsChanged() {
        refreshDevices()
        readFixedOutputVolume()
    }

    // MARK: - Volume Controls

    @Published private(set) var currentVolume = VolumeLevel(level: nil, muted: false)
    /// Still asking the output's display whether it answers (just switched to it, or the picker just opened):
    /// the Volume slider waits empty rather than saying Not Available.
    @Published private(set) var volumePending = false

    /// Reads the Mac's volume. Tests swap it out, so they don't depend on the Mac's sound hardware.
    static var readVolume: () -> VolumeLevel = SystemControl.volume

    /// 系统调不了音量的输出：显示器自己的音量（DDC），不然是 Mac TV 自己放的声音（见 FixedOutputVolume）
    let fixedOutput = FixedOutputVolume()

    func refreshVolume() {
        let system = Self.readVolume()
        fixedOutput.update(currentDevice, systemControls: system.level != nil)
        currentVolume = system.level != nil ? system : fixedOutput.volume
        volumePending = system.level == nil && fixedOutput.deciding
    }

    /// 系统能调现在这个输出的音量（内建扬声器、AirPods…）：照旧用 CoreAudio
    private var systemControlsVolume: Bool {
        let settable = Self.readVolume().level != nil
        fixedOutput.update(currentDevice, systemControls: settable)
        return settable
    }

    /// 遥控器、键盘上的音量键：调完出音量条
    func pressVolume(by delta: Int) {
        guard systemControlsVolume else { fixedOutput.perform(.step(delta), showHUD: true); return }
        currentVolume = SystemControl.changeVolume(by: delta)
        tv?.showVolume(currentVolume)
    }

    func pressMute() {
        guard systemControlsVolume else { fixedOutput.perform(.toggleMute, showHUD: true); return }
        currentVolume = SystemControl.toggleMute()
        tv?.showVolume(currentVolume)
    }

    // The audio picker's own controls. The picker shows the level itself, so there's no volume HUD.
    func setVolume(_ level: Int) {
        guard systemControlsVolume else { fixedOutput.perform(.set(level), showHUD: false); return }
        currentVolume = SystemControl.setVolume(to: level)
    }

    /// A drag sets the volume only when the level changes.
    func dragVolume(to level: Int) {
        guard level != currentVolume.level || currentVolume.muted else { return }
        setVolume(level)
    }

    func stepVolume(by delta: Int) {
        guard systemControlsVolume else { fixedOutput.perform(.step(delta), showHUD: false); return }
        currentVolume = SystemControl.changeVolume(by: delta)
    }

    func toggleMute() {
        guard systemControlsVolume else { fixedOutput.perform(.toggleMute, showHUD: false); return }
        currentVolume = SystemControl.toggleMute()
    }

    /// 打开音量面板、换了输出时：系统调不了的输出读一次显示器（还不知道归谁调就是去问它），或拿 Mac TV 自己的音量
    func readFixedOutputVolume() {
        guard !systemControlsVolume else { volumePending = false; return }
        fixedOutput.perform(.refresh, showHUD: false)
        volumePending = fixedOutput.deciding
    }

    func selectDevice(_ device: AudioOutputDevice) {
        guard SystemGuard.allows("switch the audio output to \(device.id)") else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var targetID = device.id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            size,
            &targetID
        )

        guard status == noErr else {
            Log.audio.error("Couldn't switch audio output: \(status, privacy: .public)")
            return
        }
        Log.audio.notice("Audio output switched to a \(DiagnosticReport.transportName(device.transport), privacy: .public) device")
        outputsChanged()
    }

    // MARK: - Real-Time CoreAudio Listeners

    private func startListening() {
        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.outputsChanged() }
        }
        self.defaultListenerBlock = defaultBlock
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddress,
            DispatchQueue.main,
            defaultBlock
        )

        let devicesBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.outputsChanged() }
        }
        self.devicesListenerBlock = devicesBlock
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            DispatchQueue.main,
            devicesBlock
        )
    }

    nonisolated private func stopListening() {
        if let block = defaultListenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultAddress,
                DispatchQueue.main,
                block
            )
        }
        if let block = devicesListenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &devicesAddress,
                DispatchQueue.main,
                block
            )
        }
    }

    // MARK: - Low-Level Helpers

    private func defaultOutputDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return deviceID
    }

    private func allAudioDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
        return ids
    }

    private func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size)
        return size > 0
    }

    /// Aggregate and helper devices macOS keeps out of its own sound menu.
    private func isHidden(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIsHidden,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var hidden: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &hidden)
        return status == noErr && hidden != 0
    }

    private func deviceName(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &cfName)
        guard status == noErr, let name = cfName?.takeRetainedValue() as String? else { return nil }
        return name
    }

    private func deviceUID(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &cfUID) == noErr else { return nil }
        return cfUID?.takeRetainedValue() as String?
    }

    private func transportType(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport)
        return transport
    }
}

extension TVController {
    func openAudioPicker() {
        audioCoordinator.refreshVolume()
        audioCoordinator.readFixedOutputVolume()
        let currentIndex = audioDevices.firstIndex(where: { $0.isDefault }) ?? 0
        audioPicker = AudioPickerPanel(row: currentIndex)
    }

    func handleAudioPicker(_ command: RemoteCommand) {
        guard var panel = audioPicker else { return }
        let masterSliderRow = audioDevices.count
        let soundSliderRow = audioDevices.count + 1
        let maxRow = soundSliderRow

        switch command {
        case .back:
            audioPicker = nil
            return
        case .move(.up):
            panel.row = max(0, panel.row - 1)
        case .move(.down):
            panel.row = min(maxRow, panel.row + 1)
        case .move(.left):
            if panel.row == masterSliderRow {
                stepPickerVolume(by: -5)
                return
            } else if panel.row == soundSliderRow {
                feedback.stepVolume(by: -0.05)
                return
            }
        case .move(.right):
            if panel.row == masterSliderRow {
                stepPickerVolume(by: 5)
                return
            } else if panel.row == soundSliderRow {
                feedback.stepVolume(by: 0.05)
                return
            }
        case .select:
            if panel.row == masterSliderRow {
                audioCoordinator.toggleMute()
                return
            } else if panel.row == soundSliderRow {
                feedback.toggleMute()
                return
            } else if audioDevices.indices.contains(panel.row) {
                audioCoordinator.selectDevice(audioDevices[panel.row])
                return
            }
        case .volume(let delta):
            audioCoordinator.stepVolume(by: delta)
            return
        case .mute:
            audioCoordinator.toggleMute()
            return
        default:
            break
        }
        audioPicker = panel
    }

    /// Left and Right on the Volume slider: a step, and a tick at the new level so you hear it, like the Navigation
    /// Clicks slider. The tick goes through whatever sets the volume: the Mac's, the display's, or Mac TV's own.
    /// Nothing when there's nothing to set.
    private func stepPickerVolume(by delta: Int) {
        guard audioCoordinator.currentVolume.level != nil || audioCoordinator.volumePending else { return }
        audioCoordinator.stepVolume(by: delta)
        feedback.play(.move, from: .keyboard)
    }
}

// MARK: - Audio Picker Sheet

struct AudioPickerSheet: View {
    @ObservedObject var tv: TVController
    @Environment(\.canvasSize) private var canvas

    var body: some View {
        let panel = tv.audioPicker ?? AudioPickerPanel()
        let masterSliderRow = tv.audioDevices.count
        let soundSliderRow = tv.audioDevices.count + 1

        VStack(alignment: .leading, spacing: 22) {
            // No Done button: Back closes it, as on Apple TV.
            Text("Audio Output").font(.tv(.title3, emphasized: true))

            VStack(spacing: 12) {
                if tv.audioDevices.isEmpty {
                    Text("No Audio Outputs")
                        .font(.tv(.callout))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    ForEach(Array(tv.audioDevices.enumerated()), id: \.element.id) { index, device in
                        let focused = (panel.row == index)
                        HStack(spacing: 18) {
                            // Every output's symbol fitted to one box: a wide MacBook, a TV and AirPods look the same size
                            Image(systemName: device.symbol)
                                .resizable()
                                .fontWeight(.medium)
                                .scaledToFit()
                                .frame(width: 40, height: 30)

                            Text(device.name)
                                .font(.tvMenuItem)
                                .lineLimit(1)

                            Spacer(minLength: 12)

                            if device.isDefault {
                                Image(systemName: "checkmark")
                                    .font(.tvMenuDetail)
                            }
                        }
                        .padding(.horizontal, 24)
                        .frame(height: 68)
                        .background(
                            focused ? Color.white : Color.white.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                        )
                        .foregroundStyle(focused ? Color.black : Color.white)
                        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .scaleEffect(focused ? 1.02 : 1)
                        .onTapGesture {
                            // A click focuses the row it chose, like the sliders, so focus and the checkmark agree.
                            tv.audioPicker?.row = index
                            tv.audioCoordinator.selectDevice(device)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Volume")
                    .font(.tv(.caption1, emphasized: true))
                    .foregroundStyle(.white.opacity(0.75))

                AudioVolumeSlider(tv: tv, focused: panel.row == masterSliderRow) {
                    tv.audioPicker?.row = masterSliderRow
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Navigation Clicks")   // Apple's tvOS name, as in Settings › Video and Audio
                    .font(.tv(.caption1, emphasized: true))
                    .foregroundStyle(.white.opacity(0.75))

                NavigationSoundSlider(focused: panel.row == soundSliderRow) {
                    tv.audioPicker?.row = soundSliderRow
                }
            }
        }
        .padding(52)
        .frame(width: 820, alignment: .leading)
        .tvPanel(in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .foregroundStyle(.white)
        .frame(width: canvas.width, height: canvas.height)
        .animation(Motion.focus, value: panel)
    }
}

struct AudioVolumeSlider: View {
    @ObservedObject var tv: TVController
    let focused: Bool
    var onSelect: () -> Void = {}

    private var volume: VolumeLevel {
        tv.audioCoordinator.currentVolume
    }

    /// Still asking the display: the slider waits empty, and fills once the level is known.
    private var pending: Bool {
        tv.audioCoordinator.volumePending
    }

    /// The speaker beside a slider (both sliders, so they match).
    static let speaker = CGSize(width: 36, height: 26)

    static func level(at x: CGFloat, width: CGFloat) -> Int {
        Int((max(0, min(1, x / width)) * 100).rounded())
    }

    var body: some View {
        HStack(spacing: 16) {
            Button {
                tv.audioCoordinator.toggleMute()
            } label: {
                SpeakerGlyph(level: pending ? nil : volume.level, muted: volume.muted, unknown: pending ? "speaker.fill" : "tv",
                             box: Self.speaker)
                    .opacity(pending ? 0.5 : 1)
            }
            .buttonStyle(.plain)

            if pending || volume.level != nil {
                let level = pending || volume.muted ? 0 : volume.level ?? 0
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(focused ? Color.white.opacity(0.35) : Color.white.opacity(0.18))

                        Capsule()
                            .fill(focused ? Color.white : Color.white.opacity(0.85))
                            .frame(width: geo.size.width * CGFloat(level) / 100)
                    }
                    .frame(height: 12)
                    .frame(maxHeight: .infinity, alignment: .center)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                tv.audioCoordinator.dragVolume(to: Self.level(at: value.location.x, width: geo.size.width))
                            }
                            .onEnded { value in
                                let level = Self.level(at: value.location.x, width: geo.size.width)
                                if level != volume.level || volume.muted { tv.audioCoordinator.setVolume(level) }
                            }
                    )
                }
                .frame(height: 36)

                Text(pending ? "" : volume.muted ? "Muted" : "\(volume.level ?? 0)%")
                    .font(.tv(.caption1, emphasized: true))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 80, alignment: .trailing)
                    .foregroundStyle(focused ? .white : .white.opacity(0.75))
            } else {
                Text("Not Available")
                    .font(.tv(.caption1))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
            }
        }
        .animation(Motion.appear, value: pending)
        .padding(.horizontal, 22)
        .frame(height: 64)
        .background(
            focused ? Color.white.opacity(0.16) : Color.white.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(focused ? Color.white.opacity(0.6) : Color.clear, lineWidth: 2)
        )
        .foregroundStyle(.white)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .scaleEffect(focused ? 1.02 : 1)
        .onTapGesture {
            onSelect()
        }
    }
}

struct NavigationSoundSlider: View {
    /// The navigation sound settings live in Preferences, so watching it redraws the slider.
    @ObservedObject private var preferences = Preferences.shared
    private var feedback: Feedback { .shared }
    let focused: Bool
    var onSelect: () -> Void = {}

    private var percent: Int {
        Int((feedback.volume * 100).rounded())
    }

    var body: some View {
        HStack(spacing: 16) {
            Button {
                feedback.toggleMute()
            } label: {
                SpeakerGlyph(level: percent, muted: feedback.isMuted, box: AudioVolumeSlider.speaker)
            }
            .buttonStyle(.plain)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(focused ? Color.white.opacity(0.35) : Color.white.opacity(0.18))

                    Capsule()
                        .fill(focused ? Color.white : Color.white.opacity(0.85))
                        .frame(width: geo.size.width * CGFloat(feedback.isMuted ? 0 : percent) / 100)
                }
                .frame(height: 12)
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let fraction = max(0, min(1, value.location.x / geo.size.width))
                            feedback.setVolumePercent(Int((fraction * 100).rounded()))
                        }
                )
            }
            .frame(height: 36)

            Text(feedback.isMuted ? "Muted" : "\(percent)%")
                .font(.tv(.caption1, emphasized: true))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 80, alignment: .trailing)
                .foregroundStyle(focused ? .white : .white.opacity(0.75))
        }
        .padding(.horizontal, 22)
        .frame(height: 64)
        .background(
            focused ? Color.white.opacity(0.16) : Color.white.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(focused ? Color.white.opacity(0.6) : Color.clear, lineWidth: 2)
        )
        .foregroundStyle(.white)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .scaleEffect(focused ? 1.02 : 1)
        .onTapGesture {
            onSelect()
        }
    }
}
