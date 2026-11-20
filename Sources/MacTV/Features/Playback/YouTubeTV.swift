import Foundation

/// youtube.com/tv（YouTube 电视版）在 Mac TV 里的几处调整，只对 YouTube 生效
enum YouTubeTV {
    /// 打开 YouTube 用的地址。`force_startup_screen=none`：开机时不弹"谁在看"，直接用上次的账号进首页
    /// （想换人在 YouTube 左边栏换）。Mac TV 每次打开 YouTube 都是从头加载，YouTube 重新启动时离上次弹出
    /// 选择账号超过两个小时就会再弹一次；真电视上 YouTube 一直在后台不重启，所以很少见到。
    /// 这是 YouTube 自己认的调试参数，哪天不认了，就是又要选一次账号，不会出别的错
    static let home = URL(string: "https://www.youtube.com/tv?force_startup_screen=none")!

    /// 直接放某个视频（主屏顶部、手机"发到电视"）
    static func watch(_ id: String) -> URL? {
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return URL(string: "https://www.youtube.com/tv?force_startup_screen=none#/watch?v=\(id)")
    }

    /// 页面一开始就放进去的脚本：
    /// 1. 60 帧：YouTube 电视版会问浏览器"这个格式带 framerate=… 能不能放"，好判断能不能放 60 帧。
    ///    Mac 的网页内核不看 framerate 这一段，连 framerate=9999 都说能放；YouTube 一看答不准，就把所有
    ///    60 帧的格式都扔了——60 帧的视频只剩 30 帧的版本，最高 720p。这里照电视浏览器的样子答：
    ///    帧率高得离谱（超过 240）就说不能放，其余照原来的答案。
    /// 2. 底色：YouTube 电视版自己把界面画成一个居中的 16:9 框，框外是黑的；在 16:10 的屏幕（MacBook）上，
    ///    上下会多出两条黑边。框外的底色改成 YouTube 自己的深灰，黑边就融进去了（16:9 的电视上本来就没有黑边）；
    ///    视频本身的底还是黑的
    /// 3. 清晰度：电视版只列出"播放器大小 × 像素比"放得下的清晰度（宽要够 0.99 倍）。MacBook 16 寸全屏时 16:9 的
    ///    画面是 3456 像素宽，4K（3840）放不下，最高只给 1440p，要放大才铺满；网页版 YouTube 在同一台 Mac 上给 2160p。
    ///    这里只在屏幕介于两档之间时（16:9 的画面宽 1920–3840 像素之间），把告诉 YouTube 的像素比往上抬到正好够
    ///    下一档（2560 或 3840）：MacBook 16 寸 2 → 2.22，菜单里有 2160p，"自动"也从高档开始、网速不够照样往下降。
    ///    1080p、1440p、4K 的电视和显示器正好在档上，答案原样不变；画面本身照常按真实像素画，只是 YouTube 读到的数变了
    /// 4. 广告的"跳过"：YouTube 自己给出"跳过广告"按钮时（电视版里它出现时就是选中状态，按确定就跳过），
    ///    替人按一下确定，和自己按遥控器一样。只在播放器正在放广告时每半秒看一眼，平时只盯着播放器的 class 变化；
    ///    不拦广告、不藏广告、不碰广告请求。跟"跳过片头"用同一个开关（window.__mactvAuto.skip，见 AutoPlay），关了就不按
    static let script = """
    (() => {
      const MS = window.MediaSource;
      if (MS && MS.isTypeSupported && !MS.__macTVFramerate) {
        const original = MS.isTypeSupported.bind(MS);
        MS.isTypeSupported = function (type) {
          const m = /;\\s*framerate=([0-9.]+)/i.exec(String(type));
          if (m && Number(m[1]) > 240) return false;
          return original(type);
        };
        MS.__macTVFramerate = true;
      }
      const ratio = Object.getOwnPropertyDescriptor(window, 'devicePixelRatio');
      if (ratio && ratio.get && ratio.configurable && !window.__macTVPixelRatio) {
        window.__macTVPixelRatio = true;
        Object.defineProperty(window, 'devicePixelRatio', {
          configurable: true, enumerable: ratio.enumerable,
          get() {
            const real = ratio.get.call(window);
            const wide = Math.min(screen.width, screen.height * 16 / 9) * real;
            if (!(wide > 1920) || wide >= 3840) return real;
            return real * (wide > 2560 ? 3840 : 2560) / wide;
          }
        });
      }
      const style = document.createElement('style');
      style.textContent = 'html, body { background-color: #0f0f0f !important; } video { background-color: #000; }';
      (document.head || document.documentElement).appendChild(style);
      if (!window.__macTVAdSkip) {
        window.__macTVAdSkip = true;
        const pressSkip = () => {
          if (!(window.__mactvAuto && window.__mactvAuto.skip)) return;
          const button = document.querySelector('ytlr-skip-button-renderer');
          if (!button || !button.getBoundingClientRect().width) return;
          const target = button.contains(document.activeElement) ? document.activeElement
            : button.classList.contains('zylon-focus') ? button : button.querySelector('.zylon-focus');
          if (!target) return;
          for (const type of ['keydown', 'keyup'])
            target.dispatchEvent(new KeyboardEvent(type, { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true }));
        };
        let timer = null;
        const watch = player => {
          const check = () => {
            const ad = player.classList.contains('ad-showing');
            if (ad && !timer) timer = setInterval(pressSkip, 500);
            else if (!ad && timer) { clearInterval(timer); timer = null; }
          };
          new MutationObserver(check).observe(player, { attributes: true, attributeFilter: ['class'] });
          check();
        };
        let tries = 0;
        const find = setInterval(() => {
          const player = document.querySelector('.html5-video-player');
          if (player) watch(player);
          if (player || ++tries > 150) clearInterval(find);
        }, 2000);
      }
    })();
    """
}
