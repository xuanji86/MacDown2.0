// The incremental renderer (src/render/incremental.ts) against the whole-document renderer: after every edit of a long
// random edit sequence, over the snapshot corpus, generated documents and hand-written adversarial cases, the incremental
// result must equal renderResult's byte for byte (html, blocks, tasks, outline, stats, front matter), and its `segments`
// what the preview page would cut the HTML into itself.
//
// MD2_DIFF_EDITS=<n> scales the random edit sequences (default 150 per generated document and option set, a third of that per fixture); MD2_DIFF_SEED=<n> replays one
// seed. A failure prints the seed, the edit and the text; the text is also written to $TMPDIR/md2-incremental-failure.md.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { alignSegments, splitBlocks } from '../src/preview/split-html.ts';
import { LRU } from '../src/render/lru.ts';
import { scanCuts } from '../src/render/incremental.ts';
import { loadQuarto, quartoOptions } from './helpers/quarto.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const { renderResult, renderIncremental, incremental, flavors } = await loadQuarto();

const EDITS = Number(process.env.MD2_DIFF_EDITS ?? 150);
const SEED = process.env.MD2_DIFF_SEED === undefined ? null : Number(process.env.MD2_DIFF_SEED);

const ALL = ['tables', 'strikethrough', 'autolink', 'smartPunctuation', 'mark', 'sup', 'sub', 'underline', 'footnotes', 'taskLists', 'math', 'toc', 'frontMatter', 'cjkEmphasis', 'emoji'];
const base = { flavor: 'markdown', hardBreaks: false, allowRawHTML: true, headingAnchors: true, codeHighlighting: true, codeLineNumbers: false, inlineDollarMath: false, frontMatterDisplay: 'hidden', files: {} };
// The app's defaults, everything on, and the odd combinations (anchors off with [TOC], no source lines, raw HTML off, ...).
const OPTION_SETS = {
  app: { ...base, extensions: ['tables', 'strikethrough', 'autolink', 'mark', 'footnotes', 'taskLists', 'math', 'toc', 'frontMatter', 'cjkEmphasis'] },
  all: { ...base, extensions: ALL, inlineDollarMath: true, codeLineNumbers: true, frontMatterDisplay: 'table' },
  odd: { ...base, extensions: ALL, headingAnchors: false, hardBreaks: true, allowRawHTML: false, sourceLines: false, codeHighlighting: false },
};

// Cuts: everywhere the scanner allows (every boundary gets exercised), a few, or the shipped defaults.
const SECTIONS = {
  every: { min: 0, max: 1e9, everyCandidate: true },
  some: { min: 40, max: 400, everyCandidate: false },
  shipped: { min: 1024, max: 16 * 1024, everyCandidate: false },
};

function check(src, options, where) {
  const want = renderResult(src, options);
  const { segments, ...got } = renderIncremental(src, options);
  const a = JSON.stringify(got);
  const b = JSON.stringify(want);
  if (a !== b) {
    let at = 0;
    while (at < a.length && a[at] === b[at]) at++;
    const file = join(tmpdir(), 'md2-incremental-failure.md');
    writeFileSync(file, src);
    assert.fail(`${where}: incremental differs at JSON offset ${at} (${JSON.stringify(incremental.lastRun())}); text in ${file}\n  incremental: ${JSON.stringify(a.slice(Math.max(0, at - 100), at + 100))}\n  whole:       ${JSON.stringify(b.slice(Math.max(0, at - 100), at + 100))}`);
  }
  if (segments !== undefined) {
    const expected = alignSegments(want.html, splitBlocks(want.html), want.blocks.length);
    if (JSON.stringify(segments) !== JSON.stringify(expected)) {
      writeFileSync(join(tmpdir(), 'md2-incremental-failure.md'), src);
      assert.fail(`${where}: segments differ from what the page computes`);
    }
  }
  return incremental.lastRun();
}

// mulberry32
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

// --- corpus ------------------------------------------------------------------------------------------------------------

const fixtures = join(here, '../../Packages/MarkdownCore/Tests/MarkdownCoreTests/Fixtures');
const corpus = [];
for (const dir of ['macdown3000', 'own']) {
  for (const f of readdirSync(join(fixtures, dir)).sort()) if (f.endsWith('.md')) corpus.push([`${dir}/${f}`, readFileSync(join(fixtures, dir, f), 'utf8')]);
}

