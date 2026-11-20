import AVFoundation
import WebKit

/// Mac TV 自己放的声音的音量：系统和显示器都调不了这个输出的音量时（多数电视的 HDMI、不回 DDC 的显示器、
/// 固定音量的声卡），音量键调的是它。一个全应用的音量，乘在每个原生播放器（哔哩哔哩、网易云音乐、得到、影片）
/// 和每个网页里的 <video>、<audio> 上（网页自己的音量照旧，网页看到的也还是它自己设的那个）。
/// 只在这种输出上起作用；换到系统能调的输出（内建扬声器、AirPods…）就回到原样。
/// 音量按输出记着（下次开、换回来还是这么大），静音不记
@MainActor
final class PlaybackVolume {
    static let shared = PlaybackVolume()

    private let defaults: UserDefaults
    private static let levelsKey = "fixedOutputVolume"
    /// 各个输出（CoreAudio 的 UID）记着的音量，0–100
    private var levels: [String: Int]
    /// 现在用 Mac TV 自己的音量的输出；nil = 不用（原样放）
    private(set) var output: String?
    private(set) var muted = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        levels = defaults.dictionary(forKey: Self.levelsKey) as? [String: Int] ?? [:]
    }

    var level: Int { output.flatMap { levels[$0] } ?? 100 }
    var volume: VolumeLevel { VolumeLevel(level: level, muted: muted) }

    /// 现在乘到播放器音量上的倍数
    var gain: Float { output == nil ? 1 : muted ? 0 : Self.gain(for: level) }

    /// 0–100 → 播放器音量。按三次方：听起来一格差不多一样多（直接按比例，上半截几乎听不出变化）
    static func gain(for level: Int) -> Float {
        let fraction = Float(max(0, min(100, level))) / 100
        return fraction * fraction * fraction
    }

    // MARK: 用不用、调多大

    /// 这个输出用 Mac TV 自己的音量（nil = 不用）
    func use(_ output: String?) {
        guard output != self.output else { return }
        self.output = output
        muted = false
        applyGain()
    }

    /// 这个输出以前用过 Mac TV 自己的音量才接着用（还不知道它的显示器回不回 DDC 时）
    func useIfRemembered(_ output: String) {
        use(levels[output] != nil ? output : nil)
    }

    /// 这个输出的显示器自己能调了：不再记它
    func forget(_ output: String) {
        if levels.removeValue(forKey: output) != nil { defaults.set(levels, forKey: Self.levelsKey) }
        if self.output == output { use(nil) }
    }

    func perform(_ action: VolumeAction) {
        guard let output else { return }
        var level = self.level
        switch action {
        case .step(let delta):
            if delta > 0 { muted = false }
            level = max(0, min(100, level + delta))
        case .set(let value):
            level = max(0, min(100, value))
            muted = false
        case .toggleMute:
            muted.toggle()
        case .refresh:
            return
        }
        if levels[output] != level {
            levels[output] = level
            defaults.set(levels, forKey: Self.levelsKey)
        }
        applyGain()
    }

    // MARK: 播放器

    /// 一个播放器和它自己要的音量（网易云的平衡音量、得到的淡出）
    private struct Target {
        weak var object: AnyObject?
        var base: Float
        let apply: @MainActor (AnyObject, Float) -> Void
    }
    private var targets: [ObjectIdentifier: Target] = [:]
    private var webViews: [WeakWebView] = []
    private var pushedGain: Float = 1

    /// 交给它管的播放器（建好时接上）
    static func attached(_ player: AVPlayer) -> AVPlayer {
        shared.set(player, base: 1)
        return player
    }

    /// 播放器自己要的音量（0–1），实际放的是它乘上 Mac TV 的音量
    func set(_ player: AVPlayer, base: Float) {
        add(player, base: base) { ($0 as? AVPlayer)?.volume = $1 }
    }

    /// MKV 的声音不经 AVPlayer，是它自己的渲染器
    func attach(_ renderer: AVSampleBufferAudioRenderer) {
        add(renderer, base: 1) { ($0 as? AVSampleBufferAudioRenderer)?.volume = $1 }
    }

    private func add(_ object: AnyObject, base: Float, apply: @escaping @MainActor (AnyObject, Float) -> Void) {
        targets = targets.filter { $0.value.object != nil }   // 放完的影片
        targets[ObjectIdentifier(object)] = Target(object: object, base: base, apply: apply)
        apply(object, base * gain)
    }

    private func applyGain() {
        let gain = gain
        targets = targets.filter { $0.value.object != nil }
        for target in targets.values {
            if let object = target.object { target.apply(object, target.base * gain) }
        }
        guard gain != pushedGain else { return }
        pushedGain = gain
        webViews.removeAll { $0.web == nil }
        let script = "window.__macTVVolume && window.__macTVVolume(\(gain))"
        for box in webViews { box.web?.evaluateJavaScript(script, completionHandler: nil) }
    }

    // MARK: 网页

    private struct WeakWebView {
        weak var web: WKWebView?
    }

    static let handlerName = "macTVVolume"

    /// 网页播放用的每个 WKWebView 建好时接上（加载之前）：脚本放进每个框架，音量变了推过去
    func install(in web: WKWebView) {
        let controller = web.configuration.userContentController
        let start = String(describing: gain)
        controller.addUserScript(WKUserScript(source: Self.script.replacingOccurrences(of: "__MACTV_GAIN__", with: start),
                                              injectionTime: .atDocumentStart, forMainFrameOnly: false))
        controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: .page)
        controller.addScriptMessageHandler(Relay(volume: self), contentWorld: .page, name: Self.handlerName)
        register(web)
    }

    private func register(_ web: WKWebView?) {
        webViews.removeAll { $0.web == nil }
        guard let web, !webViews.contains(where: { $0.web === web }) else { return }
        webViews.append(WeakWebView(web: web))
    }

    /// 页面（每个框架）一开始问现在的音量：建网页之后改过的、换了页面的、后来加的框架都对得上。
    /// 弹出来的小窗口（登录）用的是同一份脚本，问的时候也记下来
    /// 只拿弱引用：userContentController 一直留着它
    private final class Relay: NSObject, WKScriptMessageHandlerWithReply {
        weak var volume: PlaybackVolume?
        init(volume: PlaybackVolume) { self.volume = volume }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
            volume?.register(message.webView)
            replyHandler(Double(volume?.gain ?? 1), nil)
        }
    }

    /// 网页里的音量：把 HTMLMediaElement 的 volume 换成"网页自己设的 × Mac TV 的音量"。网页读到的还是它自己设的，
    /// 所以网站自己的音量条、记住的音量都不受影响。放过的元素都记着（不在页面里的 new Audio() 也算），
    /// 音量变了一起改，再传给子框架。全靠事件，不轮询
    static let script = #"""
    (() => {
      if (window.__macTVVolume) return;
      const proto = HTMLMediaElement.prototype;
      const native = Object.getOwnPropertyDescriptor(proto, 'volume');
      if (!native || !native.get || !native.set) return;
      let gain = __MACTV_GAIN__;
      const own = new WeakMap();
      const known = new WeakSet();
      const played = new Set();
      const apply = el => { try { native.set.call(el, (own.has(el) ? own.get(el) : 1) * gain); } catch (_) {} };
      const track = el => {
        if (!known.has(el)) { known.add(el); played.add(new WeakRef(el)); }
        apply(el);
      };
      Object.defineProperty(proto, 'volume', {
        configurable: true,
        enumerable: native.enumerable,
        get() { return own.has(this) ? own.get(this) : 1; },
        set(value) {
          const v = Number(value);
          if (!Number.isFinite(v)) throw new TypeError('The provided double value is non-finite.');
          if (v < 0 || v > 1) throw new DOMException('The volume provided (' + v + ') is outside the range [0, 1].', 'IndexSizeError');
          own.set(this, v);
          track(this);
        },
      });
      const play = proto.play;
      proto.play = function () { track(this); return play.apply(this, arguments); };
      for (const type of ['loadstart', 'play']) {
        document.addEventListener(type, e => { if (e.target instanceof HTMLMediaElement) track(e.target); }, true);
      }
      const set = value => {
        if (typeof value !== 'number' || !(value >= 0 && value <= 1)) return;
        gain = value;
        for (const ref of played) { const el = ref.deref(); if (el) apply(el); else played.delete(ref); }
        for (const el of document.querySelectorAll('video, audio')) apply(el);
        for (let i = 0; i < window.frames.length; i++) {
          try { window.frames[i].postMessage({ macTVVolume: value }, '*'); } catch (_) {}
        }
      };
      Object.defineProperty(window, '__macTVVolume', { value: set });
      if (window.parent !== window) {
        window.addEventListener('message', e => {
          if (e.source === window.parent && e.data && typeof e.data.macTVVolume === 'number') set(e.data.macTVVolume);
        });
      }
      try { window.webkit.messageHandlers.macTVVolume.postMessage(null).then(set, () => {}); } catch (_) {}
    })();
    """#
}
