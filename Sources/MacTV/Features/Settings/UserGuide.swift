import SwiftUI

/// Mac TV User Guide: Settings › System › User Guide, and Help › Mac TV Help. Plain structured content, kept here so
/// it's easy to update when Mac TV changes. Factual, in the tone of Apple's user guides.
enum UserGuide {
    struct Section: Equatable {
        let title: String
        let symbol: String
        let blocks: [Block]
    }

    enum Block: Equatable {
        case heading(String)
        case paragraph(String)
    }

    static let title = "Mac TV User Guide"

    static let sections: [Section] = [
        Section(title: "Getting Started", symbol: "sparkles.tv", blocks: [
            .paragraph("Mac TV turns your Mac into a TV: your apps on the big screen, driven by a remote from across the room. It runs full screen on the display you choose, and the keyboard and mouse work alongside any remote."),
            .heading("Connect a Remote"),
            .paragraph("Open Control Center and choose Remotes, or go to Settings › Remotes and Devices. Choose iPhone to use your phone as a remote: scan the code with your phone’s camera, or type the pairing code. Choose Siri Remote or Game Controller to pair one in Bluetooth Settings."),
            .paragraph("The first time you open Mac TV, setup offers the same choices. You can connect one, come back and connect another, or choose Set Up Later."),
            .heading("Choose a Display"),
            .paragraph("In Settings › Video and Audio, turn on Full Screen and choose the Preferred Display, such as a TV connected by HDMI."),
        ]),
        Section(title: "Remotes and Controls", symbol: "appletvremote.gen4.fill", blocks: [
            .heading("Back and Home"),
            .paragraph("Press Back to go back one level. At the top level of an app, Back goes to the Home Screen and the app stays in the background, as it was. Press and hold Back to go straight to the Home Screen."),
            .paragraph("Press Home to go straight to the Home Screen. Video pauses; music and audio books keep playing as the app’s own background playback setting says. Opening the app again returns to where you were."),
            .heading("The App Switcher"),
            .paragraph("Press Home twice to see the apps in the background, the most recent first. Press Left or Right to move between them and Select to switch to one. To quit an app, swipe up or press Up on it; the next time you open it, it starts fresh. Press Back to close the App Switcher; when you quit the last app, it closes on its own."),
            .paragraph("To quit Mac TV, press and hold Command-Q. A quick press shows “Hold ⌘Q to Quit”."),
            .heading("Menus"),
            .paragraph("Press and hold Select on a video, song, or app for its menu. On the Home Screen, holding Select on an app shows Edit Home Screen, Hide and, for apps you added, Delete for Everyone. Press and hold Home to open Control Center."),
            .heading("Siri Remote"),
            .paragraph("Press the clickpad ring or swipe on the clickpad to move, and click the center to select. Back, TV (Home; press it twice for the App Switcher), Play/Pause and the volume buttons work as on Apple TV. Swipe left or right while a video plays to move through it."),
            .heading("iPhone"),
            .paragraph("The phone remote has a clickpad with a wheel around it, Back, Home and Play/Pause, a trackpad mode for the pointer, Type on TV for entering text, and shortcuts for the app on screen."),
            .heading("Keyboard"),
            .paragraph("Use the arrow keys to move, Return or Space to select, Esc for Back, and the Home key (Fn-Left Arrow) for Home; press it twice for the App Switcher. Hold Return for menus. Type into search and text fields directly; Command-V pastes."),
            .heading("Game Controller"),
            .paragraph("The D-pad or left stick moves, A selects, B is Back (hold it for Home), X plays or pauses, the Menu button is Home (press it twice for the App Switcher), and the shoulder buttons skip back and forward."),
            .heading("Trackpad and Mouse"),
            .paragraph("Swipe with two fingers on a trackpad to move through rows, as on the Siri Remote’s clickpad. Click an item to select it. Moving the mouse shows the pointer; pressing a key hides it again."),
        ]),
        Section(title: "The Home Screen", symbol: "square.grid.3x3.fill", blocks: [
            .heading("The Dock and the Top Shelf"),
            .paragraph("The top row of apps is the dock. When an app in the dock has focus, the Top Shelf above it shows what that app offers: what you’re watching or listening to, and picks from it. Choose what each app shows in Settings › Apps › Top Shelf."),
            .heading("Arrange Apps"),
            .paragraph("Press and hold Select on an app on the Home Screen and choose Edit Home Screen, or go to Settings › Apps › Arrange Apps. Select an app, move it with the arrow keys or the remote, and select again to put it down. Press and hold Select to hide an app."),
            .heading("Add Apps"),
            .paragraph("Choose Add App on the Home Screen or in Settings › Apps to add a website, a Mac app, or a Steam game."),
            .heading("Profiles"),
            .paragraph("Choose your picture at the top right of the Home Screen to switch profiles. Each profile has its own apps on the Home Screen, its own sign-ins and history, and its own settings."),
        ]),
        Section(title: "Control Center", symbol: "switch.2", blocks: [
            .paragraph("Press and hold Home, or choose the Control Center button at the top right of the Home Screen."),
            .paragraph("Control Center has Sleep Now; Remotes, Display, Audio and Sleep Timer; and buttons for the screen saver, turning off the display, keeping the Mac awake (or awake with the lid closed), and Settings. Press Back to close it."),
        ]),
        Section(title: "Apps", symbol: "square.stack.fill", blocks: [
            .heading("Web"),
            .paragraph("Web opens to a start page with Favorites, Frequently Visited, Recently Visited, and your Safari Reading List. Select the address field to type an address or search."),
            .paragraph("The tab bar at the top of a page shows your tabs. Press and hold Select for New Private Tab, Reload Page, Zoom, Close Tab, Show All History, and Add to Favorites. Private tabs keep no history. Your tabs stay when you quit Web and come back next time."),
            .paragraph("On a keyboard, Web uses Safari’s shortcuts: Command-T for a new tab, Shift-Command-N for a private tab, Command-L for the address, Command-W to close a tab, Command-[ and Command-] for back and forward, Shift-Command-[ and Shift-Command-] to switch tabs, Command-Plus, Command-Minus and Command-0 to zoom, and Command-Y for history. The phone remote has the same actions as shortcuts."),
            .heading("Movies"),
            .paragraph("Movies shows the videos in folders on your Mac, on network shares, and on Jellyfin servers. Add sources in Settings › Apps › Movies: Add Folder…, Add Network Share…, or Sign In to Jellyfin…. Mac TV remembers where you stopped each movie."),
            .heading("哔哩哔哩"),
            .paragraph("Press Left at the edge of a row for the sidebar. Hold Select on a video for its menu. While a video plays, hold Select for the panel with likes, coins, favorites, speed and subtitles."),
            .heading("网易云音乐"),
            .paragraph("Hold Select on a song or playlist for its menu. While a song plays, hold Left or Right to rewind or fast-forward. Background playback is in the app’s own settings."),
            .heading("得到"),
            .paragraph("Select a book or course to listen. While it plays, hold Select for speed, the sleep timer and the list of lectures; hold Left or Right to skip through."),
            .heading("YouTube"),
            .paragraph("YouTube opens the TV version of YouTube. Use the arrow keys or remote to move, Select to play, and Back to go back."),
        ]),
        Section(title: "Screen Saver", symbol: "sparkles.tv.fill", blocks: [
            .paragraph("When nothing is playing, the screen saver starts after the time set in Settings › Screen Saver › Start After. Choose Aerials, My Photos, Drifting Color or Flip Clock. To start it yourself, press Back on the first app in the top row of the Home Screen. Press any button to return to where you were."),
            .paragraph("Flip Clock and the other clocks on Mac TV follow 24-Hour Time, in Settings › General or on the Screen Saver page when Flip Clock is chosen."),
        ]),
        Section(title: "Profiles and Accounts", symbol: "person.2.fill", blocks: [
            .paragraph("Go to Settings › Profiles and Accounts to add a profile, rename one, choose a photo for it, or remove it. Removing a profile removes its apps, sign-ins and settings from this Mac."),
            .paragraph("Profiles share the apps you add and the Mac’s own settings, such as the display and power. Each profile keeps its own sign-ins to 哔哩哔哩, 网易云音乐, 得到 and websites."),
        ]),
        Section(title: "Settings", symbol: "gearshape.fill", blocks: [
            .paragraph("General: 24-Hour Time, Sleep Timer, Open at Login, and playback options such as Skip Intros, Recaps and Ads."),
            .paragraph("Profiles and Accounts: who watches on this Mac."),
            .paragraph("Video and Audio: Full Screen, the Preferred Display, Audio Output and Navigation Clicks."),
            .paragraph("Screen Saver: the type, when it starts, and its options."),
            .paragraph("Remotes and Devices: Siri Remote, iPhone and game controllers."),
            .paragraph("Apps: Add App, Arrange Apps, Top Shelf, and Movies’ sources."),
            .paragraph("System: this guide, About, Software Updates, and power: Keep Mac Awake, Stay Awake With Lid Closed, Turn Off Display and Sleep Now."),
        ]),
        Section(title: "Privacy and Data", symbol: "hand.raised.fill", blocks: [
            .paragraph("Mac TV keeps its data on this Mac: your profiles, apps, settings and history, in its folder in Application Support, and sign-ins in your keychain. It has no account of its own and sends nothing about you anywhere."),
            .paragraph("The phone remote connects over your local network (or Tailscale), with a pairing code. Remove a paired phone in Settings › Remotes and Devices › iPhone."),
            .paragraph("Copy Diagnostics Report puts a report on the clipboard and nowhere else. It leaves out what you watch, titles, addresses, and file and profile names."),
        ]),
        Section(title: "Troubleshooting", symbol: "wrench.and.screwdriver.fill", blocks: [
            .heading("No Sound After Switching Outputs"),
            .paragraph("Open Control Center, choose Audio, and choose the output again. If the TV is connected by HDMI, check that the TV’s own volume isn’t muted."),
            .heading("The Remote Doesn’t Respond"),
            .paragraph("For the phone remote, check that the phone is on the same network as the Mac, then scan the code again in Settings › Remotes and Devices › iPhone. For a Siri Remote, check its Status in Settings › Remotes and Devices › Siri Remote."),
            .heading("Needs Input Monitoring"),
            .paragraph("A Siri Remote’s buttons reach Mac TV only when Mac TV is allowed in System Settings › Privacy & Security › Input Monitoring. If the remote’s Status says Needs Input Monitoring, select it to open that pane."),
            .heading("Other Problems"),
            .paragraph("Choose Help › Copy Diagnostics Report, or System › About › Copy Diagnostics Report in Settings, and include the report when you report a problem."),
        ]),
    ]
}

