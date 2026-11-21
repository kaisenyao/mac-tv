// Run with: node Tests/WebPlayback/brightness.test.cjs
// Settings › Brightness on the phone: read when Settings opens, hidden when the display has none (Not Available), and
// while the finger moves only the latest value goes, one request at a time and no more often than every 100 ms.
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { html, script: source } = require('./page.cjs');
const start = source.indexOf('// Brightness (Settings)'), end = source.indexOf('async function choosePlayer', start);
assert.ok(start >= 0 && end > start, 'the brightness section is in remote.js');
for (const id of ['brightness', 'brightness-label', 'brightness-group']) assert.ok(html.includes(`id="${id}"`), `#${id} is on the page`);
assert.ok(source.includes('loadBrightness();'), 'opening Settings reads the brightness');

const element = () => ({ hidden: true, value: '50', listeners: {}, level: null,
  style: { setProperty(name, value) { assert.equal(name, '--level'); this.owner.level = value; } },
  addEventListener(type, fn) { this.listeners[type] = fn; } });
const elements = { '#brightness': element(), '#brightness-label': element(), '#brightness-group': element() };
for (const el of Object.values(elements)) el.style.owner = el;
const slider = elements['#brightness'];
const requests = [], timers = [], haptics = [];
let clock = 1000;
const context = vm.createContext({
  $: selector => elements[selector], haptic: kind => haptics.push(kind), Number, Infinity,
  Date: { now: () => clock },
  setTimeout: (fn, ms) => { timers.push({ fn, at: clock + ms }); return timers.length; },
  api: (path, body) => new Promise((resolve, reject) => requests.push({ path, body, resolve, reject })),
});
vm.runInContext(source.slice(start, end), context);
const run = code => vm.runInContext(code, context);
const settle = () => new Promise(resolve => setImmediate(resolve));
const drag = level => { slider.value = String(level); slider.listeners.input({ target: slider }); };
const later = ms => { clock += ms; for (const t of timers.splice(0)) { if (t.at <= clock) t.fn(); else timers.push(t); } };
// Bodies made in the page's own context: compared as JSON.
const bodies = () => JSON.parse(JSON.stringify(requests.map(r => r.body ?? null)));
const shown = () => !elements['#brightness-group'].hidden && !elements['#brightness-label'].hidden;

(async () => {
  // Settings opens: the display's brightness, read afresh.
  run('loadBrightness()');
  assert.deepEqual(requests.map(r => [r.path, r.body]), [['/display/brightness', undefined]]);
  requests.shift().resolve({ level: 30 });
  await settle();
  assert.ok(shown());
  assert.equal(Number(slider.value), 30);
  assert.equal(slider.level, '30%');

  // A drag: the first value goes at once; the ones made while it's on the way wait, and only the latest goes.
  drag(40);
  assert.equal(slider.level, '40%', 'the slider fills where the finger is, before the Mac answers');
  for (const level of [45, 50, 55]) drag(level);
  assert.deepEqual(bodies(), [{ level: 40 }]);
  requests.shift().resolve({ level: 40 });
  await settle();
  assert.equal(requests.length, 0, 'not again within 100 ms');
  later(60);
  assert.equal(requests.length, 0);
  later(40);
  assert.deepEqual(bodies(), [{ level: 55 }], 'then only the latest');
  requests.shift().resolve({ level: 55 });
  await settle();
  later(500);
  assert.equal(requests.length, 0, 'nothing more once the finger stopped');

  // A read that comes back after the finger moved doesn't pull the slider back.
  run('loadBrightness()');
  const read = requests.shift();
  drag(70);
  requests.shift().resolve({ level: 70 });
  read.resolve({ level: 10 });
  await settle();
  assert.equal(Number(slider.value), 70);

  // A failed set says so; the next value still goes.
  later(200);
  drag(20);
  requests.shift().reject(new Error('Request timed out.'));
  await settle();
  assert.deepEqual(haptics, ['error']);
  later(200);
  drag(25);
  assert.deepEqual(bodies(), [{ level: 25 }]);

  // Mac TV moved to a display without brightness: the slider goes.
  requests.shift().resolve({ level: null });
  await settle();
  assert.ok(!shown());

  // Not Available when Settings opens, or the Mac didn't answer: no slider.
  run('loadBrightness()');
  requests.shift().resolve({ level: 60 });
  await settle();
  assert.ok(shown());
  run('loadBrightness()');
  requests.shift().resolve({ level: null });
  await settle();
  assert.ok(!shown());
  run('loadBrightness()');
  requests.shift().reject(new Error('This action requires a trusted remote.'));
  await settle();
  assert.ok(!shown());
  console.log('brightness: ok');
})().catch(error => { console.error(error); process.exit(1); });
