// Preview editing and two-way selection on the real page (src/preview/editing.ts, peer.ts), in headless Chrome. The app is played
// by a small simulator inside the page that does what PreviewModel and EditorHandle do: it applies an edit only when its text is
// the text the edit was made on (the burst chain), renders after a random delay with the burst's mark, and re-renders on a resync.
// Input goes through Chrome's own input pipeline (DevTools Input.insertText / dispatchKeyEvent / imeSetComposition), so the page
// sees what a keyboard or an input method produces.
//
// The plain-text fuzz knows where every shown character is in the source without the source map (its documents have no markup
// inside the text), so "the same edit made in the source" is computed independently and compared character for character, after
// random typing, deleting and Chinese input-method composition at random places with random app latency.
//
// MD2_EDIT_FUZZ=<n> scales the fuzz (default 30 rounds), MD2_EDIT_SEED=<n> replays one.
import { after, before, describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { renderResult } from '../src/render/index.ts';
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

// The app, inside the page. Messages reach it in order, each after `delay` ms (WKScriptMessageHandler is ordered); a render goes
// out `delay` ms after the text changed, the latest text wins (PreviewModel's frame wait and push loop).
const APP = `
window.app = {
  text: '', version: 0, displayed: null, chain: null, applied: [], refused: 0, delay: () => 0, queue: [], busy: false, timer: null,
  load(text) { this.text = text; this.chain = null; this.push(); },
  push() {
    const v = ++this.version, md = this.text;
    const mark = this.chain && this.chain.text === md ? { base: this.chain.base, seq: this.chain.seq } : null;
    const out = JSON.parse(MacDown2Preview.update(md, OPTIONS, v, mark));
    if (!out.deferred && !out.error) this.displayed = { version: v, text: md };
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
      if (m.seq === 1) { if (this.displayed && this.displayed.version === m.base) expected = this.displayed.text; }
      else if (this.chain && this.chain.base === m.base && this.chain.seq === m.seq - 1) expected = this.chain.text;
      if (expected === null || this.text !== expected || /[\\r\\n]/.test(m.text) || m.to > expected.length) {
        this.refused++; this.chain = null; MacDown2Preview.editRefused('stale'); this.schedule(); return;
      }
      this.text = expected.slice(0, m.from) + m.text + expected.slice(m.to);
      this.chain = { base: m.base, seq: m.seq, text: this.text };
      this.applied.push(m);
      this.schedule();
    } else if (m.type === 'resync') this.schedule();
  },
  settled() { return !this.busy && this.queue.length === 0 && this.displayed && this.displayed.text === this.text && !MacDown2Preview.editingForTests.state().burst; },
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
    return page;
  }
  const settle = async (page) => {
    for (let i = 0; i < 400; i++) {
      if (await page.eval('app.settled()')) return;
      await page.eval('new Promise((r) => setTimeout(r, 5))');
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
  const forwardDelete = (page) => key(page, 'Delete', 'Delete', 46);
  const compose = async (page, steps, commit) => {
    for (const s of steps) await page.send('Input.imeSetComposition', { text: s, selectionStart: s.length, selectionEnd: s.length });
    await page.send('Input.insertText', { text: commit });
  };
  const docText = (page) => page.eval(`[...document.querySelectorAll('#doc > *')].map((e) => e.textContent).join('|')`);
  const freshText = (text) => {
    const html = renderResult(text, OPTIONS).html;
    return html; // compared through a page below
  };

  test('a click puts the caret in the block and makes only that block editable; typing reaches the source', async () => {
    const page = await open('First paragraph here.\n\nSecond **bold** one.\n');
    try {
      // a real click in the middle of "paragraph"
      const at = await page.eval(`(() => { const t = document.querySelector('#doc p').firstChild; const r = document.createRange(); r.setStart(t, 8); r.setEnd(t, 9); const b = r.getBoundingClientRect(); return [b.left + 1, b.top + b.height / 2]; })()`);
      for (const type of ['mousePressed', 'mouseReleased']) await page.send('Input.dispatchMouseEvent', { type, x: at[0], y: at[1], button: 'left', clickCount: 1 });
      assert.deepEqual(await page.eval(`[...document.querySelectorAll('#doc [contenteditable]')].map((e) => e.tagName)`), ['P']);
      await type(page, 'X');
      await settle(page);
      assert.equal(await page.eval('app.text'), 'First paXragraph here.\n\nSecond **bold** one.\n');
      // the caret is back after the X once the render replaced the block, and typing goes on from there
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
      // the start of the text node after </strong>
      await page.eval(`(() => { MacDown2Preview.editingForTests.enterAt(0, null); const t = document.querySelector('#doc strong').nextSibling; getSelection().setBaseAndExtent(t, 0, t, 0); })()`);
      await type(page, 'Y');
      await settle(page);
      assert.equal(await page.eval('app.text'), 'Say **boldX**Y now\n');
    } finally {
      await page.close();
    }
  });

  test('words typed at the end of a paragraph keep their spaces, although Markdown does not show a trailing one', async () => {
    const page = await open('Some text.\n\nnext block\n');
    try {
      for (const delay of ['() => 0', '() => 15']) {
        await page.eval(`app.delay = ${delay}; app.load('Some text.\\n\\nnext block\\n')`);
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

  test('structural edits are refused with a hint and change nothing: Return, deleting across markup, a rich paste', async () => {
    const page = await open('ab **cd** ef\n');
    try {
      await caretAt(page, 0, 1);
      await key(page, 'Enter', 'Enter', 13);
      assert.equal(await page.eval(`document.getElementById('md2-hint')?.textContent`), 'H-newline');
      // a selection from inside the plain text into the bold: deleting it would delete the ** too
      await page.eval(`(() => { const p = document.querySelector('#doc p'); getSelection().setBaseAndExtent(p.firstChild, 1, p.querySelector('strong').firstChild, 1); })()`);
      await backspace(page);
      assert.equal(await page.eval(`document.getElementById('md2-hint')?.textContent`), 'H-formatting');
      assert.deepEqual(await page.eval('__msgs.filter((m) => m.type === "previewEdit")'), []);
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

  test('the app refusing an edit (its text moved on) puts its text back on the page', async () => {
    const page = await open('alpha beta\n');
    try {
      await page.eval('app.delay = () => 20');
      await caretAt(page, 0, 5);
      await type(page, 'X');
      // something else changes the text before the edit arrives (the editor, an undo, the file on disk)
      await page.eval(`app.text = 'alpha beta gamma\\n'; app.chain = null`);
      await page.eval('new Promise((r) => setTimeout(r, 80))');
      await settle(page);
      assert.equal(await page.eval('app.refused'), 1);
      assert.equal(await page.eval(`document.querySelector('#doc p').textContent`), 'alpha beta gamma');
      assert.equal(await page.eval(`document.getElementById('md2-hint')?.textContent`), 'H-stale');
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
      // "lo **bo": the markup is not text, the highlight covers "lo bo"
      assert.equal(await page.eval(`MacDown2Preview.highlightSource(3, 10, ${v})`), 2);
      assert.deepEqual(await highlighted(), ['lo ', 'bo']);
      // into the code block, which has no map: all of it
      await page.eval(`MacDown2Preview.highlightSource(15, 27, ${v})`);
      assert.deepEqual((await highlighted()).map((s) => s.trim()), ['world', 'code']);
      // a stale version clears it
      await page.eval(`MacDown2Preview.highlightSource(0, 5, ${v - 1})`);
      assert.deepEqual(await highlighted(), []);
    } finally {
      await page.close();
    }
  });

  test('the page selection goes to the app as the source range of the selected text', async () => {
    const page = await open('Hello **bold** world\n\n- item one\n- item two\n');
    try {
      await page.eval(`(() => { const p = document.querySelector('#doc p'); getSelection().setBaseAndExtent(p.firstChild, 2, p.querySelector('strong').firstChild, 2); })()`);
      await page.eval('new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))');
      const sel = await page.eval('__msgs.filter((m) => m.type === "selection").at(-1)');
      assert.deepEqual([sel.from, sel.to], [2, 10]); // "llo **bo"
      const text = await page.eval('app.text');
      assert.equal(text.slice(sel.from, sel.to), 'llo **bo');
      // across blocks: from "world" to "item t"
      await page.eval(`(() => { const p = document.querySelector('#doc p'); const li = document.querySelectorAll('#doc li')[1]; getSelection().setBaseAndExtent(p.lastChild, 1, li.firstChild, 6); })()`);
      await page.eval('new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))');
      const across = await page.eval('__msgs.filter((m) => m.type === "selection").at(-1)');
      assert.equal(text.slice(across.from, across.to), 'world\n\n- item one\n- item t');
      await page.eval('getSelection().removeAllRanges()');
      await page.eval('new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))');
      const cleared = await page.eval('__msgs.filter((m) => m.type === "selection").at(-1)');
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
  const startOf = (blocks, j) => blocks.slice(0, j).reduce((n, b) => n + b.prefix.length + b.text.length + 2, 0);
  const lineOf = (j) => 2 * j;

  test('fuzz: typing, deleting and composing at random places with a random app delay edit the source exactly as the same edits made there', async () => {
    const seeds = SEED === null ? Array.from({ length: ROUNDS }, (_, i) => i + 1) : [SEED];
    let ops = 0;
    for (const seed of seeds) {
      const r = rng(seed);
      const blocks = plainDoc(r);
      const page = await open(sourceOf(blocks));
      try {
        const slow = r.int(3);
        await page.eval(`app.delay = () => ${slow === 0 ? 0 : slow === 1 ? 'Math.floor(Math.random() * 8)' : 'Math.floor(Math.random() * 40)'}`);
        let j = r.int(blocks.length);
        let k = r.int(blocks[j].text.length + 1);
        const log = [`caret ${j}:${k}`];
        assert.equal(await caretAt(page, lineOf(j), k), true, `seed ${seed}: first caret ${j}:${k} in ${JSON.stringify(sourceOf(blocks))} / ${await docText(page)}`);
        for (let step = 0, n = 4 + r.int(10); step < n; step++) {
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
            await compose(page, ['z', 'zh', 'zho'].slice(0, 1 + r.int(3)), commit);
            b.text = b.text.slice(0, k) + commit + b.text.slice(k);
            k += commit.length;
            log.push(`compose ${commit}`);
          } else {
            // move: settle first (a click lands on what the page shows), then a new place, maybe in another block
            await settle(page);
            j = r.int(blocks.length);
            k = r.int(blocks[j].text.length + 1);
            assert.equal(await caretAt(page, lineOf(j), k), true, `seed ${seed}: caret ${j}:${k} in ${JSON.stringify(sourceOf(blocks))} / ${await docText(page)}`);
            log.push(`caret ${j}:${k}`);
          }
          ops++;
        }
        await settle(page);
        const want = sourceOf(blocks);
        const got = await page.eval('app.text');
        if (got !== want) {
          const msgs = await page.eval('__msgs.filter((m) => m.type !== "selection")');
          assert.equal(got, want, `seed ${seed} (delay mode ${slow}): ${log.join(', ')}\n${JSON.stringify(msgs)}`);
        }
        assert.equal(await page.eval('app.refused'), 0, `seed ${seed}: refused`);
        // what the page shows is what rendering the final text from scratch shows
        const shown = await docText(page);
        const fresh = await browser.newPage();
        try {
          await fresh.goto('/preview.html');
          await fresh.eval(`MacDown2Preview.update(${JSON.stringify(want)}, ${JSON.stringify(JSON.stringify(OPTIONS))}, 1)`);
          assert.equal(shown, await docText(fresh), `seed ${seed}: the page and a fresh render differ`);
        } finally {
          await fresh.close();
        }
        void startOf;
        void freshText;
      } finally {
        await page.close();
      }
    }
    console.log(`preview-edit fuzz: ${seeds.length} rounds, ${ops} operations`);
  });
});