extension TVController {
    /// Help › Mac TV Help: Settings › System › User Guide, over Home.
    func openUserGuide() {
        if mode != .launcher || activeSheet != nil || movies != nil { goHome() }
        openSettings(to: .userGuide)
        openSettingsPage(.userGuide)
    }

    /// A guide page: Up and Down scroll a paragraph at a time; Back, or Left, returns to the list.
    func readGuide(_ command: RemoteCommand, _ panel: SettingsPanel) {
        guard case .guideSection(let index) = panel.page, UserGuide.sections.indices.contains(index) else { return }
        let last = UserGuide.sections[index].blocks.count - 1
        switch command {
        case .back, .move(.left): closeSettingsPage()
        case .move(.up): if panel.row > 0 { pages?.row = panel.row - 1 }
        case .move(.down): if panel.row < last { pages?.row = panel.row + 1 }
        default: break
        }
    }
}

/// A guide page: headings and short paragraphs at TV reading size, scrolled with the remote a paragraph at a time.
struct UserGuidePage: View {
    let section: UserGuide.Section
    /// The paragraph at the top.
    let top: Int
    @Environment(\.canvasSize) private var canvas

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(section.blocks.enumerated()), id: \.offset) { index, block in
                        Group {
                            switch block {
                            case .heading(let text):
                                Text(text).font(.tv(.callout, emphasized: true)).padding(.top, index == 0 ? 0 : 14)
                            case .paragraph(let text):
                                Text(text).font(.tv(.body)).lineSpacing(6).opacity(0.85)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(index)
                    }
                }
                .padding(.top, SettingsMetrics.belowStatusBar + 50)
                .padding(.bottom, 120)
            }
            .scrollDisabled(true)
            .frame(height: canvas.height)
            .belowStatusBar()
            .onAppear { scroller.scrollTo(top, anchor: .top) }
            .onChange(of: top) { _, top in
                // The paragraph lands just under the faded band below the status bar.
                let below = UnitPoint(x: 0, y: (SettingsMetrics.belowStatusBar + 56) / max(canvas.height, 1))
                withAnimation(Motion.navigate) { scroller.scrollTo(top, anchor: top == 0 ? .top : below) }
            }
        }
    }
}
