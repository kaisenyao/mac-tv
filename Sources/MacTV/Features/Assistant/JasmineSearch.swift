import Foundation

/// Something Jasmine is asked to find and play: a tool her model calls (JasmineFinder.tools), or said in a fixed way
/// and understood here without the model (LocalSearch).
///
/// | | Where | What it does |
/// |---|---|---|
/// | A song, an artist, a playlist | 网易云音乐 | Searches and plays; says what's playing |
/// | A video, a person, a search | 哔哩哔哩 | Plays the first video found, or the person's newest; or shows its search |
/// | A web search | Web | Opens the results, as typing in the address bar does |
///
/// Nothing is made up: not found, can't be played and can't be reached are each said as they are. A song 网易云音乐
/// can't play (copyright, membership, region) is never fetched another way, and she never goes somewhere else by
/// herself: she asks first (JasmineOffer).
enum JasmineSearch: Equatable {
    enum Music: String { case song, artist, playlist }
    enum Video: String {
        case video, person
        /// 哔哩哔哩's own search page, with the results for the words.
        case search
    }
    case music(String, Music)
    case video(String, Video)
    /// The newest video of this person: what choosing one of several people does.
    case latest(BiliUser)
    case web(String)
}

/// A line of hers that no model wrote, in the language she was spoken to.
struct JasmineLine: Equatable {
    let chinese: String
    let english: String
    func said(chinese inChinese: Bool) -> String { inChinese ? chinese : english }
}

/// What came of a search: told to the model as it is, and said in a line when there's no model in between.
struct JasmineFound {
    var ok: Bool
    /// For the model: what's playing, or why not.
    var report: [String: Any]
    var line: JasmineLine
    /// A question that now waits for its answer; nothing was done.
    var offer: JasmineOffer?

    var json: String {
        var object = report
        object["ok"] = ok
        if let offer {
            object["ask"] = offer.ask
            if !offer.choices.isEmpty { object["choices"] = offer.choices }
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? #"{"ok":false}"#
    }

    static func done(_ report: [String: Any], _ chinese: String, _ english: String) -> JasmineFound {
        JasmineFound(ok: true, report: report, line: JasmineLine(chinese: chinese, english: english))
    }

    static func failed(_ error: String, _ chinese: String, _ english: String, report: [String: Any] = [:],
                       offer: JasmineOffer? = nil) -> JasmineFound {
        JasmineFound(ok: false, report: report.merging(["error": error]) { _, new in new },
                     line: JasmineLine(chinese: chinese, english: english), offer: offer)
    }

    static var notUnderstood: JasmineFound { failed("not understood", "没听明白。", "I didn’t get that.") }
    static var nothingWaiting: JasmineFound {
        failed("nothing is waiting for an answer", "没有在等回答的事。", "Nothing is waiting for an answer.")
    }
    static var declined: JasmineFound { done(["cancelled": true], "好的。", "OK.") }
}

/// Something she proposed and is waiting to hear about: one action to agree to (play it from 哔哩哔哩 instead), or
/// one of several to choose (which person). What's said next answers it: yes does it, no drops it, 第一个 or a name
/// chooses; anything else is a new request and the offer is dropped. Unanswered for a minute, it's dropped too.
struct JasmineOffer: Equatable {
    /// What she's asking, for the model.
    let ask: String
    /// The names to choose from; empty when it's yes or no.
    let choices: [String]
    /// What each choice does (one, for yes or no).
    let actions: [JasmineSearch]
    var until = Date.distantFuture

    static let life: TimeInterval = 60

    enum Reply: Equatable {
        case yes, no
        case choice(Int)
    }

