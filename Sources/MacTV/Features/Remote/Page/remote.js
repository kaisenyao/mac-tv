const $ = s => document.querySelector(s);
const $$ = s => [...document.querySelectorAll(s)];

// 每按一下，手机给一下震动；手机不出声，声音从电视出（和 Apple TV 的遥控器一样）。一下只震一次，不多也不漏：
// iPhone：网页里唯一的震动是系统开关（<input type=checkbox switch>）切换时那一下。iOS 26.5 起只有手指真的点在开关上
// 才震（脚本去点它不震了），所以每个能按的东西里都盖着一个看不见的开关（见 addNativeHaptic）：手指点完抬起、
// 这一下生效的时候，系统切换它、震一下。按着不放、滑走了不算点了一下，也就不震。
// Android：navigator.vibrate。画出来的键在手指按下的那一刻震（像真的键），弹出页里的按钮点完时震；按住生效、
// 转盘走一格、按住连发时再轻轻一下。
const isIOS = /iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
const vibrates = typeof navigator.vibrate === 'function';
let nativeTouch = false;   // 这一下按在盖着开关的东西上：iPhone 自己会震，脚本不再震
const haptic = (() => {
  const patterns = { press: 22, hold: 14, tick: 8, error: [22, 60, 22] };
  // 旧一点的 iOS 上脚本点开关也能震：留给没有开关盖着的时候（比如出错）
  let fallback = null;
  if (!vibrates && isIOS) {
    fallback = document.createElement('label');
    fallback.style.display = 'none';
    const input = document.createElement('input');
    input.type = 'checkbox';
    input.setAttribute('switch', '');
    fallback.appendChild(input);
    document.body.appendChild(fallback);
  }
  return kind => {
    const pattern = patterns[kind];
    if (pattern === undefined) return;
    try {
      if (vibrates) navigator.vibrate(pattern);
      else if (fallback && !nativeTouch) {
        fallback.click();
        if (kind === 'error') setTimeout(() => fallback.click(), 140);
      }
    } catch {}
  };
})();

// 盖在一个键上的看不见的系统开关（和 PianaSoul 的 iPod 一样）。点在它上面的这一下由它接走，按钮自己的 click
// 照常冒泡上去；只有提交表单这件事要替按钮做（那一下的"激活"算在开关的 label 上了）
function addNativeHaptic(el) {
  const label = document.createElement('label');
  label.setAttribute('aria-hidden', 'true');
  label.className = 'haptic';
  const input = document.createElement('input');
  input.type = 'checkbox';
  input.setAttribute('switch', '');
  input.tabIndex = -1;
  input.addEventListener('click', e => e.stopPropagation());
  label.append(input);
  if (el.type === 'submit') label.addEventListener('click', () => el.form?.requestSubmit(el));
  el.append(label);
  el.dataset.nativeHaptic = '';
}
// iPhone 上每个按钮都盖一个（后来生成的按钮、改了字的按钮也补上）；转盘和触控板各盖一整块
if (isIOS) {
  const feel = node => {
    if (!(node instanceof Element)) return;
    const buttons = node.matches('button') ? [node] : [...node.querySelectorAll('button')];
    for (const b of buttons) if (!b.closest('#clickpad') && !b.querySelector(':scope > .haptic')) addNativeHaptic(b);
  };
  addNativeHaptic($('#clickpad .ring'));
  addNativeHaptic($('#touchpad'));
  feel(document.body);
  new MutationObserver(records => records.forEach(r => {
    const owner = r.target.closest?.('button');
    if (owner) feel(owner);
    r.addedNodes.forEach(feel);
  })).observe(document.body, { childList: true, subtree: true });
}
document.addEventListener('pointerdown', e => { nativeTouch = !!e.target.closest?.('[data-native-haptic]'); }, { capture: true });

// 换一个键的样子：里面 data-state 等于 state 的那一套显示出来，别的藏起来（'normal' 是平时的样子）
function showArt(art, state = 'normal') {
  for (const part of art.querySelectorAll('[data-state]')) part.setAttribute('display', part.dataset.state === state ? 'inline' : 'none');
}
// 手指按着的键：手指离开、被系统收走、页面切走时换回来。按下的样子正好显示手指按着的这么久
const fingersDown = new Map();
// tapped：手指是点完抬起的（pointerup），不是被系统收走（开始滚动了）或别的原因放开
function letGo(pointerId, tapped = false) {
  const up = fingersDown.get(pointerId);
  if (up) { fingersDown.delete(pointerId); up(tapped); }
}
['pointerup', 'pointercancel'].forEach(t => window.addEventListener(t, e => letGo(e.pointerId, e.type === 'pointerup'), true));
const letGoAll = () => [...fingersDown.keys()].forEach(id => letGo(id));
window.addEventListener('blur', letGoAll);
document.addEventListener('visibilitychange', () => { if (document.hidden) letGoAll(); });

// 每个按钮按下的那一刻：画出来的键换成按下的样子（影子收起来）、震一下；弹出页里的按钮暗一点或缩一点，
// 点完时震。切换条、转盘和触控板自己管（它们按在哪儿、怎么动样子不一样）
const ownTouch = b => b.closest('.mode, #clickpad');
document.addEventListener('pointerdown', e => {
  const b = e.target.closest('button');
  // 按了一个键（返回、主屏、音量……）：滑完的惯性停下，不会接着甩到按完以后的界面上（和 Siri Remote 一样；swipe 见下面的"滑动"）
  if (b) swipe.stop();
  if (!b || b.disabled || ownTouch(b)) return;
  const art = b.classList.contains('drawn') ? b.querySelector('.art') : null;
  // 弹出页里能上下滚：等 70 毫秒再亮，手指是来滚动的（系统收走了这一下）就不亮；没等到就点完的，抬手时亮一下再淡掉
  // （像 iOS 的列表）
  let wait = 0;
  if (art) { showArt(art, 'pressed'); b.classList.add('down'); haptic('press'); }
  else if (b.closest('.sheet')) wait = setTimeout(() => { wait = 0; b.classList.add('pressed'); }, 70);
  else b.classList.add('pressed');
  letGo(e.pointerId);
  fingersDown.set(e.pointerId, tapped => {
    if (art) { showArt(art); b.classList.remove('down'); return; }
    if (wait) {
      clearTimeout(wait); wait = 0;
      if (!tapped) return;
      b.classList.add('pressed');
      getComputedStyle(b).opacity;   // 先让按下的样子生效，去掉时才会淡出来
    }
    b.classList.remove('pressed');
  });
});
document.addEventListener('click', e => {
  const b = e.target.closest('button');
  if (b && e.detail && !b.disabled && !b.classList.contains('drawn') && !ownTouch(b)) haptic('press');
}, true);

const store = {
  get() { try { return localStorage.getItem('mactvKey') || localStorage.getItem('matineeKey') || localStorage.getItem('couchKey') || ''; } catch { return ''; } },
  set(v) {
    for (const old of ['matineeKey', 'couchKey']) { try { localStorage.removeItem(old); } catch {} }
    try { localStorage.setItem('mactvKey', v); } catch {}
  },
};
const qrCode = new URLSearchParams(location.search).get('k') || '';
// A remote that moved here from another of the Mac's addresses brings its key in the fragment,
// which browsers never send to the server.
const carriedKey = new URLSearchParams(location.hash.slice(1)).get('key') || '';
if (carriedKey) store.set(carriedKey);
if (qrCode || carriedKey) history.replaceState(null, '', location.pathname);
let key = store.get();

// Every address the Mac answers at (its name, IP and Tailscale), from its last state.
const addresses = {
  get() { try { const list = JSON.parse(localStorage.getItem('mactvAddresses') || '[]'); return Array.isArray(list) ? list : []; } catch { return []; } },
  set(list) { try { localStorage.setItem('mactvAddresses', JSON.stringify(list)); } catch {} },
};

// When this address stops answering (the Mac's IP changed while it slept, say), try its other
// addresses and move to the first one that still knows this phone, taking the key along.
let unanswered = 0, moving = false;
async function moveToAnotherAddress(fetcher = fetch, go = url => location.replace(url)) {
  if (moving || !key) return false;
  moving = true;
  try {
    for (const origin of addresses.get()) {
      if (typeof origin !== 'string' || origin === location.origin || !/^http:\/\/[^/]+$/.test(origin)) continue;
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 2500);
      try {
        const res = await fetcher(origin + '/state', { headers: { 'X-Couch-Key': key }, signal: controller.signal });
        if (res.ok) { go(origin + '/#key=' + encodeURIComponent(key)); return true; }
      } catch {} finally { clearTimeout(timer); }
    }
    return false;
  } finally { moving = false; }
}

// Keep a reachable sleeping display distinct from an offline Mac.
function online(ok, sleeping = false) {
  $('.status').hidden = ok && !sleeping;
  // A Mac that's fully asleep is off the network; only its own keyboard, trackpad or lid wakes it.
  $('#status').textContent = !ok ? 'Can’t reach the Mac. If it’s asleep, wake it with its keyboard or lid.' : sleeping ? 'Screen asleep · controls wake it' : '';
}

// A timed-out POST may already have reached the TV; never replay it automatically.
async function request(path, body, authenticated = true, cancelSignal = null) {
  if (cancelSignal?.aborted) throw new Error('cancelled');
  const controller = new AbortController();
  const credential = key;
  const polling = authenticated && !body && path === '/state';
  const known = polling && lastState && lastState.key === credential ? lastState : null;
  let timer, cancel;
  const interrupted = new Promise((_, reject) => {
    timer = setTimeout(() => { controller.abort(); reject(new Error('Request timed out.')); }, 9000);
    cancel = () => { controller.abort(); reject(new Error('cancelled')); };
    if (cancelSignal) {
      if (cancelSignal.aborted) cancel();
      else cancelSignal.addEventListener('abort', cancel, { once: true });
    }
  });
  try {
    return await Promise.race([interrupted, (async () => {
      const res = await fetch(path, {
        method: body ? 'POST' : 'GET',
        headers: authenticated
          ? { 'Content-Type': 'application/json', 'X-Couch-Key': credential, ...(known ? { 'If-None-Match': known.tag } : {}) }
          : { 'Content-Type': 'application/json' },
        body: body ? JSON.stringify(body) : undefined,
        signal: controller.signal,
      });
      if (authenticated && res.status === 401) {
        // A late response from an old request must not revoke a newly paired key.
        if (key === credential) { key = ''; store.set(''); showPair(); }
        throw new Error('unpaired');
      }
      if (known && res.status === 304) return JSON.parse(known.json);
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || res.statusText);
      if (polling) {
        const tag = res.headers && typeof res.headers.get === 'function' ? res.headers.get('ETag') : null;
        lastState = tag ? { key: credential, tag, json: JSON.stringify(data) } : null;
      }
      return data;
    })()]);
  } finally {
    clearTimeout(timer);
    if (cancelSignal) cancelSignal.removeEventListener('abort', cancel);
  }
}
// The last /state this page got and its ETag: while nothing on the TV changes, the Mac answers 304 with no body
// and the page uses this one again (a fresh copy each time, so editing an answer never changes the saved one).
let lastState = null;
function api(path, body, signal) { return request(path, body, true, signal); }

// Keep a small bounded queue: repeats are dropped under load and urgent actions jump ahead.
const commandQueue = [];
let activeCommand = null;
function pumpCommands() {
  if (activeCommand || !commandQueue.length) return;
  const item = commandQueue.shift();
  if (!key) { item.done(); pumpCommands(); return; }
  const body = typeof item.body === 'function' ? item.body() : item.body;
  if (!body) { item.done(); pumpCommands(); return; }
  const controller = new AbortController();
  activeCommand = controller;
  api('/cmd', body, controller.signal).catch(e => {
    if (e.message !== 'unpaired' && e.message !== 'cancelled') { online(false); haptic('error'); }
  }).finally(() => { activeCommand = null; item.done(); pumpCommands(); });
}
// repeat：按住时的连发，Mac 忙着的时候丢掉。震动由按键自己给（见上面），送的时候不震
function send(a, extra = {}, repeat = false) {
  return new Promise(resolve => {
    const urgent = a === 'home';
    if (urgent) {
      wheelPending = 0;   // 转盘攒着还没送的格数作废，不会跑到主屏上去
      while (commandQueue.length) commandQueue.shift().done();
      if (activeCommand) activeCommand.abort();
      commandQueue.unshift({ body: { a, ...extra }, done: resolve });
    } else if (!(a === 'press' && extra.p !== 'alive')   // 按键的点一下 / 按住 / 松开一条都不能丢
               && ((repeat && (activeCommand || commandQueue.length)) || commandQueue.length >= 8)) {
      resolve(); return;
    } else {
      commandQueue.push({ body: { a, ...extra }, done: resolve });
    }
    pumpCommands();
  });
}

// 转盘：每过一格手机上马上"嗒"一下（手感不等网络），格数先攒着；上一条指令一回来，就把攒下的格数一次送过去。
// 转得再快也不排长队、不丢格，Mac 那边收到几格就走几格（一条最多 16 格，多的接着下一条送）
let wheelPending = 0, wheelQueued = false;
const WHEEL_MAX = 16;
function queueWheel() {
  if (wheelQueued) return;
  wheelQueued = true;
  let sent = false;
  commandQueue.push({
    body: () => {
      wheelQueued = false;
      const d = Math.max(-WHEEL_MAX, Math.min(WHEEL_MAX, wheelPending));
      wheelPending -= d;
      sent = d !== 0;
      return sent ? { a: 'wheel', d } : null;
    },
    done: () => {
      wheelQueued = false;
      if (!sent) { wheelPending = 0; return; }   // 没送出去就被丢掉了（比如按了主屏、断开了）：攒下的作废
      if (wheelPending) queueWheel();            // 超过 16 格剩下的：接着送
    },
  });
  pumpCommands();
}
function sendWheel(step) {
  haptic('tick');   // 转盘每走一格轻轻震一下
  wheelPending += step;
  queueWheel();
}

