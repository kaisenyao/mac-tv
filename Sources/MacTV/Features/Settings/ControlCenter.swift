import SwiftUI

/// Apple TV's Control Center, under the status row at the top right: Sleep Now (TV standby), four tiles that open a
/// list or a sheet (Remotes, Display, Audio, Sleep Timer) and round buttons, four to a row: the person's own choice and
/// order, changed with Edit under them, as an iPhone's Control Center is. Opened from the status row's Control Center
/// button, or by holding the TV button, over whatever is in front, which dims (see DesignSystem/Layers).
struct ControlCenterPanel: Equatable {
    enum Item: String, CaseIterable {
        case sleepNow, remotes, display, audio, sleepTimer
        /// The round buttons.
        case jasmine, screenOff, screenSaver, mute, playPause, search, appSwitcher, settings
        case stayAwake, profiles, arrangeApps, store, fullScreen, userGuide
        /// The capsule under the round buttons: Edit, and Done while editing.
        case edit, done

        /// What can be a round button, and the ones Control Center starts with.
        static let controls: [Item] = standardControls + [.stayAwake, .profiles, .arrangeApps, .store, .fullScreen, .userGuide]
        static let standardControls: [Item] = [.jasmine, .screenOff, .screenSaver, .mute, .playPause, .search, .appSwitcher, .settings]
        static let perRow = 4
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
    /// Edit: the round buttons can be moved, removed and added; the tiles rest.
    var editing = false
    /// Editing: the round button picked up, moving with the arrows until Select puts it down.
    var lifted: Item?

    /// Where each direction goes from each item. `controls` are the round buttons shown, in order; while editing,
    /// `available` are the ones that can be added, under them, and the tiles aren't reachable.
    static func neighbour(of item: Item, _ direction: RemoteCommand.Direction, controls: [Item], available: [Item] = [],
                          editing: Bool = false) -> Item? {
        let rows = Item.perRow
        // A place in a group laid out four to a row: where an arrow goes inside it, nil past its edge.
        func step(_ index: Int, _ direction: RemoteCommand.Direction, count: Int) -> Int? {
            switch direction {
            case .left: return index % rows > 0 ? index - 1 : nil
            case .right: return index % rows < rows - 1 && index + 1 < count ? index + 1 : nil
            case .up: return index >= rows ? index - rows : nil
            case .down:
                if index + rows < count { return index + rows }
                return (index / rows + 1) * rows < count ? count - 1 : nil
            }
        }
        if let index = controls.firstIndex(of: item) {
            if let next = step(index, direction, count: controls.count) { return controls[next] }
            switch direction {
            case .up where !editing: return index % rows < 2 ? .audio : .sleepTimer
            case .down: return editing ? available.first ?? .done : .edit
            default: return nil
            }
        }
        if editing, let index = available.firstIndex(of: item) {
            if let next = step(index, direction, count: available.count) { return available[next] }
            switch direction {
            case .up: return controls.last
            case .down: return .done
            default: return nil
            }
        }
        switch (item, direction) {
        case (.edit, .up): return controls.last ?? .sleepTimer
        case (.done, .up): return available.last ?? controls.last
        case (.sleepNow, .right): return .remotes
        case (.sleepNow, .down): return .audio
        case (.remotes, .left), (.display, .left), (.audio, .up): return .sleepNow
        case (.remotes, .down): return .display
        case (.display, .up): return .remotes
        case (.display, .down), (.audio, .right): return .sleepTimer
        case (.sleepTimer, .up): return .display
        case (.sleepTimer, .left): return .audio
        case (.audio, .down): return controls.first ?? .edit
        case (.sleepTimer, .down): return controls.count > 2 ? controls[2] : controls.last ?? .edit
        default: return nil
        }
    }
}

extension TVController {
    func openControlCenter() {
        controlCenter = ControlCenterPanel()
        remoteCoordinator.refreshRemoteStatus()
    }

    /// This Mac has a lid: the Lid Closed round button, otherwise Keep Mac Awake.
    var macHasLid: Bool { displayCoordinator.hasLid }

    /// The round buttons this person has, in their order (Edit changes them).
    var controlCenterControls: [ControlCenterPanel.Item] {
        get {
            preferences.controlCenterControls.map { $0.compactMap(ControlCenterPanel.Item.init(rawValue:))
                .filter(ControlCenterPanel.Item.controls.contains) } ?? ControlCenterPanel.Item.standardControls
        }
        set { preferences.controlCenterControls = newValue.map(\.rawValue) }
    }

