import Foundation

/// 登录页右边嵌着的哔哩哔哩自己的登录表单（密码登录、短信登录、微信 / QQ / 微博……），以及注入给它的两段脚本。
/// 表单、人机验证、第三方登录都是哔哩哔哩自己的页面在做：我们只换样式（深色、大字、粉色）、
/// 让方向键能在里面走。密码只打进它自己的输入框，这边不读、不存、不记。
/// 视频播放不走网页：直接取流，用系统播放器播（见 BilibiliNativePlayer）。
enum BilibiliLoginPage {
    static let url = URL(string: "https://passport.bilibili.com/login")!
    /// 网页按 1920×1080 画布的多少倍显示（再乘上画布本身的缩放）：表单里 16px 的字在电视上约 26 点
    static let zoom: CGFloat = 1.6
    /// 登录表单的底色，和原生页面上右边那块的颜色一样（网页没铺满的地方看不出接缝）
    static let background = "#1A1A21"

    /// 在页面自己的脚本运行之前注入：让哔哩哔哩按中文浏览器对待我们。
    /// 系统语言是英文、或者人在海外时，它会把页面跳到机器翻译的英文版（/en/ 或 ?lang=en）。
    static let chinese = #"""
    (function () {
      try {
        Object.defineProperty(Navigator.prototype, 'language', { get: function () { return 'zh-CN'; } });
        Object.defineProperty(Navigator.prototype, 'languages', { get: function () { return ['zh-CN', 'zh']; } });
      } catch (e) {}
      // 万一还是被带到了英文版，回到原版；只试一次，避免来回跳
      try {
        var lang = new URLSearchParams(location.search).get('lang');
        if (/^\/en(\/|$)/.test(location.pathname) || (lang && !/^zh/i.test(lang))) {
          if (!sessionStorage.getItem('__tvNoEn')) {
            sessionStorage.setItem('__tvNoEn', '1');
            var query = new URLSearchParams(location.search);
            if (lang) query.set('lang', 'zh-Hans');
            var search = query.toString();
            location.replace(location.pathname.replace(/^\/en/, '') + (search ? '?' + search : '') + location.hash);
          }
        }
      } catch (e) {}
    })();
    """#

    /// 登录表单：换成深色、藏起它自己的二维码一栏（左边已经有原生的了）、页头页脚和语言切换。
    /// 再把能选中的东西（输入框、按钮、标签、第三方登录）的位置报给原生这边，方向键怎么走由原生决定（BiliLoginPage.next），
    /// 这里只负责把选中的那个高亮、让输入框拿到键盘、按确认时点它。
    /// 跑在单独的脚本世界里（和页面自己的脚本互不相见），只在 passport.bilibili.com 上起作用：
    /// 跳到微信、QQ 这些第三方页面时原样显示
    static let form = #"""
    (function () {
      if (location.hostname !== 'passport.bilibili.com' || window.__tvLogin) return;
      var css = `
    html, body, #app, #app-main { background: \#(background) !important; min-width: 0 !important; width: auto !important; margin: 0 !important; }
    body { overflow-x: hidden !important; color: #E9E9EF !important; }
    body, body div, body span, body p, body a, body input, body label { font-family: -apple-system, "PingFang SC", "Helvetica Neue", sans-serif !important; }
    #biliMainHeader, #biliMainFooter, .top-header, .bread-cut_wp, .lang-switch, .main__left, .main__middle-line { display: none !important; }
    .login_wp { width: auto !important; margin: 0 !important; padding: 24px 0 8px !important; }
    .login__main { display: block !important; width: auto !important; height: auto !important; margin: 0 !important; }
    .main__right { width: 402px !important; margin: 0 auto !important; padding: 0 !important; }
    .tabs_wp { margin-bottom: 24px !important; }
    .tabs_wp > div { color: rgba(255,255,255,.55) !important; font-size: 20px !important; line-height: 28px !important; border-radius: 999px; }
    .tabs_wp > div:empty { background: rgba(255,255,255,.2) !important; }
    .tabs_wp > .tab_active { color: #FB7299 !important; font-weight: 600; }
    .tab__form { border-color: rgba(255,255,255,.14) !important; background: rgba(255,255,255,.05) !important; }
    .form__item { color: #E9E9EF !important; font-size: 16px !important; border-radius: 8px; transition: none !important; }
    .form__item > div:first-child { color: #E9E9EF !important; font-size: 16px !important; white-space: nowrap !important; width: auto !important; min-width: 2em; }
    .form__item .clickable { white-space: nowrap !important; font-size: 15px !important; }
    .form__item input { background: transparent !important; color: #fff !important; font-size: 16px !important; caret-color: #FB7299; }
    .form__item input::placeholder { color: rgba(255,255,255,.36) !important; }
    .form__separator-line { border-color: rgba(255,255,255,.12) !important; background: rgba(255,255,255,.12) !important; }
    .clickable, .login-protocol a { color: #FB7299 !important; }
    .btn_wp { margin-top: 20px !important; }
    .btn_other, .btn_primary { font-size: 16px !important; height: 46px !important; line-height: 46px !important; transition: none !important; }
    .btn_other { background: rgba(255,255,255,.08) !important; border-color: rgba(255,255,255,.16) !important; color: #fff !important; }
    .btn_primary { background: #FB7299 !important; color: #fff !important; }
    .btn_primary.disabled { background: rgba(251,114,153,.32) !important; color: rgba(255,255,255,.6) !important; }
    .third-party-login-wrapper { margin-top: 26px !important; }
    .third-party-login-wrapper .title { color: rgba(255,255,255,.5) !important; font-size: 14px !important; }
    .sns__item { border-radius: 12px; padding: 6px 4px !important; }
    .sns__name { color: rgba(255,255,255,.8) !important; font-size: 14px !important; }
    .login-protocol { margin-top: 20px !important; }
    .login-protocol, .login-protocol p { color: rgba(255,255,255,.4) !important; font-size: 13px !important; line-height: 20px !important; }
    .forget-tip, .area-code-select, .dialog__outline { background: #26262F !important; color: #E9E9EF !important; border-color: rgba(255,255,255,.14) !important; }
    .forget-tip .title, .forget-tip .desc, .area-code-select .option, .dialog__body { color: #E9E9EF !important; }
    .area-code-select .option.checked { color: #FB7299 !important; }
    .body__captcha-input { background: transparent !important; color: #fff !important; border-color: rgba(255,255,255,.2) !important; }
    .tv-focus { outline: none !important; }
    .tabs_wp > div.tv-focus, .clickable.tv-focus, .tab-sms__cid.tv-focus, .area-code-select .option.tv-focus, .dialog__footer > div.tv-focus {
      background: #fff !important; color: #000 !important; box-shadow: 0 0 0 6px #fff; border-radius: 6px; }
    .btn_other.tv-focus, .btn_primary.tv-focus { background: #fff !important; color: #000 !important; transform: scale(1.04); box-shadow: 0 8px 22px rgba(0,0,0,.5); }
    .sns__item.tv-focus { background: #fff !important; }
    .sns__item.tv-focus .sns__name { color: #000 !important; }
    .form__item:has(input.tv-focus) { box-shadow: inset 0 0 0 3px #fff; background: rgba(255,255,255,.08); }
    `;
      // 页面自己的样式表是后来才加进来的：同样带 !important 时后来的赢，所以我们这一份一直挪到最后
      var style = document.createElement('style');
      style.textContent = css;
      function keepLast() {
        var parent = document.head || document.documentElement;
        if (style.parentNode !== parent || style.nextElementSibling) parent.appendChild(style);
      }
      keepLast();

      function post(message) { try { webkit.messageHandlers.tvLogin.postMessage(message); } catch (e) {} }
      var MAIN = '.tabs_wp > div:not(:empty), .main__right input, .main__right .clickable, .btn_other, .btn_primary, .sns__item, .tab-sms__cid';
      var items = [], current = null, lastItems = '', lastCaret = '', ready = false, timer = 0;

      function shown(el) {
        if (!el || !el.isConnected) return false;
        var r = el.getBoundingClientRect();
        if (r.width < 2 || r.height < 2) return false;
        if (el.checkVisibility) return el.checkVisibility({ visibilityProperty: true, opacityProperty: true });
        return el.offsetParent !== null;
      }
      function isInput(el) { return !!el && el.tagName === 'INPUT'; }
      // 弹出来的小窗（二次校验、区号列表）开着时，只在它里面走
      function scope() {
        var dialog = document.querySelector('.dialog__mask');
        if (shown(dialog)) return { root: dialog, sel: 'input, .dialog__footer > div' };
        var codes = document.querySelector('.area-code-select');
        if (shown(codes)) return { root: codes, sel: '.option' };
        return { root: document, sel: MAIN };
      }
      function captchaClose() { return Array.prototype.find.call(document.querySelectorAll('[class*="geetest_close"]'), shown); }
      function collect() {
        keepLast();
        var s = scope();
        items = Array.prototype.filter.call(s.root.querySelectorAll(s.sel), shown);
        if (current && items.indexOf(current) < 0) { current.classList.remove('tv-focus'); current = null; }
        var list = items.map(function (el) {
          var r = el.getBoundingClientRect();
          return [Math.round(r.left + scrollX), Math.round(r.top + scrollY), Math.round(r.width), Math.round(r.height), isInput(el) ? 1 : 0];
        });
        // 有没有弹出来的东西开着（返回键先收起它，见 back）
        var popup = s.root !== document || !!captchaClose();
        var text = JSON.stringify([list, items.indexOf(current), popup]);
        if (text !== lastItems) { lastItems = text; post({ type: 'items', items: list, focus: items.indexOf(current), popup: popup }); }
        if (!ready && document.querySelector('.main__right') && list.length) { ready = true; post({ type: 'ready' }); }
      }
      function later() { clearTimeout(timer); timer = setTimeout(collect, 120); }
      // 光标在输入框里时，往左 / 往右还挪不挪得动（只报这两个是非，不报框里的字）
      function caret() {
        var el = document.activeElement, left = false, right = false;
        if (isInput(el)) {
          try {
            var n = el.value.length, a = el.selectionStart, b = el.selectionEnd;
            left = !(a === 0 && b === 0);
            right = !(a === n && b === n);
          } catch (e) {}
        }
        var text = left + ',' + right;
        if (text !== lastCaret) { lastCaret = text; post({ type: 'caret', left: left, right: right }); }
      }
      function mark(el) {
        if (current && current !== el) current.classList.remove('tv-focus');
        current = el || null;
        if (current) current.classList.add('tv-focus');
      }
      window.__tvLogin = {
        focus: function (i) {
          var el = items[i];
          if (!el) return false;
          mark(el);
          if (isInput(el)) { el.focus(); } else if (isInput(document.activeElement)) { document.activeElement.blur(); }
          el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
          lastCaret = '';   // 原生那边换了一个就把记着的光标作废了：一定再报一次
          caret();
          return true;
        },
        leave: function () {
          mark(null);
          if (isInput(document.activeElement)) document.activeElement.blur();
          lastCaret = '';
          caret();
        },
        activate: function (i) {
          var el = items[i];
          if (!el) return 'none';
          if (isInput(el)) return 'input';
          el.click();
          later();
          return 'clicked';
        },
        // 返回键：先收起页面里弹出来的东西（二次校验、区号列表、人机验证），都没有才是离开登录页
        back: function () {
          var dialog = document.querySelector('.dialog__mask');
          if (shown(dialog)) { var cancel = dialog.querySelector('.dialog__footer > div'); if (cancel) { cancel.click(); later(); return 'handled'; } }
          if (shown(document.querySelector('.area-code-select'))) { var cid = document.querySelector('.tab-sms__cid'); if (cid) { cid.click(); later(); return 'handled'; } }
          var close = captchaClose();
          if (close) { close.click(); later(); return 'handled'; }
          later();
          return 'none';
        }
      };
      // 用鼠标、手机触控板点了表单里的某一个，或者按了 Tab：原生那边的焦点跟过来
      document.addEventListener('focusin', function (e) {
        if (items.indexOf(e.target) < 0) collect();
        var i = items.indexOf(e.target);
        if (i >= 0 && current !== e.target) { mark(e.target); post({ type: 'focus', index: i }); }
        caret();
      }, true);
      document.addEventListener('click', function (e) {
        if (!e.isTrusted) return;
        var i = items.findIndex(function (el) { return el.contains(e.target); });
        if (i >= 0 && current !== items[i]) { mark(items[i]); post({ type: 'focus', index: i }); }
        later();
      }, true);
      ['selectionchange', 'input', 'keyup'].forEach(function (name) { document.addEventListener(name, caret, true); });
      new MutationObserver(later).observe(document.documentElement, { subtree: true, childList: true, attributes: true, attributeFilter: ['class', 'style'] });
      addEventListener('resize', later);
      addEventListener('load', later);
      document.addEventListener('DOMContentLoaded', keepLast);
    })();
    """#
}
