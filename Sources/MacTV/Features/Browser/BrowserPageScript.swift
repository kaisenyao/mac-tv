import WebKit

/// 浏览器网页里的一小段脚本（只在主框架里）：告诉 BrowserStore 视频是不是铺满了（铺满时标签栏收起），
/// 网页什么时候画出来了（换标签页时先铺的截图可以拿掉）。全靠事件，不轮询、不跟着每一帧跑；
/// 滚动时只有正在放视频才看一眼，一帧最多一次。
/// SpatialNav 在页面最上面再按上时，也是从这里（macTVBrowser）告诉标签栏
enum BrowserPageScript {
    static let handlerName = "macTVBrowser"

    @MainActor
    static func install(in config: WKWebViewConfiguration, store: BrowserStore) {
        config.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.add(Relay(store: store), name: handlerName)
    }

    /// 消息转给 BrowserStore。只拿弱引用（userContentController 一直留着它，别让它留住浏览器）；只听主框架的
    private final class Relay: NSObject, WKScriptMessageHandler {
        weak var store: BrowserStore?
        init(store: BrowserStore) { self.store = store }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated {
                guard message.frameInfo.isMainFrame else { return }
                store?.received(message.body, from: message.webView)
            }
        }
    }

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
