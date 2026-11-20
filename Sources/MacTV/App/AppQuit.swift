import AppKit
import SwiftUI
import WebKit

// Back, the TV button and the App Switcher, the same in every app on Mac TV (哔哩哔哩, 网易云音乐, 得到, YouTube, Movies,
// Web and the website apps), as on Apple TV (docs/custom/interaction-spec.md):
//
// | Input | What it does |
// |---|---|
// | Back (Esc, the Siri Remote's and phone's Back, a controller's B) | Back one level; at an app's top level, the Home Screen, with the app kept; on Home's first app, the screen saver |
// | Holding Back | The Home Screen from anywhere, with the app kept (not a TV press: it doesn't count toward a double press) |
// | The TV button (the Siri Remote's and phone's, ⌘H, the Home key, a controller's Menu or Home) | The Home Screen at once, with the app kept: music and audio books keep playing, video pauses |
// | The TV button twice (the same device) | The App Switcher, on the app it was pressed in. Back or TV leaves it for exactly where that was; Up quits an app; Select switches |
// | Holding the TV button | Control Center, over whatever is in front; TV or Back closes it, back to that |
// | ⌘Q | As Chrome: a press shows "Hold ⌘Q to Quit" (Mac TV's own toast); holding it quits Mac TV |
//
// The Quit Mac TV menu item quits at once, as Chrome's does, and so do a logout, restart, shutdown and the updater's
// relaunch: only the ⌘Q key holds.

/// A press of the TV button, kept for a moment: a second one from the same device opens the App Switcher.
struct TVPress {
    let time: Date
    let source: Feedback.Source
    /// What was in front before it: the App Switcher opens on it, and leaving the switcher goes back to it.
    let origin: String?
}

/// Home answering a TV press that has nothing to do, as an iPhone's Home Screen does. Pressed on Home: its apps
/// give a small bounce. Pressed twice with no app in the background: Home blurs and comes back, an App Switcher with
/// nothing in it. `count` makes each press play again.
struct HomeNudge: Equatable {
    enum Kind: Equatable { case bounce, nothingInBackground }
    var kind = Kind.bounce
    var count = 0
}

/// The App Switcher: every open app, most recent first; the one it was opened from first (Mac TV decision).
struct AppSwitcher: Equatable {
    /// The focused card: an index into `TVController.backgroundApps`.
    var index = 0
    /// The app it was opened from (nil: Home). Back or TV with nothing chosen goes back to it.
    var origin: String?
    /// The app whose card is sliding up as it quits.
    var leaving: String?
    /// Select or a click: the focused card dips and settles back each time this goes up.
    var presses = 0
}

extension TVController {
    /// How long ⌘Q is held before Mac TV quits, as Chrome's "Hold ⌘Q to Quit".
    static let quitKeyHold: Duration = .milliseconds(1500)
    /// How long a quitting card takes to slide up before the others close the gap.
    static let switcherQuitSlide: Duration = .milliseconds(280)

    /// The app in front, if any: the one Home sends to the background.
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

    /// A TV press: the Home Screen at once (no waiting to see if a second press comes). A second press from the same
    /// device soon after opens the App Switcher on the app the first one left. A press that closes Control Center
    /// or the App Switcher does only that, and doesn't count toward a double press.
    func pressTV(from source: Feedback.Source, at now: Date = Date()) {
        if sheets.top == .controlCenter {
            controlCenter = nil
            lastTVPress = nil
            return
        }
        if appSwitcher != nil {
            leaveAppSwitcher()
            lastTVPress = nil
            return
        }
        if let last = lastTVPress, last.source == source, now.timeIntervalSince(last.time) < InputTiming.doublePress {
            lastTVPress = nil
            if backgroundApps.isEmpty { nudgeHome(.nothingInBackground) } else { openAppSwitcher(returningTo: last.origin) }
            return
        }
        let origin = appInFront?.id
        let onHomeAlready = origin == nil && mode == .launcher && activeSheet == nil
        goHome()
        if onHomeAlready { nudgeHome(.bounce) }
        lastTVPress = TVPress(time: now, source: source, origin: origin)
    }

