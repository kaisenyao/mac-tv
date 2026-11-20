// Run with Node 22+: node Tests/WebPlayback/layout.test.cjs
// Render the real remote in an isolated headless browser; no app or user profile is touched.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { spawn } = require('node:child_process');
const candidates = [process.env.BROWSER_BIN, '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser', '/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser'];
const browser = candidates.find(file => file && fs.existsSync(file));
if (!browser) { console.log('SKIP remote layout: set BROWSER_BIN or install Chrome/Brave'); process.exit(0); }
if (!globalThis.WebSocket) { console.error('Remote layout test requires Node 22 or newer'); process.exit(1); }
const { html } = require('./page.cjs');
const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map(match => match[1]);
assert.equal(new Set(ids).size, ids.length, 'remote controls have unique IDs');
const screenshotDir = process.env.MACTV_LAYOUT_SCREENSHOTS;
if (screenshotDir) fs.mkdirSync(screenshotDir, { recursive: true });
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'mactv-layout-'));
fs.chmodSync(profile, 0o700);
const server = http.createServer((req, res) => {
  if (req.url === '/appicon.png') { res.writeHead(200, { 'Content-Type': 'image/png' }); res.end(fs.readFileSync('Assets/AppIcon.png')); return; }
  res.writeHead(200, { 'Content-Type': 'text/html' }); res.end(html);
});
let child, socket, closeBrowser;
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function run() {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  child = spawn(browser, ['--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
    '--disable-background-networking', '--remote-debugging-address=127.0.0.1', '--remote-debugging-port=0',
    `--user-data-dir=${profile}`, 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
  const port = await new Promise((resolve, reject) => {
    let data = ''; const timer = setTimeout(() => reject(new Error('Browser did not start')), 15000);
    child.on('error', error => { clearTimeout(timer); reject(error); });
    child.on('exit', code => { clearTimeout(timer); reject(new Error(`Browser exited: ${code}`)); });
    child.stderr.on('data', chunk => { data += chunk; const m = data.match(/DevTools listening on ws:\/\/127\.0\.0\.1:(\d+)\//); if (m) { clearTimeout(timer); resolve(m[1]); } });
  });
  const target = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })).json();
  socket = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
  let seq = 0; const pending = new Map();
  socket.onmessage = e => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); } };
  const call = (method, params = {}) => new Promise((resolve, reject) => {
    const id = ++seq;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`CDP ${method} timed out`)); }, 5000);
    pending.set(id, m => { clearTimeout(timer); m.error ? reject(new Error(m.error.message)) : resolve(m.result); });
    socket.send(JSON.stringify({ id, method, params }));
  });
  closeBrowser = () => call('Browser.close');
  const screenshot = async name => {
    if (!screenshotDir) return;
    const result = await call('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false });
    fs.writeFileSync(path.join(screenshotDir, name), Buffer.from(result.data, 'base64'));
  };
  const evaluate = async expression => {
    const result = await call('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    if (result.exceptionDetails) throw new Error(result.exceptionDetails.text);
    return result.result.value;
  };
  await call('Page.enable'); await call('Runtime.enable');
  await call('Page.addScriptToEvaluateOnNewDocument', { source: `
    localStorage.setItem('mactvKey', 'a'.repeat(64));
    window.testState = { apps: [], canRestore: false, autoSkip: false, autoNext: false,
      keepMacAwake: false, lidOverride: false, displaySetup: { displays: [] } };
    window.sentCommands = [];
    window.fetch = async (path, options) => {
      if (path === '/cmd') {
        const body = JSON.parse(options.body);
        window.sentCommands.push(body.a === 'press' ? 'press:' + body.k + ':' + body.p : body.a);
      }
      return { status: 200, ok: true, json: async () => path === '/state' ? window.testState : [] };
    };
  ` });
  await call('Page.navigate', { url: `http://127.0.0.1:${server.address().port}/` });
  await delay(500);
  // A real finger-like tap (pointer events with a live pointer id), and what the page sent for it.
  const tapAt = async (x, y) => {
    const before = await evaluate('sentCommands.length');
    await call('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', clickCount: 1 });
    await call('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button: 'left', clickCount: 1 });
    await delay(30);
    return evaluate(`sentCommands.slice(${before}).join(' ')`);
  };
  const sizes = [[320,568],[375,667],[390,844],[430,932],[568,320],[844,390]];
  for (const [width, height] of sizes) {
    await call('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 1, mobile: true });
    // The clickpad is one ring: a finger is placed by position (centre = OK, the ring's four sides = arrows,
    // outside the ring = nothing). The five buttons on it are for the keyboard and VoiceOver only.
    const pad = await evaluate(`(() => {
      const ring = document.querySelector('#clickpad .ring');
      ring.scrollIntoView({ block: 'center' });
      const r = ring.getBoundingClientRect(), x = r.left + r.width / 2, y = r.top + r.height / 2;
      return { x, y, radius: r.width / 2, proxies: [...document.querySelectorAll('#clickpad .chev, #clickpad .ok')].map(b => {
        const p = b.getBoundingClientRect();
        return { label: b.getAttribute('aria-label') || '', pointer: getComputedStyle(b).pointerEvents,
          off: Math.hypot(p.left + p.width / 2 - x, p.top + p.height / 2 - y) };
      }) };
    })()`);
    const size = `${width}x${height}`;
    assert.equal(pad.proxies.length, 5, `${size}: four arrows and OK for the keyboard`);
    for (const proxy of pad.proxies) assert.ok(proxy.label && proxy.pointer === 'none' && proxy.off <= pad.radius, `${size}: labelled keyboard proxy on the ring`);
    assert.equal(await tapAt(pad.x, pad.y), 'press:select:tap', `${size}: centre is OK`);
    for (const [dx, dy] of [[-22, 0], [22, 0], [0, -22], [0, 22]]) {
      assert.equal(await tapAt(pad.x + dx, pad.y + dy), 'press:select:tap', `${size}: OK takes a 44px finger`);
    }
    for (const [dir, angle] of [['right', 0], ['down', Math.PI / 2], ['left', Math.PI], ['up', -Math.PI / 2]]) {
      const along = 0.8 * pad.radius, turn = 22 / along;   // 22px either side along the ring
      for (const a of [angle, angle - turn, angle + turn]) {
        assert.equal(await tapAt(pad.x + Math.cos(a) * along, pad.y + Math.sin(a) * along), `press:${dir}:tap`, `${size}: ${dir} side of the ring, 44px wide`);
      }
    }
    assert.equal(await tapAt(pad.x + pad.radius + 15, pad.y), '', `${size}: a tap outside the ring does nothing`);
    assert.equal(await evaluate(`(async () => { const before = sentCommands.length;
      document.querySelector('#clickpad .chev.up').click(); document.querySelector('#clickpad .ok').click();
      await new Promise(resolve => setTimeout(resolve, 30)); return sentCommands.slice(before).join(' '); })()`),
      'press:up:tap press:select:tap', `${size}: keyboard reaches the arrows and OK`);
    for (const mode of ['none', 'embedded', 'brave', 'iina']) {
      const geometry = await evaluate(`(async () => {
        testState.mode = ${mode === 'none' ? "'launcher'" : "'player'"};
        testState.externalBrowser = ${mode === 'brave' ? "{name:'Brave',service:'Video',accessibilityAllowed:true}" : 'null'};
        testState.externalPlayer = ${mode === 'iina' ? "{name:'IINA',status:'Playing'}" : 'null'};
        await refresh();
        const r = e => { const x=e.getBoundingClientRect(); return {w:x.width,h:x.height,top:x.top,bottom:x.bottom}; };
        scrollTo(0, 0);
        return { ring:r(document.querySelector('#clickpad .ring')), keys:[...document.querySelectorAll('.key')].map(r),
          tool:r(document.querySelector('.controls')), scroll:document.documentElement.scrollWidth,
          viewport:innerWidth, height:innerHeight, page:document.documentElement.scrollHeight,
          controls: ${mode === 'brave' ? "!document.querySelector('#browser-controls').hidden" : mode === 'iina' ? "!document.querySelector('#iina-controls').hidden" : 'true'} };
      })()`);
      const label = `${width}x${height} ${mode}`;
      assert.ok(Math.abs(geometry.ring.w - geometry.ring.h) < 1 && geometry.ring.w >= 100, `${label}: circular D-pad`);
      for (const key of geometry.keys) assert.ok(Math.abs(key.w-key.h) < 1 && key.w >= 44 && key.h >= 44, `${label}: circular 44px media key`);
      assert.ok(geometry.scroll <= geometry.viewport + 1, `${label}: no horizontal overflow`);
      assert.ok(geometry.controls, `${label}: active controls visible`);
      // The TV key is Home: drawn as a TV, named for VoiceOver, sent on a tap and from the keyboard.
      const home = await evaluate(`(async () => {
        const button = document.querySelector('[data-press="home"]');
        button.scrollIntoView({ block: 'center' });
        const rect = button.getBoundingClientRect(), before = sentCommands.length;
        button.click();
        await new Promise(resolve => setTimeout(resolve, 30));
        return { label: button.getAttribute('aria-label') || '', width: rect.width, height: rect.height,
          x: rect.left + rect.width / 2, y: rect.top + rect.height / 2,
          displayed: getComputedStyle(button).display !== 'none', keyboard: sentCommands.slice(before).join(' ') };
      })()`);
      assert.match(home.label, /\bHome\b/, `${label}: Home is labeled`);
      assert.ok(home.displayed && home.width >= 44 && home.height >= 44, `${label}: Home stays available`);
      assert.equal(home.keyboard, 'home', `${label}: Home sends its command from the keyboard`);
      assert.equal(await tapAt(home.x, home.y), 'home', `${label}: Home sends its command on a tap`);
      await evaluate('scrollTo(0, 0)');
      if (width === 320 && height === 568 && (mode === 'none' || mode === 'brave')) await screenshot(`320x568-${mode}.png`);
      if (mode === 'none' && height > width) assert.ok(geometry.tool.bottom <= geometry.height + 1, `${label}: portrait remote fits one screen`);
      // Whatever scrolls (the page in landscape, the column when Brave's or IINA's keys don't fit), the last
      // control can be brought into view.
      const reach = await evaluate(`(() => {
        const last = [...document.querySelectorAll('.controls, #browser-controls, #iina-controls')].filter(e => !e.hidden).pop();
        last.scrollIntoView({ block: 'end' });
        const r = last.getBoundingClientRect();
        document.querySelector('main').scrollTop = 0; scrollTo(0, 0); document.body.scrollTop = 0;
        return { top: r.top, bottom: r.bottom };
      })()`);
      assert.ok(reach.top >= -1 && reach.bottom <= geometry.height + 1, `${label}: controls scroll into view`);
    }
    const sheet = await evaluate(`(() => {
      document.querySelector('#open-text').click();
      const visible = s => { const e=document.querySelector(s), r=e.getBoundingClientRect(); return !!r.width && !!r.height && getComputedStyle(e).visibility !== 'hidden'; };
      const result = { visible: visible('#text-sheet'), website: visible('#website-address'), typing: visible('#typed'),
        websiteLabel: document.querySelector('#website-address').getAttribute('aria-label'),
        typingLabel: document.querySelector('#typed').getAttribute('aria-label'),
        width: document.documentElement.scrollWidth, viewport: innerWidth };
      return result;
    })()`);
    assert.ok(sheet.visible && sheet.website && sheet.typing && sheet.websiteLabel && sheet.typingLabel, `${width}x${height}: accessible text sheet`);
    assert.ok(sheet.width <= sheet.viewport + 1, `${width}x${height}: sheet does not overflow`);
    // It slides up and settles, and Done slides it away and then hides it.
    await delay(700);
    assert.equal(await evaluate(`getComputedStyle(document.querySelector('#text-sheet .sheet')).transform`), 'none', `${width}x${height}: sheet settles open`);
    if (width === 390 && height === 844) await screenshot('390x844-text-sheet.png');
    await evaluate(`document.querySelector('#text-sheet [data-close]').click()`);
    assert.equal(await evaluate(`document.querySelector('#text-sheet').className`), 'scrim closing', `${width}x${height}: sheet slides away`);
    await delay(500);
    assert.equal(await evaluate(`getComputedStyle(document.querySelector('#text-sheet')).display`), 'none', `${width}x${height}: sheet hidden after closing`);
    console.log(`PASS remote layout ${width}x${height}`);
  }

  // Lists in sheets scroll under a finger that starts on a row, as on iOS. The page as an iPhone gets it (with
  // the invisible system switch over every button that gives the haptic) and real touches: a drag scrolls the
  // list and neither opens the row nor flips a switch; a tap opens it once and flips one switch; pulling the
  // header down still puts the sheet away.
  await call('Emulation.setUserAgentOverride', { userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1' });
  await call('Emulation.setTouchEmulationEnabled', { enabled: true, maxTouchPoints: 5 });
  await call('Emulation.setDeviceMetricsOverride', { width: 375, height: 667, deviceScaleFactor: 2, mobile: true });
  await call('Page.navigate', { url: `http://127.0.0.1:${server.address().port}/` });
  await delay(700);
  const touch = async (x, ys) => {
    await call('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x, y: ys[0] }] });
    for (const y of ys.slice(1)) { await call('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x, y }] }); await delay(16); }
    await call('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
    await delay(450);
  };
  const look = () => evaluate(`(() => {
    const sheet = document.querySelector('#settings-sheet .sheet'), row = document.querySelector('[data-page="page-display"]'), r = row.getBoundingClientRect();
    return { scroll: sheet.scrollTop, room: sheet.scrollHeight - sheet.clientHeight, x: r.left + 60, y: r.top + r.height / 2,
      overlay: !!row.querySelector(':scope > .haptic'), page: [...document.querySelectorAll('#settings-sheet .page')].find(p => !p.hidden && !p.classList.contains('leaving')).id,
      open: document.querySelector('#settings-sheet').classList.contains('show'),
      switches: [...document.querySelectorAll('.haptic input')].filter(i => i.checked).length,
      head: (h => ({ left: h.left, top: h.top }))(document.querySelector('#settings-main h2').getBoundingClientRect()) };
  })()`);
  await evaluate(`openSettings()`); await delay(700);
  let s = await look();
  assert.ok(s.overlay && s.room > 100, 'an iPhone gets the haptic switches; Settings is longer than the screen');
  const switches = s.switches;
  // (the finger rests before it lifts, so the list doesn't fling on: a tap during a fling only stops it)
  await touch(s.x, [...Array.from({ length: 11 }, (_, i) => s.y - i * 15), ...Array(12).fill(s.y - 150)]);
  const scrolled = await look();
  assert.ok(scrolled.scroll > 60, `a drag that starts on a row scrolls the list (${scrolled.scroll}px)`);
  assert.equal(scrolled.page, 'settings-main', 'the drag does not open the row');
  assert.equal(scrolled.switches, switches, 'the drag does not flip a haptic switch');
  await touch(scrolled.x, [scrolled.y]);
  await delay(300);                              // the push to the next page finishes
  const tapped = await look();
  assert.equal(tapped.page, 'page-display', 'a tap opens the row');
  assert.equal(tapped.switches, switches + 1, 'a tap flips one haptic switch');
  await evaluate(`goBack(); document.querySelector('#settings-sheet .sheet').scrollTop = 0`); await delay(600);
  s = await look();
  await touch(s.head.left + 20, Array.from({ length: 12 }, (_, i) => s.head.top + 10 + i * 30));
  assert.equal((await look()).open, false, 'pulling the header down puts the sheet away');
  console.log('PASS sheet lists scroll under a finger on a row; taps and pull-down still work');
}
(async () => {
  try { await run(); }
  catch (error) { console.error(error); process.exitCode = 1; }
  finally {
    // Graceful browser shutdown lets its helpers flush and close the profile too.
    // Killing only the parent can leave a helper recreating files during removal.
    if (closeBrowser && child?.exitCode === null && child?.signalCode === null) {
      try { await closeBrowser(); } catch { /* The browser can close CDP before replying. */ }
      if (child.exitCode === null && child.signalCode === null) {
        await Promise.race([new Promise(resolve => child.once('exit', resolve)), delay(3000)]);
      }
    }
    if (socket) socket.close();
    if (child && child.exitCode === null && child.signalCode === null) {
      child.kill('SIGTERM');
      await Promise.race([new Promise(resolve => child.once('exit', resolve)), delay(3000)]);
      if (child.exitCode === null && child.signalCode === null) { child.kill('SIGKILL'); await new Promise(resolve => child.once('exit', resolve)); }
    }
    await new Promise(resolve => server.close(resolve));
    await fs.promises.rm(profile, { recursive: true, force: true, maxRetries: 20, retryDelay: 150 });
  }
})();