// Block snippets for generated documents and for insertions: every construct the cuts must respect, several that span
// blank lines with column-0 lines inside, footnotes, references, duplicate headings, tasks.
const SNIPPETS = [
  '# Heading\n', '## Heading\n', '## Heading\n', '### Same Title\n', 'Setext title\n===\n', 'Under\n---\n',
  'A paragraph with *emphasis*, **strong**, `code`, ~~gone~~, ==mark==, H~2~O, x^2^, _under_ and a [link](http://example.com).\n',
  'Reference [link][ref] and [another][Ref2] and [missing][nope].\n', '[ref]: http://example.com/a "Title"\n', '[Ref2]: <http://example.com/b>\n', '[ref]: http://example.com/override\n',
  'A claim[^1] and another[^note] and again[^1].\n', '[^1]: The first note.\n', '[^note]: A note\n\n    with a second paragraph.\n', '[^1]: A duplicate definition.\n',
  'Inline footnote^[inline *note* text] here.\n', 'Undefined[^missing] reference.\n',
  '- item one\n- item two\n', '- [ ] open task\n- [x] done task\n', '1. first\n2. second\n', '- loose\n\n- list\n', '* star\n\n  continued paragraph\n',
  '- outer\n  - inner\n    - deeper\n', '> quote line\n> second\n', '> [!NOTE]\n> An alert.\n', '> [!WARNING]\n> Careful.\n',
  '```js\nconst a = 1;\n\nconsole.log(a);\n```\n', '```\nplain\n\n# not a heading\n\n```\n', '~~~python\ndef f():\n\n    return 1\n~~~\n', '````md\n```\nnested\n```\n````\n',
  '    indented code\n\n    more code\n', '| a | b |\n|---|:-:|\n| 1 | 2 |\n', '| x |\n|---|\n| y |\n\n| z |\n|---|\n',
  '$$\nx^2 + y^2\n\n= z^2\n$$\n', '$$ e^{i\\pi} + 1 = 0 $$\n', '\\[\n\\int_0^1 f\n\n\\]\n', 'Math $a+b$ inline and \\(c\\) too.\n',
  '<div>\n<b>html</b>\n</div>\n', '<!--\ncomment\n\n# hidden heading\n\n-->\n', '<pre>\npre text\n\nmore\n</pre>\n', '<script>\nlet x = 1;\n\n</script>\n',
  '***\n', '---\n', '\\newpage\n', '[TOC]\n', 'Emoji :smile: and :+1: here.\n', '中文**「强调」**的段落。\n', 'Trailing spaces  \nhard break\n',
  'Line with\ttab\n', 'http://autolink.example.com and www.example.org\n', '"Smart" quotes -- and... (c)\n', '<span>inline html</span> text\n',
  '![image](img.png "t")\n', '[![img](a.png)](http://x)\n', 'Term\n: not a definition\n', '{.attrs}\n', '::: div\ncontent\n:::\n',
];
// Fragments typed into the middle of things.
const FRAGMENTS = ['```', '```\n', '~~~\n', '$$', '$$\n', '\\[', '\\]', '<!--', '-->', '---\n', '+++\n', '[^1]', '[^1]: x\n', '^[n]', '[ref]', '[ref]: /u\n', '# ', '- ', '1. ', '> ', '    ', '\t', '|', '*', '_', '`', '\n', '\n\n', ' ', '[TOC]', '- [ ] ', ':', '{', '\\', '<div>', '</div>', '[', ']', '(', ')', '!', 'x', 'é', '中', '😀'];

function generate(r, blocks) {
  const out = [];
  if (r.int(4) === 0) out.push(r.pick(['---\ntitle: Doc\ntags: [a, b]\n---\n', '+++\ntitle = "Doc"\n+++\n', '---\nunclosed: yes\n']));
  for (let i = 0; i < blocks; i++) out.push(r.pick(SNIPPETS));
  return out.join(r.pick(['\n', '\n', '\n\n'])) + (r.int(3) === 0 ? '' : '\n');
}

