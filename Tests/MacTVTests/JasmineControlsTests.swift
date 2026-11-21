import AppKit
import Foundation
import Testing
@testable import MacTV

/// Jasmine's playback commands: what's said that needs no model, and what each player does with next, previous,
/// skip, seek, start over, subtitles and speed, or why it can't. The players are Mac TV's own, pretending to play
/// (no stream, no account, no network), and Videos plays on an engine that only writes down what it's asked.
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct JasmineControlsTests {
    init() { _ = NSApplication.shared }

    // MARK: What's said

    private static let apps = [(id: "bilibili", name: "哔哩哔哩"), (id: "youtube", name: "YouTube")]
    private static func heard(_ text: String) -> JasmineCommand? { LocalCommand.match(text, apps: apps) }

    @Test func playPauseNextAndPreviousNeedNoModel() {
        for phrase in ["暂停", "暂停一下", "停", "Pause.", "Stop"] { #expect(Self.heard(phrase) == .playback(.pause), "\(phrase)") }
        for phrase in ["继续", "播放", "继续播放", "接着放", "Play", "Resume."] { #expect(Self.heard(phrase) == .playback(.play), "\(phrase)") }
        for phrase in ["下一首", "下一个", "下一集", "下一首。", "请放下一首", "切歌", "Next", "Next song", "Next episode."] {
            #expect(Self.heard(phrase) == .playback(.next), "\(phrase)")
        }
        for phrase in ["上一首", "上一个", "上一集", "Previous", "Previous track", "Previous episode"] {
            #expect(Self.heard(phrase) == .playback(.previous), "\(phrase)")
        }
    }

    @Test func skippingByAnAmountNeedsNoModel() {
        #expect(Self.heard("快进") == .playback(.skip(10)))
        #expect(Self.heard("快退") == .playback(.skip(-10)))
        #expect(Self.heard("Skip forward") == .playback(.skip(10)))
        #expect(Self.heard("Rewind") == .playback(.skip(-10)))
        #expect(Self.heard("快进30秒") == .playback(.skip(30)))
        #expect(Self.heard("快进 30 秒。") == .playback(.skip(30)))
        #expect(Self.heard("快进三十秒") == .playback(.skip(30)))
        #expect(Self.heard("快进一分钟") == .playback(.skip(60)))
        #expect(Self.heard("快进1分30秒") == .playback(.skip(90)))
        #expect(Self.heard("快进半分钟") == .playback(.skip(30)))
        #expect(Self.heard("往前跳两分钟") == .playback(.skip(120)))
        #expect(Self.heard("往前跳 5 分钟") == .playback(.skip(300)))
        #expect(Self.heard("后退10秒") == .playback(.skip(-10)))
        #expect(Self.heard("后退十五秒钟") == .playback(.skip(-15)))
        #expect(Self.heard("快退一百二十秒") == .playback(.skip(-120)))
        #expect(Self.heard("倒退一分钟") == .playback(.skip(-60)))
        #expect(Self.heard("Skip forward 30 seconds") == .playback(.skip(30)))
        #expect(Self.heard("Fast forward two minutes.") == .playback(.skip(120)))
        #expect(Self.heard("Skip ahead a minute") == .playback(.skip(60)))
        #expect(Self.heard("Go back 10 seconds") == .playback(.skip(-10)))
        #expect(Self.heard("Rewind twenty-five seconds") == .playback(.skip(-25)))
        #expect(Self.heard("Skip back 1 minute and 30 seconds") == .playback(.skip(-90)))
        #expect(Self.heard("往后跳30秒") == nil, "later or earlier: not decided here")
        #expect(Self.heard("快进一点") == nil)
        #expect(Self.heard("快进到精彩的地方") == nil)
        #expect(Self.heard("快进0秒") == nil)
    }

    @Test func aTimeToGoToAndStartingOverNeedNoModel() {
        #expect(Self.heard("跳到10分钟") == .playback(.seek(600)))
        #expect(Self.heard("跳到第五分钟") == .playback(.seek(300)))
        #expect(Self.heard("跳到1分30秒") == .playback(.seek(90)))
        #expect(Self.heard("跳到一小时十分钟的地方") == .playback(.seek(4200)))
        #expect(Self.heard("Jump to 2 minutes") == .playback(.seek(120)))
        #expect(Self.heard("Go to ten minutes") == .playback(.seek(600)))
        for phrase in ["从头放", "从头开始", "从头播放", "重新播放", "Start over", "Restart.", "Play from the beginning"] {
            #expect(Self.heard(phrase) == .playback(.seek(0)), "\(phrase)")
        }
        #expect(Self.heard("跳到下一段") == nil)
        #expect(Self.heard("Go to YouTube") == .open("youtube"), "an app is still an app")
    }

    @Test func subtitlesAndSpeedNeedNoModel() {
        for phrase in ["打开字幕", "开字幕", "显示字幕", "Subtitles on", "Turn on subtitles", "Turn on the captions"] {
            #expect(Self.heard(phrase) == .playback(.subtitles(true)), "\(phrase)")
        }
        for phrase in ["关掉字幕", "关闭字幕", "关字幕", "Subtitles off", "Turn off subtitles", "Hide subtitles"] {
            #expect(Self.heard(phrase) == .playback(.subtitles(false)), "\(phrase)")
        }
        #expect(Self.heard("两倍速") == .playback(.speed(2)))
        #expect(Self.heard("2倍速") == .playback(.speed(2)))
        #expect(Self.heard("1.5倍速") == .playback(.speed(1.5)))
        #expect(Self.heard("1.25 倍速播放") == .playback(.speed(1.25)))
        #expect(Self.heard("一点五倍速") == .playback(.speed(1.5)))
        #expect(Self.heard("零点七五倍") == .playback(.speed(0.75)))
        #expect(Self.heard("调到两倍速") == .playback(.speed(2)))
        #expect(Self.heard("倍速调到1.5倍") == .playback(.speed(1.5)))
        #expect(Self.heard("1.5x") == .playback(.speed(1.5)))
        #expect(Self.heard("2x speed") == .playback(.speed(2)))
        #expect(Self.heard("Play at 1.5x") == .playback(.speed(1.5)))
        #expect(Self.heard("Two times speed") == .playback(.speed(2)))
        #expect(Self.heard("Speed one point five x") == .playback(.speed(1.5)))
        for phrase in ["正常速度", "原速", "恢复正常速度", "Normal speed", "一倍速", "1x"] {
            #expect(Self.heard(phrase) == .playback(.speed(1)), "\(phrase)")
        }
        #expect(Self.heard("100倍速") == nil)
        #expect(Self.heard("字幕太小了") == nil)
        #expect(Self.heard("打开中文字幕") == nil, "a language is the model's")
    }

    @Test func theVolumeNeedsNoModel() {
        #expect(Self.heard("静音") == .mute(true))
        #expect(Self.heard("取消静音") == .mute(false))
        #expect(Self.heard("Unmute") == .mute(false))
        #expect(Self.heard("大声一点") == .volumeStep(10))
        #expect(Self.heard("小声一点") == .volumeStep(-10))
        #expect(Self.heard("声音大一点") == .volumeStep(10))
        #expect(Self.heard("Louder") == .volumeStep(10))
        #expect(Self.heard("Turn the volume down") == .volumeStep(-10))
        #expect(Self.heard("音量调到30") == .volume(30))
        #expect(Self.heard("音量调到三十") == .volume(30))
        #expect(Self.heard("把音量调到 50。") == .volume(50))
        #expect(Self.heard("音量调到百分之二十") == .volume(20))
        #expect(Self.heard("音量 100") == .volume(100))
        #expect(Self.heard("Set the volume to 40") == .volume(40))
        #expect(Self.heard("Volume 25 percent") == .volume(25))
        #expect(Self.heard("Volume to fifty") == .volume(50))
        #expect(Self.heard("音量调到200") == nil)
        #expect(Self.heard("音量调到 1.5") == nil)
        #expect(Self.heard("音量调到合适") == nil)
    }

    @Test func anythingMoreThanTheCommandGoesOn() {
        for phrase in ["放周杰伦的歌", "播放周杰伦", "下一首放周杰伦", "暂停之后提醒我", "我想听下一首歌是什么", "Play some jazz",
                       "Next time skip the intro", "快进到他出场", "Pause the movie when she comes in", "2倍的价钱", "字幕", "倍速"] {
            #expect(Self.heard(phrase) == nil, "\(phrase)")
        }
    }

    @Test func numbersAsTheyreSaid() {
        #expect(Spoken.number("30") == 30 && Spoken.number("1.5") == 1.5)
        #expect(Spoken.number("十") == 10 && Spoken.number("十五") == 15 && Spoken.number("二十") == 20 && Spoken.number("九十九") == 99)
        #expect(Spoken.number("一百") == 100 && Spoken.number("一百零五") == 105 && Spoken.number("两百三十") == 230)
        #expect(Spoken.number("一点二五") == 1.25 && Spoken.number("零点五") == 0.5)
        #expect(Spoken.number("thirty") == 30 && Spoken.number("fortyfive") == 45 && Spoken.number("nineteen") == 19)
        #expect(Spoken.number("onepointtwofive") == 1.25)
        #expect(Spoken.number("二五") == nil && Spoken.number("") == nil && Spoken.number("jazz") == nil && Spoken.number("1.2.3") == nil)
        #expect(Spoken.seconds("90秒") == 90 && Spoken.seconds("一个小时") == 3600 && Spoken.seconds("1.5分钟") == 90)
        #expect(Spoken.seconds("halfaminute") == 30 && Spoken.seconds("2mins") == 120 && Spoken.seconds("anhour") == 3600)
        #expect(Spoken.seconds("") == nil && Spoken.seconds("三十") == nil && Spoken.seconds("1.5秒") == nil && Spoken.seconds("两天") == nil)
    }

    // MARK: Nothing playing

    private static func control(_ tv: TVController, _ action: String, seconds: Int? = nil, speed: Double? = nil) -> String {
        tv.performJasmine(ToolCall(id: "c", name: "control", arguments: [
            "action": action, "seconds": seconds.map { $0 as Any } ?? NSNull(), "speed": speed.map { $0 as Any } ?? NSNull(),
        ]))
    }
    private static let done = #"{"ok":true}"#

    @Test func withNothingPlayingEveryActionSaysSo() async throws {
        try await JasmineTests.withJasmine { rig in
            let tv = rig.tv
            for action in ["play", "pause", "next", "previous", "restart", "subtitles_on", "subtitles_off"] {
                #expect(Self.control(tv, action) == #"{"error":"nothing is playing","ok":false}"#, "\(action)")
            }
            #expect(Self.control(tv, "skip", seconds: 30).contains("nothing is playing"))
            #expect(Self.control(tv, "seek", seconds: 600).contains("nothing is playing"))
            #expect(Self.control(tv, "speed", speed: 1.5).contains("nothing is playing"))
            // Said, with nothing playing: one line, and her model isn't asked
            rig.siri(.down, .hold, .release)
            rig.transcribers[0].onFinal?("下一首")
            #expect(tv.jasmine.phase == .message && tv.jasmine.line == "Nothing Is Playing")
            #expect(rig.brain.asked.isEmpty)
            #expect(!tv.jasmineState().contains("playing"))
        }
    }

    @Test func theControlToolChecksWhatItsGiven() async throws {
        try await JasmineTests.withJasmine { rig in
            let tv = rig.tv
            #expect(Self.control(tv, "skip").contains("not understood"), "how far?")
            #expect(Self.control(tv, "skip", seconds: 0).contains("not understood"))
            #expect(Self.control(tv, "seek").contains("not understood"))
            #expect(Self.control(tv, "seek", seconds: -5).contains("not understood"))
            #expect(Self.control(tv, "speed").contains("not understood"))
            #expect(Self.control(tv, "speed", speed: 0).contains("not understood"))
            #expect(Self.control(tv, "fly").contains("not understood"))
            let control = try #require(tv.jasmineTools.first { $0.name == "control" })
            let properties = try #require(control.parameters["properties"] as? [String: [String: Any]])
            #expect(properties["action"]?["enum"] as? [String]
                    == ["play", "pause", "next", "previous", "skip", "seek", "restart", "subtitles_on", "subtitles_off", "speed"])
            #expect(control.parameters["required"] as? [String] == ["action", "seconds", "speed"])
        }
    }

    // MARK: Videos

    /// A movie engine that plays nothing and writes down what it's asked.
    private final class Engine: PlaybackEngine {
        let layer = CALayer()
        var duration: Double = 3600
        var currentTime: Double = 100
        var isPlaying = false
        var ended = false
        var renderFailure: String?
        var audioOptions: [MediaOption] = []
        var subtitleOptions: [MediaOption] = []
        var selectedAudio: Int?
        var selectedSubtitle: Int?
        var subtitleChoices: [Int?] = []
        func start(at seconds: Double) { currentTime = seconds; isPlaying = true }
        func play() { isPlaying = true }
        func pause() { isPlaying = false }
        func seek(to seconds: Double) { currentTime = seconds }
        func selectAudio(_ index: Int) {}
        func selectSubtitle(_ index: Int?) { selectedSubtitle = index; subtitleChoices.append(index) }
        func subtitle(at seconds: Double) -> String? { nil }
        func stop() { isPlaying = false }
    }

    private static func watch(_ tv: TVController, _ engine: Engine) {
        let movie = Movie(path: "/tmp/mactv-tests-none.mp4", title: "None", added: Date(), size: 0)
        tv.playbackCoordinator.startMovie(movie, engine: engine, from: 100)
    }

    @Test func videosPausesSkipsSeeksAndStartsOver() async throws {
        try await JasmineTests.withJasmine { rig in
            let tv = rig.tv, engine = Engine()
            Self.watch(tv, engine)
            #expect(tv.mode == .movie && engine.isPlaying)
            #expect(tv.jasmineState().contains(#""playing":{"app":"Videos","paused":false,"title":"None"}"#))
            #expect(Self.control(tv, "pause") == Self.done && !engine.isPlaying)
            #expect(Self.control(tv, "pause") == Self.done && !engine.isPlaying, "paused already")
            #expect(Self.control(tv, "play") == Self.done && engine.isPlaying)
            #expect(Self.control(tv, "play") == Self.done && engine.isPlaying, "playing already")
            #expect(Self.control(tv, "skip", seconds: 30) == Self.done && engine.currentTime == 130)
            #expect(Self.control(tv, "skip", seconds: -120) == Self.done && engine.currentTime == 10)
            #expect(Self.control(tv, "seek", seconds: 600) == Self.done && abs(engine.currentTime - 600) < 0.001)
            #expect(Self.control(tv, "restart") == Self.done && engine.currentTime == 0)
            tv.closeMovie()
        }
    }

    @Test func videosTurnsItsSubtitlesOnAndOff() async throws {
        try await JasmineTests.withJasmine { rig in
            let tv = rig.tv, engine = Engine()
            engine.subtitleOptions = [MediaOption(language: "fr", name: nil, detail: nil), MediaOption(language: "en", name: nil, detail: nil)]
            Self.watch(tv, engine)
            let player = try #require(tv.moviePlayer)
            #expect(Self.control(tv, "subtitles_on") == Self.done)
            let shown = try #require(player.selectedSubtitle)
            #expect(engine.subtitleChoices == [shown] && player.menu == nil, "chosen without the menu")
            #expect(Self.control(tv, "subtitles_on") == Self.done && engine.subtitleChoices == [shown], "on already: as they are")
            #expect(Self.control(tv, "subtitles_off") == Self.done)
            #expect(player.selectedSubtitle == nil && engine.subtitleChoices == [shown, nil])
            // The menu's own choice is the same function
            player.choose(column: 0, row: 2)
            #expect(player.selectedSubtitle == 1 && engine.subtitleChoices == [shown, nil, 1])
            tv.closeMovie()
        }
    }

    @Test func videosSaysWhatItCantDo() async throws {
        try await JasmineTests.withJasmine { rig in
            let tv = rig.tv, engine = Engine()
            Self.watch(tv, engine)
            #expect(Self.control(tv, "subtitles_on") == #"{"error":"this video has no subtitles","ok":false}"#)
            #expect(Self.control(tv, "subtitles_off").contains("this video has no subtitles"))
            #expect(Self.control(tv, "speed", speed: 1.5) == #"{"error":"Videos has no playback speed","ok":false}"#)
            #expect(Self.control(tv, "next").contains("there's no next episode"), "a film, not an episode")
            #expect(Self.control(tv, "previous").contains("Videos can't go back an episode"))
            #expect(tv.mode == .movie && engine.currentTime == 100 && engine.subtitleChoices.isEmpty, "nothing was touched")
            tv.closeMovie()
        }
    }

    @Test func saidWhileAVideoPlaysItsDoneWithoutHerModel() async throws {
        try await JasmineTests.withJasmine { rig in
            let tv = rig.tv, engine = Engine()
            Self.watch(tv, engine)
            @MainActor func say(_ text: String) {
                rig.siri(.down, .hold, .release)
                rig.transcribers.last?.onFinal?(text)
            }
            say("快进30秒")
            #expect(engine.currentTime == 130 && tv.jasmine.phase == .message && tv.jasmine.line == nil)
            say("后退一分钟")
            #expect(engine.currentTime == 70)
            say("跳到10分钟")
            #expect(abs(engine.currentTime - 600) < 0.001)
            say("从头放")
            #expect(engine.currentTime == 0)
            say("暂停")
            #expect(!engine.isPlaying)
            say("继续")
            #expect(engine.isPlaying)
            say("两倍速")
            #expect(tv.jasmine.line == "Not Available", "Videos has no speed: said, not pretended")
            say("打开字幕")
            #expect(tv.jasmine.line == "Not Available" && engine.subtitleChoices.isEmpty)
            #expect(rig.brain.asked.isEmpty, "no model")
            tv.closeMovie()
        }
    }

    // MARK: 得到

    private static let lecture = DedaoAPI.Track(id: "t1", title: "第一讲", reader: "讲者", cover: nil, duration: 600, progress: 0,
                                                finished: false, address: nil, fetched: Date(), productEnid: "p", productType: 66,
                                                itemEnid: "i", aliasID: "a", articleID: 1)

    @Test func dedaoSkipsSeeksAndChangesSpeed() async throws {
        try await JasmineTests.withJasmine { rig in
            let tv = rig.tv, player = tv.dedaoStore.player
            let speed = player.speed
            defer { player.setSpeed(speed) }
            tv.dedaoStore.pretendListening(Self.lecture)
            #expect(tv.jasmineState().contains(#""app":"得到""#) && tv.jasmineState().contains(#""title":"第一讲""#))
            #expect(Self.control(tv, "pause") == Self.done && player.paused, "paused already")
            #expect(Self.control(tv, "skip", seconds: 90) == Self.done && player.time == 90)
            #expect(Self.control(tv, "skip", seconds: -30) == Self.done && player.time == 60)
            #expect(Self.control(tv, "seek", seconds: 300) == Self.done && player.time == 300)
            #expect(Self.control(tv, "restart") == Self.done && player.time == 0)
            #expect(Self.control(tv, "speed", speed: 1.5) == Self.done && player.speed == 1.5)
            #expect(Self.control(tv, "speed", speed: 1) == Self.done && player.speed == 1)
            #expect(Self.control(tv, "speed", speed: 3) == #"{"error":"得到 plays at these speeds: 0.75, 1, 1.25, 1.5, 1.75, 2","ok":false}"#)
            #expect(player.speed == 1)
            #expect(Self.control(tv, "subtitles_on") == #"{"error":"得到 has no subtitles","ok":false}"#)
            #expect(Self.control(tv, "next").contains("this is the last lecture"), "the only lecture")
            #expect(Self.control(tv, "previous").contains("this is the first lecture"))
            #expect(player.current == Self.lecture)
        }
    }

    // MARK: 网易云音乐

    @Test func neteasePausesSkipsAndSeeks() async throws {
        try await JasmineTests.withJasmine { rig in
            let tv = rig.tv, store = tv.neteaseStore
            store.pretendPlaying(NeteaseSong(id: 1, name: "歌", artist: "歌手", duration: 200))
            #expect(tv.jasmineState().contains(#""playing":{"app":"网易云音乐","artist":"歌手","paused":false,"title":"歌"}"#))
            #expect(Self.control(tv, "pause") == Self.done && store.paused)
            #expect(Self.control(tv, "pause") == Self.done && store.paused, "paused already")
            #expect(Self.control(tv, "skip", seconds: 30) == Self.done && store.playbackTime() == 30)
            #expect(Self.control(tv, "skip", seconds: -10) == Self.done && store.playbackTime() == 20)
            #expect(Self.control(tv, "seek", seconds: 120) == Self.done && store.playbackTime() == 120)
            #expect(Self.control(tv, "restart") == Self.done && store.playbackTime() == 0)
            #expect(Self.control(tv, "subtitles_on") == #"{"error":"网易云音乐 has no subtitles","ok":false}"#)
            #expect(Self.control(tv, "speed", speed: 1.5) == #"{"error":"网易云音乐 has no playback speed","ok":false}"#)
            #expect(Self.control(tv, "next").contains("there's no other song in the queue"), "nothing queued")
            #expect(store.current?.id == 1)
        }
    }

    @Test func aSongStillLoadingCantBeSkippedIn() async throws {
        try await JasmineTests.withJasmine { rig in
            let tv = rig.tv
            tv.neteaseStore.pretendPlaying(NeteaseSong(id: 2, name: "歌"))   // its length isn't known yet
            #expect(Self.control(tv, "skip", seconds: 30).contains("the song is still loading"))
            #expect(Self.control(tv, "seek", seconds: 30).contains("the song is still loading"))
        }
    }

    // MARK: 哔哩哔哩

    @Test func bilibiliChangesSpeedAndSaysWhatItCantDo() async throws {
        try await JasmineTests.withJasmine { rig in
            let tv = rig.tv, player = tv.bilibiliStore.player
            let speed = player.speed
            defer { player.speed = speed }
            player.pretendOpen(BiliVideo(bvid: "BV1jasmine", title: "视频", cover: nil, duration: 600, owner: "UP", views: 0), qualities: [80])
            #expect(Self.control(tv, "speed", speed: 1.5).contains("nothing is playing"), "哔哩哔哩 isn't in front")
            tv.bilibiliOpen = true
            #expect(tv.jasmineState().contains(#""playing":{"app":"哔哩哔哩","paused":true,"title":"视频"}"#))
            #expect(Self.control(tv, "pause") == Self.done && player.paused, "paused already")
            #expect(Self.control(tv, "speed", speed: 1.5) == Self.done && player.speed == 1.5)
            #expect(Self.control(tv, "speed", speed: 1) == Self.done && player.speed == 1)
            #expect(Self.control(tv, "speed", speed: 3) == #"{"error":"哔哩哔哩 plays at these speeds: 0.5, 0.75, 1, 1.25, 1.5, 2","ok":false}"#)
            #expect(player.speed == 1)
            #expect(Self.control(tv, "subtitles_on") == #"{"error":"this video has no subtitles","ok":false}"#)
            #expect(Self.control(tv, "subtitles_off").contains("this video has no subtitles"))
            #expect(Self.control(tv, "next") == #"{"error":"this video isn't part of a series","ok":false}"#)
            #expect(Self.control(tv, "previous").contains("this video isn't part of a series"))
            #expect(Self.control(tv, "skip", seconds: 30).contains("the video is still loading"), "no stream yet")
            #expect(Self.control(tv, "seek", seconds: 300).contains("the video is still loading"))
            #expect(player.current?.bvid == "BV1jasmine" && player.time == 0)
        }
    }

    @Test func aLiveStreamCantSkipOrChangeSpeed() async throws {
        try await JasmineTests.withJasmine { rig in
            let tv = rig.tv, player = tv.bilibiliStore.player
            let speed = player.speed
            player.pretendOpen(BiliVideo(bvid: "live-9", title: "直播", cover: nil, duration: 0, owner: "主播", views: 1, liveRoom: 9), qualities: [])
            tv.bilibiliOpen = true
            #expect(Self.control(tv, "skip", seconds: 30) == #"{"error":"a live stream can't skip","ok":false}"#)
            #expect(Self.control(tv, "restart").contains("a live stream can't skip"))
            #expect(Self.control(tv, "speed", speed: 2).contains("a live stream has no playback speed") && player.speed == speed)
            #expect(Self.control(tv, "subtitles_on").contains("a live stream has no subtitles"))
        }
    }

    // MARK: A web page

    @Test func aWebPageOnlyTakesPlayPauseAndItsOwnStep() async throws {
        try await JasmineTests.withJasmine { rig in
            let tv = rig.tv
            tv.open(InteractionTests.site)
            #expect(tv.mode == .player(InteractionTests.site))
            #expect(Self.control(tv, "pause") == Self.done)
            #expect(Self.control(tv, "skip", seconds: 10) == Self.done)
            #expect(Self.control(tv, "skip", seconds: -10) == Self.done)
            #expect(Self.control(tv, "skip", seconds: 30) == #"{"error":"Test Site only skips 10 seconds at a time","ok":false}"#)
            for action in ["next", "previous", "restart", "subtitles_on"] {
                #expect(Self.control(tv, action) == #"{"error":"Test Site only takes play, pause and a 10-second skip","ok":false}"#, "\(action)")
            }
            #expect(Self.control(tv, "seek", seconds: 60).contains("only takes play, pause"))
            #expect(Self.control(tv, "speed", speed: 2).contains("only takes play, pause"))
            #expect(!tv.jasmineState().contains("playing"), "what a page plays isn't known")
        }
    }
}
