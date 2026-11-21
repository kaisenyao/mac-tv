import Foundation

/// What Jasmine can do in Mac TV, and what she's told about it. v1: open an app, control playback, the volume;
/// the commonest of these are understood here, without the model (LocalCommand).
enum JasmineCommand: Equatable {
    case open(String)          // a service id
    case home, controlCenter, settings
    case play, pause, playPause
    case skip(forward: Bool)
    case volume(Int), volumeStep(Int), mute(Bool)
    case standby
}

/// The short commands understood without the model (as PianaSoul's playback_commands): the whole of what was said,
/// in Chinese or English, or 打开 / open and an app's name. Anything else goes to the model.
enum LocalCommand {
    static func match(_ heard: String, apps: [(id: String, name: String)]) -> JasmineCommand? {
        let text = normalized(heard)
        guard !text.isEmpty else { return nil }
        let exact: [String: JasmineCommand] = [
            "暂停": .pause, "停": .pause, "停止": .pause, "暂停播放": .pause, "停止播放": .pause, "pause": .pause, "stop": .pause,
            "播放": .play, "播": .play, "继续": .play, "继续播放": .play, "接着放": .play, "play": .play, "resume": .play,
            "大点声": .volumeStep(10), "大声一点": .volumeStep(10), "声音大一点": .volumeStep(10), "调大音量": .volumeStep(10),
            "louder": .volumeStep(10), "volumeup": .volumeStep(10), "turnitup": .volumeStep(10),
            "小点声": .volumeStep(-10), "小声一点": .volumeStep(-10), "声音小一点": .volumeStep(-10), "调小音量": .volumeStep(-10),
            "quieter": .volumeStep(-10), "softer": .volumeStep(-10), "volumedown": .volumeStep(-10), "turnitdown": .volumeStep(-10),
            "静音": .mute(true), "mute": .mute(true), "取消静音": .mute(false), "unmute": .mute(false),
            "快进": .skip(forward: true), "快退": .skip(forward: false), "skipforward": .skip(forward: true), "skipback": .skip(forward: false),
            "回主屏": .home, "回到主屏": .home, "回主屏幕": .home, "回到主屏幕": .home, "主屏幕": .home, "gohome": .home, "home": .home,
            "控制中心": .controlCenter, "controlcenter": .controlCenter,
            "关屏幕": .standby, "关闭屏幕": .standby, "关电视": .standby, "待机": .standby,
            "turnoffthetv": .standby, "turnoffthescreen": .standby, "turnoffthedisplay": .standby,
        ]
        if let command = exact[text] { return command }
        for opener in ["打开", "开一下", "启动", "进入", "open", "launch", "goto"] where text.hasPrefix(opener) {
            let name = String(text.dropFirst(opener.count))
            if ["设置", "settings"].contains(name) { return .settings }
            if let id = app(named: name, in: apps) { return .open(id) }
        }
        return nil
    }

    /// Lowercase, without spaces, punctuation and a polite "please" / 请 / 帮我.
    static func normalized(_ text: String) -> String {
        var text = String(text.lowercased().unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0)
                && !CharacterSet.symbols.contains($0)
        })
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
            AssistantTool(name: "control", description: "Control what's playing: play, pause, or skip forward or back (the player's own step).",
                          parameters: ["type": "object", "properties": [
                            "action": ["type": "string", "enum": ["play", "pause", "skip_forward", "skip_back"]],
                          ], "required": ["action"], "additionalProperties": false]),
            AssistantTool(name: "volume", description: "The TV's volume: set a level (0–100), change it by an amount, or mute and unmute.",
                          parameters: ["type": "object", "properties": [
                            "level": ["type": ["integer", "null"], "minimum": 0, "maximum": 100],
                            "change": ["type": ["integer", "null"], "minimum": -100, "maximum": 100],
                            "mute": ["type": ["boolean", "null"]],
                          ], "required": ["level", "change", "mute"], "additionalProperties": false]),
        ]
    }

    /// What's on screen and playing, for the model: names and titles only (no accounts, addresses or keys).
    func jasmineState() -> String {
        var state: [String: Any] = ["screen": jasmineScreen]
        if let playing = jasminePlaying { state["playing"] = playing }
        let volume = audioCoordinator.currentVolume
        if let level = volume.level { state["volume"] = level }
        if volume.muted { state["muted"] = true }
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

    private var jasminePlaying: [String: Any]? {
        if let video = bilibiliStore.player.current, bilibiliStore.player.showing {
            return ["app": "哔哩哔哩", "title": video.title, "paused": bilibiliStore.player.paused]
        }
        if let song = neteaseStore.current {
            return ["app": "网易云音乐", "title": song.name, "artist": song.artist, "paused": neteaseStore.paused]
        }
        if let track = dedaoStore.player.current {
            return ["app": "得到", "title": track.title, "reader": track.reader, "paused": dedaoStore.player.paused]
        }
        if mode == .movie, let player = moviePlayer { return ["app": "Videos", "paused": !player.playing] }
        return nil
    }

    /// Paused, playing, or not known (a web page's video).
    private var jasminePaused: Bool? { jasminePlaying?["paused"] as? Bool }

    /// A tool the model called: done, and what came of it, as JSON for the model.
    func performJasmine(_ call: ToolCall) -> String {
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
            switch call.arguments["action"] as? String {
            case "play": command = .play
            case "pause": command = .pause
            case "skip_forward": command = .skip(forward: true)
            case "skip_back": command = .skip(forward: false)
            default: command = nil
            }
        case "volume":
            if let mute = call.arguments["mute"] as? Bool { command = .mute(mute) }
            else if let level = call.arguments["level"] as? Int { command = .volume(level) }
            else if let change = call.arguments["change"] as? Int { command = .volumeStep(change) }
            else { command = nil }
        default:
            command = nil
        }
        guard let command else { return #"{"ok":false,"error":"not understood"}"# }
        return perform(command) ? #"{"ok":true}"# : #"{"ok":false,"error":"nothing is playing"}"#
    }

    /// Does it, through the same commands the remotes send. False when there was nothing to do it to.
    @discardableResult
    func perform(_ command: JasmineCommand) -> Bool {
        switch command {
        case .open(let id):
            guard let service = services.first(where: { $0.id == id }) else { return false }
            open(service)
        case .home: goHome()
        case .controlCenter: if controlCenter == nil { handle(.controlCenter, from: .siriRemote) }
        case .settings: openSettings()
        case .play:
            guard jasminePaused != false else { return true }   // playing already
            guard jasminePlaying != nil || mode != .launcher else { return false }
            handle(.playPause, from: .siriRemote)
        case .pause:
            guard jasminePaused != true else { return true }    // paused already
            guard jasminePlaying != nil || mode != .launcher else { return false }
            handle(.playPause, from: .siriRemote)
        case .playPause: handle(.playPause, from: .siriRemote)
        case .skip(let forward):
            guard jasminePlaying != nil || mode != .launcher else { return false }
            handle(.seek(forward: forward), from: .siriRemote)
        case .volume(let level):
            audioCoordinator.setVolume(max(0, min(100, level)))
            audioCoordinator.refreshVolume()
            showVolume(audioCoordinator.currentVolume)
        case .volumeStep(let delta): handle(.volume(max(-100, min(100, delta))), from: .siriRemote)
        case .mute(let on):
            if audioCoordinator.currentVolume.muted != on { handle(.mute, from: .siriRemote) }
        case .standby: handle(.sleepNow, from: .siriRemote)
        }
        return true
    }
}
