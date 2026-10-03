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
  mathDelimiters: 'both',
  frontMatterDisplay: 'hidden',
};

test('textStats counts CJK per character and latin per word', () => {
  assert.deepEqual(textStats('中文字数 hello world'), { words: 6, characters: 16, charactersNoSpaces: 14 });
  assert.equal(textStats("it's a test").words, 3);
  assert.equal(textStats('').words, 0);
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
