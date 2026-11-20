import AppKit
import Foundation
import Testing
@testable import MacTV

/// Home's apps: one order whose first six are the dock, apps people add shared by every profile, and each
/// profile's own order and hidden apps.
@Suite @MainActor
struct AppLibraryTests {
    // Keep fixtures in the project rather than the system temporary directory or Documents.
    private func withFolder(_ body: (URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder)
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func site(_ name: String) -> URL { URL(string: "https://\(name.lowercased()).example")! }

    @Test
    func testLegacyFilePreservesAddedAndHiddenApps() throws {
        try withFolder { folder in
            let legacy = #"{"added":[{"id":"user-legacy","name":"Legacy","url":"https://example.com"}],"hidden":["youtube"]}"#
            try Data(legacy.utf8).write(to: folder.appendingPathComponent("apps.json"))
            let library = AppLibrary(folder: folder)
            #expect(library.hasHiddenBuiltIns)
            #expect(!library.services().contains { $0.id == "youtube" })
            #expect(library.services().contains { $0.id == "user-legacy" })
            library.restoreBuiltIns()
            let reloaded = AppLibrary(folder: folder)
            #expect(reloaded.services().contains { $0.id == "youtube" })
            #expect(reloaded.services().contains { $0.id == "user-legacy" })
        }
    }

    @Test
    func orderSurvivesReloadAndANewAppComesLast() throws {
        try withFolder { folder in
            let library = AppLibrary(folder: folder)
            let a = library.add(name: "First", url: site("first"), bundleID: nil)
            let b = library.add(name: "Second", url: site("second"), bundleID: nil)
            #expect(library.move(a.id, to: 0))
            #expect(library.move(b.id, to: 1))
            let expected = library.services().map(\.id)
            #expect(Array(expected.prefix(2)) == [a.id, b.id])
            #expect(AppLibrary(folder: folder).services().map(\.id) == expected)
            let c = library.add(name: "Third", url: site("third"), bundleID: nil)
            #expect(Array(library.services().suffix(3).map(\.id)) == [c.id, "add-app", "settings"])
        }
    }

    @Test
    func intoAFullDockItsLastAppGoesBelowAndOutOfItTheNextComesUp() throws {
        try withFolder { folder in
            let library = AppLibrary(folder: folder)
            for name in ["One", "Two", "Three"] { library.add(name: name, url: site(name), bundleID: nil) }
            let before = library.arrangement()
            try #require(before.count > AppLibrary.dockSize + 1)
            let dock = Array(before.prefix(AppLibrary.dockSize))
            let first = before[AppLibrary.dockSize]
            // Into the dock's third place: the apps from there move along, the sixth to the first place below.
            let moving = before[AppLibrary.dockSize + 1]
            #expect(library.move(moving, to: 2))
            var now = library.arrangement()
            #expect(Array(now.prefix(AppLibrary.dockSize)) == Array(dock.prefix(2)) + [moving] + dock[2..<5])
            #expect(now[AppLibrary.dockSize] == dock[5])
            #expect(now[AppLibrary.dockSize + 1] == first)
            // Out of the dock: the first app below comes up into its last place.
            #expect(library.move(dock[0], to: now.count - 1))
            now = library.arrangement()
            #expect(now.last == dock[0])
            #expect(now[AppLibrary.dockSize - 1] == dock[5])
            #expect(AppLibrary(folder: folder).arrangement() == now)
        }
    }

    @Test
    func favoritesFromEarlierVersionsBecomeHomeOrderOnce() throws {
        try withFolder { folder in
            // Earlier versions showed favorites first (at most six), then the rest in order. Home looks the same after.
            let file = folder.appendingPathComponent("apps.json")
            let json = #"{"order":["youtube","netease","bilibili","movies","dedao","browser"],"hidden":["netease"],"pinned":["movies","dedao","netease"]}"#
            try Data(json.utf8).write(to: file)
            let library = AppLibrary(folder: folder)
            #expect(library.arrangement() == ["movies", "dedao", "youtube", "bilibili", "browser"])
            #expect(try self.json(file)["pinned"] == nil, "the favorites go")
            library.setHidden("netease", false)
            #expect(library.arrangement().contains("netease"))
            #expect(AppLibrary(folder: folder).arrangement() == library.arrangement())

            // More than six favorites: the first six on show led Home, and still do.
            let many = #"{"added":[{"id":"user-seventh","name":"Seventh","url":"https://seventh.example"},{"id":"user-eighth","name":"Eighth","url":"https://eighth.example"}],"order":["youtube","netease","bilibili","movies","dedao","browser","user-seventh","user-eighth"],"pinned":["youtube","netease","bilibili","movies","dedao","user-seventh","user-eighth","user-gone"]}"#
            try Data(many.utf8).write(to: file)
            #expect(AppLibrary(folder: folder).arrangement()
                    == ["youtube", "netease", "bilibili", "movies", "dedao", "user-seventh", "browser", "user-eighth"])
        }
    }