    /// The round buttons that could be added, in the order Edit lists them.
    var controlCenterAvailable: [ControlCenterPanel.Item] {
        let shown = Set(controlCenterControls)
        return ControlCenterPanel.Item.controls.filter { !shown.contains($0) }
    }

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
        if panel.editing { return handleControlCenterEditing(command, panel) }
        switch command {
        case .back:
            controlCenter = nil
            return
        case .move(let direction):
            // 和 Apple TV 一样：走到边上就停住，不会把控制中心关掉（遥控器一滑容易冲过头）。按返回才关
            if let next = ControlCenterPanel.neighbour(of: panel.item, direction, controls: controlCenterControls) {
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

    /// Edit, as an iPhone's Control Center and as Arrange Apps: Select picks a round button up, the arrows move it and
    /// Select puts it down; press and hold Select takes it out; Select on one under Add a Control puts it in, last.
    /// Back (or Done) finishes; with a button picked up, Back puts it down first.
    private func handleControlCenterEditing(_ command: RemoteCommand, _ start: ControlCenterPanel) {
        var panel = start
        var controls = controlCenterControls
        switch command {
        case .back:
            if panel.lifted != nil { panel.lifted = nil } else { finishControlCenterEdit(&panel) }
        case .move(let direction):
            if let lifted = panel.lifted, let index = controls.firstIndex(of: lifted) {
                let rows = ControlCenterPanel.Item.perRow
                let target: Int? = switch direction {
                case .left: index % rows > 0 ? index - 1 : nil
                case .right: index % rows < rows - 1 && index + 1 < controls.count ? index + 1 : nil
                case .up: index >= rows ? index - rows : nil
                case .down: index + rows < controls.count ? index + rows : (index / rows + 1) * rows < controls.count ? controls.count - 1 : nil
                }
                if let target {
                    controls.remove(at: index)
                    controls.insert(lifted, at: target)
                    controlCenterControls = controls
                }
            } else if let next = ControlCenterPanel.neighbour(of: panel.item, direction, controls: controls,
                                                              available: controlCenterAvailable, editing: true) {
                panel.item = next
            }
        case .select:
            panel.presses += 1
            if panel.item == .done {
                finishControlCenterEdit(&panel)
            } else if controls.contains(panel.item) {
                panel.lifted = panel.lifted == panel.item ? nil : panel.item
            } else if ControlCenterPanel.Item.controls.contains(panel.item) {
                controlCenter = panel
                addControlCenterControl(panel.item)   // added last; focus stays on it, now among the buttons
                return
            }
        default:
            break
        }
        controlCenter = panel
    }

    private func finishControlCenterEdit(_ panel: inout ControlCenterPanel) {
        panel.editing = false
        panel.lifted = nil
        panel.item = .edit
    }

    /// Editing Control Center: a round button comes out, to Add a Control: the focused one when Select is held, or the
    /// one whose "−" was clicked.
    func removeControlCenterControl(_ chosen: ControlCenterPanel.Item? = nil) -> Bool {
        guard var panel = controlCenter, panel.editing, panel.list == nil else { return false }
        let item = chosen ?? panel.item
        var controls = controlCenterControls
        guard let index = controls.firstIndex(of: item) else { return false }
        controls.remove(at: index)
        controlCenterControls = controls
        if panel.lifted == item { panel.lifted = nil }
        panel.presses += 1
        // Focus goes to the button that took its place, or the last one; with none left, to what it became.
        if panel.item == item { panel.item = controls.isEmpty ? item : controls[min(index, controls.count - 1)] }
        controlCenter = panel
        return true
    }

    /// Editing Control Center: a round button from Add a Control goes in, last, with focus on it.
    func addControlCenterControl(_ item: ControlCenterPanel.Item) {
        guard var panel = controlCenter, panel.editing, ControlCenterPanel.Item.controls.contains(item),
              !controlCenterControls.contains(item) else { return }
        controlCenterControls.append(item)
        panel.item = item
        panel.presses += 1
        controlCenter = panel
    }

    /// Select or a click. Sheets opened from here (Connect a Remote, Audio, Settings, Arrange Apps, Store) open over
    /// Control Center, so Back comes back to it, on the control that opened them.
    func activateControl(_ item: ControlCenterPanel.Item) {
        controlCenter?.item = item
        controlCenter?.presses += 1
        switch item {
        case .sleepNow, .screenOff:
            // TV standby, at once: any wake button undoes it, and the Mac stays awake (see Standby)
            controlCenter = nil
            enterStandby(reason: item == .sleepNow ? "Sleep Now" : "Turn Off Display")
        case .remotes: pairing = true
        case .display: openDisplayPicker()
        case .audio: openAudioPicker()
        case .sleepTimer: openControlCenterList(.sleepTimer)
        case .screenSaver:
            controlCenter = nil
            showScreensaver()
        case .stayAwake: if macHasLid { lidOverride.toggle() } else { keepMacAwake.toggle() }
        case .settings: openSettings()
        case .search:
            controlCenter = nil
            openSystemSearch()
        case .profiles:
            controlCenter = nil
            openProfiles()
        case .arrangeApps: openOrganizer()
        case .store: adder = AppAdder()
        case .jasmine:
            controlCenter = nil
            jasmine.summon()
        case .mute: audioCoordinator.toggleMute()
        case .playPause: toggleBackgroundAudio()
        case .appSwitcher:
            controlCenter = nil
            if backgroundApps.isEmpty { nudgeHome(.nothingInBackground) } else { openAppSwitcher(returningTo: appInFront?.id) }
        case .fullScreen: setDedicatedTVMode(!dedicatedTVMode)
        case .userGuide: openSettings(to: .userGuide)
        case .edit:
            controlCenter?.editing = true
            controlCenter?.item = controlCenterControls.first ?? controlCenterAvailable.first ?? .done
        case .done:
            if var panel = controlCenter { finishControlCenterEdit(&panel); controlCenter = panel }
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
/// buttons as wide as a tile is tall, and Apple's tile text: 20-point titles and details, medium.
struct ControlCenterView: View {
    @ObservedObject var tv: TVController
    @ObservedObject private var siriRemote = SiriRemoteStatus.shared
    @Environment(\.canvasSize) private var canvas
    @Namespace private var focusSpace
    private static let column: CGFloat = 206
    private static let row: CGFloat = 95
    private static let gap: CGFloat = 17
    private static let width = column * 2 + gap
    /// The box every round button's symbol is fitted to.
    private static let glyph = CGSize(width: 40, height: 36)
    /// The box every tile's symbol is fitted to: as tall as Apple TV's beside 20-point text.
    private static let tileGlyph = CGSize(width: 36, height: 32)
    private static let speakerGlyph = CGSize(width: 44, height: 32)
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
                    .padding(.top, 16)
                    .contentTransition(.opacity)
                if panel.editing { addSection(panel) }
                capsule(panel.editing ? .done : .edit, panel)
                    .frame(width: Self.width)
                    .padding(.top, panel.editing ? 26 : 12)   // close under the buttons; under Add a Control while editing
            }
        }
        .foregroundStyle(.white)
        // Just under the home screen's status row, which stays in place above it: far enough below that a focused
        // tile, grown, never reaches the row; its right edge on the row's.
        .padding(.top, TopBar.top + TopBar.height + 18)
        .padding(.trailing, TopBar.trailing)
        .frame(width: canvas.width, height: canvas.height, alignment: .topTrailing)
        .animation(Motion.focus, value: panel)
        .onReceive(siriRemote.$connected.dropFirst()) { _ in tv.remoteCoordinator.refreshRemoteStatus() }
    }

    private func grid(_ panel: ControlCenterPanel) -> some View {
        let remotes = tv.remotesSummary
        let minutes = tv.sleepMinutesLeft
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
                // Speakers: the speaker that shows the volume (as the volume indicator's); headphones, a TV, AirPlay: theirs
                tile(.audio, panel, symbol: tv.currentAudioDevice?.symbol ?? AudioOutputDevice.speakerSymbol, title: "Audio",
                     detail: tv.currentAudioDevice?.name ?? "Speakers", tinted: true)
                tile(.sleepTimer, panel, symbol: "timer", title: "Sleep Timer",
                     detail: minutes > 0 ? "\(minutes) Minute\(minutes == 1 ? "" : "s") Left" : "Off")
            }
            .opacity(panel.editing ? 0.35 : 1)   // editing: the tiles rest, only the round buttons move
            .allowsHitTesting(!panel.editing)
            rounds(tv.controlCenterControls, panel, adding: false)
                .padding(.top, 4)
        }
        .animation(Motion.focus, value: tv.controlCenterControls)
    }

