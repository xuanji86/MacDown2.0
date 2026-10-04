// The preview must never flash (MacDown #1104/#1057, macdown3000 #9): no page reload, no re-fetch of what did not change,
// nothing that empties a cache. Two layers: the page itself (headless Chrome counts real navigations) and a source scan
// that no code path in the repository can clear WebKit's caches or reload the page behind our back.
import { after, before, describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
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

describe('typing in a long document (headless Chrome)', { skip: !chromeAvailable && 'no Chrome (set CHROME_BIN)' }, () => {
  let browser;
  before(async () => {
    browser = await launch({
      routes: {
        '/pic.png': (req, res) => {
          res.setHeader('Content-Type', 'image/png');
          res.setHeader('Cache-Control', 'no-store'); // the app's scheme handler answers no-store too: only the DOM may keep an image alive
          res.end(png(200, 120));
        },
      },
    });
  });
  after(async () => browser?.close());

  const doc = (n) => Array.from({ length: n }, (_, i) => `## Section ${i}\n\ntext ${i}\nmore ${i}\n${i % 250 === 0 ? `\n![pic ${i}](/pic.png?i=${i})\n` : ''}`).join('\n');

  async function open(md) {
    const page = await browser.newPage();
    await page.goto('/preview.html');
    await page.eval(`window.__alive = 'same page'; window.wait = (ms) => new Promise((r) => setTimeout(r, ms)); window.OPTIONS = ${JSON.stringify(optionsJSON)}; window.up = (md, o = window.OPTIONS) => JSON.parse(MacDown2Preview.update(md, o));`);
    await page.eval(`up(${JSON.stringify(md)})`);
    await page.eval('wait(300)'); // images in
    return page;
  }

  test('100 keystrokes in a 5k-line document: zero navigations, the same page, scrollY fixed, only DOM patches, images not re-fetched', async () => {
    const md = doc(1000);
    const page = await open(md);
    try {
      const imgs = (await page.eval('document.images.length'));
      assert.equal(imgs, 4);
      const hitsBefore = browser.hits['/pic.png'];
      assert.equal(hitsBefore, 4);
      const y0 = await page.eval(`(() => { scrollTo({ top: document.documentElement.scrollHeight / 2, behavior: 'instant' }); return scrollY; })()`);
      const navBefore = page.navigations;
      const run = await page.eval(`(async () => {
        let md = ${JSON.stringify(md)};
        const modes = [], ys = [];
        const article = document.getElementById('doc');
        const imgNodes = [...document.images];
        for (let i = 0; i < 100; i++) {
          // type in the middle of the text and at the end, alternating
          md = i % 2 ? md + 'x' : md.replace('text 500\\n', 'text 500' + 'y'.repeat(i / 2 + 1) + '\\n');
          modes.push(up(md).perf.mode);
          ys.push(scrollY);
          await new Promise((r) => requestAnimationFrame(r));
        }
        await wait(200);
        return {
          modes: [...new Set(modes)], ys: [...new Set(ys)], alive: window.__alive,
          navEntries: performance.getEntriesByType('navigation').length,
          sameArticle: article === document.getElementById('doc'),
          sameImages: imgNodes.every((n, i) => n === document.images[i]),
        };
      })()`);
      assert.deepEqual(run.modes, ['patch']);
      assert.deepEqual(run.ys, [y0]);
      assert.equal(run.alive, 'same page');
      assert.equal(run.navEntries, 1);
      assert.equal(run.sameArticle, true);
      assert.equal(run.sameImages, true);
      assert.equal(page.navigations, navBefore, 'the browser never navigated');
      assert.equal(browser.hits['/pic.png'], hitsBefore, 'unchanged images are not requested again');
    } finally {
      await page.close();
    }
  });

  test('theme switch, option change, forced rebuild and flavor load all stay inside the page', async () => {
    const md = doc(200);
    const page = await open(md);
    try {
      await page.eval(`scrollTo({ top: 3000, behavior: 'instant' })`);
      const y0 = await page.eval('scrollY');
      const hits0 = browser.hits['/pic.png'];
      const nav0 = page.navigations;
      await page.eval(`MacDown2Preview.setStyle('github', 'github-dark'); wait(200)`);
      await page.eval(`MacDown2Preview.setStyle('paper', null); wait(200)`);
      await page.eval(`up(${JSON.stringify(md)}, JSON.stringify({ ...JSON.parse(OPTIONS), hardBreaks: true, codeLineNumbers: true }))`);
      await page.eval(`MacDown2Preview.invalidate(); up(${JSON.stringify(md)})`);
      await page.eval(`MacDown2Preview.useFlavor({ chunks: [], stylesheets: [] })`);
      await page.eval('wait(300)');
      const after = await page.eval(`({ alive: window.__alive, y: scrollY, links: document.querySelectorAll('link[data-md2-style]').length })`);
      assert.equal(after.alive, 'same page');
      assert.equal(page.navigations, nav0);
      assert.equal(after.y, y0);
      assert.equal(after.links, 2, 'old style links are dropped once the new ones are in');
      void hits0; // images are re-created by a rebuild; whether the engine refetches them is the engine's (cache) business, the page is not reloaded
    } finally {
      await page.close();
    }
  });
});

// --- no code path clears a global cache or reloads the page -----------------------------------------------------------

const root = join(dirname(fileURLToPath(import.meta.url)), '../..');
function sources(dir, out = []) {
  for (const name of readdirSync(dir)) {
    if (['node_modules', '.build', 'build', '.git', 'Resources', 'Snapshots'].includes(name)) continue; // Resources = generated bundles
    const p = join(dir, name);
    if (statSync(p).isDirectory()) sources(p, out);
    else if (/\.(swift|ts|mjs|js|sh|py)$/.test(name)) out.push(p);
  }
  return out;
}
const files = ['App', 'CLI', 'QuickLook', 'Packages', 'Scripts', 'Web/src'].flatMap((d) => sources(join(root, d)));

test('the source scan sees the app (guards against scanning nothing)', () => {
  assert.ok(files.some((f) => f.endsWith('App/Preview/PreviewPane.swift')));
  assert.ok(files.some((f) => f.endsWith('Web/src/preview/main.ts')));
});

test('nothing clears WebKit/URL caches, website data or CacheStorage', () => {
  const forbidden = [
    /removeAllCachedResourceData/,
    /removeAllCachedResponses/,
    /removeCachedResponse/,
    /WKWebsiteDataStore/,
    /WebsiteDataStore/,
    /removeData\s*\(/,
    /\bWebCache\b/, // the private API original MacDown disabled the cache with (setDisabled:)
    /\.removeAllCookies|HTTPCookieStorage/,
    /\bcaches\.(delete|keys|open)\b/, // JS CacheStorage
    /clearCache|clear_cache|--disable-cache/,
  ];
  const hits = [];
  for (const f of files) {
    if (f.includes('/Tests/') || f.endsWith('.test.mjs')) continue;
    const text = readFileSync(f, 'utf8');
    for (const re of forbidden) if (re.test(text)) hits.push(`${relative(root, f)}: ${re}`);
  }
  assert.deepEqual(hits, []);
});

test('the preview page is loaded exactly once and never reloaded', () => {
  const swift = files.filter((f) => f.includes('/App/') && f.endsWith('.swift'));
  const loads = [];
  for (const f of swift) {
    const text = readFileSync(f, 'utf8').split('\n').filter((l) => !l.trim().startsWith('//')).join('\n'); // comments may talk about it
    for (const m of text.matchAll(/\bpage\.(load|reload)\b|\.reload\(|\.reloadFromOrigin|\.goBack|\.goForward/g)) loads.push(`${relative(root, f)}: ${m[0]}`);
  }
  assert.deepEqual(loads, ['App/Preview/PreviewPane.swift: page.load']);
  const js = files.filter((f) => f.includes('/Web/src/preview/'));
  for (const f of js) {
    const text = readFileSync(f, 'utf8');
    assert.doesNotMatch(text, /location\.(reload|assign|replace|href\s*=)|history\.(go|back|forward)\b|window\.open\b/, relative(root, f));
  }
});