    @Test
    func hiddenAppsKeepTheirPlaceAndBadOrdersAreRefused() throws {
        try withFolder { folder in
            let library = AppLibrary(folder: folder)
            for n in 1...2 { library.add(name: "Site \(n)", url: site("site\(n)"), bundleID: nil) }
            let before = library.arrangement()
            #expect(library.hide("netease"))
            let shown = library.arrangement()
            #expect(!shown.contains("netease"))
            for bad in [shown + ["netease"], Array(shown.dropLast()), shown + [shown[0]], ["settings"] + shown] {
                #expect(!library.arrange(bad))
            }
            #expect(library.arrangement() == shown)
            #expect(library.move("youtube", to: 0))
            #expect(!library.move("netease", to: 0))
            #expect(!library.move("settings", to: 0))
            #expect(!library.move("missing", to: 0))
            library.restoreBuiltIns()
            // NetEase comes back to the place it had.
            let restored = library.arrangement()
            #expect(restored.first == "youtube")
            #expect(restored.firstIndex(of: "netease") == before.firstIndex(of: "netease"))
            #expect(Array(library.services().suffix(2).map(\.id)) == ["add-app", "settings"])
            #expect(library.move("youtube", to: .max))
            #expect(library.arrangement().last == "youtube")
        }
    }

    @Test
    func anAppAddedInOneProfileIsEveryonesAndComesLast() throws {
        try withFolder { folder in
            let main = AppLibrary(folder: folder)
            let other = AppLibrary(profileID: "other", folder: folder)
            #expect(other.move("netease", to: 0))
            let a = main.add(name: "Video", url: site("video"), bundleID: nil)
            let b = other.add(name: "Video", url: site("video2"), bundleID: nil)
            #expect(a.id.hasPrefix("user-") && b.id.hasPrefix("user-") && a.id != b.id, "ids are new across everyone's apps")
            #expect(!b.id.hasPrefix("user-other-"))
            for library in [AppLibrary(folder: folder), AppLibrary(profileID: "other", folder: folder)] {
                #expect(Array(library.arrangement().suffix(2)) == [a.id, b.id], "both, last, for everyone")
            }
            #expect(AppLibrary(profileID: "other", folder: folder).arrangement().first == "netease", "each profile keeps its order")
            #expect(AppLibrary(folder: folder).arrangement().first != "netease")
            // Each file keeps its own part: the shared list and main's layout in apps.json, only a layout in the profile's.
            let shared = try json(folder.appendingPathComponent("apps.json"))
            #expect((shared["added"] as? [[String: Any]])?.count == 2)
            let own = try json(folder.appendingPathComponent("apps-other.json"))
            #expect(Set(own.keys) == ["hidden", "order"])
        }
    }

    @Test
    func hideIsForThisProfileAndDeleteForEveryoneIsForAll() throws {
        try withFolder { folder in
            let main = AppLibrary(folder: folder)
            let app = main.add(name: "Video", url: site("video"), bundleID: nil)
            try Data("png".utf8).write(to: main.iconFile(for: app.id))
            let other = AppLibrary(profileID: "other", folder: folder)
            #expect(other.hide(app.id))
            #expect(!other.arrangement().contains(app.id))
            #expect(AppLibrary(folder: folder).arrangement().contains(app.id), "hidden only for the profile that hid it")
            #expect(main.deleteForEveryone(app.id) == .deleted)
            #expect(!FileManager.default.fileExists(atPath: main.iconFile(for: app.id).path))
            for library in [AppLibrary(folder: folder), AppLibrary(profileID: "other", folder: folder)] {
                #expect(!library.containsAddedApp(app.id) && !library.arrangement().contains(app.id))
            }
            // Every profile forgets it, so an app added later under the same id starts afresh.
            let own = try json(folder.appendingPathComponent("apps-other.json"))
            #expect(!((own["hidden"] as? [String]) ?? []).contains(app.id))
            let again = main.add(name: "Video", url: site("video"), bundleID: nil)
            #expect(again.id == app.id)
            #expect(AppLibrary(profileID: "other", folder: folder).arrangement().last == again.id)
            // Built-in apps can only be hidden.
            #expect(main.deleteForEveryone("youtube") == .notAdded)
        }
    }