function edit(r, src) {
  const at = r.int(src.length + 1);
  const lineStart = src.lastIndexOf('\n', at - 1) + 1;
  switch (r.int(8)) {
    case 0: // type a fragment
    case 1:
      return src.slice(0, at) + r.pick(FRAGMENTS) + src.slice(at);
    case 2: { // delete a few characters
      const n = 1 + r.int(12);
      return src.slice(0, at) + src.slice(at + n);
    }
    case 3: // insert a block at a line start
      return src.slice(0, lineStart) + r.pick(SNIPPETS) + (r.int(2) ? '\n' : '') + src.slice(lineStart);
    case 4: { // delete a line
      const end = src.indexOf('\n', at);
      return src.slice(0, lineStart) + (end < 0 ? '' : src.slice(end + 1));
    }
    case 5: { // duplicate a line
      const end = src.indexOf('\n', at);
      const line = src.slice(lineStart, end < 0 ? src.length : end + 1);
      return src.slice(0, lineStart) + line + (line.endsWith('\n') ? '' : '\n') + src.slice(lineStart);
    }
    case 6: // indent or unindent a line
      return r.int(2) ? src.slice(0, lineStart) + r.pick(['  ', '    ', '\t']) + src.slice(lineStart) : src.slice(0, lineStart) + src.slice(lineStart).replace(/^[ \t]+/, '');
    default: { // move a span elsewhere
      const n = r.int(80);
      const span = src.slice(at, at + n);
      const rest = src.slice(0, at) + src.slice(at + n);
      const to = r.int(rest.length + 1);
      return rest.slice(0, to) + span + rest.slice(to);
    }
  }
}

function sequence(name, start, options, sections, seed, edits) {
  incremental.configure({ sections });
  const r = rng(seed);
  let src = start;
  const runs = { sections: 0, full: 0 };
  const tally = (run) => (run.mode === 'sections' ? runs.sections++ : runs.full++);
  tally(check(src, options, `${name} seed ${seed} initial`));
  for (let i = 0; i < edits; i++) {
    src = edit(r, src);
    if (src.length > 12000) src = src.slice(0, 8000); // keep the whole-document renders cheap
    if (process.env.MD2_DIFF_TRACE) writeFileSync(join(tmpdir(), 'md2-incremental-current.md'), src);
    tally(check(src, options, `${name} seed ${seed} edit ${i + 1}`));
  }
  return runs;
}

const total = { checks: 0, sections: 0, full: 0 };
const count = (runs) => {
  total.checks += runs.sections + runs.full;
  total.sections += runs.sections;
  total.full += runs.full;
};

test('corpus: every fixture, every option set, every section layout, then random edits', () => {
  let seed = SEED ?? 1;
  for (const [name, src] of corpus) {
    for (const [oname, options] of Object.entries(OPTION_SETS)) {
      for (const [sname, sections] of Object.entries(SECTIONS)) {
        incremental.configure({ sections });
        check(src, options, `${name} ${oname} ${sname}`);
        total.checks++;
      }
      count(sequence(`${name} ${oname}`, src, options, SECTIONS.every, seed++, Math.ceil(EDITS / 3)));
    }
  }
});

test('generated documents: long random edit sequences', () => {
  const seeds = SEED === null ? Array.from({ length: 12 }, (_, i) => 1000 + i) : [SEED];
  for (const seed of seeds) {
    const r = rng(seed);
    const doc = generate(r, 10 + r.int(40));
    for (const [oname, options] of Object.entries(OPTION_SETS)) {
      const layout = r.pick(Object.values(SECTIONS).slice(0, 2));
      count(sequence(`generated ${oname}`, doc, options, layout, seed * 7 + oname.length, EDITS));
    }
  }
  // most checks must really have gone through sections, or the test proves nothing
  assert.ok(total.sections > total.full, JSON.stringify(total));
});

// --- adversarial -------------------------------------------------------------------------------------------------------

const many = (n, f) => Array.from({ length: n }, (_, i) => f(i)).join('\n');
const filler = many(30, (i) => `# Section ${i % 7}\n\nParagraph ${i} with a [ref] link[^${i % 3}] and $x_${i}$.\n`);