// State: connection, the app list, settings.
let appsShown = '', apps = [], canRestore = false, currentLocalMovie = null, iinaInstalled = false, onTV = '';
let stateGeneration = 0, appMutationPending = false, displayChanging = false, availableDisplays = [];
let stateInFlight = null;
async function refresh(duringMutation = false) {
  if (appMutationPending && !duringMutation) return false;
  if (!key) { showPair(); return false; }
  if (stateInFlight) {
    if (!duringMutation) return stateInFlight;
    await stateInFlight; // The pre-edit snapshot must finish before the reconciliation read.
    if (!key) return false;
  }
  const pending = readState();
  stateInFlight = pending;
  try { return await pending; } finally { if (stateInFlight === pending) stateInFlight = null; }
}
async function readState() {
  const generation = ++stateGeneration;
  try {
    const s = await api('/state');
    // A newer refresh or an edit invalidates an older in-flight response.
    if (generation !== stateGeneration) return false;
    unanswered = 0;
    if (Array.isArray(s.addresses) && s.addresses.length) addresses.set(s.addresses);
    online(true, s.displaysSleeping === true);
    document.body.classList.toggle('guest', s.guest === true);
    if (s.guest === true) $$('.scrim.show').forEach(sheet => sheet.classList.remove('show'));
    renderChips(chipItems(s));
    const focused = appFocus();
    apps = s.apps;
    if (Number.isInteger(s.dockSize) && s.dockSize > 0) dockSize = s.dockSize;
    canRestore = s.canRestore;
    // 电视上开着的应用：网页、IINA 和影片在 current 里；B站、网易云、得到是 Mac TV 自己的页面，在快捷键的 context 里
    const context = s.shortcuts && typeof s.shortcuts.context === 'string' && s.shortcuts.context !== 'home' ? s.shortcuts.context : '';
    onTV = s.current && typeof s.current.id === 'string' ? s.current.id : context;
    currentLocalMovie = s.currentLocalMovie || null;
    iinaInstalled = !!s.iinaInstalled;
    updateMovieOptions();
    showSleep(s.sleepMinutes || 0);
    for (const row of $$('[data-setting]')) row.setAttribute('aria-checked', String(s[row.dataset.setting] === true));
    $('#lid-status').textContent = s.lidStatus || '';
    if (!displayChanging) updateDisplays(s.displaySetup);
    renderPlayerChoices(s.websitePlayer === 'brave' ? 'brave' : 'embedded', s.braveInstalled === true);
    const player = s.externalPlayer && s.externalPlayer.name === 'IINA' ? s.externalPlayer : null;
    $('#iina-controls').hidden = !player;
    const iinaStatus = player && typeof player.status === 'string' ? player.status : '';
    const iinaError = player && typeof player.error === 'string' ? player.error : '';
    $('#iina-status').textContent = iinaStatus;
    $('#iina-status').hidden = !iinaStatus;
    $('#iina-error').textContent = iinaError;
    $('#iina-error').hidden = !iinaError;
    const browser = s.externalBrowser;
    $('#browser-controls').hidden = !browser;
    const browserError = browser && typeof browser.error === 'string' ? browser.error : '';
    $('#browser-error').textContent = browserError;
    $('#browser-error').hidden = !browserError;
    $('#browser-retry').hidden = !browserError;
    $('#browser-retry').disabled = !!(browser && browser.opening);
    $('#browser-control-note').textContent = browser && browser.accessibilityAllowed === false
      ? 'Allow Accessibility access for Mac TV to send input to Brave. Automation access is also needed to open and control its window.' : '';
    const sig = JSON.stringify([s.apps, s.canRestore, onTV]);
    if (sig !== appsShown) {
      appsShown = sig;
      if (!appMutationPending) renderApps(focused);
    }
    return true;
  } catch (e) {
    if (generation === stateGeneration && e.message !== 'unpaired') {
      online(false);
      // About nine seconds without an answer: look for the Mac at its other addresses.
      if (++unanswered >= 3) moveToAnotherAddress();
    }
    return false;
  }
}

// 快捷键：转盘下面左边一列四个，跟着电视上的应用换（Mac 在 /state 的 shortcuts 里说是哪几个）。
// 少于四个时空着的格子留着；不能用的（比如 B站开着但没在放）暗着、按不动。
// 名字加值一行放不下时才滚动（量一次，不是每帧量）
const chips = $$('.chip');
let chipsShown = '';
const timeText = m => m < 60 ? `${m} min` : m % 60 ? `${Math.floor(m / 60)} hr ${m % 60} min` : `${m / 60} hr`;
function chipItems(s) {
  if (s.shortcuts && Array.isArray(s.shortcuts.items)) return s.shortcuts.items.slice(0, 4);
  // 还不会发快捷键的 Mac：主屏那四个照画，手机自己能做的两个能用，另外两个暗着
  const guest = s.guest === true;
  return [
    { id: 'shortcut', title: 'Run Shortcut', icon: 'shortcut', enabled: false },
    { id: 'screensaver', title: 'Screen Saver', icon: 'screensaver', enabled: false },
    { id: 'sleepTimer', title: 'Sleep Timer', icon: 'sleep', value: s.sleepMinutes ? timeText(s.sleepMinutes) : undefined, enabled: !guest, phone: true },
    { id: 'files', title: 'Finder', icon: 'files', enabled: !guest, phone: true },
  ];
}
function renderChips(items) {
  const sig = JSON.stringify(items);
  if (sig === chipsShown) return;
  chipsShown = sig;
  chips.forEach((chip, i) => {
    const item = items[i] && typeof items[i] === 'object' ? items[i] : null;
    // 字或图标换了：先把现在这一套复制下来，换完以后它淡出、新的淡入
    const look = item ? JSON.stringify([item.title, item.value, item.icon]) : '';
    const ghost = chip.shownLook && look !== chip.shownLook ? chipGhost(chip) : null;
    chip.shownLook = look;
    chip.item = item;
    chip.classList.toggle('empty', !item);
    chip.disabled = !item || item.enabled === false;
    chip.tabIndex = item ? 0 : -1;
    const title = item ? String(item.title ?? '') : '', value = item && item.value != null ? String(item.value) : '';
    if (item) chip.setAttribute('aria-label', value ? `${title}, ${value}` : title); else chip.removeAttribute('aria-label');
    const icon = item && typeof item.icon === 'string' && item.icon && document.getElementById('icon-' + item.icon) ? '#icon-' + item.icon : '';
    chip.classList.toggle('no-icon', !icon);
    const use = chip.querySelector('.icon use');
    if (icon) use.setAttribute('href', icon); else use.removeAttribute('href');
    const copy = chip.querySelector('.copy');
    copy.querySelector('b').textContent = title;
    copy.querySelector('.value').textContent = value;
    if (ghost) crossfadeChip(chip, ghost, !!item);
  });
  $('.shortcuts-label').style.visibility = items.length ? '' : 'hidden';
  chipWidth = chips[0].clientWidth;
  fitChips();
}
// 一格里现在显示的字和图标复制一份（在滚的停在现在滚到的地方），盖在上面淡出去用；页面看不见时不用
function chipGhost(chip) {
  chip.querySelector('.chip-ghost')?.remove();
  for (const part of chip.querySelectorAll('.icon, .text')) part.getAnimations().forEach(a => a.cancel());
  if (unseen() || chip.classList.contains('empty')) return null;
  const ghost = document.createElement('span');
  ghost.className = chip.classList.contains('overflow') ? 'chip-ghost overflowed' : 'chip-ghost';
  ghost.setAttribute('aria-hidden', 'true');
  if (!chip.classList.contains('no-icon')) ghost.append(chip.querySelector('.icon').cloneNode(true));
  const run = chip.querySelector('.run'), text = chip.querySelector('.text').cloneNode(true), still = text.firstElementChild;
  still.removeAttribute('class');
  still.removeAttribute('style');
  still.style.display = 'inline-block';
  still.style.transform = getComputedStyle(run).transform;
  ghost.append(text);
  return ghost;
}
// 旧的很快淡出，新的稍慢淡入（iOS 换字的样子，一共不到 0.2 秒）；格子变空时只剩旧的淡出
function crossfadeChip(chip, ghost, filled) {
  chip.append(ghost);
  const gone = () => ghost.remove();
  ghost.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 120, easing: 'ease-out', fill: 'both' }).finished.then(gone, gone);
  if (filled) for (const part of chip.querySelectorAll(':scope > .icon, :scope > .text')) part.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 180, easing: 'ease-in-out' });
}
// 放不下的：像 iPod 那样来回滚——停一下，从右往左滚到露出最后一个字，停一下，再从左往右滚回开头，一直这样来回；
// 每秒走 30 像素上下，两头各停一程的 20%。多走 10 个单位，让最后一个字走出右边的渐隐。
// 用脚本按算好的像素放动画（不靠 CSS 变量，Safari 上也稳）；要走的距离没变就不重来，正在滚的接着滚
const stillMotion = matchMedia('(prefers-reduced-motion: reduce)');
function fitChips() {
  for (const chip of chips) {
    const text = chip.querySelector('.text'), run = text.firstElementChild, copy = run.firstElementChild;
    const over = !chip.classList.contains('empty') && text.clientWidth > 0 && copy.offsetWidth > text.clientWidth;
    chip.classList.toggle('overflow', over);
    const distance = over && !stillMotion.matches ? Math.round(copy.offsetWidth - text.clientWidth + chip.clientWidth / 132 * 10) : 0;
    if (run.marquee && run.marqueeDistance === distance) continue;
    run.marquee?.cancel();
    run.marquee = null;
    run.marqueeDistance = distance;
    if (!distance) continue;
    const end = `translateX(${-distance}px)`;
    run.marquee = run.animate([
      { transform: 'translateX(0)', offset: 0 }, { transform: 'translateX(0)', offset: 0.2 },
      { transform: end, offset: 0.8 }, { transform: end, offset: 1 },
    ], { duration: Math.max(3000, distance / 30 / 0.6 * 1000), iterations: Infinity, direction: 'alternate', easing: 'linear' });
  }
}
stillMotion.addEventListener?.('change', fitChips);
// 转屏、窗口变宽变窄时再量一次（Safari 工具栏收放只改高度，不动它）
let chipWidth = 0;
window.addEventListener('resize', () => { const w = chips[0].clientWidth; if (w !== chipWidth) { chipWidth = w; fitChips(); } });
// 点一下：Mac 上的交给 Mac；睡眠定时、文件、还没选好的"运行快捷指令"手机自己开
chips.forEach(chip => chip.addEventListener('click', () => {
  const item = chip.item;
  if (!item || item.enabled === false) return;
  if (!item.phone) { send('shortcut', { id: item.id }); return; }
  if (item.id === 'sleepTimer') openSheet('#sleep-sheet');
  else if (item.id === 'files') openFiles();
  else if (item.id === 'shortcut') openSettings('page-apple');
}));

// Settings choices: a list with a checkmark, in place of a dropdown.
function choiceRow(title, detail, selected, disabled, onPick) {
  const row = document.createElement('button');
  row.className = 'row';
  row.setAttribute('aria-pressed', String(selected));
  row.disabled = disabled;
  const name = document.createElement('span'); name.textContent = title; row.appendChild(name);
  if (detail) { const value = document.createElement('span'); value.className = 'value'; value.textContent = detail; row.appendChild(value); }
  row.onclick = onPick;
  return row;
}

function updateDisplays(setup) {
  const list = $('#display-select');
  availableDisplays = Array.isArray(setup?.displays) ? setup.displays : [];
  const selected = availableDisplays.find(display => display.preferred) || availableDisplays.find(display => display.current);
  $('#display-value').textContent = selected ? selected.name : 'None';
  list.replaceChildren(...(availableDisplays.length
    ? availableDisplays.map(display => choiceRow(display.name, display.current ? 'Showing now' : '', display === selected,
        displayChanging, () => chooseDisplay(display)))
    : [choiceRow('No displays available', '', false, true, () => {})]));
}

function renderPlayerChoices(current, braveInstalled) {
  $('#website-player-value').textContent = current === 'brave' ? 'Brave' : 'Built-in';
  $('#website-player').replaceChildren(
    choiceRow('Built-in', '', current === 'embedded', false, () => choosePlayer('embedded')),
    choiceRow('Brave', braveInstalled ? '' : 'Not installed', current === 'brave', !braveInstalled && current !== 'brave', () => choosePlayer('brave')));
}

// Apps sheet: launch tiles. Edit arranges them as the iPhone Home Screen does: the icons jiggle; on top, in a frame,
// the TV's dock (Home's top row, its first six apps), and the other apps below in Home's order. Long-press an app
// and drag it; the others make room. Into a full dock, its last app moves to the first place below; out of the dock,
// the first app below comes up into it. "−" offers Hide, and Delete for Everyone for an app someone added; a system
// app (Movies, Web) has no "−", it only moves. The TV
// takes each drop at once (/apps/place); what changes on the TV arrives with the next state and moves the icons
// here. One haptic on pick-up and one on drop, a tick each time the others make room. Only the jiggle runs on its
// own, only while editing, and only as a CSS transform.
let editing = false, dockSize = 6;
const appOrder = (list = apps) => list.map(app => app.id);
const sameOrder = (a, b) => a.join() === b.join();
// The Mac's rule (AppLibrary.move): the app comes out of Home's order and goes back in at `index`
function placeApp(order, id, index) {
  const rest = order.filter(item => item !== id);
  rest.splice(Math.min(Math.max(index, 0), rest.length), 0, id);
  return rest;
}
// The app list in a new order, before the TV confirms it
function reorderedApps(order) {
  const byId = new Map(apps.map(app => [app.id, app]));
  return order.filter(id => byId.has(id)).map(id => byId.get(id));
}
function appFocus() {
  const active = document.activeElement;
  if (!$('#apps').contains(active) || !active.dataset.appId) return null;
  return { id: active.dataset.appId, action: active.dataset.action, element: active,
           index: apps.findIndex(app => app.id === active.dataset.appId) };
}
function appArt(app) {
  const art = document.createElement('span');
  art.className = 'art';
  if (app.icon) {
    const img = document.createElement('img');
    img.src = `/icon/${encodeURIComponent(app.id)}?v=${encodeURIComponent(appsShown.length)}`;
    img.alt = '';
    art.appendChild(img);
  } else {
    art.textContent = app.name.slice(0, 1).toUpperCase();
  }
  return art;
}
function appMessage(message, error = false) {
  const note = $('#apps-msg');
  note.textContent = message;
  note.className = error ? 'footnote err' : 'footnote ok';
  note.hidden = !message;
}
async function changeApp(path, body, message) {
  if (appMutationPending) return;
  const focused = appFocus();
  appMutationPending = true;
  ++stateGeneration;
  $('#apps').setAttribute('aria-busy', 'true');
  $('#apps').querySelectorAll('button').forEach(button => { button.disabled = true; });
  $('#edit-apps').disabled = true;
  $('#restore').disabled = true;
  appMessage('Saving…');
  try {
    await api(path, body);
    const updated = await refresh(true);
    appMessage(updated ? message : 'Saved on the TV. Reconnect to refresh the app list.', !updated);
  } catch (e) {
    haptic('error');
    appMessage(e.message === 'unpaired' ? 'Pair with the TV first.' : e.message, true);
    // Another remote may have changed the app or its position.
    await refresh(true);
  } finally {
    appMutationPending = false;
    // Do not take focus back if the user moved to Done or another sheet while waiting.
    const canRestoreFocus = focused && (document.activeElement === focused.element || document.activeElement === document.body);
    renderApps(canRestoreFocus ? focused : null);
  }
}
// 一个应用的格子：图标（电视上正开着的一圈蓝、字是 "On TV"；在放声音的右下角一个小黑块）
function appTile(app) {
  const b = document.createElement('button');
  b.className = app.id === onTV ? 'app current' : 'app';
  b.dataset.appId = app.id;
  b.dataset.action = 'launch';
  const tile = document.createElement('span');
  tile.className = 'tile';
  tile.append(appArt(app));
  if (app.playing === true) {
    const playing = document.createElement('span');
    playing.className = 'playing';
    playing.setAttribute('aria-hidden', 'true');
    playing.append(document.createElement('i'), document.createElement('i'), document.createElement('i'));
    tile.append(playing);
  }
  const name = document.createElement('span');
  name.className = 'name';
  name.textContent = app.id === onTV ? 'On TV' : app.name;
  b.append(tile, name);
  b.setAttribute('aria-label', `Open ${app.name}${app.id === onTV ? ', on TV' : ''}`);
  b.onclick = () => {
    closeSheets();
    send('launch', { id: app.id });
  };
  return b;
}
function renderApps(focused = appFocus()) {
  // A finger is moving an app: what the TV says meanwhile waits for the drop
  if (drag) { renderLater = true; return; }
  renderLater = false;
  const box = $('#apps');
  const sheet = $('#apps-sheet .sheet');
  const scrollTop = sheet.scrollTop;
  box.setAttribute('aria-busy', String(appMutationPending));
  if (editing) {
    renderArrangement(box);
  } else {
    arranged = null;
    closeAppMenu();
    box.textContent = '';
    box.classList.remove('editing');
    for (const app of apps) box.appendChild(appTile(app));
    // 最后两格：Mac 上的文件，和加一个应用
    const files = document.createElement('button');
    files.className = 'app files';
    files.innerHTML = '<span class="tile"><span class="art"><img src="/icon/finder" alt=""></span></span><span class="name">Finder</span>';
    files.onclick = openFiles;
    const add = document.createElement('button');
    add.className = 'app add';
    add.innerHTML = '<span class="tile"><span class="art"><svg viewBox="0 0 150 132" aria-hidden="true"><use href="#icon-store"/></svg></span></span><span class="name">Store</span>';
    add.onclick = openAdd;
    box.append(files, add);
  }
  $('#edit-apps').textContent = editing ? 'Done' : 'Edit';
  $('#edit-apps').classList.toggle('on', editing);
  $('#edit-apps').disabled = appMutationPending;
  $('#apps-done').hidden = editing;
  $('#restore-group').hidden = !(editing && canRestore);
  $('#restore').disabled = appMutationPending;
  $('#apps-title').textContent = editing ? 'Edit Apps' : 'Open on TV';
  if (focused && $('#apps-sheet').classList.contains('show') && !$('#pair').classList.contains('show')) {
    const buttons = [...box.querySelectorAll('[data-app-id]')];
    const sameApp = buttons.filter(button => button.dataset.appId === focused.id && !button.disabled);
    const target = sameApp.find(button => button.dataset.action === focused.action) || sameApp[0]
      || buttons.find(button => button.dataset.appId === apps[Math.min(Math.max(focused.index, 0), apps.length - 1)]?.id && !button.disabled)
      || $('#edit-apps');
    if (document.activeElement !== target) target.focus({ preventScroll: true });
  }
  sheet.scrollTop = scrollTop;
}
$('#edit-apps').onclick = () => { if (drag) return; editing = !editing; appMessage(''); renderApps(); };
$('#restore').onclick = () => changeApp('/apps/restore', {}, 'Restored built-in apps.');

