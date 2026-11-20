import Foundation

/// A press from any remote: the phone, the keyboard, a game controller or the mouse.
enum RemoteCommand {
    enum Direction: String { case up, down, left, right }

    /// home: a press of the TV button (the Home Screen; twice, the App Switcher). goHome: Back held, the Home Screen
    /// from anywhere, which isn't a TV press (it doesn't count toward a double press)
    case move(Direction), select, back, home, goHome
    /// The Power button: pressed, it wakes from TV standby (awake, nothing); held, TV standby
    case power(hold: Bool)
    /// 按住确认（旧版手机页的 okhold）：卡片菜单 / 看视频时右边的面板
    case longSelect
    /// 一个键：点了一下 / 按住了 / 还按着 / 松开了（手机、Siri Remote、键盘、手柄都一样，见 PhonePresses）
    case press(PhonePresses.Key, PhonePresses.Phase)
    case playPause, seek(forward: Bool)
    /// 手机遥控器的转盘转了一格：+1 顺时针，-1 逆时针
    case wheel(Int)
    case volume(Int), mute
    case text(String), deleteBackward
    case pointer(dx: Double, dy: Double), click, scroll(dy: Double)
    /// A light tap on the Siri Remote's clickpad, without pressing it (the screen saver's information)
    case touchTap
    /// 手机触控板上一根手指按住不动：和鼠标按住一样（长按出菜单）
    case pointerHold
    /// 手机触控板上的双指滑动：和 Mac 触控板上滑一样（见 TrackpadGestures）。
    /// focusFollowsFinger：遥控器式的滑动（手机的点按区、Siri Remote），焦点跟着手指走；触控板式的是 false
    case swipe(dx: Double, dy: Double, phase: String, focusFollowsFinger: Bool = false)
    case launch(String), openInBrowser
    /// TV standby (the phone's Settings › Sleep Now, as Control Center's). Mac TV never sleeps the whole Mac: it's
    /// also a server
    case sleepNow
    case sleepTimer(minutes: Int)
    case controlCenter
    case nextControl, previousControl, activateBrowser, browserFullscreen, retryBrowser
    case setting(String, Bool)
    /// 手机遥控器上的一个快捷键（见 RemoteShortcuts）：在这里不能用、现在什么都做不了的不理
    case shortcut(String)
    /// The Siri button, from any input: down, then a tap, or a hold and its release (see Jasmine)
    case siri(SiriPhase)

    init?(json: [String: Any]) {
        guard let action = json["a"] as? String else { return nil }
        switch action {
        case "up", "down", "left", "right": self = .move(Direction(rawValue: action)!)
        case "ok": self = .select
        case "okhold": self = .longSelect
        case "press":
            guard let key = (json["k"] as? String).flatMap(PhonePresses.Key.init(rawValue:)),
                  let phase = (json["p"] as? String).flatMap(PhonePresses.Phase.init(rawValue:)) else { return nil }
            self = .press(key, phase)
        case "back": self = .back
        case "home": self = .home
        case "playpause": self = .playPause
        // 转盘：手机那边把还没送到的格数攒在一起送（转得快也不丢格），这里收到几格就走几格
        case "wheel":
            let steps = max(-16, min(16, json["d"] as? Int ?? 1))
            guard steps != 0 else { return nil }
            self = .wheel(steps)
        case "volup": self = .volume(6)
        case "voldown": self = .volume(-6)
        case "mute": self = .mute
        case "text":
            guard let text = json["t"] as? String, !text.isEmpty else { return nil }
            self = .text(String(text.prefix(500)))
        case "backspace": self = .deleteBackward
        case "pointer": self = .pointer(dx: json["dx"] as? Double ?? 0, dy: json["dy"] as? Double ?? 0)
        case "click": self = .click
        case "scroll": self = .scroll(dy: json["dy"] as? Double ?? 0)
        case "mousehold": self = .pointerHold
        case "swipe":
            guard let phase = json["p"] as? String, ["began", "changed", "ended", "momentum", "momentumEnd"].contains(phase) else { return nil }
            let clamp = { (v: Double) in max(-2000, min(2000, v.isFinite ? v : 0)) }
            // 点按区上的滑动带着 "focus": true（焦点跟着手指走），触控板上的双指滑动不带
            self = .swipe(dx: clamp(json["dx"] as? Double ?? 0), dy: clamp(json["dy"] as? Double ?? 0), phase: phase,
                          focusFollowsFinger: json["focus"] as? Bool ?? false)
        case "launch":
            guard let id = json["id"] as? String else { return nil }
            self = .launch(id)
        case "browser": self = .openInBrowser
        case "sleep": self = .sleepNow
        case "sleeptimer": self = .sleepTimer(minutes: json["m"] as? Int ?? 0)
        case "controlcenter": self = .controlCenter
        case "nextcontrol": self = .nextControl
        case "previouscontrol": self = .previousControl
        case "activatebrowser": self = .activateBrowser
        case "browserfullscreen": self = .browserFullscreen
        case "retrybrowser": self = .retryBrowser
        case "setting":
            guard let key = json["k"] as? String, let value = json["v"] as? Bool else { return nil }
            self = .setting(key, value)
        case "siri":
            guard let phase = (json["p"] as? String).flatMap(SiriPhase.init(rawValue:)) else { return nil }
            self = .siri(phase)
        case "shortcut":
            guard let id = json["id"] as? String, !id.isEmpty, id.count <= 64 else { return nil }
            self = .shortcut(id)
        default: return nil
        }
    }
}