    /// Round buttons four to a row, each placed by its place in the order, as Arrange Apps places apps: one moving
    /// glides there and the others make room, instead of the rows being laid out again.
    private func rounds(_ items: [ControlCenterPanel.Item], _ panel: ControlCenterPanel, adding: Bool) -> some View {
        let perRow = ControlCenterPanel.Item.perRow
        let spacing = (Self.width - CGFloat(perRow) * Self.row) / CGFloat(perRow - 1)
        let rowCount = (items.count + perRow - 1) / perRow
        let height = rowCount == 0 ? 0 : CGFloat(rowCount) * Self.row + CGFloat(rowCount - 1) * Self.gap
        return ZStack(alignment: .topLeading) {
            ForEach(Array(items.enumerated()), id: \.element) { index, item in
                round(item, panel, adding: adding)
                    .position(x: CGFloat(index % perRow) * (Self.row + spacing) + Self.row / 2,
                              y: CGFloat(index / perRow) * (Self.row + Self.gap) + Self.row / 2)
                    .zIndex(panel.lifted == item ? 3 : panel.item == item ? 2 : 1)
            }
        }
        .frame(width: Self.width, height: height, alignment: .topLeading)
    }

    /// Editing: the round buttons that could be added, under a heading.
    private func addSection(_ panel: ControlCenterPanel) -> some View {
        let available = tv.controlCenterAvailable
        return VStack(alignment: .leading, spacing: 14) {
            if !available.isEmpty {
                Text("Add a Control")
                    .font(.system(size: 21, weight: .semibold))
                    .opacity(0.6)
                    .padding(.leading, 6)
                rounds(available, panel, adding: true)
            }
        }
        .frame(width: Self.width, alignment: .leading)
        .padding(.top, 30)
        .transition(.opacity)
    }