    @Test
    func theAppsEachProfileAddedBeforeAreGatheredOnce() throws {
        try withFolder { folder in
            let apps = folder.appendingPathComponent("apps.json"), kids = folder.appendingPathComponent("apps-kids.json")
            try Data(#"{"added":[{"id":"user-mine","name":"Mine","url":"https://mine.example"}],"order":["youtube"],"pinned":["netease"]}"#.utf8).write(to: apps)
            try Data(#"{"added":[{"id":"user-kids-cartoons","name":"Cartoons","url":"https://cartoons.example"}],"order":["user-kids-cartoons","bilibili"],"hidden":["dedao"],"pinned":["bilibili"]}"#.utf8).write(to: kids)
            let icons = folder.appendingPathComponent("Icons", isDirectory: true)
            try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
            try Data("png".utf8).write(to: icons.appendingPathComponent("user-kids-cartoons.png"))

            let main = AppLibrary(folder: folder)
            let added = try #require(try json(apps)["added"] as? [[String: Any]]).compactMap { $0["id"] as? String }
            #expect(added == ["user-mine", "user-kids-cartoons"], "every profile's apps in the shared list, ids unchanged")
            #expect(try json(kids)["added"] == nil, "taken out of the profile's file once the shared list is saved")
            #expect(try json(kids)["pinned"] != nil, "the profile's own order is its to keep")
            #expect(main.arrangement().first == "netease")
            #expect(main.arrangement().last == "user-kids-cartoons")
            let kidsLibrary = AppLibrary(profileID: "kids", folder: folder)
            #expect(Array(kidsLibrary.arrangement().prefix(2)) == ["bilibili", "user-kids-cartoons"])
            #expect(!kidsLibrary.arrangement().contains("dedao"))
            #expect(kidsLibrary.services().first { $0.id == "user-kids-cartoons" }?.iconFile != nil, "its icon file still matches")
            #expect(try json(kids)["pinned"] == nil)
        }
    }

    @Test
    func profileAppsStayWhereTheyAreIfTheSharedListCantBeSaved() throws {
        try withFolder { folder in
            let kids = folder.appendingPathComponent("apps-kids.json")
            try Data(#"{"added":[{"id":"user-kids-cartoons","name":"Cartoons","url":"https://cartoons.example"}]}"#.utf8).write(to: kids)
            // A directory at apps.json's path can't be written over.
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("apps.json"), withIntermediateDirectories: true)
            _ = AppLibrary(profileID: "kids", folder: folder)
            #expect(try json(kids)["added"] != nil)
        }
    }

    @Test
    func failedWritesRollBackTheOrder() throws {
        try withFolder { folder in
            let library = AppLibrary(folder: folder)
            let before = library.services().map(\.id)
            // A directory at the file path reliably rejects an atomic file replacement.
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("apps.json"), withIntermediateDirectories: true)
            #expect(!library.move("youtube", to: 0))
            #expect(!library.hide("youtube"))
            #expect(library.services().map(\.id) == before)
            let tv = TVController(library: library)
            let request = HTTPRequest(method: "POST", path: "/apps/place", query: [:], headers: [:],
                body: Data(#"{"id":"youtube","index":0}"#.utf8))
            #expect(tv.handleAppsRequest(request)?.status == "500 Internal Server Error")
        }
    }

    @Test
    func controllerKeepsFocusByAppIdentityAcrossChanges() throws {
        try withFolder { folder in
            let library = AppLibrary(folder: folder)
            for n in 1...3 { library.add(name: "Site \(n)", url: site("site\(n)"), bundleID: nil) }
            let tv = TVController(library: library)
            let last = try #require(tv.appOrder.last)
            tv.setFocus(.app(tv.appOrder.count - 1))
            #expect(tv.moveApp(last, to: 0))
            #expect(tv.services.first?.id == last)
            #expect(tv.focus == .app(0), "focus stays on the app it was on")
            #expect(tv.moveApp(last, to: 3))
            #expect(tv.focus == .app(3))
        }
    }

    @Test
    func appRequestsValidateAndTheOldFavoriteRoutesAreGone() throws {
        try withFolder { folder in
            let library = AppLibrary(folder: folder)
            let added = library.add(name: "Video", url: site("video"), bundleID: nil)
            let tv = TVController(library: library)
            @MainActor func request(_ path: String, _ json: String) -> HTTPResponse? {
                tv.handleAppsRequest(HTTPRequest(method: "POST", path: path, query: [:], headers: [:], body: Data(json.utf8)))
            }
            let before = tv.appOrder
            for body in [#"{"index":0}"#, #"{"id":"missing","index":0}"#, #"{"id":"settings","index":0}"#,
                         #"{"id":"add-app","index":0}"#, #"{"id":"youtube","index":true}"#, #"{"id":"youtube","index":-1}"#,
                         #"{"id":"youtube","index":1.5}"#, #"{"id":"youtube","index":"0"}"#, #"{"id":"youtube"}"#] {
                #expect(request("/apps/place", body)?.status == "400 Bad Request", "\(body)")
            }
            #expect(tv.appOrder == before)
            #expect(request("/apps/pin", #"{"id":"youtube","pinned":true}"#) == nil)
            #expect(request("/apps/move", #"{"id":"youtube","offset":-1}"#) == nil)
            #expect(request("/apps/place", #"{"id":"youtube","index":0}"#)?.status == "200 OK")
            #expect(tv.appOrder.first == "youtube")
            #expect(request("/apps/place", #"{"id":"youtube","index":1e9}"#)?.status == "200 OK")
            #expect(tv.appOrder.last == "youtube")
            #expect(request("/apps/delete", #"{"id":"netease"}"#)?.status == "400 Bad Request", "built-in apps can only be hidden")
            #expect(request("/apps/remove", #"{"id":"netease"}"#)?.status == "200 OK")
            #expect(!tv.appOrder.contains("netease") && library.isHidden("netease"))
            #expect(request("/apps/delete", #"{"id":"\#(added.id)"}"#)?.status == "200 OK")
            #expect(!library.containsAddedApp(added.id))
            // The phone's state: Home's order, the dock's size, which apps someone added; no favorites.
            let state = tv.remoteState()
            #expect(state["dockSize"] as? Int == AppLibrary.dockSize)
            let apps = try #require(state["apps"] as? [[String: Any]])
            #expect(apps.compactMap { $0["id"] as? String } == tv.appOrder)
            #expect(!apps.contains { $0["pinned"] != nil })
        }
    }

    // MARK: Deleting is careful

    /// Records what was moved to a test's own Trash, never the Mac's.
    private final class TrashLog: @unchecked Sendable {
        var moved: [URL] = []
        var failOn: String?
    }

    private func trash(into folder: URL, log: TrashLog) -> MacTrash.Mover {
        let move = MacTrash.folder(folder)
        return { url in
            if let failOn = log.failOn, url.lastPathComponent.contains(failOn) { throw CocoaError(.fileWriteNoPermission) }
            log.moved.append(url)
            return try move(url)
        }
    }

    @Test
    func builtInAppsCanOnlyEverBeHidden() throws {
        try withFolder { folder in
            // Even an older file listing a built-in id among the added apps can't make it deletable.
            try Data(#"{"added":[{"id":"youtube","name":"YouTube","url":"https://youtube.com"}]}"#.utf8)
                .write(to: folder.appendingPathComponent("apps.json"))
            let library = AppLibrary(folder: folder)
            let tv = TVController(library: library)
            for service in Catalog.services {
                #expect(library.deleteForEveryone(service.id) == .notAdded, "\(service.id)")
                #expect(tv.organizerActions(for: service.id) == [.hide], "\(service.id)")
                let response = tv.handleAppsRequest(HTTPRequest(method: "POST", path: "/apps/delete", query: [:], headers: [:],
                                                                body: Data(#"{"id":"\#(service.id)"}"#.utf8)))
                #expect(response?.status == "400 Bad Request", "\(service.id)")
            }
            let state = try #require(tv.remoteState()["apps"] as? [[String: Any]])
            #expect(!state.contains { $0["added"] as? Bool == true }, "the phone offers only Hide for built-in apps")
            // Hide is for this profile and always comes back.
            for id in ["bilibili", "netease", "dedao", "youtube", "browser", "movies"] {
                #expect(tv.handleAppsRequest(HTTPRequest(method: "POST", path: "/apps/remove", query: [:], headers: [:],
                                                         body: Data(#"{"id":"\#(id)"}"#.utf8)))?.status == "200 OK")
            }
            #expect(Set(tv.appOrder).isDisjoint(with: ["bilibili", "netease", "dedao", "youtube", "browser", "movies"]) && library.hasHiddenBuiltIns)
            tv.restoreBuiltInApps()
            #expect(Set(tv.appOrder).isSuperset(of: ["bilibili", "netease", "dedao", "youtube", "browser", "movies"]))
            #expect(Array(tv.services.suffix(2).map(\.id)) == ["add-app", "settings"])
        }
    }

    @Test
    func deleteForEveryoneMovesTheAppsOwnFilesToTheTrashAndNothingElse() throws {
        try withFolder { folder in
            let log = TrashLog(), bin = folder.appendingPathComponent("TestTrash", isDirectory: true)
            let library = AppLibrary(folder: folder, trash: trash(into: bin, log: log))
            // A Mac app shortcut whose app lives elsewhere, and a Steam game with its art.
            let bundle = folder.appendingPathComponent("Applications/Fake.app", isDirectory: true)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            let mac = library.add(name: "Fake", url: nil, bundleID: "com.example.fake")
            let game = library.add(name: "Game", url: nil, bundleID: nil, steamID: "12345")
            for id in [mac.id, game.id] { try Data("png".utf8).write(to: library.iconFile(for: id)) }
            try Data("jpg".utf8).write(to: library.heroFile(for: game.id))

            #expect(library.deleteForEveryone(game.id) == .deleted)
            #expect(library.deleteForEveryone(mac.id) == .deleted)
            #expect(Set(log.moved.map(\.lastPathComponent)) == ["\(game.id).png", "\(game.id)-hero.jpg", "\(mac.id).png"])
            #expect(log.moved.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL == library.iconsFolder.standardizedFileURL },
                    "only Mac TV's own Icons folder")
            let kept = try FileManager.default.contentsOfDirectory(atPath: bin.appendingPathComponent("Trash").path)
            #expect(kept.count == 3, "moved to the Trash, not deleted")
            #expect(FileManager.default.fileExists(atPath: bundle.path), "the Mac app itself is never touched")
            #expect(!library.containsAddedApp(game.id) && !library.containsAddedApp(mac.id))
        }
    }

    @Test
    func whenTheTrashRefusesNothingIsDeleted() throws {
        try withFolder { folder in
            let log = TrashLog()
            log.failOn = "-hero"
            let library = AppLibrary(folder: folder, trash: trash(into: folder.appendingPathComponent("TestTrash"), log: log))
            let game = library.add(name: "Game", url: site("game"), bundleID: nil)
            try Data("png".utf8).write(to: library.iconFile(for: game.id))
            try Data("jpg".utf8).write(to: library.heroFile(for: game.id))
            let tv = TVController(library: library)
            let response = tv.handleAppsRequest(HTTPRequest(method: "POST", path: "/apps/delete", query: [:], headers: [:],
                                                            body: Data(#"{"id":"\#(game.id)"}"#.utf8)))
            #expect(response?.status == "500 Internal Server Error")
            let reply = try #require(response.flatMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any] })
            #expect((reply["error"] as? String)?.contains("Couldn’t move “Game” to the Trash") == true)
            #expect(FileManager.default.fileExists(atPath: library.iconFile(for: game.id).path), "the icon came back")
            #expect(FileManager.default.fileExists(atPath: library.heroFile(for: game.id).path))
            #expect(library.containsAddedApp(game.id) && tv.appOrder.contains(game.id))
            #expect(AppLibrary(folder: folder).containsAddedApp(game.id))
        }
    }

    @Test
    func removingAProfileMovesItsFolderToTheTrash() throws {
        _ = NSApplication.shared
        try withFolder { folder in
            let profiles = ProfileStore(folder: folder)
            let second = profiles.add(named: "Second")
            let tv = TVController(library: AppLibrary(folder: folder), profiles: profiles)
            let space = tv.spaces.folder(for: second.id)
            try FileManager.default.createDirectory(at: space, withIntermediateDirectories: true)
            try Data("photo".utf8).write(to: space.appendingPathComponent("Avatar.jpg"))
            tv.removeProfile(second.id)
            #expect(!FileManager.default.fileExists(atPath: space.path))
            let bin = folder.appendingPathComponent("Trash")
            let moved = try #require(try FileManager.default.contentsOfDirectory(atPath: bin.path).first { $0.hasSuffix(second.id) })
            #expect(FileManager.default.fileExists(atPath: bin.appendingPathComponent(moved).appendingPathComponent("Avatar.jpg").path),
                    "the photo is in the Trash, not gone")
        }
    }
}
