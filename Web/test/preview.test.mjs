import { test } from 'node:test';
import assert from 'node:assert/strict';
import { renderResult } from '../src/render/index.ts';
import { MAX_MIDDLE, planPatch } from '../src/preview/dom-patch.ts';
import { resolveImageSrc } from '../src/preview/images.ts';
import { lastLE, lineToY, yToLine } from '../src/preview/scroll-map.ts';
import { alignSegments, splitBlocks } from '../src/preview/split-html.ts';

const options = {
  flavor: 'markdown',
  extensions: ['tables', 'strikethrough', 'autolink', 'mark', 'sup', 'sub', 'underline', 'footnotes', 'taskLists', 'math', 'toc', 'frontMatter', 'cjkEmphasis'],
  hardBreaks: false,
  allowRawHTML: true,
  headingAnchors: true,
  codeHighlighting: true,
  codeLineNumbers: false,
  inlineDollarMath: false,
  frontMatterDisplay: 'table',
};
const render = (md) => renderResult(md, options);

// --- planPatch -------------------------------------------------------------------------------------------

test('planPatch: identical lists keep everything', () => {
  assert.deepEqual(planPatch([1, 2, 3], [1, 2, 3]), { prefix: 3, suffix: 0, matches: [] });
});

test('planPatch: one changed block in the middle', () => {
  assert.deepEqual(planPatch([1, 2, 3, 4], [1, 9, 3, 4]), { prefix: 1, suffix: 2, matches: [] });
});

test('planPatch: insertion and deletion', () => {
  assert.deepEqual(planPatch([1, 2], [1, 7, 2]), { prefix: 1, suffix: 1, matches: [] });
  assert.deepEqual(planPatch([1, 7, 2], [1, 2]), { prefix: 1, suffix: 1, matches: [] });
  assert.deepEqual(planPatch([], [1, 2]), { prefix: 0, suffix: 0, matches: [] });
  assert.deepEqual(planPatch([1, 2], []), { prefix: 0, suffix: 0, matches: [] });
});

test('planPatch: LCS keeps unchanged blocks inside the edited middle', () => {
  // a b X c d  ->  a Y b c Z d : prefix a, suffix d, middle [b X c] vs [Y b c Z]
  const plan = planPatch([1, 2, 99, 3, 4], [1, 98, 2, 3, 97, 4]);
  assert.equal(plan.prefix, 1);
  assert.equal(plan.suffix, 1);
  assert.deepEqual(plan.matches, [[1, 2], [3, 3]]);
});

test('planPatch: a moved block is delete + insert, order stays consistent', () => {
  const plan = planPatch([1, 2, 3, 4], [1, 3, 4, 2]);
  const olds = plan.matches.map((m) => m[0]);
  const news = plan.matches.map((m) => m[1]);
  assert.deepEqual(olds, [...olds].sort((a, b) => a - b));
  assert.deepEqual(news, [...news].sort((a, b) => a - b));
  assert.equal(plan.prefix + plan.matches.length + plan.suffix, 3); // 1, 3, 4 survive
});

test('planPatch: oversized middle degrades to wholesale replace', () => {
  const a = Array.from({ length: MAX_MIDDLE + 5 }, (_, i) => i);
  const b = a.map((x) => x + 100000);
  assert.deepEqual(planPatch(a, b), { prefix: 0, suffix: 0, matches: [] });
});

// --- splitBlocks -----------------------------------------------------------------------------------------

const DOCS = {
  syntax: '---\ntitle: X\n---\n\n[TOC]\n\n# H\n\n$$\nx^2\n$$\n\n\\[ y \\]\n\n- [ ] task\n- [x] done\n\n```js\nlet a = 1;\n```\n\n==mark== ^sup^ ~sub~ ++ins++\n',
  basic: '# Title\n\nPara one\nstill one\n\n- a\n- b\n  - nested\n\n> quote\n> more\n\n---\n\n```js\nlet a = 1 < 2;\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nlast ![img](pic.png) paragraph\n',
  html: '<div class="x"><b>bold</b> <img src="a.png"></div>\n\ntext\n\n<!-- a comment -->\n\n<br/>\n\n<script>if (a < b) { x("</div>") }</script>\n\nend',
  quotes: '<a title=">" href=\'x>y\'>link</a>\n\n<p data-line="9">raw</p>\n',
  empty: '',
};

test('splitBlocks: segments concatenate back to the html and match the block count', () => {
  for (const [name, md] of Object.entries(DOCS)) {
    const { html, blocks } = render(md);
    const segs = splitBlocks(html);
    assert.ok(segs, name);
    assert.equal(segs.length, blocks.length, name);
    assert.equal(segs.map((s) => html.slice(s.start, s.end)).join(''), html, name);
  }
});

