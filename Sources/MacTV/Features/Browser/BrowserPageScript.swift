import WebKit

/// 浏览器网页里的一小段脚本（只在主框架里）：告诉 BrowserStore 视频是不是铺满了（铺满时标签栏收起），
/// 网页什么时候画出来了（换标签页时先铺的截图可以拿掉）。全靠事件，不轮询、不跟着每一帧跑；
/// 滚动时只有正在放视频才看一眼，一帧最多一次。
/// SpatialNav 在页面最上面再按上时，也是从这里（macTVBrowser）告诉标签栏。
///
/// 内嵌框架（iframe）的配色：WebKit 发现 <iframe> 这个元素的配色（跟着网页走，比如 chatgpt.com 的深色）
/// 和框架里那一页自己的配色（Google 登录卡片没写，就是浅色）对不上时，会在框架后面垫一块不透明的底，
/// 透明的圆角卡片四周就多出一个白框（Safari 里看不到）。所以每个框架载好时把自己的配色报上来（frameScheme，
/// 只发给 Mac TV，网页收不到），再把网页里指向这个网站的 <iframe> 的 color-scheme 明确设成一样的：对上了就不垫底，
/// 框架里那一页怎么画完全不变。
/// 一定要明确设上（!important），不能先猜 <iframe> 现在用的是哪种再决定设不设：chatgpt.com 的根是 "light dark"，
/// 那个 <iframe> 算出来是 "normal"，看起来是浅色、和 Google 的那一页对得上，WebKit 却按网页的深色来比，照样垫白底
/// （实测：设成 light 白框就没了，normal、dark、light dark 都还在）
enum BrowserPageScript {
    static let handlerName = "macTVBrowser"

    @MainActor
    static func install(in config: WKWebViewConfiguration, store: BrowserStore) {
        config.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.addUserScript(WKUserScript(source: frameSource, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        config.userContentController.add(Relay(store: store), name: handlerName)
    }

    /// 消息转给 BrowserStore。只拿弱引用（userContentController 一直留着它，别让它留住浏览器）。
    /// 主框架的给 BrowserStore；内嵌框架只报配色，这里直接对上
    private final class Relay: NSObject, WKScriptMessageHandler {
        weak var store: BrowserStore?
        init(store: BrowserStore) { self.store = store }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated {
                if message.frameInfo.isMainFrame {
                    store?.received(message.body, from: message.webView)
                } else if let body = message.body as? [String: Any], let scheme = body["frameScheme"] as? String,
                          let web = message.webView, let origin = BrowserPageScript.origin(message.frameInfo.securityOrigin) {
                    BrowserPageScript.match(scheme: scheme, origin: origin, in: web)
                }
            }
        }
    }

    /// "https://accounts.google.com"（端口是默认的就不写）
    @MainActor
    static func origin(_ origin: WKSecurityOrigin) -> String? {
        guard !origin.protocol.isEmpty, !origin.host.isEmpty else { return nil }
        return "\(origin.protocol)://\(origin.host)" + (origin.port == 0 ? "" : ":\(origin.port)")
    }

    /// 网页里指向这个网站的 <iframe>：color-scheme 明确设成和框架里那一页一样（!important：网页自己的样式盖不掉）
    @MainActor
    static func match(scheme: String, origin: String, in web: WKWebView) {
        guard scheme == "light" || scheme == "dark" else { return }
        web.callAsyncJavaScript(matchSource, arguments: ["scheme": scheme, "origin": origin], in: nil, in: .page, completionHandler: nil)
    }

    static let matchSource = #"""
    for (const frame of document.querySelectorAll('iframe')) {
      let from;
      try { from = new URL(frame.src || location.href, location.href).origin; } catch (_) { continue; }
      if (from !== origin) continue;
      if (frame.style.getPropertyValue('color-scheme') !== scheme || frame.style.getPropertyPriority('color-scheme') !== 'important')
        frame.style.setProperty('color-scheme', scheme, 'important');
    }
    """#

    /// 内嵌框架里：这一页自己用的是浅色还是深色（CSS 的 color-scheme，没写就看 <meta name="color-scheme">），载好时报一次
    static let frameSource = #"""
    (() => {
      if (window.top === window || window.__macTVFrameScheme) return;
      window.__macTVFrameScheme = true;
      const root = document.documentElement;
      if (!root) return;
      let declared = getComputedStyle(root).colorScheme || 'normal';
      if (declared === 'normal') {
        const meta = document.querySelector('meta[name="color-scheme"]');
        if (meta && meta.content) declared = meta.content;
      }
      const dark = /\bdark\b/.test(declared) && (!/\blight\b/.test(declared) || matchMedia('(prefers-color-scheme: dark)').matches);
      try { window.webkit.messageHandlers.macTVBrowser.postMessage({ frameScheme: dark ? 'dark' : 'light' }); } catch (_) {}
    })();
    """#

    static let source = #"""
    (() => {
      if (window.__macTVBrowserPage) return;
      window.__macTVBrowserPage = true;
      const post = m => { try { window.webkit.messageHandlers.macTVBrowser.postMessage(m); } catch (_) {} };

      // 网页画出来了：DOM 好了以后再等两帧
      const ready = () => requestAnimationFrame(() => requestAnimationFrame(() => post({ ready: true })));
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', ready, { once: true }); else ready();

      // 视频铺满了没有：网页自己进了全屏，或者一个有声音、正在放的视频露出来的部分占了画面的大半
      // （静音的背景视频不算）。进来要 85%，出去要掉到 70% 以下：标签栏收起、放出来时画面高度会变，不来回跳
      let filling = false, watched = null, pending = false;
      const resize = typeof ResizeObserver === 'function' ? new ResizeObserver(() => check()) : null;
      function shown(v) {
        const r = v.getBoundingClientRect();
        const w = Math.max(0, Math.min(r.right, innerWidth) - Math.max(r.left, 0));
        const h = Math.max(0, Math.min(r.bottom, innerHeight) - Math.max(r.top, 0));
        return w * h / Math.max(1, innerWidth * innerHeight);
      }
      function check() {
        pending = false;
        const full = document.fullscreenElement || document.webkitFullscreenElement;
        let playing = null, share = 0;
        for (const v of document.querySelectorAll('video')) {
          if (v.paused || v.ended || v.muted) continue;
          const s = shown(v);
          if (s > share) { share = s; playing = v; }
        }
        if (resize && playing !== watched) {
          if (watched) resize.unobserve(watched);
          if (playing) resize.observe(playing);
        }
        watched = playing;
        const now = !!full || (!!playing && share >= (filling ? 0.7 : 0.85));
        if (now !== filling) { filling = now; post({ video: now }); }
      }
      for (const type of ['play', 'playing', 'pause', 'ended', 'emptied', 'volumechange']) document.addEventListener(type, check, true);
      document.addEventListener('fullscreenchange', check);
      document.addEventListener('webkitfullscreenchange', check);
      addEventListener('resize', check);
      addEventListener('scroll', () => {
        if (!watched || pending) return;
        pending = true;
        requestAnimationFrame(check);
      }, { passive: true, capture: true });
      addEventListener('pagehide', () => { if (filling) { filling = false; post({ video: false }); } });
    })();
    """#
}
