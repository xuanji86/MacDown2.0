// Scroll sync regression cases (ISSUE-REVIEW 3.B), run against the real preview page in headless Chrome.
// The page maps source lines to y from markdown-it's token.map (data-line on every block, leaves inside long blocks), so
// these pin down what the old Hoedown-era apps got wrong: two parsers disagreeing, linear interpolation over uneven
// content, typing pulling the editor around, sync switched off but still moving, re-render jumping to the top.
import { after, before, describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { renderResult } from '../src/render/index.ts';
import { chromeAvailable, launch, png } from './helpers/chrome.mjs';

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
const optionsJSON = JSON.stringify(OPTIONS);
const para = (n) => `Paragraph ${n}. ${'lorem ipsum dolor sit amet '.repeat(6 + (n % 5))}\n`;
const lorem = (count, from = 0) => Array.from({ length: count }, (_, i) => para(from + i)).join('\n');

// --- pure: the renderer's side of the contract (no browser needed) -------------------------------------------------

describe('source line map (renderer)', () => {
  test('fenced code that looks like headings is one block and adds no outline entries', () => {
    const md = ['# Real', '', '```md', '# not a heading', 'Not setext', '===', '## nor this', '```', '', 'Setext', '------', '', '####### seven', ''].join('\n');
    const { outline, blocks, html } = renderResult(md, OPTIONS);
    assert.deepEqual(outline.map((o) => [o.level, o.text, o.line]), [[1, 'Real', 0], [2, 'Setext', 9]]);
    assert.deepEqual(blocks.map((b) => [b.lineStart, b.lineEnd]), [[0, 1], [2, 8], [9, 11], [12, 13]]);
    assert.match(html, /<pre data-line="2" data-line-end="8"/);
    assert.match(html, /<h2 data-line="9" data-line-end="11" id="setext">/);
    assert.match(html, /<p data-line="12" data-line-end="13">####### seven<\/p>/); // 7 hashes: a paragraph
  });

  test('every list item carries its own line range, so a long list has anchors inside it', () => {
    const md = Array.from({ length: 300 }, (_, i) => `- item ${i}`).join('\n');
    const { html, blocks } = renderResult(md, OPTIONS);
    assert.equal(blocks.length, 1);
    assert.equal(html.match(/<li data-line="\d+" data-line-end="\d+">/g).length, 300);
    assert.match(html, /<li data-line="149" data-line-end="150">item 149<\/li>/);
  });

  test('a 5000-line document: blocks tile the source without overlap', () => {
    const md = Array.from({ length: 1000 }, (_, i) => `## Section ${i}\n\ntext ${i}\nmore ${i}\n`).join('\n');
    const { blocks } = renderResult(md, OPTIONS);
    for (let i = 1; i < blocks.length; i++) assert.ok(blocks[i].lineStart >= blocks[i - 1].lineEnd, `block ${i}`);
    assert.equal(blocks.length, 2000);
  });
});

// --- in the page ---------------------------------------------------------------------------------------------------

// Helpers evaluated inside the page. `top(line)`: viewport y of the deepest element that starts at source line `line`.
const HELPERS = `
  window.top0 = (line) => { const all = document.querySelectorAll('[data-line="' + line + '"]'); return all.length ? all[all.length - 1].getBoundingClientRect().top : null; };
  window.wait = (ms) => new Promise((r) => setTimeout(r, ms));
  window.OPTIONS = ${JSON.stringify(optionsJSON)};
  window.up = (md, opts = window.OPTIONS) => JSON.parse(MacDown2Preview.update(md, opts));
`;

describe('scroll sync (preview page, headless Chrome)', { skip: !chromeAvailable && 'no Chrome (set CHROME_BIN)' }, () => {
  let browser;
  const delays = {};
  before(async () => {
    const slow = (req, res, url) => {
      const h = Number(url.searchParams.get('h') ?? 200);
      const ms = Number(url.searchParams.get('ms') ?? 150);
      setTimeout(() => {
        res.setHeader('Content-Type', 'image/png');
        res.setHeader('Cache-Control', 'no-store');
        res.end(png(300, h));
      }, ms);
      delays.last = ms;
    };
    browser = await launch({ routes: { '/img.png': slow } });
  });
  after(async () => browser?.close());

  async function open(md) {
    const page = await browser.newPage();
    await page.goto('/preview.html');
    await page.eval(HELPERS);
    await page.eval(`up(${JSON.stringify(md)})`);
    return page;
  }

  test('fenced "headings": scrolling to a line lands on the real block, the fence is not mistaken for headings', async () => {
    const md = `${lorem(40)}\n# Real heading\n\n\`\`\`md\n# not a heading\nNot setext\n===\n## nor this\n\`\`\`\n\nSetext heading\n---------------\n\n${lorem(40, 50)}`;
    const lines = md.split('\n');
    const real = lines.indexOf('# Real heading');
    const setext = lines.indexOf('Setext heading');
    const fence = lines.indexOf('```md');
    const page = await open(md);
    try {
      for (const [line, what] of [[real, 'h1'], [fence, 'pre'], [setext, 'h2']]) {
        await page.eval(`MacDown2Preview.scrollToLine(${line})`);
        const t = await page.eval(`top0(${line})`);
        assert.ok(Math.abs(t) <= 1, `${what} at line ${line} is ${t}px from the top`);
        const back = await page.eval('MacDown2Preview.visibleTopLine()');
        assert.ok(Math.abs(back - line) < 0.1, `${what}: top line reads ${back}, wanted ${line}`);
      }
      // a line inside the fence maps into the <pre>, never into the following heading
      const inside = fence + 3;
      await page.eval(`MacDown2Preview.scrollToLine(${inside})`);
      const { preTop, preBottom } = await page.eval(`(() => { const r = document.querySelector('pre[data-line="${fence}"]').getBoundingClientRect(); return { preTop: r.top, preBottom: r.bottom }; })()`);
      assert.ok(preTop < 0 && preBottom > 0, 'viewport top is inside the fence');
      // and the outline the page reports ignores everything inside the fence
      const outline = await page.eval(`up(${JSON.stringify(md)}).outline.map((o) => o.text)`);
      assert.deepEqual(outline, ['Real heading', 'Setext heading']);
    } finally {
      await page.close();
    }
  });

  test('a 300-line list with no headings maps linearly per item, not across the whole list', async () => {
    // every 7th item wraps to several lines, so a block-level linear guess would drift by tens of pixels
    const items = Array.from({ length: 300 }, (_, i) => (i % 7 === 0 ? `- item ${i} ${'wrapped words here '.repeat(40)}` : `- item ${i}`));
    const md = `${lorem(5)}\n${items.join('\n')}\n\n${lorem(5, 10)}`;
    const first = md.split('\n').indexOf(items[0]);
    const page = await open(md);
    try {
      for (const n of [3, 77, 150, 151, 222, 290]) {
        const line = first + n;
        await page.eval(`MacDown2Preview.scrollToLine(${line})`);
        const t = await page.eval(`top0(${line})`);
        assert.ok(Math.abs(t) <= 1, `item ${n} (line ${line}) is ${t}px from the top`);
      }
      // reading back: the line at the top after scrolling to a fractional position inside an item
      await page.eval(`MacDown2Preview.scrollToLine(${first + 150.5})`);
      const back = await page.eval('MacDown2Preview.visibleTopLine()');
      assert.ok(Math.abs(back - (first + 150.5)) < 0.05, `read back ${back}`);
    } finally {
      await page.close();
    }
  });

  test('images that load late move the content: the line that was at the top stays at the top', async () => {
    // 12 images of different heights above the target, each answering after a delay; until then they have no height
    const heights = [120, 480, 60, 300, 700, 90, 250, 410, 180, 520, 75, 330];
    const imgs = heights.map((h, i) => `![img ${i}](/img.png?h=${h}&ms=${150 + i * 40}&n=${i})\n`).join('\n');
    const md = `${lorem(8)}\n${imgs}\n${lorem(8, 20)}\n# Target\n\n${lorem(30, 40)}`;
    const target = md.split('\n').indexOf('# Target');
    const page = await open(md);
    try {
      await page.eval(`MacDown2Preview.scrollToLine(${target})`);
      await page.eval('wait(1500)'); // every image is in by now and the page grew under us
      const loaded = await page.eval(`[...document.images].every((i) => i.complete && i.naturalHeight > 0)`);
      assert.ok(loaded, 'images loaded');
      const t = await page.eval(`top0(${target})`);
      assert.ok(Math.abs(t) <= 2, `Target heading ended up ${t}px from the top after the images arrived`);
      // and the map is still right for a fresh request
      await page.eval('MacDown2Preview.scrollToLine(0)');
      await page.eval(`MacDown2Preview.scrollToLine(${target})`);
      assert.ok(Math.abs(await page.eval(`top0(${target})`)) <= 1);
    } finally {
      await page.close();
    }
  });

  test('a block that grows after render (formula fonts arriving) does not drag the viewport', async () => {
    const md = `${lorem(6)}\n$$\n\\frac{a}{b}\n$$\n\n${lorem(6, 10)}\n# Target\n\n${lorem(30, 20)}`;
    const target = md.split('\n').indexOf('# Target');
    const page = await open(md);
    try {
      await page.eval(`MacDown2Preview.scrollToLine(${target})`);
      await page.eval(`document.querySelector('.katex-block').style.minHeight = '380px'; wait(100)`);
      const t = await page.eval(`top0(${target})`);
      assert.ok(Math.abs(t) <= 2, `Target heading is ${t}px from the top after the formula grew`);
    } finally {
      await page.close();
    }
  });

  test('typing at the end of a 5k-line document: no scroll report, no navigation, scrollY fixed, only patches', async () => {
    const body = Array.from({ length: 1000 }, (_, i) => `## Section ${i}\n\ntext ${i}\nmore ${i}\n`).join('\n');
    const page = await open(body);
    try {
      const start = await page.eval(`(async () => {
        const y = Math.floor(document.documentElement.scrollHeight / 2);
        scrollTo({ top: y, behavior: 'instant' });
        await wait(100); // let the scroll event (a user scroll) report once
        __msgs.length = 0;
        // identity of a few blocks above and below the caret: patching must keep these nodes
        const marks = [...document.querySelectorAll('h2')].filter((_, i) => i % 97 === 0);
        marks.forEach((m, i) => (m.__mark = i));
        window.__marks = marks;
        return { y: scrollY, count: marks.length };
      })()`);
      const navBefore = page.navigations;
      const run = await page.eval(`(async () => {
        let md = ${JSON.stringify(body)};
        const modes = [];
        for (let i = 0; i < 100; i++) {
          md += 'abcdefghij'[i % 10] + (i % 25 === 24 ? '\\n\\n' : '');
          modes.push(up(md).perf.mode);
          await new Promise((r) => requestAnimationFrame(r));
        }
        await wait(100);
        return { modes: [...new Set(modes)], y: scrollY, msgs: __msgs.slice(), kept: __marks.every((m, i) => m.isConnected && m.__mark === i && document.contains(m)) };
      })()`);
      assert.deepEqual(run.modes, ['patch'], 'every keystroke is a DOM patch');
      assert.equal(run.y, start.y, 'scrollY unchanged');
      assert.deepEqual(run.msgs.filter((m) => m.type === 'scroll'), [], 'nothing reported to the editor, so it cannot be pulled along');
      assert.equal(run.kept, true, 'untouched blocks keep their DOM nodes');
      assert.equal(page.navigations, navBefore, 'no navigation while typing');
    } finally {
      await page.close();
    }
  });

  test('sync off: nothing in the page scrolls the page; the preview and the editor are independent', async () => {
    // With sync off the app never calls scrollToLine; everything else the page does must leave scrollY alone.
    const md = `${lorem(60)}\n# Mid\n\n${lorem(60, 100)}`;
    const page = await open(md);
    try {
      const r = await page.eval(`(async () => {
        scrollTo({ top: 1500, behavior: 'instant' });
        await wait(100);
        __msgs.length = 0;
        const seen = [];
        up(${JSON.stringify(`${md}\nmore text typed at the end`)}); seen.push(scrollY);
        up(${JSON.stringify(`changed first paragraph\n\n${md}`)}); seen.push(scrollY);   // lines shift under the viewport
        MacDown2Preview.invalidate(); up(${JSON.stringify(md)}); seen.push(scrollY);      // forced rebuild (theme/dir change)
        up(${JSON.stringify(md)}, JSON.stringify({ ...JSON.parse(OPTIONS), hardBreaks: true })); seen.push(scrollY); // options change
        await wait(200);
        return { seen, msgs: __msgs.slice() };
      })()`);
      assert.deepEqual(r.seen, [1500, 1500, 1500, 1500]);
      assert.deepEqual(r.msgs, [], 'no scroll report without a scroll');
    } finally {
      await page.close();
    }
  });

  test('programmatic scrolls (sync on) are not echoed back, user scrolls are reported once per frame', async () => {
    const page = await open(`${lorem(80)}`);
    try {
      const r = await page.eval(`(async () => {
        MacDown2Preview.scrollToLine(120);
        await wait(100);
        const afterProgrammatic = __msgs.length;
        scrollTo({ top: scrollY + 400, behavior: 'instant' });
        await wait(100);
        return { afterProgrammatic, user: __msgs.filter((m) => m.type === 'scroll').length };
      })()`);
      assert.equal(r.afterProgrammatic, 0);
      assert.equal(r.user, 1);
    } finally {
      await page.close();
    }
  });

  test('re-rendering keeps the scroll position (patch, forced rebuild, option change), images above included', async () => {
    const imgs = [300, 500, 200].map((h, i) => `![i](/img.png?h=${h}&ms=${30 + i * 20}&n=${i})\n`).join('\n');
    const md = `${imgs}\n${lorem(60)}\n# Here\n\n${lorem(60, 100)}`;
    const here = md.split('\n').indexOf('# Here');
    const page = await open(md);
    try {
      await page.eval('wait(500)'); // images in
      await page.eval(`MacDown2Preview.scrollToLine(${here})`);
      const y0 = await page.eval('scrollY');
      assert.ok(y0 > 500);
      const results = {};
      for (const [name, script] of [
        ['patch', `up(${JSON.stringify(md.replace('Paragraph 3.', 'Paragraph three.'))})`],
        ['rebuild', `MacDown2Preview.invalidate(); up(${JSON.stringify(md)})`],
        ['options', `up(${JSON.stringify(md)}, JSON.stringify({ ...JSON.parse(OPTIONS), hardBreaks: true }))`],
      ]) {
        await page.eval(script);
        await page.eval('wait(600)'); // late images of a rebuilt page arrive
        results[name] = await page.eval(`({ y: scrollY, t: top0(${here}) })`);
      }
      for (const [name, r] of Object.entries(results)) {
        assert.equal(r.y, y0, `${name}: scrollY`);
        assert.ok(Math.abs(r.t) <= 1, `${name}: the heading is ${r.t}px from the top`);
      }
    } finally {
      await page.close();
    }
  });
});