    /// The TV button held: Control Center, over whatever is in front (held again, it closes). Over the App Switcher,
    /// the switcher goes first (back to where it was opened). Another app's window (IINA, Brave, a Mac app, a game)
    /// can't have Mac TV drawn over it: there Mac TV comes to the front, on Home.
    func holdTV() {
        guard setup == nil, profilePicker == nil else { return }
        lastTVPress = nil
        if controlCenter != nil {
            sheets.closeDismissible()   // with whatever it opened over itself
            return
        }
        if appSwitcher != nil { leaveAppSwitcher() }
        if playbackCoordinator.iinaOpen || externalBrowser != nil || frontAppTakesKeys { goHome() }
        sheets.closeDismissible()
        openControlCenter()
        bringToFront()
    }

    /// Back held: the Home Screen from anywhere, with the app kept, closing whatever is open over it.
    func holdBack() {
        lastTVPress = nil
        goHome()
    }

    /// The App Switcher, on `origin`'s card (the app the first TV press left), or the most recent app from Home.
    /// Nothing open: nothing to switch to, so it doesn't open.
    /// Home's answer to a press with nothing to do (see HomeNudge).
    func nudgeHome(_ kind: HomeNudge.Kind) {
        homeNudge = HomeNudge(kind: kind, count: homeNudge.count + 1)
    }

    func openAppSwitcher(returningTo origin: String?) {
        guard !backgroundApps.isEmpty else { return }
        let index = origin.flatMap { id in backgroundApps.firstIndex { $0.id == id } } ?? 0
        appSwitcher = AppSwitcher(index: index, origin: origin)
    }

    /// Back, or a TV press, with nothing chosen: back to exactly where the switcher was opened from, the app as it
    /// was or Home. If that app was quit meanwhile, Home.
    func leaveAppSwitcher() {
        let origin = appSwitcher?.origin
        appSwitcher = nil
        if let origin, let app = backgroundApps.first(where: { $0.id == origin }) { open(app) }
    }

    /// Left and Right move along the cards; Select switches to one; Up quits it; Back leaves (see leaveAppSwitcher).
    func handleAppSwitcher(_ command: RemoteCommand) {
        guard var switcher = appSwitcher else { return }
        let last = backgroundApps.count - 1
        switch command {
        case .move(.left): switcher.index = max(0, switcher.index - 1)
        case .move(.right): switcher.index = max(0, min(last, switcher.index + 1))
        case .move(.up) where backgroundApps.indices.contains(switcher.index) && switcher.leaving == nil:
            quitFromSwitcher(backgroundApps[switcher.index])
            return
        case .select where switcher.leaving == nil:   // a card on its way out is quitting, not to be chosen
            switcher.presses += 1
            appSwitcher = switcher
            chooseInSwitcher(switcher.index)
            return
        case .back:
            leaveAppSwitcher()
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

    /// Home is about to send the app in front to the background: it moves to the front of the App Switcher, with a
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
                MainActor.assumeIsolated {
                    // Late: only for an app that's still open (one quit meanwhile has no card)
                    guard let self, let image, self.backgroundApps.contains(where: { $0.id == id }) else { return }
                    self.appSnapshots[id] = image
                }
            }
            return
        }
        // The window's layers as they're already drawn, composited straight to card size. It runs before Home shows,
        // so it must be quick: `cacheDisplay` redrew the whole window at full resolution first, seconds with glass
        // and artwork, and the TV button waited for it.
        guard let view = window?.contentView, let layer = view.layer, view.bounds.width > 1 else { return }
        let pixels = (width: Int(width), height: Int((width * view.bounds.height / view.bounds.width).rounded()))
        guard let context = CGContext(data: nil, width: pixels.width, height: pixels.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        if layer.isGeometryFlipped {
            context.translateBy(x: 0, y: CGFloat(pixels.height))
            context.scaleBy(x: 1, y: -1)
        }
        context.scaleBy(x: CGFloat(pixels.width) / view.bounds.width, y: CGFloat(pixels.height) / view.bounds.height)
        layer.render(in: context)
        guard let picture = context.makeImage() else { return }
        appSnapshots[id] = NSImage(cgImage: picture, size: NSSize(width: pixels.width, height: pixels.height))
    }

