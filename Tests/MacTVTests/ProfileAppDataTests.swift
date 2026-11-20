import AppKit
import Foundation
import Testing
@testable import MacTV

/// 网易云、得到：每个人（个人资料）一份登录、设置和播放器，换人时不带过去；换人前发出去的请求回来，
/// 不会把上一个人的登录信息记到下一个人身上。只用测试自己文件夹里的设置，不碰真的
@Suite(.serialized) @MainActor struct ProfileAppDataTests {
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

    /// What's saved, not counting the defaults the apps register for everyone
    private func saved(_ keys: [String], in defaults: UserDefaults = .standard, suite: String? = nil) -> [NSObject?] {
        let domain = defaults.persistentDomain(forName: suite ?? Bundle.main.bundleIdentifier ?? "") ?? [:]
        return keys.map { domain[$0] as? NSObject }
    }

    private func response(_ url: URL, cookie: String) throws -> HTTPURLResponse {
        try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Set-Cookie": cookie]))
    }

    // MARK: 网易云

    @Test func neteaseLoginsArePerProfileAndLateAnswersAreDropped() throws {
        try withFolder { folder in
            let spaces = ProfileSpaces.sandbox(folder)
            let anna = spaces.enter("anna")
            NeteaseAPI.useProfile(anna)
            #expect(!NeteaseAPI.hasLogin)
            #expect(NeteaseAPI.importLogin(["MUSIC_U": "anna-token", "__csrf": "a"], epoch: anna.epoch))
            #expect(NeteaseAPI.hasLogin)
            #expect((anna.defaults.dictionary(forKey: NeteaseAPI.storeKey) as? [String: String])?["MUSIC_U"] == "anna-token")
            let annasLogin = NeteaseAPI.login

            let ben = spaces.enter("ben")
            NeteaseAPI.useProfile(ben)
            #expect(!NeteaseAPI.hasLogin)
            // Anna's sign-in finishing after the switch doesn't become Ben's.
            #expect(!NeteaseAPI.importLogin(["MUSIC_U": "late"], epoch: anna.epoch))
            let url = try #require(URL(string: "https://music.163.com/weapi/x"))
            NeteaseAPI.remember(try response(url, cookie: "MUSIC_U=renewed; Path=/"), for: url, sent: annasLogin)
            #expect(!NeteaseAPI.hasLogin)
            #expect(ben.defaults.object(forKey: NeteaseAPI.storeKey) == nil)
            #expect(!NeteaseAPI.isCurrent(annasLogin))
            // Anna's last play report goes out with her own sign-in.
            let pinned = NeteaseAPI.$pinned.withValue(annasLogin) { NeteaseAPI.login.cookies["MUSIC_U"] }
            #expect(pinned == "anna-token")

            // Ben's own answers are kept.
            NeteaseAPI.remember(try response(url, cookie: "__csrf=b; Path=/"), for: url, sent: NeteaseAPI.login)
            #expect((ben.defaults.dictionary(forKey: NeteaseAPI.storeKey) as? [String: String])?["__csrf"] == "b")

            // Back to Anna: still signed in; signing out is hers only.
            NeteaseAPI.useProfile(spaces.enter("anna"))
            #expect(NeteaseAPI.login.cookies["MUSIC_U"] == "anna-token")
            NeteaseAPI.forgetLogin()
            #expect(anna.defaults.object(forKey: NeteaseAPI.storeKey) == nil)
            #expect(ben.defaults.object(forKey: NeteaseAPI.storeKey) != nil)
        }
    }

