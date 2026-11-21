import Foundation

/// What Jasmine can do in Mac TV, and what she's told about it: open an app, control what's playing, the volume.
/// The commonest of these are understood here, without the model (LocalCommand). Finding something to play is
/// JasmineSearch.
enum JasmineCommand: Equatable {
    case open(String)          // a service id
    case home, controlCenter, settings
    case playback(Playback)
    case volume(Int), volumeStep(Int), mute(Bool)
    case standby

    /// Asked of whatever is playing (see JasminePlayer).
    enum Playback: Equatable {
        case play, pause
        case next, previous
        /// Seconds from where it is; back when negative.
        case skip(Int)
        /// Seconds from the start; 0 starts over.
        case seek(Int)
        case subtitles(Bool)
        /// 1 is normal.
        case speed(Double)
    }
}

/// Why a command wasn't done: told to the model as it is, and in a line on screen.
enum JasmineFailure: Equatable {
    case notUnderstood
    case nothingPlaying
    /// What's playing can't do it, or can't now: why, for the model.
    case unavailable(String)

    var reason: String {
        switch self {
        case .notUnderstood: "not understood"
        case .nothingPlaying: "nothing is playing"
        case .unavailable(let why): why
        }
    }

    var line: String {
        switch self {
        case .nothingPlaying: "Nothing Is Playing"
        case .notUnderstood, .unavailable: "Not Available"
        }
    }
}

/// The short commands understood without the model (as PianaSoul's playback_commands): the whole of what was said,
/// in Chinese or English, with a number where one belongs (快进 30 秒, 1.5 倍速, volume 40), or 打开 / open and an
/// app's name. Anything else goes to the model.
enum LocalCommand {
    static func match(_ heard: String, apps: [(id: String, name: String)]) -> JasmineCommand? {
        let text = normalized(heard)
        guard !text.isEmpty else { return nil }
        if let command = exact[text] ?? measured(text) { return command }
        for opener in ["打开", "开一下", "启动", "进入", "open", "launch", "goto"] where text.hasPrefix(opener) {
            let name = String(text.dropFirst(opener.count))
            if ["设置", "settings"].contains(name) { return .settings }
            if let id = app(named: name, in: apps) { return .open(id) }
        }
        return nil
    }

    private static let exact: [String: JasmineCommand] = {
        var table: [String: JasmineCommand] = [:]
        func say(_ command: JasmineCommand, _ phrases: String...) { for phrase in phrases { table[phrase] = command } }
        say(.playback(.pause), "暂停", "停", "停止", "暂停播放", "停止播放", "pause", "stop")
        say(.playback(.play), "播放", "播", "继续", "继续播放", "继续放", "接着放", "接着播", "play", "resume", "continue")
        say(.playback(.next), "下一首", "下一个", "下一集", "下一曲", "下一讲", "下一首歌", "放下一首", "播放下一首", "切歌",
            "next", "nextone", "nextsong", "nexttrack", "nextepisode", "nextvideo", "playthenextone", "playthenextsong")
        say(.playback(.previous), "上一首", "上一个", "上一集", "上一曲", "上一讲", "上一首歌", "放上一首", "播放上一首",
            "previous", "previousone", "previoussong", "previoustrack", "previousepisode", "previousvideo",
            "playthepreviousone", "playtheprevioussong")
        say(.playback(.skip(10)), "快进", "skipforward", "fastforward")
        say(.playback(.skip(-10)), "快退", "后退", "skipback", "rewind")
        say(.playback(.seek(0)), "从头放", "从头播", "从头播放", "从头开始", "从头开始放", "从头开始播放", "从头再来", "重新播放",
            "重头放", "重头开始", "startover", "restart", "playfromthebeginning", "playitfromthebeginning",
            "fromthebeginning", "startfromthebeginning", "playfromthestart", "fromthestart", "backtothebeginning")
        say(.playback(.subtitles(true)), "打开字幕", "开字幕", "开启字幕", "显示字幕", "字幕打开", "把字幕打开",
            "subtitleson", "turnonsubtitles", "turnonthesubtitles", "turnsubtitleson", "showsubtitles", "showthesubtitles",
            "captionson", "turnoncaptions", "turnonthecaptions", "showcaptions")
        say(.playback(.subtitles(false)), "关掉字幕", "关闭字幕", "关字幕", "隐藏字幕", "不要字幕", "字幕关掉", "把字幕关掉",
            "subtitlesoff", "turnoffsubtitles", "turnoffthesubtitles", "turnsubtitlesoff", "hidesubtitles", "hidethesubtitles",
            "captionsoff", "turnoffcaptions", "turnoffthecaptions", "hidecaptions")
        say(.playback(.speed(1)), "正常速度", "正常倍速", "正常速度播放", "原速", "原速播放", "恢复正常速度", "恢复原速",
            "normalspeed", "regularspeed", "playatnormalspeed", "backtonormalspeed")
        say(.volumeStep(10), "大点声", "大声点", "大声一点", "声音大点", "声音大一点", "音量大一点", "调大音量", "音量调大",
            "louder", "volumeup", "turnitup", "turnupthevolume", "turnthevolumeup")
        say(.volumeStep(-10), "小点声", "小声点", "小声一点", "声音小点", "声音小一点", "音量小一点", "调小音量", "音量调小",
            "quieter", "softer", "volumedown", "turnitdown", "turndownthevolume", "turnthevolumedown")
        say(.mute(true), "静音", "mute")
        say(.mute(false), "取消静音", "解除静音", "关闭静音", "unmute")
        say(.home, "回主屏", "回到主屏", "回主屏幕", "回到主屏幕", "主屏幕", "gohome", "home")
        say(.controlCenter, "控制中心", "controlcenter")
        say(.standby, "关屏幕", "关闭屏幕", "关电视", "待机", "turnoffthetv", "turnoffthescreen", "turnoffthedisplay")
        return table
    }()