    /// Quits an app (from the App Switcher, a profile switch): everything it was playing stops (positions saved and
    /// play reports sent first, as each app does), and everything it held goes: web views, players, what it had
    /// loaded, its snapshot. Next time it opens fresh, as if it had just launched; Web's tabs come back, as Safari's do.
    func quitApp(_ id: String, reason: String) {
        switch id {
        case BilibiliStore.appID: quitBilibili()
        case NeteaseStore.appID: closeNetease(); neteaseStore.quit()
        case DedaoStore.appID: closeDedao()
        case BrowserStore.appID: closeBrowser(); browserStore.closePrivateTabs()
        case "movies":
            movies = nil
            moviesWork.stop()
            playbackCoordinator.quitMovies()
        default: break
        }
        // Website apps, and Web's page: the page in front, or the one kept in the background.
        if case .player(let service) = mode,
           service.id == id || (id == BrowserStore.appID && service.id == BrowserStore.pageID)
            || (id == BilibiliStore.appID && service.id == BilibiliStore.loginID)
            || (id == NeteaseStore.appID && service.id == NeteaseStore.loginID) {
            playbackCoordinator.closeWebPlayback()
            setMode(.launcher)   // the app quit was in front: Home
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
            bilibiliStore.closeLogin()   // its QR code stops being polled; opening 哔哩哔哩 again shows where it was
            bilibiliOpen = false
            BiliImageCache.shared.trim()   // decoded covers (up to 64 MB) come back from the network cache on return
        }
        leaveNetease()
        if dedaoOpen {
            dedaoStore.backgrounded()
            dedaoOpen = false
        }
        closeBrowser()
        playbackCoordinator.parkWebPlayback()
    }

    /// Back went into a web page as Escape (YouTube's TV page and the other apps that move with their own keys), and
    /// the page had nothing to close with it: that's the app's top level, so Back goes Home with the app kept, as
    /// everywhere else. (Unhandled, AppKit would have taken that Escape to leave full screen; see TVWindow.)
    func pageLetBackThrough() {
        guard case .player(let service) = mode, webView != nil else { return }
        Log.app.info("Back at the top of \(service.id, privacy: .public): Home")
        if service.id == BrowserStore.pageID { returnToBrowser() } else { goHome() }
    }

    /// Something started to play (a video, a song, a lecture): music or an audio book in the background pauses, so
    /// only one thing plays. Opening an app doesn't do this; playing does.
    func startedPlaying(_ appID: String) {
        if appID != NeteaseStore.appID { neteaseStore.pauseIfPlaying() }
        if appID != DedaoStore.appID { dedaoStore.player.pause() }
    }

    /// A held Left or Right let go: the seek ends where it got to, in 网易云 or 得到, whichever started it, even if it
    /// has gone to the background since (both ends do nothing when that app isn't seeking).
    func endHoldSeek() {
        dedaoStore.endHold()
        neteaseStore.endScrub()
    }

    /// Someone else starts watching: what Home kept in the background is the last person's, so it quits (the apps
    /// that keep data per profile stop and save through their own profile hooks).
    func quitBackgroundApps(reason: String) {
        Log.app.notice("Quit the apps in the background: \(reason, privacy: .public)")
        playbackCoordinator.quitMovies()
        playbackCoordinator.closeExternalBrowser()
        playbackCoordinator.dropParkedWeb()
        backgroundApps = []
        appSnapshots = [:]
    }

    // MARK: Memory pressure: the one place that gives memory back

    /// Listens for macOS's memory pressure (warning and critical) for as long as Mac TV runs. This Mac runs other
    /// services too, so Mac TV gives memory back at the warning, not only when it's critical. Nothing else in Mac TV
    /// has a limit: apps stay in the background as long as memory allows.
    func startMemoryPressureWatch() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            MainActor.assumeIsolated {
                guard let event = source?.data else { return }
                self?.memoryPressure(critical: event.contains(.critical))
            }
        }
        source.activate()
        memoryPressureSource = source
    }

    /// Warning: decoded pictures go (they come back from disk), and the least recently used background web page is
    /// released. Critical: every background web page. A released app keeps its switcher card and picture, and opens
    /// again where it was (see PlaybackCoordinator.reclaimWeb). Sign-ins, cookies and stored data are never touched,
    /// and nothing in front is.
    func memoryPressure(critical: Bool) {
        Log.app.notice("Memory pressure (\(critical ? "critical" : "warning", privacy: .public)): giving memory back")
        BiliImageCache.shared.trim()
        movieLibrary.artwork.trim()
        browserStore.trimMemory()
        let parked = playbackCoordinator.parkedWebIDs
        let leastRecentFirst = backgroundApps.reversed().map(\.id).filter(parked.contains)
        for id in critical ? leastRecentFirst : Array(leastRecentFirst.prefix(1)) { playbackCoordinator.reclaimWeb(id) }
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
