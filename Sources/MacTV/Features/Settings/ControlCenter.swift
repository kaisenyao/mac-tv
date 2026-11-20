import SwiftUI

/// Apple TV's Control Center, under the status row at the top right: Sleep Now (TV standby), four tiles that open a
/// list or a sheet (Remotes, Display, Audio, Sleep Timer) and four round buttons (Screen Saver, Turn Off Display,
/// Lid Closed on a laptop or Keep Mac Awake on a desktop, and Settings). Opened from the status row's
/// Control Center button, or by holding the TV button, over whatever is in front.
struct ControlCenterPanel: Equatable {
    enum Item: CaseIterable {
        case sleepNow, remotes, display, audio, sleepTimer, screenSaver, screenOff, stayAwake, settings
    }

    /// A tile's list, shown in place of the tiles until Back: the display choices, or the sleep timer's.
    enum List: Equatable {
        case display, sleepTimer
    }

    /// One choice in a list.
    enum Choice: Hashable {
        case fullScreen, automaticDisplay, display(String), timer(Int), cancelTimer
    }

    var item: Item = .remotes
    var list: List?
    var listRow = 0
    /// Select or a click: the focused control dips and settles back each time this goes up.
    var presses = 0

    /// Where each direction goes from each item.
    static func neighbour(of item: Item, _ direction: RemoteCommand.Direction) -> Item? {
        switch (item, direction) {
        case (.sleepNow, .right): .remotes
        case (.sleepNow, .down): .audio
        case (.remotes, .left), (.display, .left), (.audio, .up): .sleepNow
        case (.remotes, .down): .display
        case (.display, .up): .remotes
        case (.display, .down), (.audio, .right): .sleepTimer
        case (.sleepTimer, .up): .display
        case (.sleepTimer, .left): .audio
        case (.audio, .down): .screenSaver
        case (.sleepTimer, .down): .stayAwake
        case (.screenSaver, .up), (.screenOff, .up): .audio
        case (.stayAwake, .up), (.settings, .up): .sleepTimer
        case (.screenSaver, .right), (.stayAwake, .left): .screenOff
        case (.screenOff, .left): .screenSaver
        case (.screenOff, .right), (.settings, .left): .stayAwake
        case (.stayAwake, .right): .settings
        default: nil
        }
    }
}

extension TVController {
    func openControlCenter() {
        controlCenter = ControlCenterPanel()
        remoteCoordinator.refreshRemoteStatus()
    }

    /// This Mac has a lid: the third round button is Lid Closed, otherwise Keep Mac Awake.
    var macHasLid: Bool { displayCoordinator.hasLid }

    func handleControlCenter(_ command: RemoteCommand) {
        guard var panel = controlCenter else { return }
        if let list = panel.list {
            let choices = controlCenterChoices(list)
            panel.listRow = min(panel.listRow, choices.count - 1)
            switch command {
            case .back: panel.list = nil   // back to the tiles, on the tile it came from
            case .move(.up): panel.listRow = max(0, panel.listRow - 1)
            case .move(.down): panel.listRow = min(choices.count - 1, panel.listRow + 1)
            case .select:
                panel.presses += 1
                controlCenter = panel
                chooseControlCenter(choices[panel.listRow])
                return
            default: break
            }
            controlCenter = panel
            return
        }
        switch command {
        case .back:
            controlCenter = nil
            return
        case .move(let direction):
            // 和 Apple TV 一样：走到边上就停住，不会把控制中心关掉（遥控器一滑容易冲过头）。按返回才关
            if let next = ControlCenterPanel.neighbour(of: panel.item, direction) {
                panel.item = next
            }
        case .select:
            controlCenter = panel
            activateControl(panel.item)
            return
        default:
            break
        }
        controlCenter = panel
    }

