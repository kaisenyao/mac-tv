import AppKit
import Foundation
import Testing
import WebKit
@testable import MacTV

/// An app in the background (Home, see AppQuit) runs nothing it only needs on screen: video that finishes loading
/// doesn't start, a live room disconnects, sign-in codes stop being polled, a held seek ends, and a parked web page
/// can't start its own media again. Music and audio books keep playing (their own Background Playback setting).
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct BackgroundLeaksTests {
    init() {
        _ = NSApplication.shared
        AudioCoordinator.readVolume = { VolumeLevel(level: 50, muted: false) }
    }

    /// A TV with everything in a scratch folder and its own defaults, both removed afterwards.
    private func withTV(_ body: (TVController) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacTVTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "MacTVTests.Background.\(UUID().uuidString)"
        defer {
            TestDefaults.remove(suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let tv = TVController(library: AppLibrary(folder: folder), profiles: ProfileStore(folder: folder),
                              services: AppServices(preferences: Preferences(defaults: TestDefaults.named(suite))))
        tv.remoteCoordinator.pairingStore = PairingStore(folder: folder)
        tv.bilibiliStore.tv = tv
        tv.neteaseStore.tv = tv
        tv.dedaoStore.tv = tv
        try await body(tv)
        tv.goHome()
        tv.playbackCoordinator.dropParkedWeb()
    }

    @MainActor
    private func waitUntil(_ timeout: Duration = .seconds(5), _ condition: @MainActor () async -> Bool) async -> Bool {
        let clock = ContinuousClock(), end = clock.now + timeout
        while await !condition() {
            if clock.now > end { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    // MARK: 哔哩哔哩

    @Test func aVideoThatFinishesLoadingInTheBackgroundStaysPaused() async throws {
        try await withTV { tv in
            let player = tv.bilibiliStore.player
            player.pretendOpen(BiliVideo(bvid: "BV1bg", title: "视频", cover: nil, duration: 600, owner: "UP", views: 0), qualities: [80])
            tv.bilibiliOpen = true
            tv.handle(.home)
            #expect(player.inBackground && !tv.bilibiliOpen)
            player.pretendStreamArrived()   // the stream, a quality switch or the end of a scrub, arriving late
            #expect(player.player.rate == 0 && player.paused, "a parked player never starts playing")
            // In front again: still paused (Play goes on), and a stream arriving now plays.
            player.returnFromBackground()
            #expect(!player.inBackground && player.player.rate == 0)
            player.pretendStreamArrived()
            #expect(player.player.rate > 0)
            player.player.pause()
        }
    }

    @Test func aLiveRoomDisconnectsInTheBackground() async throws {
        try await withTV { tv in
            let player = tv.bilibiliStore.player
            player.pretendOpen(BiliVideo(bvid: "live-7", title: "直播", cover: nil, duration: 0, owner: "主播", views: 1, liveRoom: 7), qualities: [])
            player.pretendLiveConnected()
            #expect(player.liveTasksRunning)
            tv.bilibiliOpen = true
            tv.handle(.home)
            #expect(!player.liveTasksRunning, "no watchdog, danmaku or connection in the background")
            #expect(player.player.currentItem == nil && player.player.rate == 0, "the live stream isn't pulled")
            #expect(player.current?.liveRoom == 7, "still the same room, to reconnect from on Play")
        }
    }

    @Test func homeClosesTheSignInPageAndItsQRCode() async throws {
        try await withTV { tv in
            tv.bilibiliStore.qrService = NoQR()
            tv.bilibiliOpen = true
            tv.bilibiliStore.openLogin()
            let qr = try #require(tv.bilibiliStore.login?.qr)
            #expect(qr.running)
            tv.handle(.home)
            #expect(tv.bilibiliStore.login == nil && !qr.running, "the code isn't polled in the background")
        }
    }

    // MARK: 网易云音乐, 得到: a held seek

    private static let lecture = DedaoAPI.Track(id: "t1", title: "第一讲", reader: "讲者", cover: nil, duration: 600, progress: 0,
                                                finished: false, address: nil, fetched: Date(), productEnid: "p", productType: 66,
                                                itemEnid: "i", aliasID: "a", articleID: 1)

    @Test func homeWhileHoldingASeekEndsItInDedao() async throws {
        try await withTV { tv in
            let store = tv.dedaoStore
            store.pretendListening(Self.lecture)
            tv.dedaoOpen = true
            store.beginHold(forward: true)
            #expect(store.holdSeeking && store.player.scrubbing)
            tv.handle(.home)
            #expect(!store.holdSeeking && !store.player.scrubbing, "the 20-a-second timer doesn't stay behind")
            // The key let go afterwards, with 得到 in the background: nothing left to end, nothing goes wrong.
            tv.endHoldSeek()
            #expect(!store.holdSeeking)
        }
    }

    @Test func homeWhileHoldingASeekEndsItInNetease() async throws {
        try await withTV { tv in
            let store = tv.neteaseStore
            store.pretendPlaying(NeteaseSong(id: 1, name: "歌", duration: 200))
            tv.neteaseOpen = true
            store.beginHold(forward: false)
            #expect(store.holdSeeking && store.scrubbing)
            tv.handle(.home)
            #expect(!store.holdSeeking && !store.scrubbing)
        }
    }

    @Test func aHeldSeekLetGoEndsInTheAppThatStartedIt() async throws {
        try await withTV { tv in
            // The phone's Left held in 得到, let go after 得到 left the front: it still ends 得到's seek.
            tv.dedaoStore.pretendListening(Self.lecture)
            tv.dedaoOpen = true
            tv.handle(.press(.left, .hold), from: .remote)
            #expect(tv.dedaoStore.holdSeeking)
            tv.dedaoOpen = false
            tv.handle(.press(.left, .release), from: .remote)
            #expect(!tv.dedaoStore.holdSeeking && !tv.dedaoStore.player.scrubbing)
        }
    }

    // MARK: Web pages

    /// A parked website app's page is paused and its media suspended: the page itself can't start playing again.
    /// Opening the app again lifts the suspension, still paused.
    @Test func aParkedPageCantStartItsOwnMedia() async throws {
        try await withTV { tv in
            let site = Service(id: "test-media", name: "Media", kind: .web(URL(string: "about:blank")!), accent: "#333333", deep: "#111111")
            tv.open(site)
            let web = try #require(tv.webView)
            #expect(await waitUntil { !web.isLoading })
            _ = try? await web.callAsyncJavaScript("""
                const a = document.createElement('audio'); a.id = 'a'; a.loop = true; a.muted = true; a.src = src;
                document.body.appendChild(a);
                """, arguments: ["src": Self.silentWAV], contentWorld: .page)
            tv.handle(.home)
            #expect(tv.playbackCoordinator.parkedWebIDs == [site.id])
            #expect(await waitUntil { await web.requestMediaPlaybackState() == .suspended }, "suspended while parked")
            _ = try? await web.callAsyncJavaScript("try { await document.getElementById('a').play() } catch (e) {}", contentWorld: .page)
            #expect(await web.requestMediaPlaybackState() == .suspended, "the page's own play() doesn't get through")
            tv.open(site)
            #expect(tv.webView === web)
            #expect(await waitUntil { await web.requestMediaPlaybackState() != .suspended }, "lifted on return")
        }
    }

    /// Half a second of silence, as a WAV data address: real media for the page, no sound, no network.
    private static let silentWAV: String = {
        let samples = 4000, rate: UInt32 = 8000
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + samples * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(rate); put(rate * 2); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(UInt32(samples * 2))
        data.append(Data(count: samples * 2))
        return "data:audio/wav;base64," + data.base64EncodedString()
    }()
}

/// A sign-in code service that gives a code and then only "waiting": no network.
private struct NoQR: BiliQRService {
    func generate() async -> BiliQRCode? { BiliQRCode(url: "https://account.bilibili.com/h5/account-h5/auth/scan-web?qrcode_key=t", key: "t") }
    func poll(_ key: String) async -> BiliQRPoll { .waiting }
}