    private static let forward = ["快进", "前进", "往前跳", "向前跳", "往前快进", "向前快进", "往前进",
                                  "skipforward", "fastforward", "goforward", "jumpforward", "skipahead", "jumpahead", "forward"]
    /// 往后跳 isn't here: some mean later by it, some earlier.
    private static let back = ["快退", "后退", "倒退", "回退", "倒回", "退后", "退回", "往回跳", "往回倒", "往回退", "往后退",
                               "skipbackwards", "skipbackward", "skipback", "goback", "jumpback", "rewind", "back"]
    private static let to = ["跳到", "跳转到", "快进到", "快退到", "回到", "jumpto", "skipto", "seekto", "goto"]

    /// The commands with a number in them: 快进 30 秒, rewind two minutes, 跳到 10 分钟, 1.5 倍速, 音量调到 30.
    private static func measured(_ text: String) -> JasmineCommand? {
        for (openers, sign) in [(forward, 1), (back, -1)] {
            for opener in openers where text.hasPrefix(opener) {
                if let seconds = Spoken.seconds(String(text.dropFirst(opener.count))) { return .playback(.skip(sign * seconds)) }
            }
        }
        for opener in to where text.hasPrefix(opener) {
            var place = String(text.dropFirst(opener.count))
            if place.hasPrefix("第") { place.removeFirst() }
            for ending in ["处", "的地方", "的位置"] where place.hasSuffix(ending) { place.removeLast(ending.count) }
            if let seconds = Spoken.seconds(place) { return .playback(.seek(seconds)) }
        }
        let speeds = ["(?:倍速|速度|播放速度)?(?:调到|调成|调为|设为|设成|换成|切到|改成|改为|开)?\(Spoken.chinese)倍速?(?:播放)?",
                      "(?:play(?:it)?at|(?:set(?:the)?)?(?:playback)?speed(?:to)?)?\(Spoken.english)(?:x|times)(?:speed)?"]
        if let speed = number(in: text, speeds), speed > 0, speed <= 4 { return .playback(.speed(speed)) }
        let volumes = ["把?(?:音量|声音)(?:调到|调成|调为|调整到|设为|设成|设到|设置为|设置成|开到|到)?(?:百分之)?\(Spoken.chinese)",
                       "(?:set|turn|change)?(?:the)?volume(?:to|at)?\(Spoken.english)(?:percent)?"]
        if let level = number(in: text, volumes), level == level.rounded(), (0...100).contains(level) { return .volume(Int(level)) }
        return nil
    }

