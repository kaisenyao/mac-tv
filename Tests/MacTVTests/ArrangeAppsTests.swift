import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MacTV

/// Arrange Apps on the TV shows Home as it is: the dock (Home's first six apps) and the rows below. Select picks
/// an app up, the D-pad moves it, Select puts it down and Back puts it back; press and hold for Hide, and Delete
/// for Everyone on an app someone added. After Select, Home shows exactly what Arrange Apps showed.
@Suite(.timeLimit(.minutes(1))) @MainActor
struct ArrangeAppsTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func withFolder(_ body: (URL) throws -> Void) throws {
        let folder = Self.root.appendingPathComponent("work/tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder)
    }

    /// A Home with two rows: the built-in apps and four added sites.
    private func twoRows(_ folder: URL) -> TVController {
        let library = AppLibrary(folder: folder)
        for n in 1...4 { library.add(name: "Site \(n)", url: URL(string: "https://site\(n).example"), bundleID: nil) }
        return TVController(library: library)
    }

    private func select(_ tv: TVController, _ id: String) { tv.organizer?.selectedID = id }

    private var dock: Int { AppLibrary.dockSize }

    @Test func arrangeAppsShowsHomeAndHomeShowsWhatArrangeAppsShowed() throws {
        try withFolder { folder in
            let tv = twoRows(folder)
            tv.openOrganizer()
            #expect(tv.organizerOrder == tv.services.filter { $0.kind != .addApp && $0.kind != .settings }.map(\.id))
            #expect(tv.organizerOrder.count > dock, "a full dock and apps below it; never an empty frame beside a full top row")
            select(tv, tv.appOrder[dock + 1])
            tv.handleOrganizer(.select)
            tv.handleOrganizer(.move(.up))
            tv.handleOrganizer(.move(.left))
            let shown = tv.organizerOrder
            tv.handleOrganizer(.select)
            #expect(tv.services.prefix(shown.count).map(\.id) == shown, "Home shows exactly what Arrange Apps showed")
            #expect(AppLibrary(folder: folder).arrangement() == shown)
        }
    }

    @Test func intoAFullDockItsLastAppGoesBelowUntilTheAppLeaves() throws {
        try withFolder { folder in
            let tv = twoRows(folder)
            let before = tv.appOrder
            let moving = before[dock + 2]
            tv.openOrganizer()
            select(tv, moving)
            tv.handleOrganizer(.select)
            #expect(tv.organizer?.lift?.id == moving)

            // Up from the row below: into the dock at the same column; the dock's last app moves below.
            tv.handleOrganizer(.move(.up))
            var shown = tv.organizerOrder
            #expect(Array(shown.prefix(dock)) == Array(before.prefix(2)) + [moving] + before[2..<5])
            #expect(shown[dock] == before[5])
            #expect(tv.appOrder == before, "nothing is saved while the app is still moving")

            // Down again: out of the dock, and the app that went below comes back.
            tv.handleOrganizer(.move(.down))
            #expect(tv.organizerOrder == before)

            // In again, one place left, and down it goes.
            tv.handleOrganizer(.move(.up))
            tv.handleOrganizer(.move(.left))
            shown = tv.organizerOrder
            #expect(shown[1] == moving)
            tv.handleOrganizer(.select)
            #expect(tv.organizer?.lift == nil && tv.organizer?.selectedID == moving)
            #expect(tv.appOrder == shown)
            #expect(tv.appOrder[dock] == before[5])
        }
    }

    @Test func outOfTheDockTheFirstAppBelowComesUp() throws {
        try withFolder { folder in
            let tv = twoRows(folder)
            let before = tv.appOrder
            tv.openOrganizer()
            select(tv, before[0])
            tv.handleOrganizer(.select)
            tv.handleOrganizer(.move(.up))           // nothing above the dock
            tv.handleOrganizer(.move(.left))         // nor left of its first place
            #expect(tv.organizer?.lift?.index == 0)
            for _ in 0..<8 { tv.handleOrganizer(.move(.right)) }
            #expect(tv.organizer?.lift?.index == dock - 1, "the dock's row ends at six")
            tv.handleOrganizer(.move(.down))
            #expect(tv.organizer?.lift?.index == min(2 * dock - 1, before.count - 1))
            tv.handleOrganizer(.select)
            #expect(Array(tv.appOrder.prefix(dock)) == Array(before[1...dock]), "the first app below came up into the dock")
            #expect(!tv.appOrder.prefix(dock).contains(before[0]))
        }
    }