    private static let yes = ["好的", "好啊", "好呀", "好嘞", "好", "可以的", "可以啊", "可以", "行的", "行啊", "行", "嗯嗯", "嗯", "对的", "对",
                              "是的", "是", "要的", "要", "当然", "没问题", "那就放", "就放", "放一个", "放", "播放", "播", "来一个", "来",
                              "okay", "ok", "yes", "yeah", "yep", "yup", "sure", "please", "doit", "goahead", "fine", "alright", "playit"]
    private static let no = ["不用了", "不用", "不要了", "不要", "不必了", "不必", "不了", "不行", "不好", "不可以", "不放了", "不放", "不",
                             "算了", "别放了", "别放", "别", "取消", "没事", "nothankyou", "nothanks", "nope", "nah", "no", "cancel",
                             "nevermind", "dont"]

    /// What was said, as an answer to an offer with these choices. Nil when it isn't one.
    static func reply(_ heard: String, choices: [String]) -> Reply? {
        let text = LocalCommand.normalized(heard)
        guard !text.isEmpty else { return nil }
        if only(no, text) { return .no }
        guard !choices.isEmpty else { return only(yes, text) ? .yes : nil }
        if let index = ordinal(text, of: choices.count) ?? named(text, in: choices) { return .choice(index) }
        return nil
    }

    /// The whole text is these words and nothing else: 好的放吧, 不用了算了.
    private static func only(_ words: [String], _ text: String) -> Bool {
        Spoken.captures(text, "(?:" + words.joined(separator: "|") + ")+") != nil
    }

    /// 第一个, 二号, 3, 最后一个; the first one, second, last.
    private static func ordinal(_ text: String, of count: Int) -> Int? {
        if ["最后一个", "最后那个", "最后一位", "最后", "last", "lastone", "thelast", "thelastone"].contains(text) { return count - 1 }
        var number: Int?
        if let said = Spoken.captures(text, "(?:就|要|选|我要|我选)?第?\(Spoken.chinese)(?:个|位|号|条)?(?:那个)?")?.first ?? nil {
            number = Spoken.number(said).flatMap { Int(exactly: $0) }
        } else if let said = Spoken.captures(text, "(?:the)?(first|second|third|fourth|fifth|1st|2nd|3rd|4th|5th)(?:one)?")?.first ?? nil {
            number = ["first": 1, "1st": 1, "second": 2, "2nd": 2, "third": 3, "3rd": 3, "fourth": 4, "4th": 4, "fifth": 5, "5th": 5][said]
        }
        return number.flatMap { (1...count).contains($0) ? $0 - 1 : nil }
    }

