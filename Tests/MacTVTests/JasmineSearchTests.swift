import AppKit
import Foundation
import Testing
@testable import MacTV

/// Jasmine finding something to play: what's said that needs no model, what each tool does when it finds it, doesn't,
/// can't play it or can't reach the service, and the question she asks and waits to hear about. 网易云音乐 and 哔哩哔哩
/// are stand-ins that hold made-up songs and videos and write down what they're asked to play (no network, no
/// account); the web is a list of the addresses opened.
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct JasmineSearchTests {
    init() { _ = NSApplication.shared }

    // MARK: Stand-ins

    final class Music: JasmineMusic {
        var signedIn = true
        var reachable = true
        var ownPlaylists: [NeteasePlaylist] = []
        var songs: [String: [NeteaseSong]] = [:]
        var artists: [String: [NeteasePlaylist]] = [:]
        var playlists: [String: [NeteasePlaylist]] = [:]
        /// The songs of an artist or a playlist, by its id.
        var contents: [Int: [NeteaseSong]] = [:]
        /// The songs that can't be played, by id.
        var availability: [Int: JasmineAvailability] = [:]
        private(set) var searches: [String] = []
        private(set) var played: [(song: NeteaseSong, queue: [NeteaseSong], list: NeteasePlaylist?)] = []

        func findSongs(_ keyword: String) async -> [NeteaseSong]? { searches.append("song \(keyword)"); return reachable ? songs[keyword] ?? [] : nil }
        func findArtists(_ keyword: String) async -> [NeteasePlaylist]? { searches.append("artist \(keyword)"); return reachable ? artists[keyword] ?? [] : nil }
        func findPlaylists(_ keyword: String) async -> [NeteasePlaylist]? { searches.append("playlist \(keyword)"); return reachable ? playlists[keyword] ?? [] : nil }
        func songs(of list: NeteasePlaylist) async -> [NeteaseSong] { reachable ? contents[list.id] ?? [] : [] }
        func availability(of song: NeteaseSong) async -> JasmineAvailability { reachable ? availability[song.id] ?? .playable : .unreachable }
        func playFound(_ song: NeteaseSong, in songs: [NeteaseSong], from list: NeteasePlaylist?) { played.append((song, songs, list)) }
    }

    final class Videos: JasmineVideos {
        var reachable = true
        var videos: [String: [BiliVideo]] = [:]
        var people: [String: [BiliUser]] = [:]
        /// A person's videos, by mid.
        var uploads: [Int: [BiliVideo]] = [:]
        private(set) var played: [(video: BiliVideo, user: BiliUser?)] = []
        private(set) var shown: [String] = []

        func findVideos(_ keyword: String) async -> [BiliVideo]? { reachable ? videos[keyword] ?? [] : nil }
        func findPeople(_ keyword: String) async -> [BiliUser]? { reachable ? people[keyword] ?? [] : nil }
        func uploads(of user: BiliUser) async -> [BiliVideo] { reachable ? uploads[user.mid] ?? [] : [] }
        func playFound(_ video: BiliVideo, of user: BiliUser?) { played.append((video, user)) }
        func showResults(for keyword: String) { shown.append(keyword) }
    }

    /// 网易云音乐 with a few songs, 哔哩哔哩 with a few videos and people, and a clock the test moves.
    @MainActor final class World {
        let music = Music(), videos = Videos()
        var opened: [URL] = []
        var time = Date(timeIntervalSince1970: 1_800_000_000)
        lazy var finder = JasmineFinder(music: music, videos: videos, web: { [unowned self] in opened.append($0) }, now: { [unowned self] in time })

        init() {
            music.songs["夜曲"] = [Self.nocturne, Self.nocturneLive, Self.cover]
            music.songs["晴天"] = [Self.sunny]
            music.songs["周杰伦"] = [Self.sunny, Self.nocturne]
            music.artists["周杰伦"] = [NeteasePlaylist(id: 6452, name: "周杰伦", kind: .artist), NeteasePlaylist(id: 9, name: "周杰伦翻唱", kind: .artist)]
            music.contents[6452] = [Self.sunny, Self.nocturne]
            videos.videos["夜曲 周杰伦"] = [Self.clip]
            videos.videos["猫"] = [Self.cats, Self.clip]
            videos.videos["猫咪合集"] = [Self.cats]
            videos.people["老番茄"] = [Self.tomato, Self.tomatoDaily]
            videos.people["番茄"] = [Self.tomato, Self.tomatoDaily, Self.ketchup, BiliUser(mid: 4, name: "番茄炒蛋")]
            videos.uploads[1] = [BiliVideo(bvid: "BV1new", title: "新视频", cover: nil, duration: 600, owner: "老番茄", views: 9)]
            videos.uploads[2] = [BiliVideo(bvid: "BV1day", title: "日常", cover: nil, duration: 60, owner: "老番茄的日常", views: 1)]
        }

        static let jay = [NeteaseArtist(id: 6452, name: "周杰伦")]
        static let nocturne = NeteaseSong(id: 1, name: "夜曲", artist: "周杰伦", artists: jay)
        static let nocturneLive = NeteaseSong(id: 2, name: "夜曲", artist: "周杰伦", artists: jay)
        static let cover = NeteaseSong(id: 3, name: "夜曲", artist: "某翻唱", artists: [NeteaseArtist(id: 7, name: "某翻唱")])
        static let sunny = NeteaseSong(id: 4, name: "晴天", artist: "周杰伦", artists: jay)
        static let clip = BiliVideo(bvid: "BV1clip", title: "周杰伦《夜曲》MV", cover: nil, duration: 240, owner: "音乐台", views: 100)
        static let cats = BiliVideo(bvid: "BV1cats", title: "猫咪合集", cover: nil, duration: 300, owner: "猫奴", views: 50)
        static let tomato = BiliUser(mid: 1, name: "老番茄", fans: 19_000_000, sign: "新人 UP 主")
        static let tomatoDaily = BiliUser(mid: 2, name: "老番茄的日常", fans: 120_000, sign: "小号")
        static let ketchup = BiliUser(mid: 3, name: "番茄酱", fans: 800)

        func call(_ name: String, _ arguments: [String: Any]) async -> String {
            await finder.tool(ToolCall(id: "c", name: name, arguments: arguments)) ?? "not one of hers"
        }
        func music(_ query: String, _ kind: String) async -> String { await call("play_music", ["query": query, "kind": kind]) }
        func video(_ query: String, _ kind: String) async -> String { await call("play_video", ["query": query, "kind": kind]) }
        func answer(_ accept: Bool, choice: Int? = nil) async -> String {
            await call("answer", ["accept": accept, "choice": choice.map { $0 as Any } ?? NSNull()])
        }
    }

    // MARK: What's said

    @Test func askingForASongOrASingerNeedsNoModel() {
        for phrase in ["我想听夜曲", "我想听夜曲。", "想听夜曲", "我要听夜曲", "播放夜曲", "播放 夜曲", "来一首夜曲", "放首夜曲", "帮我播放夜曲", "请播放《夜曲》",
                       "我想听一首夜曲", "播放夜曲吧"] {
            #expect(LocalSearch.match(phrase) == .music("夜曲", .song), "\(phrase)")
        }
        #expect(LocalSearch.match("我想听周杰伦的夜曲") == .music("周杰伦的夜曲", .song), "whose song it is goes into the search as said")
        #expect(LocalSearch.match("播放 Taylor Swift") == .music("Taylor Swift", .song))
        #expect(LocalSearch.match("Play Shake It Off") == .music("Shake It Off", .song))
        #expect(LocalSearch.match("I want to listen to Yesterday.") == .music("Yesterday", .song))
        for phrase in ["放周杰伦的歌", "播放周杰伦的歌", "我想听周杰伦的歌", "听听周杰伦的歌", "来点周杰伦的歌", "放点周杰伦的音乐", "帮我放周杰伦的歌曲",
                       "我想听点周杰伦的歌"] {
            #expect(LocalSearch.match(phrase) == .music("周杰伦", .artist), "\(phrase)")
        }
        #expect(LocalSearch.match("Play songs by Taylor Swift") == .music("Taylor Swift", .artist))
        #expect(LocalSearch.match("Play some music by Adele") == .music("Adele", .artist))
    }

    @Test func aMoodOrASceneIsTheModels() {
        for phrase in ["放点睡前歌单", "想听点舒缓的古典音乐", "我想听舒缓的音乐", "我想听安静的歌", "放点好听的歌", "来点音乐", "我想听歌", "播放音乐",
                       "我想听适合跑步的", "播放我喜欢的音乐", "放点轻松的", "播放歌单", "我想听爵士", "Play some jazz", "Play something relaxing",
                       "Play my playlist", "Play music"] {
            #expect(LocalSearch.match(phrase) == nil, "\(phrase)")
        }
    }

    @Test func whatIsntANameGoesToTheModel() {
        for phrase in ["播放这首歌", "我想听刚才那首", "播放下一首歌", "播放第二集", "播放视频", "我想听下一首歌是什么", "播放器怎么用", "放大一点",
                       "放周杰伦", "听不清", "下一首放周杰伦", "暂停之后提醒我", "播放 YouTube 上的视频", "我想听网易云的每日推荐", "Play it",
                       "Play the next one", "Play that again", "我想听", "播放", "讲个故事", "今天天气怎么样",
                       "我想听一个很长很长很长很长很长很长很长很长很长很长很长很长很长的名字的歌曲"] {
            #expect(LocalSearch.match(phrase) == nil, "\(phrase)")
        }
    }

    @Test func bilibiliByNameNeedsNoModel() {
        for phrase in ["在B站看猫咪合集", "在 B 站看猫咪合集", "B站看猫咪合集", "在哔哩哔哩看猫咪合集", "在b站上看猫咪合集", "去B站看看猫咪合集", "在B站播放猫咪合集",
                       "帮我在B站看猫咪合集"] {
            #expect(LocalSearch.match(phrase) == .video("猫咪合集", .video), "\(phrase)")
        }
        #expect(LocalSearch.match("Watch cat videos on Bilibili") == .video("cat videos", .video))
        for phrase in ["在B站看老番茄的视频", "B站看老番茄的视频", "在哔哩哔哩看老番茄的最新视频", "在B站看老番茄最新的视频"] {
            #expect(LocalSearch.match(phrase) == .video("老番茄", .person), "\(phrase)")
        }
        for phrase in ["B站搜老番茄", "B 站搜老番茄", "在B站搜索老番茄", "B站搜一下老番茄", "在哔哩哔哩上找老番茄", "用B站搜老番茄", "帮我在B站搜老番茄"] {
            #expect(LocalSearch.match(phrase) == .video("老番茄", .search), "\(phrase)")
        }
        #expect(LocalSearch.match("Search for cats on Bilibili") == .video("cats", .search))
        for phrase in ["在B站看这个", "B站看看", "B站搜", "在B站看刚才那个视频", "B站怎么登录", "B站"] {
            #expect(LocalSearch.match(phrase) == nil, "\(phrase)")
        }
    }

    @Test func aWebSearchNeedsNoModel() {
        for phrase in ["搜一下红烧肉", "帮我搜一下红烧肉", "帮我搜红烧肉", "搜索红烧肉", "搜红烧肉", "查一下红烧肉", "上网搜一下红烧肉", "百度一下红烧肉",
                       "请帮我搜一下红烧肉。"] {
            #expect(LocalSearch.match(phrase) == .web("红烧肉"), "\(phrase)")
        }
        #expect(LocalSearch.match("搜一下怎么做红烧肉") == .web("怎么做红烧肉"), "a question is something to search for")
        #expect(LocalSearch.match("Search for apple pie recipes") == .web("apple pie recipes"))
        #expect(LocalSearch.match("Look up the weather in Paris.") == .web("the weather in Paris"))
        #expect(LocalSearch.match("Google Swift concurrency") == .web("Swift concurrency"))
        for phrase in ["搜一下", "搜一下这个", "搜一下刚才那首歌", "搜狐", "红烧肉是什么", "搜一下YouTube上的猫", "搜一下网易云的周杰伦", "Search", "Look it up",
                       "找一下遥控器"] {
            #expect(LocalSearch.match(phrase) == nil, "\(phrase)")
        }
    }

    // MARK: An answer to what she asked

    @Test func yesNoAndWhichOne() {
        typealias Offer = JasmineOffer
        for phrase in ["好", "好的", "好啊", "可以", "行", "行吧", "放吧", "好的，放吧", "嗯", "要", "播放", "Yes", "Yes please", "OK", "ok.", "Sure", "Go ahead"] {
            #expect(Offer.reply(phrase, choices: []) == .yes, "\(phrase)")
        }
        for phrase in ["不用", "不用了", "不要", "算了", "算了吧", "不", "不行", "别放了", "取消", "No", "No thanks", "Never mind", "Don't", "Cancel"] {
            #expect(Offer.reply(phrase, choices: []) == .no, "\(phrase)")
        }
        for phrase in ["不好听", "好听吗", "放周杰伦的歌", "暂停", "第一个", "为什么放不了", "好不好", "What?", ""] {
            #expect(Offer.reply(phrase, choices: []) == nil, "\(phrase)")
        }
        let names = ["老番茄", "老番茄的日常", "番茄酱"]
        #expect(Offer.reply("第一个", choices: names) == .choice(0))
        #expect(Offer.reply("第二个吧", choices: names) == .choice(1))
        #expect(Offer.reply("第 3 个", choices: names) == .choice(2))
        #expect(Offer.reply("二号", choices: names) == .choice(1))
        #expect(Offer.reply("最后一个", choices: names) == .choice(2))
        #expect(Offer.reply("The first one", choices: names) == .choice(0))
        #expect(Offer.reply("Second", choices: names) == .choice(1))
        #expect(Offer.reply("老番茄", choices: names) == .choice(0), "the name itself, though another has it inside")
        #expect(Offer.reply("老番茄那个", choices: names) == .choice(0))
        #expect(Offer.reply("要番茄酱", choices: names) == .choice(2))
        #expect(Offer.reply("日常那个", choices: names) == .choice(1))
        #expect(Offer.reply("算了", choices: names) == .no)
        #expect(Offer.reply("第四个", choices: names) == nil, "there are three")
        #expect(Offer.reply("番茄", choices: names) == nil, "which of them?")
        #expect(Offer.reply("好", choices: names) == nil, "yes to which?")
        #expect(Offer.reply("放周杰伦的歌", choices: names) == nil)
    }

    // MARK: play_music

    @Test func aSongIsFoundAndPlayed() async {
        let world = World()
        #expect(await world.music("夜曲", "song") == #"{"artist":"周杰伦","ok":true,"playing":"夜曲"}"#)
        #expect(world.music.played.count == 1 && world.music.played[0].song.id == 1 && world.music.played[0].list == nil)
        #expect(world.music.played[0].queue.map(\.id) == [1, 2, 3], "what was found goes on after it")
        #expect(world.finder.waiting == nil)
        let found = await world.finder.find(.music("晴天", .song))
        #expect(found.ok && found.line == JasmineLine(chinese: "播放周杰伦的《晴天》。", english: "Playing 晴天 by 周杰伦."))
    }

    @Test func aSongNotFoundAsksAboutBilibili() async {
        let world = World()
        let result = await world.music("不存在的歌", "song")
        #expect(result == #"{"ask":"whether to play a video of it from 哔哩哔哩 instead","error":"nothing on 网易云音乐 for 不存在的歌","ok":false}"#)
        #expect(world.music.played.isEmpty && world.videos.played.isEmpty, "nothing is played from anywhere until they agree")
        #expect(world.finder.waiting?.actions == [.video("不存在的歌", .video)])
    }

    @Test func aSongThatCantBePlayedAsksAndIsNeverPlayed() async {
        let world = World()
        world.music.availability = [1: .unavailable, 2: .unavailable]
        let found = await world.finder.find(.music("夜曲", .song))
        #expect(!found.ok && found.report["error"] as? String == "网易云音乐 can't play 夜曲 by 周杰伦: copyright, membership or region")
        #expect(found.line.chinese == "网易云放不了《夜曲》，从 B 站放一个视频行吗？")
        #expect(world.music.played.isEmpty, "someone else's version isn't played instead")
        #expect(world.videos.played.isEmpty)
        #expect(world.finder.waiting?.actions == [.video("夜曲 周杰伦", .video)])
        // A members' song on an account that isn't one: a preview isn't the song
        world.music.availability = [1: .preview, 2: .unavailable]
        #expect(await world.music("夜曲", "song").contains("members only"))
        #expect(world.music.played.isEmpty)
    }

    @Test func anotherReleaseOfTheSameSongWillDo() async {
        let world = World()
        world.music.availability = [1: .unavailable]
        #expect(await world.music("夜曲", "song").contains(#""ok":true"#))
        #expect(world.music.played.map(\.song.id) == [2])
    }

    @Test func musicThatCantBeReachedOrIsntSignedInSaysSo() async {
        let world = World()
        world.music.reachable = false
        for kind in ["song", "artist", "playlist"] {
            #expect(await world.music("夜曲", kind) == #"{"error":"couldn't reach 网易云音乐","ok":false}"#, "\(kind)")
        }
        #expect(world.finder.waiting == nil, "not reaching it isn't not having it: nothing is offered")
        world.music.reachable = true
        world.music.signedIn = false
        #expect(await world.music("夜曲", "song") == #"{"error":"网易云音乐 isn't signed in","ok":false}"#)
        #expect(world.music.played.isEmpty && world.music.searches.count == 3)
        // The address couldn't be asked for: it isn't called unplayable
        world.music.signedIn = true
        world.music.availability = [4: .unreachable]
        #expect(await world.music("晴天", "song").contains("couldn't reach"))
        #expect(world.finder.waiting == nil && world.music.played.isEmpty)
    }

    @Test func anArtistsPopularSongsArePlayed() async {
        let world = World()
        #expect(await world.music("周杰伦", "artist") == #"{"artist":"周杰伦","ok":true,"playing":"晴天","queue":"周杰伦's popular songs"}"#)
        #expect(world.music.played[0].song.id == 4 && world.music.played[0].list?.id == 6452 && world.music.played[0].queue.map(\.id) == [4, 1])
        // A singer's name asked for as a song is the singer
        #expect(await world.music("周杰伦", "song").contains("popular songs"))
        #expect(world.music.played.count == 2 && world.music.played[1].list?.id == 6452)
        // Nobody by that name: she asks, as for a song
        #expect(await world.music("无名氏", "artist").contains("nothing on 网易云音乐 for 无名氏"))
        #expect(world.finder.waiting?.actions == [.video("无名氏", .video)])
        // Found, and none of the first three can be played
        world.music.availability = [4: .unavailable, 1: .unavailable]
        let found = await world.finder.find(.music("周杰伦", .artist))
        #expect(found.line.chinese == "网易云放不了周杰伦的歌，从 B 站放一个视频行吗？" && world.music.played.count == 2)
        // Found, and the songs didn't come
        world.music.contents[6452] = []
        #expect(await world.music("周杰伦", "artist") == #"{"error":"couldn't get the songs of 周杰伦 from 网易云音乐","ok":false}"#)
    }

    @Test func aPlaylistOfTheirOwnComesFirst() async {
        let world = World()
        world.music.ownPlaylists = [NeteasePlaylist(id: 100, name: "我喜欢的音乐", count: 500), NeteasePlaylist(id: 101, name: "睡前助眠", count: 30)]
        world.music.contents[101] = [World.sunny]
        world.music.playlists["睡前"] = [NeteasePlaylist(id: 200, name: "睡前轻音乐", count: 80, plays: 9_000_000)]
        let result = await world.music("睡前", "playlist")
        #expect(result == #"{"artist":"周杰伦","from":"their own playlists","ok":true,"playing":"晴天","playlist":"睡前助眠"}"#)
        #expect(world.music.played[0].list?.id == 101 && world.music.searches.isEmpty, "found at home: nothing was searched")
        #expect(await world.finder.find(.music("睡前歌单", .playlist)).line.chinese == "播放你的歌单《睡前助眠》。")
    }

    @Test func otherwiseTheMostPlayedPublicPlaylistWithEnoughSongs() async {
        let world = World()
        world.music.ownPlaylists = [NeteasePlaylist(id: 100, name: "我喜欢的音乐", count: 500)]
        world.music.playlists["舒缓 古典"] = [
            NeteasePlaylist(id: 201, name: "三首古典", count: 3, plays: 90_000_000),
            NeteasePlaylist(id: 202, name: "舒缓古典 100 首", count: 100, plays: 5_000_000),
            NeteasePlaylist(id: 203, name: "古典入门", count: 40, plays: 800_000),
        ]
        world.music.contents[202] = [World.nocturne, World.sunny]
        let result = await world.music("舒缓 古典", "playlist")
        #expect(result == #"{"artist":"周杰伦","from":"a public playlist","ok":true,"playing":"夜曲","playlist":"舒缓古典 100 首"}"#)
        #expect(world.music.played[0].list?.id == 202)
        #expect(JasmineFinder.best([NeteasePlaylist(id: 1, name: "a", count: 3, plays: 5), NeteasePlaylist(id: 2, name: "b", count: 0, plays: 9)])?.id == 1)
        #expect(JasmineFinder.best([]) == nil)
        // None found: said, and nothing offered (a video isn't a playlist)
        #expect(await world.music("不存在", "playlist") == #"{"error":"no playlist on 网易云音乐 for 不存在","ok":false}"#)
        #expect(world.finder.waiting == nil)
        // Found, and its songs didn't come
        world.music.contents[202] = []
        #expect(await world.music("舒缓 古典", "playlist").contains("couldn't get the songs of 舒缓古典 100 首"))
        // Found, and nothing in it can be played
        world.music.contents[202] = [World.nocturne]
        world.music.availability = [1: .unavailable]
        #expect(await world.music("舒缓 古典", "playlist").contains("can't play the playlist"))
        #expect(world.music.played.count == 1)
    }

    @Test func theirOwnPlaylistsByName() {
        let lists = [NeteasePlaylist(id: 1, name: "我喜欢的音乐"), NeteasePlaylist(id: 2, name: "跑步"), NeteasePlaylist(id: 3, name: "跑步 2026")]
        #expect(JasmineFinder.named("跑步", in: lists)?.id == 2, "the one named so, before one that has it inside")
        #expect(JasmineFinder.named("跑步歌单", in: lists)?.id == 2)
        #expect(JasmineFinder.named("2026", in: lists)?.id == 3)
        #expect(JasmineFinder.named("睡前", in: lists) == nil)
        #expect(JasmineFinder.named("歌单", in: lists) == nil)
    }

    // MARK: play_video

    @Test func aVideoIsFoundAndOpened() async {
        let world = World()
        #expect(await world.video("猫", "video") == #"{"by":"猫奴","ok":true,"on":"哔哩哔哩","opened":"猫咪合集"}"#)
        #expect(world.videos.played.count == 1 && world.videos.played[0].video.bvid == "BV1cats" && world.videos.played[0].user == nil)
        #expect(await world.video("不存在", "video") == #"{"error":"nothing on 哔哩哔哩 for 不存在","ok":false}"#)
        world.videos.reachable = false
        for kind in ["video", "person"] {
            #expect(await world.video("猫", kind) == #"{"error":"couldn't reach 哔哩哔哩","ok":false}"#, "\(kind)")
        }
        #expect(world.videos.played.count == 1 && world.finder.waiting == nil)
    }

    @Test func aPersonsNewestVideoIsPlayed() async {
        let world = World()
        #expect(await world.video("老番茄", "person") == #"{"by":"老番茄","newest":true,"ok":true,"on":"哔哩哔哩","opened":"新视频"}"#)
        #expect(world.videos.played[0].video.bvid == "BV1new" && world.videos.played[0].user == World.tomato, "the one whose name it is")
        #expect(await world.video("无名氏", "person") == #"{"error":"nobody on 哔哩哔哩 named 无名氏","ok":false}"#)
        // The person is found, their videos aren't
        world.videos.uploads[1] = []
        #expect(await world.video("老番茄", "person") == #"{"error":"couldn't get 老番茄's videos from 哔哩哔哩","ok":false}"#)
        #expect(world.videos.played.count == 1)
    }

    @Test func severalPeopleAreAskedAbout() async throws {
        let world = World()
        let found = await world.finder.find(.video("番茄", .person))
        #expect(!found.ok && found.line.chinese == "找到3位：老番茄、老番茄的日常、番茄酱。要哪一个？")
        let object = try #require(JSONSerialization.jsonObject(with: Data(found.json.utf8)) as? [String: Any])
        #expect(object["ask"] as? String == "which of these people they mean")
        #expect(object["choices"] as? [String] == ["老番茄", "老番茄的日常", "番茄酱"])
        let candidates = try #require(object["candidates"] as? [[String: Any]])
        #expect(candidates.count == 3 && candidates[0]["followers"] as? Int == 19_000_000 && candidates[1]["about"] as? String == "小号")
        #expect(world.videos.played.isEmpty)
        #expect(world.finder.state?["choices"] as? [String] == ["老番茄", "老番茄的日常", "番茄酱"])
        // Yes isn't an answer to which one; a number out of range neither. The question still waits
        #expect(await world.answer(true).contains("which one"))
        #expect(await world.answer(true, choice: 4).contains("not understood"))
        #expect(world.finder.waiting != nil && world.videos.played.isEmpty)
        #expect(await world.answer(true, choice: 2).contains(#""opened":"日常""#))
        #expect(world.videos.played.map(\.video.bvid) == ["BV1day"] && world.videos.played[0].user == World.tomatoDaily)
        #expect(world.finder.waiting == nil)
    }

    @Test func bilibilisOwnSearchIsShown() async {
        let world = World()
        #expect(await world.video("猫", "search") == #"{"ok":true,"showing":"哔哩哔哩's search for 猫"}"#)
        #expect(world.videos.shown == ["猫"] && world.videos.played.isEmpty)
    }

    // MARK: web_search

    @Test func aWebSearchOpensWhatTheAddressBarWould() async {
        let world = World()
        #expect(await world.call("web_search", ["query": "红烧肉 做法"]) == #"{"ok":true,"showing":"web search results for 红烧肉 做法"}"#)
        #expect(world.opened == [BrowserStore.destination("红烧肉 做法")].compactMap { $0 })
        #expect(world.opened.first?.host == "www.google.com" && world.opened.first?.query?.hasPrefix("q=") == true)
        // Words that look like an address are searched for, not gone to
        #expect(BrowserStore.search("apple.com")?.host == "www.google.com")
        #expect(BrowserStore.destination("apple.com")?.host == "apple.com")
    }

    // MARK: What the tools are given

    @Test func theToolsCheckWhatTheyreGiven() async {
        let world = World()
        #expect(await world.music("", "song").contains("not understood"))
        #expect(await world.music("  ", "artist").contains("not understood"))
        #expect(await world.music("夜曲", "album").contains("not understood"))
        #expect(await world.video("猫", "live").contains("not understood"))
        #expect(await world.call("play_video", ["kind": "video"]).contains("not understood"))
        #expect(await world.call("web_search", [:]).contains("not understood"))
        #expect(await world.call("answer", [:]).contains("not understood"))
        #expect(await world.answer(true) == #"{"error":"nothing is waiting for an answer","ok":false}"#)
        #expect(await world.answer(false).contains("nothing is waiting"))
        #expect(await world.finder.tool(ToolCall(id: "c", name: "control", arguments: ["action": "pause"])) == nil, "not one of these")
        #expect(world.music.played.isEmpty && world.videos.played.isEmpty && world.opened.isEmpty)
        #expect(JasmineFinder.tools.map(\.name) == ["play_music", "play_video", "web_search", "answer"])
    }

    // MARK: The offer, by the tools

    @Test func agreedToItsDoneDeclinedItsDropped() async {
        let world = World()
        world.music.availability = [1: .unavailable, 2: .unavailable]
        _ = await world.music("夜曲", "song")
        #expect(world.finder.state?["asked"] as? String == "whether to play a video of it from 哔哩哔哩 instead")
        #expect(await world.answer(true) == #"{"by":"音乐台","ok":true,"on":"哔哩哔哩","opened":"周杰伦《夜曲》MV"}"#)
        #expect(world.videos.played.map(\.video.bvid) == ["BV1clip"] && world.finder.waiting == nil)
        #expect(await world.answer(true).contains("nothing is waiting"), "once")

        _ = await world.music("夜曲", "song")
        #expect(await world.answer(false) == #"{"cancelled":true,"ok":true}"#)
        #expect(world.finder.waiting == nil && world.videos.played.count == 1)
    }

    @Test func anOfferLastsAMinute() async {
        let world = World()
        world.music.availability = [1: .unavailable, 2: .unavailable]
        _ = await world.music("夜曲", "song")
        world.time += 59
        #expect(world.finder.waiting != nil && world.finder.reply(to: "好") == .yes)
        world.time += 2
        #expect(world.finder.waiting == nil && world.finder.state == nil)
        #expect(world.finder.reply(to: "好") == nil, "yes to nothing")
        #expect(await world.answer(true).contains("nothing is waiting"))
        #expect(world.videos.played.isEmpty)
    }

    @Test func aNewSearchReplacesTheOffer() async {
        let world = World()
        world.music.availability = [1: .unavailable, 2: .unavailable]
        _ = await world.music("夜曲", "song")
        _ = await world.music("晴天", "song")
        #expect(world.finder.waiting == nil && world.music.played.map(\.song.id) == [4])
        #expect(await world.answer(true).contains("nothing is waiting"))
    }

    // MARK: Said to her

    private static func say(_ rig: JasmineTests.Rig, _ text: String) throws {
        rig.siri(.down, .hold, .release)
        try #require(rig.transcribers.last).onFinal?(text)
    }

    /// Waits for her line, said: what came of a search.
    private static func line(_ rig: JasmineTests.Rig, after said: Int) async -> String? {
        await JasmineTests.waitUntil { rig.voice.said.count > said && rig.tv.jasmine.phase == .speaking }
        return rig.tv.jasmine.line
    }

    @Test func askedInAFixedWayItsFoundWithoutTheModel() async throws {
        let world = World()
        try await JasmineTests.withJasmine(finder: world.finder) { rig in
            try Self.say(rig, "放周杰伦的歌")
            #expect(rig.tv.jasmine.phase == .thinking, "she's finding it")
            #expect(await Self.line(rig, after: 0) == "播放周杰伦的歌。")
            #expect(rig.voice.said == ["播放周杰伦的歌。"] && rig.brain.asked.isEmpty)
            #expect(world.music.played.map(\.song.id) == [4])
            rig.voice.finish()
            #expect(rig.tv.jasmine.phase == .message && rig.ducks.last == 1)

            try Self.say(rig, "Search for apple pie")
            #expect(await Self.line(rig, after: 1) == "Searching the web for apple pie.", "in the language she was asked in")
            #expect(world.opened.count == 1 && rig.brain.asked.isEmpty)

            try Self.say(rig, "在B站看猫咪合集")
            #expect(await Self.line(rig, after: 2) == "从 B 站播放《猫咪合集》。")
            world.music.reachable = false
            try Self.say(rig, "我想听夜曲")
            #expect(await Self.line(rig, after: 3) == "连不上网易云音乐。")
            #expect(rig.brain.asked.isEmpty)
        }
    }

    @Test func sheAsksBeforePlayingFromSomewhereElse() async throws {
        let world = World()
        world.music.availability = [1: .unavailable, 2: .unavailable]
        try await JasmineTests.withJasmine(finder: world.finder) { rig in
            try Self.say(rig, "我想听夜曲")
            #expect(await Self.line(rig, after: 0) == "网易云放不了《夜曲》，从 B 站放一个视频行吗？")
            #expect(world.music.played.isEmpty && world.videos.played.isEmpty, "asked, not done")
            #expect(rig.tv.jasmineState().contains(#""waiting":{"asked":"whether to play a video of it from 哔哩哔哩 instead"}"#))
            rig.voice.finish()

            try Self.say(rig, "好的，放吧。")
            #expect(await Self.line(rig, after: 1) == "从 B 站播放《周杰伦《夜曲》MV》。")
            #expect(world.videos.played.map(\.video.bvid) == ["BV1clip"])
            #expect(rig.brain.asked.isEmpty, "the question and its answer need no model")
            #expect(!rig.tv.jasmineState().contains("waiting"))
        }
    }

    @Test func declinedNothingIsPlayed() async throws {
        let world = World()
        world.music.availability = [1: .unavailable, 2: .unavailable]
        try await JasmineTests.withJasmine(finder: world.finder) { rig in
            try Self.say(rig, "我想听夜曲")
            _ = await Self.line(rig, after: 0)
            try Self.say(rig, "不用了")
            #expect(await Self.line(rig, after: 1) == "好的。")
            #expect(world.videos.played.isEmpty && world.finder.waiting == nil && rig.brain.asked.isEmpty)
            // The question is gone: a yes now is only a word, and her model's to make something of
            try Self.say(rig, "好")
            await JasmineTests.waitUntil { rig.brain.asked.count == 1 }
            #expect(rig.brain.asked[0].text == "好" && world.videos.played.isEmpty)
        }
    }

    @Test func anOfferOutOfTimeIsNoLongerAnswered() async throws {
        let world = World()
        world.music.availability = [1: .unavailable, 2: .unavailable]
        try await JasmineTests.withJasmine(finder: world.finder) { rig in
            try Self.say(rig, "我想听夜曲")
            _ = await Self.line(rig, after: 0)
            world.time += 61
            try Self.say(rig, "好")
            await JasmineTests.waitUntil { rig.brain.asked.count == 1 }
            #expect(!rig.brain.asked[0].state.contains("waiting") && world.videos.played.isEmpty)
        }
    }

    @Test func aCommandOrAnotherSearchDropsTheOffer() async throws {
        let world = World()
        world.music.availability = [1: .unavailable, 2: .unavailable]
        try await JasmineTests.withJasmine(finder: world.finder) { rig in
            try Self.say(rig, "我想听夜曲")
            _ = await Self.line(rig, after: 0)
            try Self.say(rig, "打开设置")
            #expect(rig.tv.activeSheet == .settings && world.finder.waiting == nil)

            try Self.say(rig, "我想听夜曲")
            _ = await Self.line(rig, after: 1)
            try Self.say(rig, "我想听晴天")
            #expect(await Self.line(rig, after: 2) == "播放周杰伦的《晴天》。")
            #expect(world.finder.waiting == nil && world.videos.played.isEmpty && rig.brain.asked.isEmpty)
        }
    }

    @Test func somethingElseSaidIsANewRequestForHerModel() async throws {
        let world = World()
        world.music.availability = [1: .unavailable, 2: .unavailable]
        try await JasmineTests.withJasmine(finder: world.finder) { rig in
            // Her model is told what waits, and leaves it: it's dropped when the request is over
            rig.brain.script = { _, _, _ in "因为版权。" }
            try Self.say(rig, "我想听夜曲")
            _ = await Self.line(rig, after: 0)
            try Self.say(rig, "为什么放不了")
            #expect(await Self.line(rig, after: 1) == "因为版权。")
            #expect(rig.brain.asked[0].state.contains(#""waiting":{"asked":"#), "her model knows what she asked")
            #expect(world.finder.waiting == nil && world.videos.played.isEmpty)

            // Her model takes it for a yes, in words no rule knows
            rig.brain.script = { _, _, perform in
                let result = await perform(ToolCall(id: "a", name: "answer", arguments: ["accept": true, "choice": NSNull()]))
                #expect(result.contains(#""opened":"周杰伦《夜曲》MV""#))
                return "好，放了。"
            }
            try Self.say(rig, "我想听夜曲")
            _ = await Self.line(rig, after: 2)
            try Self.say(rig, "那就这么办")
            #expect(await Self.line(rig, after: 3) == "好，放了。")
            #expect(world.videos.played.map(\.video.bvid) == ["BV1clip"] && world.finder.waiting == nil)
        }
    }

    @Test func herModelsToolsFindThingsAndItsQuestionWaits() async throws {
        let world = World()
        world.music.playlists["睡前 轻音乐"] = [NeteasePlaylist(id: 300, name: "睡前轻音乐", count: 60, plays: 1_000)]
        world.music.contents[300] = [World.sunny]
        try await JasmineTests.withJasmine(finder: world.finder) { rig in
            // A mood is the model's: it makes the search words and asks for a playlist
            rig.brain.script = { _, _, perform in
                let result = await perform(ToolCall(id: "1", name: "play_music", arguments: ["query": "睡前 轻音乐", "kind": "playlist"]))
                #expect(result.contains(#""playlist":"睡前轻音乐""#) && result.contains(#""from":"a public playlist""#))
                return "放的是歌单「睡前轻音乐」。"
            }
            try Self.say(rig, "放点睡前歌单")
            #expect(await Self.line(rig, after: 0) == "放的是歌单「睡前轻音乐」。")
            #expect(rig.brain.asked.count == 1 && world.music.played.map(\.list?.id) == [300])

            // What her model's tool asked waits too, and a plain yes after it needs no model
            world.music.availability = [1: .unavailable, 2: .unavailable]
            rig.brain.script = { _, _, perform in
                let result = await perform(ToolCall(id: "2", name: "play_music", arguments: ["query": "夜曲", "kind": "song"]))
                #expect(result.contains(#""ask":"#))
                return "网易云放不了，从 B 站放行吗？"
            }
            try Self.say(rig, "来个周杰伦那首讲夜晚的")
            _ = await Self.line(rig, after: 1)
            #expect(world.finder.waiting != nil && world.videos.played.isEmpty)
            try Self.say(rig, "可以")
            _ = await Self.line(rig, after: 2)
            #expect(world.videos.played.map(\.video.bvid) == ["BV1clip"] && rig.brain.asked.count == 2)
        }
    }

    @Test func whichPersonIsAskedAndChosenByNumberOrName() async throws {
        let world = World()
        world.videos.people["番茄"] = [World.tomato, World.tomatoDaily, World.ketchup]
        try await JasmineTests.withJasmine(finder: world.finder) { rig in
            try Self.say(rig, "在B站看番茄的视频")
            #expect(await Self.line(rig, after: 0) == "找到3位：老番茄、老番茄的日常、番茄酱。要哪一个？")
            #expect(world.videos.played.isEmpty)
            try Self.say(rig, "第二个")
            #expect(await Self.line(rig, after: 1) == "播放老番茄的日常最新的视频。")
            #expect(world.videos.played.map(\.video.bvid) == ["BV1day"])

            try Self.say(rig, "在B站看番茄的视频")
            _ = await Self.line(rig, after: 2)
            try Self.say(rig, "老番茄那个")
            #expect(await Self.line(rig, after: 3) == "播放老番茄最新的视频。")
            #expect(world.videos.played.map(\.video.bvid) == ["BV1day", "BV1new"] && rig.brain.asked.isEmpty)
        }
    }

    // MARK: What the services answer (made-up answers, read by the same functions the apps use)

    @Test func neteaseSearchAnswersAreRead() {
        let songs = NeteaseAPI.songs(inSearch: ["songs": [
            ["id": 1, "name": "夜曲", "ar": [["id": 6452, "name": "周杰伦"]], "al": ["id": 5, "name": "十一月的萧邦"], "dt": 226_000],
            ["name": "no id"],
        ]])
        #expect(songs.count == 1 && songs[0].name == "夜曲" && songs[0].artist == "周杰伦" && songs[0].duration == 226)
        let artists = NeteaseAPI.artists(inSearch: ["artists": [["id": 6452, "name": "周杰伦"], ["id": 9]]])
        #expect(artists.map(\.id) == [6452] && artists[0].kind == .artist)
        let lists = NeteaseAPI.playlists(inSearch: ["playlists": [
            ["id": 200, "name": "睡前轻音乐", "trackCount": 80, "playCount": 9_000_000, "creator": ["userId": 7]],
            ["id": 201, "name": "没有数字的"],
        ]])
        #expect(lists.map(\.id) == [200, 201] && lists[0].count == 80 && lists[0].plays == 9_000_000 && lists[0].creator == 7)
        #expect(lists[1].plays == 0 && lists[1].count == 0)
        #expect(NeteaseAPI.songs(inSearch: [:]).isEmpty && NeteaseAPI.playlists(inSearch: ["songCount": 0]).isEmpty)
    }

    @Test func whetherASongCanBePlayedIsReadFromTheAnswer() {
        func read(_ reply: [String: Any]?) -> String {
            switch NeteaseAPI.availability(in: reply, level: "exhigh", fromClient: true) {
            case .playable(let url, let level, _, let preview): "\(preview ? "preview" : "playable") \(url.absoluteString) \(level)"
            case .unavailable: "unavailable"
            case .unreachable: "unreachable"
            }
        }
        #expect(read(["code": 200, "data": [["id": 1, "url": "http://m.example/a.mp3", "level": "standard"]]]) == "playable https://m.example/a.mp3 standard")
        // No copyright, members only or not in this region: an answer, with no address
        #expect(read(["code": 200, "data": [["id": 1, "url": NSNull(), "code": 404]]]) == "unavailable")
        #expect(read(["code": 200, "data": [["id": 1, "url": ""]]]) == "unavailable")
        // A members' song on an account that isn't one: a sample
        #expect(read(["code": 200, "data": [["id": 1, "url": "https://m.example/a.mp3", "freeTrialInfo": ["start": 0, "end": 30]]]])
                == "preview https://m.example/a.mp3 exhigh")
        #expect(read(["code": 200, "data": [["id": 1, "url": "https://m.example/a.mp3", "freeTrialInfo": NSNull()]]]).hasPrefix("playable"))
        // No answer, or one that says nothing about the song
        #expect(read(nil) == "unreachable")
        #expect(read(["code": -460, "message": "Cheating"]) == "unreachable")
        #expect(read(["code": 200, "data": [[String: Any]]()]) == "unreachable")
    }

    @Test func bilibiliSearchAnswersAreRead() {
        let videos = BiliAPI.videos(inSearch: [
            ["bvid": "BV1x", "title": "<em class=\"keyword\">猫</em>咪 &amp; 狗", "author": "猫奴", "mid": 5, "play": 1234, "duration": "3:05", "aid": 9],
            ["title": "no id"],
        ])
        #expect(videos.count == 1 && videos[0].title == "猫咪 & 狗" && videos[0].owner == "猫奴" && videos[0].duration == 185
                && videos[0].ownerMid == 5 && videos[0].views == 1234)
        let people = BiliAPI.users(inSearch: [["mid": 1, "uname": "老番茄", "fans": 19_000_000, "videos": 600, "usign": "新人 UP 主"], ["uname": "no id"]])
        #expect(people == [BiliUser(mid: 1, name: "老番茄", fans: 19_000_000, videos: 600, sign: "新人 UP 主")])
        #expect(BiliAPI.videos(inSearch: []).isEmpty && BiliAPI.users(inSearch: []).isEmpty)
    }
}
