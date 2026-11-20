import SwiftUI

/// The first-run setup: a welcome, choosing the home screen's apps and connecting remotes.
/// Shown once on a new install, driven by the D-pad, the keyboard or the mouse.
struct SetupFlow: Equatable {
    enum Step: Int, CaseIterable {
        case welcome, apps, remote
    }

    var step: Step = .welcome
    /// In the apps step: the focused app, or the Continue button when it's past the last app.
    var index = 0
    /// The remote step: Connect a Remote's pages, with the choice of what to connect (iPhone, Siri Remote, a game
    /// controller) and Set Up Later. Each choice opens its own pairing page; Back returns to the choice.
    var connect = SettingsPanel(section: .remotes, open: true, connectRemote: true, inSetup: true)
    /// The steps this run shows, in order.
    var steps: [Step] { Step.allCases }

    static let columns = 5
}

extension TVController {
    /// A new install: nothing paired, no apps added or removed, and setup never finished.
    var needsSetup: Bool {
        !UserDefaults.standard.bool(forKey: "setupDone") && !phonePaired && !library.hasSavedApps
    }

    /// The built-in apps setup offers, in home-screen order.
    var setupChoices: [Service] {
        Catalog.services.filter { $0.kind != .addApp && $0.kind != .settings && $0.isAvailable }
    }

    func startSetup() {
        setup = SetupFlow()
    }

    func finishSetup() {
        guard setup != nil else { return }
        UserDefaults.standard.set(true, forKey: "setupDone")
        setup = nil
        setFocus(.app(0))
        showStartupPairingIfReady()
    }

    func handleSetup(_ command: RemoteCommand) {
        guard var flow = setup else { return }
        // Connecting remotes: Connect a Remote's own pages (see `pages`).
        if flow.step == .remote {
            handleSettings(command)
            return
        }
        switch command {
        case .back:
            setupBack()
            return
        case .select:
            setup = flow
            activateSetup(flow.step == .apps ? flow.index : 0)
            return
        case .move(let direction) where flow.step == .apps:
            flow.index = movedSetupFocus(from: flow.index, direction)
        default:
            break
        }
        setup = flow
    }

    /// Selects an app (checking or unchecking it) or the step's button.
    func activateSetup(_ index: Int) {
        guard var flow = setup else { return }
        let choices = setupChoices
        if flow.step == .apps, choices.indices.contains(index) {
            flow.index = index
            setup = flow
            let id = choices[index].id
            library.setHidden(id, !library.isHidden(id))
            reloadServices()
            return
        }
        advanceSetup()
    }

    func advanceSetup() {
        guard var flow = setup else { return }
        let steps = flow.steps
        guard let at = steps.firstIndex(of: flow.step), at + 1 < steps.count else {
            finishSetup()
            return
        }
        let next = steps[at + 1]
        flow.step = next
        flow.index = 0
        setup = flow
    }

    /// A phone, Siri Remote or controller connected: on the remote step its row says so, and Set Up Later
    /// becomes Continue. The person moves on when they're done; one can be connected after another.
    func notePhoneDuringSetup() {
        guard setup?.step == .remote else { return }
        objectWillChange.send()
    }

    /// Back on the remote step's choice: the step before.
    func setupBack() {
        guard var flow = setup, let at = flow.steps.firstIndex(of: flow.step), at > 0 else { return }
        flow.step = flow.steps[at - 1]
        flow.index = 0
        setup = flow
    }

    private func movedSetupFocus(from index: Int, _ direction: RemoteCommand.Direction) -> Int {
        let count = setupChoices.count, columns = SetupFlow.columns
        let button = count
        switch direction {
        case .left:
            return index < button && index % columns > 0 ? index - 1 : index
        case .right:
            return index < button && index % columns < columns - 1 && index + 1 < count ? index + 1 : index
        case .down:
            if index == button { return index }
            return index + columns < count ? index + columns : button
        case .up:
            if index == button { return max(count - 1, 0) / columns * columns }
            return index >= columns ? index - columns : index
        }
    }
}

