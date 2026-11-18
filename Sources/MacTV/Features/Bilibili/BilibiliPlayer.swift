import Foundation

/// 哔哩哔哩的登录页是网页（扫码登录），这是注入给它的唯一一段脚本。
/// 视频播放不走网页：直接取流，用系统播放器播（见 BilibiliNativePlayer）。
enum BilibiliLoginPage {
    /// 在页面自己的脚本运行之前注入：让哔哩哔哩按中文浏览器对待我们。
    /// 系统语言是英文、或者人在海外时，它会把页面跳到机器翻译的英文版（/en/）。
    static let chinese = #"""
    (function () {
      try {
        Object.defineProperty(Navigator.prototype, 'language', { get: function () { return 'zh-CN'; } });
        Object.defineProperty(Navigator.prototype, 'languages', { get: function () { return ['zh-CN', 'zh']; } });
      } catch (e) {}
      // 万一还是被带到了英文版，回到原版；只试一次，避免来回跳
      if (/^\/en(\/|$)/.test(location.pathname)) {
        try {
          if (!sessionStorage.getItem('__tvNoEn')) {
            sessionStorage.setItem('__tvNoEn', '1');
            location.replace(location.pathname.replace(/^\/en/, '') + location.search);
          }
        } catch (e) {}
      }
    })();
    """#
}