    /// Select or a click. Sheets opened from here (Connect a Remote, Audio, Settings) open over Control Center, so
    /// Back comes back to it, on the control that opened them.
    func activateControl(_ item: ControlCenterPanel.Item) {
        controlCenter?.item = item
        controlCenter?.presses += 1
        switch item {
        case .sleepNow, .screenOff:
            // TV standby, at once: any wake button undoes it, and the Mac stays awake (see Standby)
            controlCenter = nil
            enterStandby(reason: item == .sleepNow ? "Sleep Now" : "Turn Off Display")
        case .remotes: pairing = true
        case .display: openControlCenterList(.display)
        case .audio: openAudioPicker()
        case .sleepTimer: openControlCenterList(.sleepTimer)
        case .screenSaver:
            controlCenter = nil
            showScreensaver()
        case .stayAwake: if macHasLid { lidOverride.toggle() } else { keepMacAwake.toggle() }
        case .settings: openSettings()
        }
    }

    private func openControlCenterList(_ list: ControlCenterPanel.List) {
        let choices = controlCenterChoices(list)
        controlCenter?.list = list
        // Focus starts on the choice in use.
        controlCenter?.listRow = choices.firstIndex { controlCenterChoice($0).checked } ?? 0
    }

    /// A list's choices, in order.
    func controlCenterChoices(_ list: ControlCenterPanel.List) -> [ControlCenterPanel.Choice] {
        switch list {
        case .display:
            return [.fullScreen, .automaticDisplay] + availableTVDisplays.map { .display($0.id) }
        case .sleepTimer:
            let steps = Self.sleepTimerSteps.filter { $0 > 0 }.map(ControlCenterPanel.Choice.timer)
            return (sleepMinutesLeft > 0 ? [.cancelTimer] : [.timer(0)]) + steps
        }
    }

    /// How a choice shows: the same row as Settings.
    func controlCenterChoice(_ choice: ControlCenterPanel.Choice) -> SettingsRowContent {
        let preferred = preferences.preferredTVDisplay
        switch choice {
        case .fullScreen: return SettingsRowContent(title: "Full Screen", accessory: .toggle(dedicatedTVMode))
        case .automaticDisplay: return SettingsRowContent(title: "Automatic", checked: preferred == nil)
        case .display(let id):
            let name = availableTVDisplays.first { $0.id == id }?.name ?? "Display"
            return SettingsRowContent(title: name, checked: preferred == id)
        case .timer(0): return SettingsRowContent(title: "Off", checked: sleepMinutesLeft == 0)
        case .timer(let minutes): return SettingsRowContent(title: "\(minutes) Minutes")
        case .cancelTimer:
            let left = sleepMinutesLeft
            return SettingsRowContent(title: "Cancel Timer", value: "\(left) Minute\(left == 1 ? "" : "s") Left")
        }
    }

    /// Choosing in a list: Full Screen switches in place; anything else takes effect and goes back to the tiles.
    func chooseControlCenter(_ choice: ControlCenterPanel.Choice) {
        switch choice {
        case .fullScreen:
            setDedicatedTVMode(!dedicatedTVMode)
            return
        case .automaticDisplay: chooseTVDisplay(nil)
        case .display(let id): chooseTVDisplay(id)
        case .timer(let minutes): setSleepTimer(minutes: minutes)
        case .cancelTimer: setSleepTimer(minutes: 0)
        }
        controlCenter?.list = nil
    }

    /// What the Remotes tile shows: what's connected, Apple style ("Siri Remote · 87%, iPhone"), and a symbol
    /// for it: the remote's, unless the only thing connected is a game controller or a phone.
    var remotesSummary: (text: String, symbol: String, connected: Bool) {
        let siri = SiriRemoteStatus.shared.connected
        let phone = remoteCoordinator.pairingStore.connectedCount() > 0
        let battery = remoteCoordinator.siriRemoteBattery.map { " · \($0)%" } ?? ""
        let pad = controller.map { "Game Controller" + ($0.percent.map { " · \($0)%" } ?? "") }
        let parts = [siri ? "Siri Remote" + battery : nil, phone ? "iPhone" : nil, pad].compactMap { $0 }
        let symbol = !siri && !phone && pad != nil ? "gamecontroller.fill"
            : !siri && phone && pad == nil ? "iphone" : "appletvremote.gen4.fill"
        return (parts.isEmpty ? "Not Connected" : parts.joined(separator: ", "), symbol, !parts.isEmpty)
    }
}