// Edit's dock, the grid below it and a tile per app, kept while editing: when the order changes (here or on the TV)
// the same tiles move to their new places (FLIP, a transform), rather than being drawn again
let arranged = null;
function renderArrangement(box) {
  if (!arranged) {
    box.textContent = '';
    box.classList.add('editing');
    const dock = document.createElement('div');
    dock.className = 'dock';
    const row = document.createElement('div');
    row.className = 'app-grid';
    row.setAttribute('role', 'group');
    row.setAttribute('aria-label', 'Dock');
    dock.append(row);
    const below = document.createElement('div');
    below.className = 'app-grid';
    box.append(dock, below);
    arranged = { dock, row, below, tiles: new Map() };
  }
  const seen = new Set();
  for (const app of apps) {
    seen.add(app.id);
    let tile = arranged.tiles.get(app.id);
    if (!tile) {
      tile = document.createElement('div');
      tile.className = 'app';
      tile.dataset.appId = app.id;
      tile.dataset.action = 'arrange';
      tile.tabIndex = 0;
      tile.setAttribute('role', 'button');
      tile.setAttribute('aria-roledescription', 'app');
      arranged.tiles.set(app.id, tile);
    }
    const look = JSON.stringify([app.name, !!app.icon, !!app.added, !!app.system]);
    if (tile.dataset.look !== look) fillArrangeTile(tile, app, look);
    const badge = tile.querySelector('.hide-badge');
    if (badge) badge.disabled = appMutationPending;
  }
  for (const [id, tile] of arranged.tiles) if (!seen.has(id)) { tile.remove(); arranged.tiles.delete(id); }
  placeTiles(appOrder());
}
// An app while editing: its icon with the "−" (the iPhone Home Screen's remove badge), and its name. A system app
// (Movies, Web) can't be hidden or deleted, so it has no "−"
function fillArrangeTile(tile, app, look) {
  const face = document.createElement('span');
  face.className = 'tile';
  face.append(appArt(app));
  if (!app.system) face.append(hideBadge(tile, app));
  const name = document.createElement('span');
  name.className = 'name';
  name.textContent = app.name;
  tile.setAttribute('aria-label', app.name);
  tile.replaceChildren(face, name);
  tile.dataset.look = look;
}
function hideBadge(tile, app) {
  const badge = document.createElement('button');
  badge.className = 'hide-badge';
  badge.setAttribute('aria-label', `Remove ${app.name}`);
  badge.setAttribute('aria-haspopup', 'menu');
  const sign = document.createElement('span');
  sign.className = 'sign minus';
  sign.setAttribute('aria-hidden', 'true');
  badge.append(sign);
  badge.onclick = () => {
    if (Date.now() - droppedAt < 500) return;   // the end of a drag that started near it
    if (openMenu?.parentElement === tile) closeAppMenu(); else appMenu(tile, app);
  };
  return badge;
}
// Puts each tile in its place: the first six in the dock, the rest below. Tiles that move glide from where they
// were; `still` (the one under the finger) follows the finger instead.
function placeTiles(order, still = null) {
  const { row, below, tiles } = arranged;
  const moving = [...tiles.values()].filter(tile => tile !== still && tile.isConnected);
  const was = new Map(moving.map(tile => [tile, tile.getBoundingClientRect()]));
  moving.forEach(tile => tile.getAnimations().forEach(run => run.cancel()));
  const focused = document.activeElement;
  const placed = order.map(id => tiles.get(id)).filter(Boolean);
  row.append(...placed.slice(0, dockSize));
  below.append(...placed.slice(dockSize));
  if (focused && focused !== document.activeElement && focused.isConnected) focused.focus({ preventScroll: true });
  if (unseen() || calm()) return;
  for (const tile of moving) {
    const from = was.get(tile), to = tile.getBoundingClientRect();
    const dx = from.left - to.left, dy = from.top - to.top;
    if (!from.width || (!dx && !dy)) continue;
    tile.animate([{ transform: `translate(${dx}px, ${dy}px)` }, { transform: 'none' }], { duration: 320, easing: 'cubic-bezier(.2,.8,.2,1)' });
  }
}
// "−" on an app: a small menu with Hide (this profile only) and, for an app someone added, Delete for Everyone
let openMenu = null;
function appMenu(tile, app) {
  closeAppMenu();
  if (drag || appMutationPending || app.system) return;
  const menu = document.createElement('div');
  menu.className = 'app-menu';
  menu.setAttribute('role', 'menu');
  const item = (label, danger, act) => {
    const button = document.createElement('button');
    button.setAttribute('role', 'menuitem');
    button.textContent = label;
    if (danger) button.className = 'danger';
    button.onclick = e => { e.stopPropagation(); closeAppMenu(); act(); };
    menu.append(button);
  };
  item('Hide', false, () => hideApp(app));
  if (app.added) item('Delete for Everyone', true, () => deleteApp(app));
  const sheet = $('#apps-sheet .sheet').getBoundingClientRect(), place = tile.getBoundingClientRect();
  menu.classList.toggle('flip', place.left + place.width / 2 > sheet.left + sheet.width / 2);
  tile.append(menu);
  openMenu = menu;
}
function closeAppMenu() { openMenu?.remove(); openMenu = null; }
document.addEventListener('pointerdown', e => {
  if (openMenu && !openMenu.contains(e.target) && !e.target.closest?.('.hide-badge')) closeAppMenu();
}, true);
// Hide: off this profile's Home. A built-in app comes back with Restore built-in apps; one someone added, by adding it again
function hideApp(app) {
  if (drag || appMutationPending || app.system) return;
  apps = apps.filter(item => item.id !== app.id);
  if (!app.added) canRestore = true;
  renderApps();
  saveArrangement('/apps/remove', { id: app.id });
}
// Delete for Everyone: off every profile's Home, so it asks first
function deleteApp(app) {
  if (drag || appMutationPending || app.system || !confirm(`Delete “${app.name}” for Everyone?`)) return;
  apps = apps.filter(item => item.id !== app.id);
  renderApps();
  saveArrangement('/apps/delete', { id: app.id });
}
// An edit while editing: the list here already shows it; the TV takes it, then its state settles any difference.
// Quiet when it works (nothing to read), a message and the error haptic when it doesn't.
async function saveArrangement(path, body) {
  appMutationPending = true;
  ++stateGeneration;
  appMessage('');
  try {
    await api(path, body);
  } catch (e) {
    haptic('error');
    appMessage(e.message === 'unpaired' ? 'Pair with the TV first.' : e.message, true);
  }
  try { await refresh(true); } finally {
    appMutationPending = false;
    renderApps();
  }
}

// Long-press an app (300 ms; moving sooner is a scroll) and drag it. The tile under the finger follows it; the
// others make room as it passes over their places, in the dock or below it.
let drag = null, renderLater = false, droppedAt = 0;
const PICK_UP_MS = 300, PICK_UP_SLOP = 8;
$('#apps').addEventListener('pointerdown', e => {
  if (!editing || drag || !arranged || appMutationPending || (e.pointerType === 'mouse' && e.button !== 0)) return;
  // What is really under the finger: the browser may hand a touch near the small "−" to the "−" itself
  const under = document.elementFromPoint(e.clientX, e.clientY) || e.target;
  const tile = under.closest('.app[data-app-id]');
  if (!tile || !arranged.tiles.has(tile.dataset.appId) || under.closest('.hide-badge, .app-menu')) return;
  const finger = { id: e.pointerId, x: e.clientX, y: e.clientY };
  const listening = new AbortController();
  const stop = () => { clearTimeout(timer); listening.abort(); };
  const timer = setTimeout(() => { stop(); pickUp(tile, finger); }, PICK_UP_MS);
  window.addEventListener('pointermove', ev => {
    if (ev.pointerId !== finger.id) return;
    if (Math.hypot(ev.clientX - e.clientX, ev.clientY - e.clientY) > PICK_UP_SLOP) stop();
    else { finger.x = ev.clientX; finger.y = ev.clientY; }
  }, { signal: listening.signal });
  for (const type of ['pointerup', 'pointercancel']) {
    window.addEventListener(type, ev => { if (ev.pointerId === finger.id) stop(); }, { signal: listening.signal });
  }
});
function pickUp(tile, finger) {
  const id = tile.dataset.appId, start = appOrder();
  if (!editing || drag || !arranged || appMutationPending || !tile.isConnected || !start.includes(id)) return;
  closeAppMenu();
  tile.getAnimations().forEach(run => run.cancel());
  const centre = iconCentre(tile);
  drag = { id, tile, pointer: finger.id, start, rest: start.filter(item => item !== id), index: start.indexOf(id),
    x: finger.x, y: finger.y, tx: 0, ty: 0, grab: { x: finger.x - centre.x, y: finger.y - centre.y } };
  tile.classList.add('lifted');
  $('#apps').classList.add('dragging');
  haptic('press');
}
// The place in Home's order under the middle of the dragged icon: the dock (and half the gap below it) holds the
// first six, the grid below the rest
function spotAt(x, y) {
  const { dock, row, below } = arranged;
  const inDock = y < dock.getBoundingClientRect().bottom + 9;
  const grid = inDock ? row : below;
  const r = grid.getBoundingClientRect(), style = getComputedStyle(grid);
  const columns = Math.max(1, style.gridTemplateColumns.split(' ').filter(Boolean).length);
  const gapX = parseFloat(style.columnGap) || 0, gapY = parseFloat(style.rowGap) || 0;
  const cellW = (r.width - gapX * (columns - 1)) / columns, cellH = drag.tile.offsetHeight || 1;
  const column = Math.min(columns - 1, Math.max(0, Math.floor((x - r.left + gapX / 2) / (cellW + gapX))));
  const line = inDock ? 0 : Math.max(0, Math.floor((y - r.top + gapY / 2) / (cellH + gapY)));
  return Math.min((inDock ? 0 : dockSize) + line * columns + column, drag.rest.length);
}
function dragTo(x, y) {
  const d = drag;
  d.x = x; d.y = y;
  const index = spotAt(x - d.grab.x, y - d.grab.y);
  if (index !== d.index) {
    d.index = index;
    placeTiles(placeApp(d.start, d.id, index), d.tile);
    haptic('tick');
  }
  follow(d);
}
// The middle of a tile's icon where the grid puts it (the dock's icons are smaller than the ones below)
function iconCentre(tile) {
  const box = tile.getBoundingClientRect();
  return { x: box.left + box.width / 2, y: box.top + (tile.querySelector('.tile')?.offsetHeight || box.height) / 2 };
}
// The dragged icon sits under the finger wherever its place in the grid is now
function follow(d) {
  d.tile.style.transform = '';
  const home = iconCentre(d.tile);
  d.tx = d.x - d.grab.x - home.x;
  d.ty = d.y - d.grab.y - home.y;
  d.tile.style.transform = `translate(${d.tx}px, ${d.ty}px)`;
}
// Lifting the finger drops it where it is (the TV takes it); the system taking the touch away puts it back
function dropApp(cancelled = false) {
  const d = drag;
  if (!d) return;
  drag = null;
  droppedAt = Date.now();
  $('#apps').classList.remove('dragging');
  d.tile.classList.remove('lifted');
  d.tile.style.transform = '';
  const target = cancelled ? d.start : placeApp(d.start, d.id, d.index);
  if (cancelled && arranged) placeTiles(d.start, d.tile);
  if (!unseen() && !calm()) {
    const home = iconCentre(d.tile), dx = d.x - d.grab.x - home.x, dy = d.y - d.grab.y - home.y;
    if (dx || dy) d.tile.animate([{ transform: `translate(${dx}px, ${dy}px)` }, { transform: 'none' }], { duration: 260, easing: 'cubic-bezier(.2,.8,.2,1)' });
  }
  if (!cancelled) haptic('press');
  if (cancelled || sameOrder(target, d.start)) { if (renderLater) renderApps(); return; }
  apps = reorderedApps(target);
  saveArrangement('/apps/place', { id: d.id, index: d.index });
}
window.addEventListener('pointermove', e => { if (drag && e.pointerId === drag.pointer) dragTo(e.clientX, e.clientY); });
window.addEventListener('pointerup', e => { if (drag && e.pointerId === drag.pointer) dropApp(); });
window.addEventListener('pointercancel', e => { if (drag && e.pointerId === drag.pointer) dropApp(true); });
// While an app is lifted the finger moves it, not the sheet; a long press shows no callout
document.addEventListener('touchmove', e => { if (drag && e.cancelable) e.preventDefault(); }, { passive: false });
$('#apps').addEventListener('contextmenu', e => { if (editing && e.target.closest('.app')) e.preventDefault(); });
// The keyboard (and a switch control): the arrow keys move the focused app one place earlier or later in Home's order
$('#apps').addEventListener('keydown', e => {
  if (!editing || drag || appMutationPending || !arranged) return;
  const tile = e.target.closest?.('.app[data-app-id]');
  const step = { ArrowLeft: -1, ArrowUp: -1, ArrowRight: 1, ArrowDown: 1 }[e.key];
  if (!tile || e.target !== tile || !step) return;
  e.preventDefault();
  const order = appOrder(), id = tile.dataset.appId, index = order.indexOf(id) + step;
  if (index < 0 || index >= order.length) return;
  apps = reorderedApps(placeApp(order, id, index));
  haptic('tick');
  renderApps();
  saveArrangement('/apps/place', { id, index });
});

