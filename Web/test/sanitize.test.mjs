// Output that leaves the app (Copy HTML, export, PDF, CLI) goes through sanitizeHtml: hostile.md in, no live markup out.
// The preview does not use it (CSP + stripActiveContent there), so the same document is also rendered without it as a control.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { renderResult } from '../src/render/index.ts';
import { safeUrl, sanitizeHtml } from '../src/render/sanitize.ts';

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
const clean = renderResult(hostile, { ...OPTIONS, sanitize: true }).html;
const raw = renderResult(hostile, OPTIONS).html;

const tags = (html) => [...html.matchAll(/<\/?([a-zA-Z][^\s/>]*)([^>]*)>/g)];

test('control: without sanitize the hostile document does reach the output', () => {
  assert.match(raw, /<script>__p\('script-tag'\)<\/script>/);
  assert.match(raw, /onerror="__p\('img-onerror'\)"/);
  assert.match(raw, /<iframe /);
  assert.match(raw, /<meta http-equiv="refresh"/);
});

test('hostile.md: no active element, no event handler, no script URL in the sanitized output', () => {
  for (const [, name, attrs] of tags(clean)) {
    assert.ok(!['script', 'iframe', 'frame', 'frameset', 'object', 'embed', 'applet', 'meta', 'base', 'link', 'noscript', 'animate', 'set'].includes(name.toLowerCase()), `<${name}> survived`);
    // quoted values are blanked first: a title may legitimately contain the escaped text of an attack
    const bare = attrs.replace(/"[^"]*"/g, '""');
    assert.doesNotMatch(bare, /\son[a-z]+\s*=/i, `event handler in <${name}${attrs}>`);
    assert.doesNotMatch(bare, /\s(srcdoc|action|formaction)\s*=/i, `<${name}${attrs}>`);
  }
  assert.doesNotMatch(clean, /(?:href|src|data|action)="\s*(?:javascript|vbscript|data:text|file|blob):/i);
  assert.doesNotMatch(clean, /__p\('(?:script-tag|img-onerror|a-onclick|js-link|svg-script|svg-onload|iframe-srcdoc|dup-attr)'\)/); // the payload of a dropped script or handler is gone, not just its tag
});

test('hostile.md: what is harmless stays', () => {
  assert.match(clean, /<a href="#" id="hostile-onclick">click me<\/a>/); // the handler goes, the link stays
  assert.match(clean, /<a href="https:\/\/example\.com\/" target="_blank" rel="opener">new window<\/a>/);
  assert.match(clean, /<details open>/);
  assert.match(clean, /<form method="post">/); // the action is gone
  assert.match(clean, /<a href="mailto:someone@example\.com">/);
  assert.match(clean, /<code>&lt;script&gt;__p\('inside-code'\)&lt;\/script&gt;<\/code>/); // escaped text is not markup
  assert.match(clean, /<a name="manual-anchor"><\/a>/);
});

test('hostile.md: the sanitizer is idempotent and quiet about an already clean document', () => {
  assert.equal(sanitizeHtml(clean), clean);
  const plain = renderResult('# T\n\ntext with `code` and [a link](https://example.com/ "t") and ![i](pic.png)\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n> quote\n\n- [x] done\n', { ...OPTIONS, sanitize: true }).html;
  const same = renderResult('# T\n\ntext with `code` and [a link](https://example.com/ "t") and ![i](pic.png)\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n> quote\n\n- [x] done\n', OPTIONS).html;
  assert.equal(plain, same);
});

test('math, highlighting, alerts and footnotes come through intact (KaTeX uses inline style and svg paths)', () => {
  const md = 'Euler $$e^{i\\pi}+1=0$$\n\n$$\\sqrt{x^2+1}$$\n\n```js\nconst a = 1;\n```\n\n> [!NOTE]\n> hi\n\nfoot[^1]\n\n[^1]: note\n';
  const a = renderResult(md, { ...OPTIONS, sanitize: true }).html;
  const b = renderResult(md, OPTIONS).html;
  assert.equal(a, b.replace("class='katex-block'", 'class="katex-block"')); // the one difference: quotes
  assert.match(a, /class="katex"/);
  assert.match(a, /<svg[^>]*>.*<path d="[^"]+"\s*\/?>/s);
});

const bypasses = [
  ['<img src=x onerror=alert(1)>', '<img src="x">'],
  ['<img/src=x/onerror=alert(1)>', '<img src="x/onerror=alert(1)">'], // the slash is part of the unquoted value, exactly as a browser reads it
  ['<IMG SRC=x ONERROR=alert(1)>', '<IMG SRC="x">'], // names keep their case (SVG's viewBox needs it)
  ['<a href="jav&#x61;script:alert(1)">x</a>', '<a>x</a>'],
  ['<a href="java&Tab;script:alert(1)">x</a>', '<a>x</a>'],
  ['<a href="&#x6A&#x61&#x76&#x61&#x73&#x63&#x72&#x69&#x70&#x74&#x3A;alert(1)">x</a>', '<a>x</a>'],
  ['<a href="\u0001 javascript:alert(1)">x</a>', '<a>x</a>'],
  ['<a href=" vbscript:x">x</a>', '<a>x</a>'],
  ['<a href="data:text/html,<script>1</script>">x</a>', '<a>x</a>'],
  ['<img src="data:image/png;base64,AAAA">', '<img src="data:image/png;base64,AAAA">'],
  ['<a href="data:image/png;base64,AAAA">x</a>', '<a>x</a>'], // a data: link is a navigation, not an image
  ['<svg><a xlink:href="javascript:alert(1)"><text>x</text></a></svg>', '<svg><a><text>x</text></a></svg>'],
  ['<svg><script>alert(1)</script><circle/></svg>', '<svg><circle/></svg>'],
  ['<svg viewBox="0 0 1 1"><foreignObject width="1"><b>x</b></foreignObject></svg>', '<svg viewBox="0 0 1 1"><foreignObject width="1"><b>x</b></foreignObject></svg>'],
  ['<svg><set attributeName="href" to="javascript:alert(1)"/></svg>', '<svg></svg>'],
  ['<script>alert(1)</script>after', 'after'],
  ['<script src=x>', ''],
  ['<SCRIPT\n>alert(1)</SCRIPT\n>ok', 'ok'],
  ['<scr<script>ipt>alert(1)</scr</script>ipt>', '&lt;script>'], // not a tag name: text; then a real script element, dropped
  ['<iframe srcdoc="<script>1</script>"></iframe>x', 'x'],
  ['<object data=x><param name=a value=b></object>y', 'y'],
  ['<meta http-equiv="refresh" content="0;url=https://evil.example/">', ''],
  ['<base href="https://evil.example/">', ''],
  ['<link rel=stylesheet href=https://evil.example/x.css>', ''],
  ['<form action="https://evil.example/"><button formaction="https://evil.example/">x</button></form>', '<form><button>x</button></form>'],
  ['<a href="x" href="javascript:alert(1)">d</a>', '<a href="x">d</a>'],
  ['<div title="a>b" onclick="x">t</div>', '<div title="a&gt;b">t</div>'],
  ["<div title='say \"hi\"'>t</div>", '<div title="say &quot;hi&quot;">t</div>'],
  ['<!-- <script>alert(1)</script> -->z', 'z'],
  ['<!-->z', 'z'],
  ['<!--[if IE]><script>1</script><![endif]-->z', 'z'],
  ['<? <script>1</script> >z', '1 >z'], // a bogus comment ends at the first `>`, in a browser too
  ['<noscript><p title="</noscript><img src=x onerror=alert(1)>"></noscript>z', '<img src="x">">z'],
  ['<style>@import url(https://evil.example/a.css); a { background: url(javascript:alert(1)) } b { background: url(https://ok.example/i.png) }</style>',
    '<style> a { background: url() } b { background: url(https://ok.example/i.png) }</style>'],
  ['<div style="background:url(javascript:alert(1))">x</div>', '<div style="background:url()">x</div>'],
  ['<p onclick', '&lt;p onclick'], // never closed: text
  ['a < b and c > d', 'a < b and c > d'],
  ['<3 hearts', '<3 hearts'],
  ['<details open ontoggle=alert(1)><summary>s</summary></details>', '<details open><summary>s</summary></details>'],
  ['<math><mi xlink:href="javascript:alert(1)">x</mi></math>', '<math><mi>x</mi></math>'],
];
for (const [input, expected] of bypasses) {
  test(`sanitize: ${JSON.stringify(input).slice(0, 70)}`, () => {
    assert.equal(sanitizeHtml(input), expected);
  });
}

test('safeUrl: schemes after entity decoding and control-character removal', () => {
  for (const ok of ['https://a.example/', 'HTTP://A', 'mailto:a@b.c', 'tel:+1', '#frag', 'rel/path.md', '../x', '//host/x', '?q=1', '']) assert.ok(safeUrl(ok, 'href'), ok);
  for (const bad of ['javascript:1', ' JaVaScRiPt:1', 'java\tscript:1', 'jav&#x61;script:1', 'file:///etc/passwd', 'blob:https://x/1', 'data:text/html,x', 'x-apple.systempreferences:a', 'ssh://a']) assert.ok(!safeUrl(bad, 'href'), bad);
  assert.ok(safeUrl('data:image/png;base64,AA', 'src') && !safeUrl('data:image/png;base64,AA', 'href'));
});
