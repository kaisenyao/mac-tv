// Run with: node Tests/WebPlayback/touchpad.test.cjs
// Execute the real touchpad handler with a deliberately slow mock transport, a hand-cranked animation frame
// and clock: one finger moves the pointer (sent each frame, up to three on the way, nothing lost), a tap
// clicks after the movement has arrived, a still hold is a mouse hold, two fingers swipe with momentum.
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { script: source } = require('./page.cjs');
const start = source.indexOf('// 触控板：');
const end = source.indexOf('// Old installations stored', start);
assert.ok(start >= 0 && end > start, 'touchpad section is in remote.js');
const listeners = {};
const pad = { addEventListener: (name, fn) => { listeners[name] = fn; }, setPointerCapture() {} };
const requests = [], pending = [], sent = [], haptics = [], timers = [];
let frames = [], now = 0, nextId = 1;
const inFlight = a => pending.filter(p => p.body.a === a).length;
let mostPointers = 0, mostSwipes = 0;
const api = (_path, body) => {
  requests.push(body);
  return new Promise((resolve, reject) => {
    pending.push({ body, resolve: () => resolve({}), reject: () => reject(new Error('offline')) });
    mostPointers = Math.max(mostPointers, inFlight('pointer'));
    mostSwipes = Math.max(mostSwipes, inFlight('swipe'));
  });
};
const answer = (fail = false) => { const p = pending.shift(); fail ? p.reject() : p.resolve(); };
vm.runInNewContext(source.slice(start, end), {
  $: () => pad, api, Math, Map, Promise, Date: { now: () => now },
  send: action => { sent.push(action); return Promise.resolve(); },
  haptic: kind => haptics.push(kind),
  performance: { now: () => now },
  requestAnimationFrame: fn => { frames.push(fn); return frames.length; },
  cancelAnimationFrame: () => { frames = []; },
  setTimeout: (fn, ms) => { const id = nextId++; timers.push({ id, fn, at: now + ms }); return id; },
  clearTimeout: id => { const t = timers.find(x => x.id === id); if (t) t.fn = null; },
});
const event = (type, id, x, y) => listeners[type]({ type, pointerId: id, clientX: x, clientY: y });
const settle = () => new Promise(resolve => setImmediate(resolve));
// One screen frame: time moves 16 ms, due timers and the frame callbacks run.
const frame = async () => {
  now += 16;
  for (const t of timers.filter(t => t.fn && t.at <= now)) { const fn = t.fn; t.fn = null; fn(); }
  const due = frames; frames = [];
  due.forEach(fn => fn(now));
  await settle();
};
const sum = (list, key) => list.reduce((n, x) => n + x[key], 0);
const gain = d => d * (1.6 + Math.min(Math.abs(d) / 6, 3));
(async () => {
  // One finger: movement goes out once per frame, never more than three on the way, and every bit of it arrives.
  event('pointerdown', 1, 100, 100);
  let x = 100, expected = 0;
  for (let i = 0; i < 6; i++) {
    x += 3; expected += gain(3);
    event('pointermove', 1, x, 100);
    await frame();
  }
  assert.equal(mostPointers, 3, 'up to three pointer packets on the way');
  assert.equal(inFlight('pointer'), 3);
  answer(true);                                  // a lost packet does not stall the rest
  await settle(); await frame();
  while (pending.length) { answer(); await settle(); await frame(); }
  const moved = requests.filter(r => r.a === 'pointer');
  assert.ok(moved.length >= 4, 'movement made while three were on the way is sent later');
  assert.ok(Math.abs(sum(moved, 'dx') - expected) < 0.2, `all movement is sent (${sum(moved, 'dx')} of ${expected})`);
  assert.equal(sum(moved, 'dy'), 0);
  for (let i = 0; i < 35; i++) await frame();
  assert.deepEqual(sent, [], 'a finger that moved and then rests is not a mouse hold');
  event('pointerup', 1, x, 100);
  assert.deepEqual(sent, [], 'a drag is not a click');
  assert.equal(frames.length, 0, 'nothing keeps running once the finger is still');

  // A tap: a small wobble, then the click, only after that wobble has reached the Mac.
  requests.length = 0;
  event('pointerdown', 1, 50, 50);
  event('pointermove', 1, 52, 50);
  await frame();
  assert.equal(inFlight('pointer'), 1);
  now += 100;
  event('pointerup', 1, 52, 50);
  assert.deepEqual(haptics.splice(0), ['press'], 'the tap buzzes at once');
  await settle();
  assert.deepEqual(sent, [], 'no click before the movement before it has arrived');
  answer(true);                                  // even when it failed
  await settle(); await settle();
  assert.deepEqual(sent.splice(0), ['click']);
  assert.deepEqual(requests.map(r => r.a), ['pointer']);

  // A slow press is not a click; a still half-second hold is a mouse hold (long press), not a click either.
  event('pointerdown', 1, 50, 50); now += 400; event('pointerup', 1, 50, 50);
  assert.deepEqual(sent, [], 'a slow press is not a click');
  event('pointerdown', 1, 50, 50);
  for (let i = 0; i < 35; i++) await frame();
  assert.deepEqual(sent.splice(0), ['mousehold']);
  assert.deepEqual(haptics.splice(0), ['hold']);
  event('pointerup', 1, 50, 50);
  assert.deepEqual(sent, [], 'lifting after a hold is not a click');

  // Two fingers: a swipe, one request at a time, movement merged while one is on the way, no pointer moves.
  requests.length = 0;
  event('pointerdown', 1, 100, 200); event('pointerdown', 2, 140, 200);
  assert.deepEqual(requests.map(r => `${r.a}:${r.p}`), ['swipe:began']);
  for (let i = 1; i <= 5; i++) {
    event('pointermove', 1, 100, 200 - i * 10); event('pointermove', 2, 140, 200 - i * 10); now += 16;
  }
  assert.equal(requests.length, 1, 'changes wait while "began" is on the way');
  answer(); await settle();
  assert.deepEqual(requests.map(r => `${r.a}:${r.p}`), ['swipe:began', 'swipe:changed']);
  assert.ok(Math.abs(requests[1].dy - -50 * 1.4) < 0.2, `the centre's movement, scaled 1.4 (${requests[1].dy})`);
  event('pointerup', 2, 140, 150);                // second finger lifts: the swipe ends, momentum follows
  event('pointermove', 1, 100, 120);              // the remaining finger does not move the pointer
  while (pending.length) { answer(); await settle(); }
  for (let i = 0; i < 400 && (frames.length || pending.length); i++) { await frame(); while (pending.length) { answer(); await settle(); } }
  const phases = requests.map(r => r.p);
  assert.equal(phases.indexOf('ended'), 2);
  assert.ok(phases.includes('momentum'), 'a fast swipe carries on');
  assert.equal(phases.at(-1), 'momentumEnd', 'momentum ends');
  assert.equal(requests.filter(r => r.a === 'pointer').length, 0, 'no pointer movement during or after a swipe');
  assert.equal(mostSwipes, 1, 'one swipe request at a time');
  event('pointerup', 1, 100, 120);
  assert.deepEqual(sent, [], 'a swipe is not a click');

  // A finger landing during momentum stops it.
  requests.length = 0;
  event('pointerdown', 1, 100, 200); event('pointerdown', 2, 140, 200);
  for (let i = 1; i <= 5; i++) { now += 16; event('pointermove', 1, 100, 200 - i * 20); event('pointermove', 2, 140, 200 - i * 20); }
  event('pointerup', 1, 100, 100); event('pointerup', 2, 140, 100);
  while (pending.length) { answer(); await settle(); }
  for (let i = 0; i < 3; i++) await frame();     // momentum goes out about every 33 ms
  while (pending.length) { answer(); await settle(); }
  assert.ok(requests.some(r => r.p === 'momentum'));
  event('pointerdown', 3, 10, 10);
  while (pending.length) { answer(); await settle(); }
  assert.equal(requests.at(-1).p, 'momentumEnd', 'touching the pad stops the momentum');
  assert.equal(frames.length, 0);
  event('pointerup', 3, 10, 10);
  console.log('Touchpad pointer packets, tap ordering, hold and two-finger swipes passed');
})().catch(error => { console.error(error); process.exitCode = 1; });