// File IDs come from the server and remain opaque; names are always rendered as text.
let fileTrail = [], fileEntries = [], fileNext = null, selectedMovie = null, fileGeneration = 0;
function fileMessage(message, error = false) {
  $('#files-msg').textContent = message;
  $('#files-msg').className = error ? 'footnote err' : 'footnote';
}
// 一行：名字，右边一个灰的说明
function listRow(title, detail, onClick) {
  const button = document.createElement('button');
  button.className = 'row';
  const name = document.createElement('span'); name.textContent = title;
  button.append(name);
  if (detail) { const tag = document.createElement('span'); tag.className = 'value'; tag.textContent = detail; button.append(tag); }
  button.onclick = onClick;
  return button;
}
function emptyRow(text) {
  const row = document.createElement('div');
  row.className = 'row empty';
  row.textContent = text;
  return row;
}
function updateMovieOptions() {
  $('#play-iina').disabled = !iinaInstalled;
  $('#play-iina').textContent = iinaInstalled ? 'Play in IINA' : 'IINA not installed';
  $('#subtitle-search-iina').disabled = !iinaInstalled;
}
async function loadFiles(more = false) {
  const generation = ++fileGeneration;
  const folder = fileTrail[fileTrail.length - 1];
  const offset = more ? fileNext : 0;
  fileMessage('Loading…');
  try {
    const data = await api(folder ? `/files?folder=${encodeURIComponent(folder.id)}&offset=${encodeURIComponent(offset)}&limit=100` : '/files/roots');
    if (generation !== fileGeneration) return;
    const items = folder ? (data.entries || []) : (data.roots || []);
    fileEntries = more ? fileEntries.concat(items) : items;
    fileNext = folder && data.nextOffset != null ? data.nextOffset : null;
    fileMessage('');
    renderFiles();
  } catch (e) {
    if (generation !== fileGeneration) return;
    fileMessage(e.message === 'unpaired' ? 'Pair with the TV first.' : e.message, true);
  }
}
function renderFiles() {
  $('#files-path').textContent = ['Locations', ...fileTrail.map(item => item.name)].join(' › ');
  $('#files-back').disabled = !fileTrail.length;
  $('#files-more-group').hidden = fileNext == null;
  const filter = $('#files-filter').value.trim().toLocaleLowerCase();
  const matches = fileEntries.filter(item => item.name.toLocaleLowerCase().includes(filter));
  $('#files-list').replaceChildren(...matches.map(item => listRow(item.name,
    item.kind === 'directory' ? 'Folder ›' : item.kind === 'subtitle' ? 'Subtitle' : 'Video', () => {
      if (item.kind === 'directory') {
        fileTrail.push({ id:item.id, name:item.name });
        $('#files-filter').value = ''; loadFiles();
      } else if (item.kind === 'video') {
        selectedMovie = { id:item.id, title:item.name };
        $('#movie-name').textContent = item.name;
        $('#movie-options').hidden = false;
        $('#subtitle-panel').hidden = true;
      } else if (item.kind === 'subtitle' && selectedMovie) {
        applySubtitle(item.id);
      } else {
        fileMessage('Select a video first, then choose a subtitle.');
      }
    })));
  if (!matches.length) $('#files-list').append(emptyRow(filter ? 'No matches' : 'Nothing to play here'));
}
function openFiles() {
  presentSheet($('#files-sheet'));   // 开着的别的弹出页（比如应用）收下去，这一页升上来
  fileTrail = []; fileEntries = []; fileNext = null; $('#files-filter').value = '';
  selectedMovie = currentLocalMovie;
  $('#movie-options').hidden = !selectedMovie; $('#subtitle-panel').hidden = true;
  if (selectedMovie) $('#movie-name').textContent = selectedMovie.title;
  updateMovieOptions(); loadFiles();
}
$('#files-back').onclick = () => { if (fileTrail.length) { fileTrail.pop(); $('#files-filter').value = ''; loadFiles(); } };
$('#files-filter').addEventListener('input', renderFiles);
$('#files-more').onclick = () => { if (fileNext != null) loadFiles(true); };
async function playFile(player) {
  if (!selectedMovie) return;
  try {
    fileMessage('Opening video…');
    await api('/files/play', { id:selectedMovie.id, player });
    fileMessage(player === 'iina' ? 'Playing in IINA on the Mac.' : 'Playing on Mac TV.');
    refresh();
  } catch (e) { fileMessage(e.message === 'unpaired' ? 'Pair with the TV first.' : e.message, true); }
}
$('#play-native').onclick = () => playFile('native');
$('#play-iina').onclick = () => playFile('iina');
async function applySubtitle(id) {
  if (!selectedMovie) return;
  try { await api('/files/subtitle', { movie:selectedMovie.id, subtitle:id }); fileMessage('Opening the video with subtitles in IINA.'); }
  catch (e) { fileMessage(e.message === 'unpaired' ? 'Pair with the TV first.' : e.message, true); }
}
$('#subtitle-options').onclick = async () => {
  if (!selectedMovie) return;
  $('#subtitle-panel').hidden = false;
  const list = $('#subtitle-list'); list.textContent = '';
  try {
    const data = await api(`/files/subtitles?movie=${encodeURIComponent(selectedMovie.id)}`);
    list.replaceChildren(...(data.entries || []).map(item => listRow(item.name, '', () => applySubtitle(item.id))));
    if (!list.childElementCount) list.append(emptyRow('No subtitles beside this video'));
  } catch (e) { fileMessage(e.message === 'unpaired' ? 'Pair with the TV first.' : e.message, true); }
};
$('#subtitle-upload').onchange = async e => {
  const input = e.target, file = input.files[0];
  if (!file || !selectedMovie) return;
  try {
    if (!/\.srt$/i.test(file.name) || !file.size || file.size > 256 * 1024) throw new Error('Choose a UTF-8 .srt file up to 256 KB.');
    const content = new TextDecoder('utf-8', { fatal:true }).decode(await file.arrayBuffer());
    await api('/files/subtitle-upload', { movie:selectedMovie.id, name:file.name, content });
    fileMessage('Subtitle uploaded; opening the video in IINA.');
  } catch (err) { fileMessage(err.message === 'unpaired' ? 'Pair with the TV first.' : err.message, true); }
  finally { input.value = ''; }
};
$('#subtitle-search-iina').onclick = async () => {
  if (!selectedMovie) return;
  try { await api('/files/subtitle-search', { movie:selectedMovie.id }); fileMessage('Searching in IINA.'); }
  catch (e) { fileMessage(e.message === 'unpaired' ? 'Pair with the TV first.' : e.message, true); }
};
$('#subtitle-search-web').onclick = () => {
  if (!selectedMovie) return;
  window.open('https://www.opensubtitles.org/en/search/sublanguageid-all/moviename-' + encodeURIComponent(selectedMovie.title.replace(/\.(mp4|m4v|mov|mkv|webm|avi|wmv|flv|ts|m2ts|mts|mpg|mpeg|3gp)$/i, '')), '_blank', 'noopener,noreferrer');
};

function openAdd() {
  presentSheet($('#add-sheet'));   // 应用页收下去，这一页升上来
  $('#add-msg').textContent = '';
  $('#add-msg').className = 'footnote';
  addTab('web');
}
function addTab(which) {
  $('#add-web-tab').classList.toggle('on', which === 'web');
  $('#add-mac-tab').classList.toggle('on', which === 'mac');
  $('#web-form').hidden = which !== 'web';
  $('#mac-form').hidden = which !== 'mac';
  if (which === 'mac') searchMac();
}
$('#add-web-tab').onclick = () => addTab('web');
$('#add-mac-tab').onclick = () => addTab('mac');

function added(result) {
  const msg = $('#add-msg');
  msg.className = 'footnote ok';
  msg.textContent = `Added ${result.name}.`;
  refresh();
  setTimeout(() => { closeSheets(); }, 1400);
}
function failed(e) {
  haptic('error');
  const msg = $('#add-msg');
  msg.className = 'footnote err';
  msg.textContent = e.message === 'unpaired' ? 'Pair with the TV first.' : e.message;
}
$('#web-form').onsubmit = e => {
  e.preventDefault();
  const url = $('#web-url').value.trim();
  if (!url) { failed(new Error('Enter a website address.')); return; }
  $('#add-msg').className = 'footnote';
  $('#add-msg').textContent = 'Adding…';
  api('/apps/add', { url, name: $('#web-name').value.trim() }).then(r => {
    $('#web-url').value = ''; $('#web-name').value = '';
    added(r);
  }).catch(failed);
};

let macTimer = 0;
$('#mac-q').addEventListener('input', () => { clearTimeout(macTimer); macTimer = setTimeout(searchMac, 200); });
async function searchMac() {
  try {
    const list = await api(`/macapps?q=${encodeURIComponent($('#mac-q').value)}`);
    $('#mac-list').replaceChildren(...list.map(app => {
      const b = listRow(app.name, app.added ? 'Added' : 'Add', () => api('/apps/add', { bundleID: app.bundleID }).then(added).catch(failed));
      b.disabled = app.added;
      return b;
    }));
    if (!list.length) $('#mac-list').append(emptyRow('No apps match'));
  } catch (e) { failed(e); }
}

// A six-digit code is exchanged once for a separate device credential.
function showPair() { if ($('#pair').classList.contains('show')) return; $('#pair').classList.add('show'); setTimeout(() => $('#code').focus(), 50); }
async function pair(code, name) {
  const data = await request('/pair', { code, name }, false);
  key = data.token;
  store.set(key);
  $('#pair').classList.remove('show');
  $('#pair-err').textContent = '';
  $('#code').value = '';
  return refresh();
}
$('#pair-btn').onclick = async () => {
  try { await pair($('#code').value.trim(), $('#device-name').value.trim()); }
  catch (e) { haptic('error'); $('#pair-err').textContent = e.message; }
};
// A list row: a name with a detail under it, and its buttons on the right.
function itemRow(title, detail, buttons) {
  const row = document.createElement('div');
  row.className = 'row item';
  const text = document.createElement('span'); text.className = 'text';
  const name = document.createElement('span'); name.textContent = title; text.appendChild(name);
  if (detail) { const sub = document.createElement('span'); sub.className = 'detail'; sub.textContent = detail; text.appendChild(sub); }
  const actions = document.createElement('div'); actions.className = 'item-actions';
  actions.append(...buttons);
  row.append(text, actions);
  return row;
}
function linkButton(label, onClick, danger = false, aria = '') {
  const button = document.createElement('button');
  button.className = danger ? 'link danger' : 'link';
  button.textContent = label;
  if (aria) button.setAttribute('aria-label', aria);
  button.onclick = onClick;
  return button;
}
const countLabel = count => count ? String(count) : 'None';

async function loadDevices() {
  const box = $('#devices');
  try {
    const devices = await api('/devices');
    box.replaceChildren(...devices.map(device => itemRow(device.name + (device.current ? ' · this phone' : ''),
      device.guest ? `Guest until ${new Date(device.expiresAt).toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' })}` : '',
      [linkButton('Remove', async () => {
        if (!confirm(`Remove ${device.name}?`)) return;
        try {
          await api('/devices/revoke', { id: device.id });
          if (device.current) { key = ''; store.set(''); closeSheets(); showPair(); }
          else await loadDevices();
        } catch (e) { $('#devices-msg').textContent = e.message; }
      }, true, `Remove ${device.name}`)])));
    box.hidden = devices.length === 0;
    $('#devices-count').textContent = countLabel(devices.length);
    $('#revoke-all').hidden = false;
    $('#devices-msg').textContent = '';
  } catch (e) {
    box.replaceChildren();
    $('#revoke-all').hidden = true;
    $('#devices-msg').textContent = e.message === 'Guests cannot manage devices' ? 'Guest devices cannot manage pairing.' : e.message;
  }
}
let sharesPoll = 0;
async function loadShares() {
  const box = $('#shares');
  let list;
  try { list = await api('/shares'); } catch (e) { $('#shares-msg').textContent = e.message; return; }
  box.replaceChildren(...list.map(share => {
    const buttons = [];
    if (!share.connected && !share.connecting) {
      buttons.push(linkButton('Connect', async () => { try { await api('/shares/connect', { id: share.id }); } catch {} watchShares(); }));
    }
    buttons.push(linkButton('Remove', async () => {
      if (!confirm(`Remove ${share.name} from Mac TV?`)) return;
      try { await api('/shares/remove', { id: share.id }); } catch (e) { $('#shares-msg').textContent = e.message; }
      loadShares();
    }, true, `Remove ${share.name}`));
    const row = itemRow(share.name, share.status, buttons);
    row.title = share.address || '';
    return row;
  }));
  box.hidden = list.length === 0;
  $('#shares-count').textContent = countLabel(list.length);
  return list;
}
// Connecting takes a few seconds: refresh the list until it settles.
function watchShares() {
  clearTimeout(sharesPoll);
  let tries = 0;
  const tick = async () => {
    const list = await loadShares();
    if (list && list.some(share => share.connecting) && ++tries < 50) sharesPoll = setTimeout(tick, 1500);
  };
  tick();
}
$('#share-form').onsubmit = async e => {
  e.preventDefault();
  const address = $('#share-address').value.trim();
  if (!address) { $('#shares-msg').textContent = 'Enter a shared folder, e.g. nas.local/Movies.'; return; }
  try {
    await api('/shares/add', { address, user: $('#share-user').value.trim(), password: $('#share-password').value });
    $('#share-address').value = ''; $('#share-password').value = '';
    $('#shares-msg').textContent = '';
  } catch (err) { $('#shares-msg').textContent = err.message; haptic('error'); }
  watchShares();
};
let jellyfinPoll = 0;
async function loadJellyfin() {
  const box = $('#jellyfin');
  let reply;
  try { reply = await api('/jellyfin'); } catch (e) { $('#jellyfin-msg').textContent = e.message; return; }
  box.replaceChildren(...reply.servers.map(server => {
    const row = itemRow(server.name, server.status, [linkButton('Remove', async () => {
      if (!confirm(`Sign out of ${server.name} and remove it from Mac TV?`)) return;
      try { await api('/jellyfin/remove', { id: server.id }); } catch (e) { $('#jellyfin-msg').textContent = e.message; }
      loadJellyfin();
    }, true, `Remove ${server.name}`)]);
    row.title = `${server.user} on ${server.address}`;
    return row;
  }));
  box.hidden = reply.servers.length === 0;
  $('#jellyfin-count').textContent = countLabel(reply.servers.length);
  if (reply.signingIn) $('#jellyfin-msg').textContent = 'Signing in…';
  return reply;
}
// Signing in takes a moment: check until it's done, then say how it went.
function watchJellyfin() {
  clearTimeout(jellyfinPoll);
  let tries = 0;
  const tick = async () => {
    const reply = await loadJellyfin();
    if (!reply) return;
    if (reply.signingIn && ++tries < 40) { jellyfinPoll = setTimeout(tick, 1000); return; }
    if (reply.error) { $('#jellyfin-msg').textContent = reply.error; haptic('error'); }
    else { $('#jellyfin-msg').textContent = ''; $('#jellyfin-password').value = ''; }
  };
  tick();
}
$('#jellyfin-form').onsubmit = async e => {
  e.preventDefault();
  const address = $('#jellyfin-address').value.trim();
  const user = $('#jellyfin-user').value.trim();
  if (!address || !user) { $('#jellyfin-msg').textContent = 'Enter the server and your user name.'; return; }
  try {
    await api('/jellyfin/add', { address, user, password: $('#jellyfin-password').value });
  } catch (err) { $('#jellyfin-msg').textContent = err.message; haptic('error'); return; }
  watchJellyfin();
};
$('#revoke-all').onclick = async () => {
  if (!confirm('Remove all paired devices, including this one?')) return;
  try { await api('/devices/revoke-all', {}); key = ''; store.set(''); closeSheets(); showPair(); }
  catch (e) { $('#devices-msg').textContent = e.message; }
};


