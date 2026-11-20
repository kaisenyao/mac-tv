import AppKit
import IOKit.graphics
import ServiceManagement

/// Window and login-item behavior for the optional dedicated TV setup.
@MainActor
final class TVMode {
    private let window: NSWindow
    private weak var tv: TVController?
    private var normalFrame: NSRect?
    private var transitioning = false
    private var transitionGeneration = 0
    private var pendingDedicatedEntry = false
    private var relocationPending = false
    private var manualTargetID: String?
    private var manualRestoreFullscreen = false
    private var manualDedicatedEntry = false
    private var manualEntering = false
    private var fullscreenTargetID: String?
    private var fullscreenMoveRetries = 0
    private var movingWindow = false
    private var screenChangeGeneration = 0
    private var observers: [NSObjectProtocol] = []
    private let preferences: Preferences

    init(window: NSWindow, tv: TVController, preferences: Preferences = .shared) {
        self.window = window
        self.tv = tv
        self.preferences = preferences
        tv.displayCoordinator.tvMode = self
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didEnterFullScreen() }
        })
        observers.append(center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didExitFullScreen() }
        })
        // Back from System Settings, where Open at Login may have just been approved.
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cachedLoginStatus = nil }
        })
    }

    private func toggleFullscreenWithWatchdog() {
        transitionGeneration += 1
        let generation = transitionGeneration
        window.toggleFullScreen(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.transitionGeneration == generation, self.transitioning else { return }
            self.trace("fullscreen transition timed out")
            self.transitioning = false
            self.pendingDedicatedEntry = false
            self.manualEntering = false
            self.manualTargetID = nil
            self.fullscreenTargetID = nil
            self.manualRestoreFullscreen = false
            self.manualDedicatedEntry = false
            self.relocationPending = false
            self.tv?.showToast("Couldn't Move to That Display")
            self.tv?.objectWillChange.send()
        }
    }

    /// One short line per window step, for the diagnostics report: the display it's on (first part
    /// of its id), where it's headed, and its state.
    private func trace(_ event: String) {
        func short(_ id: String?) -> String { id.map { String($0.prefix(8)) } ?? "none" }
        var parts = ["on \(short(window.screen.map(id)))"]
        if let manualTargetID { parts.append("to \(short(manualTargetID))") }
        parts.append(preferredID.map { "prefers \(short($0))" } ?? "automatic")
        parts.append(window.styleMask.contains(.fullScreen) ? "full screen" : "windowed")
        if transitioning { parts.append("transitioning") }
        if movingWindow { parts.append("moving") }
        parts.append("\(Int(window.frame.width))×\(Int(window.frame.height))")
        Log.display.notice("\(event, privacy: .public): \(parts.joined(separator: ", "), privacy: .public)")
    }

    var enabled: Bool { preferences.dedicatedTVMode }
    var preferredID: String? { preferences.preferredTVDisplay }
    /// Asking the system is a synchronous round trip, too slow for every redraw of Settings › General: asked
    /// once, then again only after changing it or coming back to Mac TV.
    private var cachedLoginStatus: SMAppService.Status?
    var loginStatus: SMAppService.Status {
        if let cachedLoginStatus { return cachedLoginStatus }
        let status = SMAppService.mainApp.status
        cachedLoginStatus = status
        return status
    }
    var loginEnabled: Bool { loginStatus == .enabled || loginStatus == .requiresApproval }

    /// Each display's lasting id, looked up once per display: Settings › Video and Audio names the preferred one on
    /// every redraw. Cleared when displays change.
    private var screenIDs: [CGDirectDisplayID: String] = [:]

    private func id(_ screen: NSScreen) -> String {
        if let known = screenIDs[screen.displayID] { return known }
        let found = CGDisplayCreateUUIDFromDisplayID(screen.displayID).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
            ?? "display-\(screen.displayID)"
        screenIDs[screen.displayID] = found
        return found
    }

    struct DisplayOption: Equatable {
        let id: String
        let name: String
        let current: Bool
        let preferred: Bool
    }

    var displayOptions: [DisplayOption] {
        NSScreen.screens.map { screen in
            DisplayOption(id: id(screen), name: screen.localizedName,
                          current: window.screen?.displayID == screen.displayID,
                          preferred: preferredID == id(screen))
        }
    }

    /// Connect a Remote opens on its first page.
    func resetPairingFocus() { tv?.connectRemote = .connect }

    @discardableResult
    func chooseDisplay(id displayID: String) -> Bool {
        guard NSScreen.screens.contains(where: { id($0) == displayID }) else { return false }
        preferences.preferredTVDisplay = displayID
        trace("choose")
        if !transitioning, !movingWindow, window.screen.map({ id($0) }) == displayID {
            tv?.objectWillChange.send()
            return true
        }
        manualTargetID = displayID
        fullscreenMoveRetries = 0
        manualRestoreFullscreen = manualRestoreFullscreen || window.styleMask.contains(.fullScreen) || enabled
        manualDedicatedEntry = manualDedicatedEntry || enabled
        tv?.objectWillChange.send()
        performManualMove()
        return true
    }

    private func performManualMove() {
        guard let targetID = manualTargetID, !transitioning, !movingWindow else { return }
        guard let target = NSScreen.screens.first(where: { id($0) == targetID }) else {
            finishManualMoveFailure("The selected display disconnected.")
            return
        }
        if window.styleMask.contains(.fullScreen) {
            transitioning = true
            trace("request exit fullscreen")
            toggleFullscreenWithWatchdog()
        } else {
            movingWindow = true
            moveWindow(to: target)
            confirmManualMove(targetID: targetID, attempt: 0)
        }
    }

    private func confirmManualMove(targetID: String, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.trace("confirm move attempt \(attempt)")
            guard self.manualTargetID == targetID else {
                self.movingWindow = false
                self.performManualMove()
                return
            }
            guard let target = NSScreen.screens.first(where: { self.id($0) == targetID }) else {
                self.finishManualMoveFailure("The selected display disconnected.")
                return
            }
            if self.window.screen?.displayID == target.displayID {
                self.movingWindow = false
                self.manualTargetID = nil
                self.tv?.objectWillChange.send()
                if self.manualRestoreFullscreen {
                    self.manualRestoreFullscreen = false
                    self.manualEntering = true
                    self.fullscreenTargetID = targetID
                    self.pendingDedicatedEntry = self.manualDedicatedEntry
                    self.manualDedicatedEntry = false
                    self.transitioning = true
                    self.trace("request enter fullscreen")
                    self.toggleFullscreenWithWatchdog()
                }
            } else if attempt < 9 {
                self.moveWindow(to: target)
                self.confirmManualMove(targetID: targetID, attempt: attempt + 1)
            } else {
                self.finishManualMoveFailure("Couldn't Move to That Display")
            }
        }
    }

    private func finishManualMoveFailure(_ message: String) {
        movingWindow = false
        manualTargetID = nil
        let restore = manualRestoreFullscreen
        let dedicated = manualDedicatedEntry
        manualRestoreFullscreen = false
        manualDedicatedEntry = false
        trace("move failure: \(message)")
        tv?.showToast(message)
        tv?.objectWillChange.send()
        guard restore, !window.styleMask.contains(.fullScreen) else { return }
        if window.screen == nil, let fallback = NSScreen.main ?? NSScreen.screens.first {
            moveWindow(to: fallback)
        }
        manualEntering = true
        fullscreenTargetID = nil
        pendingDedicatedEntry = dedicated
        transitioning = true
        toggleFullscreenWithWatchdog()
    }

    var preferredName: String {
        guard let preferredID else { return "Automatic" }
        return NSScreen.screens.first(where: { id($0) == preferredID })?.localizedName ?? "Disconnected"
    }

    func stepDisplay(_ step: Int, wrap: Bool) {
        let screens = NSScreen.screens
        let choices: [String?] = [nil] + screens.map { id($0) as String? }
        // Keep a disconnected preference until the user explicitly chooses another display.
        let current = choices.firstIndex { $0 == preferredID } ?? 0
        var next = current + step
        next = wrap ? (next + choices.count) % choices.count : min(max(next, 0), choices.count - 1)
        preferences.preferredTVDisplay = choices[next]
        if enabled { reconcileScreen() }
    }

    /// Control Center's Display list: no display preferred; full screen goes where it picks.
    func preferAutomaticDisplay() {
        preferences.preferredTVDisplay = nil
        if enabled { reconcileScreen() }
        tv?.objectWillChange.send()
    }

    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        preferences.dedicatedTVMode = value
        if value {
            normalFrame = window.frame
            reconcileScreen()
        } else if window.styleMask.contains(.fullScreen) && !transitioning {
            relocationPending = false
            transitioning = true
            toggleFullscreenWithWatchdog()
        } else if !transitioning {
            restoreNormalFrame()
        }
    }

    func start() {
        guard enabled else { return }
        normalFrame = window.frame
        // Allow the normal window to be presented before requesting a Space transition.
        DispatchQueue.main.async { [weak self] in self?.reconcileScreen() }
    }

    func setLoginEnabled(_ value: Bool) {
        guard SystemGuard.allows(value ? "add the login item" : "remove the login item") else { return }
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            cachedLoginStatus = nil
            if loginStatus == .requiresApproval {
                tv?.showToast("Allow Mac TV in System Settings › General › Login Items")
            }
        } catch {
            cachedLoginStatus = nil
            tv?.showToast("Could not change login item: \(error.localizedDescription)")
        }
        tv?.objectWillChange.send()
    }

    func screensChanged() {
        screenIDs = [:]
        screenChangeGeneration += 1
        let generation = screenChangeGeneration
        // Display arrangements can produce several notifications while HDMI settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, generation == self.screenChangeGeneration else { return }
            self.tv?.objectWillChange.send()
            if self.enabled { self.reconcileScreen() }
        }
    }

    var playbackScreen: NSScreen? { targetScreen }

    private var targetScreen: NSScreen? {
        if let preferredID, let match = NSScreen.screens.first(where: { id($0) == preferredID }) { return match }
        return NSScreen.screens.first(where: { CGDisplayIsBuiltin($0.displayID) == 0 }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func reconcileScreen() {
        guard enabled, let target = targetScreen else { return }
        if transitioning || movingWindow {
            relocationPending = true
            return
        }
        if window.styleMask.contains(.fullScreen), window.screen?.displayID == target.displayID { return }
        // Use the same exit, move, verify and re-enter sequence as an explicit display choice.
        manualTargetID = id(target)
        fullscreenMoveRetries = 0
        manualRestoreFullscreen = true
        manualDedicatedEntry = true
        relocationPending = false
        performManualMove()
    }

    private func moveWindow(to screen: NSScreen) {
        let area = screen.visibleFrame
        let original = window.frame.size
        let scale = min(1, area.width / max(original.width, 1), area.height / max(original.height, 1))
        let size = NSSize(width: original.width * scale, height: original.height * scale)
        window.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                               width: size.width, height: size.height), display: true)
        trace("set frame for \(id(screen))")
    }

    private func didEnterFullScreen() {
        transitionGeneration += 1
        trace("did enter fullscreen")
        let wasDedicatedEntry = pendingDedicatedEntry
        pendingDedicatedEntry = false
        let wasManualEntry = manualEntering
        manualEntering = false
        let enteredTarget = fullscreenTargetID
        fullscreenTargetID = nil
        // didEnter arrives before macOS has always finished settling its Space animation.
        // Serialize any next toggle and check the final screen after that settling period.
        transitioning = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.transitioning = false
            self.trace("settled fullscreen entry")
            self.tv?.objectWillChange.send()
            if self.manualTargetID != nil { self.performManualMove(); return }
            if wasDedicatedEntry && !self.enabled {
                self.transitioning = true
                self.toggleFullscreenWithWatchdog()
                return
            }
            if wasManualEntry, let enteredTarget,
               self.window.screen.map({ self.id($0) }) != enteredTarget {
                if self.fullscreenMoveRetries < 2,
                   NSScreen.screens.contains(where: { self.id($0) == enteredTarget }) {
                    self.fullscreenMoveRetries += 1
                    self.manualTargetID = enteredTarget
                    self.manualRestoreFullscreen = true
                    self.manualDedicatedEntry = wasDedicatedEntry && self.enabled
                    self.performManualMove()
                } else {
                    self.fullscreenMoveRetries = 0
                    self.tv?.showToast("Couldn't Move to That Display")
                }
                return
            }
            self.fullscreenMoveRetries = 0
            if self.enabled && self.relocationPending {
                self.relocationPending = false
                self.reconcileScreen()
            }
        }
    }

    private func didExitFullScreen() {
        transitionGeneration += 1
        trace("did exit fullscreen")
        transitioning = false
        tv?.objectWillChange.send()
        if manualTargetID != nil {
            transitioning = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                self.transitioning = false
                self.trace("settled fullscreen exit")
                self.performManualMove()
            }
            return
        }
        if enabled {
            // macOS can exit full screen during display removal. Keep the user's
            // setting and recover on the available screen until they choose Exit TV mode.
            relocationPending = false
            reconcileScreen()
        } else {
            relocationPending = false
            restoreNormalFrame()
        }
    }

    private func restoreNormalFrame() {
        guard let frame = normalFrame else { return }
        // Don't restore an inaccessible window after the display has been unplugged.
        if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
            window.setFrame(frame, display: true)
        } else if let screen = NSScreen.main ?? NSScreen.screens.first {
            moveWindow(to: screen)
        }
        normalFrame = nil
    }
}

