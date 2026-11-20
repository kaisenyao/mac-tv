import SwiftUI

/// The first-run setup: a welcome, choosing the home screen's apps and pairing the phone remote.
/// Shown once on a new install, driven by the D-pad, the keyboard or the mouse.
struct SetupFlow: Equatable {
    enum Step: Int, CaseIterable {
        case welcome, apps, remote
    }

    var step: Step = .welcome
    /// In the apps step: the focused app, or the Continue button when it's past the last app.
    var index = 0
    /// A phone opened the remote while the remote step was showing.
    var phoneConnected = false
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
        switch command {
        case .back:
            let steps = flow.steps
            if let at = steps.firstIndex(of: flow.step), at > 0 { flow.step = steps[at - 1]; flow.index = 0 }
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

    /// Called whenever a phone fetches the remote's state: on the remote step, that means it's paired.
    func notePhoneDuringSetup() {
        guard let flow = setup, flow.step == .remote, !flow.phoneConnected else { return }
        setup?.phoneConnected = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            if self?.setup?.step == .remote { self?.advanceSetup() }
        }
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
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Group {
                switch flow.step {
                case .welcome: welcome
                case .apps: apps(flow)
                case .remote: remote(flow)
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

    private func remote(_ flow: SetupFlow) -> some View {
        VStack(spacing: 28) {
            title("Use Your Phone as a Remote")
            subtitle("Scan with your phone’s camera. A Siri Remote or game controller works too.")
            HStack(alignment: .top, spacing: 36) {
                if tv.remoteLinks.isEmpty {
                    RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.white.opacity(0.1))
                        .frame(width: 300, height: 300)
                        .overlay(Text("Connect to Wi-Fi\nor Tailscale").multilineTextAlignment(.center)
                            .font(.tv(.caption2)).opacity(0.7))
                }
                ForEach(tv.remoteLinks) { link in
                    VStack(spacing: 14) {
                        if let qr = link.qr {
                            Image(nsImage: qr).interpolation(.none).resizable()
                                .frame(width: 240, height: 240)
                                .padding(20)
                                .background(.white, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                        }
                        Text(link.label).font(.tv(.caption2)).opacity(0.8)
                        if let fallback = link.fallback {
                            Text("or open \(fallback)").font(.tv(.caption2)).monospacedDigit().opacity(0.5)
                        }
                    }
                }
            }
            .padding(.top, 12)
            .opacity(flow.phoneConnected ? 0.35 : 1)
            .overlay {
                if flow.phoneConnected {
                    Label("Remote Connected", systemImage: "checkmark.circle.fill")
                        .font(.tv(.body, emphasized: true))
                        .padding(.horizontal, 34).frame(height: 76)
                        .background(Capsule().fill(Color(white: 0.16)))
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
            .animation(Motion.appear, value: flow.phoneConnected)
            ShelfButton(title: flow.phoneConnected ? "Continue" : "Skip for Now", focused: true, glass: false) { tv.advanceSetup() }
                .padding(.top, 8)
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
