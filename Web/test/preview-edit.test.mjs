// Preview editing and two-way selection on the real page (src/preview/editing.ts, peer.ts), in headless Chrome. The app is played
// by a simulator inside the page that does what PreviewModel, PreviewEditChain and EditorHandle do, in the order the real app can
// see things: a script message is delivered as soon as the app's main thread is free (`delay`), while the continuation of its
// callJavaScript, where the app learns that a render landed, runs later (`landing`), so an edit made on a fresh render can arrive
// before the app knows the page shows it. The simulator applies an edit only on exactly the text it was made on (the burst chain,
// the base from the renders it sent, the removed source and the source around it), renders after a delay with the burst's mark,
// refuses with the burst's id and seq (and sends nothing else), re-renders on a resync, and forgets what a landed render settled.
// Input goes through Chrome's own input pipeline (DevTools Input.insertText / dispatchKeyEvent / imeSetComposition).
//
// The plain-text fuzz knows where every shown character is in the source without the source map (its documents have no markup
// inside the text), so "the same edit made in the source" is computed independently and compared character for character, after
// random typing, deleting and Chinese input-method composition at random places, in several blocks of one burst, with random app
// latency. The syntax fuzz types Markdown punctuation into formatted documents: whatever the page accepts must show exactly as typed
// when the app's final text is rendered from scratch, and whatever it refuses must leave the page as it was.
//
// MD2_EDIT_FUZZ=<n> scales the fuzz (default 30 rounds each), MD2_EDIT_SEED=<n> replays one.
import { after, before, describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { chromeAvailable, launch } from './helpers/chrome.mjs';

const ROUNDS = Number(process.env.MD2_EDIT_FUZZ ?? 30);
const SEED = process.env.MD2_EDIT_SEED === undefined ? null : Number(process.env.MD2_EDIT_SEED);
const OPTIONS = {
  flavor: 'markdown',
  extensions: ['tables', 'strikethrough', 'autolink', 'mark', 'footnotes', 'taskLists', 'math', 'toc', 'frontMatter', 'cjkEmphasis'],
  hardBreaks: false,
  allowRawHTML: true,
  headingAnchors: true,
  codeHighlighting: true,
  codeLineNumbers: false,
  inlineDollarMath: false,
  frontMatterDisplay: 'hidden',
};
const HINTS = { newline: 'H-newline', unmapped: 'H-unmapped', formatting: 'H-formatting', paste: 'H-paste', structure: 'H-structure', stale: 'H-stale' };

function rng(seed) {
  let a = seed >>> 0;
  const next = () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  return { next, int: (n) => Math.floor(next() * n), pick: (xs) => xs[Math.floor(next() * xs.length)] };
}

const APP = `
window.app = {
  text: '', version: 0, sent: [], displayed: null, chain: null, applied: [], refused: 0, renders: 0,
  delay: () => 0, landing: () => 0, queue: [], busy: false, timer: null, landingsDue: 0, base: undefined, failNext: false,
  load(text) { this.text = text; this.chain = null; this.push(); },
  // PreviewEditChain.mark: the burst and the number of the last of its edits a text is the result of
  mark(md) {
    if (!this.chain) return null;
    for (const [seq, t] of this.chain.texts) if (t === md) return { burst: this.chain.burst, seq };
    return null;
  },
  // PreviewModel.push: one render in flight at a time, the latest text when it is the next one's turn
  push() {
    if (this.landingsDue) { this.pushAgain = true; return; }
    const v = ++this.version, md = this.text, mark = this.mark(md);
    this.sent.push({ version: v, text: md });
    if (this.sent.length > 8) this.sent.shift();
    this.renders++;
    const options = this.failNext ? '{' : OPTIONS; // a render that throws inside the page
    this.failNext = false;
    const out = JSON.parse(MacDown2Preview.update(md, options, v, mark, false, this.base));
    (window.__updates ??= []).push({ v, mark, deferred: !!out.deferred, error: out.error, mode: out.perf?.mode, state: MacDown2Preview.editingForTests.state() });
    // the callJavaScript continuation: the app learns what the page shows, later than it hears the page's messages
    this.landingsDue++;
    setTimeout(() => {
      this.landingsDue--;
      if (!out.deferred && !out.error) {
        // PreviewEditChain.landed: older renders are not needed any more, nor a burst this render ended
        this.displayed = { version: v, text: md };
        this.sent = this.sent.filter((r) => r.version >= v);
        if (mark && this.chain && this.chain.burst === mark.burst && this.chain.seq === mark.seq) this.chain = null;
      }
      if (this.pushAgain) { this.pushAgain = false; this.push(); }
    }, this.landing());
    return out;
  },
  schedule() { clearTimeout(this.timer); this.timer = setTimeout(() => this.push(), this.delay()); },
  receive(m) { this.queue.push(m); if (!this.busy) this.drain(); },
  drain() {
    const m = this.queue.shift();
    if (!m) { this.busy = false; return; }
    this.busy = true;
    setTimeout(() => { this.handle(m); this.drain(); }, this.delay());
  },
  handle(m) {
    if (m.type === 'previewEdit') {
      let expected = null;
      if (m.seq === 1) expected = this.sent.find((r) => r.version === m.base)?.text ?? null;
      else if (this.chain && this.chain.burst === m.burst && this.chain.seq === m.seq - 1) expected = this.chain.text;
      const fits = expected !== null && this.text === expected && !/[\\n\\r\\v\\f\\u0085\\u2028\\u2029]/.test(m.text) && m.to <= expected.length &&
        expected.slice(m.from, m.to) === m.removed && expected.slice(Math.max(0, m.from - 16), m.from) === m.before && expected.slice(m.to, m.to + 16) === m.after;
      if (!fits) {
        this.refused++;
        this.why = { edit: m, expected, text: this.text, chain: this.chain && { burst: this.chain.burst, seq: this.chain.seq } };
        if (!this.chain || this.chain.burst <= m.burst) this.chain = null;
        MacDown2Preview.editRefused('stale', m.burst, m.seq);
        return;
      }
      this.text = expected.slice(0, m.from) + m.text + expected.slice(m.to);
      const texts = m.seq === 1 ? new Map() : this.chain.texts;
      texts.set(m.seq, this.text);
      if (texts.size > 8) texts.delete(texts.keys().next().value);
      this.chain = { burst: m.burst, base: m.base, seq: m.seq, text: this.text, texts };
      this.applied.push(m);
      this.schedule();
    } else if (m.type === 'resync') this.schedule();
  },
  settled() {
    return !this.busy && this.queue.length === 0 && this.landingsDue === 0 && !this.pushAgain && this.displayed && this.displayed.text === this.text &&
      !MacDown2Preview.editingForTests.state().burst && !MacDown2Preview.editingForTests.state().composing;
  },
};
window.webkit.messageHandlers.macdown2.postMessage = (m) => { window.__msgs.push(m); window.app.receive(m); };
`;

describe('preview editing (headless Chrome)', { skip: !chromeAvailable && 'no Chrome (set CHROME_BIN)' }, () => {
  let browser;
  before(async () => {
    browser = await launch();
  });
  after(async () => browser?.close());

  async function open(text) {
    const page = await browser.newPage();
    await page.goto('/preview.html');
    await page.eval(`window.OPTIONS = ${JSON.stringify(JSON.stringify(OPTIONS))}; ${APP}`);
    await page.eval(`MacDown2Preview.setTaskToken('tok'); MacDown2Preview.setEditing({ enabled: true, hints: ${JSON.stringify(HINTS)} })`);
    if (text !== undefined) await page.eval(`app.load(${JSON.stringify(text)})`);
    await settle(page);
    return page;
  }
  const wait = (page, ms) => page.eval(`new Promise((r) => setTimeout(r, ${ms}))`);
  const settle = async (page) => {
    for (let i = 0; i < 600; i++) {
      if (await page.eval('app.settled()')) return;
      await wait(page, 5);
    }
    throw new Error(`never settled: ${JSON.stringify(await page.eval('({ text: app.text, displayed: app.displayed, state: MacDown2Preview.editingForTests.state(), queue: app.queue.length })'))}`);
  };
  // The caret at character k of the text of the block on `line` (of its paragraph, list item or heading: not counting the line
  // breaks between a list's or a quote's own tags), in edit mode.
  const caretAt = (page, line, k) =>
    page.eval(`(() => {
      const top = [...document.querySelectorAll('#doc [data-line]')].find((e) => e.dataset.line === '${line}' && e.parentElement.id === 'doc');
      if (!top || !MacDown2Preview.editingForTests.enterAt(${line}, null)) return false;
      const h = top.matches('ul, ol, blockquote') ? top.querySelector('li, p') : top;
      const w = document.createTreeWalker(h, NodeFilter.SHOW_TEXT);
      let left = ${k}, n;
      while ((n = w.nextNode())) { if (left <= n.data.length) { getSelection().setBaseAndExtent(n, left, n, left); return true; } left -= n.data.length; }
      return false;
    })()`);
  const type = (page, text) => page.send('Input.insertText', { text });
  const key = async (page, name, code, vk) => {
    await page.send('Input.dispatchKeyEvent', { type: name === 'Enter' ? 'keyDown' : 'rawKeyDown', key: name, code, windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk, ...(name === 'Enter' ? { text: '\r' } : {}) });
    await page.send('Input.dispatchKeyEvent', { type: 'keyUp', key: name, code, windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk });
  };
  const backspace = (page) => key(page, 'Backspace', 'Backspace', 8);
  const arrow = (page, name) => key(page, name, name, { ArrowLeft: 37, ArrowUp: 38, ArrowRight: 39, ArrowDown: 40 }[name]);
  const hintText = (page) => page.eval(`document.getElementById('md2-hint')?.textContent ?? null`);
  // An event dispatched to the block being edited (WebKit's input events that Chrome does not send); true when it was prevented.
  const fire = (page, js) => page.eval(`(() => { const ev = ${js}; document.querySelector('#doc [contenteditable]').dispatchEvent(ev); return ev.defaultPrevented; })()`);
  // A cancelable beforeinput of one of WebKit's input types; Chrome blanks the ones it does not know in the constructor.
  const webkitInput = (inputType, data) =>
    `(() => { const ev = new InputEvent('beforeinput', { data: ${JSON.stringify(data)}, cancelable: true, bubbles: true }); Object.defineProperty(ev, 'inputType', { value: ${JSON.stringify(inputType)} }); return ev; })()`;
  const forwardDelete = (page) => key(page, 'Delete', 'Delete', 46);
  const compose = async (page, steps, commit, pause = 0) => {
    for (const s of steps) {
      await page.send('Input.imeSetComposition', { text: s, selectionStart: s.length, selectionEnd: s.length });
      if (pause) await wait(page, pause);
    }
    await page.send('Input.insertText', { text: commit });
  };
  const docText = (page) => page.eval(`[...document.querySelectorAll('#doc > *')].map((e) => e.textContent).join('|')`);
  const sentEdits = (page) => page.eval('__msgs.filter((m) => m.type === "previewEdit").length');
  async function freshText(text) {
    const fresh = await browser.newPage();
    try {
      await fresh.goto('/preview.html');
      await fresh.eval(`MacDown2Preview.update(${JSON.stringify(text)}, ${JSON.stringify(JSON.stringify(OPTIONS))}, 1)`);
      return await docText(fresh);
    } finally {
      await fresh.close();
    }
  }

  test('a click puts the caret in the block and makes only that block editable; typing reaches the source', async () => {
    const page = await open('First paragraph here.\n\nSecond **bold** one.\n');
    try {
      const at = await page.eval(`(() => { const t = document.querySelector('#doc p').firstChild; const r = document.createRange(); r.setStart(t, 8); r.setEnd(t, 9); const b = r.getBoundingClientRect(); return [b.left + 1, b.top + b.height / 2]; })()`);
      for (const type of ['mousePressed', 'mouseReleased']) await page.send('Input.dispatchMouseEvent', { type, x: at[0], y: at[1], button: 'left', clickCount: 1 });
      assert.deepEqual(await page.eval(`[...document.querySelectorAll('#doc [contenteditable]')].map((e) => e.tagName)`), ['P']);
      await type(page, 'X');
      await settle(page);
      assert.equal(await page.eval('app.text'), 'First paXragraph here.\n\nSecond **bold** one.\n');
      await type(page, 'Y');
      await settle(page);
      assert.equal(await page.eval('app.text'), 'First paXYragraph here.\n\nSecond **bold** one.\n');
      assert.equal(await page.eval('app.refused'), 0);
    } finally {
      await page.close();
    }
  });

  test('inside and around formatting: typing at the end of a bold run stays bold, after it does not', async () => {
    const page = await open('Say **bold** now\n');
    try {
      await caretAt(page, 0, 8); // end of "bold"
      await type(page, 'X');
      await settle(page);
      assert.equal(await page.eval('app.text'), 'Say **boldX** now\n');
      assert.equal(await page.eval(`document.querySelector('#doc strong').textContent`), 'boldX');
      await page.eval(`(() => { MacDown2Preview.editingForTests.enterAt(0, null); const t = document.querySelector('#doc strong').nextSibling; getSelection().setBaseAndExtent(t, 0, t, 0); })()`);
      await type(page, 'Y');
      await settle(page);
      assert.equal(await page.eval('app.text'), 'Say **boldX**Y now\n');
    } finally {
      await page.close();
    }
  });

  test('Markdown typed in the preview shows as typed: written escaped where it would turn into markup', async () => {
    const page = await open('| a | b |\n|---|---|\n| cell | x |\n\nplain words here and *more*\n');
    try {
      await caretAt(page, 0, 0); // the table's text starts with its line breaks: find "cell"
      await page.eval(`(() => { const td = document.querySelectorAll('#doc td')[0]; MacDown2Preview.editingForTests.enterAt(0, null); getSelection().setBaseAndExtent(td.firstChild, 4, td.firstChild, 4); })()`);
      await type(page, '|');
      await settle(page);
      assert.equal(await page.eval('app.text'), '| a | b |\n|---|---|\n| cell\\| | x |\n\nplain words here and *more*\n');
      assert.equal(await page.eval(`document.querySelectorAll('#doc td')[0].textContent`), 'cell|');
      await caretAt(page, 4, 0);
      await type(page, '# '); // at once (a paste, an input method): escaped as a whole
      await settle(page);
      assert.equal(await page.eval(`document.querySelector('#doc p').textContent`), '# plain words here and more');
      assert.equal(await page.eval('app.text').then((t) => t.includes('\n\\# plain')), true);
      await caretAt(page, 4, 7);
      await type(page, '*'); // with the *more* after it, it would be emphasis
      await settle(page);
      assert.equal(await page.eval(`document.querySelector('#doc p').textContent`), '# plain* words here and more');
      assert.equal(await page.eval(`document.querySelectorAll('#doc p em').length`), 1); // still only the one emphasis
      assert.equal(await page.eval('app.refused'), 0);
      // one character at a time: "#" shows as itself, the space after it would make a heading of the line: refused
      await page.eval(`app.load('word\\n')`);
      await settle(page);
      await caretAt(page, 0, 0);
      await type(page, '#');
      await settle(page);
      await type(page, ' ');
      assert.equal(await page.eval(`document.getElementById('md2-hint')?.textContent`), 'H-formatting');
      await settle(page);
      assert.equal(await page.eval('app.text'), '#word\n');
      assert.equal(await page.eval(`document.querySelector('#doc p').textContent`), '#word');
    } finally {
      await page.close();
    }
  });

  test('words typed at the end of a paragraph keep their spaces, although Markdown does not show a trailing one', async () => {
    const page = await open('Some text.\n\nnext block\n');
    try {
      for (const delay of ['() => 0', '() => 15']) {
        await page.eval(`app.delay = ${delay}; app.load('Some text.\\n\\nnext block\\n')`);
        await settle(page);
        await caretAt(page, 0, 10);
        for (const c of ' more words.') {
          await type(page, c);
          if (delay === '() => 0') await settle(page); // every character comes back before the next: the space vanishes from the page each time
        }
        await compose(page, [' z', ' zh'], ' 中');
        await settle(page);
        assert.equal(await page.eval('app.text'), 'Some text. more words. 中\n\nnext block\n', `delay ${delay}`);
        assert.equal(await page.eval('app.refused'), 0);
      }
    } finally {
      await page.close();
    }
  });

  test('structural edits are refused with a hint and change nothing: Return, deleting across markup', async () => {
    const page = await open('ab **cd** ef\n');
    try {
      await caretAt(page, 0, 1);
      await key(page, 'Enter', 'Enter', 13);
      assert.equal(await page.eval(`document.getElementById('md2-hint')?.textContent`), 'H-newline');
      await page.eval(`(() => { const p = document.querySelector('#doc p'); getSelection().setBaseAndExtent(p.firstChild, 1, p.querySelector('strong').firstChild, 1); })()`);
      await backspace(page);
      assert.equal(await page.eval(`document.getElementById('md2-hint')?.textContent`), 'H-formatting');
      // the only character of an emphasis: deleting it would leave literal ** behind
      await page.eval(`(() => { const t = document.querySelector('#doc strong').firstChild; MacDown2Preview.editingForTests.enterAt(0, null); getSelection().setBaseAndExtent(t, 0, t, 2); })()`);
      await backspace(page);
      assert.equal(await page.eval(`document.getElementById('md2-hint')?.textContent`), 'H-formatting');
      assert.equal(await sentEdits(page), 0);
      assert.equal(await page.eval('app.text'), 'ab **cd** ef\n');
      assert.equal(await page.eval(`document.querySelector('#doc p').textContent`), 'ab cd ef');
    } finally {
      await page.close();
    }
  });

  test('Chinese input-method composition becomes one edit with every character, also while edits are still in flight', async () => {
    const page = await open('中文段落。\n\nnext\n');
    try {
      await page.eval('app.delay = () => 25'); // slow app: the composition starts before the typed character came back
      await caretAt(page, 0, 2);
      await type(page, 'a');
      await compose(page, ['z', 'zh', 'zhong', '中'], '中');
      await compose(page, ['w', 'wen'], '文字');
      await settle(page);
      assert.equal(await page.eval('app.text'), '中文a中文字段落。\n\nnext\n');
      assert.equal(await page.eval(`document.querySelector('#doc p').textContent`), '中文a中文字段落。');
      assert.equal(await page.eval('app.refused'), 0);
      assert.deepEqual(await page.eval('app.applied.map((m) => [m.seq, m.text])'), [[1, 'a'], [2, '中'], [3, '文字']]);
    } finally {
      await page.close();
    }
  });

  test('a long candidate selection outlasts the burst timeout: nothing is rebuilt under the input method, nothing is lost', async () => {
    const page = await open('alpha beta\n\nnext\n');
    try {
      await page.eval('MacDown2Preview.editingForTests.configure({ burstTimeoutMs: 120 })');
      await page.eval('app.delay = () => 400'); // the app is busy: the edit before the composition stays unanswered past the timeout
      await caretAt(page, 0, 5);
      await type(page, 'x');
      const p = await page.eval(`(window.__p = document.querySelector('#doc p'), true)`);
      void p;
      for (const s of ['zh', 'zho', 'zhon', 'zhong']) {
        await page.send('Input.imeSetComposition', { text: s, selectionStart: s.length, selectionEnd: s.length });
        await wait(page, 120); // half a second of candidates: the burst timeout comes and goes meanwhile
      }
      assert.equal(await page.eval(`document.querySelector('#doc p') === window.__p`), true, 'the block was rebuilt while composing');
      await page.eval('app.delay = () => 0'); // the app answers again
      await page.send('Input.insertText', { text: '中' });
      await settle(page);
      const msgs = JSON.stringify(await page.eval('[__msgs.filter((m) => m.type !== "selection"), app.why]'));
      assert.equal(await page.eval('app.text'), 'alphax中 beta\n\nnext\n', msgs);
      assert.equal(await page.eval('app.refused'), 0, msgs);
      assert.equal(await page.eval('__msgs.filter((m) => m.type === "resync").length'), 0, msgs);
    } finally {

      await page.eval('MacDown2Preview.editingForTests.configure({ burstTimeoutMs: 2000 })').catch(() => {});
      await page.close();
    }
  });

  test('an edit in another block while a burst is still in flight lands where it was typed', async () => {
    const page = await open('first block text\n\nsecond block text\n\nthird\n');
    try {
      await page.eval('app.delay = () => 30');
      await caretAt(page, 0, 5);
      for (const c of 'AAA') await type(page, c); // three characters before the second block
      await caretAt(page, 2, 6); // no settling: the burst is in flight
      await type(page, 'B');
      await backspace(page);
      await type(page, 'C');
      await caretAt(page, 0, 0);
      await forwardDelete(page); // and back to the first block, before what was typed there
      await settle(page);
      assert.equal(await page.eval('app.text'), 'irstAAA block text\n\nsecondC block text\n\nthird\n');
      assert.equal(await page.eval('app.refused'), 0);
    } finally {
      await page.close();
    }
  });

  test('the app learning late that a render landed does not refuse the next edit (message before continuation)', async () => {
    const page = await open('quick typing here\n');
    try {
      await page.eval('app.delay = () => 0; app.landing = () => 60');
      await caretAt(page, 0, 5);
      for (const c of 'abcdef') {
        await type(page, c);
        await wait(page, 10); // the render of the last character has landed in the page, the app does not know yet
      }
      await settle(page);
      assert.equal(await page.eval('app.text'), 'quickabcdef typing here\n');
      assert.equal(await page.eval('app.refused'), 0);
    } finally {
      await page.close();
    }
  });

  test('a late refusal of a burst that is over does not touch the current one', async () => {
    const page = await open('one two\n');
    try {
      await page.eval('app.delay = () => 200');
      await caretAt(page, 0, 3);
      await type(page, 'X');
      const state = await page.eval('MacDown2Preview.editingForTests.state()');
      assert.equal(await page.eval(`MacDown2Preview.editRefused('stale', ${state.burst.id - 1}, 1)`), false);
      assert.equal(await page.eval(`MacDown2Preview.editRefused('stale', ${state.burst.id}, ${state.burst.seq + 1})`), false);
      assert.deepEqual(await page.eval('MacDown2Preview.editingForTests.state().burst'), state.burst);
      await page.eval('app.delay = () => 0');
      await settle(page);
      assert.equal(await page.eval('app.text'), 'oneX two\n');
    } finally {
      await page.close();
    }
  });

  test('the app refusing an edit (its text moved on) puts its text back on the page, with one render', async () => {
    const page = await open('alpha beta\n');
    try {
      await page.eval('app.delay = () => 20');
      await caretAt(page, 0, 5);
      await type(page, 'X');
      await page.eval(`app.text = 'alpha beta gamma\\n'; app.chain = null`);
      const before = await page.eval('app.renders');
      await settle(page);
      assert.equal(await page.eval('app.refused'), 1);
      assert.equal(await page.eval('app.renders') - before, 1);
      assert.equal(await page.eval(`document.querySelector('#doc p').textContent`), 'alpha beta gamma');
      assert.equal(await page.eval(`document.getElementById('md2-hint')?.textContent`), 'H-stale');
    } finally {
      await page.close();
    }
  });

  test('a rebuild asked for with a held-back render does not reset the page', async () => {
    const page = await open('alpha\n\nbeta\n');
    try {
      await caretAt(page, 0, 5);
      await page.send('Input.imeSetComposition', { text: 'zh', selectionStart: 2, selectionEnd: 2 });
      await page.eval(`window.__p = document.querySelector('#doc p')`);
      const out = JSON.parse(await page.eval(`MacDown2Preview.update(app.text, OPTIONS, ++app.version, null, true)`));
      assert.equal(out.deferred, true);
      assert.equal(await page.eval(`document.querySelector('#doc p') === window.__p`), true);
      await page.send('Input.insertText', { text: '中' });
      await settle(page);
      assert.equal(await page.eval('app.text'), 'alpha中\n\nbeta\n');
    } finally {
      await page.close();
    }
  });

  test('a late refusal of an earlier burst on the same render does not end the next one', async () => {
    const page = await open('one two\n\nthree\n');
    try {
      await page.eval('app.delay = () => 150');
      await caretAt(page, 0, 3);
      await type(page, 'X');
      const first = await page.eval('MacDown2Preview.editingForTests.state().burst');
      assert.equal(await page.eval(`MacDown2Preview.editRefused('stale', ${first.id}, 1)`), true); // it goes: the page asks for the app's text
      await caretAt(page, 2, 3);
      await type(page, 'Y'); // before that text comes: a new burst (in a block the page still shows as rendered), on the same render
      const second = await page.eval('MacDown2Preview.editingForTests.state().burst');
      assert.equal(second.base, first.base);
      assert.notEqual(second.id, first.id);
      assert.equal(await page.eval(`MacDown2Preview.editRefused('stale', ${first.id}, 1)`), false); // the same answer again, late
      assert.deepEqual(await page.eval('MacDown2Preview.editingForTests.state().burst'), second);
    } finally {
      await page.close();
    }
  });

  test('a composition cancelled (Escape) shows the render that came meanwhile at once, also with an edit in flight', async () => {
    const page = await open('alpha beta\n\nnext\n');
    try {
      await page.eval('MacDown2Preview.editingForTests.configure({ burstTimeoutMs: 60000 })'); // no help from the timeout
      for (const inFlight of [false, true]) {
        await page.eval(`app.delay = () => ${inFlight ? 80 : 0}; app.load('alpha beta\\n\\nnext\\n')`);
        await settle(page);
        await caretAt(page, 0, 5);
        if (inFlight) await type(page, 'x');
        await page.send('Input.imeSetComposition', { text: 'zh', selectionStart: 2, selectionEnd: 2 });
        await wait(page, inFlight ? 250 : 0); // the app has the edit and renders it: held back, the input method composes
        await page.eval(`app.text = app.text.replace('next', 'next more'); app.push()`); // and a change from elsewhere: held back too
        assert.equal(await page.eval('MacDown2Preview.editingForTests.state().heldBack'), true);
        await page.send('Input.imeSetComposition', { text: '', selectionStart: 0, selectionEnd: 0 }); // Escape
        await settle(page);
        assert.equal(await page.eval('app.text'), inFlight ? 'alphax beta\n\nnext more\n' : 'alpha beta\n\nnext more\n');
        assert.equal(await docText(page), await freshText(await page.eval('app.text')));
        assert.equal(await hintText(page), null, 'no "the text changed" hint');
        assert.equal(await page.eval('app.refused'), 0);
      }
    } finally {
      await page.eval('MacDown2Preview.editingForTests.configure({ burstTimeoutMs: 2000 })').catch(() => {});
      await page.close();
    }
  });

  test('WebKit asking to insert a composition the page refuses: the app text comes back, with what was held back', async () => {
    const page = await open('alpha beta\n\nnext\n');
    try {
      await page.eval('MacDown2Preview.editingForTests.configure({ burstTimeoutMs: 60000, trace: true })');
      await caretAt(page, 0, 5);
      // WebKit's order of events, which Chrome does not send: compositionstart, then a cancelable insertFromComposition at the end
      await fire(page, `new CompositionEvent('compositionstart', { bubbles: true })`);
      await page.eval(`app.text = 'alpha beta\\n\\nnext more\\n'; app.push()`); // held back: it composes
      assert.equal(await fire(page, webkitInput('insertFromComposition', 'a\nb')), true);
      await settle(page).catch(async (e) => { throw new Error(`${e.message} ${JSON.stringify(await page.eval('[MacDown2Preview.editingForTests.events(), __msgs]'))}`); });
      assert.equal(await hintText(page), 'H-newline');
      assert.equal(await docText(page), await freshText('alpha beta\n\nnext more\n'));
      assert.equal(await sentEdits(page), 0);
    } finally {
      await page.eval('MacDown2Preview.editingForTests.configure({ burstTimeoutMs: 2000 })').catch(() => {});
      await page.close();
    }
  });

  test('a composition over a selection replaces it: in Chrome, and in WebKit with its deleteByComposition', async () => {
    const page = await open('alpha beta gamma\n');
    try {
      const select = (a, b) => page.eval(`(() => { MacDown2Preview.editingForTests.enterAt(0, null); const t = document.querySelector('#doc p').firstChild; getSelection().setBaseAndExtent(t, ${a}, t, ${b}); })()`);
      await select(6, 10); // "beta"
      await compose(page, ['z', 'zh'], '中');
      await settle(page);
      assert.equal(await page.eval('app.text'), 'alpha 中 gamma\n');
      // WebKit (as the app logs it): compositionstart over the selection, the composition replaces it, at the end the composition is
      // taken out again and a cancelable insertFromComposition asks for the committed text; the space left at the edge of the text
      // node is written as U+00A0 meanwhile. (Its deleteByComposition, sent elsewhere, is let through, not refused.)
      await select(6, 7); // "中"
      await fire(page, `new CompositionEvent('compositionstart', { bubbles: true })`);
      await page.eval(`(() => { getSelection().getRangeAt(0).deleteContents(); const t = document.querySelector('#doc p').firstChild; t.replaceData(5, 1, '\\u00a0'); })()`);
      assert.equal(await page.eval(`document.querySelector('#doc p').textContent`), 'alpha  gamma');
      assert.equal(await fire(page, webkitInput('insertFromComposition', '文')), true);
      await fire(page, `new CompositionEvent('compositionend', { data: '文', bubbles: true })`);
      await settle(page);
      assert.equal(await page.eval('app.text'), 'alpha 文 gamma\n');
      assert.equal(await page.eval(`document.querySelector('#doc p').textContent`), 'alpha 文 gamma');
      await select(6, 7);
      assert.equal(await fire(page, webkitInput('deleteByComposition', null)), false);
      assert.equal(await page.eval('MacDown2Preview.editingForTests.state().composing'), true); // its record has the selection
      await page.eval(`getSelection().getRangeAt(0).deleteContents()`);
      assert.equal(await fire(page, webkitInput('insertFromComposition', '字')), true);
      await settle(page);
      assert.equal(await page.eval('app.text'), 'alpha 字 gamma\n');
      assert.equal(await hintText(page), null);
      assert.equal(await page.eval('app.refused'), 0);
    } finally {
      await page.close();
    }
  });

  test('the render that catches up puts the caret where the user moved it since the last edit', async () => {
    const page = await open('alpha beta\n');
    try {
      await page.eval('app.delay = () => 60');
      await caretAt(page, 0, 5);
      await type(page, 'x');
      for (let i = 0; i < 3; i++) await arrow(page, 'ArrowLeft'); // before the app answers
      await settle(page);
      await type(page, 'Q');
      await settle(page);
      assert.equal(await page.eval('app.text'), 'alpQhax beta\n');
      // and a selection made meanwhile stays selected
      await caretAt(page, 0, 2);
      await type(page, 'y');
      await page.eval(`(() => { const t = document.querySelector('#doc p').firstChild; getSelection().setBaseAndExtent(t, 5, t, 9); })()`); // "hax " of "alypQhax beta"
      await settle(page);
      assert.equal(await page.eval('getSelection().toString()'), 'hax ');
    } finally {
      await page.close();
    }
  });

  test('a render that fails to catch up leaves a consistent page: the burst and edit mode go, the next render shows the text', async () => {
    const page = await open('alpha beta\n');
    try {
      await caretAt(page, 0, 5);
      await page.eval('app.failNext = true');
      await type(page, 'x');
      for (let i = 0; i < 100 && !(await page.eval('app.applied.length === 1 && !app.landingsDue && app.renders >= 2')); i++) await wait(page, 5);
      assert.deepEqual(await page.eval('MacDown2Preview.editingForTests.state()'), { editing: false, burst: null, composing: false, heldBack: false });
      assert.equal(await page.eval(`document.querySelector('#doc p').textContent`), 'alphax beta'); // the edit stays on the page
      await page.eval('app.push()');
      await settle(page);
      await caretAt(page, 0, 6);
      await type(page, 'y');
      await settle(page);
      assert.equal(await page.eval('app.text'), 'alphaxy beta\n');
      assert.equal(await page.eval('app.refused'), 0);
    } finally {
      await page.close();
    }
  });

  test('a render held back with another document folder changes nothing on the page (its blocks stay)', async () => {
    const page = await open('alpha\n\nbeta\n');
    try {
      await page.eval(`app.base = 'file:///one/'; app.push()`);
      await settle(page);
      await caretAt(page, 0, 5);
      await page.send('Input.imeSetComposition', { text: 'zh', selectionStart: 2, selectionEnd: 2 });
      await page.eval(`app.base = 'file:///two/'; app.push()`); // held back: it composes
      await page.eval(`app.base = 'file:///one/'`);
      await page.send('Input.insertText', { text: '中' });
      await settle(page);
      assert.equal(await page.eval('app.text'), 'alpha中\n\nbeta\n');
      assert.deepEqual(await page.eval('__updates.filter((u) => !u.deferred).slice(-1).map((u) => u.mode)'), ['patch'], 'the block table survived the held-back render');
    } finally {
      await page.close();
    }
  });

  test('undo steps: typing on goes on in the same step across renders; a jump or another block starts a new one', async () => {
    const page = await open('alpha beta\n\ngamma\n');
    try {
      await caretAt(page, 0, 5);
      for (const c of 'xyz') {
        await type(page, c);
        await settle(page); // a render after every key: still one typing step
      }
      await backspace(page);
      await settle(page);
      await arrow(page, 'ArrowLeft'); // the caret moves away and back: the editor starts a new step after that too
      await arrow(page, 'ArrowRight');
      await type(page, 'W');
      await settle(page);
      await type(page, 'V'); // and typing on goes on in it
      await settle(page);
      await caretAt(page, 0, 0); // a caret jump
      await type(page, 'Q');
      await settle(page);
      await caretAt(page, 2, 5); // another block
      await type(page, 'R');
      await settle(page);
      assert.equal(await page.eval('app.text'), 'QalphaxyWV beta\n\ngammaR\n');
      assert.deepEqual(await page.eval('app.applied.map((m) => [m.text, m.step])'), [['x', true], ['y', false], ['z', false], ['', false], ['W', true], ['V', false], ['Q', true], ['R', true]]);
    } finally {
      await page.close();
    }
  });

  test('editing off: nothing becomes editable', async () => {
    const page = await open('text\n');
    try {
      await page.eval('MacDown2Preview.setEditing({ enabled: false })');
      const at = await page.eval(`(() => { const t = document.querySelector('#doc p').firstChild; const r = document.createRange(); r.setStart(t, 1); r.setEnd(t, 2); const b = r.getBoundingClientRect(); return [b.left + 1, b.top + b.height / 2]; })()`);
      for (const type of ['mousePressed', 'mouseReleased']) await page.send('Input.dispatchMouseEvent', { type, x: at[0], y: at[1], button: 'left', clickCount: 1 });
      assert.equal(await page.eval(`document.querySelectorAll('#doc [contenteditable]').length`), 0);
    } finally {
      await page.close();
    }
  });

  // --- two-way selection -------------------------------------------------------------------------------------------------------

  test('the editor selection shows as a highlight over exactly the mapped text, whole blocks where nothing maps', async () => {
    const page = await open('Hello **bold** world\n\n```\ncode\n```\n\nlast\n');
    try {
      const v = await page.eval('app.displayed.version');
      const highlighted = () => page.eval(`[...(CSS.highlights.get('md2-peer') ?? [])].map((r) => r.toString())`);
      assert.equal(await page.eval(`MacDown2Preview.highlightSource(3, 10, ${v})`), 2);
      assert.deepEqual(await highlighted(), ['lo ', 'bo']);
      await page.eval(`MacDown2Preview.highlightSource(15, 27, ${v})`);
      assert.deepEqual((await highlighted()).map((s) => s.trim()), ['world', 'code']);
      await page.eval(`MacDown2Preview.highlightSource(0, 5, ${v - 1})`);
      assert.deepEqual(await highlighted(), []);
    } finally {
      await page.close();
    }
  });

  test('the page selection goes to the app as the source range of the selected text', async () => {
    const page = await open('Hello **bold** world\n\n- item one\n- item two\n');
    try {
      const last = async () => {
        await wait(page, 40);
        return page.eval('__msgs.filter((m) => m.type === "selection").at(-1)');
      };
      await page.eval(`(() => { const p = document.querySelector('#doc p'); getSelection().setBaseAndExtent(p.firstChild, 2, p.querySelector('strong').firstChild, 2); })()`);
      const sel = await last();
      const text = await page.eval('app.text');
      assert.equal(text.slice(sel.from, sel.to), 'llo **bo');
      await page.eval(`(() => { const p = document.querySelector('#doc p'); const li = document.querySelectorAll('#doc li')[1]; getSelection().setBaseAndExtent(p.lastChild, 1, li.firstChild, 6); })()`);
      const across = await last();
      assert.equal(text.slice(across.from, across.to), 'world\n\n- item one\n- item t');
      // from after the paragraph's last character to the start of the first item: nothing of either block is taken whole
      await page.eval(`(() => { const p = document.querySelector('#doc p'); const li = document.querySelectorAll('#doc li')[0]; getSelection().setBaseAndExtent(p.lastChild, p.lastChild.data.length, li.firstChild, 0); })()`);
      const edges = await last();
      assert.equal(text.slice(edges.from, edges.to), '\n\n- ');
      await page.eval('getSelection().removeAllRanges()');
      const cleared = await last();
      assert.deepEqual([cleared.from, cleared.to], [-1, -1]);
    } finally {
      await page.close();
    }
  });

  // --- fuzz --------------------------------------------------------------------------------------------------------------------

  const LETTERS = ['a', 'b', 'k', 'Q', '7', '字', '文', 'é'];
  // Plain blocks: words of letters and single spaces, behind a fixed prefix. Shown unit k of block j is source offset start + prefix + k.
  function plainDoc(r) {
    const blocks = [];
    for (let i = 0, n = 2 + r.int(4); i < n; i++) {
      const words = Array.from({ length: 2 + r.int(5) }, () => Array.from({ length: 2 + r.int(6) }, () => r.pick(LETTERS)).join(''));
      let prefix = r.pick(['', '', '# ', '- ', '> ']);
      if (prefix === '- ' && blocks.at(-1)?.prefix === '- ') prefix = ''; // two lists in a row are one loose list
      blocks.push({ prefix, text: words.join(' ') });
    }
    return blocks;
  }
  const sourceOf = (blocks) => blocks.map((b) => b.prefix + b.text).join('\n\n') + '\n';
  const lineOf = (j) => 2 * j;
  const DELAYS = ['() => 0', '() => Math.floor(Math.random() * 8)', '() => Math.floor(Math.random() * 40)'];

  test('fuzz: typing, deleting and composing at random places, in several blocks of a burst, with random app latency, edit the source exactly as the same edits made there', async () => {
    const seeds = SEED === null ? Array.from({ length: ROUNDS }, (_, i) => i + 1) : [SEED];
    let ops = 0;
    for (const seed of seeds) {
      const r = rng(seed);
      const blocks = plainDoc(r);
      const page = await open(sourceOf(blocks));
      try {
        await page.eval(`app.delay = ${r.pick(DELAYS)}; app.landing = ${r.pick(DELAYS)}`);
        let j = r.int(blocks.length);
        let k = r.int(blocks[j].text.length + 1);
        const log = [`caret ${j}:${k}`];
        assert.equal(await caretAt(page, lineOf(j), k), true);
        for (let step = 0, n = 4 + r.int(12); step < n; step++) {
          const b = blocks[j];
          const op = r.int(10);
          if (op < 4) {
            const c = r.pick(LETTERS);
            await type(page, c);
            b.text = b.text.slice(0, k) + c + b.text.slice(k);
            k += 1;
            log.push(`type ${c}`);
          } else if (op < 6) {
            // only a letter between letters (a space at the start or end of a block would not show, and the model would drift)
            if (k >= 2 && b.text[k - 1] !== ' ' && b.text[k - 2] !== ' ' && (k === b.text.length || b.text[k] !== ' ')) {
              await backspace(page);
              b.text = b.text.slice(0, k - 1) + b.text.slice(k);
              k -= 1;
              log.push('backspace');
            }
          } else if (op < 7) {
            if (k + 2 <= b.text.length && k > 0 && b.text[k] !== ' ' && b.text[k + 1] !== ' ' && b.text[k - 1] !== ' ') {
              await forwardDelete(page);
              b.text = b.text.slice(0, k) + b.text.slice(k + 1);
              log.push('delete');
            }
          } else if (op < 9) {
            const commit = r.pick(['中', '文字', '汉字词', 'é']);
            await compose(page, ['z', 'zh', 'zho'].slice(0, 1 + r.int(3)), commit, r.int(3) === 0 ? 30 : 0);
            b.text = b.text.slice(0, k) + commit + b.text.slice(k);
            k += commit.length;
            log.push(`compose ${commit}`);
          } else {
            // a new place, maybe in another block; half the time without waiting for the app (the burst still in flight)
            if (r.int(2)) await settle(page);
            j = r.int(blocks.length);
            k = r.int(blocks[j].text.length + 1);
            assert.equal(await caretAt(page, lineOf(j), k), true, `seed ${seed}: caret ${j}:${k}`);
            log.push(`caret ${j}:${k}`);
          }
          ops++;
        }
        await settle(page).catch(async (e) => {
          const file = join(tmpdir(), 'md2-preview-edit-failure.json');
          writeFileSync(file, JSON.stringify(await page.eval('({ msgs: __msgs.filter((m) => m.type !== "selection"), why: app.why ?? null, updates: window.__updates ?? null })'), null, 1));
          throw new Error(`seed ${seed}: ${log.join(', ')}: ${e.message} (messages in ${file})`);
        });
        const want = sourceOf(blocks);
        const got = await page.eval('app.text');
        if (got !== want) {
          const msgs = await page.eval('__msgs.filter((m) => m.type !== "selection")');
          assert.equal(got, want, `seed ${seed}: ${log.join(', ')}\n${JSON.stringify(msgs)}`);
        }
        assert.equal(await page.eval('app.refused'), 0, `seed ${seed}: refused`);
        assert.equal(await docText(page), await freshText(want), `seed ${seed}: the page and a fresh render differ`);
      } finally {
        await page.close();
      }
    }
    console.log(`preview-edit fuzz: ${seeds.length} rounds, ${ops} operations`);
  });

  // Formatted blocks and Markdown punctuation typed into them.
  const SYNTAX = ['*', '_', '`', '|', '#', '<', '>', '[', ']', '(', ')', '!', '~', '=', '^', '$', '\\', '&', ':', '-', '+', '.', 'a', '中'];
  const FORMATTED = [
    'Some *em* and **strong** text', 'Code `x = 1` and [a link](http://x.y)', '| one | two |\n|---|---|\n| three | four |',
    '# A heading', '- item *one*\n- item two', '> quoted **text**', 'mixed ~~gone~~ and ==mark== words',
  ];

  test('fuzz: Markdown punctuation typed into formatted text shows exactly as typed, or is refused and changes nothing', async () => {
    const seeds = SEED === null ? Array.from({ length: ROUNDS }, (_, i) => i + 1) : [SEED];
    let accepted = 0;
    let refusedByPage = 0;
    for (const seed of seeds) {
      const r = rng(seed * 31 + 7);
      const doc = Array.from({ length: 2 + r.int(3) }, () => r.pick(FORMATTED)).filter((b, i, a) => !(b.startsWith('- ') && a[i - 1]?.startsWith('- '))).join('\n\n') + '\n';
      const page = await open(doc);
      try {
        await page.eval(`app.delay = ${r.pick(DELAYS)}`);
        for (let n = 0, ops = 3 + r.int(6); n < ops; n++) {
          // a random place in a random text node of a random block
          const placed = await page.eval(`(() => {
            const tops = [...document.querySelectorAll('#doc > [data-line]')];
            const top = tops[${r.int(1000)} % tops.length];
            const nodes = []; const w = document.createTreeWalker(top, NodeFilter.SHOW_TEXT); let t;
            while ((t = w.nextNode())) if (t.data.trim()) nodes.push(t);
            if (!nodes.length || !MacDown2Preview.editingForTests.enterAt(Number(top.dataset.line), null)) return null;
            const node = nodes[${r.int(1000)} % nodes.length]; const at = ${r.int(1000)} % (node.data.length + 1);
            getSelection().setBaseAndExtent(node, at, node, at);
            return [...document.querySelectorAll('#doc > *')].map((e) => e.textContent).join('|');
          })()`);
          if (placed === null) continue;
          const c = r.pick(SYNTAX);
          const before = await sentEdits(page);
          await type(page, c);
          const after = await sentEdits(page);
          if (after === before) {
            refusedByPage++;
            assert.equal(await docText(page), placed, `seed ${seed}: a refused ${JSON.stringify(c)} changed the page`);
            continue;
          }
          accepted++;
          // the page shows what was typed now; once the app has the edit, rendering its whole text from scratch shows the same
          const shown = await docText(page);
          await settle(page);
          assert.equal(await freshText(await page.eval('app.text')), shown, `seed ${seed}: ${JSON.stringify(c)} did not show as typed in ${JSON.stringify(await page.eval('app.text'))}`);
        }
        assert.equal(await page.eval('app.refused'), 0, `seed ${seed}`);
      } finally {
        await page.close();
      }
    }
    assert.ok(accepted > refusedByPage, `accepted ${accepted}, refused ${refusedByPage}`);
    console.log(`preview-edit syntax fuzz: ${seeds.length} rounds, ${accepted} accepted, ${refusedByPage} refused by the page`);
  });
});
