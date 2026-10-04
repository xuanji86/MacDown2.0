// hostile.md (Packages/MarkdownCore/Tests/MarkdownCoreTests/Fixtures/own/hostile.md): script in every shape, event handlers,
// javascript:/data:/file: links, frames and plugins, SVG tricks, meta refresh, forms, traversal in image paths, links to
// programs. Nothing in it may run, load, navigate or open anything. Layers tested here:
//   - the fixture is live: dropped into a bare page its payloads do run (so "nothing ran" below means something);
//   - CSP alone stops them in the real preview page;
//   - the real update() path (strips active elements, rewrites links) leaves a page with no script, no navigation;
//   - the hrefs the app's navigation decider will see are exactly the expected ones (LinkPolicyTests covers each).
import { after, before, describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { renderResult } from '../src/render/index.ts';
import { resolveImageSrc } from '../src/preview/images.ts';
import { resolveLinkHref } from '../src/preview/links.ts';
import { chromeAvailable, launch } from './helpers/chrome.mjs';

const hostile = readFileSync(new URL('../../Packages/MarkdownCore/Tests/MarkdownCoreTests/Fixtures/own/hostile.md', import.meta.url), 'utf8');
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
const BASE = 'file:///work/doc/';
const rendered = renderResult(hostile, OPTIONS);

describe('hostile.md through the renderer', () => {
  test('markdown link syntax never makes a javascript:/data: link; raw HTML passes through (the page and the app defend)', () => {
    assert.match(rendered.html, /\[markdown js link\]\(javascript:__p\(/); // markdown-it refuses the scheme: literal text
    assert.match(rendered.html, /\[markdown data link\]\(data:text\/html/);
    assert.doesNotMatch(rendered.html, /<a href="javascript:[^"]*"[^>]*>markdown js link/);
    assert.match(rendered.html, /<a href="javascript:__p\('js-link'\)"/); // raw HTML is kept: allowRawHTML is a user setting
  });

  test('code spans and fences stay inert text', () => {
    assert.match(rendered.html, /<code>&lt;script&gt;__p\('inside-code'\)&lt;\/script&gt;<\/code>/);
    assert.match(rendered.html, /<pre[^>]*data-lang="html"[^>]*>.*inside-fence/s);
    assert.doesNotMatch(rendered.html, /<script>__p\('inside-fence'\)/);
  });

  test('the title and alt injections are escaped into the attribute value', () => {
    assert.doesNotMatch(rendered.html, /onmouseover="__p\('title-injection'/);
    assert.doesNotMatch(rendered.html, /<img [^>]*onerror="__p\('alt-injection'/);
  });

  test('relative links resolve against the document folder; absolute ones, anchors and empty stay as written', () => {
    const r = (h) => resolveLinkHref(h, BASE);
    assert.equal(r('notes/readme.md'), 'file:///work/doc/notes/readme.md');
    assert.equal(r('other.md#section'), 'file:///work/doc/other.md#section');
    assert.equal(r('../outside.md'), 'file:///work/outside.md'); // leaving the folder is allowed to resolve; the policy decides
    assert.equal(r('../../../../../../Applications/Calculator.app'), 'file:///Applications/Calculator.app'); // clamps at the root
    assert.equal(r('/etc/passwd'), 'file:///etc/passwd');
    assert.equal(r('a b.md'), 'file:///work/doc/a%20b.md');
    assert.equal(r('//example.com/x'), 'https://example.com/x');
    for (const same of ['#frag', '#', '', '  ', 'https://x.example/', 'mailto:a@b.c', 'javascript:alert(1)', 'JaVaScRiPt:x', 'file:///etc/hosts', 'data:text/html,x', 'x-apple.systempreferences:a']) {
      assert.equal(r(same), null, JSON.stringify(same));
    }
    assert.equal(resolveLinkHref('a.md', null), null); // unsaved document: nothing to resolve against
  });

  test('image paths that climb out of the document folder are never rewritten into the doc host', () => {
    for (const bad of ['../../../../../../etc/passwd', '..%2f..%2f..%2fetc%2fpasswd', '%2e%2e/%2e%2e/secret.png', '..\\..\\secret.png', '/etc/passwd', '//example.com/x.png', 'file:///etc/passwd', '../secret.png']) {
      const out = resolveImageSrc(bad);
      if (out === null) continue; // left as written: it resolves to nothing the app serves
      assert.ok(out.startsWith('macdown2-res://doc/'), `${bad} -> ${out}`);
      const rest = out.slice('macdown2-res://doc/'.length);
      if (/%2f|%5c|\\/i.test(rest)) continue; // an encoded slash or a backslash is one ordinary segment for the URL parser (macdown2-res is not a special scheme); the Swift handler decodes it and DocumentFileResolver refuses a '..' component
      assert.ok(!decodeURIComponent(rest).split(/[/\\]/).some((p) => p === '..'), `${bad} -> ${out}`);
    }
  });
});

describe('hostile.md in the preview page (headless Chrome)', { skip: !chromeAvailable && 'no Chrome (set CHROME_BIN)' }, () => {
  let browser;
  before(async () => {
    browser = await launch({
      routes: { '/never': (req, res) => res.end('x') },
    });
  });
  after(async () => browser?.close());

  const record = `window.__pwned = []; window.__p = (n) => window.__pwned.push(String(n));`;
  async function open(path) {
    const page = await browser.newPage();
    await page.goto(path);
    await page.eval(`${record} window.wait = (ms) => new Promise((r) => setTimeout(r, ms)); window.OPTIONS = ${JSON.stringify(JSON.stringify(OPTIONS))};`);
    return page;
  }

  test('control: the same HTML in a bare page with no CSP and no stripping does run code', async () => {
    const page = await browser.newPage();
    await page.goto('/never');
    await page.eval(record);
    const bare = rendered.html.replace(/<meta[^>]*>/g, ''); // a meta refresh would navigate the control page away
    await page.eval(`(async () => { document.open(); document.write(${JSON.stringify(bare)}); document.close(); await new Promise((r) => setTimeout(r, 600)); })()`);
    const pwned = await page.eval('window.__pwned');
    for (const name of ['script-tag', 'img-onerror', 'iframe-srcdoc', 'svg-script']) assert.ok(pwned.includes(name), `control: ${name} ran (got ${pwned})`);
    await page.close();
  });

  test('CSP alone (HTML injected straight into the page, bypassing every other layer) blocks scripts, handlers and frames', async () => {
    const page = await open('/preview.html?csp=1');
    try {
      const html = rendered.html.replace(/<meta[^>]*>/g, ''); // meta refresh is not a CSP matter, update() removes it (next test)
      await page.eval(`document.getElementById('doc').innerHTML = ${JSON.stringify(html)}`);
      await page.eval(`(() => { for (const id of ['hostile-onclick', 'hostile-js', 'hostile-submit']) document.getElementById(id)?.click(); })()`);
      await page.eval('wait(800)');
      assert.deepEqual(await page.eval('window.__pwned'), []);
      const csp = await page.eval('__msgs.filter((m) => m.type === "error" && m.stage === "csp").length');
      assert.ok(csp > 5, `CSP actively blocked things (${csp} violations)`);
      assert.equal(page.navigations, 1, 'only the initial load: the form and the javascript: link went nowhere');
    } finally {
      await page.close();
    }
  });

  test('update(): nothing runs, no navigation, no active elements left in the page', async () => {
    const page = await open('/preview.html');
    try {
      await page.eval(`MacDown2Preview.setBase(${JSON.stringify(BASE)})`);
      await page.eval(`MacDown2Preview.update(${JSON.stringify(hostile)}, OPTIONS)`);
      await page.eval(`(() => { for (const id of ['hostile-onclick', 'hostile-js', 'hostile-submit']) document.getElementById(id)?.click(); })()`);
      await page.eval('wait(800)');
      assert.deepEqual(await page.eval('window.__pwned'), []);
      assert.equal(page.navigations, 1);
      const active = await page.eval(`document.querySelectorAll('#doc script, #doc iframe, #doc frame, #doc object, #doc embed, #doc meta, #doc base').length`);
      assert.equal(active, 0);
      assert.equal(await page.eval('document.head.querySelectorAll("base, meta[http-equiv=refresh]").length'), 0);
    } finally {
      await page.close();
    }
  });

  test('what the navigation decider will see: every link in hostile.md, as resolved by the page', async () => {
    const page = await open('/preview.html');
    try {
      await page.eval(`MacDown2Preview.setBase(${JSON.stringify(BASE)})`);
      await page.eval(`MacDown2Preview.update(${JSON.stringify(hostile)}, OPTIONS)`);
      const hrefs = await page.eval(`[...document.querySelectorAll('#doc a[href]')].map((a) => a.getAttribute('href'))`);
      assert.deepEqual(hrefs, [
        '#', // onclick
        "javascript:__p('js-link')",
        "JaVaScRiPt:__p('js-link-mixed-case')", // the decider lower-cases the scheme
        "javascript:__p('js-link-entity')",
        "javascript:__p('js-link-tab')", // the tab inside the scheme is gone once the URL parser has seen it
        "data:text/html,<script>__p('data-link')</script>",
        'blob:https://example.com/00000000-0000-0000-0000-000000000000',
        'https://example.com/', // title injection
        'https://example.com/', // target=_blank
        'file:///Applications/Calculator.app',
        'file:///Applications/Calculator.app',
        'file:///usr/bin/true',
        'file://server/share/doc.md',
        'file:///Applications/Calculator.app', // ../../../.. relative
        'file:///work/doc/run.sh',
        'file:///work/doc/Tool.app',
        'file:///work/doc/Setup.pkg',
        'file:///work/doc/notes/readme.md',
        'file:///work/outside.md',
        'file:///work/doc/other.md#section',
        'file:///work/doc/report.pdf',
        'file:///work/doc/does-not-exist.md',
        'file:///etc/passwd',
        'https://example.com/page',
        'http://example.com/page',
        'mailto:someone@example.com',
        'x-apple.systempreferences:com.apple.preference.security',
        'ssh://root@example.com',
        'smb://example.com/share',
        '#hostile-document',
        '#manual-anchor',
        '#html-id-target',
        '#nothing-here',
        'file:///work/doc/x', // duplicate-attribute anchor: the parser keeps the first href
      ]);
    } finally {
      await page.close();
    }
  });
});

describe('in-page anchors (headless Chrome)', { skip: !chromeAvailable && 'no Chrome (set CHROME_BIN)' }, () => {
  let browser;
  before(async () => {
    browser = await launch();
  });
  after(async () => browser?.close());

  const filler = (n, from = 0) => Array.from({ length: n }, (_, i) => `Filler ${from + i}. ${'words '.repeat(60)}\n`).join('\n');
  const doc = [
    '[to heading](#target-heading) [to name](#manual-anchor) [to id](#html-id-target) [encoded](#%E5%AE%89%E8%A3%85-%E6%AD%A5%E9%AA%A4) [dup](#same-1) [none](#nothing-here) [top](#top) [^1]',
    filler(25),
    '# Target heading\n',
    filler(25, 100),
    '<a name="manual-anchor"></a>Hand written anchor.\n',
    filler(25, 200),
    '<p id="html-id-target">An id on a plain element.</p>\n',
    filler(25, 300),
    '# 安装 步骤\n',
    filler(25, 400),
    '# Same\n\n# Same\n',
    filler(25, 500),
    '[^1]: The note.\n',
  ].join('\n');

  async function setup() {
    const page = await browser.newPage();
    await page.goto('/preview.html');
    await page.eval(`window.wait = (ms) => new Promise((r) => setTimeout(r, ms)); MacDown2Preview.setBase('file:///work/doc/'); MacDown2Preview.update(${JSON.stringify(doc)}, ${JSON.stringify(JSON.stringify(OPTIONS))});`);
    return page;
  }
  const click = (page, href) => page.eval(`(() => { const a = [...document.querySelectorAll('a')].find((a) => a.getAttribute('href') === ${JSON.stringify(href)}); a.click(); return !!a; })()`);

  for (const [href, selector, what] of [
    ['#target-heading', '#target-heading', 'heading id'],
    ['#manual-anchor', 'a[name="manual-anchor"]', 'hand written <a name>'],
    ['#html-id-target', '#html-id-target', 'id on an arbitrary element'],
    ['#%E5%AE%89%E8%A3%85-%E6%AD%A5%E9%AA%A4', '[id="安装-步骤"]', 'non-ASCII slug (markdown-it percent-encodes the href)'],
    ['#same-1', '#same-1', 'deduplicated slug'],
  ]) {
    test(`click on ${href} scrolls to the ${what} inside the page, no navigation`, async () => {
      const page = await setup();
      try {
        await page.eval('scrollTo({ top: 0, behavior: "instant" })');
        const nav = page.navigations;
        assert.equal(await click(page, href), true);
        await page.eval('wait(50)');
        const top = await page.eval(`document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect().top`);
        assert.ok(Math.abs(top) <= 1, `${selector} is ${top}px from the top`);
        assert.equal(page.navigations, nav, 'no navigation of any kind');
        assert.equal(await page.eval('location.hash'), '', 'the URL did not change either');
      } finally {
        await page.close();
      }
    });
  }

  test('an anchor with no target does nothing; #top goes to the top', async () => {
    const page = await setup();
    try {
      await page.eval('scrollTo({ top: 1200, behavior: "instant" })');
      const nav = page.navigations;
      await click(page, '#nothing-here');
      await page.eval('wait(50)');
      assert.equal(await page.eval('scrollY'), 1200);
      await click(page, '#top');
      await page.eval('wait(50)');
      assert.equal(await page.eval('scrollY'), 0);
      assert.equal(page.navigations, nav);
    } finally {
      await page.close();
    }
  });

  test('footnote links and the [TOC] use the same in-page scrolling', async () => {
    const page = await setup();
    try {
      const nav = page.navigations;
      await page.eval(`document.querySelector('a[href="#footnote1"]').click()`);
      await page.eval('wait(50)');
      const { top, atEnd } = await page.eval(`({ top: document.getElementById('footnote1').getBoundingClientRect().top, atEnd: scrollY >= document.documentElement.scrollHeight - innerHeight - 1 })`);
      assert.ok(Math.abs(top) <= 1 || atEnd, `footnote is ${top}px from the top`); // the last element cannot reach the top of a short tail
      assert.equal(page.navigations, nav);
    } finally {
      await page.close();
    }
  });
});