// Each case: a starting text and edits applied one after another ([at, deleteCount, insert], `at` < 0 counts from the end).
const ADVERSARIAL = {
  'a fence opened at the top swallows every section, then closes': [filler, [[0, 0, '```\n'], [-1, 0, '\n```\n'], [0, 4, '']]],
  'a fence closer typed below an opener far above': [`\`\`\`\n${filler}`, [[-1, 0, '\n```\n'], [-5, 5, '']]],
  'unclosed $$ at the top': [filler, [[0, 0, '$$\n'], [3, 0, 'x\n$$\n']]],
  '\\[ whose \\] is far below': [`\\[\n${filler}`, [[-1, 0, '\n\\]\n'], [0, 2, '']]],
  'an HTML comment across many sections': [filler, [[0, 0, '<!--\n'], [-1, 0, '\n-->\n'], [0, 5, '']]],
  'front matter opened and closed': [filler, [[0, 0, '---\n'], [4, 0, 'title: x\n\n# yaml comment\n\n---\n'], [0, 4, '']]],
  'TOML front matter without its closing line, then with it': [filler, [[0, 0, '+++\ntitle = 1\n\n# t\n'], [-1, 0, '\n+++\n']]],
  'footnote definitions moved, references reordered': [filler + '\n[^0]: zero\n\n[^1]: one\n\n[^2]: two\n', [[0, 0, 'First [^2] then [^0].\n\n'], [-12, 12, ''], [0, 0, 'Again [^1][^1].\n\n'], [-1, 0, '\n[^2]: redefined\n']]],
  'a reference definition appears, changes and goes': [filler, [[0, 0, '[ref]: http://a\n\n'], [8, 1, 'b'], [0, 17, '']]],
  'duplicate headings renumbered by an insertion above': [filler, [[0, 0, '# Section 3\n\n'], [0, 0, '# Section 3\n\n'], [0, 13, '']]],
  'a [TOC] appears with anchors off': [filler, [[0, 0, '[TOC]\n\n'], [-1, 0, '\n# Late heading\n'], [0, 7, '']]],
  'tasks renumbered by a task inserted above': [`${filler}\n- [ ] a\n- [x] b\n`, [[0, 0, '- [ ] first\n\n'], [0, 13, '']]],
  'list continued across a blank line by an item at column 0': ['- a\n\nparagraph\n\n- b\n', [[5, 9, ''], [5, 0, 'x'], [0, 0, '\n']]],
  'indented code continued after a blank line': ['    code\n\nText\n\n    more\n', [[10, 5, ''], [10, 0, '    ']]],
  'lazy continuation into a quote': ['> quote\ntext\n\nnext\n', [[14, 0, '\n'], [8, 1, '']]],
  'a table caption-like line and attrs after a blank': ['| a |\n|---|\n| b |\n\n{.cls}\n\n: caption\n', [[0, 0, 'x\n\n']]],
  'blank lines that hold spaces and tabs': ['a\n \t\nb\n\t\n# c\n   \nd', [[2, 0, ' '], [0, 0, '# t\n\t\n']]],
  'no trailing newline, then one': ['# a\n\nb', [[-1, 0, '\n'], [-1, 0, 'c']]],
  'empty and whitespace-only documents': ['', [[0, 0, '\n'], [0, 0, '# x'], [0, 3, ''], [0, 0, '   \n\n']]],
  'math with global macros falls back': ['$$\\gdef\\foo{x}$$\n\n$$\\foo$$\n', [[0, 0, 'a\n\n'], [-1, 0, '\n\n$$\\foo+1$$\n']]],
  'CR and NUL fall back': ['a\r\n\r\nb\n', [[0, 0, '\0'], [0, 1, '']]],
  'inline footnote with a reference inside falls back': ['x^[see [^1]]\n\n[^1]: n\n', [[0, 0, 'y\n\n']]],
  'heading inside a footnote falls back': ['x[^1]\n\n[^1]:\n    # h\n', [[0, 0, '# t\n\n']]],
  'alert, page break and HTML block at section starts': [filler, [[0, 0, '> [!TIP]\n> tip\n\n\\newpage\n\n<div>\nraw\n</div>\n\n']]],
  'html block types 1-5 left open': [filler, [[0, 0, '<pre>\n'], [-1, 0, '\n</pre>\n'], [0, 0, '<script>\n'], [0, 0, '<?php\n'], [0, 0, '<![CDATA[\n']]],
  'setext underline after a cut': ['a\n\nb\n\nc\n', [[5, 0, '---\n'], [5, 0, '===\n']]],
  'footnote definition continued after a blank line': ['[^1]: a\n\n    b\n\nc[^1]\n', [[9, 4, ''], [9, 0, '\t']]],
};

test('adversarial edit sequences', () => {
  for (const [name, [start, edits]] of Object.entries(ADVERSARIAL)) {
    for (const [oname, options] of Object.entries(OPTION_SETS)) {
      for (const sections of [SECTIONS.every, SECTIONS.some]) {
        incremental.configure({ sections });
        let src = start;
        check(src, options, `${name} (${oname}) start`);
        edits.forEach(([at, del, ins], i) => {
          const p = at < 0 ? Math.max(0, src.length + at + 1) : Math.min(at, src.length);
          src = src.slice(0, p) + ins + src.slice(p + del);
          check(src, options, `${name} (${oname}) edit ${i + 1}`);
          total.checks++;
        });
      }
    }
  }
});

