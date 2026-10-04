// Output that leaves the app (Copy HTML, export, PDF, CLI) goes through sanitizeHtml (an allowlist over a parse5 tree, src/sanitize):
// hostile.md in, no live markup out. The preview does not use it (CSP + stripActiveContent there), so the same document is also
// rendered without it as a control. The corpus at the bottom is also run in real Chrome: every payload calls __p('name'), and after
// sanitizing none of them may.
import { after, before, describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { defaultTreeAdapter, html as ns, parseFragment, serialize } from 'parse5';
import { renderResult, sanitizer } from '../src/render/index.ts';
import { cleanCss, safeUrl, sanitizeHtml } from '../src/sanitize/sanitize.ts';
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
sanitizer.register(sanitizeHtml); // in the app sanitize.chunk.js does this; the chunk itself is tested in sanitize-chunk.test.mjs
const clean = renderResult(hostile, { ...OPTIONS, sanitize: true }).html;
const raw = renderResult(hostile, OPTIONS).html;

/** What a browser makes of `html` and writes back, with nothing removed: the baseline for "benign markup is untouched". */
const reserialize = (html) => serialize(parseFragment(defaultTreeAdapter.createElement('div', ns.NS.HTML, []), html, {}));

/** Every element and attribute of `html` as the HTML parser sees it, for assertions that must not depend on how the text is quoted. */
function elements(html) {
  const out = [];
  const walk = (node) => {
    if (defaultTreeAdapter.isElementNode(node)) out.push({ tag: node.tagName, space: node.namespaceURI, attrs: node.attrs });
    for (const child of node.childNodes ?? []) walk(child);
  };
  walk(parseFragment(defaultTreeAdapter.createElement('div', ns.NS.HTML, []), html, {}));
  return out;
}

test('control: without sanitize the hostile document does reach the output', () => {
  assert.match(raw, /<script>__p\('script-tag'\)<\/script>/);
  assert.match(raw, /onerror="__p\('img-onerror'\)"/);
  assert.match(raw, /<iframe /);
  assert.match(raw, /<meta http-equiv="refresh"/);
});

test('hostile.md: no active element, no event handler, no script URL in the sanitized output', () => {
  const ACTIVE = new Set(['script', 'iframe', 'frame', 'frameset', 'object', 'embed', 'applet', 'meta', 'base', 'link', 'noscript', 'animate', 'set', 'foreignObject', 'use', 'template']);
  for (const el of elements(clean)) {
    assert.ok(!ACTIVE.has(el.tag), `<${el.tag}> survived`);
    for (const { name, value } of el.attrs) {
      assert.doesNotMatch(name, /^on/i, `${name} on <${el.tag}>`);
      assert.ok(!['srcdoc', 'action', 'formaction', 'ping'].includes(name), `${name} on <${el.tag}>`);
      if (['href', 'src', 'cite'].includes(name)) assert.ok(safeUrl(value, name), `${name}=${value} on <${el.tag}>`);
    }
  }
  assert.doesNotMatch(clean, /__p\('(?:script-tag|img-onerror|a-onclick|js-link|svg-script|svg-onload|iframe-srcdoc|dup-attr)'\)/); // the payload of a dropped script or handler is gone, not just its tag
});

test('hostile.md: what is harmless stays', () => {
  assert.match(clean, /<a href="#" id="hostile-onclick">click me<\/a>/); // the handler goes, the link stays
  assert.match(clean, /<a href="https:\/\/example\.com\/" target="_blank" rel="opener">new window<\/a>/);
  assert.match(clean, /<details open="">/);
  assert.match(clean, /<form method="post">/); // the action is gone
  assert.match(clean, /<a href="mailto:someone@example\.com">/);
  assert.match(clean, /<code>&lt;script&gt;__p\('inside-code'\)&lt;\/script&gt;<\/code>/); // escaped text is not markup
  assert.match(clean, /<a name="manual-anchor"><\/a>/);
});

test('sanitizing settles: a second pass changes nothing, and benign Markdown output is only re-serialized', () => {
  assert.equal(sanitizeHtml(clean), clean);
  const md = '# T\n\ntext with `code` and [a link](https://example.com/ "t") and ![i](pic.png)\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n> quote\n\n- [x] done\n- [ ] open\n\n---\n\n[TOC]\n\n\\newpage\n\nline  \nbreak <u>u</u> ==mark== ~~del~~\n\nfoot[^1]\n\n[^1]: note\n';
  const rendered = renderResult(md, OPTIONS).html;
  assert.equal(renderResult(md, { ...OPTIONS, sanitize: true }).html, reserialize(rendered));
});

test('math, highlighting, alerts and footnotes come through intact (KaTeX uses inline style, svg paths and MathML)', () => {
  const md = 'Euler $$e^{i\\pi}+1=0$$\n\n$$\\sqrt{x^2+1}$$\n\n$$\\cancel{x}\\ \\frac{a}{b}\\ \\begin{matrix}1&2\\end{matrix}$$\n\n```js\nconst a = 1;\n```\n\n> [!NOTE]\n> hi\n\nfoot[^1]\n\n[^1]: note\n';
  const a = renderResult(md, { ...OPTIONS, sanitize: true }).html;
  const b = renderResult(md, OPTIONS).html;
  assert.equal(a, reserialize(b)); // not a byte of the KaTeX, highlight.js or footnote markup was removed
  assert.match(a, /class="katex"/);
  assert.match(a, /<svg[^>]*>.*<path d="[^"]+"/s);
  assert.match(a, /<math[^>]*><semantics>/);
  assert.match(a, /<annotation encoding="application\/x-tex">/);
});

// [input, what the sanitized text must be exactly]. These are the ones whose exact output is worth pinning; the corpus below is
// checked for "nothing runs" in Chrome instead.
const pinned = [
  ['<img src=x onerror=alert(1)>', '<img src="x">'],
  ['<img/src=x/onerror=alert(1)>', '<img src="x/onerror=alert(1)">'], // the slash is part of the unquoted value, exactly as a browser reads it
  ['<IMG SRC=x ONERROR=alert(1)>', '<img src="x">'],
  ['<a href="jav&#x61;script:alert(1)">x</a>', '<a>x</a>'],
  ['<a href="java&Tab;script:alert(1)">x</a>', '<a>x</a>'],
  ['<a href="&#x6A&#x61&#x76&#x61&#x73&#x63&#x72&#x69&#x70&#x74&#x3A;alert(1)">x</a>', '<a>x</a>'],
  ['<a href="&#0000000106;avascript:alert(1)">x</a>', '<a>x</a>'], // codex: more than 8 digits in a numeric reference
  ['<a href="&#x0000006A;avascript:alert(1)">x</a>', '<a>x</a>'],
  ['<a href="&#106avascript:alert(1)">x</a>', '<a>x</a>'], // no semicolon
  ['<a href="&#x6A;avascript:alert(1)">x</a>', '<a>x</a>'],
  ['<a href="java\tscript:alert(1)">x</a>', '<a>x</a>'],
  ['<a href="java\nscript:alert(1)">x</a>', '<a>x</a>'],
  ['<a href=" javascript:alert(1)">x</a>', '<a>x</a>'],
  ['<a href="\u0001 javascript:alert(1)">x</a>', '<a>x</a>'],
  ['<a href=" vbscript:x">x</a>', '<a>x</a>'],
  ['<a href="data:text/html,<script>1</script>">x</a>', '<a>x</a>'],
  ['<img src="data:image/png;base64,AAAA">', '<img src="data:image/png;base64,AAAA">'],
  ['<a href="data:image/png;base64,AAAA">x</a>', '<a>x</a>'], // a data: link is a navigation, not an image
  ['<svg><style><img src=x onerror=alert(1)></style></svg>', '<svg></svg><img src="x">'], // codex: SVG <style> is not CSS; the parser breaks out at <img>
  ['<math><mi><mglyph><style><img src=x onerror=alert(1)>', '<math><mi><img src="x"></mi></math>'],
  ['<svg><a xlink:href="javascript:alert(1)"><text>x</text></a></svg>', '<svg></svg>'],
  ['<svg><script>alert(1)</script><circle/></svg>', '<svg><circle></circle></svg>'],
  ['<svg viewBox="0 0 1 1"><foreignObject width="1"><b>x</b></foreignObject></svg>', '<svg viewBox="0 0 1 1"></svg>'],
  ['<svg><set attributeName="href" to="javascript:alert(1)"/></svg>', '<svg></svg>'],
  ['<script>alert(1)</script>after', 'after'],
  ['<SCRIPT\n>alert(1)</SCRIPT\n>ok', 'ok'],
  ['<iframe srcdoc="<script>1</script>"></iframe>x', 'x'],
  ['<object data=x><param name=a value=b></object>y', 'y'],
  ['<meta http-equiv="refresh" content="0;url=https://evil.example/">', ''],
  ['<base href="https://evil.example/">', ''],
  ['<link rel=stylesheet href=https://evil.example/x.css>', ''],
  ['<form action="https://evil.example/"><button formaction="https://evil.example/">x</button></form>', '<form><button>x</button></form>'],
  ['<a href="x" href="javascript:alert(1)">d</a>', '<a href="x">d</a>'],
  ['<div title="a>b" onclick="x">t</div>', '<div title="a>b">t</div>'],
  ["<div title='say \"hi\"'>t</div>", '<div title="say &quot;hi&quot;">t</div>'],
  ['<!-- <script>alert(1)</script> -->z', 'z'],
  ['<!--[if IE]><script>1</script><![endif]-->z', 'z'],
  ['<noscript><p title="</noscript><img src=x onerror=alert(1)>"></noscript>z', '<img src="x">"&gt;z'],
  ['<template><img src=x onerror=alert(1)></template>t', 't'],
  ['<style>@import url(https://evil.example/a.css); a { background: url(javascript:alert(1)) } b { background: url(https://ok.example/i.png) }</style>', '<style> a { background: url() } b { background: url(https://ok.example/i.png) }</style>'],
  ['<div style="background:url(javascript:alert(1))">x</div>', '<div style="background:url()">x</div>'],
  ['<style>@\\69mport url(//evil.example/x.css); p{}</style>', '<style></style>'], // CSS escapes cannot hide an @import
  ['<p onclick', ''], // never closed: the parser drops it, as a browser does
  ['a < b and c > d', 'a &lt; b and c &gt; d'],
  ['<details open ontoggle=alert(1)><summary>s</summary></details>', '<details open=""><summary>s</summary></details>'],
  ['<math><mi xlink:href="javascript:alert(1)">x</mi></math>', '<math><mi>x</mi></math>'],
  ['<svg viewBox="0 0 1 1" onload=alert(1)><path d="M0 0"/></svg>', '<svg viewBox="0 0 1 1"><path d="M0 0"></path></svg>'], // SVG names keep their case
];
for (const [input, expected] of pinned) {
  test(`sanitize: ${JSON.stringify(input).slice(0, 80)}`, () => assert.equal(sanitizeHtml(input), expected));
}

// More payloads, not pinned: every one calls __p('<name>') when it runs.
const corpus = [
  '<img src=x onerror=__p(1)>',
  '<svg onload=__p(2)>',
  '<svg><script>__p(3)</script></svg>',
  '<svg><style><img src=x onerror=__p(4)></style></svg>',
  '<svg><title><style><img src=x onerror=__p(5)></style></title></svg>',
  '<svg><desc><style><img src=x onerror=__p(6)></style></desc></svg>',
  '<svg></p><style><a id="</style><img src=x onerror=__p(7)>">',
  '<math><mi><mglyph><style><img src=x onerror=__p(8)>',
  '<math><mtext><table><mglyph><style><!--</style><img title="--&gt;&lt;/mglyph&gt;&lt;img src=1 onerror=__p(9)&gt;">',
  '<math><annotation-xml encoding="text/html"><img src=x onerror=__p(10)></annotation-xml></math>',
  '<math><mtext><style><img src=x onerror=__p(11)></style></mtext></math>',
  '<form><math><mtext></form><form><mglyph><style></math><img src onerror=__p(12)>',
  '<noscript><p title="</noscript><img src=x onerror=__p(13)>">',
  '<template><img src=x onerror=__p(14)></template>',
  '<template><svg><style><img src=x onerror=__p(15)></style></svg></template>',
  '<table><tr><td><style></td></tr></table><img src=x onerror=__p(16)>',
  '<xmp><img src=x onerror=__p(17)></xmp>',
  '<textarea></textarea><img src=x onerror=__p(18)>',
  '<title><img src=x onerror=__p(19)></title>',
  '<iframe srcdoc="&lt;script&gt;parent.__p(20)&lt;/script&gt;"></iframe>',
  '<a href="javascript:__p(21)" id="a21">x</a>',
  '<a href="&#0000000106;avascript:__p(22)" id="a22">x</a>',
  '<a href="&#x6A;avascript:__p(23)" id="a23">x</a>',
  '<a href="&#106avascript:__p(24)" id="a24">x</a>',
  '<a href="java\tscript:__p(25)" id="a25">x</a>',
  '<a href="java&Tab;script:__p(26)" id="a26">x</a>',
  '<a href=" javascript:__p(27)" id="a27">x</a>',
  '<a href="java&NewLine;script:__p(28)" id="a28">x</a>',
  '<a href="jav&#x09;ascript:__p(29)" id="a29">x</a>',
  '<a href="\u0000javascript:__p(30)" id="a30">x</a>',
  '<a href="&#x6a&#x61&#x76&#x61&#x73&#x63&#x72&#x69&#x70&#x74&#x3a__p(31)" id="a31">x</a>',
  '<svg><a xlink:href="javascript:__p(32)" id="a32"><text x=0 y=9>x</text></a></svg>',
  '<svg><a href="javascript:__p(33)" id="a33"><text x=0 y=9>x</text></a></svg>',
  '<svg><use href="data:image/svg+xml,&lt;svg id=x xmlns=http://www.w3.org/2000/svg&gt;&lt;script&gt;parent.__p(34)&lt;/script&gt;&lt;/svg&gt;#x"/></svg>',
  '<svg><animate attributeName=href values=javascript:__p(35) /><a id="a35"><text x=0 y=9>x</text></a></svg>',
  '<svg><set attributeName=onmouseover to=__p(36) /></svg>',
  '<math><maction actiontype="statusline#" xlink:href="javascript:__p(37)"><mtext>x</mtext></maction></math>',
  '<math href="javascript:__p(38)" id="a38"><mtext>x</mtext></math>',
  '<details open ontoggle=__p(39)>x</details>',
  '<input autofocus onfocus=__p(40)>',
  '<video><source onerror=__p(41)></video>',
  '<body onload=__p(42)>',
  '<div style="background:url(javascript:__p(43))">x</div>',
  '<style>@import "javascript:__p(44)";</style>',
  '<style>p{background:u\\72l("javascript:__p(45)")}</style>',
  '<object data="javascript:__p(46)"></object>',
  '<embed src="javascript:__p(47)">',
  '<form id=f48><button formaction="javascript:__p(48)" id="a48">x</button></form>',
  '<form action="javascript:__p(49)"><input type=submit id="a49"></form>',
  '<img src=x onerror="__p(50)" onerror="__p(51)">',
  '<img/src="x"/onerror="__p(52)">',
  '<img src=x\fonerror=__p(53)>',
  '<a href=#" onclick=__p(54) id="a54">x</a>',
  '<div <img src=x onerror=__p(55)>',
  '<scr<script>ipt>__p(56)</scr</script>ipt>',
  '<<script>__p(57)//<</script>',
  '<![CDATA[<img src=x onerror=__p(58)>]]>',
  '<? <img src=x onerror=__p(59)> ?>',
  '<!--><img src=x onerror=__p(60)>-->',
  '<!--! --!><img src=x onerror=__p(61)>-->',
  '<select><template><option><style></select><img src=x onerror=__p(62)></style></option></template></select>',
  '<a id=x><b id=y></a><img src=x onerror=__p(63)>',
  '<p><svg><desc><div><svg><style><img src=x onerror=__p(64)></style></svg></div></desc></svg>',
  '<svg><foreignObject><img src=x onerror=__p(65)></foreignObject></svg>',
  '<svg><foreignObject><iframe srcdoc="&lt;script&gt;parent.__p(66)&lt;/script&gt;"></iframe></foreignObject></svg>',
];

test('corpus: nothing in it survives as an element or attribute that could run (parser view)', () => {
  const ACTIVE = new Set(['script', 'iframe', 'frame', 'frameset', 'object', 'embed', 'applet', 'meta', 'base', 'link', 'noscript', 'animate', 'set', 'foreignObject', 'use', 'template', 'xmp', 'textarea', 'title', 'maction', 'mglyph', 'annotation-xml']);
  for (const payload of corpus) {
    const out = sanitizeHtml(payload);
    for (const el of elements(out)) {
      if (el.tag === 'title' && el.space === ns.NS.SVG) continue;
      assert.ok(!ACTIVE.has(el.tag), `<${el.tag}> in ${JSON.stringify(out)} from ${payload}`);
      assert.ok(el.space !== ns.NS.SVG || el.tag !== 'style', `svg style in ${out}`);
      for (const { name, value } of el.attrs) {
        assert.doesNotMatch(name, /^on/i, `${name} in ${out}`);
        if (['href', 'src', 'cite'].includes(name)) assert.ok(safeUrl(value, name), `${name}=${value} in ${out}`);
      }
    }
    assert.equal(sanitizeHtml(out), out, `not settled: ${payload}`);
  }
});

test('safeUrl: schemes on the decoded value, after control characters and whitespace are removed', () => {
  for (const ok of ['https://a.example/', 'HTTP://A', 'mailto:a@b.c', 'tel:+1', '#frag', 'rel/path.md', '../x', '//host/x', '?q=1', '', 'a/b:c']) assert.ok(safeUrl(ok, 'href'), ok);
  for (const bad of ['javascript:1', ' JaVaScRiPt:1', 'java\tscript:1', 'java\nscript:1', '\u0001javascript:1', 'java​script:1', 'file:///etc/passwd', 'blob:https://x/1', 'data:text/html,x', 'x-apple.systempreferences:a', 'ssh://a', 'vbscript:x']) assert.ok(!safeUrl(bad, 'href'), JSON.stringify(bad));
  assert.ok(safeUrl('data:image/png;base64,AA', 'src') && !safeUrl('data:image/png;base64,AA', 'href'));
});

test('cleanCss: import and url() go, also when written with CSS escapes; ordinary CSS stays', () => {
  assert.equal(cleanCss('p { color: red; margin: 0 }'), 'p { color: red; margin: 0 }');
  assert.equal(cleanCss('height:1.2em;vertical-align:-0.1777em;'), 'height:1.2em;vertical-align:-0.1777em;');
  assert.equal(cleanCss('@import url(x.css); p{}'), ' p{}');
  assert.equal(cleanCss('@\\69mport url(x.css); p{}'), '');
  assert.equal(cleanCss('p{background:u\\72l(javascript:x)}'), '');
  assert.equal(cleanCss('p{content:"\\201C"}'), 'p{content:"\\201C"}');
  assert.equal(cleanCss('p{width:expression(alert(1))}'), 'p{width:x(alert(1))}');
});

// The same payloads in a real browser, injected the three ways sanitized output meets one: written into a page (an exported HTML
// file), assigned to innerHTML (Copy HTML pasted into an editor), and parsed a second time out of a serialization (mXSS).
describe('corpus in headless Chrome', { skip: !chromeAvailable && 'no Chrome (set CHROME_BIN)' }, () => {
  let browser;
  before(async () => {
    browser = await launch({ routes: { '/never': (req, res) => res.end('<!doctype html><title>x</title>') } });
  });
  after(async () => browser?.close());

  async function runs(markup, how) {
    const page = await browser.newPage();
    try {
      await page.goto('/never');
      await page.eval(`window.__pwned = []; window.__p = (n) => window.__pwned.push(String(n));`);
      const html = JSON.stringify(markup);
      if (how === 'write') await page.eval(`(async () => { document.open(); document.write('<!doctype html><html><body><article id="doc">' + ${html} + '</article></body></html>'); document.close(); })()`);
      else if (how === 'innerHTML') await page.eval(`document.body.innerHTML = '<article id="doc"></article>'; document.getElementById('doc').innerHTML = ${html};`);
      else await page.eval(`(() => { const a = document.createElement('div'); a.innerHTML = ${html}; const b = document.createElement('div'); b.innerHTML = a.innerHTML; document.body.append(b); })()`);
      // A harmless click must not navigate the page away (it would take __pwned with it); a javascript: link still runs.
      await page.eval(`addEventListener('click', (e) => { const a = e.target.closest && e.target.closest('a'); if (a && !/^javascript:/i.test(a.href)) e.preventDefault(); }, true); addEventListener('submit', (e) => e.preventDefault(), true);`);
      // click everything clickable: a javascript: link that survived runs here
      await page.eval(`(() => { for (const el of document.querySelectorAll('a, button, input[type=submit], [id^=a]')) { try { el.click(); } catch {} } })()`);
      await page.eval('new Promise((r) => setTimeout(r, 150))');
      return (await page.eval('window.__pwned')) ?? ['NAVIGATED-AWAY'];
    } finally {
      await page.close();
    }
  }

  test('control: the unsanitized corpus does run code in Chrome (so "nothing ran" below means something)', async () => {
    const ran = new Set();
    for (const payload of corpus) for (const n of await runs(payload, 'write')) ran.add(n);
    assert.ok(ran.size >= 20, `only ${ran.size} payloads ran unsanitized: ${[...ran]}`);
  });

  for (const how of ['write', 'innerHTML', 'reparse']) {
    test(`sanitized corpus runs nothing (${how})`, async () => {
      const bad = [];
      for (const payload of corpus) {
        const ran = await runs(sanitizeHtml(payload), how);
        if (ran.length) bad.push(`${payload} -> ${ran}`);
      }
      assert.deepEqual(bad, []);
    });
  }

  test('hostile.md, sanitized, runs nothing in any of the three', async () => {
    const meta = (html) => html.replace(/<meta[^>]*>/g, '');
    for (const how of ['write', 'innerHTML', 'reparse']) assert.deepEqual(await runs(meta(clean), how), [], how);
  });
});