    @Test func neteaseSettingsArePerProfileAndAreNotWrittenWhenRead() throws {
        try withFolder { folder in
            let keys = ["neteaseBackground", "neteaseBalance", "neteaseQuality", "neteaseMode", "neteaseLogin"]
            let before = saved(keys)
            let profiles = ProfileStore(folder: folder)
            let second = profiles.add(named: "Second")
            let tv = TVController(library: AppLibrary(folder: folder), profiles: profiles)
            let mainBackground = tv.neteaseStore.backgroundPlay
            try FileManager.default.createDirectory(at: tv.spaces.folder(for: second.id), withIntermediateDirectories: true)
            let suite = try #require(UserDefaults(suiteName: tv.spaces.suiteName(for: second.id)))
            suite.set(false, forKey: "neteaseBackground")
            suite.set("lossless", forKey: "neteaseQuality")

            tv.switchProfile(to: second.id)
            #expect(!tv.neteaseStore.backgroundPlay && tv.neteaseStore.preferredLevel == "lossless")
            #expect(tv.neteaseStore.balanceVolume && tv.neteaseStore.mode == .list)   // never changed: the defaults
            #expect(saved(["neteaseBalance"], in: suite, suite: tv.spaces.suiteName(for: second.id)) == [nil])   // reading saved nothing
            #expect(tv.neteaseStore.account == nil && tv.neteaseStore.home.isEmpty)

            tv.switchProfile(to: Profile.mainID)
            #expect(tv.neteaseStore.backgroundPlay == mainBackground)
            #expect(saved(keys) == before)
        }
    }

    // MARK: 得到

    @Test func dedaoSignInsArePerProfileAndLateCookiesAreDropped() throws {
        try withFolder { folder in
            let spaces = ProfileSpaces.sandbox(folder)
            let anna = spaces.enter("anna")
            DedaoAPI.useProfile(anna)
            let url = DedaoAPI.site
            DedaoCookies.take(try response(url, cookie: "GAT=anna; Path=/"), from: url, sent: DedaoCookies.login)
            #expect(DedaoCookies.signedIn)
            #expect((anna.defaults.dictionary(forKey: DedaoCookies.storeKey) as? [String: String])?["GAT"] == "anna")
            let annasLogin = DedaoCookies.login

            let ben = spaces.enter("ben")
            DedaoAPI.useProfile(ben)
            #expect(!DedaoCookies.signedIn)
            DedaoCookies.take(try response(url, cookie: "GAT=late; Path=/"), from: url, sent: annasLogin)
            DedaoCookies.markSignedIn(annasLogin)
            #expect(!DedaoCookies.signedIn)
            #expect(ben.defaults.object(forKey: DedaoCookies.storeKey) == nil)
            let pinned = DedaoCookies.$pinned.withValue(annasLogin) { DedaoCookies.value("GAT") }
            #expect(pinned == "anna")

            DedaoAPI.useProfile(spaces.enter("anna"))
            #expect(DedaoCookies.value("GAT") == "anna")
            DedaoCookies.clear()
            #expect(anna.defaults.object(forKey: DedaoCookies.storeKey) == nil)
        }
    }

    @Test func dedaoSettingsAndContentStartOverForAnotherProfile() throws {
        try withFolder { folder in
            let keys = ["dedaoSpeed", "dedaoAutoNext", "dedaoHiddenSections", "dedaoLogin"]
            let before = saved(keys)
            let profiles = ProfileStore(folder: folder)
            let second = profiles.add(named: "Second")
            let tv = TVController(library: AppLibrary(folder: folder), profiles: profiles)
            let mainSpeed = tv.dedaoStore.player.speed

            tv.switchProfile(to: second.id)
            #expect(tv.dedaoStore.player.speed == 1 && tv.dedaoStore.player.autoNext)
            #expect(DedaoStore.hiddenSections.isEmpty && tv.dedaoStore.user == nil && tv.dedaoStore.player.queue.isEmpty)
            tv.dedaoStore.player.setSpeed(1.5)
            tv.dedaoStore.player.autoNext = false
            DedaoStore.hiddenSections = ["历史"]
            let suite = try #require(UserDefaults(suiteName: tv.spaces.suiteName(for: second.id)))
            #expect(suite.object(forKey: "dedaoSpeed") as? Float == 1.5 && suite.object(forKey: "dedaoAutoNext") as? Bool == false)

            tv.switchProfile(to: Profile.mainID)
            #expect(tv.dedaoStore.player.speed == mainSpeed)
            #expect(saved(keys) == before)

            tv.switchProfile(to: second.id)
            #expect(tv.dedaoStore.player.speed == 1.5 && !tv.dedaoStore.player.autoNext)
            #expect(DedaoStore.hiddenSections == ["历史"])
            tv.switchProfile(to: Profile.mainID)
        }
    }
}