    /// The number in the first of these patterns the whole text fits.
    private static func number(in text: String, _ patterns: [String]) -> Double? {
        for pattern in patterns {
            if let said = Spoken.captures(text, pattern)?.first ?? nil { return Spoken.number(said) }
        }
        return nil
    }

    /// Lowercase, without spaces, punctuation (a decimal point stays) and a polite "please" / 请 / 帮我.
    static func normalized(_ text: String) -> String {
        let scalars = Array(text.lowercased().unicodeScalars)
        func digit(_ index: Int) -> Bool { scalars.indices.contains(index) && ("0"..."9").contains(scalars[index]) }
        var kept = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            let dropped = CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar)
            if !dropped || (scalar == "." && digit(index - 1) && digit(index + 1)) { kept.append(scalar) }
        }
        var text = String(kept)
        for prefix in ["please", "请", "帮我", "给我"] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        for suffix in ["please", "吧", "一下"] where text.hasSuffix(suffix) && text.count > suffix.count { text.removeLast(suffix.count) }
        return text
    }

    /// An app by its name, or a name people say for it.
    static func app(named name: String, in apps: [(id: String, name: String)]) -> String? {
        let aliases = ["b站": "bilibili", "哔哩哔哩": "bilibili", "bilibili": "bilibili", "网易云": "netease", "网易云音乐": "netease",
                       "油管": "youtube", "youtube": "youtube", "得到": "dedao", "影片": "movies", "电影": "movies", "movies": "movies", "videos": "movies",
                       "浏览器": "browser", "网页": "browser", "web": "browser", "safari": "browser"]
        if let id = aliases[name], apps.contains(where: { $0.id == id }) { return id }
        return apps.first { normalized($0.name) == name }?.id
    }
}

/// Numbers and lengths of time as they're said or written out, without spaces (LocalCommand.normalized): 30, 1.5,
/// 三十, 两, 一点五, thirty, twentyfive, onepointfive; 30秒, 两分钟, 1分30秒, 半小时, thirtyseconds, aminute.
enum Spoken {
    /// A number inside a pattern, Chinese or English: its one capture.
    static let chinese = "([0-9.]+|[零〇一二两三四五六七八九十百点半]+)"
    static let english = "([0-9.]+|[a-z]+?)"

    /// What each group of the pattern caught, when the whole text fits it.
    static func captures(_ text: String, _ pattern: String) -> [String?]? {
        guard let match = try? Regex(pattern).wholeMatch(in: text) else { return nil }
        return match.output.dropFirst().map { $0.substring.map(String.init) }
    }

    static func number(_ text: String) -> Double? {
        if text.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789.").contains($0) }) { return Double(text) }
        for point in ["点", "point"] {
            let parts = text.components(separatedBy: point)
            guard parts.count == 2 else { continue }
            guard let whole = integer(parts[0]), let fraction = digits(parts[1]) else { return nil }
            return Double("\(whole).\(fraction)")
        }
        return integer(text).map(Double.init)
    }

    /// Whole seconds, at least one and at most a day.
    static func seconds(_ text: String) -> Int? {
        let patterns = ["(?:\(chinese)个?小时)?(?:\(chinese)分钟?)?(?:\(chinese)秒钟?)?",
                        "(?:\(english)(?:hours?|hrs?))?(?:and)?(?:\(english)(?:minutes?|mins?))?(?:and)?(?:\(english)(?:seconds?|secs?))?"]
        let words = ["半": 0.5, "half": 0.5, "halfa": 0.5, "halfan": 0.5, "a": 1, "an": 1]
        for pattern in patterns {
            guard let parts = captures(text, pattern), parts.contains(where: { $0 != nil }) else { continue }
            var total = 0.0
            for (part, unit) in zip(parts, [3600.0, 60, 1]) {
                guard let part else { continue }
                guard let amount = words[part] ?? number(part) else { return nil }
                total += amount * unit
            }
            return total >= 1 && total <= 86_400 && total == total.rounded() ? Int(total) : nil
        }
        return nil
    }

