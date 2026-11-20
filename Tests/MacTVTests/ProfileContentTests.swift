import AppKit
import Foundation
import Testing
@testable import MacTV

/// The browser, 哔哩哔哩 and movie places per profile, and removing a profile leaving nothing behind. Everything is
/// in a folder of its own: other profiles' defaults are plists inside it and the Keychain is in memory.
@Suite(.serialized) @MainActor struct ProfileContentTests {
    init() {
        _ = NSApplication.shared
        AudioCoordinator.readVolume = { VolumeLevel(level: 50, muted: false) }
    }

    private func withFolder(_ body: (URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            let main = ProfileSpaces.sandbox(folder).enter(Profile.mainID)
            NeteaseAPI.useProfile(main)
            DedaoAPI.useProfile(main)
            try? FileManager.default.removeItem(at: folder)
        }
        try body(folder)
    }

    /// A stand-in for the first profile with its own defaults, so nothing lands in UserDefaults.standard.
    private func mainSpace(_ folder: URL, keychain: ProfileKeychain) -> (ProfileSpace, String) {
        let suite = folder.appendingPathComponent("main.plist").path
        return (ProfileSpace(profileID: Profile.mainID, defaults: UserDefaults(suiteName: suite)!, suiteName: nil, folder: folder,
                             caches: folder.appendingPathComponent("Caches"), keychain: keychain, epoch: 0), suite)
    }

    private func saved(_ key: String, in defaults: UserDefaults, suite: String) -> Any? {
        defaults.persistentDomain(forName: suite)?[key]
    }

    // MARK: Browser