struct SetupScreen: View {
    @ObservedObject var tv: TVController
    @Environment(\.canvasSize) private var canvas

    var body: some View {
        let flow = tv.setup ?? SetupFlow()
        if flow.step == .remote {
            // Connect a Remote, as everywhere else, with the setup's dots under it.
            SettingsPages(tv: tv, panel: flow.connect)
                .overlay(alignment: .bottom) { dots(flow).padding(.bottom, 64) }
                .transition(.opacity)
        } else {
            steps(flow)
        }
    }

    private func steps(_ flow: SetupFlow) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Group {
                switch flow.step {
                case .welcome: welcome
                case .apps: apps(flow)
                case .remote: EmptyView()
                }
            }
            .id(flow.step)
            .transition(.opacity.combined(with: .offset(y: 24)))
            Spacer(minLength: 0)
            dots(flow)
                .padding(.bottom, 64)
        }
        .foregroundStyle(.white)
        .frame(width: canvas.width, height: canvas.height)
        .animation(Motion.navigate, value: flow.step)
        .animation(Motion.focus, value: flow.index)
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 28) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 200, height: 200)
                .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
            title("Welcome to Mac TV")
            subtitle("Your apps on the big screen.")
            ShelfButton(title: "Get Started", focused: true, glass: false) { tv.activateSetup(0) }
                .padding(.top, 20)
        }
    }

    private func apps(_ flow: SetupFlow) -> some View {
        let choices = tv.setupChoices
        let rows = stride(from: 0, to: choices.count, by: SetupFlow.columns).map { Array($0..<min($0 + SetupFlow.columns, choices.count)) }
        return VStack(spacing: 28) {
            title("Choose Your Apps")
            subtitle("Choose what’s on your Home Screen.")
            VStack(spacing: 34) {
                ForEach(rows, id: \.self) { row in
                    HStack(spacing: 40) {
                        ForEach(row, id: \.self) { index in
                            choice(choices[index], index: index, focused: flow.index == index)
                        }
                    }
                }
            }
            .padding(.top, 20)
            ShelfButton(title: "Continue", focused: flow.index == choices.count, glass: false) { tv.advanceSetup() }
                .padding(.top, 16)
        }
    }

    // MARK: Pieces

    private func title(_ text: String) -> some View {
        Text(text).font(.tv(.title2, emphasized: true))
    }

    private func subtitle(_ text: String) -> some View {
        Text(text)
            .font(.tv(.body))
            .foregroundStyle(.white.opacity(0.7))
            .multilineTextAlignment(.center)
            .lineSpacing(4)
            .frame(maxWidth: 1000)
    }

    private func choice(_ service: Service, index: Int, focused: Bool) -> some View {
        let on = !tv.library.isHidden(service.id)
        return VStack(spacing: 16) {
            AppTile(service: service, focused: focused, tilt: .zero)
                .opacity(on ? 1 : 0.4)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 34, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(on ? .black : .white.opacity(0.8), on ? .white : .clear)
                        .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                        .padding(12)
                        .scaleEffect(focused ? 1.14 : 1)
                        .offset(y: focused ? -10 : 0)
                        .animation(Motion.focus, value: focused)
                }
            Text(service.name)
                .font(.tv(.caption2))
                .opacity(focused ? 1 : 0.7)
        }
        .contentShape(Rectangle())
        .onTapGesture { tv.activateSetup(index) }
    }

    private func dots(_ flow: SetupFlow) -> some View {
        HStack(spacing: 12) {
            ForEach(flow.steps, id: \.self) { each in
                Capsule()
                    .fill(.white.opacity(each == flow.step ? 0.9 : 0.25))
                    .frame(width: each == flow.step ? 28 : 10, height: 10)
            }
        }
        .animation(Motion.focus, value: flow.step)
    }
}