test('a large document: typing in the middle re-renders one section', () => {
  incremental.configure({ sections: SECTIONS.shipped });
  const r = rng(7);
  const doc = generate(r, 1500);
  const options = OPTION_SETS.app;
  check(doc, options, 'large initial');
  const mid = doc.indexOf("\n\nA paragraph", doc.length >> 1) + 2 + 40; // past the characters a cut decision hashes
  let src = doc;
  for (let i = 0; i < 20; i++) {
    src = src.slice(0, mid + i) + 'z' + src.slice(mid + i);
    const run = check(src, options, `large edit ${i + 1}`);
    assert.equal(run.mode, 'sections');
    assert.equal(run.rendered, 1, JSON.stringify(run));
    assert.ok(run.parsed < 20000, JSON.stringify(run));
  }
  // new lines move every later section's line numbers (and, past 999 -> 1000 and the like, their HTML's length)
  for (let i = 0; i < 8; i++) {
    src = src.slice(0, mid) + 'z\n'.repeat(i % 2 ? 1 : 300) + src.slice(mid);
    const run = check(src, options, `large newline ${i + 1}`);
    assert.equal(run.mode, 'sections');
  }
});

test('flavors other than Markdown and sanitized output render whole, with the same result', () => {
  const qdir = join(here, 'fixtures/quarto');
  for (const f of readdirSync(qdir).filter((n) => n.endsWith('.qmd'))) {
    const src = readFileSync(join(qdir, f), 'utf8');
    const options = quartoOptions({ codeLineNumbers: true, frontMatterDisplay: 'table' });
    assert.equal(JSON.stringify(renderIncremental(src, options)), JSON.stringify(renderResult(src, options)), f);
    assert.equal(incremental.lastRun().mode, 'full');
  }
});

test('the debug cross-check compares with a whole render and stays quiet when they agree', () => {
  const messages = [];
  incremental.configure({ crossCheckEvery: 1, onMismatch: (m) => messages.push(m), sections: SECTIONS.every });
  let src = filler;
  for (let i = 0; i < 10; i++) {
    src = src.replace(`Paragraph ${i}`, `Paragraph ${i} edited`);
    check(src, OPTION_SETS.app, `cross-check ${i}`);
  }
  incremental.configure({ crossCheckEvery: 0 });
  assert.deepEqual(messages, []);
});

test('the debug cross-check reports a difference and returns the whole render', () => {
  // A renderer rule that counts its calls makes every render differ from every other one: the section renderer's output
  // cannot match a whole render's, which is what the check is there to catch.
  let n = 0;
  flavors.register('markdown', (md) => {
    md.renderer.rules.paragraph_open = () => `<p data-n="${n++}">`;
  });
  try {
    const messages = [];
    incremental.configure({ crossCheckEvery: 1, onMismatch: (m) => messages.push(m), sections: SECTIONS.every });
    const result = renderIncremental('one\n\ntwo\n', OPTION_SETS.app);
    assert.equal(messages.length, 1);
    assert.match(messages[0], /incremental render differs from a whole render/);
    assert.equal(result.segments, undefined); // the whole render's result
  } finally {
    incremental.configure({ crossCheckEvery: 0 });
    flavors.register('markdown', () => {});
  }
  check('one\n\ntwo\n', OPTION_SETS.app, 'after restoring the flavor');
});

test('cuts land only before column-0 lines that follow a blank line, outside fences', () => {
  incremental.configure({ sections: SECTIONS.every });
  const src = 'a\n\nb\n\n  c\n\n- d\n\n```\n\ne\n\n```\n\nf\n\n1. g\n\n:h\n\n{i}\n\nj';
  const lines = (cuts) => cuts.map((c) => src.slice(c, src.indexOf('\n', c) < 0 ? undefined : src.indexOf('\n', c)));
  assert.deepEqual(lines(scanCuts(src, true)), ['b', '```', 'f', 'j']);
  incremental.configure({ sections: SECTIONS.shipped });
});

test('LRU evicts the least recently used entries past its weight budget', () => {
  const lru = new LRU(10);
  lru.set('a', 1, 4);
  lru.set('b', 2, 4);
  assert.equal(lru.get('a'), 1); // a is now the most recent
  lru.set('c', 3, 4); // 12 > 10: b goes
  assert.equal(lru.get('b'), undefined);
  assert.equal(lru.get('a'), 1);
  assert.equal(lru.get('c'), 3);
  lru.set('huge', 4, 11); // never kept
  assert.equal(lru.get('huge'), undefined);
  assert.ok(lru.weight <= 10);
});

test(`totals (${EDITS} edits per sequence)`, () => {
  console.log(`incremental differential: ${total.checks} comparisons, ${total.sections} through sections, ${total.full} whole`);
  assert.ok(total.checks > 1000);
});