    @Test func eachProfileHasItsOwnTabsHistoryAndZoomAndOnlyTheFirstSeesSafari() throws {
        try withFolder { folder in
            let mainSuite = folder.appendingPathComponent("browser.plist").path
            let mainStorage = BrowserTabStorage(suite: mainSuite, folder: folder.appendingPathComponent("Main Tabs"))
            let spaces = ProfileSpaces.sandbox(folder)
            spaces.enter(Profile.mainID)
            let store = BrowserStore(storage: mainStorage)
            store.newTab(try #require(URL(string: "https://mine.example/")))
            mainStorage.addHistory(try #require(URL(string: "https://mine.example/")), title: "Mine")
            mainStorage.setZoom(2, for: "mine.example")
            #expect(store.showsSafari)

            store.profileWillChange()
            let other = spaces.enter("other")
            store.profileChanged()
            #expect(store.tabs.isEmpty && !store.showsSafari)
            #expect(!store.rows.contains { ["favorites", "frequent", "reading", "permission"].contains($0.id) })
            #expect(!store.rows.contains { $0.id == "recent" })
            store.newTab(try #require(URL(string: "https://theirs.example/")))
            let theirs = BrowserTabStorage.forProfile(other)
            #expect(theirs.load().tabs.map(\.url.host) == ["theirs.example"])
            #expect(theirs.folder.path.hasPrefix(folder.path) && theirs.zoom(for: "mine.example") == nil)
            #expect(mainStorage.load().tabs.map(\.url.host) == ["mine.example"])

            store.profileWillChange()
            spaces.enter(Profile.mainID)
            store.profileChanged()
            #expect(store.tabs.map(\.url.host) == ["mine.example"] && store.showsSafari)
            #expect(mainStorage.history.map(\.title) == ["Mine"] && mainStorage.zoom(for: "mine.example") == 2)
            TestDefaults.remove(mainSuite)
        }
    }

    // MARK: 哔哩哔哩

    private func signedIn(_ mid: Int) throws -> (BiliAccount, [HTTPCookie]) {
        let cookie = try #require(HTTPCookie(properties: [.domain: ".bilibili.com", .path: "/", .name: "SESSDATA", .value: "test-\(mid)"]))
        return (BiliAccount(name: "账号\(mid)", mid: mid), [cookie])
    }

    @Test func bilibiliAccountsArePerProfileAndMoveWithTheirOwner() throws {
        try withFolder { folder in
            let spaces = ProfileSpaces.sandbox(folder)
            let (main, suite) = mainSpace(folder, keychain: spaces.keychain)
            let anna = spaces.space(for: "anna", epoch: 1), ben = spaces.space(for: "ben", epoch: 1)
            for mid in [1, 2, 3] {
                let (account, cookies) = try signedIn(mid)
                BiliAccounts.remember(account, cookies: cookies, in: main)
            }
            #expect(BiliAccounts.list(in: main).map(\.mid) == [3, 2, 1])
            #expect(BiliAccounts.list(in: anna).isEmpty && BiliAccounts.cookies(for: 1, in: anna).isEmpty)

            // 1 is signed in in Anna's own web data, 3 in the first profile's; 2 nowhere.
            BiliAccounts.attribute(main: main, others: [(anna, 1), (ben, 3), (ben, nil)], mainLoggedIn: 3)
            #expect(BiliAccounts.list(in: main).map(\.mid) == [3, 2])
            #expect(BiliAccounts.list(in: anna).map(\.mid) == [1])
            #expect(BiliAccounts.cookies(for: 1, in: anna).map(\.name) == ["SESSDATA"])
            #expect(BiliAccounts.cookies(for: 1, in: main).isEmpty)
            #expect(spaces.keychain.data(service: "Mac TV Bilibili (anna)", account: "1") != nil)
            #expect(spaces.keychain.data(service: "Mac TV Bilibili", account: "1") == nil)
            #expect(BiliAccounts.list(in: ben).isEmpty)

            // Nothing to move: stays where it is.
            #expect(!BiliAccounts.move(9, from: main, to: anna))
            BiliAccounts.forget(1, in: anna)
            #expect(BiliAccounts.list(in: anna).isEmpty && spaces.keychain.data(service: "Mac TV Bilibili (anna)", account: "1") == nil)
            TestDefaults.remove(suite)
        }
    }

    @Test func bilibiliSettingsHistoryAndPlacesArePerProfile() throws {
        try withFolder { folder in
            let keys = ["bilibiliSpeed", "bilibiliSubtitles", "bilibiliDanmaku", "bilibiliSearchHistory", "bilibiliSidebarHidden",
                        "bilibiliResumePositions", "bilibiliDanmakuStyle", "bilibiliAccounts"]
            let standard = UserDefaults.standard
            let domain = Bundle.main.bundleIdentifier ?? ""
            let before = keys.map { standard.persistentDomain(forName: domain)?[$0] as? NSObject }
            let profiles = ProfileStore(folder: folder)
            let second = profiles.add(named: "Second")
            let tv = TVController(library: AppLibrary(folder: folder), profiles: profiles)
            let mainSpeed = tv.bilibiliStore.player.speed

            tv.switchProfile(to: second.id)
            let player = tv.bilibiliStore.player
            #expect(player.speed == 1 && player.subtitlesOn && player.danmakuOn)
            #expect(BiliSearchHistory.all.isEmpty && BiliSidebar.hidden.isEmpty && tv.bilibiliStore.savedAccounts.isEmpty)
            player.speed = 1.5
            BiliSearchHistory.add("猫")
            BiliResume.save(bvid: "BV1test", cid: 7, seconds: 42)
            BiliSidebar.hidden = [.live]
            #expect(BiliResume.position(bvid: "BV1test", cid: 7) == 42)

            tv.switchProfile(to: Profile.mainID)
            #expect(tv.bilibiliStore.player.speed == mainSpeed)
            #expect(keys.map { standard.persistentDomain(forName: domain)?[$0] as? NSObject } == before)

            tv.switchProfile(to: second.id)
            #expect(tv.bilibiliStore.player.speed == 1.5 && BiliSearchHistory.all == ["猫"])
            #expect(BiliResume.position(bvid: "BV1test", cid: 7) == 42 && tv.bilibiliStore.hiddenTabs == [.live])
            tv.switchProfile(to: Profile.mainID)
        }
    }

    // MARK: Movies

    @Test func moviePlacesArePerProfileAndTheLibraryIsShared() throws {
        try withFolder { folder in
            let movies = folder.appendingPathComponent("Movies", isDirectory: true)
            try FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)
            var film = Movie(path: "/test/Film.mkv", title: "Film", added: Date(), size: 1)
            film.position = 600
            film.duration = 6000
            film.lastWatched = Date(timeIntervalSince1970: 1000)
            try JSONEncoder().encode([film]).write(to: movies.appendingPathComponent("library.json"))
            let library = MovieLibrary(folder: movies)
            let spaces = ProfileSpaces.sandbox(folder)
            #expect(library.movie(film.path)?.position == 600 && library.continueWatching.count == 1)

            let other = spaces.space(for: "other", epoch: 1)
            library.use(other)
            #expect(library.movies.count == 1)                        // the same library
            #expect(library.movie(film.path)?.position == nil && library.continueWatching.isEmpty)
            library.record(position: 1200, duration: 6000, for: film)
            #expect(library.movie(film.path)?.position == 1200)
            #expect(FileManager.default.fileExists(atPath: other.folder.appendingPathComponent("movie-positions.json").path))

            library.use(spaces.space(for: Profile.mainID, epoch: 2))
            #expect(library.movie(film.path)?.position == 600)
            #expect(MovieLibrary(folder: movies).movie(film.path)?.position == 600)   // the first profile's, as saved
            library.use(spaces.space(for: "other", epoch: 3))
            #expect(library.movie(film.path)?.position == 1200)
        }
    }

    // MARK: Removing a profile

    @Test func removingAProfileLeavesNothingBehind() throws {
        try withFolder { folder in
            let choiceSuite = folder.appendingPathComponent("choices.plist").path
            let choices = BrowserPreferences(defaults: UserDefaults(suiteName: choiceSuite)!)
            let profiles = ProfileStore(folder: folder)
            let gone = profiles.add(named: "Gone"), stays = profiles.add(named: "Stays")
            let tv = TVController(library: AppLibrary(folder: folder), profiles: profiles, browserPreferences: choices)
            let shared = folder.appendingPathComponent("apps.json")
            try Data("{}".utf8).write(to: shared)
            let icons = folder.appendingPathComponent("Icons", isDirectory: true)
            let layout = folder.appendingPathComponent("apps-\(gone.id).json")
            try Data("{}".utf8).write(to: layout)

            tv.switchProfile(to: gone.id)
            let space = ProfileSpace.current
            space.defaults.set(false, forKey: "autoSkip")
            try FileManager.default.createDirectory(at: space.folder, withIntermediateDirectories: true)
            try Data([0xFF, 0xD8]).write(to: space.folder.appendingPathComponent("Avatar.jpg"))
            try FileManager.default.createDirectory(at: space.caches, withIntermediateDirectories: true)
            let (account, cookies) = try signedIn(5)
            BiliAccounts.remember(account, cookies: cookies)
            choices.setChoice(.brave, for: gone.id)
            choices.setChoice(.brave, for: stays.id)
            YouTubeFeed.remember([], for: .recommended, profile: gone.id)
            #expect(UserDefaults.standard.data(forKey: "youtubeShelfSaved.\(gone.id).recommended") != nil)

            tv.removeProfile(gone.id)
            #expect(tv.profile.id == Profile.mainID && !tv.profiles.all.contains { $0.id == gone.id })
            #expect(UserDefaults(suiteName: tv.spaces.suiteName(for: gone.id))?.persistentDomain(forName: tv.spaces.suiteName(for: gone.id))?["autoSkip"] == nil)
            #expect(!FileManager.default.fileExists(atPath: space.folder.path))
            #expect(!FileManager.default.fileExists(atPath: space.caches.path))
            #expect(!FileManager.default.fileExists(atPath: layout.path))
            #expect(tv.spaces.keychain.data(service: space.keychainService(BiliAccounts.service), account: "5") == nil)
            #expect(UserDefaults.standard.data(forKey: "youtubeShelfSaved.\(gone.id).recommended") == nil)
            #expect(choices.choice(for: gone.id) == .embedded && choices.choice(for: stays.id) == .brave)
            // What everyone shares stays.
            #expect(FileManager.default.fileExists(atPath: shared.path) && FileManager.default.fileExists(atPath: icons.path))
            #expect(tv.profiles.all.contains { $0.id == stays.id })
            // The first profile can't be removed.
            tv.removeProfile(Profile.mainID)
            #expect(tv.profiles.all.contains { $0.id == Profile.mainID })
            TestDefaults.remove(choiceSuite)
        }
    }
}