// 一按就送的键：播放 / 暂停、静音、音量，Brave / IINA 那一排和打字页里的键
document.querySelectorAll('[data-a]').forEach(b => b.addEventListener('click', e => {
  if (b.hasAttribute('data-repeat') && e.detail) return;   // 音量：手指按下时已经送了（见下面）；这里只接键盘 / 辅助功能
  send(b.dataset.a);
}));

// 按住连发：音量的上下两半（和按住键盘上的键、Siri Remote 的音量键一样）：按下去就调一格，按住 0.45 秒起
// 每 0.16 秒再调一格。连发的每一下和转盘走一格一样轻轻震一下
document.querySelectorAll('[data-repeat]').forEach(b => {
  let timer = null;
  const stop = () => { clearTimeout(timer); clearInterval(timer); timer = null; };
  b.addEventListener('pointerdown', () => {
    stop();
    send(b.dataset.a);
    timer = setTimeout(() => {
      haptic('tick');
      send(b.dataset.a, {}, true);
      timer = setInterval(() => { haptic('tick'); send(b.dataset.a, {}, true); }, 160);
    }, 450);
  });
  ['pointerup', 'pointercancel', 'pointerleave'].forEach(t => b.addEventListener(t, stop));
});

// 按键的"点一下 / 按住"：手机自己按手指按了多久来判断（不受网络快慢影响），告诉 Mac 是哪一种；
// Mac 按键盘上同一个键的规矩来做（见 PhonePress.swift）。按住时每 300 毫秒报一次"还按着"，
// 万一"松开"在网络上丢了，Mac 一会儿收不到就当松开了。按住生效时轻轻震一下
const press = {
  held: new Map(),
  tap(k) {
    if (k === 'home') return send('home');   // 回主屏是"急"的：排在前面、把还没送的都清掉
    send('press', { k, p: 'tap' });
  },
  hold(k) {
    this.release(k, false);
    haptic('hold');
    send('press', { k, p: 'hold' });
    this.held.set(k, setInterval(() => send('press', { k, p: 'alive' }, true), 300));
  },
  release(k, tell = true) {
    if (!this.held.has(k)) return;
    clearInterval(this.held.get(k));
    this.held.delete(k);
    if (tell) send('press', { k, p: 'release' });
  },
};
// 返回（按住 = 主屏幕）、TV（按住 = 控制中心）、电源（按一下 = 叫醒，按住 = TV 待机）：和 Siri Remote 一样
document.querySelectorAll('[data-press]').forEach(b => {
  const k = b.dataset.press;
  let timer = null, held = false;
  b.addEventListener('pointerdown', () => {
    held = false;
    clearTimeout(timer);
    timer = setTimeout(() => { held = true; press.hold(k); }, 500);
  });
  b.addEventListener('pointerup', () => {
    clearTimeout(timer);
    if (held) press.release(k); else press.tap(k);
    held = false;
  });
  ['pointercancel', 'pointerleave'].forEach(t => b.addEventListener(t, () => { clearTimeout(timer); if (held) press.release(k); held = false; }));
  b.addEventListener('click', e => { if (e.detail === 0) press.tap(k); });   // 键盘 / 辅助功能触发
});
$('#browser-retry').onclick = () => send('retrybrowser').then(refresh);
let websiteOpening = false, openedNote = 0;   // openedNote：收起"Opened on TV"的定时，新的一条重新计时
$('#open-website').onsubmit = async e => {
  e.preventDefault();
  if (websiteOpening) return;
  clearTimeout(openedNote);
  const input = $('#website-address'), note = $('#website-open-error');
  const url = input.value.trim();
  if (!url) { note.classList.add('err'); note.textContent = 'Paste a link or enter a website address.'; note.hidden = false; return; }
  websiteOpening = true;
  $('#website-go').disabled = true;
  note.hidden = true;
  try {
    const reply = await api('/browser/open', { url });
    input.value = '';
    // 告诉人电视上打开的是什么（"Bilibili video""NetEase Cloud Music playlist""website"），几秒后收起
    note.classList.remove('err');
    note.textContent = 'Opened on TV' + (reply && reply.opened ? ': ' + reply.opened : '');
    note.hidden = false;
    openedNote = setTimeout(() => { if (!note.classList.contains('err')) note.hidden = true; }, 4000);
    await refresh();
  } catch (error) {
    if (error.message !== 'unpaired') {
      note.classList.add('err');
      note.textContent = error.message || 'Could not open that link.';
      note.hidden = false;
      haptic('error');
    }
  } finally {
    websiteOpening = false;
    $('#website-go').disabled = false;
  }
};
$('#type').onsubmit = e => {
  e.preventDefault();
  const t = $('#typed').value;
  if (t) send('text', { t });
  $('#typed').value = '';
};

// Sheets：每个弹出页都从这里开、关（像 iOS）。开：暗的一层慢慢盖上，弹出页顺着 iOS 的曲线升上来（0.48 秒，起步快、
// 落地轻）；关：倒过来，降下去、暗的一层退掉（0.32 秒），走完了才藏起来。半路又开、又关，都从它这一刻在的地方接着走，
// 不会卡在半路。从一个弹出页换到另一个时暗的一层不退，由新的接着盖住。只动位置和透明度；系统里开了"减弱动态效果"
// 时只淡入淡出、不滑；页面看不见时（切到后台）不动画，直接到位
const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)');
const calm = () => reduceMotion.matches;
const unseen = () => document.hidden;
const SHEET_EASE = 'cubic-bezier(.32,.72,0,1)', SHEET_OPEN = 480;
const CLOSE_EASE = 'cubic-bezier(.3,.5,.2,1)', SHEET_CLOSE = 320, FADE = 200;
const OFFSCREEN = 'translateY(calc(100% + 48px))';   // 整个弹出页连上沿的影子都在屏幕下面
document.documentElement.classList.toggle('unseen', unseen());
for (const scrim of $$('.scrim')) {
  const dim = document.createElement('div');
  dim.className = 'dim';
  dim.setAttribute('aria-hidden', 'true');
  scrim.prepend(dim);
}
const sheetOf = scrim => scrim.querySelector('.sheet'), dimOf = scrim => scrim.querySelector('.dim');
const sheetMotion = new Map();   // 每个弹出页正在走的动画，和收起来以后要做的事
const motionOf = scrim => {
  if (!sheetMotion.has(scrim)) sheetMotion.set(scrim, { sheet: null, dim: null, hidden: [] });
  return sheetMotion.get(scrim);
};
// 弹出页这一刻在哪（往下离开了多少像素）、多不透明，暗的一层多暗：正在升、正在降、正被手指拉着都算
function sheetNow(scrim) {
  const look = getComputedStyle(sheetOf(scrim));
  let y = 0;
  try { y = new DOMMatrixReadOnly(look.transform).m42; } catch {}
  return { y, opacity: Number(look.opacity), dim: Number(getComputedStyle(dimOf(scrim)).opacity) };
}
// 停在这一刻的样子、动画收掉，接下来从这里接着走
function holdSheet(scrim) {
  const now = sheetNow(scrim), m = motionOf(scrim);
  m.sheet?.cancel(); m.dim?.cancel();
  m.sheet = m.dim = null;
  return now;
}
function presentSheet(scrim) {
  if (scrim.classList.contains('show')) return;
  let dimFrom = 0;
  for (const other of $$('.scrim.show, .scrim.closing')) {
    if (other === scrim) continue;
    dimFrom = Math.max(dimFrom, sheetNow(other).dim);
    dismissSheet(other);
    const m = motionOf(other);
    m.dim?.cancel(); m.dim = null;
    dimOf(other).style.opacity = '0';   // 暗的一层交给新的这一页：屏幕不会一亮一暗
  }
  const m = motionOf(scrim), back = scrim.classList.contains('closing'), from = holdSheet(scrim);
  scrim.classList.remove('closing');
  scrim.classList.add('show');
  if (back) m.hidden.splice(0).forEach(fn => fn());
  const sheet = sheetOf(scrim), dim = dimOf(scrim);
  sheet.style.transform = sheet.style.opacity = dim.style.opacity = '';
  if (unseen()) return;
  const timing = { duration: calm() ? FADE : SHEET_OPEN, easing: SHEET_EASE };
  if (back) {   // 正在降：从这一刻在的地方升回去
    m.sheet = sheet.animate([{ transform: `translateY(${from.y}px)`, opacity: from.opacity }, { transform: 'none', opacity: 1 }], timing);
    m.dim = dim.animate([{ opacity: Math.max(from.dim, dimFrom) }, { opacity: 1 }], timing);
  } else {      // 从屏幕下面（连影子一起藏着）升上来；按它自己的高度算，内容半路变了也对得上
    m.sheet = sheet.animate(calm() ? [{ opacity: 0 }, { opacity: 1 }] : [{ transform: OFFSCREEN }, { transform: 'none' }], timing);
    m.dim = dim.animate([{ opacity: dimFrom }, { opacity: 1 }], timing);
  }
}
// speed：手指往下甩的速度（像素 / 毫秒），收起时接着这个速度走
function dismissSheet(scrim, speed = 0) {
  if (!scrim.classList.contains('show')) return;
  const now = holdSheet(scrim), m = motionOf(scrim);
  scrim.classList.replace('show', 'closing');
  if (scrim.contains(document.activeElement)) document.activeElement.blur();   // 键盘跟着收起
  const sheet = sheetOf(scrim), dim = dimOf(scrim);
  sheet.style.transform = sheet.style.opacity = dim.style.opacity = '';
  if (unseen()) { hideSheet(scrim); return; }
  const at = `translateY(${now.y}px)`;
  let duration = calm() ? FADE : SHEET_CLOSE;
  // 这条曲线起步的斜率是 5/3：甩得越快，走得越快
  if (speed > 0 && !calm()) duration = Math.max(140, Math.min(SHEET_CLOSE, (sheet.offsetHeight + 48 - now.y) / speed * 5 / 3));
  const timing = { duration, easing: CLOSE_EASE, fill: 'both' };
  m.sheet = sheet.animate(calm() ? [{ transform: at, opacity: now.opacity }, { transform: at, opacity: 0 }] : [{ transform: at }, { transform: OFFSCREEN }], timing);
  m.dim = dim.animate([{ opacity: now.dim }, { opacity: 0 }], timing);
  const run = m.sheet;
  run.finished.then(() => { if (m.sheet === run) hideSheet(scrim); }, () => {});
}
function hideSheet(scrim) {
  const m = motionOf(scrim), sheet = sheetOf(scrim);
  m.sheet?.cancel(); m.dim?.cancel();
  m.sheet = m.dim = null;
  scrim.classList.remove('closing');
  sheet.style.transform = sheet.style.opacity = dimOf(scrim).style.opacity = '';
  if (scrim.id === 'settings-sheet') settlePages();
  m.hidden.splice(0).forEach(fn => fn());
}
// 等这一页完全收起来再做（比如应用页从编辑换回去，免得降到一半变了样子、高度一跳）
function whenHidden(scrim, fn) {
  if (scrim.classList.contains('closing')) motionOf(scrim).hidden.push(fn); else fn();
}
const closeSheets = (speed = 0) => {
  const closingText = $('#text-sheet').classList.contains('show');
  $$('.scrim.show').forEach(s => dismissSheet(s, Number(speed) || 0));
  if (closingText) $('#open-text').focus();
  if (drag) dropApp(true);
  if (editing) { editing = false; whenHidden($('#apps-sheet'), () => renderApps()); }
};
function openSheet(selector) { closeSheets(); presentSheet($(selector)); }
$$('.scrim').forEach(s => s.addEventListener('click', e => { if (e.target === s || e.target === dimOf(s)) closeSheets(); }));
$$('[data-close]').forEach(b => b.onclick = () => closeSheets());
$('#open-text').onclick = () => { presentSheet($('#text-sheet')); $('#text-sheet [data-close]').focus({ preventScroll: true }); };
$('#open-apps').onclick = () => { refresh(); presentSheet($('#apps-sheet')); };
$('#open-settings').onclick = () => openSettings();

