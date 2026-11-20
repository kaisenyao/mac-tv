import Foundation
import Testing
@testable import MacTV

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
    func testPinsAndOrderSurviveReloadAndNewAppAppendsUnpinned() throws {
        try withFolder { folder in
            let library = AppLibrary(folder: folder)
            let a = library.add(name: "First", url: URL(string: "https://first.example"), bundleID: nil)
            let b = library.add(name: "Second", url: URL(string: "https://second.example"), bundleID: nil)
            #expect(library.setPinned(a.id, true))
            #expect(library.setPinned(b.id, true))
            let pinned = library.services().filter { library.isPinned($0.id) }.map(\.id)
            #expect(Set(pinned) == Set([a.id, b.id]))
            try #require(pinned.count == 2)
            #expect(library.move(pinned[1], by: -1))
            let expected = library.services().map(\.id)
            let reloaded = AppLibrary(folder: folder)
            #expect(reloaded.services().map(\.id) == expected)
            #expect(Array(expected.prefix(2)) == Array(pinned.reversed()))
            #expect(reloaded.isPinned(a.id))
            #expect(reloaded.isPinned(b.id))
            let c = reloaded.add(name: "Third", url: URL(string: "https://third.example"), bundleID: nil)
            #expect(!reloaded.isPinned(c.id))
            #expect(Array(reloaded.services().suffix(3).map(\.id)) == [c.id, "add-app", "settings"])
        }
    }

    @Test
    func testMoveBoundariesAndUtilityTiles() throws {
        try withFolder { folder in
            let library = AppLibrary(folder: folder)
            #expect(library.setPinned("youtube", true))
            let before = library.services().map(\.id)
            for id in ["missing", "add-app", "settings"] {
                #expect(!library.setPinned(id, true))
                #expect(!library.move(id, by: -1))
                #expect(!library.move(id, by: -1))
            }
            #expect(!library.move("youtube", by: -1))
            #expect(!library.move("youtube", by: 1))
            #expect(!library.move("youtube", by: 1))
            // 第一个没置顶的应用不能挪进置顶区（这个分支里排在最前面的是哔哩哔哩，不是 YouTube）
            let firstUnpinned = try #require(before.dropFirst().first)
            #expect(!library.move(firstUnpinned, by: -1))
            #expect(!library.move(firstUnpinned, by: -1))
            #expect(library.services().map(\.id) == before)
            #expect(Array(before.suffix(2)) == ["add-app", "settings"])
        }
    }

    @Test
    func testHiddenBuiltinRetainsPreferenceAndRemovedAddedAppDoesNot() throws {
        try withFolder { folder in
            let library = AppLibrary(folder: folder)
            #expect(library.setPinned("netease", true))
            #expect(library.setPinned("youtube", true))
            let original = library.services().filter { library.isPinned($0.id) }.map(\.id)
            try #require(original.count == 2)
            #expect(library.move(original[1], by: -1))
            let reordered = library.services().filter { library.isPinned($0.id) }.map(\.id)
            library.remove("netease")
            #expect(!library.services().contains { $0.id == "netease" })
            let reloaded = AppLibrary(folder: folder)
            reloaded.restoreBuiltIns()
            #expect(reloaded.isPinned("netease"))
            #expect(reloaded.services().filter { reloaded.isPinned($0.id) }.map(\.id) == reordered)

            let added = reloaded.add(name: "Disposable", url: URL(string: "https://example.com"), bundleID: nil)
            #expect(reloaded.setPinned(added.id, true))
            reloaded.remove(added.id)
            let replacement = reloaded.add(name: "Disposable", url: URL(string: "https://example.com"), bundleID: nil)
            #expect(replacement.id == added.id)
            #expect(!reloaded.isPinned(replacement.id))
            #expect(Array(reloaded.services().suffix(3).map(\.id)) == [replacement.id, "add-app", "settings"])
        }
    }

    @Test
    func testMoreThanSixAppsCanBePinned() throws {
        try withFolder { folder in
            let library = AppLibrary(folder: folder)
            let sites = (1...4).map { library.add(name: "Site \($0)", url: URL(string: "https://site\($0).example"), bundleID: nil).id }
            let ids = ["bilibili", "netease", "youtube", "movies"] + sites
            for id in ids { #expect(library.setPinned(id, true)) }
            #expect(Set(library.services().filter { library.isPinned($0.id) }.map(\.id)) == Set(ids))
            #expect(Array(library.services().suffix(2).map(\.id)) == ["add-app", "settings"])
        }
    }

    @Test
    func testStaleAndDuplicateOrderIDsAndInvalidOffsets() throws {
        try withFolder { folder in
            let json = #"{"added":[],"hidden":[],"order":["youtube","user-later","missing","youtube","netease"],"pinned":["user-later"]}"#
            try Data(json.utf8).write(to: folder.appendingPathComponent("apps.json"))
            let library = AppLibrary(folder: folder)
            let ids = library.services().map(\.id)
            #expect(Array(ids.prefix(2)) == ["youtube", "netease"])
            #expect(Set(ids).count == ids.count)
            for offset in [Int.min, -2, 0, 2, Int.max] {
                #expect(!library.move("youtube", by: offset))
                #expect(!library.move("youtube", by: offset))
            }
            #expect(library.services().map(\.id) == ids)
            let added = library.add(name: "Later", url: URL(string: "https://later.example"), bundleID: nil)
            #expect(added.id == "user-later")
            #expect(!library.isPinned(added.id))
            #expect(Array(library.services().suffix(3).map(\.id)) == [added.id, "add-app", "settings"])
        }
    }

    @Test
    func testMovingVisibleAppsPreservesUnavailableAppPreference() throws {
        try withFolder { folder in
            let json = #"{"added":[{"id":"user-unavailable","name":"Unavailable","bundleID":"invalid.example.mactv.unavailable"}],"hidden":[],"order":["netease","user-unavailable","youtube"],"pinned":["user-unavailable"]}"#
            let file = folder.appendingPathComponent("apps.json")
            try Data(json.utf8).write(to: file)
            let library = AppLibrary(folder: folder)
            #expect(!library.services().contains { $0.id == "user-unavailable" })
            #expect(library.move("youtube", by: -1))
            let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            let order = try #require(saved["order"] as? [String])
            #expect(Array(order.prefix(3)) == ["youtube", "user-unavailable", "netease"])
            let reloaded = AppLibrary(folder: folder)
            #expect(reloaded.isPinned("user-unavailable"))
        }
    }


    @Test
    func controllerKeepsFocusByAppIdentityAcrossChanges() throws {
        try withFolder { folder in
            let library = AppLibrary(folder: folder)
            let sites = (1...3).map { library.add(name: "Site \($0)", url: URL(string: "https://site\($0).example"), bundleID: nil).id }
            let tv = TVController(library: library)
            tv.setFocus(.shelf(0))
            // 焦点停在排第一的应用上（这个分支里是哔哩哔哩），之后按"是哪个应用"跟着它走
            let first = try #require(tv.services.first?.id)
            for id in ["netease", "youtube", "movies"] + sites where id != first {
                #expect(tv.setPinned(id, true))
            }
            let firstIndex = try #require(tv.services.firstIndex { $0.id == first })
            #expect(firstIndex >= tv.columns)
            #expect(tv.focus == .app(firstIndex))
            #expect(tv.setPinned(first, true))
            let pinnedIndex = try #require(tv.services.firstIndex { $0.id == first })
            #expect(tv.focus == .app(pinnedIndex))
            #expect(tv.moveApp(first, by: 1))
            let movedIndex = try #require(tv.services.firstIndex { $0.id == first })
            #expect(movedIndex == pinnedIndex + 1)
            #expect(tv.focus == .app(movedIndex))
        }
    }

    @Test
    func organizerKeepsSelectedAppWhenMovedAndClosesOnBack() throws {
        try withFolder { folder in
            let tv = TVController(library: AppLibrary(folder: folder))
            let index = try #require(tv.services.firstIndex { $0.id == "youtube" })
            tv.setFocus(.app(index))
            tv.openOrganizer()
            #expect(tv.organizer?.selectedID == "youtube")
            tv.activateOrganizerAction(.later, for: "youtube")
            #expect(tv.organizer?.selectedID == "youtube")
            #expect(tv.arrangedServices.firstIndex { $0.id == "youtube" } == index + 1)
            tv.handleOrganizer(.back)
            #expect(tv.organizer == nil)
        }
    }

    @Test
    func appRequestValidationRejectsWrongTypesAndFixedOrUnknownIDs() throws {
        try withFolder { folder in
            let tv = TVController(library: AppLibrary(folder: folder))
            @MainActor func request(_ path: String, _ json: String) -> HTTPResponse? {
                tv.handleAppsRequest(HTTPRequest(method: "POST", path: path, query: [:], headers: [:], body: Data(json.utf8)))
            }
            let invalid: [(String, String)] = [
                ("/apps/pin", #"{"id":"movies","pinned":1}"#),
                ("/apps/pin", #"{"id":"movies","pinned":"true"}"#),
                ("/apps/pin", #"{"id":"missing","pinned":true}"#),
                ("/apps/pin", #"{"id":"settings","pinned":true}"#),
                ("/apps/move", #"{"id":"youtube","offset":true}"#),
                ("/apps/move", #"{"id":"youtube","offset":"-1"}"#),
                ("/apps/move", #"{"id":"youtube","offset":2}"#),
                ("/apps/move", #"{"id":"missing","offset":-1}"#),
                ("/apps/move", #"{"id":"add-app","offset":-1}"#)
            ]
            let before = tv.services.map(\.id)
            for (path, body) in invalid {
                #expect(request(path, body)?.status == "400 Bad Request")
            }
            #expect(tv.services.map(\.id) == before)
            // 排第二的应用往前挪一格就到了最前面（原版是 YouTube，这个分支里是网易云）
            let second = tv.services[1].id
            #expect(request("/apps/move", #"{"id":"\#(second)","offset":-1}"#)?.status == "200 OK")
            #expect(tv.services.first?.id == second)
            #expect(request("/apps/pin", #"{"id":"movies","pinned":true}"#)?.status == "200 OK")
            #expect(tv.isPinned("movies"))
        }
    }

    @Test func failedWritesRollBackPinsAndOrder() throws {
        try withFolder { folder in
            let library = AppLibrary(folder: folder)
            let before = library.services().map(\.id)
            // A directory at the file path reliably rejects an atomic file replacement.
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("apps.json"), withIntermediateDirectories: true)
            #expect(!library.setPinned("youtube", true))
            #expect(!library.isPinned("youtube"))
            #expect(!library.move("youtube", by: -1))
            #expect(library.services().map(\.id) == before)
            let tv = TVController(library: library)
            let request = HTTPRequest(method: "POST", path: "/apps/pin", query: [:], headers: [:],
                body: Data(#"{"id":"youtube","pinned":true}"#.utf8))
            #expect(tv.handleAppsRequest(request)?.status == "500 Internal Server Error")
        }
    }

}
