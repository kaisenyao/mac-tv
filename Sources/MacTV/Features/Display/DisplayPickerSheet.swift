import AppKit
import SwiftUI

/// The Display sheet, opened from Control Center's Display tile and built like Audio Output: Full Screen, Automatic and
/// each display (the same choices as before, see `controlCenterChoices(.display)`), then the Brightness slider.
struct DisplayPickerPanel: Equatable {
    var row = 0

    /// The display choices, in order. Tests swap it, so they have displays to choose from.
    @MainActor static var choices: (TVController) -> [ControlCenterPanel.Choice] = { $0.controlCenterChoices(.display) }
    /// Choosing one: Control Center's own (Full Screen switches in place; a display moves Mac TV there). Tests swap it,
    /// so they never move the window or change full screen.
    @MainActor static var choose: (TVController, ControlCenterPanel.Choice) -> Void = { $0.chooseControlCenter($1) }
}

extension TVController {
    var displayPickerChoices: [ControlCenterPanel.Choice] { DisplayPickerPanel.choices(self) }

    /// The Display sheet, over Control Center: focus on the choice in use, and the brightness read afresh.
    func openDisplayPicker() {
        let choices = displayPickerChoices
        displayPicker = DisplayPickerPanel(row: choices.firstIndex { controlCenterChoice($0).checked } ?? 0)
        refreshPickerBrightness()
    }

    /// The brightness of the display Mac TV is on now.
    func refreshPickerBrightness() {
        DisplayBrightness.shared.refresh(display: displayCoordinator.playbackScreen?.displayID)
    }

    func chooseDisplayPicker(_ choice: ControlCenterPanel.Choice) {
        DisplayPickerPanel.choose(self, choice)
    }

    func handleDisplayPicker(_ command: RemoteCommand) {
        guard var panel = displayPicker else { return }
        let choices = displayPickerChoices
        let brightnessRow = choices.count
        panel.row = min(panel.row, brightnessRow)

        switch command {
        case .back:
            displayPicker = nil   // back to Control Center, on the Display tile
            return
        case .move(.up):
            panel.row = max(0, panel.row - 1)
        case .move(.down):
            panel.row = min(brightnessRow, panel.row + 1)
        case .move(.left):
            if panel.row == brightnessRow { stepPickerBrightness(by: -5); return }
        case .move(.right):
            if panel.row == brightnessRow { stepPickerBrightness(by: 5); return }
        case .select:
            if choices.indices.contains(panel.row) {
                displayPicker = panel
                chooseDisplayPicker(choices[panel.row])
                return
            }
        default:
            break
        }
        displayPicker = panel
    }

    /// Left and Right on the Brightness slider: a step, live, and a tick so you hear it, as the Volume slider does.
    /// Nothing when there's no brightness to set.
    private func stepPickerBrightness(by delta: Int) {
        let brightness = DisplayBrightness.shared
        guard brightness.level != nil, !brightness.pending else { return }
        brightness.step(by: delta)
        feedback.play(.move, from: .keyboard)
    }
}

// MARK: - Display Sheet

struct DisplayPickerSheet: View {
    @ObservedObject var tv: TVController
    @Environment(\.canvasSize) private var canvas

    var body: some View {
        let panel = tv.displayPicker ?? DisplayPickerPanel()
        let choices = tv.displayPickerChoices
        let brightnessRow = choices.count

        VStack(alignment: .leading, spacing: 22) {
            // No Done button: Back closes it, as on Apple TV.
            Text("Display").font(.tv(.title3, emphasized: true))

            VStack(spacing: 12) {
                ForEach(Array(choices.enumerated()), id: \.element) { index, choice in
                    let content = tv.controlCenterChoice(choice)
                    let focused = (panel.row == index)
                    HStack(spacing: 18) {
                        Image(systemName: Self.symbol(choice))
                            .font(.system(size: 30, weight: .medium))
                            .frame(width: 40)

                        Text(content.title)
                            .font(.tv(.callout, emphasized: content.checked))
                            .lineLimit(1)

                        Spacer(minLength: 12)

                        if case .toggle(let on) = content.accessory {
                            SettingSwitch(on: on)
                        } else if content.checked {
                            Image(systemName: "checkmark")
                                .font(.system(size: 20, weight: .bold))
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
                        // A click focuses the row it chose, like the slider, so focus and the checkmark agree.
                        tv.displayPicker?.row = index
                        tv.chooseDisplayPicker(choice)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Brightness")
                    .font(.tv(.caption1, emphasized: true))
                    .foregroundStyle(.white.opacity(0.75))

                DisplayBrightnessSlider(focused: panel.row == brightnessRow) {
                    tv.displayPicker?.row = brightnessRow
                }
            }
        }
        .padding(52)
        .frame(width: 820, alignment: .leading)
        .tvPanel(in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .foregroundStyle(.white)
        .frame(width: canvas.width, height: canvas.height)
        .animation(Motion.focus, value: panel)
        // Mac TV moved to another display (a display chosen above): the slider shows that one's brightness.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification)) { note in
            if let window = tv.window, note.object as? NSWindow === window { tv.refreshPickerBrightness() }
        }
    }

    /// A choice's symbol: Full Screen as Control Center's round button, a Mac's own display as a laptop, others a TV.
    static func symbol(_ choice: ControlCenterPanel.Choice) -> String {
        switch choice {
        case .fullScreen: return "arrow.up.left.and.arrow.down.right"
        case .automaticDisplay: return "display.2"
        case .display(let id):
            let screen = NSScreen.screens.first { screen in
                CGDisplayCreateUUIDFromDisplayID(screen.displayID).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } == id
            }
            return screen.map { CGDisplayIsBuiltin($0.displayID) != 0 } == true ? "laptopcomputer" : "tv"
        default: return "display"
        }
    }
}

struct DisplayBrightnessSlider: View {
    @ObservedObject private var brightness = DisplayBrightness.shared
    let focused: Bool
    var onSelect: () -> Void = {}

    private var symbol: String {
        guard let level = brightness.level, !brightness.pending else { return "sun.max" }
        return level < 50 ? "sun.min.fill" : "sun.max.fill"
    }

    var body: some View {
        let pending = brightness.pending
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .medium))
                .frame(width: 36)
                .opacity(pending ? 0.5 : 1)
                .contentTransition(.symbolEffect(.replace))

            if pending || brightness.level != nil {
                let level = pending ? 0 : brightness.level ?? 0
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
                                brightness.set(AudioVolumeSlider.level(at: value.location.x, width: geo.size.width))
                            }
                    )
                }
                .frame(height: 36)

                Text(pending ? "" : "\(brightness.level ?? 0)%")
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