// MARK: Views

/// Drawn at Apple TV's own sizes at 1080p: tiles about 206 points wide and 95 tall, Sleep Now as tall as two, round
/// buttons as wide as a tile is tall, and Apple's tile text: 24-point titles, 22-point details.
struct ControlCenterView: View {
    @ObservedObject var tv: TVController
    @ObservedObject private var siriRemote = SiriRemoteStatus.shared
    @Environment(\.canvasSize) private var canvas
    @Namespace private var focusSpace
    private static let column: CGFloat = 206
    private static let row: CGFloat = 95
    private static let gap: CGFloat = 17
    private static let width = column * 2 + gap
    /// The blue of a connected remote or the sound output, as on Apple TV.
    private static let tint = Color(hex: "#5AC8FA")

    var body: some View {
        let panel = tv.controlCenter ?? ControlCenterPanel()
        VStack(alignment: .trailing, spacing: 0) {
            if let list = panel.list {
                listPanel(list, panel)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            } else {
                GlassGroup(spacing: 0) { grid(panel) }
                    .transition(.opacity)
                Text(caption(panel))
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.4), radius: 5, y: 1)
                    .frame(width: Self.width, alignment: .center)
                    .padding(.top, 60)
                    .contentTransition(.opacity)
            }
        }
        .foregroundStyle(.white)
        // Just under the home screen's status row, which stays in place above it.
        .padding(.top, 124)
        .padding(.trailing, 80)
        .frame(width: canvas.width, height: canvas.height, alignment: .topTrailing)
        .animation(Motion.focus, value: panel)
        .onReceive(siriRemote.$connected.dropFirst()) { _ in tv.remoteCoordinator.refreshRemoteStatus() }
    }

    private func grid(_ panel: ControlCenterPanel) -> some View {
        let remotes = tv.remotesSummary
        let minutes = tv.sleepMinutesLeft
        let lid = tv.macHasLid
        return VStack(spacing: Self.gap) {
            HStack(alignment: .top, spacing: Self.gap) {
                sleepTile(panel)
                VStack(spacing: Self.gap) {
                    tile(.remotes, panel, symbol: remotes.symbol, title: "Remotes", detail: remotes.text, tinted: remotes.connected)
                    tile(.display, panel, symbol: "display", title: "Display",
                         detail: tv.displaySummary ?? "")
                }
            }
            HStack(spacing: Self.gap) {
                tile(.audio, panel, symbol: tv.currentAudioDevice?.symbol ?? "hifispeaker.fill", title: "Audio",
                     detail: tv.currentAudioDevice?.name ?? "Speakers", tinted: true)
                tile(.sleepTimer, panel, symbol: "timer", title: "Sleep Timer",
                     detail: minutes > 0 ? "\(minutes) Minute\(minutes == 1 ? "" : "s") Left" : "Off")
            }
            HStack(spacing: 0) {
                round(.screenSaver, panel, symbol: "sparkles.tv")
                Spacer(minLength: 0)
                round(.screenOff, panel, symbol: "tv.slash")
                Spacer(minLength: 0)
                round(.stayAwake, panel, symbol: lid ? "laptopcomputer" : "cup.and.saucer.fill",
                      on: lid ? tv.lidOverride : tv.keepMacAwake)
                Spacer(minLength: 0)
                round(.settings, panel, symbol: "gearshape.fill")
            }
            .frame(width: Self.width)
            .padding(.top, 4)
        }
    }

    /// What the focused round button does, under the cluster, since those buttons have no label.
    private func caption(_ panel: ControlCenterPanel) -> String {
        switch panel.item {
        case .screenSaver: "Screen Saver"
        case .screenOff: "Turn Off Display"
        case .stayAwake where tv.macHasLid: tv.lidOverride ? "Lid Closed: Stay Awake" : "Lid Closed: Sleep"
        case .stayAwake: tv.keepMacAwake ? "Keep Mac Awake: On" : "Keep Mac Awake: Off"
        case .settings: "Settings"
        default: " "
        }
    }

    private func sleepTile(_ panel: ControlCenterPanel) -> some View {
        let focused = panel.item == .sleepNow
        let shape = RoundedRectangle(cornerRadius: 32, style: .continuous)
        return Button { tv.activateControl(.sleepNow) } label: {
            VStack(spacing: 10) {
                Image(systemName: "power").font(.system(size: 76, weight: .regular))
                Text("Sleep Now").font(.system(size: 22, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
            .foregroundStyle(focused ? .black : .white)
            .frame(width: Self.column, height: Self.row * 2 + Self.gap)
            .focusPlatter(shape, focused: focused, color: .white)
            .contentShape(shape)
            .lifted(focused, in: shape)
        }
        .buttonStyle(PressDip(presses: panel.presses, focused: focused))
    }

    private func tile(_ item: ControlCenterPanel.Item, _ panel: ControlCenterPanel, symbol: String,
                      title: String, detail: String, tinted: Bool = false) -> some View {
        let focused = panel.item == item
        return Button { tv.activateControl(item) } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 28, weight: .medium))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(focused ? Color.black : tinted ? Self.tint : .white)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 24, weight: .semibold))
                        .minimumScaleFactor(0.85)
                    Text(detail).font(.system(size: 22, weight: .medium)).opacity(0.62)
                        .minimumScaleFactor(0.75)   // "Game Controller · 70%" still fits
                        .contentTransition(detail.first?.isNumber == true ? .numericText() : .opacity)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .foregroundStyle(focused ? .black : .white)
            .frame(width: Self.column, height: Self.row)
            .focusPlatter(Capsule(), focused: focused)
            .contentShape(Capsule())
            .lifted(focused, in: Capsule())
        }
        .buttonStyle(PressDip(presses: panel.presses, focused: focused))
    }

    /// A round button. One that's switched on is white, as Apple TV's are; focus lifts it.
    private func round(_ item: ControlCenterPanel.Item, _ panel: ControlCenterPanel, symbol: String, on: Bool = false) -> some View {
        let focused = panel.item == item
        return Button { tv.activateControl(item) } label: {
            Image(systemName: symbol)
                .font(.system(size: 36, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(focused || on ? .black : .white)
                .frame(width: Self.row, height: Self.row)
                .background { if on, !focused { Circle().fill(.white.opacity(0.92)) } }
                .focusPlatter(Circle(), focused: focused)
                .contentShape(Circle())
                .lifted(focused, in: Circle())
        }
        .buttonStyle(PressDip(presses: panel.presses, focused: focused))
    }

    /// A tile's list in place of the tiles, as tvOS opens one: its choices in Settings' rows. Back returns.
    private func listPanel(_ list: ControlCenterPanel.List, _ panel: ControlCenterPanel) -> some View {
        let choices = tv.controlCenterChoices(list)
        return VStack(alignment: .leading, spacing: 10) {
            Text(list == .display ? "Display" : "Sleep Timer")
                .font(.system(size: 23, weight: .semibold))
                .padding(.leading, 6).padding(.bottom, 4)
            ForEach(Array(choices.enumerated()), id: \.element) { index, choice in
                SettingsRow(content: tv.controlCenterChoice(choice), focused: index == panel.listRow, presses: panel.presses,
                            compact: true, focusSpace: focusSpace) {
                    tv.controlCenter?.listRow = index
                    tv.chooseControlCenter(choice)
                }
                .equatable()
            }
        }
        .padding(18)
        .frame(width: Self.width)
        .tvGlass(in: RoundedRectangle(cornerRadius: 32, style: .continuous))
    }
}

private extension View {
    /// Control Center's focus: the focused control lifts and casts a shadow, as everywhere else on the TV. The
    /// shadow is the platter's alone, not cast by the text and symbol on it.
    func lifted<S: Shape>(_ focused: Bool, in shape: S) -> some View {
        background { shape.fill(.white).opacity(focused ? 1 : 0).shadow(color: .black.opacity(0.4), radius: 16, y: 12) }
            .scaleEffect(focused ? 1.06 : 1)
    }
}