test('splitBlocks: hash ignores data-line shifts but not content', () => {
  const hashes = (md) => splitBlocks(render(md).html).map((s) => s.hash);
  const base = hashes('# A\n\ntext one\n\n- x\n- y\n');
  const shifted = hashes('# A\n\nnew para\n\n\n\ntext one\n\n- x\n- y\n');
  assert.equal(shifted[shifted.length - 1], base[base.length - 1]); // the list moved down, same hash
  assert.equal(shifted[shifted.length - 2], base[base.length - 2]);
  const edited = hashes('# A\n\ntext onE\n\n- x\n- y\n');
  assert.notEqual(edited[1], base[1]);
  assert.equal(edited[0], base[0]);
  assert.equal(edited[2], base[2]);
});

test('splitBlocks: heading slug dedupe changes the later block hash (cross-block dependency is not missed)', () => {
  const one = splitBlocks(render('# Same\n\n## Other\n').html);
  const two = splitBlocks(render('# Same\n\n## Same\n').html);
  assert.notEqual(one[1].hash, two[1].hash);
});

test('splitBlocks: unbalanced html is rejected or miscounted, never silently accepted', () => {
  const md = '<div>\n\ninside\n\n</div>\n';
  const { html, blocks } = render(md);
  const segs = splitBlocks(html);
  assert.ok(segs === null || segs.length !== blocks.length);
  assert.equal(splitBlocks('</p>'), null);
  assert.equal(splitBlocks('<p>x'), null);
});

test('alignSegments folds the footnote section into one tail segment', () => {
  const md = 'Text[^1] and more.\n\nPara two.\n\n[^1]: The note.\n';
  const { html, blocks } = render(md);
  const raw = splitBlocks(html);
  assert.equal(raw.length, blocks.length + 2); // <hr class="footnotes-sep"> and <section class="footnotes">
  const segs = alignSegments(html, raw, blocks.length);
  assert.equal(segs.length, blocks.length + 1);
  assert.equal(segs.at(-1).tail, true);
  assert.equal(segs.map((s) => html.slice(s.start, s.end)).join(''), html);
});

test('alignSegments rejects counts it cannot explain', () => {
  const { html, blocks } = render('<div>a</div> <b>x</b>\n\npara\n');
  assert.equal(alignSegments(html, splitBlocks(html), blocks.length), null); // extra segment that is not a footnote section
  assert.equal(alignSegments(html, null, 1), null);
});

// --- scroll-map ------------------------------------------------------------------------------------------

const anchors = [
  { line0: 0, line1: 1, top: 0, bottom: 40 }, // heading
  { line0: 2, line1: 6, top: 60, bottom: 220 }, // paragraph, 4 lines in 160px
  { line0: 8, line1: 9, top: 240, bottom: 280 },
];
const at = (i) => anchors[i];

test('lineToY: inside a block, in the gap between blocks, and at the edges', () => {
  assert.equal(lineToY(0, 3, at), 0);
  assert.equal(lineToY(4, 3, at), 140); // halfway through the 4-line paragraph
  assert.equal(lineToY(1.5, 3, at), 50); // gap lines 1..2 span y 40..60
  assert.equal(lineToY(7, 3, at), 230); // gap lines 6..8 span y 220..240
  assert.equal(lineToY(50, 3, at), 280); // past the end
  assert.equal(lineToY(5, 0, at), 0); // no blocks
});

test('yToLine inverts lineToY', () => {
  for (const line of [0, 0.5, 1.5, 2, 3.25, 4, 5.9, 7, 8, 8.5]) {
    assert.ok(Math.abs(yToLine(lineToY(line, 3, at), 3, at) - line) < 1e-9, `line ${line}`);
  }
  assert.equal(yToLine(-5, 3, at), 0);
  assert.equal(yToLine(9999, 3, at), 9);
});

test('lastLE', () => {
  const a = [1, 3, 3, 7];
  assert.equal(lastLE(4, (i) => a[i], 0), -1);
  assert.equal(lastLE(4, (i) => a[i], 3), 2);
  assert.equal(lastLE(4, (i) => a[i], 100), 3);
});

// --- images ----------------------------------------------------------------------------------------------

test('resolveImageSrc rewrites relative paths into the doc host and leaves the rest alone', () => {
  assert.equal(resolveImageSrc('pic.png'), 'macdown2-res://doc/pic.png');
  assert.equal(resolveImageSrc('./img/a%20b.png?x=1#h'), 'macdown2-res://doc/img/a%20b.png?x=1#h');
  assert.equal(resolveImageSrc('a/../b.png'), 'macdown2-res://doc/b.png');
  for (const same of ['https://x/y.png', 'data:image/png;base64,AA', '//cdn/x.png', '/abs/x.png', '#frag', '', 'macdown2-res://doc/x.png']) {
    assert.equal(resolveImageSrc(same), null, same);
  }
});

test('resolveImageSrc refuses to climb out of the document directory', () => {
  for (const up of ['../x.png', 'a/../../x.png', '%2e%2e/x.png', './%2E./x.png', '..']) assert.equal(resolveImageSrc(up), null, up);
  // an encoded slash is not a path separator for the URL parser: the Swift handler decodes and rejects it
  assert.equal(resolveImageSrc('..%2f..%2fPackage.swift'), 'macdown2-res://doc/..%2f..%2fPackage.swift');
});