    @Test func backPutsTheAppBackAndThenCloses() throws {
        try withFolder { folder in
            let tv = twoRows(folder)
            let before = tv.appOrder
            tv.openOrganizer()
            select(tv, before[dock])
            tv.handleOrganizer(.select)
            tv.handleOrganizer(.move(.up))
            tv.handleOrganizer(.move(.right))
            #expect(tv.organizerOrder != before)
            tv.handleOrganizer(.back)
            #expect(tv.organizer != nil && tv.organizer?.lift == nil, "Back first cancels the move")
            #expect(tv.organizerOrder == before && tv.appOrder == before)
            #expect(tv.organizer?.selectedID == before[dock])
            tv.handleOrganizer(.back)
            #expect(tv.organizer == nil)
        }
    }

    @Test func theDPadMovesAsOnHome() {
        let step = { (index: Int, direction: RemoteCommand.Direction) in AppOrganizer.step(from: index, direction, count: 10) }
        #expect(step(5, .right) == nil, "rows end at six")
        #expect(step(2, .down) == 8)
        #expect(step(4, .down) == 9, "down to a shorter last row lands on its last app")
        #expect(step(8, .up) == 2)
        #expect(step(0, .up) == nil && step(0, .left) == nil)
        #expect(step(9, .right) == nil)
    }

    @Test func pressAndHoldOffersHideAndDeleteForEveryoneForAnAddedApp() throws {
        try withFolder { folder in
            let library = AppLibrary(folder: folder)
            let site = library.add(name: "Example", url: URL(string: "https://example.com"), bundleID: nil).id
            let tv = TVController(library: library)
            tv.openOrganizer()
            let order = tv.appOrder
            let youtube = try #require(order.firstIndex(of: "youtube"))

            // A built-in app: Hide only, and it hides at once; focus goes to the app that follows.
            select(tv, "youtube")
            #expect(tv.organizerActions(for: "youtube") == [.hide])
            #expect(tv.holdSelect(from: .keyboard))
            #expect(tv.organizer?.menu == .actions(row: 0))
            #expect(tv.holdSelect(from: .keyboard), "holding again closes the menu")
            #expect(tv.organizer?.menu == nil)
            #expect(tv.holdSelect(from: .keyboard))
            tv.handleOrganizer(.move(.down))
            #expect(tv.organizer?.menu == .actions(row: 0) && tv.organizer?.lift == nil)
            tv.handleOrganizer(.select)
            #expect(!tv.appOrder.contains("youtube") && library.isHidden("youtube"))
            #expect(tv.organizer?.selectedID == order[youtube + 1])

            // An app someone added: Hide, or Delete for Everyone, which asks first, starting on Cancel.
            select(tv, site)
            #expect(tv.organizerActions(for: site) == [.hide, .deleteForEveryone])
            #expect(tv.holdSelect(from: .keyboard))
            tv.handleOrganizer(.move(.down))
            tv.handleOrganizer(.select)
            #expect(tv.organizer?.menu == .confirmDelete(row: AppOrganizer.Menu.cancelRow))
            tv.handleOrganizer(.select)
            #expect(tv.organizer?.menu == nil && tv.appOrder.contains(site), "Cancel keeps it")
            #expect(tv.holdSelect(from: .keyboard))
            tv.handleOrganizer(.move(.down))
            tv.handleOrganizer(.select)
            tv.handleOrganizer(.back)
            #expect(tv.organizer?.menu == nil && tv.appOrder.contains(site), "Back keeps it")
            #expect(tv.holdSelect(from: .keyboard))
            tv.handleOrganizer(.move(.down))
            tv.handleOrganizer(.select)
            tv.handleOrganizer(.move(.down))
            #expect(tv.organizer?.menu == .confirmDelete(row: AppOrganizer.Menu.deleteRow))
            tv.handleOrganizer(.select)
            #expect(!tv.appOrder.contains(site) && !library.containsAddedApp(site))
            #expect(!AppLibrary(profileID: "other", folder: folder).containsAddedApp(site), "gone for everyone")
            #expect(tv.organizer != nil, "the sheet stays open")
        }
    }

