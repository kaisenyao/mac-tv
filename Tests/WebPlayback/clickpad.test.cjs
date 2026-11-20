// Run with: node Tests/WebPlayback/clickpad.test.cjs
// Execute the real clickpad handler (with the real key presses and swipe sender) against a hand-cranked clock
// and animation frame. It recognises strokes the way the Siri Remote's touch surface does (SiriRemoteTouch):
// a stroke sends nothing until it is clearly a turn (away from the centre, 25° within 0.6 s) or a swipe (22% of
// the ring's diameter within 0.25 s); a resting or rolling finger sends no stray move or turn; a press that
// became a hold, or another finger pressing, wins over any gesture; a swipe follows the finger, in the Siri
// Remote's points, and glides after release until a new touch stops it; it says focus: true (focus follows the finger).
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { script: source } = require('./page.cjs');
const section = (from, to) => {
  const start = source.indexOf(from), end = source.indexOf(to, start);
  assert.ok(start >= 0 && end > start, `${from} … ${to} is in remote.js`);
  return source.slice(start, end);
};
const code = section('const press = {', '// 返回（按住') + section('// 滑动：', '// 触控板：');

// The ring as the layout tests measure it: centre (175, 125), radius 105, so 210 across.
const CX = 175, CY = 125, SIZE = 210;
const listeners = {}, documentListeners = {};
const ring = { getBoundingClientRect: () => ({ left: CX - SIZE / 2, top: CY - SIZE / 2, width: SIZE, height: SIZE }) };
const pad = { querySelector: () => ring, querySelectorAll: () => [], setPointerCapture() {},
  addEventListener: (type, fn) => { listeners[type] = fn; } };
const doc = { visibilityState: 'visible', addEventListener: (type, fn) => { documentListeners[type] = fn; } };
const sent = [], swipes = [], haptics = [], timers = [];
let frames = [], now = 1000, nextId = 1;
vm.runInNewContext(code, {
  document: doc, Math, Map, Promise,
  $: selector => selector === '#clickpad' ? pad : {},
  showArt() {}, haptic: kind => haptics.push(kind),
  send: (a, extra = {}) => { sent.push(a === 'press' ? `${extra.k}:${extra.p}` : a); return Promise.resolve(); },
  sendWheel: d => sent.push(`wheel:${d}`),
  api: (_path, body) => { swipes.push(body); return Promise.resolve({}); },
  performance: { now: () => now },
  requestAnimationFrame: fn => { frames.push(fn); return frames.length; },
  cancelAnimationFrame: () => { frames = []; },
  setTimeout: (fn, ms) => { const id = nextId++; timers.push({ id, fn, at: now + ms }); return id; },
  clearTimeout: id => { const t = timers.find(x => x.id === id); if (t) t.fn = null; },
  setInterval: (fn, ms) => { const id = nextId++; timers.push({ id, fn, at: now + ms, every: ms }); return id; },
  clearInterval: id => { const t = timers.find(x => x.id === id); if (t) t.fn = null; },
});
const settle = () => new Promise(resolve => setImmediate(resolve));
// Time passes: due timers (holds, "still holding") run.
const wait = ms => {
  const until = now + ms;
  for (;;) {
    const due = timers.filter(t => t.fn && t.at <= until).sort((a, b) => a.at - b.at)[0];
    if (!due) break;
    now = Math.max(now, due.at);
    const fn = due.fn;
    if (due.every) due.at += due.every; else due.fn = null;
    fn();
  }
  now = until;
};
const at = (type, x, y, id = 1) => listeners[type]({ type, pointerId: id, clientX: x, clientY: y });
const down = (x, y, id) => at('pointerdown', x, y, id);
const up = (x, y, id) => at('pointerup', x, y, id);
// The finger goes along these points, one every `ms`.
const path = (points, ms, id = 1) => { for (const [x, y] of points) { wait(ms); at('pointermove', x, y, id); } };
const line = (from, to, n) => Array.from({ length: n }, (_, i) => [from[0] + (to[0] - from[0]) * (i + 1) / n, from[1] + (to[1] - from[1]) * (i + 1) / n]);
const arc = (r, from, to, n) => Array.from({ length: n }, (_, i) => {
  const a = from + (to - from) * (i + 1) / n;
  return [CX + Math.cos(a) * r, CY + Math.sin(a) * r];
});
const onRing = (r, a) => [CX + Math.cos(a) * r, CY + Math.sin(a) * r];
const deg = d => d * Math.PI / 180;
const phases = () => swipes.map(s => s.p);
const total = key => swipes.filter(s => s.p === 'changed').reduce((n, s) => n + s[key], 0);
const wheel = list => list.reduce((n, s) => n + (s.startsWith('wheel:') ? Number(s.slice(6)) : 0), 0);
const right = [CX + 90, CY], centre = [CX, CY], outside = [20, CY];
const reset = async () => { await settle(); sent.length = 0; swipes.length = 0; haptics.length = 0; };
// Runs the glide's frames until it stops.
const glide = async () => {
  for (let i = 0; i < 500 && frames.length; i++) {
    now += 16;
    const due = frames; frames = [];
    due.forEach(fn => fn(now));
    await settle();
  }
};