// 往下拉弹出页：手指按在页头上，或内容已经在最上面时按在哪儿都行（输入框和排序的把手除外）。弹出页跟着手指走、
// 暗的一层跟着变亮；拉过一段（页高的 45%，最多 240 像素，甩的算上它会滑多远）或往下一甩就收起，不然顺着 iOS 的
// 曲线弹回去。拉起来以后，手指下面那个按钮这一下不算点了。手指拉着时才动，不用定时器
let pull = null, pulled = false;
function pullStart(scrim, target, x, y, t) {
  // (an app in Edit is for long-press and drag: a finger on it scrolls, but never pulls the sheet away)
  if (pull || !scrim.classList.contains('show') || target.closest('input, textarea, select, .handle, .apps.editing .app')) return;
  const sheet = sheetOf(scrim), head = !!target.closest('.sheet-head');
  if (!head && sheet.scrollTop > 0) return;
  pull = { scrim, sheet, head, x, y, live: false, base: 0, off: 0, h: 1, dim: 1, trail: [{ y, t }] };
}
// 返回 true：这一下归弹出页（不让内容滚）
function pullMove(x, y, t) {
  const p = pull;
  if (!p) return false;
  const dx = x - p.x, dy = y - p.y;
  if (!p.live) {
    if (Math.hypot(dx, dy) < 8) return dy > 0;   // 还看不出往哪走：往下的先别让内容滚（往上的照常滚，页头上也是）
    if (Math.abs(dx) > Math.abs(dy) || dy < 0 || (!p.head && p.sheet.scrollTop > 0)) { pull = null; return false; }
    p.live = true;
    pulled = true;
    letGoAll();                                            // 手指下面按着的那一行亮回去
    const now = holdSheet(p.scrim);                        // 还在升的时候抓住：从它这一刻在的地方接着拉
    p.base = now.y - dy;
    p.dim = now.dim;
    p.h = Math.max(1, p.sheet.offsetHeight);
  }
  p.off = Math.max(0, p.base + dy);
  p.sheet.style.transform = `translateY(${p.off}px)`;
  dimOf(p.scrim).style.opacity = String(Math.max(0, p.dim * (1 - p.off / p.h)));
  p.trail.push({ y, t });
  while (p.trail.length > 2 && t - p.trail[0].t > 100) p.trail.shift();
  return true;
}
function pullEnd(cancelled, t = performance.now()) {
  const p = pull;
  pull = null;
  if (!p || !p.live) return;
  const first = p.trail[0], last = p.trail[p.trail.length - 1];
  const speed = t - last.t < 100 && last.t > first.t ? (last.y - first.y) / (last.t - first.t) : 0;   // 往下为正
  if (!cancelled && speed > -0.2 && (speed > 0.9 || p.off + speed * 180 > Math.min(p.h * 0.45, 240))) { closeSheets(speed); return; }
  const m = motionOf(p.scrim), dim = dimOf(p.scrim), dimNow = Number(dim.style.opacity || 1);
  p.sheet.style.transform = dim.style.opacity = '';
  if (unseen() || (!p.off && dimNow >= 1)) return;
  const timing = { duration: calm() ? FADE : 420, easing: SHEET_EASE };
  m.sheet = p.sheet.animate([{ transform: `translateY(${p.off}px)` }, { transform: 'none' }], timing);
  m.dim = dim.animate([{ opacity: dimNow }, { opacity: 1 }], timing);
}
for (const scrim of $$('.scrim')) {
  const sheet = sheetOf(scrim);
  sheet.addEventListener('touchstart', e => {
    if (pull && !pull.mouse) pullEnd(true, e.timeStamp);
    if (e.touches.length === 1) pullStart(scrim, e.target, e.touches[0].clientX, e.touches[0].clientY, e.timeStamp);
  }, { passive: true });
  sheet.addEventListener('touchmove', e => {
    const f = e.touches[0];
    if (f && e.touches.length === 1 && pullMove(f.clientX, f.clientY, e.timeStamp) && e.cancelable) e.preventDefault();
  }, { passive: false });
  sheet.addEventListener('touchend', e => { if (!e.touches.length) pullEnd(false, e.timeStamp); });
  sheet.addEventListener('touchcancel', e => pullEnd(true, e.timeStamp));
  // 电脑上用鼠标开的遥控器也能拉
  sheet.addEventListener('pointerdown', e => {
    if (e.pointerType !== 'mouse' || e.button !== 0) return;
    pullStart(scrim, e.target, e.clientX, e.clientY, e.timeStamp);
    if (pull) pull.mouse = e.pointerId;
  });
}
window.addEventListener('pointermove', e => { if (pull && pull.mouse === e.pointerId) pullMove(e.clientX, e.clientY, e.timeStamp); });
window.addEventListener('pointerup', e => { if (pull && pull.mouse === e.pointerId) pullEnd(false, e.timeStamp); });
window.addEventListener('pointercancel', e => { if (pull && pull.mouse === e.pointerId) pullEnd(true, e.timeStamp); });
window.addEventListener('pointerdown', () => { pulled = false; }, true);
window.addEventListener('click', e => { if (pulled && e.detail) { pulled = false; e.preventDefault(); e.stopPropagation(); } }, true);
// 切到后台：正在走的都直接走完，拉着的松开
document.addEventListener('visibilitychange', () => {
  document.documentElement.classList.toggle('unseen', unseen());
  if (!unseen()) return;
  pullEnd(true);
  for (const scrim of $$('.scrim')) {
    if (scrim.classList.contains('closing')) { hideSheet(scrim); continue; }
    const m = sheetMotion.get(scrim);
    try { m?.sheet?.finish(); m?.dim?.finish(); } catch {}
  }
  settlePages();
});

// Settings：主页面和一层层的子页面，每页左上角回到上一页（按钮上写着上一页的名字）
let pageStack = [];
const onPage = { 'page-start': renderStart, 'page-shortcuts': renderShortcutsPage, 'page-picker': renderPicker, 'page-apple': loadApple };
function openSettings(first = 'settings-main') {
  refresh(); loadDevices(); loadShares(); loadJellyfin(); loadShortcuts();
  pageStack = [];
  showPage(first);
  presentSheet($('#settings-sheet'));
}
function showPage(id, push = true) {
  settlePages();
  const sheet = $('#settings-sheet .sheet');
  const from = $$('#settings-sheet .page').find(page => !page.hidden), to = $('#' + id);
  const slide = !!from && from !== to && $('#settings-sheet').classList.contains('show') && !unseen();
  const fromHeight = slide ? sheet.offsetHeight : 0, fromScroll = sheet.scrollTop;
  if (push && pageStack[pageStack.length - 1] !== id) pageStack.push(id);
  const previous = pageStack[pageStack.length - 2];
  for (const page of $$('#settings-sheet .page')) page.hidden = page.id !== id;
  const back = $('#' + id).querySelector('[data-back]');
  if (back) { back.hidden = !previous; back.textContent = previous ? $('#' + previous).dataset.title : ''; }
  $('#settings-sheet .sheet').scrollTop = 0;
  onPage[id]?.();
  if (slide) slidePages(sheet, from, to, push, fromHeight, fromScroll);
}
// 一页推到下一页（像 iOS 的导航）：新的一页从右边盖过来，旧的往左挪三成、暗下去；回上一页倒过来。弹出页的高度
// 同时从旧的一页慢慢变成新的一页。半路又点了：这一次直接到位，再走新的
const PAGE_TIME = 440;
let pageMotion = null;
function settlePages() {
  const m = pageMotion;
  if (!m) return;
  pageMotion = null;
  m.anims.forEach(a => a.cancel());
  m.tidy();
}
function slidePages(sheet, from, to, ahead, fromHeight, fromScroll) {
  const toHeight = sheet.offsetHeight, quiet = calm();
  const upper = ahead ? to : from, lower = ahead ? from : to;
  from.hidden = false;
  from.style.top = `${-fromScroll}px`;   // 旧的一页停在刚才滚到的地方
  from.classList.add('leaving');
  upper.classList.add('upper');
  sheet.classList.add('paging');
  const timing = { duration: quiet ? FADE : PAGE_TIME, easing: SHEET_EASE, fill: 'both' };
  const slide = (page, a, b) => page.animate([{ transform: `translateX(${a})` }, { transform: `translateX(${b})` }], timing);
  const anims = [sheet.animate([{ height: `${quiet ? toHeight : fromHeight}px` }, { height: `${toHeight}px` }], timing)];
  if (quiet) anims.push(from.animate([{ opacity: 1 }, { opacity: 0 }], timing), to.animate([{ opacity: 0 }, { opacity: 1 }], timing));
  else {
    anims.push(ahead ? slide(to, '100%', '0px') : slide(from, '0px', '100%'));
    anims.push(ahead ? slide(from, '0px', '-30%') : slide(to, '-30%', '0px'));
    try { anims.push(lower.animate([{ opacity: ahead ? 0 : .08 }, { opacity: ahead ? .08 : 0 }], { ...timing, pseudoElement: '::after' })); } catch {}
  }
  const m = { anims, tidy() {
    sheet.classList.remove('paging');
    for (const page of [from, to]) page.classList.remove('leaving', 'upper');
    from.style.top = '';
    from.hidden = true;
  } };
  pageMotion = m;
  Promise.all(anims.map(a => a.finished)).then(() => {
    if (pageMotion !== m) return;
    settlePages();
    // 路上内容变了（比如列表刚读回来）：高度从路上那个接着变过去，不跳
    const real = sheet.offsetHeight;
    if (!quiet && Math.abs(real - toHeight) > 1) sheet.animate([{ height: `${toHeight}px` }, { height: `${real}px` }], { duration: 260, easing: SHEET_EASE });
  }, () => {});
}
function goBack() {
  if (pageStack.length < 2) return;
  pageStack.pop();
  showPage(pageStack[pageStack.length - 1], false);
}
$$('#settings-sheet [data-page]').forEach(row => row.onclick = () => showPage(row.dataset.page));
$$('#settings-sheet [data-back]').forEach(back => back.onclick = goBack);

// 睡眠定时：设置里一条，快捷键里点 Sleep Timer 弹出的小页一条，两条一样
$$('.sleep-choice button').forEach(b => b.onclick = () => {
  const m = Number(b.dataset.m);
  send('sleeptimer', { m }).then(refresh);
  showSleep(m);
});
function showSleep(minutes) {
  for (const b of $$('.sleep-choice button')) {
    const m = Number(b.dataset.m);
    b.classList.toggle('on', minutes ? m !== 0 && m >= minutes && m - minutes < 15 : m === 0);
  }
  for (const note of $$('.sleep-left')) { note.textContent = minutes ? `${timeText(minutes)} left` : ''; note.hidden = !minutes; }
}
async function chooseDisplay(display) {
  if (displayChanging) return;
  const note = $('#display-msg');
  displayChanging = true;
  note.hidden = true;
  updateDisplays({ displays: availableDisplays.map(item => ({ ...item, preferred: item === display })) });
  try {
    await api('/display/select', { id: display.id });
  } catch (error) {
    if (error.message !== 'unpaired') {
      note.textContent = error.message || 'Could not change display.';
      note.className = 'footnote err';
      note.hidden = false;
      haptic('error');
    }
  } finally {
    displayChanging = false;
    await refresh();
  }
}
async function choosePlayer(player) {
  const note = $('#browser-msg');
  note.hidden = true;
  try {
    await api('/browser/preference', { player });
  } catch (error) {
    if (error.message !== 'unpaired') {
      note.textContent = error.message || 'Could not change website player.';
      note.hidden = false;
      haptic('error');
    }
  }
  await refresh();
}
// 开关：整行都能点（和 iOS 设置一样），点了马上换样子，Mac 下一次的状态里再对一遍
$$('[data-setting]').forEach(row => row.onclick = () => {
  const v = row.getAttribute('aria-checked') !== 'true';
  row.setAttribute('aria-checked', String(v));
  send('setting', { k: row.dataset.setting, v });
});

// Sleep Now: TV standby, as Control Center's on the TV (the Mac keeps running; Power, Back, TV or Select wakes it)
$('#sleep').onclick = () => { closeSheets(); send('sleep'); };

// 打开遥控器时先是哪一个：点按、触控，或上次用的那个（这台手机自己记着）
const START = [['click', 'Clickpad'], ['touch', 'Touchpad'], ['last', 'Last used']];
const startIn = {
  get() { try { const v = localStorage.getItem('mactvStart'); return START.some(([k]) => k === v) ? v : 'last'; } catch { return 'last'; } },
  set(v) { try { localStorage.setItem('mactvStart', v); } catch {} },
};
function renderStart() {
  const current = startIn.get();
  $('#start-value').textContent = START.find(([k]) => k === current)[1];
  $('#start-choices').replaceChildren(...START.map(([k, name]) => choiceRow(name, '', k === current, false, () => { startIn.set(k); renderStart(); })));
}
renderStart();

// 快捷键设置（GET /shortcuts）：主屏一组；有自己快捷键的应用（B站、网易云、得到）各一组，空着就和主屏一样。
// 挑选页里每改一下马上存（POST /shortcuts/set），存完拿回来的就是新的全部
let shortcutsData = null, pickScope = 'home', saving = Promise.resolve(), unsaved = 0;
const LIMIT = 4;
const catalogEntry = id => shortcutsData?.catalog?.[id] || { title: id, icon: '' };
async function loadShortcuts() {
  try { useShortcuts(await api('/shortcuts')); }
  catch (e) { if (e.message !== 'unpaired') { shortcutsData = null; $('#shortcuts-row').hidden = true; } }
}
function useShortcuts(data) {
  if (!data || !Array.isArray(data.home)) return;
  shortcutsData = data;
  $('#shortcuts-row').hidden = false;
  const own = (data.apps || []).filter(app => app.own).length;
  $('#shortcuts-value').textContent = own ? `Home + ${own} app${own === 1 ? '' : 's'}` : 'Home';
  const showing = pageStack[pageStack.length - 1];
  const redraw = { 'page-shortcuts': renderShortcutsPage, 'page-picker': renderPicker, 'page-apple': renderApple }[showing];
  if (redraw && $('#settings-sheet').classList.contains('show')) redraw();
}
// 每改一下：先在手机上改好、画出来，再按顺序一条条存；最后一条存好时以 Mac 拿回来的为准（中间的不画，免得闪回去），
// 出错了说一句、重新读一遍
function saveShortcuts(scope, ids) {
  const d = shortcutsData;
  if (!d) return;
  if (scope === 'home') d.home = ids;
  else {
    const app = (d.apps || []).find(item => item.id === scope);
    if (app) { app.own = ids.length > 0; app.picked = ids.length ? ids : [...d.home]; }
  }
  useShortcuts(d);
  const msg = $('#pick-msg');
  msg.hidden = true;
  unsaved++;
  saving = saving.then(() => api('/shortcuts/set', { scope, ids })).then(data => { if (unsaved === 1) useShortcuts(data); }, e => {
    if (e.message === 'unpaired') return;
    for (const note of [msg, $('#sc-msg')]) { note.textContent = e.message; note.hidden = false; }
    haptic('error');
    return loadShortcuts();
  }).finally(() => { unsaved--; refresh(); });
}
function glyph(icon) {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('class', 'glyph');
  svg.setAttribute('viewBox', '0 0 44 44');
  svg.setAttribute('aria-hidden', 'true');
  if (icon && document.getElementById('icon-' + icon)) {
    const use = document.createElementNS('http://www.w3.org/2000/svg', 'use');
    use.setAttribute('href', '#icon-' + icon);
    svg.append(use);
  }
  return svg;
}
function span(text, className = '') {
  const el = document.createElement('span');
  if (className) el.className = className;
  el.textContent = text;
  return el;
}
function handle() {
  const grip = span('', 'handle');
  grip.setAttribute('aria-hidden', 'true');
  grip.append(document.createElement('i'), document.createElement('i'), document.createElement('i'));
  return grip;
}
// 拖着把手上下排：手指过了相邻那一行的一半就和它换位置，松手时存
function reorderable(list, done) {
  list.addEventListener('pointerdown', e => {
    const grip = e.target.closest('.handle');
    if (!grip) return;
    const row = grip.parentElement.closest('.group > *');
    if (!row || row.parentElement !== list) return;
    e.preventDefault();
    e.stopPropagation();
    grip.setPointerCapture(e.pointerId);
    const keys = () => [...list.children].map(item => item.dataset.key).filter(Boolean);
    const before = keys().join();
    let start = e.clientY;
    row.classList.add('lifted');
    haptic('press');
    const listening = new AbortController();
    grip.addEventListener('pointermove', ev => {
      if (ev.pointerId !== e.pointerId) return;
      const next = row.nextElementSibling, prev = row.previousElementSibling, offset = ev.clientY - start;
      if (next && offset > next.offsetHeight / 2) { list.insertBefore(next, row); start += next.offsetHeight; haptic('tick'); }
      else if (prev && offset < -prev.offsetHeight / 2) { list.insertBefore(row, prev); start -= prev.offsetHeight; haptic('tick'); }
      row.style.transform = `translateY(${ev.clientY - start}px)`;
    }, { signal: listening.signal });
    const end = ev => {
      if (ev.pointerId !== e.pointerId) return;
      listening.abort();
      row.classList.remove('lifted');
      row.style.transform = '';
      if (keys().join() !== before) done(keys());
    };
    grip.addEventListener('pointerup', end, { signal: listening.signal });
    grip.addEventListener('pointercancel', end, { signal: listening.signal });
  });
}
function renderShortcutsPage() {
  const d = shortcutsData;
  $('#sc-msg').hidden = true;
  if (!d) { $('#sc-home').replaceChildren(); $('#sc-apps').replaceChildren(); return; }
  const home = d.home.map(id => {
    const { title, icon } = catalogEntry(id);
    const row = document.createElement('button');
    row.className = 'row';
    row.dataset.key = id;
    row.append(glyph(icon), span(title));
    if (id === 'shortcut' && d.appleShortcut) row.append(span(d.appleShortcut, 'value'));
    row.append(handle());
    row.onclick = () => openPicker('home');
    return row;
  });
  if (!home.length) {
    const edit = document.createElement('button');
    edit.className = 'row nav';
    edit.append(span('Edit'));
    edit.onclick = () => openPicker('home');
    home.push(edit);
  }
  $('#sc-home').replaceChildren(...home);
  $('#sc-apps').replaceChildren(...(d.apps || []).map(app => {
    const row = document.createElement('button');
    row.className = 'row nav';
    const picture = span('', 'app-icon');
    const known = apps.find(item => item.id === app.id);
    if (known && !known.icon) picture.textContent = app.name.slice(0, 1);
    else {
      const img = document.createElement('img');
      img.src = `/icon/${encodeURIComponent(app.id)}`;
      img.alt = '';
      img.onerror = () => { img.remove(); picture.textContent = app.name.slice(0, 1); };
      picture.append(img);
    }
    const summary = app.own ? (app.picked || []).map(id => catalogEntry(id).title).join(', ') : 'Same as Home';
    row.append(picture, span(app.name), span(summary, 'value'));
    row.onclick = () => openPicker(app.id);
    return row;
  }));
  $('#sc-apps').hidden = !(d.apps || []).length;
}
reorderable($('#sc-home'), ids => saveShortcuts('home', ids));

