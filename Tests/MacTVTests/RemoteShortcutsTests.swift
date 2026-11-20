import AppKit
import Foundation
import Testing
@testable import MacTV

/// 手机遥控器的快捷键：能选什么、每个地方显示哪几个、/state 里的样子、/shortcuts 的读写
@Suite @MainActor
struct RemoteShortcutsTests {
    init() { _ = NSApplication.shared }

    // MARK: 选择本身

    @Test func setsHoldAtMostFourKnownShortcutsOnceEach() {
        #expect(RemoteShortcuts.problem(with: ["shortcut", "screensaver", "sleepTimer", "files"], in: "home") == nil)
        #expect(RemoteShortcuts.problem(with: [], in: "home") == nil)
        #expect(RemoteShortcuts.problem(with: ["bilibili.danmaku", "bilibili.quality", "bilibili.speed", "bilibili.subtitles", "bilibili.coin"],
                                        in: "bilibili") != nil)
        #expect(RemoteShortcuts.problem(with: ["screensaver", "screensaver"], in: "home") != nil)
        #expect(RemoteShortcuts.problem(with: ["rewind"], in: "home") != nil)
        #expect(RemoteShortcuts.problem(with: ["screensaver"], in: "youtube") != nil)
    }

    @Test func homeTakesEverywhereShortcutsAndAppsAlsoTheirOwn() {
        #expect(RemoteShortcuts.problem(with: ["bilibili.danmaku"], in: "home") != nil)
        #expect(RemoteShortcuts.problem(with: ["bilibili.danmaku", "screensaver"], in: "bilibili") == nil)
        #expect(RemoteShortcuts.problem(with: ["netease.like"], in: "bilibili") != nil)
        #expect(RemoteShortcuts.problem(with: ["dedao.next", "files", "shortcut"], in: "dedao") == nil)
        for app in RemoteShortcuts.apps {
            #expect(!RemoteShortcuts.own(of: app.id).isEmpty)
            #expect(RemoteShortcuts.own(of: app.id).allSatisfy { RemoteShortcuts.entry($0)?.app == app.id })
        }
        #expect(RemoteShortcuts.everywhere == ["shortcut", "screensaver", "sleepTimer", "files"])
    }

    @Test func defaultsAreTheDesignedSets() {
        let choice = RemoteShortcutChoice()
        #expect(choice.picked(in: "home") == ["shortcut", "screensaver", "sleepTimer", "files"])
        #expect(choice.picked(in: "bilibili") == ["bilibili.danmaku", "bilibili.quality", "bilibili.speed", "bilibili.subtitles"])
        #expect(choice.picked(in: "netease") == ["netease.like", "netease.lyrics", "netease.mode", "netease.daily"])
        #expect(choice.picked(in: "dedao") == ["dedao.speed", "dedao.transcript", "dedao.timer", "dedao.next"])
        #expect(RemoteShortcuts.apps.allSatisfy { choice.hasOwn($0.id) })
        #expect(choice.appleShortcut.isEmpty)
        // Every default is a valid set
        for (scope, ids) in RemoteShortcuts.defaults { #expect(RemoteShortcuts.problem(with: ids, in: scope) == nil) }
    }

    @Test func anEmptyAppSetAndOtherAppsUseHome() {
        var choice = RemoteShortcutChoice()
        let problem1 = choice.choose(["files", "screensaver"], for: "home")
        #expect(problem1 == nil)
        let problem2 = choice.choose([], for: "netease")
        #expect(problem2 == nil)
        #expect(!choice.hasOwn("netease"))
        #expect(choice.picked(in: "netease") == ["files", "screensaver"])
        #expect(choice.picked(in: "youtube") == ["files", "screensaver"])
        #expect(choice.picked(in: "bilibili") == RemoteShortcuts.defaults["bilibili"])
        // A refused set leaves the choice as it was
        let problem3 = choice.choose(["netease.like"], for: "home")
        #expect(problem3 != nil)
        #expect(choice.picked(in: "home") == ["files", "screensaver"])
    }

    @Test func savedChoiceComesBackAndDropsWhatNoLongerFits() throws {
        let suite = "MacTVTests.\(UUID().uuidString)"
        let defaults = TestDefaults.named(suite)
        defer { TestDefaults.remove(suite) }
        var choice = RemoteShortcutChoice()
        let problem4 = choice.choose(["bilibili.coin", "files"], for: "bilibili")
        #expect(problem4 == nil)
        let accepted7 = choice.chooseAppleShortcut("  Movie Night ")
        #expect(accepted7)
        choice.save(to: defaults)
        #expect(RemoteShortcutChoice.load(from: defaults) == choice)
        #expect(RemoteShortcutChoice.load(from: defaults).appleShortcut == "Movie Night")

        defaults.set(["home": ["gone", "files", "files", "netease.like", "screensaver"], "dedao": ["dedao.next", 3]],
                     forKey: RemoteShortcutChoice.setsKey)
        let cleaned = RemoteShortcutChoice.load(from: defaults)
        #expect(cleaned.picked(in: "home") == ["files", "screensaver"])
        #expect(cleaned.picked(in: "dedao") == RemoteShortcuts.defaults["dedao"])   // not a list of names: its default

        let accepted8 = choice.chooseAppleShortcut("Two\nlines")

        #expect(!accepted8)
        let accepted9 = choice.chooseAppleShortcut("")
        #expect(accepted9)
        #expect(choice.appleShortcut.isEmpty)
    }

    @Test func shortcutsListAndTimeLeftRead() {
        #expect(AppleShortcuts.names(fromList: Data("Movie Night\n  Lights off \n\nMovie Night\n".utf8)) == ["Movie Night", "Lights off"])
        #expect(AppleShortcuts.names(fromList: Data()).isEmpty)
        #expect(RemoteShortcuts.minutesText(25) == "25 min")
        #expect(RemoteShortcuts.minutesText(60) == "1 hr")
        #expect(RemoteShortcuts.minutesText(90) == "1 hr 30 min")
    }

    // MARK: 指令

    @Test func rewindAndForwardAreGoneAndShortcutsCarryTheirID() {
        #expect(RemoteCommand(json: ["a": "rewind"]) == nil)
        #expect(RemoteCommand(json: ["a": "forward"]) == nil)
        if case .shortcut("bilibili.danmaku")? = RemoteCommand(json: ["a": "shortcut", "id": "bilibili.danmaku"]) {} else {
            Issue.record("快捷键")
        }
        #expect(RemoteCommand(json: ["a": "shortcut"]) == nil)
        #expect(RemoteCommand(json: ["a": "shortcut", "id": ""]) == nil)
    }

    @Test func pressesThatDontBelongOrDoNothingAreIgnored() throws {
        try withController { tv, _ in
            let danmaku = tv.bilibiliStore.player.danmakuOn
            tv.runShortcut("bilibili.danmaku", from: .remote)   // not in 哔哩哔哩
            tv.bilibiliOpen = true
            tv.runShortcut("bilibili.danmaku", from: .remote)   // in 哔哩哔哩, but no video
            tv.runShortcut("no.such.shortcut", from: .remote)
            #expect(tv.bilibiliStore.player.danmakuOn == danmaku)
            #expect(!tv.remoteCoordinator.appleShortcutRunning)
            tv.runShortcut("shortcut", from: .remote)           // no Apple Shortcut chosen: the phone opens the picker
            #expect(!tv.remoteCoordinator.appleShortcutRunning)
        }
    }

    @Test func runShortcutRunsTheChosenOneOnceAtATime() async throws {
        let ran = NamesBox()
        try await withController { tv, _ in
            tv.remoteCoordinator.runAppleShortcutNamed = { name in await ran.add(name); return .done }
            var choice = tv.remoteCoordinator.shortcutChoice
            let accepted10 = choice.chooseAppleShortcut("Movie Night")
            #expect(accepted10)
            tv.remoteCoordinator.shortcutChoice = choice
            #expect(tv.remoteCoordinator.runAppleShortcut())
            #expect(!tv.remoteCoordinator.runAppleShortcut())   // still running
            for _ in 0..<100 where tv.remoteCoordinator.appleShortcutRunning { try await Task.sleep(for: .milliseconds(10)) }
            #expect(!tv.remoteCoordinator.appleShortcutRunning)
        }
        #expect(await ran.names == ["Movie Night"])
    }

    // MARK: /state

    @Test func stateShowsHomeShortcuts() throws {
        try withController { tv, _ in
            let shortcuts = try #require(tv.remoteState()["shortcuts"] as? [String: Any])
            #expect(shortcuts["context"] as? String == "home")
            let items = try #require(shortcuts["items"] as? [[String: Any]])
            #expect(items.map { $0["id"] as? String } == ["shortcut", "screensaver", "sleepTimer", "files"])
            #expect(items[0]["title"] as? String == "Run Shortcut" && items[0]["icon"] as? String == "shortcut")
            #expect(items[0]["phone"] as? Bool == true && items[0]["value"] == nil)   // nothing chosen: the phone opens the picker
            #expect(items[1]["phone"] as? Bool == false && items[1]["enabled"] as? Bool == true)
            #expect(items[2]["phone"] as? Bool == true && items[2]["icon"] as? String == "sleep")
            #expect(items[3]["phone"] as? Bool == true)
            #expect(items.allSatisfy { Set($0.keys).isSubset(of: ["id", "title", "icon", "value", "enabled", "phone"]) })

            var choice = tv.remoteCoordinator.shortcutChoice
            _ = choice.chooseAppleShortcut("Movie Night")
            tv.remoteCoordinator.shortcutChoice = choice
            let chosen = try #require((tv.shortcutState()["items"] as? [[String: Any]])?.first)
            #expect(chosen["value"] as? String == "Movie Night" && chosen["phone"] as? Bool == false && chosen["enabled"] as? Bool == true)
        }
    }

    @Test func stateFollowsTheAppOnScreen() throws {
        try withController { tv, _ in
            tv.bilibiliOpen = true
            let state = tv.shortcutState()
            #expect(state["context"] as? String == "bilibili")
            let items = try #require(state["items"] as? [[String: Any]])
            #expect(items.map { $0["id"] as? String } == ["bilibili.danmaku", "bilibili.quality", "bilibili.speed", "bilibili.subtitles"])
            #expect(items.allSatisfy { $0["enabled"] as? Bool == false && $0["phone"] as? Bool == false })   // no video playing
            #expect(items[0]["title"] as? String == "弹幕")
            #expect(items[0]["value"] as? String == (tv.bilibiliStore.player.danmakuOn ? "打开" : "关闭"))

            // Fewer than four stay fewer, and an app's set may mix in the everywhere ones
            var choice = tv.remoteCoordinator.shortcutChoice
            let problem5 = choice.choose(["screensaver", "bilibili.favorite"], for: "bilibili")
            #expect(problem5 == nil)
            let problem6 = choice.choose([], for: "netease")
            #expect(problem6 == nil)
            tv.remoteCoordinator.shortcutChoice = choice
            #expect((tv.shortcutState()["items"] as? [[String: Any]])?.map { $0["id"] as? String } == ["screensaver", "bilibili.favorite"])

            tv.bilibiliOpen = false
            tv.neteaseOpen = true
            let netease = tv.shortcutState()
            #expect(netease["context"] as? String == "netease")
            #expect((netease["items"] as? [[String: Any]])?.map { $0["id"] as? String } == RemoteShortcuts.defaults["home"])
        }
    }

    @Test func guestsSeeShortcutsTheyCantPress() throws {
        try withServer { tv, server, owner, guest in
            var choice = tv.remoteCoordinator.shortcutChoice
            _ = choice.chooseAppleShortcut("Movie Night")
            tv.remoteCoordinator.shortcutChoice = choice
            @MainActor func items(_ token: String) throws -> [[String: Any]] {
                let response = server.respond(to: HTTPRequest(method: "GET", path: "/state", query: [:], headers: ["x-couch-key": token], body: Data()))
                let state = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
                return try #require((state["shortcuts"] as? [String: Any])?["items"] as? [[String: Any]])
            }
            #expect(try items(owner).first?["value"] as? String == "Movie Night")
            let seen = try items(guest)
            #expect(seen.count == 4 && seen.allSatisfy { $0["enabled"] as? Bool == false })
            #expect(seen.first?["value"] == nil)
            let press = try JSONSerialization.data(withJSONObject: ["a": "shortcut", "id": "screensaver"])
            #expect(server.respond(to: HTTPRequest(method: "POST", path: "/cmd", query: [:], headers: ["x-couch-key": guest], body: press)).status
                    == "403 Forbidden")
        }
    }

    // MARK: /shortcuts

    @Test func settingsRoutesReadAndSaveTheChoice() throws {
        try withServer { tv, server, owner, _ in
            @MainActor func call(_ method: String, _ path: String, _ body: [String: Any]? = nil) throws -> (String, [String: Any]) {
                let data = try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
                let response = server.respond(to: HTTPRequest(method: method, path: path, query: [:], headers: ["x-couch-key": owner], body: data))
                return (response.status, try JSONSerialization.jsonObject(with: response.body) as? [String: Any] ?? [:])
            }
            let (status, settings) = try call("GET", "/shortcuts")
            #expect(status == "200 OK")
            #expect(settings["home"] as? [String] == RemoteShortcuts.defaults["home"])
            #expect(settings["everywhere"] as? [String] == RemoteShortcuts.everywhere)
            #expect(settings["appleShortcut"] as? String == "")
            let catalog = try #require(settings["catalog"] as? [String: [String: String]])
            #expect(catalog["bilibili.favorite"] == ["title": "收藏", "icon": "star"])
            #expect(catalog.count == RemoteShortcuts.catalog.count)
            let apps = try #require(settings["apps"] as? [[String: Any]])
            #expect(apps.map { $0["id"] as? String } == ["bilibili", "netease", "dedao"])
            #expect(apps[0]["name"] as? String == "哔哩哔哩" && apps[0]["own"] as? Bool == true)
            #expect(apps[0]["available"] as? [String] == RemoteShortcuts.own(of: "bilibili"))
            #expect(apps[0]["picked"] as? [String] == RemoteShortcuts.defaults["bilibili"])

            let (saved, after) = try call("POST", "/shortcuts/set", ["scope": "home", "ids": ["files", "screensaver"]])
            #expect(saved == "200 OK" && after["home"] as? [String] == ["files", "screensaver"])
            let (emptied, fallback) = try call("POST", "/shortcuts/set", ["scope": "dedao", "ids": [String]()])
            let dedao = (fallback["apps"] as? [[String: Any]])?.last
            #expect(emptied == "200 OK" && dedao?["own"] as? Bool == false && dedao?["picked"] as? [String] == ["files", "screensaver"])
            #expect(tv.remoteCoordinator.shortcutChoice.picked(in: "dedao") == ["files", "screensaver"])

            for bad: [String: Any] in [["scope": "home", "ids": ["bilibili.danmaku"]],
                                       ["scope": "bilibili", "ids": ["netease.like"]],
                                       ["scope": "bilibili", "ids": ["files", "files"]],
                                       ["scope": "netease", "ids": ["netease.like", "netease.lyrics", "netease.mode", "netease.daily", "files"]],
                                       ["scope": "home", "ids": ["nope"]],
                                       ["scope": "youtube", "ids": ["files"]],
                                       ["scope": "home"]] {
                let (refused, error) = try call("POST", "/shortcuts/set", bad)
                #expect(refused == "400 Bad Request" && error["error"] is String)
            }
            #expect(tv.remoteCoordinator.shortcutChoice.picked(in: "home") == ["files", "screensaver"])

            let (named, chosen) = try call("POST", "/shortcuts/apple", ["name": "Movie Night"])
            #expect(named == "200 OK" && chosen["appleShortcut"] as? String == "Movie Night")
            #expect(try call("POST", "/shortcuts/apple", ["name": "a\nb"]).0 == "400 Bad Request")
            #expect(try call("POST", "/shortcuts/apple", ["name": ""]).1["appleShortcut"] as? String == "")
        }
    }

    @Test func appleShortcutsListComesOffTheMainThread() async throws {
        try await withServer { tv, server, owner, _ in
            let request = HTTPRequest(method: "GET", path: "/shortcuts/apple", query: [:], headers: ["x-couch-key": owner], body: Data())
            tv.remoteCoordinator.listAppleShortcuts = { ["Movie Night", "Lights off"] }
            let listed = await server.answer(request)
            #expect(listed.status == "200 OK")
            let names = try JSONSerialization.jsonObject(with: listed.body) as? [String: [String]]
            #expect(names?["names"] == ["Movie Night", "Lights off"])
            tv.remoteCoordinator.listAppleShortcuts = { nil }
            let failed = await server.answer(request)
            #expect(failed.status == "500 Internal Server Error")
            #expect((try JSONSerialization.jsonObject(with: failed.body) as? [String: Any])?["error"] is String)
        }
    }

    @Test func settingsNeedATrustedRemote() throws {
        try withServer { _, server, _, guest in
            for (method, path) in [("GET", "/shortcuts"), ("POST", "/shortcuts/set"), ("GET", "/shortcuts/apple"), ("POST", "/shortcuts/apple")] {
                let body = try JSONSerialization.data(withJSONObject: ["scope": "home", "ids": ["files"], "name": "x"])
                #expect(server.respond(to: HTTPRequest(method: method, path: path, query: [:], headers: ["x-couch-key": guest], body: body)).status
                        == "403 Forbidden")
                #expect(server.respond(to: HTTPRequest(method: method, path: path, query: [:], headers: [:], body: body)).status
                        == "401 Unauthorized")
            }
        }
    }

    // MARK: 搭台子

    private func withController(_ body: @MainActor (TVController, UserDefaults) throws -> Void) throws {
        let (tv, defaults, cleanUp) = try makeController()
        defer { cleanUp() }
        try body(tv, defaults)
    }

    private func withController(_ body: @MainActor (TVController, UserDefaults) async throws -> Void) async throws {
        let (tv, defaults, cleanUp) = try makeController()
        defer { cleanUp() }
        try await body(tv, defaults)
    }

    private func makeController() throws -> (TVController, UserDefaults, () -> Void) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/shortcuts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "MacTVTests.\(UUID().uuidString)"
        let defaults = TestDefaults.named(suite)
        let tv = TVController(library: AppLibrary(folder: folder))
        tv.remoteCoordinator.shortcutDefaults = defaults
        return (tv, defaults, {
            TestDefaults.remove(suite)
            try? FileManager.default.removeItem(at: folder)
        })
    }

    private func withServer(_ body: @MainActor (TVController, RemoteServer, String, String) throws -> Void) throws {
        let (tv, server, owner, guest, cleanUp) = try makeServer()
        defer { cleanUp() }
        try body(tv, server, owner, guest)
    }

    private func withServer(_ body: @MainActor (TVController, RemoteServer, String, String) async throws -> Void) async throws {
        let (tv, server, owner, guest, cleanUp) = try makeServer()
        defer { cleanUp() }
        try await body(tv, server, owner, guest)
    }

    private func makeServer() throws -> (TVController, RemoteServer, String, String, () -> Void) {
        let (tv, _, cleanController) = try makeController()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/shortcut-pairs-\(UUID().uuidString)")
        let store = PairingStore(folder: folder)
        let owner = try store.issue(name: "Owner", guest: false)
        let guest = try store.issue(name: "Guest", guest: true)
        let server = RemoteServer(token: "", onCommand: { _ in }, state: { tv.remoteState() }, icon: { _ in nil },
                                  routes: { tv.handleAppsRequest($0) }, pairing: store)
        return (tv, server, owner, guest, {
            server.stop()
            cleanController()
            try? FileManager.default.removeItem(at: folder)
        })
    }
}

/// Names an injected runner was called with.
private actor NamesBox {
    private(set) var names: [String] = []
    func add(_ name: String) { names.append(name) }
}
