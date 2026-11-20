// Run with Node 22+: node Tests/WebPlayback/arrange.test.cjs
// The phone's Apps sheet › Edit, arranged as the iPhone Home Screen is: the TV's dock (Home's top row, its first six
// apps) in a frame on top, the other apps below, in Home's one order. First the rule on its own (the same as
// AppLibrary.move on the Mac), then the real page in an isolated headless browser: a long-press picks an app up,
// dragging it makes the others room, into a full dock its last app goes below (and comes back when the app leaves),
// the drop goes to the TV as one /apps/place, a quick swipe only scrolls, "−" offers Hide (and Delete for Everyone
// for an app someone added), a system app (Movies, Web) has no "−" but still moves in and out of the dock, the TV's
// own changes move the same tiles, and no star or hint text is left.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const vm = require('node:vm');
const { spawn } = require('node:child_process');
const { html, script } = require('./page.cjs');

// 1. The rule.
const section = script.slice(script.indexOf('let editing = false, dockSize = 6;'), script.indexOf('function appFocus()'));
assert.ok(section.includes('function placeApp') && section.includes('function reorderedApps'), 'the arranging rule is in remote.js');
const rules = { apps: [] };
vm.runInNewContext(section + '\nObject.assign(globalThis, { placeApp, reorderedApps, sameOrder, appOrder });', rules);
const order = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i'];
const dock = list => list.slice(0, 6), below = list => list.slice(6);
let moved = rules.placeApp(order, 'h', 2);
assert.deepEqual(dock(moved), ['a', 'b', 'h', 'c', 'd', 'e'], 'into the dock: the apps after it make room');
assert.deepEqual(below(moved), ['f', 'g', 'i'], 'the full dock’s last app goes to the first place below');
moved = rules.placeApp(order, 'b', 7);
assert.deepEqual(dock(moved), ['a', 'c', 'd', 'e', 'f', 'g'], 'out of the dock: the first app below comes up into it');
assert.deepEqual(below(moved), ['h', 'b', 'i']);
assert.deepEqual([...rules.placeApp(order, 'a', 99)].pop(), 'a', 'a place past the end is the last place');
// Each place is worked out from where the drag began, so an app pushed out comes back when the app moves on.
assert.ok(rules.sameOrder(rules.placeApp(order, 'h', 7), order) && !rules.sameOrder(rules.placeApp(order, 'h', 0), order));
rules.apps = order.map(id => ({ id, name: id.toUpperCase() }));
assert.deepEqual(rules.appOrder(rules.reorderedApps(['c', 'a', 'b'])), ['c', 'a', 'b'], 'the list follows the new order before the TV answers');
console.log('PASS arranging rule');