    /// One of the names, or the only one it's part of: 老番茄, 老番茄那个.
    private static func named(_ text: String, in choices: [String]) -> Int? {
        guard let said = Spoken.captures(text, "(?:就|要|选|我要|我选|是)?(.+?)(?:的?那个|的?那位|这个)?")?.first ?? nil else { return nil }
        let names = choices.map(LocalCommand.normalized)
        let same = names.indices.filter { names[$0] == said }
        if same.count == 1 { return same[0] }
        guard same.isEmpty, said.count >= 2 else { return nil }
        let near = names.indices.filter { names[$0].contains(said) || (names[$0].count >= 2 && said.contains(names[$0])) }
        return near.count == 1 ? near[0] : nil
    }
}

/// The requests to find something that are understood without the model, by how they're put (the words around the
/// name are fixed; the name is what's left):
///
/// | Said | Is |
/// |---|---|
/// | 我想听 X, 播放 X, 来一首 X; play X, listen to X | A song |
/// | 放 X 的歌, 我想听 X 的歌; play songs by X | An artist |
/// | 在 B 站看 X; watch X on Bilibili | A video on 哔哩哔哩 |
/// | 在 B 站看 X 的视频 | A person on 哔哩哔哩 |
/// | B 站搜 X; search X on Bilibili | 哔哩哔哩's search |
/// | 搜一下 X, 帮我搜 X, 查一下 X; search for X, look up X | A web search |
///
/// Only when the name is a name: a mood or a scene (放点睡前歌单, 想听点舒缓的古典音乐), something pointed at (这首,
/// 刚才那个) or anything long is the model's, which turns it into search words.
enum LocalSearch {
    static func match(_ heard: String) -> JasmineSearch? {
        var text = Heard.forField(heard)
        for ending in ["吧", "好吗", "行吗", "可以吗", " please"] where text.lowercased().hasSuffix(ending) { text.removeLast(ending.count) }
        func caught(_ pattern: String) -> String? {
            (Spoken.captures(text, "(?i)\\s*(?:please\\s+|请|麻烦你?)?(?:帮我|给我)?\\s*" + pattern)?.first ?? nil).map(name)
        }
        let bilibili = "(?:(?:在|去|用|上)\\s*)?(?:b\\s*站|哔哩哔哩|bilibili)\\s*(?:上面|上|里面|里)?\\s*"

        if let words = caught(bilibili + "(?:搜索|搜一搜|搜|找找|找|查)(?:一下)?\\s*(.+)")
            ?? caught("(?:search|find)\\s+(?:for\\s+)?(.+?)\\s+on\\s+bilibili") {
            let words = person(words) ?? words
            return pointing(words) ? nil : .video(words, .search)
        }
        if let words = caught(bilibili + "(?:看看|看|播放|播|放)(?:一下)?\\s*(.+)") ?? caught("(?:watch|play)\\s+(.+?)\\s+on\\s+bilibili") {
            if let who = person(words) { return pointing(who) ? nil : .video(who, .person) }
            return pointing(words) ? nil : .video(words, .video)
        }
        if let words = caught("(?:上网|在网上|网上)?\\s*(?:(?:搜索|搜一搜|搜|百度|谷歌)(?:一下)?|查一下|查一查|查查)\\s*(.+)")
            ?? caught("(?:search\\s+(?:the\\s+web\\s+|online\\s+)?for|google|look\\s+up)\\s+(.+)") {
            return unclear(words) || elsewhere(words) ? nil : .web(words)
        }
        if let who = caught("(?:播放|听听|放|播|听|来)(?:点|些|一点|一些|几首)?\\s*(.+?)的(?:歌曲|歌|音乐)")
            ?? caught("(?:play|listen\\s+to)\\s+(?:(?:some\\s+)?(?:songs|music)|something)\\s+by\\s+(.+)") {
            return singer(who)
        }
        if let words = caught("(?:我\\s*)?(?:想要|想|要)\\s*听(?:一下|一首|首)?\\s*(.+)")
            ?? caught("(?:播放|来一首|来首|放一首|放首|播一首|播首|听一首|听首|听一下)\\s*(.+)")
            ?? caught("(?:i\\s+(?:want|wanna|would\\s+like|'d\\s+like)\\s+to\\s+(?:listen\\s+to|hear)|play|listen\\s+to)\\s+(.+)") {
            if let who = (Spoken.captures(words, "(?:点|些|一点|一些|几首)?\\s*(.+?)的(?:歌曲|歌|音乐)")?.first ?? nil).map(name) { return singer(who) }
            return pointing(words) || mood(words) || elsewhere(words) ? nil : .music(words, .song)
        }
        return nil
    }

    private static func singer(_ who: String) -> JasmineSearch? {
        pointing(who) || mood(who) || elsewhere(who) || ["我", "你", "他", "她", "别人", "他们"].contains(who) ? nil : .music(who, .artist)
    }

    /// X 的视频: the person whose videos they are.
    private static func person(_ words: String) -> String? {
        (Spoken.captures(words, "(.+?)(?:最新)?的(?:最新|新)?视频")?.first ?? nil).map(name)
    }

