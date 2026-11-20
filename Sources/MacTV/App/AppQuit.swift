import AppKit
import SwiftUI
import WebKit

// Back, the TV button and the App Switcher, the same in every app on Mac TV (哔哩哔哩, 网易云音乐, 得到, YouTube, Movies,
// Web and the website apps), as on Apple TV:
//
// | Input | What it does |
// |---|---|
// | Back (Esc, the Siri Remote's Back, the phone's Back, a controller's B) | Back one level; at an app's top level, the Home Screen, with the app in the background; on Home's first app, the screen saver |
// | Holding Back | The Home Screen, with the app in the background |
// | The TV button (the Siri Remote's, the phone's, ⌘H, a controller's Home or Menu) | The Home Screen, with the app in the background: music and audio books keep playing, video pauses |
// | The TV button twice | The App Switcher: the apps in the background, most recent first. Up on one quits it; Select switches to it |
// | Holding the TV button | Control Center |
// | ⌘Q | As Chrome: a press shows "Hold ⌘Q to Quit" (Mac TV's own toast); holding it quits Mac TV |
//
// The Quit Mac TV menu item quits at once, as Chrome's does, and so do a logout, restart, shutdown and the updater's
// relaunch: only the ⌘Q key holds.

/// The App Switcher: every app in the background, most recent first, as on Apple TV.
struct AppSwitcher: Equatable {
    /// The focused card: an index into `TVController.backgroundApps`.
    var index = 0
    /// The app whose card is sliding up as it quits.
    var leaving: String?
    /// Select or a click: the focused card dips and settles back each time this goes up.
    var presses = 0
}

extension TVController {
    /// How long ⌘Q is held before Mac TV quits, as Chrome's "Hold ⌘Q to Quit".
    static let quitKeyHold: Duration = .milliseconds(1500)
    /// Two presses of the TV button this close together open the App Switcher.
    static let homeDoublePress: TimeInterval = 0.45
    /// How long a quitting card takes to slide up before the others close the gap.
    static let switcherQuitSlide: Duration = .milliseconds(280)

    /// The app in front, if any: the one the TV button sends to the background.
    var appInFront: Service? {
        func app(_ id: String) -> Service? { services.first { $0.id == id } ?? Catalog.services.first { $0.id == id } }
        if bilibiliOpen { return app(BilibiliStore.appID) }
        if neteaseOpen { return app(NeteaseStore.appID) }
        if dedaoOpen { return app(DedaoStore.appID) }
        if browserOpen || browserPageInFront { return app(BrowserStore.appID) }
        if movies != nil || mode == .movie || playbackCoordinator.iinaOpen { return app("movies") }
        if externalBrowser != nil, let service = externalBrowserService { return app(service.id) ?? service }
        if case .player(let service) = mode {
            // A sign-in page an app opened belongs to that app.
            if service.id == BilibiliStore.loginID { return app(BilibiliStore.appID) }
            if service.id == NeteaseStore.loginID { return app(NeteaseStore.appID) }
            return app(service.id) ?? service
        }
        return nil
    }

    // MARK: The App Switcher

    /// The TV button was pressed (it has gone Home already, or is about to). True when it was the second press of
    /// two with apps in the background, which opens the App Switcher, or a press while the switcher is open, which
    /// closes it. With nothing in the background the second press is just Home again.
    func pressHome(at now: Date = Date()) -> Bool {
        defer { lastHomePress = now }
        if appSwitcher != nil {
            appSwitcher = nil
            lastHomePress = nil
            return true
        }
        guard let last = lastHomePress, now.timeIntervalSince(last) < Self.homeDoublePress else { return false }
        goHome()
        guard !backgroundApps.isEmpty else { return true }
        appSwitcher = AppSwitcher()   // on the app just left
        return true
    }

    /// Left and Right move along the cards; Select switches to one; Up quits it; Back closes the switcher.
    func handleAppSwitcher(_ command: RemoteCommand) {
        guard var switcher = appSwitcher else { return }
        let last = backgroundApps.count - 1
        switch command {
        case .move(.left): switcher.index = max(0, switcher.index - 1)
        case .move(.right): switcher.index = max(0, min(last, switcher.index + 1))
        case .move(.up) where backgroundApps.indices.contains(switcher.index) && switcher.leaving == nil:
            quitFromSwitcher(backgroundApps[switcher.index])
            return
        case .select:
            switcher.presses += 1
            appSwitcher = switcher
            chooseInSwitcher(switcher.index)
            return
        case .back:
            appSwitcher = nil
            return
        default:
            break
        }
        appSwitcher = switcher
    }