    /// Movies and Web are system apps: held on Home, the menu offers only Edit Home Screen; in Arrange Apps, holding
    /// one opens no menu. They still move, and nothing hides them.
    @Test func systemAppsOfferNoHideOnTheTV() throws {
        _ = NSApplication.shared
        try withFolder { folder in
            let tv = twoRows(folder)
            for id in ["movies", "browser"] {
                // On Home: Edit Home Screen only, which picks the app up in Arrange Apps.
                tv.organizer = nil
                tv.setFocus(.app(try #require(tv.services.firstIndex { $0.id == id })))
                #expect(tv.homeAppFocused, "\(id)")
                #expect(tv.holdSelect(from: .keyboard), "\(id)")
                #expect(tv.organizer?.fromHome == true && tv.organizer?.menu == .actions(row: 0), "\(id)")
                #expect(tv.organizerActions(for: id) == [.editHomeScreen], "\(id)")
                tv.handle(.move(.down))
                #expect(tv.organizer?.menu == .actions(row: 0), "\(id): there's no second row")
                tv.chooseOrganizerMenuRow(1)
                #expect(tv.appOrder.contains(id) && !tv.library.isHidden(id), "\(id): no row hides it")
                tv.handle(.select)
                #expect(tv.organizer?.lift?.id == id && tv.organizer?.menu == nil, "\(id): Edit Home Screen")

                // It moves: into the dock's first place, then out of the dock.
                tv.handle(.back)
                tv.openOrganizer()
                select(tv, id)
                #expect(tv.moveApp(id, to: 0) && tv.appOrder.first == id, "\(id)")
                #expect(tv.moveApp(id, to: AppLibrary.dockSize + 1) && tv.appOrder.firstIndex(of: id) == AppLibrary.dockSize + 1, "\(id)")

                // In Arrange Apps: nothing to offer, so no menu, from the remote or the pointer.
                select(tv, id)
                #expect(tv.organizerActions(for: id).isEmpty, "\(id)")
                #expect(!tv.holdSelect(from: .keyboard), "\(id)")
                #expect(tv.organizer?.menu == nil, "\(id)")
                tv.organizerHold(id)
                #expect(tv.organizer?.menu == nil, "\(id)")
                // Even a menu forced open can't hide it.
                tv.organizer?.menu = .actions(row: 0)
                tv.chooseOrganizerMenuRow(0)
                #expect(tv.appOrder.contains(id) && !tv.library.isHidden(id), "\(id)")
                // Picking it up with Select still works.
                tv.organizer?.menu = nil
                tv.handleOrganizer(.select)
                #expect(tv.organizer?.lift?.id == id, "\(id)")
                tv.handleOrganizer(.back)
                tv.handle(.back)
            }
            // The other built-in apps still offer Hide.
            tv.organizer = nil
            tv.openOrganizer()
            for id in ["bilibili", "netease", "dedao", "youtube"] {
                select(tv, id)
                #expect(tv.organizerActions(for: id) == [.hide], "\(id)")
            }
        }
    }

    /// Press and hold on a Home Screen app, as on Apple TV: its menu, from every remote that has a hold (the phone's
    /// and the Siri Remote's OK, held Return). Edit Home Screen picks the app up in Arrange Apps; Back, or Hide,
    /// goes back to Home.
    @Test func holdingSelectOnAHomeAppOpensItsMenu() throws {
        _ = NSApplication.shared
        try withFolder { folder in
            let library = AppLibrary(folder: folder)
            let site = library.add(name: "Example", url: URL(string: "https://example.com"), bundleID: nil).id
            let tv = TVController(library: library)
            let youtube = try #require(tv.services.firstIndex { $0.id == "youtube" })
            tv.setFocus(.app(youtube))
            #expect(tv.homeAppFocused)

            // Each remote's hold opens it; Back closes it, back on Home with the same app focused.
            let holds: [(String, () -> Void)] = [
                ("phone", { tv.handle(.press(.select, .hold), from: .remote); tv.handle(.press(.select, .release), from: .remote) }),
                ("Siri Remote", { tv.handle(.press(.select, .hold), from: .siriRemote); tv.handle(.press(.select, .release), from: .siriRemote) }),
                ("keyboard", { _ = tv.holdSelect(from: .keyboard) }),
            ]
            for (name, hold) in holds {
                hold()
                #expect(tv.organizer?.fromHome == true && tv.organizer?.menu == .actions(row: 0), "\(name)")
                #expect(tv.organizer?.selectedID == "youtube" && tv.mode == .launcher, "\(name): nothing opened")
                #expect(tv.organizerActions(for: "youtube") == [.editHomeScreen, .hide], "\(name)")
                tv.handle(.back)
                #expect(tv.organizer == nil && tv.focus == .app(youtube), "\(name): Back is Home again")
            }

            // Holding again closes it, as every menu.
            #expect(tv.holdSelect(from: .keyboard))
            #expect(tv.holdSelect(from: .keyboard))
            #expect(tv.organizer == nil)

            // Edit Home Screen: Arrange Apps with the app picked up; Select puts it down, Back leaves.
            #expect(tv.holdSelect(from: .keyboard))
            tv.handle(.select)
            #expect(tv.organizer?.fromHome == false && tv.organizer?.menu == nil)
            #expect(tv.organizer?.lift?.id == "youtube" && tv.activeSheet == .organizer)
            let before = tv.appOrder
            tv.handle(.move(youtube % dock == 0 ? .right : .left))
            tv.handle(.select)
            #expect(tv.organizer?.lift == nil && tv.appOrder != before, "moved, and saved")
            tv.handle(.back)
            #expect(tv.organizer == nil)

            // Hide: gone from Home, and Home again.
            tv.setFocus(.app(try #require(tv.services.firstIndex { $0.id == "youtube" })))
            #expect(tv.holdSelect(from: .keyboard))
            tv.handle(.move(.down))
            tv.handle(.select)
            #expect(tv.organizer == nil && !tv.appOrder.contains("youtube") && library.isHidden("youtube"))

            // An app someone added also has Delete for Everyone, which asks first; Cancel goes back to Home.
            tv.setFocus(.app(try #require(tv.services.firstIndex { $0.id == site })))
            #expect(tv.holdSelect(from: .keyboard))
            #expect(tv.organizerActions(for: site) == [.editHomeScreen, .hide, .deleteForEveryone])
            tv.handle(.move(.down))
            tv.handle(.move(.down))
            tv.handle(.select)
            #expect(tv.organizer?.menu == .confirmDelete(row: AppOrganizer.Menu.cancelRow))
            tv.handle(.select)
            #expect(tv.organizer == nil && tv.appOrder.contains(site))

            // Not on Home's add and Settings tiles, and not with an app open.
            tv.setFocus(.app(tv.services.count - 1))
            #expect(!tv.homeAppFocused && !tv.holdSelect(from: .keyboard) && tv.organizer == nil)
        }
    }

    /// Back on the top row's first app starts the screen saver, as on Apple TV; anywhere else on Home it goes to that
    /// app first, in one press.
    @Test func backOnHomesFirstAppStartsTheScreenSaver() throws {
        _ = NSApplication.shared
        try withFolder { folder in
            let tv = twoRows(folder)
            tv.setFocus(.app(2))
            tv.handle(.back)
            #expect(!tv.screensaver && tv.focus == .app(0))
            tv.setFocus(.app(dock + 1))
            tv.handle(.back)
            #expect(!tv.screensaver && tv.focus == .app(0))
            tv.handle(.back)
            #expect(tv.screensaver)
            tv.handle(.select)   // the press that ends it does nothing else
            #expect(!tv.screensaver && tv.focus == .app(0) && tv.mode == .launcher)
        }
    }

    @Test func hideOnAnAddedAppIsForThisProfileOnly() throws {
        _ = NSApplication.shared
        try withFolder { folder in
            let library = AppLibrary(folder: folder)
            let site = library.add(name: "Example", url: URL(string: "https://example.com"), bundleID: nil).id
            let profiles = ProfileStore(folder: folder)
            let second = profiles.add(named: "Second")
            let tv = TVController(library: library, profiles: profiles)
            tv.switchProfile(to: second.id)
            #expect(tv.appOrder.last == site, "an app added by anyone is everyone's, last")
            tv.openOrganizer()
            select(tv, site)
            #expect(tv.holdSelect(from: .keyboard))
            tv.handleOrganizer(.select)
            #expect(!tv.appOrder.contains(site))
            // Adding it again here shows it again, last.
            tv.organizer = nil
            let again = try #require(tv.addWebsite(name: nil, address: "example.com"))
            #expect(again.id == site && tv.appOrder.last == site)
            tv.hideApp(site)
            tv.switchProfile(to: Profile.mainID)
            #expect(tv.appOrder.contains(site), "the main profile still has it")
        }
    }

    @Test func holdingWhileAnAppMovesPutsItDown() throws {
        _ = NSApplication.shared
        try withFolder { folder in
            let tv = twoRows(folder)
            let before = tv.appOrder
            tv.openOrganizer()
            select(tv, before[2])
            tv.handleOrganizer(.select)
            tv.handleOrganizer(.move(.left))
            #expect(!tv.holdSelect(from: .keyboard), "no menu while an app is moving")
            tv.handle(.longSelect)
            #expect(tv.organizer?.lift == nil && tv.organizer?.menu == nil)
            #expect(tv.appOrder[1] == before[2])
        }
    }

    @Test func thePhoneChangingAppsKeepsTheMoveGoing() throws {
        try withFolder { folder in
            let tv = twoRows(folder)
            let before = tv.appOrder
            let moving = before[dock + 1]
            tv.openOrganizer()
            select(tv, moving)
            tv.handleOrganizer(.select)
            tv.handleOrganizer(.move(.up))
            // Meanwhile the phone moves the dock's first app to the end.
            #expect(tv.moveApp(before[0], to: before.count - 1))
            #expect(tv.organizer?.lift?.id == moving)
            #expect(tv.organizer?.lift?.rest.contains(moving) == false)
            #expect(tv.organizerOrder[1] == moving)
            tv.handleOrganizer(.select)
            #expect(tv.appOrder[1] == moving && tv.appOrder.last == before[0])
            // And the phone hiding the app being moved ends the move.
            select(tv, tv.appOrder[dock])
            tv.handleOrganizer(.select)
            let gone = try #require(tv.organizer?.lift?.id)
            tv.hideApp(gone)
            #expect(tv.organizer?.lift == nil && tv.organizer?.selectedID != gone)
        }
    }

    @Test func thePointerDragsAnAppIntoPlace() throws {
        try withFolder { folder in
            let tv = twoRows(folder)
            let before = tv.appOrder
            let moving = before[dock + 3]
            tv.openOrganizer()
            tv.beginOrganizerDrag(moving)
            #expect(tv.organizer?.lift?.id == moving)
            let place = ArrangeGrid.center(of: 4)
            #expect(ArrangeGrid.index(at: place) == 4)
            #expect(ArrangeGrid.index(at: ArrangeGrid.center(of: dock + 1)) == dock + 1)
            tv.dragOrganizerApp(to: ArrangeGrid.index(at: place))
            #expect(tv.organizerOrder[4] == moving)
            tv.endOrganizerDrag()
            #expect(Array(tv.appOrder.prefix(dock)) == Array(before.prefix(4)) + [moving, before[4]])
            // A point far below the last row is the last place.
            tv.beginOrganizerDrag(moving)
            tv.dragOrganizerApp(to: ArrangeGrid.index(at: CGPoint(x: 9999, y: 9999)))
            tv.endOrganizerDrag()
            #expect(tv.appOrder.last == moving)
        }
    }

    // MARK: Renders

    /// Home and Arrange Apps at 1920×1080, before and after moving an app into the dock, and press and hold's
    /// menu and question. Written to work/native-qa/ and, when set, MACTV_RENDER_DIR.
    @Test func homeAndArrangeAppsRender() async throws {
        _ = NSApplication.shared
        let folder = Self.root.appendingPathComponent("work/tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = AppLibrary(folder: folder)
        // The built-in icons live in the app bundle, which tests don't have: stand-ins carry the same artwork. Web and
        // Movies are system apps, which never hide, so they stay as themselves.
        for id in ["bilibili", "netease", "dedao", "youtube", "iina"] { library.setHidden(id, true) }
        let art: [(String, String)] = [("YouTube", "youtube"), ("哔哩哔哩", "bilibili"), ("网易云音乐", "netease"),
                                       ("得到", "dedao"), ("IINA", "iina"),
                                       ("Crunchyroll", ""), ("Twitch", ""), ("Plex", ""), ("Disney+", ""), ("Steam", "")]
        for (index, (name, icon)) in art.enumerated() {
            let app = library.add(name: name, url: URL(string: "https://app\(index).example"), bundleID: nil)
            if !icon.isEmpty, let png = try? Data(contentsOf: Self.root.appendingPathComponent("Icons/\(icon).png")),
               let image = NSImage(data: png)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                library.setIcon(png, accent: TileArt.brandColor(from: image), for: app.id)
            }
        }
        let tv = TVController(library: library)
        let output = Self.root.appendingPathComponent("work/native-qa/round3")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let extra = ProcessInfo.processInfo.environment["MACTV_RENDER_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let extra { try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true) }

        func render(_ name: String, _ view: some View) async throws {
            let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark).frame(width: 1920, height: 1080))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1920, height: 1080), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(500))
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            var lit = 0
            for y in stride(from: 0, to: rep.pixelsHigh, by: 16) {
                for x in stride(from: 0, to: rep.pixelsWide, by: 16) {
                    if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       max(color.redComponent, color.greenComponent, color.blueComponent) > 0.5 { lit += 1 }
                }
            }
            #expect(lit > 40, "\(name) shows its icons and text")
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("\(name).png"))
            if let extra { try png.write(to: extra.appendingPathComponent("\(name).png")) }
            window.close()
        }
        let home = { ZStack { Color.black; TVCanvas { HomeView(tv: tv) } } }
        let arrange = { ZStack { Wallpaper(); SheetBackdrop(); TVCanvas { AppOrganizerSheet(tv: tv) } } }

        tv.setFocus(.app(1))
        try await render("1-home-before", home())
        tv.openOrganizer()
        try await render("2-arrange-before", arrange())

        // An app from the row below moving up into the full dock: the dock's last app makes room below.
        tv.organizer?.selectedID = tv.appOrder[AppLibrary.dockSize + 2]
        tv.handleOrganizer(.select)
        tv.handleOrganizer(.move(.up))
        try await render("3-arrange-moving-into-dock", arrange())
        tv.handleOrganizer(.select)
        try await render("4-arrange-after", arrange())
        let shown = tv.organizerOrder
        tv.organizer = nil
        tv.setFocus(.app(2))
        #expect(tv.services.prefix(shown.count).map(\.id) == shown)
        try await render("5-home-after", home())

        tv.openOrganizer()
        tv.organizer?.selectedID = tv.appOrder[AppLibrary.dockSize + 1]
        _ = tv.holdSelect(from: .keyboard)
        try await render("6-arrange-hold-menu", arrange())
        tv.handleOrganizer(.move(.down))
        tv.handleOrganizer(.select)
        try await render("7-arrange-delete-for-everyone", arrange())
    }
}
