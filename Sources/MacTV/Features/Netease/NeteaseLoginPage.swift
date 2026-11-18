import AppKit
import WebKit

/// 在后台加载网易云官方网页的登录框，把它生成的二维码原样取出来给我们自己的界面显示。
/// 登录这件事全程是官方网页自己在做（它带着网易云风控要的东西），这里只是"看"它的二维码；
/// 你扫码确认后，登录状态落在这个应用自己的网页数据里。
@MainActor
final class NeteaseLoginPage: NSObject, WKScriptMessageHandler {
    private var webView: WKWebView?
    /// 取到了新的二维码图
    var onImage: ((NSImage) -> Void)?
    /// 官方页查询扫码状态的结果：802 = 已扫码等确认
    var onState: ((Int) -> Void)?

    private static let script = """
    (function(){
      if (window.top !== window) return;
      var post = function(o){ try { webkit.messageHandlers.netease.postMessage(o) } catch(e) {} };
      var open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(m, u){ this.__u = String(u); return open.apply(this, arguments) };
      XMLHttpRequest.prototype.send = function(){
        var x = this;
        x.addEventListener('load', function(){ try {
          if (x.__u.indexOf('login/qrcode/client/login') >= 0) post({state: JSON.parse(x.responseText).code});
        } catch(e) {} });
        return send.apply(this, arguments);
      };
      var sent = null, clicked = 0;
      setInterval(function(){
        var modal = document.querySelector('.mrc-modal-wrapper');
        if (!modal) {
          var a = document.querySelector('a[data-action=login]');
          if (a && Date.now() - clicked > 300) { clicked = Date.now(); a.click(); }
          return;
        }
        var all = modal.querySelectorAll('*');
        for (var k = 0; k < all.length; k++) {
          if (all[k].children.length === 0 && all[k].textContent.trim() === '点击刷新') { all[k].click(); return; }
        }
        var data = null, c = modal.querySelectorAll('canvas'), i = modal.querySelectorAll('img');
        for (var n = 0; n < c.length; n++) {
          if (c[n].width >= 100 && Math.abs(c[n].width - c[n].height) < 4) { try { data = c[n].toDataURL('image/png') } catch(e) {} }
        }
        if (!data) for (var j = 0; j < i.length; j++) {
          if (i[j].naturalWidth >= 100 && Math.abs(i[j].naturalWidth - i[j].naturalHeight) < 4) data = i[j].src;
        }
        if (data && data !== sent) { sent = data; post({image: data}); }
      }, 100);
    })();
    """

    func start(store: WKWebsiteDataStore, in window: NSWindow?) {
        stop()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        config.userContentController.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.add(self, name: "netease")
        // 放在窗口里看不见的地方：不在窗口里的网页，系统会让它"省电"，二维码出得慢
        let view = WKWebView(frame: NSRect(x: -4000, y: -4000, width: 1280, height: 800), configuration: config)
        view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
        window?.contentView?.addSubview(view, positioned: .below, relativeTo: nil)
        view.load(URLRequest(url: URL(string: "https://music.163.com/#/login")!))
        webView = view
    }

    func stop() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "netease")
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if let state = body["state"] as? Int { onState?(state) }
        guard let text = body["image"] as? String else { return }
        if text.hasPrefix("data:"), let comma = text.firstIndex(of: ","),
           let data = Data(base64Encoded: String(text[text.index(after: comma)...])), let image = NSImage(data: data) {
            onImage?(image)
        } else if let url = URL(string: text), url.scheme?.hasPrefix("http") == true {
            Task { @MainActor [weak self] in
                guard let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) else { return }
                self?.onImage?(image)
            }
        }
    }
}
