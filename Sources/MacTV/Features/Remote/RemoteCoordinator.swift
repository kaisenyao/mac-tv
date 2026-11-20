import AppKit
import GameController
import IOKit.hid
import Network

/// Manages remote server links, pairing tokens, remote state snapshots, and client request routing.
@MainActor
final class RemoteCoordinator: ObservableObject {
    weak var tv: TVController?

    @Published private(set) var remoteGuestToken = ""
    @Published private(set) var remoteGuestLinks: [RemoteLink] = []
    @Published private(set) var remoteLinks: [RemoteLink] = []
    var remoteToken = ""
    @Published var pairingGuest = false

    var remotePort: UInt16 = 0 {
        didSet {
            refreshRemoteURL()
            watchNetwork()
        }
    }

    /// The links change only when the network does or the pairing code rotates, so Mac TV waits
    /// for those instead of checking every few seconds.
    private var pathMonitor: NWPathMonitor?
    /// Every address a phone can reach this Mac at, for the phone to move between and for the server's
    /// cross-origin checks.
    private(set) var origins: [String] = []
    private var codeTimer: Timer?
    private var startupPairingPending = false
    private var startupPairingVisible = false
    private var phoneConnectedThisLaunch = false

    // MARK: Shortcuts (see RemoteShortcuts)

    /// Where the first profile's shortcut choice is kept; tests use their own.
    var shortcutDefaults = UserDefaults.standard {
        didSet { savedShortcuts = nil }
    }
    /// Another profile's own defaults while they're watching: each person picks their own shortcuts.
    private var profileShortcutDefaults: UserDefaults?
    private var activeShortcutDefaults: UserDefaults { profileShortcutDefaults ?? shortcutDefaults }
    private var savedShortcuts: RemoteShortcutChoice?
    /// The owner's shortcut choice, read once and saved on every change. `/state` reads it every few seconds.
    var shortcutChoice: RemoteShortcutChoice {
        get {
            if let savedShortcuts { return savedShortcuts }
            let loaded = RemoteShortcutChoice.load(from: activeShortcutDefaults)
            savedShortcuts = loaded
            return loaded
        }
        set {
            savedShortcuts = newValue
            newValue.save(to: activeShortcutDefaults)
        }
    }

    /// Someone else is watching: their shortcut sets and Apple Shortcut from now on (a new profile starts
    /// with the defaults).
    func shortcutsProfileChanged(_ space: ProfileSpace) {
        profileShortcutDefaults = space.isMain ? nil : space.defaults
        savedShortcuts = nil
    }
    /// Lists and runs the owner's Apple Shortcuts; tests stand in for the Shortcuts app.
    var listAppleShortcuts: @Sendable () async -> [String]? = { await AppleShortcuts.names() }
    var runAppleShortcutNamed: @Sendable (String) async -> AppleShortcuts.Outcome = { await AppleShortcuts.run($0) }
    /// An Apple Shortcut started from the phone hasn't finished yet.
    var appleShortcutRunning = false

    var phonePaired: Bool {
        get { UserDefaults.standard.bool(forKey: "phonePaired") }
        set { UserDefaults.standard.set(newValue, forKey: "phonePaired") }
    }

    /// The paired phones. The remote server checks every request against this same store, so a phone
    /// removed in Settings is refused at once. Tests put in their own before first use.
    lazy var pairingStore = PairingStore()

    /// The Siri Remote's charge, when this macOS exposes it, and whether Mac TV may read the remote's buttons.
    @Published private(set) var siriRemoteBattery: Int?
    @Published private(set) var inputMonitoringAllowed = false

    /// Reads the remotes' battery and Input Monitoring again: when a page or sheet showing them opens, when a
    /// remote connects or disconnects, and on coming back from System Settings. Never on a timer.
    func refreshRemoteStatus() {
        let battery = SiriRemoteStatus.shared.connected ? SiriRemoteBattery.read() : nil
        if battery != siriRemoteBattery { siriRemoteBattery = battery }
        let allowed = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        if allowed != inputMonitoringAllowed { inputMonitoringAllowed = allowed }
        // A controller's charge is read when it connects; read it again now.
        if let tv, let pad = GCController.controllers().first(where: { $0.extendedGamepad != nil }) {
            let info = ControllerInput.info(for: pad)
            if tv.controller != info { tv.controller = info }
        }
    }