function openPicker(scope) {
  pickScope = scope;
  const name = scope === 'home' ? 'Home' : ((shortcutsData?.apps || []).find(app => app.id === scope)?.name || scope);
  $('#page-picker').dataset.title = name;
  $('#pick-title').textContent = name;
  $('#pick-msg').hidden = true;
  showPage('page-picker');
}
function renderPicker() {
  const d = shortcutsData;
  if (!d) return;
  const app = pickScope === 'home' ? null : (d.apps || []).find(item => item.id === pickScope);
  if (pickScope !== 'home' && !app) return;
  const picked = app ? app.picked || [] : d.home;
  const full = picked.length >= LIMIT;
  $('#pick-count').textContent = `${picked.length} of ${LIMIT}`;
  $('#pick-on').replaceChildren(...picked.map(id => {
    const { title, icon } = catalogEntry(id);
    const row = document.createElement('div');
    row.className = 'row';
    row.dataset.key = id;
    const remove = document.createElement('button');
    remove.className = 'remove-pick';
    remove.setAttribute('aria-label', `Remove ${title}`);
    remove.append(span('', 'sign minus'));
    remove.onclick = () => saveShortcuts(pickScope, picked.filter(other => other !== id));
    // 运行快捷指令：右边是选好的那个，点这一行换一个
    let body;
    if (id === 'shortcut') {
      body = document.createElement('button');
      body.className = 'pick-body nav';
      body.append(glyph(icon), span(title), span(d.appleShortcut || 'None', 'value'));
      body.onclick = () => showPage('page-apple');
    } else {
      body = span('', 'pick-body');
      body.append(glyph(icon), span(title));
    }
    row.append(remove, body, handle());
    return row;
  }));
  $('#pick-on').hidden = !picked.length;
  const addRow = id => {
    const { title, icon } = catalogEntry(id);
    const row = document.createElement('button');
    row.className = 'row';
    row.disabled = full;
    row.setAttribute('aria-label', `Add ${title}`);
    row.append(span('', 'sign'), glyph(icon), span(title));
    row.onclick = () => saveShortcuts(pickScope, [...picked, id]);
    return row;
  };
  const fromApp = app ? (app.available || []).filter(id => !picked.includes(id)) : [];
  const everywhere = (d.everywhere || []).filter(id => !picked.includes(id));
  $('#pick-app-label').textContent = app ? `From ${app.name}` : '';
  $('#pick-app-label').hidden = !fromApp.length;
  $('#pick-app').replaceChildren(...fromApp.map(addRow));
  $('#pick-app').hidden = !fromApp.length;
  $('#pick-every-label').hidden = !everywhere.length;
  $('#pick-every').replaceChildren(...everywhere.map(addRow));
  $('#pick-every').hidden = !everywhere.length;
}
reorderable($('#pick-on'), ids => saveShortcuts(pickScope, ids));

// 运行快捷指令：从 Mac 上"快捷指令"App 里的挑一个（GET /shortcuts/apple），也可以不选
let appleNames = [];
async function loadApple() {
  const msg = $('#apple-msg');
  renderApple();
  msg.className = 'footnote';
  msg.textContent = 'Loading…';
  msg.hidden = false;
  try {
    const reply = await api('/shortcuts/apple');
    appleNames = Array.isArray(reply.names) ? reply.names.filter(name => typeof name === 'string') : [];
    msg.textContent = appleNames.length ? '' : 'No shortcuts in the Shortcuts app.';
    msg.hidden = !!appleNames.length;
  } catch (e) {
    appleNames = [];
    if (e.message === 'unpaired') { msg.hidden = true; return; }
    msg.textContent = 'Couldn’t load your shortcuts.';
    msg.className = 'footnote err';
  }
  renderApple();
}
function renderApple() {
  const current = shortcutsData?.appleShortcut || '';
  const names = current && !appleNames.includes(current) ? [current, ...appleNames] : appleNames;
  $('#apple-list').replaceChildren(choiceRow('None', '', !current, false, () => chooseApple('')),
    ...names.map(name => choiceRow(name, '', name === current, false, () => chooseApple(name))));
}
async function chooseApple(name) {
  if (shortcutsData) { shortcutsData.appleShortcut = name; renderApple(); }
  try { useShortcuts(await api('/shortcuts/apple', { name })); }
  catch (e) {
    if (e.message === 'unpaired') return;
    const msg = $('#apple-msg');
    msg.textContent = e.message;
    msg.className = 'footnote err';
    msg.hidden = false;
    haptic('error');
    await loadShortcuts();
  }
  renderApple();
  refresh();
}

// Tabs：点按 / 触控 切换条（和设计稿一样）。点哪一半就切到哪边；也可以按住滑块拖过去，松手停在近的那边。
// 手指按着切换条时滑块是按下的样子
let thumbAt = 0;                 // 滑块在哪：0 = 点按（左），1 = 触控（右）
const THUMB_TRAVEL = 536;        // 滑块从左走到右的距离（设计稿单位）
function placeThumb(at, animate = true) {
  const mode = $('#mode');
  thumbAt = Math.max(0, Math.min(1, at));
  if (!animate) mode.classList.add('still');
  $('#mode-thumb').style.transform = `translateX(${THUMB_TRAVEL * thumbAt}px)`;
  if (!animate) { mode.getBoundingClientRect(); mode.classList.remove('still'); }
}
function tab(which, animate = true) {
  const touch = which === 'touch';
  // 真的换了一边：换上来的转盘 / 触控板淡入（0.18 秒），不跳
  const changed = $('#tab-touch').getAttribute('aria-selected') !== String(touch);
  if (animate && changed && !unseen()) $(touch ? '#touchpad' : '#clickpad').animate([{ opacity: 0 }, { opacity: 1 }], { duration: 180, easing: 'ease-out' });
  $('#tab-click').setAttribute('aria-selected', String(!touch));
  $('#tab-touch').setAttribute('aria-selected', String(touch));
  $('#mode-label-click').classList.toggle('on', !touch);
  $('#mode-label-touch').classList.toggle('on', touch);
  placeThumb(touch ? 1 : 0, animate);
  $('#clickpad').style.display = touch ? 'none' : 'block';
  $('#touchpad').style.display = touch ? 'block' : 'none';
  try { localStorage.setItem('mactvTab', which); } catch {}
}
(() => {
  const mode = $('#mode'), thumb = $('#mode-thumb');
  let drag = null;
  // 手指在切换条上的横坐标（设计稿单位，0 到 1080）
  const at = e => { const r = mode.getBoundingClientRect(); return (e.clientX - r.left) * 1080 / r.width; };
  mode.addEventListener('pointerdown', e => {
    if (drag) return;
    mode.setPointerCapture(e.pointerId);
    const x = at(e), left = 9 + THUMB_TRAVEL * thumbAt;   // 滑块左边（设计稿里滑块 526 宽，离底槽左边 9）
    drag = { id: e.pointerId, x, start: thumbAt, onThumb: x >= left && x <= left + 526, moved: false };
    showArt(thumb, 'pressed');
    haptic('press');
  });
  mode.addEventListener('pointermove', e => {
    if (!drag || e.pointerId !== drag.id) return;
    const x = at(e);
    if (!drag.moved && Math.abs(x - drag.x) < 20) return;   // 20 个单位 ≈ 6 像素：手抖不算拖
    drag.moved = true;
    mode.classList.add('dragging');
    // 按在滑块上：跟着手指走；按在另一边：滑块的中间跟着手指
    placeThumb(drag.onThumb ? drag.start + (x - drag.x) / THUMB_TRAVEL : (x - 9 - 263) / THUMB_TRAVEL);
  });
  const finish = (e, cancelled) => {
    if (!drag || e.pointerId !== drag.id) return;
    const target = cancelled ? drag.start : drag.moved ? Math.round(thumbAt) : (at(e) < 540 ? 0 : 1);
    drag = null;
    mode.classList.remove('dragging');
    showArt(thumb);
    tab(target ? 'touch' : 'click');
  };
  mode.addEventListener('pointerup', e => finish(e, false));
  mode.addEventListener('pointercancel', e => finish(e, true));
  // 键盘 / 辅助功能：点了哪个就是哪个
  $('#tab-click').addEventListener('click', e => { if (e.detail === 0) tab('click'); });
  $('#tab-touch').addEventListener('click', e => { if (e.detail === 0) tab('touch'); });
  // 打开时先是哪一个：设置里选的，或者上次用的那个
  const start = startIn.get();
  let first = start;
  if (start === 'last') { try { first = localStorage.getItem('mactvTab') === 'touch' ? 'touch' : 'click'; } catch { first = 'click'; } }
  tab(first, false);
})();

// 滑动：触控板上的双指滑动和点按区上的滑动都这样送（和 Siri Remote 一样，交给 Mac 上同一套滑动规则，
// 见 TrackpadGestures）。几个阶段按顺序送；同一阶段里连着的移动合在一起送，一条都不丢。
// 手指滑着离开：接着送"惯性"，一帧一帧慢下来（像 Mac 的触控板）；手指再放上去就停。
// 点按区上的滑动每一条都带着 focus: true：Mac 上焦点跟着手指走（像 Siri Remote）；
// 触控板上的双指滑动不带，内容跟着手指走（像 Mac 的触控板）
const swipe = (() => {
  const queue = [];
  let busy = false, focus = false;
  const put = (p, dx = 0, dy = 0) => {
    const last = queue[queue.length - 1];
    if (last && last.p === p && last.focus === focus && (p === 'changed' || p === 'momentum')) { last.dx += dx; last.dy += dy; }
    else queue.push({ p, dx, dy, focus });
    pump();
  };
  const pump = async () => {
    if (busy) return;
    busy = true;
    while (queue.length) {
      const item = queue.shift();
      const body = { a: 'swipe', p: item.p, dx: Math.round(item.dx * 10) / 10, dy: Math.round(item.dy * 10) / 10 };
      if (item.focus) body.focus = true;
      await api('/cmd', body).catch(() => {});
    }
    busy = false;
  };
  // 惯性：手指离开时的速度（最后 90 毫秒走了多远），一帧一帧慢下来
  let inertia = 0, samples = [];
  const glide = () => {
    const now = performance.now();
    const recent = samples.filter(s => now - s.t < 90);
    if (recent.length < 2) { put('momentumEnd'); return; }
    const dt = Math.max(16, recent[recent.length - 1].t - recent[0].t);
    const velocity = { x: recent.reduce((a, s) => a + s.dx, 0) / dt, y: recent.reduce((a, s) => a + s.dy, 0) / dt };
    if (Math.hypot(velocity.x, velocity.y) < 0.25) { put('momentumEnd'); return; }
    let last = now, acc = { x: 0, y: 0 }, sentAt = now;
    const frame = t => {
      const step = Math.min(50, t - last); last = t;
      const decay = Math.pow(0.9965, step);          // 每毫秒慢一点（像 Mac 的惯性）
      velocity.x *= decay; velocity.y *= decay;
      acc.x += velocity.x * step; acc.y += velocity.y * step;
      if (t - sentAt >= 33) { put('momentum', acc.x, acc.y); acc = { x: 0, y: 0 }; sentAt = t; }
      if (Math.hypot(velocity.x, velocity.y) < 0.04) { inertia = 0; put('momentumEnd'); return; }
      inertia = requestAnimationFrame(frame);
    };
    inertia = requestAnimationFrame(frame);
  };
  return {
    // followsFinger：点按区（焦点跟着手指走）；触控板不传
    began(followsFinger = false) { samples = []; focus = followsFinger; put('began'); },
    // 移动了多少（点；往左 / 往上为负）
    moved(dx, dy) {
      samples.push({ t: performance.now(), dx, dy });
      if (samples.length > 12) samples.shift();
      put('changed', dx, dy);
    },
    // coast：手指是滑着抬起来的，接着是惯性；被系统收走、被一下按键打断的不甩
    ended(coast) { put('ended'); if (coast) glide(); else put('momentumEnd'); },
    // 手指放上去：正在甩的惯性停下
    stop() {
      if (!inertia) return;
      cancelAnimationFrame(inertia); inertia = 0;
      put('momentumEnd');
    },
  };
})();

