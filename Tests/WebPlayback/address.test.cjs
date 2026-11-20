// Exercise the actual address form without a browser or external network.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { script: source } = require('./page.cjs');
const start = source.indexOf('let websiteOpening = false');
const end = source.indexOf("$('#type').onsubmit", start);
assert.ok(start >= 0 && end > start);
const classes = () => { const set = new Set(); return { add: c => set.add(c), remove: c => set.delete(c), contains: c => set.has(c) }; };
const elements = Object.fromEntries(['open-website', 'website-address', 'website-go', 'website-open-error']
  .map(id => [id, { value: '', textContent: '', hidden: true, disabled: false, classList: classes() }]));
const note = elements['website-open-error'];
const requests = [], timers = [];
let resolveRequest, rejectRequest, refreshes = 0, haptics = 0;
const api = (path, body) => {
  requests.push({ path, body });
  return new Promise((resolve, reject) => { resolveRequest = resolve; rejectRequest = reject; });
};
// Timers run when the test says so (the note that says what opened goes away after a few seconds).
const later = { setTimeout: (fn, ms) => timers.push({ fn, ms, id: timers.length + 1 }) && timers.length, clearTimeout: id => { const t = timers.find(x => x.id === id); if (t) t.fn = null; } };
const runTimers = () => timers.splice(0).forEach(t => t.fn && t.fn());
vm.runInNewContext(source.slice(start, end), {
  $: selector => elements[selector.slice(1)], api, haptic: kind => { if (kind === 'error') haptics++; },
  refresh: async () => { refreshes++; }, ...later,
});
const submit = () => elements['open-website'].onsubmit({ preventDefault() {} });
(async () => {
  // Nothing typed: say so, send nothing.
  await submit();
  assert.equal(requests.length, 0);
  assert.equal(note.hidden, false);
  assert.ok(note.classList.contains('err') && note.textContent, 'empty address explains itself');
  elements['website-address'].value = ' youtube.com ';
  const first = submit();
  await submit();
  assert.equal(requests.length, 1, 'no duplicate while pending');
  assert.equal(requests[0].path, '/browser/open');
  assert.equal(requests[0].body.url, 'youtube.com');
  assert.equal(elements['website-go'].disabled, true);
  assert.equal(note.hidden, true, 'old message cleared while opening');
  // Opened: the field empties, the note says what the TV opened, then goes away.
  resolveRequest({ ok: true, opened: 'YouTube video' });
  await first;
  assert.equal(elements['website-address'].value, '');
  assert.equal(elements['website-go'].disabled, false);
  assert.equal(refreshes, 1);
  assert.equal(note.textContent, 'Opened on TV: YouTube video');
  assert.equal(note.hidden, false);
  assert.equal(note.classList.contains('err'), false);
  // A second link opened before the first note went away keeps its own note for its full time.
  elements['website-address'].value = 'example.com';
  const second = submit();
  resolveRequest({ ok: true });
  await second;
  assert.equal(note.textContent, 'Opened on TV');
  const pending = timers.filter(t => t.fn);
  assert.equal(pending.length, 1, 'only the latest note is timed');
  runTimers();
  assert.equal(note.hidden, true, 'the note goes away');
  // Failed: the error is shown as text, the address stays for editing.
  elements['website-address'].value = 'bad-address';
  const failed = submit();
  rejectRequest(new Error('<img src=x onerror=alert(1)>'));
  await failed;
  assert.equal(note.textContent, '<img src=x onerror=alert(1)>');
  assert.equal(note.hidden, false);
  assert.ok(note.classList.contains('err'));
  assert.equal(haptics, 1, 'an error buzzes once');
  assert.equal(elements['website-go'].disabled, false);
  assert.equal(elements['website-address'].value, 'bad-address', 'preserve failed address for editing');
  runTimers();
  assert.equal(note.hidden, false, 'errors stay until the next try');
  // Unpaired: no error text (the pairing screen takes over).
  const unpaired = submit();
  rejectRequest(new Error('unpaired'));
  await unpaired;
  assert.equal(note.hidden, true);
  assert.equal(requests.some(x => x.path === '/apps/add'), false, 'navigation does not save tiles');
  console.log('Website address submission, failure recovery and duplicate prevention passed');
})().catch(error => { console.error(error); process.exitCode = 1; });