    /// A card chosen: its app, as it was.
    func chooseInSwitcher(_ index: Int) {
        appSwitcher = nil
        guard backgroundApps.indices.contains(index) else { return }
        open(backgroundApps[index])
    }

    /// Up on an app's card: it slides up and quits, and the cards after it close the gap. The last one quit, the
    /// switcher closes on the Home Screen.
    func quitFromSwitcher(_ app: Service) {
        appSwitcher?.leaving = app.id
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.switcherQuitSlide)
            guard let self else { return }
            self.quitApp(app.id, reason: "App Switcher")
            guard var switcher = self.appSwitcher else { return }
            guard !self.backgroundApps.isEmpty else { self.appSwitcher = nil; return }
            switcher.leaving = nil
            switcher.index = min(switcher.index, self.backgroundApps.count - 1)
            withAnimation(Motion.focus) { self.appSwitcher = switcher }
        }
    }

    /// The TV button is about to send the app in front to the background: it moves to the front of the App Switcher, with a
    /// picture of how it looks now, taken once, small.
    func noteAppInBackground() {
        guard let app = appInFront else { return }
        backgroundApps.removeAll { $0.id == app.id }
        backgroundApps.insert(app, at: 0)
        snapshot(app.id)
    }

    /// One picture of the app as it is, card-sized: a web page from WebKit, anything else from the window.
    private func snapshot(_ id: String) {
        let width: CGFloat = 640
        if case .player = mode, let web = playbackCoordinator.webView {
            let configuration = WKSnapshotConfiguration()
            configuration.snapshotWidth = NSNumber(value: Double(width))
            web.takeSnapshot(with: configuration) { [weak self] image, _ in
                MainActor.assumeIsolated { if let image { self?.appSnapshots[id] = image } }
            }
            return
        }
        guard let view = window?.contentView, view.bounds.width > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let size = NSSize(width: width, height: (width * view.bounds.height / view.bounds.width).rounded())
        let image = NSImage(size: size)
        image.lockFocus()
        rep.draw(in: NSRect(origin: .zero, size: size))
        image.unlockFocus()
        appSnapshots[id] = image
    }

    /// Quits an app (from the App Switcher, a profile switch): everything it was playing stops (positions saved and
    /// play reports sent first, as each app does), and everything it held goes: web views, players, what it had
    /// loaded, its snapshot. Next time it opens fresh, as if it had just launched; Web's tabs come back, as Safari's do.
    func quitApp(_ id: String, reason: String) {
        switch id {
        case BilibiliStore.appID: closeBilibili()
        case NeteaseStore.appID: closeNetease(); neteaseStore.quit()
        case DedaoStore.appID: closeDedao()
        case BrowserStore.appID: closeBrowser()
        case "movies":
            movies = nil
            playbackCoordinator.quitMovies()
        default: break
        }
        // Website apps, and Web's page: the page in front, or the one kept in the background.
        if case .player(let service) = mode,
           service.id == id || (id == BrowserStore.appID && service.id == BrowserStore.pageID)
            || (id == BilibiliStore.appID && service.id == BilibiliStore.loginID)
            || (id == NeteaseStore.appID && service.id == NeteaseStore.loginID) {
            playbackCoordinator.closeWebPlayback()
        }
        if externalBrowserService?.id == id { playbackCoordinator.closeExternalBrowser() }
        playbackCoordinator.dropParkedWeb(id)
        // The apps that keep data per profile save what they were in the middle of, then start over.
        if let app = profileApps.apps.first(where: { type(of: $0).appID == id }) {
            app.profileWillChange()
            app.profileChanged()
        }
        backgroundApps.removeAll { $0.id == id }
        appSnapshots[id] = nil
        Log.app.notice("Quit \(id, privacy: .public): \(reason, privacy: .public)")
    }

    /// The Home Screen, as the TV button goes there: the app in front goes to the background. Music and audio books keep
    /// playing (网易云音乐 as its own Background Playback setting says); video pauses, and is still there on
    /// coming back. Web keeps its tabs.
    func sendAppsToBackground() {
        if bilibiliOpen {
            bilibiliStore.player.pauseForBackground()
            bilibiliOpen = false
            BiliImageCache.shared.trim()   // decoded covers (up to 64 MB) come back from the network cache on return
        }
        leaveNetease()
        if dedaoOpen {
            if dedaoStore.player.scrubbing { dedaoStore.player.endScrub() }
            dedaoOpen = false
        }
        closeBrowser()
        playbackCoordinator.parkWebPlayback()
    }

    /// Someone else starts watching: what the TV button kept in the background is the last person's, so it quits (the apps
    /// that keep data per profile stop and save through their own profile hooks).
    func quitBackgroundApps(reason: String) {
        Log.app.notice("Quit the apps in the background: \(reason, privacy: .public)")
        playbackCoordinator.quitMovies()
        playbackCoordinator.closeExternalBrowser()
        playbackCoordinator.dropParkedWeb()
        backgroundApps = []
        appSnapshots = [:]
    }

    /// The sleep timer: on the Home Screen, the music and audio books that would keep playing in the background stop.
    func stopBackgroundAudio(reason: String) {
        Log.app.notice("Stopped background audio: \(reason, privacy: .public)")
        closeNetease()
        if dedaoStore.player.current != nil, !dedaoStore.player.paused { dedaoStore.player.pause() }
    }

    // MARK: ⌘Q: quit Mac TV, as Chrome

    /// ⌘Q went down: "Hold ⌘Q to Quit", and Mac TV quits if it's still held when the time is up.
    func quitKeyDown() {
        quitKeyPresses += 1
        let press = quitKeyPresses
        quitKeyHeld = true
        showToast("Hold ⌘Q to Quit")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.quitKeyHold)
            guard let self, self.quitKeyHeld, self.quitKeyPresses == press else { return }
            self.quitKeyHeld = false
            Log.app.notice("Quitting: ⌘Q held")
            self.terminate()
        }
    }

    /// ⌘Q (or ⌘) let go: too soon to quit. The toast fades on its own, as every toast does.
    func quitKeyUp() {
        quitKeyHeld = false
    }
}