extension TVController {
    private var tvMode: TVMode? { displayCoordinator.tvMode }
    var availableTVDisplays: [TVMode.DisplayOption] { tvMode?.displayOptions ?? [] }
    var displaySetup: [[String: Any]] {
        availableTVDisplays.map { ["id": $0.id, "name": $0.name, "current": $0.current, "preferred": $0.preferred] }
    }
    @discardableResult func selectTVDisplay(id: String) -> Bool { tvMode?.chooseDisplay(id: id) ?? false }
    /// A display to prefer and move to, or nil for Automatic.
    func chooseTVDisplay(_ id: String?) {
        if let id { selectTVDisplay(id: id) } else { tvMode?.preferAutomaticDisplay() }
    }
    var dedicatedTVMode: Bool { tvMode?.enabled ?? false }
    var preferredTVDisplayName: String { tvMode?.preferredName ?? "Automatic" }
    var launchAtLogin: Bool { tvMode?.loginEnabled ?? false }
    var loginNeedsApproval: Bool { tvMode?.loginStatus == .requiresApproval }
    func setDedicatedTVMode(_ enabled: Bool) { tvMode?.setEnabled(enabled) }
    func stepTVDisplay(_ step: Int, wrap: Bool = false) { tvMode?.stepDisplay(step, wrap: wrap) }
    func setLaunchAtLogin(_ enabled: Bool) { tvMode?.setLoginEnabled(enabled) }
}