    /// Edit under the round buttons; Done while editing. A small capsule, as on an iPhone's Control Center.
    private func capsule(_ item: ControlCenterPanel.Item, _ panel: ControlCenterPanel) -> some View {
        let focused = panel.item == item
        return Button { tv.activateControl(item) } label: {
            Text(item == .done ? "Done" : "Edit")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(focused ? .black : .white)
                .padding(.horizontal, 26)
                .frame(height: 46)
                .focusPlatter(Capsule(), focused: focused)
                .contentShape(Capsule())
                .lifted(focused, in: Capsule())
        }
        .buttonStyle(PressDip(presses: panel.presses, focused: focused))
    }

    /// What the focused round button does, under the cluster, since those buttons have no label.
    private func caption(_ panel: ControlCenterPanel) -> String {
        switch panel.item {
        case .screenSaver: "Screen Saver"
        case .screenOff: "Turn Off Display"
        case .stayAwake where tv.macHasLid: tv.lidOverride ? "Lid Closed: Stay Awake" : "Lid Closed: Sleep"
        case .stayAwake: tv.keepMacAwake ? "Keep Mac Awake: On" : "Keep Mac Awake: Off"
        case .settings: "Settings"
        case .search: "Search"
        case .profiles: "Profiles"
        case .arrangeApps: "Arrange Apps"
        case .store: "Store"
        case .jasmine: "Jasmine"
        case .mute: tv.audioCoordinator.currentVolume.muted ? "Muted" : "Mute"
        case .playPause: "Play/Pause"
        case .appSwitcher: "App Switcher"
        case .fullScreen: tv.dedicatedTVMode ? "Full Screen: On" : "Full Screen: Off"
        case .userGuide: "User Guide"
        default: " "
        }
    }

    /// A round button's symbol, and whether it's switched on.
    private func look(_ item: ControlCenterPanel.Item) -> (symbol: String, on: Bool) {
        let lid = tv.macHasLid
        switch item {
        case .screenSaver: return ("sparkles.tv", false)
        case .screenOff: return ("tv.slash", false)
        case .stayAwake: return (lid ? "laptopcomputer" : "cup.and.saucer.fill", lid ? tv.lidOverride : tv.keepMacAwake)
        case .settings: return ("gearshape.fill", false)
        case .search: return ("magnifyingglass", false)
        case .profiles: return ("person.2.fill", false)
        case .arrangeApps: return ("square.grid.3x3.fill", false)
        case .store: return ("bag.fill", false)
        case .jasmine: return ("waveform", false)
        case .mute: return (tv.audioCoordinator.currentVolume.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                            tv.audioCoordinator.currentVolume.muted)
        case .playPause: return ("playpause.fill", false)
        case .appSwitcher: return ("square.stack.3d.up.fill", false)
        case .fullScreen: return ("arrow.up.left.and.arrow.down.right", tv.dedicatedTVMode)
        case .userGuide: return ("book.fill", false)
        default: return ("circle", false)
        }
    }