(async () => {
  // Taps: an edge and the centre, also with the finger rolling a little; outside the ring is nothing.
  down(...right); wait(80); up(...right);
  down(...centre); path(line(centre, [CX + 8, CY - 6], 5), 20); up(CX + 8, CY - 6);
  down(...right); path(line(right, [CX + 75, CY + 12], 6), 25); up(CX + 75, CY + 12);
  down(...outside); wait(80); up(...outside);
  await settle();
  assert.deepEqual(sent.splice(0), ['right:tap', 'select:tap', 'right:tap'], 'taps; a finger rolling within reach still taps');
  assert.deepEqual(swipes, []);

  // A resting thumb that rolls off and drifts sends nothing: no tap, no hold, no move, no turn.
  await reset();
  down(...right);
  path(line(right, [CX + 60, CY], 10), 25);                     // rolls 30 px in a quarter of a second
  path(line([CX + 60, CY], [CX + 20, CY + 40], 100), 30);       // then drifts for three seconds
  up(CX + 20, CY + 40);
  down(...onRing(120, 0));                                       // outside the ring, creeping a quarter of the way round
  path(arc(120, 0, deg(90), 150), 20);
  up(...onRing(120, deg(90)));
  wait(1000); await settle();
  assert.deepEqual(sent, [], `a resting thumb sends nothing (${sent})`);
  assert.deepEqual(swipes, [], 'and no swipe');

  // Turning: 20° is nothing; past 25° it turns, 16 steps a full turn less the 25° it took to start.
  await reset();
  down(...onRing(90, 0)); path(arc(90, 0, deg(20), 10), 4); up(...onRing(90, deg(20)));
  assert.deepEqual(sent.splice(0), [], 'a 20° nudge is not a turn, nor a tap');
  down(...onRing(90, 0)); path(arc(90, 0, deg(360), 360), 1.5); up(...onRing(90, 0));
  assert.equal(wheel(sent), 15, `clockwise: (360 - 25) / 22 → 15 steps (${wheel(sent)})`);
  assert.ok(sent.splice(0).every(s => s === 'wheel:1'));
  down(...onRing(90, 0)); path(arc(90, 0, deg(-180), 180), 1.5); up(...onRing(90, deg(-180)));
  assert.equal(wheel(sent.splice(0)), -7, 'counterclockwise goes back');
  // The angle is not read too near the centre, and a turn has to stay out on the ring
  // (half a turn a second: plenty for a turn out on the ring, too slow to be a swipe).
  down(...onRing(30, 0)); path(arc(30, 0, deg(360), 120), 16.7); up(...onRing(30, 0));
  down(...onRing(50, 0)); path(arc(50, 0, deg(360), 120), 16.7); up(...onRing(50, 0));
  assert.deepEqual(sent.filter(s => s.startsWith('wheel')), [], 'circling the centre button is not the wheel');
  assert.deepEqual(swipes, []);

  // Swiping: 22% of the ring within a quarter of a second. Less, or slower, is nothing.
  await reset();
  down(...outside); path(line(outside, [outside[0] + 40, CY], 8), 12); up(outside[0] + 40, CY);
  down(...right); path(line(right, [right[0] - 40, CY], 8), 12); up(right[0] - 40, CY);
  down(...outside); path(line(outside, [outside[0] + 100, CY], 40), 25); up(outside[0] + 100, CY);
  await settle();
  assert.deepEqual(sent, [], `too short or too slow: nothing, and no tap (${sent})`);
  assert.deepEqual(swipes, []);

  // A swipe follows the finger in the Siri Remote's points (500 across the pad), then glides.
  await reset();
  down(...right); path(line(right, [right[0] - 120, CY - 6], 10), 12); up(right[0] - 120, CY - 6);
  await settle();
  assert.deepEqual(sent, [], 'a swipe that started on an edge is not also a tap');
  assert.equal(haptics.filter(h => h === 'tick').length, 0, 'it buzzed once, when the edge was touched');
  assert.equal(phases()[0], 'began');
  assert.ok(Math.abs(total('dx') - -120 * 500 / SIZE) < 1, `scaled like the Siri Remote: ${total('dx')}`);
  assert.ok(total('dy') < 0, 'up is negative, like the touchpad');
  assert.equal(phases().filter(p => p === 'ended').length, 1);
  await glide();
  assert.ok(phases().includes('momentum'), 'a fast swipe glides on');
  assert.equal(phases().at(-1), 'momentumEnd');
  assert.ok(swipes.filter(s => s.p === 'momentum').every(s => s.dx < 0), 'the same way');
  // Every part of it, the glide too, says focus follows the finger (like the Siri Remote; the touchpad's don't).
  assert.ok(swipes.every(s => s.focus === true), `focus: true on every swipe (${JSON.stringify(swipes.filter(s => s.focus !== true))})`);

  // From outside the ring it buzzes once when it starts to swipe; one that stops before lifting doesn't glide.
  await reset();
  down(...outside); path(line(outside, [outside[0] + 80, CY], 8), 12); wait(150); up(outside[0] + 80, CY);
  await settle();
  assert.deepEqual(haptics, ['tick']);
  assert.deepEqual(phases().slice(-2), ['ended', 'momentumEnd']);
  assert.equal(frames.length, 0, 'nothing runs afterwards');

  // A new touch stops the glide; the capture going away after a lift does not.
  await reset();
  down(...outside); path(line(outside, [outside[0] + 120, CY], 8), 12); up(outside[0] + 120, CY);
  at('lostpointercapture', outside[0] + 120, CY);
  for (let i = 0; i < 4; i++) { now += 16; const due = frames; frames = []; due.forEach(fn => fn(now)); await settle(); }
  assert.ok(phases().includes('momentum'), 'gliding');
  down(...outside, 2);
  await settle();
  assert.equal(phases().at(-1), 'momentumEnd', 'the touch stops it');
  assert.equal(frames.length, 0);
  up(...outside, 2);

  // A hold wins: the finger then swiping or going round does nothing until it lets go.
  await reset();
  down(...right); wait(350);
  assert.deepEqual(sent.splice(0), ['right:hold']);
  path(line(right, [right[0] - 150, CY], 6), 12);
  path(arc(90, deg(180), deg(500), 100), 3);
  up(...onRing(90, deg(500)));
  await settle();
  assert.deepEqual(sent.filter(s => s !== 'right:alive'), ['right:release'], `only the key (${sent})`);
  assert.deepEqual(swipes, [], 'a held press is never a swipe');

  // Another finger pressing wins: the swipe under it ends without gliding, the press counts,
  // and the first finger is ignored from then on.
  await reset();
  down(...outside); path(line(outside, [outside[0] + 60, CY], 4), 12);
  assert.equal(phases()[0], 'began');
  down(...centre, 2);
  await settle();
  assert.deepEqual(phases().slice(-2), ['ended', 'momentumEnd'], 'the swipe ends, no glide');
  wait(60); up(...centre, 2);
  path(line([outside[0] + 60, CY], [outside[0] + 160, CY], 4), 12, 1); up(outside[0] + 160, CY, 1);
  await settle();
  assert.deepEqual(sent, ['select:tap']);
  assert.equal(phases().filter(p => p === 'changed').length, 1, 'the first finger no longer swipes');
  assert.equal(frames.length, 0);

  // Hiding the page lets go of a hold.
  await reset();
  down(...right); wait(350);
  doc.visibilityState = 'hidden'; documentListeners.visibilitychange(); doc.visibilityState = 'visible';
  up(...right);
  assert.deepEqual(sent, ['right:hold', 'right:release']);
  assert.equal(timers.filter(t => t.fn).length, 0, 'nothing left pending');
  console.log('Clickpad taps, holds, resting thumbs, turn and swipe thresholds, glide and presses winning passed');
})().catch(error => { console.error(error); process.exitCode = 1; });
