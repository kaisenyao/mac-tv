/// Presses the players' own "Skip Intro", "Skip Recap" and "Next Episode" buttons when they
/// appear (streaming sites label them plainly): only the exact phrases below count.
/// 同一个开关也管 YouTube 的"Skip ad"：YouTube 自己给出跳过按钮时帮你按一下（见 YouTubeTV.script），
/// 别的网站的广告按钮不碰。
enum AutoPlay {
    static func script(skip: Bool, next: Bool) -> String {
        "window.__mactvAuto = { skip: \(skip), next: \(next) };\n" + body
    }

    private static let body = #"""
    (() => {
      if (window.__mactvAutoInstalled) return;
      window.__mactvAutoInstalled = true;
      const settings = window.__mactvAuto || {};
      if (!settings.skip && !settings.next) return;

      const SKIP_LABEL = /\bskip\s+(the\s+)?(intro|introduction|recap|opening|opening credits|credits|summary)\b/i;
      const NEXT_LABEL = /^(next episode|play next episode|watch next episode)$/i;
      const pressed = new WeakSet();

      setInterval(() => {
        const candidates = document.querySelectorAll('button, [role="button"]');
        for (const el of candidates) {
          if (pressed.has(el)) continue;
          const box = el.getBoundingClientRect();
          if (!box.width || !box.height) continue;
          const label = (el.getAttribute('aria-label') || el.textContent || '').replace(/\s+/g, ' ').trim();
          if (label.length > 40) continue;
          const isSkip = SKIP_LABEL.test(label);
          const isNext = NEXT_LABEL.test(label);
          if ((isSkip && settings.skip) || (isNext && settings.next)) {
            pressed.add(el);
            el.click();
          }
        }
      }, 1000);
    })();
    """#
}