    private static let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
                               "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
    private static let tens = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]
    private static let figures: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7,
                                                    "八": 8, "九": 9]

    /// 三十, 一百零五, 两; thirty, twentyfive (its hyphen is gone).
    private static func integer(_ text: String) -> Int? {
        if let value = ones.firstIndex(of: text) ?? tens[text] { return value }
        for (ten, value) in tens where text.hasPrefix(ten) {
            if let one = ones.firstIndex(of: String(text.dropFirst(ten.count))), (1...9).contains(one) { return value + one }
        }
        guard !text.isEmpty else { return nil }
        var total = 0
        var figure: Int?
        for character in text {
            if let value = figures[character] {
                guard figure == nil || figure == 0 else { return nil }   // 二五 isn't twenty-five
                figure = value
            } else if let unit = ["十": 10, "百": 100][character] {
                total += (figure ?? 1) * unit
                figure = nil
            } else {
                return nil
            }
        }
        return total + (figure ?? 0)
    }

    /// What follows the point, figure by figure: 25, 二五, twofive.
    private static func digits(_ text: String) -> String? {
        var rest = Substring(text), found = ""
        while let first = rest.first {
            if first.isASCII, first.isNumber {
                found.append(first)
                rest.removeFirst()
            } else if let value = figures[first] {
                found += String(value)
                rest.removeFirst()
            } else if let value = ones[..<10].firstIndex(where: { rest.hasPrefix($0) }) {
                found += String(value)
                rest.removeFirst(ones[value].count)
            } else {
                return nil
            }
        }
        return found.isEmpty ? nil : found
    }
}

extension TVController {
    /// Jasmine's instructions: the same for every request, so OpenAI's prompt cache keeps them.
    static let jasmineInstructions = """
    You are Jasmine (小茗同学), the voice assistant built into Mac TV, a TV home screen running on a Mac, used with a \
    remote from the sofa. Reply in the language the person used (Chinese or English; mixing them is fine). Say one or \
    two short sentences, as spoken aloud: no Markdown, no lists, no emoji. Never mention tools, JSON or the state.
    To do something on the TV, call a tool; never say something was done unless a tool did it, and if a tool fails, \
    say so in a few words. For something no tool can do yet, say briefly that you can't do that yet. Before a tool \
    that takes a moment, say nothing; after it, confirm in a few words or not at all. Questions: answer briefly from \
    what you know and from the state, which says what's on screen and what's playing.
    Music is play_music: a song or an artist by name; for a mood, a scene or a genre, a playlist from a few search \
    words of yours, and say which playlist it is. play_video is for 哔哩哔哩. web_search only when asked to search. \
    A result with `ask` did nothing: ask that in one short sentence, and never play from somewhere else unasked. \
    Their reply comes with `waiting` in the state: call answer when it agrees, declines or chooses.
    """

    /// The apps Jasmine can open: what's on Home.
    var jasmineApps: [(id: String, name: String)] {
        services.filter { $0.kind != .addApp }.map { ($0.id, $0.name) }
    }

    var jasmineTools: [AssistantTool] {
        let apps = jasmineApps
        return [
            AssistantTool(name: "open", description: "Open an app, Home, Control Center or Settings on the TV. Apps: "
                          + apps.map { "\($0.id) (\($0.name))" }.joined(separator: ", "),
                          parameters: ["type": "object", "properties": [
                            "target": ["type": "string", "enum": apps.map(\.id) + ["home", "control_center"]],
                          ], "required": ["target"], "additionalProperties": false]),
            AssistantTool(name: "control", description: """
                          Control what's playing. play, pause; next, previous (a song, an episode, a lecture); skip by \
                          `seconds` (negative goes back); seek to `seconds` from the start; restart; subtitles_on, \
                          subtitles_off; speed with `speed` (1 is normal). A player that can't do one says so: a web page \
                          and YouTube only play, pause and skip 10 or -10.
                          """,
                          parameters: ["type": "object", "properties": [
                            "action": ["type": "string", "enum": ["play", "pause", "next", "previous", "skip", "seek", "restart",
                                                                  "subtitles_on", "subtitles_off", "speed"]],
                            "seconds": ["type": ["integer", "null"]],
                            "speed": ["type": ["number", "null"]],
                          ], "required": ["action", "seconds", "speed"], "additionalProperties": false]),
            AssistantTool(name: "volume", description: "The TV's volume: set a level (0–100), change it by an amount, or mute and unmute.",
                          parameters: ["type": "object", "properties": [
                            "level": ["type": ["integer", "null"], "minimum": 0, "maximum": 100],
                            "change": ["type": ["integer", "null"], "minimum": -100, "maximum": 100],
                            "mute": ["type": ["boolean", "null"]],
                          ], "required": ["level", "change", "mute"], "additionalProperties": false]),
        ] + JasmineFinder.tools
    }