    /// The name as it's searched for: without the quotes around it.
    private static func name(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "《》「」『』“”\"'‘’，,。.")))
    }

    /// Not a name: nothing, one character, a sentence, or something pointed at (这首, 刚才那个, 第二集, something).
    private static func pointing(_ words: String) -> Bool {
        let text = words.lowercased()
        if text.count < 2 || text.count > 30 { return true }
        if ["点", "些", "个", "首", "第", "一点", "一些", "一个", "一首", "some ", "a ", "an ", "my ", "it ", "this", "that", "something",
            "anything", "more ", "another", "the next", "the previous", "the last", "next ", "previous "].contains(where: text.hasPrefix) {
            return true
        }
        if ["it", "歌", "歌曲", "音乐", "首歌", "视频", "列表", "队列", "历史", "music", "songs"].contains(text) { return true }
        return ["这", "那个", "那首", "那部", "那位", "哪", "什么", "刚才", "刚刚", "上次", "之前", "下一", "上一", "一下", "一集", "它"]
            .contains(where: text.contains)
    }

    /// Not something to search the web for: nothing, a paragraph, or something pointed at. (A question is: 怎么做红烧肉.)
    private static func unclear(_ words: String) -> Bool {
        let text = words.lowercased()
        if text.count < 2 || text.count > 40 { return true }
        if ["这", "它", "it ", "this", "that"].contains(where: text.hasPrefix) || ["it", "一下"].contains(text) { return true }
        return ["那个", "那首", "那部", "那位", "刚才", "刚刚"].contains(where: text.contains)
    }

    /// A mood, a scene, a kind of music, or a kind of thing that isn't a song: the model's to turn into search words.
    private static func mood(_ words: String) -> Bool {
        let text = words.lowercased()
        return ["怎么", "最近", "视频", "电影", "电视", "直播", "节目", "歌单", "音乐", "电台", "播客", "有声书", "的歌", "随便", "推荐", "好听",
                "热门", "流行", "类似", "风格", "适合", "心情", "安静", "舒缓", "轻松", "放松", "欢快", "开心", "伤感", "悲伤", "浪漫", "治愈",
                "助眠", "睡前", "睡觉", "起床", "运动", "跑步", "工作", "学习", "古典", "爵士", "摇滚", "民谣", "说唱", "电子", "钢琴", "我喜欢",
                "我收藏", "playlist", "video", "movie", "episode", "music", "songs", "podcast", "radio", "jazz", "classical",
                "relaxing", "calm", "sleep"].contains(where: text.contains)
    }

    /// Names another app: which one is meant is the model's.
    private static func elsewhere(_ words: String) -> Bool {
        let text = words.lowercased()
        return ["youtube", "油管", "b站", "b 站", "哔哩哔哩", "bilibili", "网易云", "得到", "netflix"].contains(where: text.contains)
    }
}

/// Whether 网易云音乐 can play a song now. `preview`: only a sample of it (a members' song, on an account that isn't
/// one); `unavailable`: it answered, with no address (copyright, membership or region); `unreachable`: no answer.
enum JasmineAvailability { case playable, preview, unavailable, unreachable }

/// Where she finds music: 网易云音乐 (NeteaseStore). A search that couldn't be asked is nil; one that found nothing
/// is empty.
@MainActor
protocol JasmineMusic: AnyObject {
    var signedIn: Bool { get }
    /// The person's own playlists: made and saved.
    var ownPlaylists: [NeteasePlaylist] { get }
    func findSongs(_ keyword: String) async -> [NeteaseSong]?
    func findArtists(_ keyword: String) async -> [NeteasePlaylist]?
    func findPlaylists(_ keyword: String) async -> [NeteasePlaylist]?
    /// An artist's popular songs, or a playlist's; empty when they couldn't be got.
    func songs(of list: NeteasePlaylist) async -> [NeteaseSong]
    func availability(of song: NeteaseSong) async -> JasmineAvailability
    func playFound(_ song: NeteaseSong, in songs: [NeteaseSong], from list: NeteasePlaylist?)
}