// Clickpad：点外圈的四边走一格（按住一直走），绕着外圈转是转盘，在上面任何地方滑是滑动（和 Siri Remote 的
// 触控面一样：焦点跟着手指走，松手接着甩），点中间是确认（按住是菜单）；点在外圈外面什么都不做。
// 手指按着哪一块，哪一块就是按下的样子：中间一种；外圈按手指的方向分八种（压下去那边暗、对面亮一点），
// 手指在外圈上挪动、转圈时跟着手指走
(() => {
  const pad = $('#clickpad'), ring = pad.querySelector('.ring');
  const ringArt = $('#ring-art'), centerArt = $('#center-art');
  const DIRS = ['right', 'down-right', 'down', 'down-left', 'left', 'up-left', 'up', 'up-right'];
  const CENTER = 62.05 / 109.35;   // 中间的确认键（连同它的细边）占外圈半径的比例（设计稿）
  pad.querySelectorAll('button').forEach(button => button.addEventListener('click', e => {
    // 手指的按法在下面按位置算；这里只接键盘 / 辅助功能（detail = 0）
    if (e.detail === 0) press.tap(button.dataset.dir || 'select');
  }));
  // 手指相对转盘圆心的方向和距离；外圈的半径
  const where = (x, y) => {
    const r = ring.getBoundingClientRect();
    const cx = x - (r.left + r.width / 2), cy = y - (r.top + r.height / 2);
    return { angle: Math.atan2(cy, cx), off: Math.hypot(cx, cy), radius: r.width / 2 };
  };
  const dir8 = angle => DIRS[(Math.round(angle / (Math.PI / 4)) + 8) % 8];
  const dir4 = angle => DIRS[((Math.round(angle / (Math.PI / 2)) + 4) % 4) * 2];
  // 按在哪一块：'ok'（中间）、外圈的上下左右，或者 null（外圈外面）
  const zoneAt = (x, y) => {
    const { angle, off, radius } = where(x, y);
    if (off < radius * CENTER + 8) return 'ok';
    if (off > radius + 6) return null;
    return dir4(angle);
  };
  // 显示按下的样子：'ok'、外圈的八个方向之一，或 null（都松开）
  let shown = null;
  const show = part => {
    if (part === shown) return;
    shown = part;
    showArt(ringArt, part && part !== 'ok' ? 'pressed-' + part : 'normal');
    showArt(centerArt, part === 'ok' ? 'pressed' : 'normal');
  };

  // 认手势（和 Siri Remote 的触控面一个做法，见 SiriRemote.swift 的 SiriRemoteTouch）：
  //   手指放在外圈或中间上先是"按"：没挪开就松手是点了一下；按着不动是按住（方向 0.35 秒、OK 0.5 秒，和键盘一样。
  //   按住以后由 Mac 按那个键的规矩来做：方向一直走，网易云播放界面里快进 / 快退；OK 是卡片菜单 / 右边的面板）。
  //   按住了就是按键：手指再怎么挪都不转、不滑，直到松开。手指挪开了（SLOP）就不再是按，松手也不算点了一下。
  //   挪动的这一段先什么都不发，直到看得出是
  //     转盘：手指一直离圆心够远，0.6 秒里绕了至少 25 度（这一段不算格数）；
  //     滑动：四分之一秒里走过转盘直径的 22%。跟着手指送（见 swipe），松手接着甩。
  //   比这慢的（拇指搭着慢慢挪、手指一滚）什么都不是：0.6 秒还没认出来就从这里重新算。
  //   另一根手指按下来是一下按键，它说了算：前一根手指正在滑的停下（不甩），正在转的停下。
  // 转盘（和 iPod 的点按转盘一样）：每转过一格送一格，顺时针 = 往后 / 往下 / 快进，逆时针相反。
  // 离圆心太近（中间的 OK 上）角度乱跳，不算
  const WHEEL_UNIT = 0.384;          // 每格的弧度（22 度，一圈 16 格：手机上的转盘大，比 Siri Remote 的格子密）
  const TURN_START = 25 * Math.PI / 180, TURN_SPAN = 600;
  const SWIPE_WINDOW = 250, SWIPE_DISTANCE = 0.22;
  // 滑过整个转盘直径算多少点：和 Siri Remote 滑过整个触控面一样（SiriRemoteTouch.swipeScale）
  const SWIPE_POINTS = 500;
  const SLOP = 24;                   // 手指挪了这么多（像素）就不算按了
  // 占转盘直径的比例：离圆心这么近不算角度；转圈时手指一直离圆心至少这么远
  // （转盘的直径，不是整块点按区：那块比转盘宽，会把界线挤到外圈最边上）
  const DEAD = 0.19, RING = 0.28;
  const turnBy = (a, b) => { let d = b - a; if (d > Math.PI) d -= Math.PI * 2; if (d < -Math.PI) d += Math.PI * 2; return d; };
  const keyOf = zone => zone === 'ok' ? 'select' : zone;
  // 手指的一个位置：在哪、什么时候、离圆心多远、什么角度，和转盘的直径
  const sample = e => {
    const { angle, off, radius } = where(e.clientX, e.clientY);
    return { x: e.clientX, y: e.clientY, t: performance.now(), angle, off, size: radius * 2 };
  };
  // 还没认出来的这一段
  const stroke = p => ({ startedAt: p.t, points: [p], last: p, sweep: 0, minOff: p.off });
  // 按在点按区上的手指（一次只认一根）
  let finger = null;
  const notPress = f => { f.pressing = false; clearTimeout(f.timer); f.timer = 0; };
  const turnWheel = (f, p) => {
    show(dir8(p.angle));               // 转盘：按下的那一块跟着手指转
    if (p.off >= p.size * DEAD && f.last.off >= p.size * DEAD) {
      f.sum += turnBy(f.last.angle, p.angle);
      const steps = Math.trunc(f.sum / WHEEL_UNIT);
      if (steps) {
        f.sum -= steps * WHEEL_UNIT;
        for (let i = 0; i < Math.abs(steps); i++) sendWheel(Math.sign(steps));
      }
    }
    f.last = p;
  };
  pad.addEventListener('pointerdown', e => {
    pad.setPointerCapture(e.pointerId);
    swipe.stop();                      // 手指放上去：滑完的惯性停下
    end(false);                        // 另一根手指按下来：前一根手指的滑动、转圈、按都停下
    const p = sample(e), zone = zoneAt(e.clientX, e.clientY);
    const f = finger = { id: e.pointerId, zone, from: p, pressing: !!zone, held: false, timer: 0, gesture: null,
                         stroke: stroke(p), last: p, sum: 0 };
    if (!zone) return;
    // 按下的那一刻：按下的样子、震一下
    show(zone === 'ok' ? 'ok' : dir8(p.angle));
    haptic('press');
    f.timer = setTimeout(() => { f.timer = 0; f.held = true; press.hold(keyOf(zone)); }, zone === 'ok' ? 500 : 350);
  });
  pad.addEventListener('pointermove', e => {
    const f = finger;
    if (!f || e.pointerId !== f.id) return;
    const p = sample(e);
    if (f.pressing && Math.hypot(p.x - f.from.x, p.y - f.from.y) > SLOP) notPress(f);   // 挪开了：不是按了
    const follow = () => { if (f.zone && f.zone !== 'ok') show(dir8(p.angle)); };   // 按在外圈上挪动：按下的方向跟着手指
    if (f.held) { follow(); return; }  // 按住了：是按键，手指怎么挪都不算
    if (f.gesture === 'turn') { turnWheel(f, p); return; }
    if (f.gesture === 'swipe') {
      const scale = SWIPE_POINTS / p.size;
      swipe.moved((p.x - f.last.x) * scale, (p.y - f.last.y) * scale);
      f.last = p;
      follow();
      return;
    }
    // 还没认出来：先看是不是在转，再看是不是在滑
    const s = f.stroke;
    if (p.off >= p.size * DEAD && s.last.off >= p.size * DEAD) s.sweep += turnBy(s.last.angle, p.angle);
    s.points.push(p);
    s.last = p;
    s.minOff = Math.min(s.minOff, p.off);
    if (s.minOff >= p.size * RING && Math.abs(s.sweep) >= TURN_START) {
      notPress(f);
      f.gesture = 'turn';
      f.last = p;
      show(dir8(p.angle));
      return;
    }
    const from = s.points.find(q => p.t - q.t <= SWIPE_WINDOW);
    if (Math.hypot(p.x - from.x, p.y - from.y) >= p.size * SWIPE_DISTANCE) {
      notPress(f);
      f.gesture = 'swipe';
      f.last = p;
      if (!f.zone) haptic('tick');     // 滑起来了：按下时没震过（按在转盘外面）才轻轻震一下，一下不震两次
      const scale = SWIPE_POINTS / p.size;
      swipe.began(true);               // 焦点跟着手指走（和 Siri Remote 一样）
      swipe.moved((p.x - from.x) * scale, (p.y - from.y) * scale);
      follow();
      return;
    }
    if (p.t - s.startedAt > TURN_SPAN) f.stroke = stroke(p);   // 慢慢挪：从这里重新算
    follow();
  });
  // 手指离开（lifted：是抬起来的），或者这一下被打断了（被系统收走、页面切走、另一根手指按下来）
  function end(lifted) {
    const f = finger;
    if (!f) return;
    finger = null;
    clearTimeout(f.timer);
    show(null);
    if (f.held) press.release(keyOf(f.zone));                  // 按住过：松开
    else if (f.gesture === 'swipe') swipe.ended(lifted);       // 滑着抬起来的接着甩；被打断的不甩
    else if (lifted && f.pressing) press.tap(keyOf(f.zone));   // 没挪开就松手：点了一下
  }
  pad.addEventListener('pointerup', e => { if (finger && e.pointerId === finger.id) end(true); });
  const cancel = e => { if (finger && e.pointerId === finger.id) end(false); };
  pad.addEventListener('pointercancel', cancel);
  pad.addEventListener('lostpointercapture', cancel);
  document.addEventListener('visibilitychange', () => { if (document.visibilityState !== 'visible') { end(false); swipe.stop(); } });
})();

// 触控板：和 Mac 的触控板一样。
//   一根手指：移动鼠标；点一下 = 点击；按住不动半秒 = 鼠标按住（长按出菜单的地方出菜单）。
//   两根手指滑：和在 Mac 触控板上双指滑一样——交给 Mac 上同一套滑动规则（长条一甩带惯性、挑选一次一格、
//   抽屉、拖进度），手指离开后手机接着送"惯性"，慢慢停下，和触控板的手感一样。
// 触控板是一块固定的板，没有按下的样子：点一下（= 点击）时震一下（iPhone 上是盖着的开关震）
(() => {
  const tp = $('#touchpad');
  const fingers = new Map();
  const GAIN = 1.4;                 // 手机上滑多远，相当于 Mac 触控板上滑多远
  let travel = 0, downAt = 0, multi = false, holdTimer = 0, held = false;
  // 一根手指：鼠标移动（快的时候走得更远，和触控板的加速一样）。攒到下一帧一起送（一秒六十包上下）；
  // 移动是"往哪挪多少"，先到后到加起来都一样，所以不用等上一包回来：最多同时 3 包在路上，一包不丢。
  // 以前是一包回来才送下一包，一秒只到二三十包、还不匀，Mac 上的光标一顿一顿的（Mac 那边还会把每包
  // 摊到屏幕的每一帧里走，见 PointerGlide）
  const POINTER_IN_FLIGHT = 3;
  let pointerAcc = { dx: 0, dy: 0 }, pointerFrame = 0, pointerInFlight = 0, pointerIdle = [];
  const sendPointer = () => {
    if (pointerInFlight >= POINTER_IN_FLIGHT) return;   // 有一包回来时接着送
    const dx = Math.round(pointerAcc.dx * 10) / 10, dy = Math.round(pointerAcc.dy * 10) / 10;
    if (!dx && !dy) {
      if (!pointerInFlight) { pointerIdle.forEach(done => done()); pointerIdle = []; }
      return;
    }
    pointerAcc.dx -= dx; pointerAcc.dy -= dy;
    pointerInFlight++;
    api('/cmd', { a: 'pointer', dx, dy }).catch(() => {}).finally(() => {
      pointerInFlight--;
      if (pointerIdle.length) sendPointer(); else schedulePointer();
    });
  };
  const schedulePointer = () => {
    if (!pointerFrame) pointerFrame = requestAnimationFrame(() => { pointerFrame = 0; sendPointer(); });
  };
  // 攒着的移动马上全送出去，都送到了才好（点击要等它，免得点在挪之前的位置）
  const flushPointer = () => new Promise(done => {
    cancelAnimationFrame(pointerFrame); pointerFrame = 0;
    pointerIdle.push(done);
    sendPointer();
  });

  // 两根手指：滑动（怎么送、手指离开后的惯性，见上面的 swipe）
  const centre = () => {
    let x = 0, y = 0;
    for (const f of fingers.values()) { x += f.x; y += f.y; }
    return { x: x / fingers.size, y: y / fingers.size };
  };
  let swipeFrom = null;

  tp.addEventListener('pointerdown', e => {
    tp.setPointerCapture(e.pointerId);
    swipe.stop();                                    // 手指放上去：正在滑的惯性停下（和触控板一样）
    if (fingers.size === 0) {
      travel = 0; downAt = Date.now(); multi = false; held = false;
      clearTimeout(holdTimer);
      holdTimer = setTimeout(() => {                 // 一根手指按住不动：鼠标按住
        if (!multi && travel < 8 && fingers.size === 1) { held = true; haptic('hold'); send('mousehold'); }
      }, 500);
    }
    fingers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (fingers.size === 2) {                        // 第二根手指放上：开始一次双指滑动
      multi = true;
      clearTimeout(holdTimer);
      swipeFrom = centre();
      swipe.began();
    }
  });
  tp.addEventListener('pointermove', e => {
    const f = fingers.get(e.pointerId);
    if (!f) return;
    const dx = e.clientX - f.x, dy = e.clientY - f.y;
    f.x = e.clientX; f.y = e.clientY;
    travel += Math.abs(dx) + Math.abs(dy);
    if (fingers.size >= 2 && swipeFrom) {
      const c = centre();
      const mx = (c.x - swipeFrom.x) * GAIN, my = (c.y - swipeFrom.y) * GAIN;
      swipeFrom = c;
      if (mx || my) swipe.moved(mx, my);
    } else if (fingers.size === 1 && !multi && !held) {
      const gain = 1.6 + Math.min(Math.hypot(dx, dy) / 6, 3);
      pointerAcc.dx += dx * gain; pointerAcc.dy += dy * gain;
      schedulePointer();
    }
  });
  const lift = e => {
    if (!fingers.delete(e.pointerId)) return;
    if (swipeFrom && fingers.size < 2) {             // 双指离开：这次滑动结束，接着是惯性
      swipeFrom = null;
      swipe.ended(e.type === 'pointerup');
    }
    if (fingers.size === 0) {
      clearTimeout(holdTimer);
      if (e.type === 'pointerup' && !multi && !held && travel < 8 && Date.now() - downAt < 350) {
        haptic('press');                                   // 认出是点了一下就震，不等网络
        flushPointer().then(() => send('click'));          // 先把点之前的移动送到，再点
      }
    }
  };
  tp.addEventListener('pointerup', lift);
  tp.addEventListener('pointercancel', lift);
})();

// Old installations stored the shared six-digit code; exchange it automatically during migration.
const initialCode = /^\d{6}$/.test(qrCode) ? qrCode : (/^\d{6}$/.test(key) ? key : '');
if (initialCode) {
  if (/^\d{6}$/.test(key)) { key = ''; store.set(''); }
  pair(initialCode, 'Phone').catch(() => { $('#code').value = ''; showPair(); });
} else { refresh(); }
setInterval(() => { if (document.visibilityState === 'visible') refresh(); }, 3000);
document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') refresh(); });