// 2. The page.
const candidates = [process.env.BROWSER_BIN, '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser', '/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser'];
const browser = candidates.find(file => file && fs.existsSync(file));
if (!browser) { console.log('SKIP arranging on the page: set BROWSER_BIN or install Chrome/Brave'); process.exit(0); }
if (!globalThis.WebSocket) { console.error('The page test needs Node 22 or newer'); process.exit(1); }
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'mactv-arrange-'));
fs.chmodSync(profile, 0o700);
const server = http.createServer((req, res) => { res.writeHead(200, { 'Content-Type': 'text/html' }); res.end(html); });
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
  const evaluate = async expression => {
    const result = await call('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    if (result.exceptionDetails) throw new Error(result.exceptionDetails.exception?.description || result.exceptionDetails.text);
    return result.result.value;
  };
  // MACTV_ARRANGE_SCREENSHOTS=<folder> keeps a picture of Edit at rest, mid-drag and with the "−" menu.
  const screenshotDir = process.env.MACTV_ARRANGE_SCREENSHOTS;
  const screenshot = async name => {
    if (!screenshotDir) return;
    fs.mkdirSync(screenshotDir, { recursive: true });
    const result = await call('Page.captureScreenshot', { format: 'png' });
    fs.writeFileSync(path.join(screenshotDir, name), Buffer.from(result.data, 'base64'));
  };
  await call('Page.enable'); await call('Runtime.enable');
  // The TV: its state, and the arranging routes doing what the Mac does (the page's own rule stands in for it).
  await call('Page.addScriptToEvaluateOnNewDocument', { source: `
    localStorage.setItem('mactvKey', 'a'.repeat(64));
    const app = id => ({ id, name: id[0].toUpperCase() + id.slice(1), icon: false, added: id === 'site', system: id === 'movies' });
    window.testState = { apps: ['one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'site', 'movies'].map(app),
      dockSize: 6, canRestore: false, autoSkip: false, autoNext: false, keepMacAwake: false, lidOverride: false, displaySetup: { displays: [] } };
    window.posts = []; window.vibrations = [];
    navigator.vibrate = pattern => { window.vibrations.push(pattern); return true; };
    window.confirm = message => { window.asked = message; return true; };
    window.fetch = async (path, options = {}) => {
      const body = options.body ? JSON.parse(options.body) : null;
      if (path.startsWith('/apps/')) {
        window.posts.push({ path, body });
        if (path === '/apps/place') {
          const byId = new Map(testState.apps.map(a => [a.id, a]));
          testState.apps = placeApp(testState.apps.map(a => a.id), body.id, body.index).map(id => byId.get(id));
        }
        if (path === '/apps/remove' || path === '/apps/delete') testState.apps = testState.apps.filter(a => a.id !== body.id);
      }
      const reply = path === '/state' ? JSON.parse(JSON.stringify(testState)) : { ok: true };
      return { status: 200, ok: true, json: async () => reply };
    };
  ` });
  await call('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 2, mobile: true });
  await call('Emulation.setTouchEmulationEnabled', { enabled: true, maxTouchPoints: 5 });
  await call('Page.navigate', { url: `http://127.0.0.1:${server.address().port}/` });
  await delay(700);
  const layout = () => evaluate(`({ dock: [...document.querySelectorAll('#apps .dock .app')].map(t => t.dataset.appId),
    below: [...document.querySelectorAll('#apps > .app-grid .app')].map(t => t.dataset.appId) })`);
  const centre = id => evaluate(`(() => { const r = document.querySelector('#apps [data-app-id="${id}"] .tile').getBoundingClientRect();
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; })()`);
  const touch = (type, x, y) => call('Input.dispatchTouchEvent', { type, touchPoints: type === 'touchEnd' ? [] : [{ x, y }] });
  const glide = async (from, to, steps = 10) => {
    for (let i = 1; i <= steps; i++) { await touch('touchMove', from.x + (to.x - from.x) * i / steps, from.y + (to.y - from.y) * i / steps); await delay(16); }
  };

  await evaluate(`document.querySelector('#open-apps').click()`); await delay(700);
  const plain = await evaluate(`({ dock: !!document.querySelector('#apps .dock'), star: !!document.querySelector('#apps .favourite'),
    labels: [...document.querySelectorAll('#apps .app')].map(b => b.getAttribute('aria-label') || '').join('|') })`);
  assert.ok(!plain.dock && !plain.star, 'Open on TV is a plain grid with no stars');
  assert.ok(!/favorite/i.test(plain.labels), 'no app is called a favorite');
  await evaluate(`document.querySelector('#edit-apps').click()`); await delay(100);
  const start = await layout();
  assert.deepEqual(start, { dock: ['one', 'two', 'three', 'four', 'five', 'six'], below: ['seven', 'eight', 'nine', 'site', 'movies'] },
    'Edit: Home’s first six apps in the dock, the rest below');
  const look = await evaluate(`(() => { const d = document.querySelector('#apps .dock'), t = d.querySelector('.tile'), s = getComputedStyle(t);
    return { jiggle: s.animationName, iteration: s.animationIterationCount, badge: !!t.querySelector('.hide-badge .sign.minus'),
      only: d.children.length === 1 && d.firstElementChild.classList.contains('app-grid'),
      names: getComputedStyle(d.querySelector('.name')).display,
      text: document.querySelector('#apps-sheet .sheet').innerText }; })()`);
  assert.equal(look.jiggle, 'jiggle', 'icons jiggle while editing');
  assert.equal(look.iteration, 'infinite');
  assert.ok(look.badge, 'each icon has the “−” badge');
  assert.ok(look.only, 'the dock frame holds only its row: no title');
  assert.equal(look.names, 'none', 'the dock shows icons without names, as the TV’s top row does');
  assert.ok(!/Favorites|Drag apps|Move apps/.test(look.text), 'no Favorites title and no hint text');
  await delay(600);
  await screenshot('phone-edit.png');

  // A quick swipe that starts on an app scrolls; it doesn't pick the app up.
  const nine = await centre('nine');
  await touch('touchStart', nine.x, nine.y);
  await glide(nine, { x: nine.x, y: nine.y - 120 }, 6);
  await touch('touchEnd');
  await delay(400);
  assert.equal(await evaluate(`document.querySelectorAll('#apps .lifted').length`), 0, 'a quick swipe does not lift an app');
  assert.equal(await evaluate('posts.length'), 0);
  await evaluate(`document.querySelector('#apps-sheet .sheet').scrollTop = 0`); await delay(50);

  // Long-press "eight", drag it into the full dock's third place, back out, and in again; drop it there.
  await evaluate('vibrations.length = 0');
  const eight = await centre('eight'), third = await centre('three');
  await touch('touchStart', eight.x, eight.y);
  await delay(420);
  assert.equal(await evaluate(`document.querySelector('#apps [data-app-id="eight"]').classList.contains('lifted')`), true, 'a long press lifts the app');
  assert.deepEqual(await evaluate('vibrations'), [22], 'one haptic on pick-up');
  await glide(eight, third);
  await delay(50);
  let now = await layout();
  assert.deepEqual(now.dock, ['one', 'two', 'eight', 'three', 'four', 'five'], 'the apps in the dock make room');
  assert.equal(now.below[0], 'six', 'the full dock’s last app goes to the first place below');
  assert.ok((await evaluate('vibrations')).slice(1).every(v => v === 8) && (await evaluate('vibrations.length')) > 1, 'a tick each time the others make room');
  const lifted = await evaluate(`(() => { const r = document.querySelector('#apps [data-app-id="eight"] .tile').getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; })()`);
  assert.ok(Math.hypot(lifted.x - third.x, lifted.y - third.y) < 14, 'the lifted icon stays under the finger');
  await delay(350);
  await screenshot('phone-drag-into-full-dock.png');
  const lower = await evaluate(`(() => { const r = document.querySelector('#apps > .app-grid').getBoundingClientRect(); return { x: r.left + 20, y: r.bottom - 20 }; })()`);
  await glide(third, lower);
  await delay(50);
  now = await layout();
  assert.deepEqual(now.dock, ['one', 'two', 'three', 'four', 'five', 'six'], 'leaving the dock gives the pushed-out app its place back');
  assert.ok(now.below.includes('eight'));
  await glide(lower, third);
  await delay(50);
  await evaluate('vibrations.length = 0');
  await touch('touchEnd');
  await delay(500);
  assert.deepEqual(await evaluate('vibrations'), [22], 'one haptic on the drop');
  assert.deepEqual(await evaluate('posts'), [{ path: '/apps/place', body: { id: 'eight', index: 2 } }], 'the drop is one move on the TV');
  now = await layout();
  assert.deepEqual(now, { dock: ['one', 'two', 'eight', 'three', 'four', 'five'], below: ['six', 'seven', 'nine', 'site', 'movies'] }, 'and it stays there');
  assert.equal(await evaluate(`document.querySelector('#apps [data-app-id="eight"]').style.transform`), '', 'the dropped icon settles in its place');

  // Moving an app out of the dock brings the first app below up into it.
  await evaluate('posts.length = 0');
  const one = await centre('one'), ninth = await centre('nine');
  await touch('touchStart', one.x, one.y);
  await delay(420);
  await glide(one, ninth);
  await delay(50);
  now = await layout();
  assert.deepEqual(now.dock, ['two', 'eight', 'three', 'four', 'five', 'six'], 'out of the dock: the first app below comes up');
  await touch('touchEnd');
  await delay(500);
  assert.equal((await evaluate('posts'))[0]?.path, '/apps/place');

  // The TV moves an app: the same tiles move here (no redraw).
  await evaluate(`window.seven = document.querySelector('#apps [data-app-id="seven"]');
    testState.apps = [testState.apps.find(a => a.id === 'seven'), ...testState.apps.filter(a => a.id !== 'seven')];
    refresh()`);
  await delay(100);
  now = await layout();
  assert.equal(now.dock[0], 'seven', 'a change on the TV shows here');
  assert.ok(await evaluate(`document.querySelector('#apps [data-app-id="seven"]') === window.seven`), 'by moving the tile it already had');

  // "−" on a built-in app: Hide only. On an app someone added: Hide and Delete for Everyone, which asks first.
  await evaluate('posts.length = 0');
  await evaluate(`document.querySelector('#apps [data-app-id="nine"] .hide-badge').click()`);
  await delay(50);
  assert.deepEqual(await evaluate(`[...document.querySelectorAll('#apps .app-menu button')].map(b => b.textContent)`), ['Hide'], 'a built-in app offers Hide');
  await evaluate(`document.querySelector('#apps [data-app-id="site"] .hide-badge').click()`);
  await delay(50);
  assert.deepEqual(await evaluate(`[...document.querySelectorAll('#apps .app-menu button')].map(b => b.textContent)`),
    ['Hide', 'Delete for Everyone'], 'an app someone added also offers Delete for Everyone');
  await screenshot('phone-remove-menu.png');
  await evaluate(`document.querySelector('#apps .app-menu .danger').click()`);
  await delay(200);
  assert.match(await evaluate('window.asked'), /^Delete “Site” for Everyone\?/, 'Delete for Everyone asks first');
  assert.deepEqual(await evaluate('posts'), [{ path: '/apps/delete', body: { id: 'site' } }]);
  assert.equal(await evaluate(`document.querySelector('#apps [data-app-id="site"]')`), null, 'the deleted app goes');
  await evaluate('posts.length = 0');
  await evaluate(`document.querySelector('#apps [data-app-id="nine"] .hide-badge').click()`);
  await delay(50);
  await evaluate(`document.querySelector('#apps .app-menu button').click()`);
  await delay(200);
  assert.deepEqual(await evaluate('posts'), [{ path: '/apps/remove', body: { id: 'nine' } }], 'Hide hides it here');
  assert.equal(await evaluate(`document.querySelector('#apps .app-menu')`), null, 'the menu goes');

  // A system app (Movies, Web) can never be hidden or deleted: no "−", and nothing reaches the TV if asked anyway.
  assert.equal(await evaluate(`document.querySelector('#apps [data-app-id="movies"] .hide-badge')`), null, 'a system app has no “−”');
  await evaluate('posts.length = 0');
  await evaluate(`(() => { const movies = apps.find(a => a.id === 'movies'); hideApp(movies); deleteApp(movies);
    appMenu(document.querySelector('#apps [data-app-id="movies"]'), movies); })()`);
  await delay(200);
  assert.deepEqual(await evaluate('posts'), [], 'a system app is never hidden or deleted from the phone');
  assert.equal(await evaluate(`document.querySelector('#apps .app-menu')`), null, 'and opens no menu');
  // It still moves: into the dock's first place, then back out below.
  await evaluate(`document.querySelector('#apps-sheet .sheet').scrollTop = 0`); await delay(50);
  let movies = await centre('movies');
  const first = await evaluate(`(() => { const r = document.querySelector('#apps .dock .app .tile').getBoundingClientRect();
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; })()`);
  await touch('touchStart', movies.x, movies.y);
  await delay(420);
  await glide(movies, first);
  await delay(50);
  await touch('touchEnd');
  await delay(500);
  assert.deepEqual(await evaluate('posts'), [{ path: '/apps/place', body: { id: 'movies', index: 0 } }], 'a system app moves into the dock');
  assert.equal((await layout()).dock[0], 'movies');
  await evaluate('posts.length = 0');
  movies = await centre('movies');
  const bottom = await evaluate(`(() => { const r = document.querySelector('#apps > .app-grid').getBoundingClientRect(); return { x: r.left + 20, y: r.bottom - 20 }; })()`);
  await touch('touchStart', movies.x, movies.y);
  await delay(420);
  await glide(movies, bottom);
  await delay(50);
  await touch('touchEnd');
  await delay(500);
  assert.equal((await evaluate('posts'))[0]?.path, '/apps/place', 'and out of it');
  now = await layout();
  assert.ok(!now.dock.includes('movies') && now.below.includes('movies'), 'back below the dock');

  // Done ends editing: the icons stop.
  await evaluate(`document.querySelector('#edit-apps').click()`); await delay(100);
  assert.equal(await evaluate(`document.querySelector('#apps .dock')`), null, 'Done ends editing');
  assert.equal(await evaluate(`getComputedStyle(document.querySelector('#apps .app .tile')).animationName`), 'none', 'nothing jiggles outside Edit');
  console.log('PASS arranging on the page: dock, long-press drag, make room, push out, pull up, drop, TV changes, hide, delete, system apps');
}
(async () => {
  try { await run(); }
  catch (error) { console.error(error); process.exitCode = 1; }
  finally {
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