// MARK: Views

/// The App Switcher: cards like Home's tiles, side by side, the focused one in the middle, lifted. Each is the app as
/// it was when it went to the background, with its icon and name under it.
struct AppSwitcherView: View {
    @ObservedObject var tv: TVController
    @Environment(\.canvasSize) private var canvas
    private static let card = CGSize(width: 640, height: 360)
    private static let gap: CGFloat = 56

    var body: some View {
        let switcher = tv.appSwitcher ?? AppSwitcher()
        let apps = tv.backgroundApps
        let step = Self.card.width + Self.gap
        HStack(alignment: .top, spacing: Self.gap) {
            ForEach(Array(apps.enumerated()), id: \.element.id) { offset, app in
                card(app, index: offset, switcher: switcher)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(width: canvas.width, alignment: .leading)
        .offset(x: canvas.width / 2 - Self.card.width / 2 - CGFloat(switcher.index) * step)
        .frame(width: canvas.width, height: canvas.height)
        .foregroundStyle(.white)
        .animation(Motion.focus, value: switcher)
        .animation(Motion.focus, value: apps.map(\.id))
    }

    private func card(_ app: Service, index: Int, switcher: AppSwitcher) -> some View {
        let focused = switcher.index == index
        let leaving = app.id == switcher.leaving
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        return Button { tv.appSwitcher?.index = index; tv.chooseInSwitcher(index) } label: {
            VStack(spacing: 22) {
                picture(app)
                    .frame(width: Self.card.width, height: Self.card.height)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(.white.opacity(focused ? 0.9 : 0.12), lineWidth: focused ? 4 : 1))
                    .scaleEffect(focused ? 1.06 : 1)
                    .shadow(color: .black.opacity(focused ? 0.5 : 0.25), radius: focused ? 30 : 14, y: focused ? 20 : 8)
                HStack(spacing: 14) {
                    if let icon = Icons.image(for: app) {
                        Image(nsImage: icon).resizable().scaledToFill()
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    Text(app.name).font(.tv(.callout, emphasized: true)).lineLimit(1)
                }
                .opacity(focused ? 1 : 0.6)
            }
            .offset(y: leaving ? -220 : 0)
            .opacity(leaving ? 0.3 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressDip(presses: switcher.presses, focused: focused))
    }

    @ViewBuilder
    private func picture(_ app: Service) -> some View {
        if let snapshot = tv.appSnapshots[app.id] {
            Image(nsImage: snapshot).resizable().scaledToFill()
        } else {
            // No picture yet (it went to the background before one could be taken): its tile.
            ZStack {
                Artwork(accent: app.accent, deep: app.deep)
                AppTile(service: app, focused: false, tilt: .zero)
            }
        }
    }
}