    /// What's on screen and playing, for the model: names and titles only (no accounts, addresses or keys).
    func jasmineState() -> String {
        var state: [String: Any] = ["screen": jasmineScreen]
        if case .player(let player) = jasminePlaying { state["playing"] = player.jasmineState }
        let volume = audioCoordinator.currentVolume
        if let level = volume.level { state["volume"] = level }
        if volume.muted { state["muted"] = true }
        if let waiting = jasmine.finder.state { state["waiting"] = waiting }
        state["time"] = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime])
        let data = (try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private var jasmineScreen: String {
        if let top = sheets.top { return top.remoteName }
        switch mode {
        case .movie: return "Videos (playing)"
        case .player(let service): return service.name
        case .launcher:
            if bilibiliOpen { return "哔哩哔哩" }
            if neteaseOpen { return "网易云音乐" }
            if dedaoOpen { return "得到" }
            if browserOpen { return "Web" }
            if movies != nil { return "Videos" }
            return "Home"
        }
    }

    /// A tool the model called: done, and what came of it, as JSON for the model.
    func performJasmine(_ call: ToolCall) -> String {
        func number(_ name: String) -> Double? { (call.arguments[name] as? NSNumber)?.doubleValue }
        func whole(_ name: String) -> Int? { number(name).flatMap { $0 == $0.rounded() ? Int(exactly: $0) : nil } }
        let command: JasmineCommand?
        switch call.name {
        case "open":
            switch call.arguments["target"] as? String {
            case "home": command = .home
            case "control_center": command = .controlCenter
            case "settings": command = .settings
            case let id?: command = jasmineApps.contains { $0.id == id } ? .open(id) : nil
            case nil: command = nil
            }
        case "control":
            let playback: JasmineCommand.Playback?
            switch call.arguments["action"] as? String {
            case "play": playback = .play
            case "pause": playback = .pause
            case "next": playback = .next
            case "previous": playback = .previous
            case "skip": playback = whole("seconds").flatMap { $0 == 0 ? nil : .skip($0) }
            case "seek": playback = whole("seconds").flatMap { $0 < 0 ? nil : .seek($0) }
            case "restart": playback = .seek(0)
            case "subtitles_on": playback = .subtitles(true)
            case "subtitles_off": playback = .subtitles(false)
            case "speed": playback = number("speed").flatMap { $0 > 0 ? .speed($0) : nil }
            default: playback = nil
            }
            command = playback.map { .playback($0) }
        case "volume":
            if let mute = call.arguments["mute"] as? Bool { command = .mute(mute) }
            else if let level = call.arguments["level"] as? Int { command = .volume(level) }
            else if let change = call.arguments["change"] as? Int { command = .volumeStep(change) }
            else { command = nil }
        default:
            command = nil
        }
        guard let failure = command == nil ? .notUnderstood : command.flatMap({ perform($0) }) else { return #"{"ok":true}"# }
        let data = (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": failure.reason], options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? #"{"ok":false}"#
    }

    /// Does it. Why not, when it wasn't done: nothing is playing, or what's playing can't.
    @discardableResult
    func perform(_ command: JasmineCommand) -> JasmineFailure? {
        switch command {
        case .open(let id):
            guard let service = services.first(where: { $0.id == id }) else { return .notUnderstood }
            open(service)
        case .home: goHome()
        case .controlCenter: if controlCenter == nil { handle(.controlCenter, from: .siriRemote) }
        case .settings: openSettings()
        case .playback(let request): return perform(request)
        case .volume(let level):
            audioCoordinator.setVolume(max(0, min(100, level)))
            audioCoordinator.refreshVolume()
            showVolume(audioCoordinator.currentVolume)
        case .volumeStep(let delta): handle(.volume(max(-100, min(100, delta))), from: .siriRemote)
        case .mute(let on):
            if audioCoordinator.currentVolume.muted != on { handle(.mute, from: .siriRemote) }
        case .standby: handle(.sleepNow, from: .siriRemote)
        }
        return nil
    }
}