    /// Settings › Remotes and Devices › iPhone: forgets one phone; it has to scan the code again.
    func removePairedDevice(_ id: String) {
        do {
            try pairingStore.revoke(id: id)
            if pairingStore.activeDevices().isEmpty { phonePaired = false }
        } catch {
            Log.remote.failure("Removing a paired phone", error)
            tv?.showToast("Couldn’t Remove the Device")
        }
        objectWillChange.send()
    }

    init(tv: TVController? = nil) {
        self.tv = tv
    }

    private func watchNetwork() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            // Addresses settle a moment after the path changes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated { self?.refreshRemoteURL() }
            }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    func refreshRemoteURL() {
        guard remotePort != 0 else { return }
        let code = RemoteServer.pairingCode()
        let guestCode = RemoteServer.guestPairingCode()
        codeTimer?.invalidate()
        codeTimer = Timer.scheduledTimer(withTimeInterval: max(1, RemoteServer.pairingCodeExpires.timeIntervalSinceNow + 0.5),
                                         repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshRemoteURL() }
        }
        let codeChanged = code != remoteToken || guestCode != remoteGuestToken
        remoteToken = code
        remoteGuestToken = guestCode
        let ip = LAN.ipv4(), tailscale = LAN.tailscaleIPv4(), name = ip == nil ? nil : LAN.bonjourName()
        // On the home network the QR code uses the Mac's name, which survives the IP changing while it
        // sleeps; the IP is shown to type instead. Tailscale addresses don't change.
        var found: [(label: String, address: String, fallback: String?)] = []
        if let ip { found.append(("Same Wi-Fi", "http://\(name ?? ip):\(remotePort)", name == nil ? nil : "\(ip):\(remotePort)")) }
        if let tailscale { found.append(("Tailscale", "http://\(tailscale):\(remotePort)", nil)) }
        origins = ([name, ip, tailscale].compactMap { $0 }).map { "http://\($0):\(remotePort)" }
        guard codeChanged || found.map(\.address) != remoteLinks.map(\.address)
            || found.map(\.fallback) != remoteLinks.map(\.fallback) else { return }
        remoteLinks = found.map { label, address, fallback in
            RemoteLink(label: label, address: address, fallback: fallback, qr: QRCode.image(for: "\(address)/?k=\(remoteToken)"))
        }
        remoteGuestLinks = found.map { label, address, fallback in
            RemoteLink(label: label, address: address, fallback: fallback, qr: QRCode.image(for: "\(address)/?k=\(remoteGuestToken)"))
        }
    }

    func offerStartupPairing() {
        startupPairingPending = !phoneConnectedThisLaunch
        showStartupPairingIfReady()
    }

    /// Connect a Remote at launch, as Apple TV shows its pairing screen: only while there's no remote at all.
    /// The keyboard and mouse always work, so a Siri Remote or game controller that's connected, or a phone
    /// that has ever been paired (even if its page isn't open yet), is enough. Back closes it, and so does a
    /// remote connecting or being used.
    func showStartupPairingIfReady() {
        guard let tv, startupPairingPending, !phoneConnectedThisLaunch,
              tv.setup == nil, tv.profilePicker == nil, tv.mode == .launcher else { return }
        startupPairingPending = false
        guard !tv.otherRemoteConnected, pairingStore.activeDevices().isEmpty else { return }
        startupPairingVisible = true
        tv.pairing = true
    }

    func noteRemoteConnection() {
        phoneConnectedThisLaunch = true
        startupPairingPending = false
        if startupPairingVisible, let tv {
            tv.pairing = false
        }
    }

    /// A Siri Remote or game controller connected or was used: the pairing sheet shown at launch goes away.
    func noteOtherRemote() {
        startupPairingPending = false
        if startupPairingVisible, let tv { tv.pairing = false }
    }

    func notePairingDismissed() {
        startupPairingVisible = false
    }

    // MARK: - Remote State

    func remoteState() -> [String: Any] {
        guard let tv else { return [:] }
        if !phonePaired { phonePaired = true }   // asked every few seconds: write it once, not on every ask
        noteRemoteConnection()
        tv.notePhoneDuringSetup()

        let sheetName = tv.activeSheet?.remoteName ?? ""

        var state: [String: Any] = [
            "device": tv.deviceName,
            "addresses": origins,
            "mode": "launcher",
            "audioDevice": tv.currentAudioDevice?.name ?? "",
            "apps": tv.arrangedServices.map { service -> [String: Any] in
                ["id": service.id, "name": service.name, "icon": Icons.image(for: service) != nil,
                 "playing": playingAudio(service.id, tv), "added": tv.organizerActions(for: service.id).contains(.deleteForEveryone),
                 // A system app (Movies, Web): the phone's Edit shows no "−" on it
                 "system": AppLibrary.isSystemApp(service.id)]
            },
            // Home's first apps are its top row, the dock; the phone's Edit shows the same.
            "dockSize": AppLibrary.dockSize,
            "canRestore": tv.library.hasHiddenBuiltIns,
            "profile": tv.profile.name,
            "focus": String(describing: tv.focus),
            "sheet": sheetName,
            "autoSkip": tv.autoSkip,
            "autoNext": tv.autoNext,
            "keepMacAwake": tv.keepMacAwake,
            "lidOverride": tv.lidOverride,
            "lidStatus": tv.lidStatus,
            "accessibilityAllowed": AXIsProcessTrusted(),
            "sleepMinutes": tv.sleepMinutesLeft,
        ]
        state["displaySetup"] = ["displays": tv.displaySetup, "fullscreen": tv.window?.styleMask.contains(.fullScreen) ?? false]
        state["displaysSleeping"] = tv.displaysSleeping
        state["websitePlayer"] = tv.browserPreferences.choice(for: tv.profile.id).rawValue
        state["braveInstalled"] = tv.braveInstalled
        state["shortcuts"] = tv.shortcutState()

        if tv.externalBrowser != nil {
            state["externalBrowser"] = [
                "name": "Brave",
                "service": tv.externalBrowserService?.name ?? "Website",
                "accessibilityAllowed": AXIsProcessTrusted(),
                "error": tv.externalBrowserError ?? "",
                "opening": tv.externalBrowserOpening
            ]
        }
        if tv.playbackCoordinator.iinaOpen {
            state["mode"] = "player"
            state["externalPlayer"] = ["name": "IINA", "status": tv.iinaPlaybackStatus, "error": tv.iinaPlaybackError ?? ""]
        }
        state["iinaInstalled"] = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.colliderli.iina") != nil

        if let movie = tv.currentLocalMovie {
            state["currentLocalMovie"] = ["id": PhoneFiles.id(for: movie.url), "title": movie.displayTitle, "player": tv.localMoviePlayer]
        }
        if case .player(let service) = tv.mode {
            state["mode"] = "player"
            state["current"] = ["id": service.id, "name": service.name]
        } else if tv.mode == .movie, let player = tv.moviePlayer {
            state["mode"] = "player"
            state["current"] = ["id": "movies", "name": player.movie.displayTitle]
            state["movie"] = ["time": player.time, "duration": player.duration, "playing": player.playing,
                              "failure": player.engine.renderFailure ?? ""]
        }
        return state
    }

    /// The apps that keep playing sound in the background (the phone's Apps sheet marks them).
    private func playingAudio(_ id: String, _ tv: TVController) -> Bool {
        switch id {
        case "netease": tv.neteaseStore.current != nil && !tv.neteaseStore.paused
        case "dedao": !tv.dedaoStore.player.paused
        default: false
        }
    }

    // MARK: - Remote Routing

    @discardableResult
    func handleGuestCommand(_ command: RemoteCommand) -> Bool {
        switch command {
        case .home, .playPause, .volume, .mute, .activateBrowser, .browserFullscreen:
            tv?.handle(command, from: .remote)
            return true
        default: return false
        }
    }

    func handleAppsRequest(_ request: HTTPRequest) -> HTTPResponse? {
        guard let tv else { return nil }
        if request.path == "/shortcuts" || request.path.hasPrefix("/shortcuts/") { return handleShortcutsRequest(request) }
        if let response = tv.handleSharesRequest(request) { return response }
        if let response = tv.handleJellyfinRequest(request) { return response }
        if request.method == "POST", request.path == "/display/select" {
            guard let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
                  let id = body["id"] as? String, tv.selectTVDisplay(id: id) else {
                return .json(["error": "Choose a connected display."], status: "400 Bad Request")
            }
            return .json(["ok": true])
        }
        if request.method == "POST", request.path == "/browser/open" {
            // 手机上粘贴的链接（或 App 分享出来的一整段文字）：哔哩哔哩、网易云、YouTube 的交给对应的应用打开；
            // 普通网页照旧在网页播放器里打开（下面），分享文字里夹着的网址也找出来
            var address = ((try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any])?["url"] as? String ?? ""
            if let reading = PhoneLink.read(address) {
                if case .ready(.web(let found)) = reading {
                    // 本来就是一个网址（比如 youtube.com）就照原样用（会补成 https）；是一段夹着网址的文字才换成找出来的那个
                    if WebsiteAddress.url(from: address) == nil { address = found.absoluteString }
                } else if let opened = tv.openPhoneLink(address) {
                    return .json(["ok": true, "opened": opened])
                }
            }
            guard let url = WebsiteAddress.url(from: address) else {
                return .json(["error": "Paste a Bilibili, NetEase Cloud Music or YouTube link, or enter a website address such as youtube.com."], status: "400 Bad Request")
            }
            guard !tv.externalBrowserOpening else {
                return .json(["error": "Wait for the website to open, then try again."], status: "409 Conflict")
            }
            let service = Service.website(url)
            if tv.browserPreferences.choice(for: tv.profile.id) == .brave, tv.externalBrowser != nil {
                do {
                    try tv.playbackCoordinator.navigateExternalBrowser(service: service, url: url)
                } catch {
                    return .json(["error": error.localizedDescription], status: "409 Conflict")
                }
            } else {
                tv.open(service)
            }
            return .json(["ok": true, "opened": "website"])
        }
        if request.method == "POST", request.path == "/browser/preference" {
            guard let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
                  let raw = body["player"] as? String, tv.setWebsitePlayer(raw) else {
                return .json(["error": "Install Brave to choose it."], status: "400 Bad Request")
            }
            return .json(["ok": true])
        }
        if let response = tv.handleSubtitleRequest(request) ?? tv.handleFilesRequest(request) { return response }
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        switch (request.method, request.path) {
        case ("GET", "/macapps"):
            let installed = Set(tv.services.compactMap { service -> String? in
                if case .app(let bundleID) = service.kind { return bundleID }
                return nil
            })
            return .json(InstalledApps.matching(request.query["q"] ?? "").map {
                ["name": $0.name, "bundleID": $0.bundleID, "added": installed.contains($0.bundleID)]
            })
        case ("POST", "/apps/add"):
            let app: AddedApp?
            if let bundleID = body["bundleID"] as? String {
                app = tv.addMacApp(bundleID: bundleID)
            } else if let address = body["url"] as? String {
                app = tv.addWebsite(name: body["name"] as? String, address: address)
            } else {
                app = nil
            }
            guard let app else { return .json(["error": "Couldn't add that. Check the address."], status: "400 Bad Request") }
            return .json(["ok": true, "id": app.id, "name": app.name])
        case ("POST", "/apps/remove"):
            // Hide: the app leaves this profile's Home only.
            guard let id = body["id"] as? String else { return .json(["error": "Missing app"], status: "400 Bad Request") }
            if let refusal = tv.hideApp(id) { return .json(["error": refusal], status: "400 Bad Request") }
            return .json(["ok": true])
        case ("POST", "/apps/delete"):
            // Delete for Everyone: only for an app someone added; built-in apps can only be hidden, and system apps
            // neither. Its files go to the Trash.
            if let id = body["id"] as? String, AppLibrary.isSystemApp(id) {
                return .json(["error": tv.systemAppRefusal(id, deleting: true)], status: "400 Bad Request")
            }
            guard let id = body["id"] as? String, tv.library.containsAddedApp(id),
                  !Catalog.services.contains(where: { $0.id == id }) else {
                return .json(["error": "Built-in apps can’t be deleted. You can hide them."], status: "400 Bad Request")
            }
            if let error = tv.deleteAppForEveryone(id) { return .json(["error": error], status: "500 Internal Server Error") }
            return .json(["ok": true])
        case ("POST", "/apps/restore"):
            tv.restoreBuiltInApps()
            return .json(["ok": true])
        case ("POST", "/apps/place"):
            // The phone's Edit: an app dropped at a place in Home's order (the first six are the dock).
            guard let id = body["id"] as? String, tv.appOrder.contains(id),
                  let index = body["index"] as? NSNumber, CFGetTypeID(index) != CFBooleanGetTypeID(),
                  index.doubleValue >= 0, index.doubleValue == index.doubleValue.rounded() else {
                return .json(["error": "Choose an app and where to put it."], status: "400 Bad Request")
            }
            guard tv.moveApp(id, to: Int(min(index.doubleValue, 10_000))) else {
                return .json(["error": "Couldn't save that app's position. Check storage on the Mac."], status: "500 Internal Server Error")
            }
            return .json(["ok": true])
        default:
            return nil
        }
    }
}
