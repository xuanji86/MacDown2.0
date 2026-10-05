// The Pandoc blank-line rules of the quarto flavor (src/quarto/rules/pandoc-blank-line.ts): what Pandoc does, the plain
// Markdown flavor staying CommonMark, and a snapshot of a document that uses every case (test/fixtures/quarto-dialect).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadQuarto, plain, quartoOptions } from './helpers/quarto.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const { renderResult } = await loadQuarto();
const quarto = (src) => plain(renderResult(src, quartoOptions({ headingAnchors: false })).html);
const markdown = (src) => plain(renderResult(src, { ...quartoOptions({ headingAnchors: false }), flavor: 'markdown', renderChunks: [] }).html);

test('a heading needs a blank line before it (blank_before_header)', () => {
  assert.equal(quarto('text\n# not a heading'), '<p>text\n# not a heading</p>');
  assert.equal(quarto('text\n\n# heading'), '<p>text</p>\n<h1>heading</h1>');
  assert.equal(quarto('# first\n# second'), '<h1>first</h1>\n<h1>second</h1>'); // after another block it is fine
  assert.equal(quarto('# top of the document'), '<h1>top of the document</h1>');
  assert.equal(quarto('text\n## two\n'), '<p>text\n## two</p>');
});

test('a block quote needs a blank line before it (blank_before_blockquote)', () => {
  assert.equal(quarto('text\n> not a quote'), '<p>text\n&gt; not a quote</p>');
  assert.equal(quarto('text\n\n> quote'), '<p>text</p>\n<blockquote>\n<p>quote</p>\n</blockquote>');
  assert.equal(quarto('> a\n>> b'), '<blockquote>\n<p>a\n&gt; b</p>\n</blockquote>'); // the example in the Pandoc manual: not nested
  assert.equal(quarto('> a\n>\n> > b'), '<blockquote>\n<p>a</p>\n<blockquote>\n<p>b</p>\n</blockquote>\n</blockquote>');
});

test('a list needs a blank line before it (lists_without_preceding_blankline is off)', () => {
  assert.equal(quarto('text\n- a\n- b'), '<p>text\n- a\n- b</p>');
  assert.equal(quarto('text\n1. a'), '<p>text\n1. a</p>');
  assert.equal(quarto('text\n\n- a\n- b'), '<p>text</p>\n<ul>\n<li>a</li>\n<li>b</li>\n</ul>');
  assert.equal(quarto('- a\n- b'), '<ul>\n<li>a</li>\n<li>b</li>\n</ul>');
});

test('inside a list item the next marker still starts an item or a nested list', () => {
  assert.equal(quarto('- a\n  - nested\n- b'), '<ul>\n<li>a\n<ul>\n<li>nested</li>\n</ul>\n</li>\n<li>b</li>\n</ul>');
  assert.equal(quarto('1. one\n2. two\n   - x'), '<ol>\n<li>one</li>\n<li>two\n<ul>\n<li>x</li>\n</ul>\n</li>\n</ol>');
  assert.equal(quarto('- a\n\n  para\n- c'), '<ul>\n<li>\n<p>a</p>\n<p>para</p>\n</li>\n<li>\n<p>c</p>\n</li>\n</ul>');
});

test('lazy lines of a list item or a quote stay text (Pandoc collects them raw)', () => {
  assert.equal(quarto('- a\n# h'), '<ul>\n<li>a\n# h</li>\n</ul>');
  assert.equal(quarto('- a\n> q'), '<ul>\n<li>a\n&gt; q</li>\n</ul>');
  assert.equal(quarto('- a\n\n# h'), '<ul>\n<li>a</li>\n</ul>\n<h1>h</h1>');
  assert.equal(quarto('> a\n# lazy'), '<blockquote>\n<p>a\n# lazy</p>\n</blockquote>');
  assert.equal(quarto('> a\n- lazy'), '<blockquote>\n<p>a\n- lazy</p>\n</blockquote>');
  assert.equal(quarto('> text\n> - item'), '<blockquote>\n<p>text\n- item</p>\n</blockquote>'); // a list inside a quote follows the same rule
  assert.equal(quarto('> text\n>\n> - item'), '<blockquote>\n<p>text</p>\n<ul>\n<li>item</li>\n</ul>\n</blockquote>');
});

test('what Pandoc still lets end a paragraph is unchanged: fences and setext underlines', () => {
  assert.match(quarto('text\n```py\ncode\n```'), /^<p>text<\/p>\n<pre data-lang="py">/);
  assert.equal(quarto('text\n---'), '<h2>text</h2>');
  assert.equal(quarto('text\n===\n'), '<h1>text</h1>');
});

test('the plain Markdown flavor is still CommonMark', () => {
  assert.equal(markdown('text\n# h'), '<p>text</p>\n<h1>h</h1>');
  assert.equal(markdown('text\n> q'), '<p>text</p>\n<blockquote>\n<p>q</p>\n</blockquote>');
  assert.equal(markdown('text\n- a'), '<p>text</p>\n<ul>\n<li>a</li>\n</ul>');
  assert.equal(markdown('- a\n# h'), '<ul>\n<li>a</li>\n</ul>\n<h1>h</h1>');
});

test('rendering one flavor does not leak into the other (rules are per instance, in either order)', () => {
  const a = markdown('x\n# h');
  quarto('x\n# h');
  assert.equal(markdown('x\n# h'), a);
  assert.equal(quarto('x\n# h'), '<p>x\n# h</p>');
});

test('the blocks stay mappable: source lines of a paragraph that swallowed a heading line', () => {
  const res = renderResult('text\n# swallowed\n\n# real', quartoOptions({ headingAnchors: false }));
  assert.match(res.html, /<p data-line="0" data-line-end="2">text\n# swallowed<\/p>/);
  assert.match(res.html, /<h1 data-line="3"/);
  assert.deepEqual(res.outline.map((o) => o.text), ['real']);
});

test('snapshot: a document with every case', () => {
  const name = 'pandoc-blank-line';
  const src = readFileSync(join(here, `fixtures/quarto-dialect/${name}.qmd`), 'utf8');
  const html = renderResult(src, quartoOptions({ codeLineNumbers: true, frontMatterDisplay: 'table' })).html;
  const file = join(here, `snapshots/quarto-dialect/${name}.html`);
  if (process.env.SNAPSHOT_UPDATE === '1') {
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, html);
  } else {
    assert.ok(existsSync(file), `missing snapshot ${file}; run SNAPSHOT_UPDATE=1 npm test`);
    assert.equal(html, readFileSync(file, 'utf8'));
  }
});