/// Where she finds videos: 哔哩哔哩 (BilibiliStore).
@MainActor
protocol JasmineVideos: AnyObject {
    func findVideos(_ keyword: String) async -> [BiliVideo]?
    func findPeople(_ keyword: String) async -> [BiliUser]?
    /// A person's videos, the newest first; empty when they couldn't be got.
    func uploads(of user: BiliUser) async -> [BiliVideo]
    func playFound(_ video: BiliVideo, of user: BiliUser?)
    func showResults(for keyword: String)
}

/// Finds what's asked for and starts it, and keeps the one offer that waits for its answer.
@MainActor
final class JasmineFinder {
    private let music: any JasmineMusic
    private let videos: any JasmineVideos
    private let web: (URL) -> Void
    private let now: () -> Date
    private var offer: JasmineOffer?

    init(music: any JasmineMusic, videos: any JasmineVideos, web: @escaping (URL) -> Void, now: @escaping () -> Date = Date.init) {
        self.music = music
        self.videos = videos
        self.web = web
        self.now = now
    }

    // MARK: The offer

    /// The offer waiting for its answer, if it hasn't run out.
    var waiting: JasmineOffer? {
        if let offer, offer.until <= now() { self.offer = nil }
        return offer
    }

    /// What was said, when it answers the offer that waits.
    func reply(to heard: String) -> JasmineOffer.Reply? {
        waiting.flatMap { JasmineOffer.reply(heard, choices: $0.choices) }
    }

    /// The offer is answered: agreed to or chosen, it's done; declined, it's dropped.
    func settle(_ reply: JasmineOffer.Reply) async -> JasmineFound {
        guard let offer = waiting else { return .nothingWaiting }
        let index: Int
        switch reply {
        case .no:
            self.offer = nil
            return .declined
        case .yes:
            guard offer.choices.isEmpty else { return .failed("which one? choice is 1 to \(offer.choices.count)", "要哪一个？", "Which one?") }
            index = 0
        case .choice(let chosen):
            guard offer.actions.indices.contains(chosen), !offer.choices.isEmpty else { return .notUnderstood }
            index = chosen
        }
        self.offer = nil
        return await find(offer.actions[index])
    }

    /// Something else was said: the offer is dropped. With `only`, when it's still that one (a request of the model's
    /// keeps the offer while it runs, for the model to answer, and may leave a new one).
    func forget(only that: JasmineOffer? = nil) {
        if that == nil || that == offer { offer = nil }
    }

    /// For the model's state: what she asked and waits to hear about.
    var state: [String: Any]? {
        waiting.map { $0.choices.isEmpty ? ["asked": $0.ask] : ["asked": $0.ask, "choices": $0.choices] }
    }

    // MARK: The tools

    static let tools: [AssistantTool] = [
        AssistantTool(name: "play_music", description: """
                      Find music on 网易云音乐 and play it. kind song: `query` is the song's name, with the singer when known. \
                      artist: the singer's name. playlist: a few search words for a mood, a scene or a genre (睡前, 舒缓 古典); \
                      the person's own playlists come first, then a well-played public one.
                      """,
                      parameters: ["type": "object", "properties": [
                        "query": ["type": "string"],
                        "kind": ["type": "string", "enum": ["song", "artist", "playlist"]],
                      ], "required": ["query", "kind"], "additionalProperties": false]),
        AssistantTool(name: "play_video", description: """
                      Find on 哔哩哔哩. kind video: play the first video for `query`. person: play the newest video of that \
                      uploader. search: show 哔哩哔哩's search results for `query`.
                      """,
                      parameters: ["type": "object", "properties": [
                        "query": ["type": "string"],
                        "kind": ["type": "string", "enum": ["video", "person", "search"]],
                      ], "required": ["query", "kind"], "additionalProperties": false]),
        AssistantTool(name: "web_search", description: "Open the web search results for `query` in the TV's browser.",
                      parameters: ["type": "object", "properties": ["query": ["type": "string"]],
                                   "required": ["query"], "additionalProperties": false]),
        AssistantTool(name: "answer", description: """
                      Their answer to what the state's `waiting` asked: `accept` true does it, false drops it; `choice` is \
                      which of its choices, from 1.
                      """,
                      parameters: ["type": "object", "properties": [
                        "accept": ["type": "boolean"],
                        "choice": ["type": ["integer", "null"]],
                      ], "required": ["accept", "choice"], "additionalProperties": false]),
    ]

