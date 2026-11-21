import SwiftUI

struct RootView: View {
    @ObservedObject var tv: TVController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if tv.externalBrowser != nil {
                TVCanvas { BravePlaybackView(tv: tv) }.ignoresSafeArea()
            } else if case .player(let service) = tv.mode, let web = tv.webView {
                if service.id == BrowserStore.pageID {
                    // 浏览器：上面一条标签栏，网页在它下面（见 BrowserChrome）
                    BrowserPageView(store: tv.browserStore, web: web, failed: tv.playerFailure != nil)
                } else {
                    WebViewHost(webView: web).id(ObjectIdentifier(web))
                        .allowsHitTesting(tv.playerFailure == nil)
                        .accessibilityHidden(tv.playerFailure != nil)
                }
                if tv.playerFailure != nil {
                    TVCanvas { PlaybackFailureView(tv: tv) }.ignoresSafeArea()
                }
            } else if tv.mode == .movie, let player = tv.moviePlayer {
                MoviePlayerView(player: player).id(ObjectIdentifier(player))
            } else {
                if tv.bilibiliOpen {
                    BilibiliRoot(store: tv.bilibiliStore)
                        .allowsHitTesting(tv.activeSheet == nil && !tv.screensaver)
                } else if tv.neteaseOpen {
                    NeteaseRoot(store: tv.neteaseStore)
                        .allowsHitTesting(tv.activeSheet == nil && !tv.screensaver)
                } else if tv.browserOpen {
                    BrowserRoot(store: tv.browserStore)
                        .allowsHitTesting(tv.activeSheet == nil && !tv.screensaver)
                } else if tv.dedaoOpen {
                    DedaoRoot(store: tv.dedaoStore)
                        .allowsHitTesting(tv.activeSheet == nil && !tv.screensaver)
                } else if tv.movies != nil {
                    // Opaque, and the only screen drawn, so nothing shows through on the way back from a movie.
                    TVCanvas { MoviesScreen(tv: tv) }
                        .ignoresSafeArea()
                        .allowsHitTesting(tv.activeSheet == nil && !tv.screensaver)
                        .accessibilityHidden(tv.activeSheet != nil || tv.screensaver)
                } else if !tv.screensaver {
                    ZStack {
                        Wallpaper().ignoresSafeArea()
                        TVCanvas { HomeView(tv: tv).modifier(HomeBounce(nudge: tv.homeNudge)) }
                            .ignoresSafeArea()
                            // A Home Screen app's menu is on Home itself (see AppOrganizer.onHome): Home takes its clicks.
                            .allowsHitTesting((tv.activeSheet == nil || tv.organizer?.onHome == true) && !tv.screensaver)
                            .accessibilityHidden(tv.activeSheet != nil || tv.screensaver)
                    }
                    // Home's status row, a layer above the dim of a panel opened from it (see HomeStatusRow). Home's
                    // topmost layer, so the App Switcher's backdrop finding nothing comes over it too.
                    TVCanvas { HomeStatusRow(tv: tv).modifier(HomeBounce(nudge: tv.homeNudge)) }
                        .ignoresSafeArea()
                        .allowsHitTesting(tv.activeSheet == nil && !tv.screensaver)
                        .accessibilityHidden(tv.activeSheet != nil || tv.screensaver)
                        .modifier(HomeEmptySwitcher(nudge: tv.homeNudge))
                        .zIndex(ModalSheetRouter.statusRowLayer)
                }
            }
            // Sheets over whatever is in front: Home, an app, a web page or a movie (Control Center opens over them)
            ModalSheetRouter(tv: tv)
            if tv.screensaver {
                TVCanvas { Screensaver(idle: tv.idleCoordinator) }
                    .ignoresSafeArea()
                    .transition(.opacity.animation(.easeInOut(duration: 1.2)))
                    .zIndex(100)   // 在所有弹出的面板上面（面板有固定的层级，见 ModalSheetRouter）
            }

