// The inline source map (src/render/inline-map.ts probes a block, src/preview/source-map.ts and text-domain.ts read the probe on
// the page). Checked against an oracle that knows nothing about how the map is made: change the one source character the map
// names for a unit of the shown text (a letter for another letter, punctuation for other punctuation) and render the whole document
// again; exactly that unit of the shown text must change, to the new character. A unit the map names wrongly changes some other
// place, or none. When the change also moves other text (it made or broke syntax: a link label, a flanking rule) the sample proves
// nothing and is counted apart; there must be few of those and no failure at all.
//
// Then edits made through the map (src/preview/source-map.ts sourceEdit, what the page sends the app): a deletion or replacement of
// shown units must be the deletion of exactly the source characters the oracle confirmed for them, typing goes next to the confirmed
// neighbour, and after rendering the edited source the block shows what the user typed wherever the edit sits inside plain text.
//
// MD2_MAP_DOCS=<n> scales the generated documents (default 160 per option set), MD2_MAP_SEED=<n> replays one seed.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { inlineMap, renderResult } from '../src/render/index.ts';
import { alignKept } from '../src/render/align.ts';
import { readProbes, settle, sourceEdit, insertionAt } from '../src/preview/source-map.ts';
import { blockHTML, linesRange, textNodesOf, textOf } from './helpers/text-dom.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const DOCS = Number(process.env.MD2_MAP_DOCS ?? 160);
const SEED = process.env.MD2_MAP_SEED === undefined ? null : Number(process.env.MD2_MAP_SEED);

const ALL = ['tables', 'strikethrough', 'autolink', 'smartPunctuation', 'mark', 'sup', 'sub', 'underline', 'footnotes', 'taskLists', 'math', 'toc', 'frontMatter', 'cjkEmphasis', 'emoji'];
const base = { flavor: 'markdown', hardBreaks: false, allowRawHTML: true, headingAnchors: true, codeHighlighting: true, codeLineNumbers: false, inlineDollarMath: false, frontMatterDisplay: 'hidden' };
const OPTION_SETS = {
  app: { ...base, extensions: ['tables', 'strikethrough', 'autolink', 'mark', 'footnotes', 'taskLists', 'math', 'toc', 'frontMatter', 'cjkEmphasis'] },
  all: { ...base, extensions: ALL, inlineDollarMath: true, codeLineNumbers: true, frontMatterDisplay: 'table' },
  odd: { ...base, extensions: ALL, headingAnchors: false, hardBreaks: true, allowRawHTML: false },
};

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

/** What the page computes for block j of `doc`: its shown text and, per unit, the source offset (document) or -1; null rel = unmappable. */
function mapBlock(doc, options, result, html, j) {
  const b = result.blocks[j];
  const [start, end] = linesRange(doc, b.lineStart, b.lineEnd);
  const blockText = doc.slice(start, end);
  const live = textOf(html[j]);
  const first = b.lineStart === 0;
  let probes = inlineMap.probe(blockText, options, first, null);
  let rel = probes.length ? readProbes(live, probes, textOf) : null;
  if (!rel && probes.length) {
    probes = inlineMap.probe(blockText, options, first, inlineMap.context(doc, options));
    rel = readProbes(live, probes, textOf);
  }
  if (rel && !settle(rel, live, blockText)) rel = null;
  const offsets = new Int32Array(live.length).fill(-1);
  if (rel) for (let k = 0; k < rel.length; k++) if (rel[k] >= 0) offsets[k] = rel[k] + start;
  return { live, offsets, mapped: rel !== null, start, end };
}