    /// A tool of these the model called: done, and what came of it, as JSON. Nil for a tool that isn't one of these.
    func tool(_ call: ToolCall) async -> String? {
        let query = (call.arguments["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = call.arguments["kind"] as? String ?? ""
        let search: JasmineSearch?
        switch call.name {
        case "play_music": search = JasmineSearch.Music(rawValue: kind).map { .music(query, $0) }
        case "play_video": search = JasmineSearch.Video(rawValue: kind).map { .video(query, $0) }
        case "web_search": search = .web(query)
        case "answer":
            guard let accept = call.arguments["accept"] as? Bool else { return JasmineFound.notUnderstood.json }
            guard accept else { return await settle(.no).json }
            let choice = (call.arguments["choice"] as? NSNumber)?.intValue
            return await settle(choice.map { .choice($0 - 1) } ?? .yes).json
        default: return nil
        }
        guard let search, !query.isEmpty else { return JasmineFound.notUnderstood.json }
        return await find(search).json
    }

    // MARK: Finding

    /// Finds it and starts it. An offer that comes of it waits from now; the one before is gone.
    func find(_ search: JasmineSearch) async -> JasmineFound {
        offer = nil
        var found: JasmineFound
        switch search {
        case .music(let query, .song): found = await song(query)
        case .music(let query, .artist): found = await artist(query)
        case .music(let query, .playlist): found = await playlist(query)
        case .video(let query, .video): found = await video(query)
        case .video(let query, .person): found = await person(query)
        case .video(let query, .search):
            videos.showResults(for: query)
            found = .done(["showing": "哔哩哔哩's search for \(query)"], "在 B 站搜「\(query)」。", "Searching Bilibili for \(query).")
        case .latest(let user): found = await latest(of: user)
        case .web(let query):
            guard let url = BrowserStore.search(query) else { return .notUnderstood }
            web(url)
            found = .done(["showing": "web search results for \(query)"], "搜索「\(query)」。", "Searching the web for \(query).")
        }
        found.offer?.until = now().addingTimeInterval(JasmineOffer.life)
        offer = found.offer
        return found
    }

    private static let netease = JasmineFound.failed("couldn't reach 网易云音乐", "连不上网易云音乐。", "Can’t reach 网易云音乐.")
    private static let signedOut = JasmineFound.failed("网易云音乐 isn't signed in", "网易云音乐还没登录。", "网易云音乐 isn’t signed in.")
    private static let bilibili = JasmineFound.failed("couldn't reach 哔哩哔哩", "连不上哔哩哔哩。", "Can’t reach Bilibili.")

    private func song(_ query: String) async -> JasmineFound {
        guard music.signedIn else { return Self.signedOut }
        guard let songs = await music.findSongs(query) else { return Self.netease }
        guard let top = songs.first else { return nothing(on: query) }
        // The words are a singer's name and no song's: the singer's songs
        let plain = LocalCommand.normalized(query)
        if top.artists.contains(where: { LocalCommand.normalized($0.name) == plain }),
           !songs.contains(where: { LocalCommand.normalized($0.name) == plain }) {
            return await artist(query)
        }
        // The same song released more than once: any of them is it. Someone else's version isn't what was asked for
        let same = songs.filter { $0.name == top.name && $0.artist == top.artist }
        switch await firstPlayable(in: same) {
        case .song(let song):
            music.playFound(song, in: songs, from: nil)
            return .done(["playing": song.name, "artist": song.artist],
                         song.artist.isEmpty ? "播放《\(song.name)》。" : "播放\(song.artist)的《\(song.name)》。",
                         song.artist.isEmpty ? "Playing \(song.name)." : "Playing \(song.name) by \(song.artist).")
        case .blocked(let why):
            return blocked("\(top.name) by \(top.artist)", why, "《\(top.name)》", top.name, video: "\(top.name) \(top.artist)")
        case .unreachable:
            return Self.netease
        }
    }

    private func artist(_ query: String) async -> JasmineFound {
        guard music.signedIn else { return Self.signedOut }
        guard let artists = await music.findArtists(query) else { return Self.netease }
        let plain = LocalCommand.normalized(query)
        guard let artist = artists.first(where: { LocalCommand.normalized($0.name) == plain }) ?? artists.first else { return nothing(on: query) }
        let songs = await music.songs(of: artist)
        guard !songs.isEmpty else { return empty(artist.name) }
        switch await firstPlayable(in: songs) {
        case .song(let song):
            music.playFound(song, in: songs, from: artist)
            return .done(["playing": song.name, "artist": artist.name, "queue": "\(artist.name)'s popular songs"],
                         "播放\(artist.name)的歌。", "Playing songs by \(artist.name).")
        case .blocked(let why):
            return blocked("\(artist.name)'s songs", why, "\(artist.name)的歌", "\(artist.name)’s songs", video: artist.name)
        case .unreachable:
            return Self.netease
        }
    }

    private func playlist(_ query: String) async -> JasmineFound {
        guard music.signedIn else { return Self.signedOut }
        var list = Self.named(query, in: music.ownPlaylists)
        let own = list != nil
        if list == nil {
            guard let lists = await music.findPlaylists(query) else { return Self.netease }
            list = Self.best(lists)
        }
        guard let list else {
            return .failed("no playlist on 网易云音乐 for \(query)", "网易云没找到「\(query)」的歌单。", "No playlist on 网易云音乐 for \(query).")
        }
        let songs = await music.songs(of: list)
        guard !songs.isEmpty else { return empty(list.name) }
        switch await firstPlayable(in: songs) {
        case .song(let song):
            music.playFound(song, in: songs, from: list)
            return .done(["playlist": list.name, "from": own ? "their own playlists" : "a public playlist", "playing": song.name,
                          "artist": song.artist],
                         own ? "播放你的歌单《\(list.name)》。" : "播放歌单《\(list.name)》。",
                         own ? "Playing your playlist \(list.name)." : "Playing the playlist \(list.name).")
        case .blocked(let why):
            return .failed("网易云音乐 can't play the playlist \(list.name): \(why)", "网易云放不了歌单《\(list.name)》。",
                           "网易云音乐 can’t play the playlist \(list.name).")
        case .unreachable:
            return Self.netease
        }
    }

    /// The playlist of the person's own that the words name: 跑步 is 跑步歌单, 睡前歌单 is 睡前.
    static func named(_ query: String, in lists: [NeteasePlaylist]) -> NeteasePlaylist? {
        var words = LocalCommand.normalized(query)
        for ending in ["歌单", "playlist"] where words.hasSuffix(ending) { words.removeLast(ending.count) }
        guard !words.isEmpty else { return nil }
        let names = lists.map { LocalCommand.normalized($0.name) }
        let index = names.firstIndex(of: words) ?? names.firstIndex { $0.contains(words) || ($0.count >= 2 && words.contains($0)) }
        return index.map { lists[$0] }
    }

    /// Of the public playlists found: the most played of those with enough songs (20; any, when none has).
    static func best(_ lists: [NeteasePlaylist]) -> NeteasePlaylist? {
        let full = lists.filter { $0.count >= 20 }
        return (full.isEmpty ? lists.filter { $0.count > 0 } : full).max { $0.plays < $1.plays }
    }

    private enum Playable {
        case song(NeteaseSong)
        /// None can be played: why, for the model.
        case blocked(String)
        case unreachable
    }

    /// The first of these 网易云音乐 can play, of the first three (as its own player gives up after three).
    private func firstPlayable(in songs: [NeteaseSong]) async -> Playable {
        var preview = false
        for song in songs.prefix(3) {
            switch await music.availability(of: song) {
            case .playable: return .song(song)
            case .preview: preview = true
            case .unavailable: break
            case .unreachable: return .unreachable
            }
        }
        return .blocked(preview ? "members only (a preview is all this account gets)" : "copyright, membership or region")
    }

    private static let instead = "whether to play a video of it from 哔哩哔哩 instead"

    /// 网易云音乐 has it and can't play it: she asks about a video from 哔哩哔哩.
    private func blocked(_ what: String, _ why: String, _ chinese: String, _ english: String, video: String) -> JasmineFound {
        .failed("网易云音乐 can't play \(what): \(why)", "网易云放不了\(chinese)，从 B 站放一个视频行吗？",
                "网易云音乐 can’t play \(english). Play a video of it from Bilibili instead?",
                offer: JasmineOffer(ask: Self.instead, choices: [], actions: [.video(video, .video)]))
    }

    /// 网易云音乐 has nothing for the words: the same question.
    private func nothing(on query: String) -> JasmineFound {
        .failed("nothing on 网易云音乐 for \(query)", "网易云没找到「\(query)」，从 B 站放一个视频行吗？",
                "Nothing on 网易云音乐 for \(query). Play a video of it from Bilibili instead?",
                offer: JasmineOffer(ask: Self.instead, choices: [], actions: [.video(query, .video)]))
    }

    private func empty(_ name: String) -> JasmineFound {
        .failed("couldn't get the songs of \(name) from 网易云音乐", "没取到「\(name)」的歌。", "Couldn’t get the songs of \(name).")
    }

    private func video(_ query: String) async -> JasmineFound {
        guard let found = await videos.findVideos(query) else { return Self.bilibili }
        guard let video = found.first else {
            return .failed("nothing on 哔哩哔哩 for \(query)", "B 站没找到「\(query)」。", "Nothing on Bilibili for \(query).")
        }
        videos.playFound(video, of: nil)
        return .done(["opened": video.title, "by": video.owner, "on": "哔哩哔哩"], "从 B 站播放《\(video.title)》。",
                     "Playing \(video.title) from Bilibili.")
    }

    private func person(_ query: String) async -> JasmineFound {
        guard let people = await videos.findPeople(query) else { return Self.bilibili }
        guard !people.isEmpty else {
            return .failed("nobody on 哔哩哔哩 named \(query)", "B 站没找到叫「\(query)」的 UP 主。", "Nobody on Bilibili named \(query).")
        }
        // The one found, or the one whose name it is (names there are one person's each)
        let plain = LocalCommand.normalized(query)
        if let one = people.count == 1 ? people.first : people.first(where: { LocalCommand.normalized($0.name) == plain }) {
            return await latest(of: one)
        }
        let few = Array(people.prefix(3)), names = few.map(\.name)
        return .failed("several people on 哔哩哔哩 match \(query)", "找到\(few.count)位：\(names.joined(separator: "、"))。要哪一个？",
                       "I found \(names.joined(separator: ", ")). Which one?",
                       report: ["candidates": few.map { ["name": $0.name, "followers": $0.fans, "about": $0.sign] as [String: Any] }],
                       offer: JasmineOffer(ask: "which of these people they mean", choices: names, actions: few.map { .latest($0) }))
    }

    private func latest(of user: BiliUser) async -> JasmineFound {
        guard let video = await videos.uploads(of: user).first else {
            return .failed("couldn't get \(user.name)'s videos from 哔哩哔哩", "没取到\(user.name)的视频。", "Couldn’t get \(user.name)’s videos.")
        }
        videos.playFound(video, of: user)
        return .done(["opened": video.title, "by": user.name, "on": "哔哩哔哩", "newest": true], "播放\(user.name)最新的视频。",
                     "Playing \(user.name)’s newest video.")
    }
}