    private func sleepTile(_ panel: ControlCenterPanel) -> some View {
        let focused = panel.item == .sleepNow
        let shape = RoundedRectangle(cornerRadius: 32, style: .continuous)
        return Button { tv.activateControl(.sleepNow) } label: {
            VStack(spacing: 16) {
                Image(systemName: "power").font(.system(size: 88, weight: .light))
                Text("Sleep Now").font(.system(size: 20, weight: .medium))
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
            // As Apple TV's: the symbol well in from the edge with room before the text, the title and its detail the
            // same size and weight (the detail only dimmer), smaller than the tile so it breathes.
            HStack(spacing: 12) {
                // Every tile's symbol fitted to the same box, so a tall remote and a wide display look the same size
                Group {
                    if symbol == AudioOutputDevice.speakerSymbol {
                        // The speaker with its three waves is wide: a wider box (running into the gap before the text)
                        // makes it look as big as the other tiles' symbols
                        VolumeSpeaker(audio: tv.audioCoordinator, box: Self.speakerGlyph, weight: .regular)
                            .frame(width: Self.tileGlyph.width, alignment: .leading)
                    } else {
                        Image(systemName: symbol)
                            .resizable()
                            .fontWeight(.regular)
                            .scaledToFit()
                            .frame(width: Self.tileGlyph.width, height: Self.tileGlyph.height)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .foregroundStyle(focused ? Color.black : tinted ? Self.tint : .white)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 20, weight: .medium))
                        .minimumScaleFactor(0.85)
                    Text(detail).font(.system(size: 20, weight: .medium)).opacity(0.6)
                        .minimumScaleFactor(0.75)   // "Game Controller · 70%" still fits
                        .contentTransition(detail.first?.isNumber == true ? .numericText() : .opacity)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 18)
            .padding(.trailing, 10)
            .foregroundStyle(focused ? .black : .white)
            .frame(width: Self.column, height: Self.row)
            .focusPlatter(Capsule(), focused: focused)
            .contentShape(Capsule())
            .lifted(focused, in: Capsule())
        }
        .buttonStyle(PressDip(presses: panel.presses, focused: focused))
    }

    /// A round button. One that's switched on is white, as Apple TV's are; focus lifts it. Editing, as Arrange Apps:
    /// the one picked up lifts further and wiggles while it moves; each wears a badge above everything, "−" to take it
    /// out, "+" to add it (with the remote: hold Select to take one out, Select to add one).
    private func round(_ item: ControlCenterPanel.Item, _ panel: ControlCenterPanel, adding: Bool) -> some View {
        let focused = panel.item == item
        let lifted = panel.lifted == item
        let look = look(item)
        let on = look.on && !panel.editing
        return Button {
            if panel.editing {
                tv.controlCenter?.item = item
                tv.handleControlCenter(.select)
            } else {
                tv.activateControl(item)
            }
        } label: {
            // Every symbol fitted to one box, so a wide one (Play/Pause, Mute, the screens) is no bigger than a square
            // or round one (Settings, Search): the same size to the eye.
            Group {
                if item == .mute {
                    VolumeSpeaker(audio: tv.audioCoordinator, box: CGSize(width: 48, height: 36))   // the waves follow the volume
                } else {
                    Image(systemName: look.symbol)
                        .resizable()
                        .fontWeight(.medium)
                        .scaledToFit()
                        .frame(maxWidth: Self.glyph.width, maxHeight: Self.glyph.height)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
                .foregroundStyle(focused || on ? .black : .white)
                .frame(width: Self.row, height: Self.row)
                .background { if on, !focused { Circle().fill(.white.opacity(0.92)) } }
                .focusPlatter(Circle(), focused: focused)
                .contentShape(Circle())
                .lifted(focused, in: Circle())
        }
        .buttonStyle(PressDip(presses: panel.presses, focused: focused))
        .overlay(alignment: .topLeading) {
            if panel.editing { badge(item, adding: adding) }
        }
        .scaleEffect(lifted ? 1.1 : 1)
        .tvShadow(.lift, active: lifted)
        .modifier(Wiggle(active: lifted))
    }

    /// Editing: "−" takes a round button out, "+" puts one in. Dark, so it shows on a white focused button too, and
    /// outside the button's edge even when it's lifted.
    private func badge(_ item: ControlCenterPanel.Item, adding: Bool) -> some View {
        Button {
            if adding { tv.addControlCenterControl(item) } else { _ = tv.removeControlCenterControl(item) }
        } label: {
            Image(systemName: adding ? "plus" : "minus")
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color(hex: "#48484A"), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .offset(x: -10, y: -10)
        .transition(.scale.combined(with: .opacity))
    }

    /// A tile's list in place of the tiles, as tvOS opens one: its choices in Settings' rows. Back returns.
    private func listPanel(_ list: ControlCenterPanel.List, _ panel: ControlCenterPanel) -> some View {
        let choices = tv.controlCenterChoices(list)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Sleep Timer")   // Display opens its own sheet (DisplayPickerSheet)
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
