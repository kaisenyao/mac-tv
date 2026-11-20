// Run with: node Tests/WebPlayback/transport.test.cjs
// Exercise the page's transport, command queue, refresh scheduler, pairing recovery and clickpad holds with
// controlled slow responses.
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { script: source } = require('./page.cjs');
const section = (from, to) => {
  const start = source.indexOf(from), end = source.indexOf(to, start);
  assert.ok(start >= 0 && end > start, `${from} … ${to} is in remote.js`);
  return source.slice(start, end);
};
const transport = section('// A timed-out POST', '// State: connection');
const refresh = section('let stateInFlight = null;', 'async function readState()');
assert.ok(transport.includes('function request') && transport.includes('function send') && refresh.includes('function refresh'));
const requests = [], calls = [], errors = [], storage = [];
let readCount = 0, finishRead, finishFetch;
const context = vm.createContext({
  AbortController, Promise, Error, Math, JSON,
  setTimeout: (fn, ms) => setTimeout(fn, ms === 9000 ? 30 : ms), clearTimeout,
  fetch: (path, options) => {
    requests.push({ path, options });
    return new Promise((resolve, reject) => {
      finishFetch = resolve;
      options.signal.addEventListener('abort', () => reject(new Error('aborted')), { once: true });
    });
  },
  store: { set: value => storage.push(value) }, showPair: () => calls.push('pair'),
  haptic() {}, online: ok => errors.push(ok),
  readState: () => { readCount++; return new Promise(resolve => { finishRead = resolve; }); },
});
vm.runInContext("let key = 'original'; let appMutationPending = false;" + transport + refresh, context);
const run = code => vm.runInContext(code, context);
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
const commands = () => requests.filter(r => r.path === '/cmd');
const body = r => JSON.parse(r.options.body);
const ok = () => finishFetch({ status: 200, ok: true, json: async () => ({ ok: true }) });
// Answer the command on the way, and each one the queue sends after it, until it is empty.
const drain = async () => { for (let i = 0; i < 50 && run('activeCommand !== null'); i++) { ok(); await wait(0); } };
(async () => {
  const timeout = run("api('/files/play', {id:'video'})");
  await assert.rejects(timeout, /timed out|aborted/);
  assert.equal(requests.length, 1, 'timed-out POST is not replayed');
  assert.equal(requests[0].options.signal.aborted, true);

  const old = run('refresh()');
  const concurrent = run('refresh()');
  assert.equal(readCount, 1, 'concurrent polls share a single request');
  run('appMutationPending = true');
  const reconcile = run('refresh(true)');
  assert.equal(readCount, 1, 'edit waits for the older read');
  finishRead(false); await old; await concurrent; await wait(0);
  assert.equal(readCount, 2, 'edit gets a fresh reconciliation read');
  finishRead(true); assert.equal(await reconcile, true);
  run('appMutationPending = false');

  // One command at a time. A held key's repeats (volume, "still holding") are dropped while one is on the
  // way; taps and the press / hold / release of a key never are, however many wait.
  const first = run("send('volup', {}, true)");
  for (let i = 0; i < 20; i++) run("send('volup', {}, true)");
  for (const p of ['tap', 'hold', 'release']) run(`send('press', { k: 'up', p: '${p}' })`);
  for (let i = 0; i < 8; i++) run("send('press', { k: 'down', p: 'tap' })");
  run("send('press', { k: 'up', p: 'alive' }, true)");
  await wait(0);
  assert.equal(commands().length, 1, 'repeat traffic is dropped while busy');
  await drain(); await first;
  const sent = commands().map(body);
  assert.deepEqual(sent.map(b => b.a === 'press' ? `${b.k}:${b.p}` : b.a),
    ['volup', 'up:tap', 'up:hold', 'up:release', ...Array(8).fill('down:tap')], 'presses are kept in order, "alive" is dropped');

  // The clickpad wheel: ticks made while a command is on the way are added up and sent as one, at most 16
  // a time; none are lost.
  const before = commands().length;
  for (let i = 0; i < 20; i++) run('sendWheel(1)');
  await drain();
  const wheel = commands().slice(before).map(body);
  assert.ok(wheel.every(b => b.a === 'wheel' && Math.abs(b.d) <= 16), 'wheel steps are batched, 16 at most');
  assert.equal(wheel.reduce((n, b) => n + b.d, 0), 20, 'every wheel step arrives');
  assert.ok(wheel.length <= 3, 'wheel steps are merged while busy');

  // Home is urgent: it cancels the command on the way and everything waiting, wheel steps included.
  const busy = run("send('playpause')");
  run("send('press', { k: 'left', p: 'tap' })");
  run('sendWheel(1); sendWheel(1)');
  const urgent = run("send('home')");
  await wait(0);
  const cmd = commands();
  assert.equal(cmd.at(-2).options.signal.aborted, true, 'urgent command cancels old request');
  assert.equal(body(cmd.at(-1)).a, 'home');
  await drain();
  await Promise.all([busy, urgent]);
  assert.equal(body(commands().at(-1)).a, 'home', 'nothing queued before Home is sent after it');
  assert.deepEqual(errors, [], 'intentional cancellation is not an offline error');

  // An unchanged /state: the page sends the last ETag, the Mac answers 304 with no body, and the page uses its
  // last state again (a fresh copy: edits to an earlier answer don't leak into it).
  const stateAsks = () => requests.filter(r => r.path === '/state');
  const fresh = run("api('/state')");
  finishFetch({ status: 200, ok: true, headers: { get: name => name === 'ETag' ? '"t1"' : null }, json: async () => ({ apps: [1, 2] }) });
  const firstState = await fresh;
  assert.equal(stateAsks().at(-1).options.headers['If-None-Match'], undefined, 'the first poll has no tag to send');
  firstState.apps.push(3);
  const same = run("api('/state')");
  assert.equal(stateAsks().at(-1).options.headers['If-None-Match'], '"t1"');
  finishFetch({ status: 304, ok: false, json: async () => { throw new Error('304 has no body'); } });
  assert.deepEqual(await same, { apps: [1, 2] }, '304 reuses the last state');
  const changed = run("api('/state')");
  finishFetch({ status: 200, ok: true, headers: { get: () => '"t2"' }, json: async () => ({ apps: [4] }) });
  assert.deepEqual(await changed, { apps: [4] }, 'a changed state replaces it');
  const again = run("api('/state')");
  assert.equal(stateAsks().at(-1).options.headers['If-None-Match'], '"t2"');
  finishFetch({ status: 304, ok: false });
  assert.deepEqual(await again, { apps: [4] });

  const expired = run("api('/state')");
  finishFetch({ status: 401, ok: false });
  await assert.rejects(expired, /unpaired/);
  assert.equal(run('key'), '');
  assert.deepEqual(storage, ['']);
  assert.deepEqual(calls, ['pair']);
  await run('refresh()');
  assert.equal(readCount, 2, 'unpaired polling never contacts state');
  const pairSource = section('function showPair()', 'async function pair(');
  let shown = false, focuses = 0, scheduled = 0;
  const pairElements = { '#pair': { classList: { contains: () => shown, add: () => { shown = true; } } }, '#code': { focus: () => { focuses++; } } };
  const pairContext = vm.createContext({ $: s => pairElements[s], setTimeout: fn => { scheduled++; fn(); } });
  vm.runInContext(pairSource, pairContext);
  vm.runInContext('showPair(); showPair(); showPair()', pairContext);
  assert.equal(scheduled, 1, 'pairing focus is scheduled only on transition');
  assert.equal(focuses, 1);

  // The clickpad with the real "press" protocol: holding an arrow tells the Mac "hold", then "alive" every
  // 300 ms, then "release". Hiding the page or losing the finger releases it, so a key is never left held.
  const press = section('const press = {', '// 返回（按住');
  const clickpad = section('// Clickpad：', '// 触控板：');
  const sends = [], timers = [], intervals = new Map(), documentListeners = {}, listeners = {};
  let nextId = 1;
  const ring = { getBoundingClientRect: () => ({ left: 70, top: 20, width: 210, height: 210 }) };
  const pad = { querySelector: () => ring, querySelectorAll: () => [], setPointerCapture() {},
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 350, height: 251 }),
    addEventListener: (type, fn) => { listeners[type] = fn; } };
  const doc = { visibilityState: 'visible', addEventListener: (type, fn) => { documentListeners[type] = fn; } };
  const padContext = vm.createContext({ document: doc, Math, Map,
    $: selector => selector === '#clickpad' ? pad : {},
    performance: { now: () => 0 },
    swipe: { stop() {}, began: () => sends.push('swipe'), moved() {}, ended() {} },   // gestures: clickpad.test.cjs
    showArt() {}, haptic() {}, sendWheel: d => sends.push(`wheel:${d}`),
    send: (a, extra = {}, repeat = false) => { sends.push(a === 'press' ? `${extra.k}:${extra.p}${repeat ? '~' : ''}` : a); return Promise.resolve(); },
    setTimeout: (fn, ms) => { const id = nextId++; timers.push({ id, fn, ms }); return id; },
    clearTimeout: id => { const t = timers.find(x => x.id === id); if (t) t.fn = null; },
    setInterval: fn => { const id = nextId++; intervals.set(id, fn); return id; },
    clearInterval: id => intervals.delete(id) });
  vm.runInContext(press + clickpad, padContext);
  const fire = ms => { for (const t of timers.splice(0)) if (t.fn && t.ms === ms) t.fn(); };
  const at = (type, x, y, id = 1) => listeners[type]({ type, pointerId: id, clientX: x, clientY: y });
  const centre = [175, 125], right = [175 + 90, 125];

  at('pointerdown', ...right); at('pointerup', ...right);
  at('pointerdown', ...centre); at('pointerup', ...centre);
  at('pointerdown', 5, 5); at('pointerup', 5, 5);
  assert.deepEqual(sends.splice(0), ['right:tap', 'select:tap'], 'arrow and OK taps; outside the ring does nothing');

  at('pointerdown', ...right); fire(350);
  assert.deepEqual(sends.splice(0), ['right:hold']);
  assert.equal(intervals.size, 1);
  [...intervals.values()][0]();
  assert.deepEqual(sends.splice(0), ['right:alive~'], '"still holding" is a droppable repeat');
  doc.visibilityState = 'hidden'; documentListeners.visibilitychange();
  assert.deepEqual(sends.splice(0), ['right:release'], 'hiding the page releases the held arrow');
  assert.equal(intervals.size, 0, 'and stops "still holding"');
  doc.visibilityState = 'visible';

  at('pointerdown', ...centre); fire(500);
  assert.deepEqual(sends.splice(0), ['select:hold'], 'holding OK is a hold of select');
  listeners.lostpointercapture({ pointerId: 1 });
  assert.deepEqual(sends.splice(0), ['select:release'], 'losing the finger releases it');
  assert.equal(intervals.size, 0);
  at('pointerup', ...centre);
  assert.deepEqual(sends.splice(0), [], 'no tap after a released hold');

  at('pointerdown', ...right); fire(350); at('pointerup', ...right);
  assert.deepEqual(sends.splice(0), ['right:hold', 'right:release'], 'lifting after a hold releases, no extra tap');

  // Turning around the ring is the wheel, not a press (swipes, resting thumbs and the rest: clickpad.test.cjs).
  const turn = a => [175 + Math.cos(a) * 90, 125 + Math.sin(a) * 90];
  at('pointerdown', ...turn(0));
  for (let a = 0.1; a <= 2.5; a += 0.1) at('pointermove', ...turn(a));
  at('pointerup', ...turn(2.5));
  const turned = sends.splice(0);
  assert.ok(turned.length >= 3 && turned.every(s => s === 'wheel:1'), `clockwise turn is wheel steps: ${turned}`);
  assert.equal(timers.filter(t => t.fn).length, 0, 'no hold left pending');

  // Volume acts on press and repeats while held (after 0.45 s, every 0.16 s), like the Siri Remote's volume keys;
  // the click after lifting the finger adds nothing, a keyboard / accessibility click still counts.
  const volume = section('// 一按就送的键', '// 按键的"点一下');
  const volumeListeners = {}, volumeSends = [], volumeTimers = [];
  const volup = { dataset: { a: 'volup' }, hasAttribute: name => name === 'data-repeat',
    addEventListener: (type, fn) => { volumeListeners[type] = fn; } };
  const volumeContext = vm.createContext({
    document: { querySelectorAll: selector => selector === '[data-a]' || selector === '[data-repeat]' ? [volup] : [] },
    haptic() {},
    send: (a, extra = {}, repeat = false) => { volumeSends.push(a + (repeat ? '~' : '')); return Promise.resolve(); },
    setTimeout: (fn, ms) => { volumeTimers.push({ fn, ms }); return volumeTimers.length; },
    setInterval: (fn, ms) => { volumeTimers.push({ fn, ms }); return volumeTimers.length; },
    clearTimeout: id => { if (volumeTimers[id - 1]) volumeTimers[id - 1].fn = null; },
    clearInterval: id => { if (volumeTimers[id - 1]) volumeTimers[id - 1].fn = null; },
  });
  vm.runInContext(volume, volumeContext);
  const due = ms => volumeTimers.filter(t => t.fn && t.ms === ms).forEach(t => t.fn());
  volumeListeners.pointerdown({});
  assert.deepEqual(volumeSends.splice(0), ['volup'], 'one step as the finger goes down');
  due(450); due(160); due(160);
  assert.deepEqual(volumeSends.splice(0), ['volup~', 'volup~', 'volup~'], 'then repeats while held');
  volumeListeners.pointerup({}); volumeListeners.click({ detail: 1 });
  due(160);
  assert.deepEqual(volumeSends.splice(0), [], 'lifting stops it; the click adds nothing');
  volumeListeners.click({ detail: 0 });
  assert.deepEqual(volumeSends.splice(0), ['volup'], 'a keyboard click is one step');
  console.log('Remote request deadlines, serialized refresh, bounded commands, clickpad holds, volume repeat and pairing recovery passed');
})().catch(error => { console.error(error); process.exitCode = 1; });