            NoticesOverlay(notices: tv.notices)
            JasmineOverlay(jasmine: tv.jasmine)
        }
        .environment(\.colorScheme, .dark)
        .background(Color.black.ignoresSafeArea())
        .animation(Motion.appear, value: tv.sheets.open)
        .animation(Motion.appear, value: tv.movies != nil)
        .animation(Motion.appear, value: tv.bilibiliOpen)
        .animation(Motion.appear, value: tv.neteaseOpen)
        .animation(Motion.appear, value: tv.browserOpen)
        .animation(Motion.appear, value: tv.dedaoOpen)
        .animation(.easeInOut(duration: 1.2), value: tv.screensaver)
    }
}

/// Draws the open sheets, bottom to top. Only the top one takes the pointer and VoiceOver.
struct ModalSheetRouter: View {
    @ObservedObject var tv: TVController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The layers, bottom to top: the screen in front (0), the dim of a panel (Control Center, the profiles dropped
    /// from the avatar), Home's status row, then each sheet at 1 + its own number. A panel only ever opens over Home
    /// or an app, never over another sheet, so its dim sits under the status row and that row stays bright.
    static let panelDimLayer = 0.25
    static let statusRowLayer = 0.5

    var body: some View {
        // Arrange Apps isn't drawn while a Home Screen app's menu is open on Home (see AppOrganizer.onHome).
        ForEach(tv.sheets.open.filter { $0 != .organizer || tv.organizer?.onHome != true }, id: \.self) { layer in
            // Control Center is a panel (DesignSystem/Layers): the screen behind dims, fading while the panel drops
            // in, and a click on it closes Control Center.
            if isPanel(layer) {
                DimBackdrop { layer == .controlCenter ? (tv.controlCenter = nil) : (tv.profilePicker = nil) }
                    .allowsHitTesting(tv.isTopSheet(layer))
                    .transition(.opacity)
                    .zIndex(Self.panelDimLayer)
            }
            TVCanvas { sheet(layer) }
                .ignoresSafeArea()
                .allowsHitTesting(tv.isTopSheet(layer))
                .accessibilityHidden(!tv.isTopSheet(layer))
                .background { if !isPanel(layer) { SheetBackdrop() } }
                .transition(transition(layer))
                // 固定的层级：不然收起时 SwiftUI 把它挪到主屏下面，收回去的动画被挡住，看起来是一下子没了
                .zIndex(1 + Double(layer.rawValue))
        }
    }

    @ViewBuilder
    private func sheet(_ layer: SheetStack.Layer) -> some View {
        switch layer {
        case .controlCenter: ControlCenterView(tv: tv)
        case .settings: SettingsSheet(tv: tv)
        case .organizer: AppOrganizerSheet(tv: tv)
        case .pairing: PairSheet(tv: tv)
        case .addApp: AddAppSheet(tv: tv)
        case .topShelfPreferences: TopShelfPreferencesSheet(tv: tv)
        case .audioPicker: AudioPickerSheet(tv: tv)
        case .displayPicker: DisplayPickerSheet(tv: tv)
        case .appSwitcher: AppSwitcherView(tv: tv)
        case .search: SystemSearchSheet(tv: tv)
        case .profilePicker:
            if tv.profilePicker?.dropdown == true { ProfileDropdown(tv: tv) } else { ProfilesScreen(tv: tv) }
        case .setup: SetupScreen(tv: tv)
        }
    }

    /// Panels over Home's status row (Control Center, the profiles dropped down from the avatar): Home stays, dimmed.
    private func isPanel(_ layer: SheetStack.Layer) -> Bool {
        layer == .controlCenter || (layer == .profilePicker && tv.profilePicker?.dropdown == true)
    }

    /// Control Center drops from the top like tvOS's; full-screen flows fade; the rest settle in.
    private func transition(_ layer: SheetStack.Layer) -> AnyTransition {
        switch layer {
        case .controlCenter: .move(edge: .top)
        case .profilePicker, .setup: .opacity
        default: Motion.sheet(reduceMotion: reduceMotion)
        }
    }
}
