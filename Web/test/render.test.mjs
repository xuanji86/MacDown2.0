import { test } from 'node:test';
import assert from 'node:assert/strict';
import { flavors, render, renderResult } from '../src/render/index.ts';
import { hash53, slugify, textStats } from '../src/render/text.ts';

const defaults = {
  flavor: 'markdown',
  extensions: ['tables', 'strikethrough', 'autolink'],
  hardBreaks: false,
  allowRawHTML: true,
  headingAnchors: true,
  codeHighlighting: true,
  codeLineNumbers: false,
  inlineDollarMath: false,
  frontMatterDisplay: 'hidden',
};

test('textStats counts CJK per character and latin per word', () => {
  assert.deepEqual(textStats('中文字数 hello world'), { words: 6, characters: 16, charactersNoSpaces: 14 });
  assert.equal(textStats("it's a test").words, 3);
  assert.equal(textStats('').words, 0);
});

test('textStats: the plain-ASCII shortcut counts exactly what the grapheme segmenter counts', () => {
  const graphemes = new Intl.Segmenter('und', { granularity: 'grapheme' });
  const reference = (text) => {
    let characters = 0;
    let charactersNoSpaces = 0;
    for (const { segment } of graphemes.segment(text)) {
      if (segment === '\n') continue;
      characters++;
      if (!/^\s+$/u.test(segment)) charactersNoSpaces++;
    }
    return { characters, charactersNoSpaces };
  };
  const alphabet = ['a', 'Z', '1', ' ', '\t', '\n', '\v', '\f', '.', "'", '-', '_', '~', '\r', '\u0007', '\u007f', 'é', 'é', '中', '😀', ' ', '　'];
  let seed = 7;
  const next = () => ((seed = (seed * 1103515245 + 12345) >>> 0) / 2 ** 32);
  for (let i = 0; i < 3000; i++) {
    const n = Math.floor(next() * 40);
    // half the strings stay within the shortcut's alphabet, half wander out of it
    const pool = i % 2 ? alphabet : alphabet.slice(0, 13);
    const text = Array.from({ length: n }, () => pool[Math.floor(next() * pool.length)]).join('');
    const { characters, charactersNoSpaces } = textStats(text);
    assert.deepEqual({ characters, charactersNoSpaces }, reference(text), JSON.stringify(text));
  }
});