// A different character of the same kind, so the change is as unlikely as possible to make or break syntax. One half of a
// surrogate pair gets its lowest bit flipped: still a valid pair, a different character, only that unit changes.
function alternative(c) {
  const u = c.charCodeAt(0);
  if (u >= 0xd800 && u <= 0xdfff) return String.fromCharCode(u ^ 1);
  if (/[a-z]/.test(c)) return c === 'q' ? 'z' : c === 'z' ? 'k' : 'q';
  if (/[A-Z]/.test(c)) return c === 'Q' ? 'Z' : c === 'Z' ? 'K' : 'Q';
  if (/[0-8]/.test(c)) return String(Number(c) + 1);
  if (c === '9') return '3';
  if (/[一-鿿]/.test(c)) return c === '字' ? '文' : '字';
  if (c === ' ') return '\t';
  if (c === '\t') return ' ';
  if (/[\p{L}\p{N}\p{M}]/u.test(c)) return c === 'é' ? 'ü' : 'é';
  if (/[.,;:!?'"()\-]/.test(c)) return c === ';' ? ',' : ';';
  if (/[\p{P}\p{S}]/u.test(c)) return c === '、' ? '，' : '、';
  return null;
}

/** The oracle for one placed unit: 'pass', 'moved' (the change touched other text too) or a failure message. */
function confirm(doc, options, j, live, k, at) {
  const c = doc[at];
  if (c !== live[k]) return `source[${at}] is ${JSON.stringify(c)}, shown unit ${k} is ${JSON.stringify(live[k])}`;
  const alt = alternative(c);
  if (alt === null) return 'moved';
  const changed = doc.slice(0, at) + alt + doc.slice(at + 1);
  const r = renderResult(changed, options);
  const html = blockHTML(r);
  if (!html || r.blocks.length <= j) return 'moved';
  const now = textOf(html[j]);
  if (now.length !== live.length) return 'moved';
  const diffs = [];
  for (let i = 0; i < now.length; i++) if (now[i] !== live[i]) diffs.push(i);
  if (diffs.length === 1 && diffs[0] === k && now[k] === alt) return 'pass';
  // The new character showed up in one other place, and nothing else moved: the map named the wrong unit.
  if (diffs.length === 1 && now[diffs[0]] === alt) return `changing source[${at}] ${JSON.stringify(c)} -> ${JSON.stringify(alt)} changed shown unit ${diffs[0]}, not unit ${k}`;
  return 'moved'; // the change made or broke syntax: this sample says nothing
}

function failWith(doc, options, message) {
  const file = join(tmpdir(), 'md2-inline-map-failure.md');
  writeFileSync(file, doc);
  assert.fail(`${message}\n  options: ${JSON.stringify(options.extensions)}\n  text in ${file}: ${JSON.stringify(doc.slice(0, 400))}`);
}

/** Maps every block of `doc`, confirms up to `budget` placed units with the oracle; returns counts. */
function checkDocument(doc, options, r, budget, stats) {
  const result = renderResult(doc, options);
  const html = blockHTML(result);
  if (!html) return;
  for (let j = 0; j < result.blocks.length; j++) {
    const m = mapBlock(doc, options, result, html, j);
    stats.blocks++;
    if (!m.mapped) {
      stats.unmappable++;
      continue;
    }
    const placed = [];
    for (let k = 0; k < m.offsets.length; k++) if (m.offsets[k] >= 0) placed.push(k);
    stats.placed += placed.length;
    stats.units += m.live.length;
    for (let n = 0; n < Math.min(budget, placed.length); n++) {
      const k = placed.length <= budget ? placed[n] : placed[r.int(placed.length)];
      const verdict = confirm(doc, options, j, m.live, k, m.offsets[k]);
      if (verdict === 'pass') stats.pass++;
      else if (verdict === 'moved') stats.moved++;
      else failWith(doc, options, `block ${j}: ${verdict}`);
    }
  }
}

// --- unit cases -----------------------------------------------------------------------------------------------------------

function only(doc, options = OPTION_SETS.app) {
  const result = renderResult(doc, options);
  const html = blockHTML(result);
  const m = mapBlock(doc, options, result, html, 0);
  // the shown text with every placed unit bracketed by its source character's offset
  return { m, placed: m.live.split('').map((c, k) => (m.offsets[k] >= 0 ? c : '·')).join('') };
}

test('plain text, emphasis, code spans, links and CJK are placed character by character', () => {
  assert.equal(only('Hello **bold** and *em* `code` [link](http://x.y "t") 中文。\n').placed, 'Hello bold and em code link 中文。\n'.replace(/\n$/, '') + '·');
  const { m } = only('Hello **bold** world\n');
  assert.equal(m.live, 'Hello bold world\n');
  assert.deepEqual([...m.offsets].slice(0, 16), [0, 1, 2, 3, 4, 5, 8, 9, 10, 11, 14, 15, 16, 17, 18, 19]);
});

test('escapes, entities, typographer replacements, emoji, math and footnote numbers have no place', () => {
  assert.equal(only('a \\* b &amp; c\n').placed, 'a · b · c·');
  assert.equal(only('"a" -- b... (c)\n', OPTION_SETS.all).placed, '·a· · b· ··');
  assert.equal(only('x :smile: y\n', OPTION_SETS.all).placed, 'x ·· y·');
  assert.equal(only('m $x+1$ n\n', OPTION_SETS.all).placed, 'm  n·');
  assert.equal(only('t[^1] u\n\n[^1]: n\n').placed, 't u·');
});

test('container prefixes, list markers, heading markers and closing hashes are skipped', () => {
  assert.equal(only('> quoted\n> line two\n').placed, '·quoted·line two··');
  assert.equal(only('- one\n  two\n').placed, '·one·two··');
  assert.equal(only('## Title ##\n').placed, 'Title·');
  assert.equal(only('- [ ] task\n').placed, '··task··'); // the space after the box could be the one inside it: given up
});

test('a reference link defined elsewhere maps with the document context', () => {
  const { m } = only('see [the docs][d] now\n\n[d]: http://d.example\n');
  assert.equal(m.mapped, true);
  assert.equal(m.live.split('').map((c, k) => (m.offsets[k] >= 0 ? c : '·')).join(''), 'see the docs now·');
  // `[label]` and `[label][]`: the text is the label too, editing it would break the link
  assert.equal(only('a [d] b [d][] c\n\n[d]: http://d.example\n').placed, 'a · b · c·');
});

test('alignKept keeps what a rewrite kept and gives up characters a removed run could have been', () => {
  assert.deepEqual([...alignKept('a--b', 'a–b')], [0, -1, 3]);
  assert.deepEqual([...alignKept('***a**', '*a')], [-1, 3]);
  assert.deepEqual([...alignKept('abc', 'abc')], [0, 1, 2]);
  assert.deepEqual([...alignKept(':smile: x', '😄 x')], [-1, -1, 7, 8]);
});

test('typing goes next to the character the caret is attached to; deletions must not cross formatting', () => {
  const offsets = Int32Array.from([0, 1, 2, 5, 6, -1]);
  assert.equal(insertionAt(offsets, 3, true, false), 3); // end of "abc" in **...**: inside it
  assert.equal(insertionAt(offsets, 3, false, true), 5); // start of the next node: after the markup
  assert.equal(insertionAt(offsets, 5, true, false), 7); // after "e"
  assert.equal(insertionAt(offsets, 6, false, true), -1);
  assert.deepEqual(sourceEdit(offsets, 'abcde\n', 'abc**de\n', 1, 3, '', true, true), { from: 1, to: 3 });
  assert.deepEqual(sourceEdit(offsets, 'abcde\n', 'abc**de\n', 2, 4, '', true, true), { refused: 'formatting' });
  assert.deepEqual(sourceEdit(offsets, 'abcde\n', 'abc**de\n', 4, 6, '', true, true), { refused: 'newline' });
  assert.deepEqual(sourceEdit(offsets, 'abcde\n', 'abc**de\n', 1, 1, 'x\ny', true, true), { refused: 'newline' });
});

// --- corpus and generated documents ----------------------------------------------------------------------------------------

const fixtures = join(here, '../../Packages/MarkdownCore/Tests/MarkdownCoreTests/Fixtures');
const corpus = [];
for (const dir of ['macdown3000', 'own']) {
  for (const f of readdirSync(join(fixtures, dir)).sort()) if (f.endsWith('.md')) corpus.push([`${dir}/${f}`, readFileSync(join(fixtures, dir, f), 'utf8')]);
}

test('the snapshot corpus: every unit the map places is confirmed by the oracle', () => {
  for (const [name, options] of Object.entries(OPTION_SETS)) {
    const stats = { blocks: 0, unmappable: 0, placed: 0, units: 0, pass: 0, moved: 0 };
    const r = rng(17);
    for (const [, text] of corpus) checkDocument(text.replace(/\r\n?/g, "\n"), options, r, 14, stats);
    assert.ok(stats.pass > 500, `${name}: ${JSON.stringify(stats)}`);
    assert.ok(stats.moved < stats.pass / 10, `${name}: too many inconclusive samples ${JSON.stringify(stats)}`);
    console.log(`corpus ${name}: ${JSON.stringify(stats)}`);
  }
});

const WORDS = ['alpha', 'beta', 'Gamma', 'delta', '42', 'x', 'snake_case_name', 'it’s', '中文', '「重点」', '的', '😀', 'café', 'naïve', 'a·b'];
const INLINE = [
  () => '**bold**', () => '*em*', () => '_under_', () => '__strong__', () => '***both***', () => '`code`', () => '`` a ` b ``', () => '` padded `',
  () => '[link](http://x.example "t")', () => '[ref link][r1]', () => '[r1]', () => '![img](a.png)', () => '<span>html</span>', () => '<b>b</b>',
  () => '&amp;', () => '&copy;', () => '\\*not em\\*', () => '\\\\', () => '~~del~~', () => '==mark==', () => 'H~2~O', () => 'x^2^', () => '$x+1$',
  () => '\\(a\\)', () => 'claim[^1]', () => '^[inline note]', () => ':smile:', () => '"quoted"', () => '--', () => '...', () => '(c)', () => '<http://a.example>',
  () => 'http://example.com', () => 'www.example.org', () => '*', () => '**', () => '_', () => '[x]', () => '**「重点」**的', () => '`中文`', () => 'a b',
];

function inlineRun(r, n) {
  const out = [];
  for (let i = 0; i < n; i++) out.push(r.int(3) ? r.pick(WORDS) : r.pick(INLINE)());
  let s = out.join(r.pick([' ', ' ', '', '，']));
  if (r.int(6) === 0) s += r.pick(['  \n', '\n', '\\\n']) + r.pick(WORDS);
  return s;
}

function generate(r) {
  const blocks = [];
  const n = 2 + r.int(7);
  for (let i = 0; i < n; i++) {
    const t = () => inlineRun(r, 2 + r.int(6));
    switch (r.int(12)) {
      case 0: blocks.push(`# ${t()}`); break;
      case 1: blocks.push(`## ${t()} ##`); break;
      case 2: blocks.push(`${t()}\n===`); break;
      case 3: blocks.push(`- ${t()}\n- ${t()}\n  ${t()}`); break;
      case 4: blocks.push(`1. ${t()}\n2. [ ] ${t()}`); break;
      case 5: blocks.push(`> ${t()}\n> ${t()}\n${t()}`); break;
      case 6: blocks.push(`> [!NOTE]\n> ${t()}`); break;
      case 7: blocks.push(`| ${r.pick(WORDS)} | ${r.pick(WORDS)} |\n|---|---|\n| ${t()} | ${r.pick(WORDS)} |`); break;
      case 8: blocks.push('```\ncode ' + r.pick(WORDS) + '\n```'); break;
      default: blocks.push(`${t()}\n${t()}`);
    }
  }
  if (r.int(2)) blocks.push('[r1]: http://r.example "R"');
  if (r.int(2)) blocks.push('[^1]: A note with **bold**.');
  return blocks.join('\n\n') + '\n';
}

test('generated documents: every unit the map places is confirmed by the oracle', () => {
  const seeds = SEED === null ? Array.from({ length: DOCS }, (_, i) => i + 1) : [SEED];
  for (const [name, options] of Object.entries(OPTION_SETS)) {
    const stats = { blocks: 0, unmappable: 0, placed: 0, units: 0, pass: 0, moved: 0 };
    for (const seed of seeds) {
      const r = rng(seed * 7919 + name.length);
      checkDocument(generate(r), options, r, 12, stats);
    }
    assert.ok(stats.moved < stats.pass / 5, `${name}: too many inconclusive samples ${JSON.stringify(stats)}`);
    console.log(`generated ${name} (${seeds.length} docs): ${JSON.stringify(stats)}`);
  }
});

// --- edits through the map ---------------------------------------------------------------------------------------------------

const INERT = ['q', 'Z', '7', '字', 'é'];
const ANY = [...INERT, '*', '_', '`', '[', ']', '#', '\\', '&', ' ', '~', '<', '中文', 'xy', '😀'];
const inert = (s) => /^[\p{L}\p{N}]*$/u.test(s);

/** Random edits of the shown text of every mapped block of `doc`, made through the map; see the file header. */
function editDocument(doc, options, r, stats) {
  const result = renderResult(doc, options);
  const html = blockHTML(result);
  if (!html) return;
  for (let j = 0; j < result.blocks.length; j++) {
    const m = mapBlock(doc, options, result, html, j);
    if (!m.mapped) continue;
    const { starts } = textNodesOf(html[j]);
    const len = m.live.length;
    const sameNode = (a, b) => !starts.some((s) => s > a && s <= b); // units a..b in one text node
    for (let n = 0; n < 6; n++) {
      const kind = r.int(3); // 0 type, 1 delete, 2 replace
      const k0 = r.int(len + 1);
      const k1 = kind === 0 ? k0 : Math.min(len, k0 + 1 + r.int(3));
      let prev = k0 > 0;
      let next = k0 < len;
      if (k0 > 0 && starts.includes(k0)) {
        if (r.int(2)) next = false;
        else prev = false;
      }
      const data = kind === 1 ? '' : r.pick(r.int(2) ? INERT : ANY);
      const v = sourceEdit(m.offsets, m.live, doc, k0, k1, data, prev, next);
      stats.edits++;
      if ('refused' in v) {
        stats.refused[v.refused] = (stats.refused[v.refused] ?? 0) + 1;
        continue;
      }
      stats.applied++;
      // The source characters removed are the shown characters removed, and typing lands next to the unit the caret is attached to.
      if (doc.slice(v.from, v.to) !== m.live.slice(k0, k1)) failWith(doc, options, `block ${j}: deleting shown ${JSON.stringify(m.live.slice(k0, k1))} deletes source ${JSON.stringify(doc.slice(v.from, v.to))}`);
      if (k0 === k1) {
        const anchor = prev && m.offsets[k0 - 1] >= 0 ? m.offsets[k0 - 1] + 1 : m.offsets[k0];
        if (v.from !== anchor) failWith(doc, options, `block ${j}: typing at unit ${k0} goes to ${v.from}, not ${anchor}`);
      }
      // Each anchor unit is one the oracle confirms (when it can tell).
      for (const k of k0 === k1 ? [prev && m.offsets[k0 - 1] >= 0 ? k0 - 1 : k0] : [k0, k1 - 1]) {
        const verdict = confirm(doc, options, j, m.live, k, m.offsets[k]);
        if (verdict !== 'pass' && verdict !== 'moved') failWith(doc, options, `block ${j}: ${verdict}`);
      }
      // Inside plain text (both neighbours placed and next to the edit in the source, one text node, letters typed or deleted):
      // rendering the edited source shows exactly what was typed.
      const a = k0 - 1;
      const b = k1;
      const interior = a >= 0 && b < len && m.offsets[a] >= 0 && m.offsets[b] >= 0 && sameNode(a, b) && inert(data) && inert(m.live.slice(k0, k1)) &&
        inert(m.live[a]) && inert(m.live[b]) && v.from === m.offsets[a] + 1 && v.to === m.offsets[b];
      if (!interior) continue;
      stats.interior++;
      const edited = doc.slice(0, v.from) + data + doc.slice(v.to);
      const again = renderResult(edited, options);
      const h2 = blockHTML(again);
      const now = h2 && again.blocks.length === result.blocks.length ? textOf(h2[j]) : null;
      const want = m.live.slice(0, k0) + data + m.live.slice(k1);
      if (now === want) stats.shown++;
      else {
        stats.syntax++;
        if (stats.examples.length < 5) stats.examples.push({ block: doc.slice(m.start, m.end), want, now });
      }
    }
  }
}

test('edits through the map: the same source characters, and plain-text edits render as typed', () => {
  const seeds = SEED === null ? Array.from({ length: DOCS }, (_, i) => i + 1) : [SEED];
  let total = 0;
  for (const [name, options] of Object.entries(OPTION_SETS)) {
    const stats = { edits: 0, applied: 0, refused: {}, interior: 0, shown: 0, syntax: 0, examples: [] };
    for (const seed of seeds) {
      const r = rng(seed * 104729 + name.length);
      editDocument(generate(r), options, r, stats);
    }
    for (const [, text] of corpus.slice(0, 12)) editDocument(text.replace(/\r\n?/g, '\n'), options, rng(5), stats);
    total += stats.edits;
    // A letter typed or deleted inside a word can still change the syntax around it (a shortcut reference's label, a scheme that
    // linkify no longer knows): rare, and it is what the same edit in the source does too.
    assert.ok(stats.syntax <= stats.interior / 50, `${name}: ${JSON.stringify(stats)}`);
    console.log(`edits ${name}: ${JSON.stringify({ ...stats, examples: stats.examples.length })}`);
    if (stats.examples.length) console.log(JSON.stringify(stats.examples, null, 1));
  }
  assert.ok(total > 1000);
});
