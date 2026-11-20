// Run with: node Tests/WebPlayback/volume.test.cjs
// Runs PlaybackVolume's page script against a minimal DOM: the page keeps seeing the volume it set,
// while what plays is that times Mac TV's level, for elements in the page and ones that never join it.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('Sources/MacTV/Features/Audio/PlaybackVolume.swift', 'utf8')
  .split('static let script = #"""')[1].split('"""#')[0];

function frame({ parent, gain, asked }) {
  // The real accessor: what WebKit would play at.
  class HTMLMediaElement {
    constructor() { this._volume = 1; this.played = false; }
    play() { this.played = true; return Promise.resolve(); }
  }
  Object.defineProperty(HTMLMediaElement.prototype, 'volume', {
    configurable: true, enumerable: true,
    get() { return this._volume; },
    set(v) { if (v < 0 || v > 1) throw new Error('IndexSizeError'); this._volume = v; },
  });
  const inPage = [];
  const docListeners = {};
  const winListeners = {};
  const window = {
    frames: [],
    addEventListener(type, fn) { (winListeners[type] ||= []).push(fn); },
    webkit: { messageHandlers: { macTVVolume: { postMessage() { asked.count++; return Promise.resolve(gain); } } } },
  };
  window.parent = parent || window;
  window.postMessage = data => { for (const fn of winListeners.message || []) fn({ data, source: window.parent }); };
  const document = {
    addEventListener(type, fn, capture) { assert.equal(capture, true); (docListeners[type] ||= []).push(fn); },
    querySelectorAll() { return inPage; },
  };
  class DOMException extends Error { constructor(message, name) { super(message); this.name = name; } }
  const context = vm.createContext({ window, document, HTMLMediaElement, WeakRef, WeakMap, WeakSet, Set, Number, DOMException, TypeError, Object });
  vm.runInContext(source.replace('__MACTV_GAIN__', '1.0'), context);
  const make = (attached = true) => { const el = new HTMLMediaElement(); if (attached) inPage.push(el); return el; };
  const fire = (type, target) => { for (const fn of docListeners[type] || []) fn({ target }); };
  return { window, make, fire, again: () => vm.runInContext(source.replace('__MACTV_GAIN__', '0.1'), context) };
}

(async () => {
  const asked = { count: 0 };
  const top = frame({ gain: 0.5, asked });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(asked.count, 1);   // asked Mac TV for the level at the start

  // A video the page never set the volume of: the page sees 1, it plays at Mac TV's level.
  const video = top.make();
  top.fire('loadstart', video);
  assert.equal(video.volume, 1);
  assert.equal(video._volume, 0.5);

  // The page's own volume control still works and reads back what it set.
  video.volume = 0.8;
  assert.equal(video.volume, 0.8);
  assert.equal(video._volume, 0.4);
  assert.throws(() => { video.volume = 2; }, e => e.name === 'IndexSizeError');
  assert.throws(() => { video.volume = NaN; }, TypeError);
  assert.equal(video.volume, 0.8);

  // An Audio() that never joins the page counts once it plays.
  const audio = top.make(false);
  audio.play();
  assert.equal(audio.played, true);
  assert.equal(audio._volume, 0.5);

  // Mac TV's level changes: everything follows, the page's values don't.
  top.window.__macTVVolume(0.25);
  assert.equal(video._volume, 0.2);
  assert.equal(audio._volume, 0.25);
  assert.equal(video.volume, 0.8);
  top.window.__macTVVolume(7);   // out of range: ignored
  assert.equal(audio._volume, 0.25);

  // A child frame (an embedded player) gets the change from its parent, and only from it.
  const child = frame({ parent: top.window, gain: 0.25, asked });
  top.window.frames.push(child.window);
  await new Promise(resolve => setImmediate(resolve));
  const embedded = child.make();
  child.fire('play', embedded);
  assert.equal(embedded._volume, 0.25);
  top.window.__macTVVolume(1);
  assert.equal(embedded._volume, 1);
  assert.equal(video._volume, 0.8);

  // The script running again in the same frame (a second web view setup) changes nothing.
  top.again();
  video.volume = 0.5;
  assert.equal(video._volume, 0.5);
  console.log('volume: ok');
})().catch(error => { console.error(error); process.exit(1); });