test('KaTeX output is memoised only while no formula has defined a global macro', () => {
  const math = { ...defaults, extensions: ['math'] };
  const undefinedFoo = renderResult('$$\\foo$$\n', math).html; // memoised: an unknown macro
  assert.match(undefinedFoo, /#cc0000/); // KaTeX shows an unknown macro in red
  const defined = renderResult('$$\\gdef\\foo{x}$$\n\n$$\\foo$$\n', math).html;
  const [, second] = defined.split('</p>\n');
  assert.match(second, /<mi>x<\/mi>/, 'after \\gdef the formula renders with the macro, not from the memo');
  assert.equal(renderResult('$$\\foo$$\n', math).html, undefinedFoo, 'the next render starts without the macro again');
});

test('an alert checked as a terminator leaves the block state alone: no hang, later source lines intact', () => {
  const all = ['tables', 'strikethrough', 'autolink', 'mark', 'footnotes', 'taskLists', 'math', 'toc', 'frontMatter', 'cjkEmphasis'];
  // this one used to loop until the page ran out of memory
  assert.match(renderResult('.\n>[!WARNING]\n-\n$', { ...defaults, extensions: all }).html, /<blockquote[^]*<ul/);
  const { blocks } = renderResult('para\n> [!NOTE]\n> note\n# Heading\n\n\nnext\n', defaults);
  assert.deepEqual(blocks.map((b) => [b.lineStart, b.lineEnd]), [[0, 1], [1, 3], [3, 4], [6, 7]]);
});

test('slugify follows GitHub style and dedupes', () => {
  const seen = new Map();
  assert.equal(slugify('Hello, World!', seen), 'hello-world');
  assert.equal(slugify('Hello World', seen), 'hello-world-1');
  assert.equal(slugify('安装 步骤', seen), '安装-步骤');
});

test('hash53 is stable and JSON-safe', () => {
  assert.equal(hash53('abc'), hash53('abc'));
  assert.notEqual(hash53('abc'), hash53('abd'));
  assert.ok(Number.isSafeInteger(hash53('x'.repeat(1000))));
});

test('blocks carry top-level source line ranges', () => {
  const md = '# Title\n\nPara one\nstill one\n\n- a\n- b\n\n> quote\n';
  const { blocks, html } = renderResult(md, defaults);
  assert.deepEqual(blocks.map((b) => [b.lineStart, b.lineEnd]), [[0, 1], [2, 4], [5, 8], [8, 9]]);
  assert.match(html, /<h1 data-line="0" data-line-end="1" id="title">Title<\/h1>/);
  assert.match(html, /<li data-line="5"/);
});

test('outline lists headings with slugs and lines', () => {
  const { outline } = renderResult('# A\n\n## B `code`\n\n## B `code`\n', defaults);
  assert.deepEqual(outline, [
    { level: 1, text: 'A', slug: 'a', line: 0 },
    { level: 2, text: 'B code', slug: 'b-code', line: 2 },
    { level: 2, text: 'B code', slug: 'b-code-1', line: 4 },
  ]);
});

test('options toggle tables, strikethrough, raw HTML and hard breaks', () => {
  const src = '| a |\n|---|\n| b |\n\n~~x~~ <b>y</b>\nz';
  const on = renderResult(src, { ...defaults, hardBreaks: true }).html;
  assert.match(on, /<table/);
  assert.match(on, /<s>x<\/s> <b>y<\/b><br>/);
  const off = renderResult(src, { ...defaults, extensions: [], allowRawHTML: false }).html;
  assert.doesNotMatch(off, /<table|<s>/);
  assert.match(off, /&lt;b&gt;y&lt;\/b&gt;/);
});

test('flavors register and unknown flavors throw', () => {
  assert.throws(() => render('x', JSON.stringify({ ...defaults, flavor: 'nope' })), /Unknown flavor/);
  flavors.register('test', (md) => {
    md.core.ruler.push('test_class', (state) => {
      for (const t of state.tokens) if (t.type === 'paragraph_open') t.attrJoin('class', 'test-flavor');
    });
  });
  const out = JSON.parse(render('hi', JSON.stringify({ ...defaults, flavor: 'test' })));
  assert.match(out.html, /<p class="test-flavor" data-line="0"/);
});

test('mermaid fences become code blocks tagged mermaid-source (what exports, Quick Look and JSC show)', () => {
  const src = 'para\n\n```mermaid\ngraph TD\n  A --> B & C\n```\n\n```js\nlet a;\n```\n';
  const { html, blocks } = renderResult(src, defaults);
  assert.match(html, /<pre data-line="2" data-line-end="6" data-lang="mermaid" class="mermaid-source"><code class="language-mermaid">graph TD\n  A --&gt; B &amp; C\n<\/code><\/pre>/);
  assert.match(html, /<pre data-line="7" data-line-end="10" data-lang="js"><code class="hljs language-js">/); // other languages are untouched
  assert.deepEqual(blocks.map((b) => [b.lineStart, b.lineEnd]), [[0, 1], [2, 6], [7, 10]]);
  assert.doesNotMatch(renderResult('```Mermaid\nx\n```', defaults).html, /mermaid-source/); // the info string is case-sensitive
});

test('mermaid-source joins classes that other rules put on the fence', () => {
  flavors.register('fence-class', (md) => {
    md.core.ruler.push('fence_class', (state) => {
      for (const t of state.tokens) if (t.type === 'fence') t.attrJoin('class', 'extra');
    });
  });
  const html = renderResult('```mermaid\nx\n```', { ...defaults, flavor: 'fence-class', codeLineNumbers: true }).html;
  assert.match(html, /<pre [^>]*class="extra mermaid-source line-numbers"[^>]*>/);
  assert.equal(html.match(/class="extra/g).length, 1);
});
