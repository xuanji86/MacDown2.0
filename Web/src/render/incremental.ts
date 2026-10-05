// Section-incremental rendering for the live preview (`renderIncremental`). The result is byte for byte what `renderResult`
// (core.ts) returns for the same text; a keystroke re-renders the section of the document it falls in, not all of it.
//
// Sections. The text is cut before line L when line L-1 is blank and line L starts in column 0 with a character that cannot
// continue anything above it (not a space, tab, list marker `- + *` or digit, `:` or `{`), outside what the scanner sees as a
// fenced code block, `$$` formula (math on), HTML comment or `<pre>`/`<script>`/`<style>`/`<textarea>` block (raw HTML on) or
// front matter. At such a line markdown-it's root loop is between two blocks: every block above ended at the blank line, or
// (lists, footnote definitions) ends because line L is not indented and not a list item; nothing below depends on lines
// above (rules do not look back), except through `env`. The scanner is only a heuristic: each cut is *verified* by the parse
// of the section above it (a section is parsed as a document of its own):
//   - a block that ran into the end of the section (an unclosed fence, `$$` formula, HTML block of type 1-5, front matter;
//     anything but a list or a footnote definition) would have gone on in the whole document;
//   - a rule that looks ahead for a closing line and failed (`\[ ... \]`, TOML front matter) might have found it below;
//   - the section ends in a hidden closing token: the renderer would put a newline before the next block;
//   - the parse left the block state changed (a plugin bug: then the rest of the document is one section).
// A section that fails is merged with the next ones (1, 2, 4, ... at a time) until one passes; the last one needs no check.
// Cuts are chosen content-defined (at headings, or where a hash of the line's start says so, at least SECTION.min apart), so
// an edit moves only the cuts next to it.
//
// What crosses sections, collected after every section's block phase and applied to the inline phase (a change re-renders
// every section): reference definitions (first one wins), footnote labels. What only the whole document decides is left as a
// hole in each section's HTML and filled when the sections are put together: `data-line` values (relative to the section),
// heading ids (deduplicated over the document; absent unless anchors or a [TOC]), task checkbox ids (numbered over the
// document), footnote references (numbered in order of first reference), the [TOC] list. The footnote section is rebuilt from
// the sections' definitions as the footnote plugin builds it (its line numbers are holes too).
//
// Rendered whole instead (`renderResult`): flavors other than plain Markdown (Quarto's plugins carry state across blocks:
// divs, attributes, captions, includes), CR or NUL in the text, TeX that defines global macros (they reach later formulas),
// headings / tasks / [TOC] inside footnote definitions, footnote references inside inline footnotes, sanitized output, any
// rule this file does not know; and, because it would be slower than one whole render: a text with a single section, an edit
// that leaves most of the text to parse again, or more re-parsing than the text is long (then the next renders are whole
// too, for a while: backing off).
import type { MarkdownIt, RendererRule, StateBlock, StateCore, Token } from 'markdown-it';
import { alignSegments, hashRange, splitBlocks, type Segment } from '../preview/split-html.ts';
import {
  blocksOf,
  build,
  collectText,
  definesTeXMacros,
  onFlavorRegistered,
  optionsKey,
  plainText,
  renderResult,
  tasksOf,
  type AnnotateHooks,
  type BlockMap,
  type OutlineItem,
  type RenderOptions,
  type RenderResult,
  type TaskItem,
} from './core.ts';
import { tocList } from './plugins/toc.ts';
import { LRU, ownCopy } from './lru.ts';
import { dedupeSlug, slugBase, textStats, type TextStats } from './text.ts';

export type IncrementalResult = RenderResult & { segments?: Segment[] | null };

// lazy: only plain Markdown; upgrade = a flavor declares which of its rules are section-safe (Quarto would need its div
// depth, attribute and caption rules checked at cuts, and its include files in the context key).
const FLAVORS = new Set(['markdown']);
// Rules this file has been checked against (see the header); any other one makes the options render whole.
const KNOWN_BLOCK = new Set([
  'table', 'code', 'fence', 'blockquote', 'hr', 'list', 'reference', 'html_block', 'heading', 'lheading', 'paragraph',
  'front_matter', 'front_matter_toml', 'alert', 'math_block_bracket', 'math_block_dollar', 'footnoteDef', 'macdown2_page_break',
]);
const KNOWN_CORE = new Set([
  'normalize', 'block', 'strip_references', 'inline', 'linkify', 'replacements', 'smartquotes', 'text_join', 'emoji',
  'macdown2_toc', 'macdown2_underline', 'task_list', 'footnoteTail', 'macdown2_annotate',
]);
const KNOWN_INLINE = new Set([
  'text', 'linkify', 'newline', 'escape', 'backticks', 'strikethrough', 'emphasis', 'link', 'image', 'autolink', 'html_inline',
  'entity', 'balance_pairs', 'fragments_join', 'math_inline_bracket', 'math_inline_dollar', 'mark_=', 'sub_~', 'sup_^',
  'footnoteInline', 'footnote_ref',
]);
// Blocks that may end exactly at the end of a section: they stop there because the next section's first line is neither
// indented nor a list item, which is also what ends them in the whole document.
const ENDS_AT_CUT = new Set(['list', 'footnoteDef']);
const FRONT_MATTER = new Set(['front_matter', 'front_matter_toml']);
// Rules that fail (rather than run to the end) when their closing line is missing: did this one start here?
const LOOKAHEAD: Record<string, (state: StateBlock, line: number) => boolean> = {
  math_block_bracket: (s, line) => {
    const p = s.bMarks[line] + s.tShift[line];
    return s.src.charCodeAt(p) === 0x5c && s.src.charCodeAt(p + 1) === 0x5b; // \[
  },
  front_matter_toml: (s, line) => line === 0 && s.tShift[0] === 0 && s.src.slice(0, s.eMarks[0]).trimEnd() === '+++',
};

// lazy: section sizes are fixed heuristics (a 1-16 KB section re-parses in well under a millisecond); upgrade = tune per
// document size if typing in very large sections shows up. Tests change them, and turn `adaptive` off so every text goes
// through the sections (no falling back to a whole render for speed, no backing off).
const SECTION = { min: 1024, max: 16 * 1024, everyCandidate: false, adaptive: true };
// lazy: characters of source + HTML (and a share for objects) kept per option set, room for a few versions of the document
// (an entry weighs about 5x its text), 16M-64M; upgrade = measure the page's memory instead if large documents need more.
const cacheBudget = (chars: number): number => Math.min(64, Math.max(16, Math.ceil((chars * 16) / 2 ** 20))) * 2 ** 20;
const GROUP = 'md2_footnote_group';

type Reference = { title: string; href: string };
interface Heading { level: number; text: string; base: string | null; explicit: string | null; line: number }
interface GroupMeta {
  id: number; // identity, for the footnote section's cache
  kind: 'def' | 'inline';
  label?: string;
  tokens: Token[];
  lines: Token[]; // tokens that get data-line attributes once the footnote section is put together
  refs: Array<{ token: Token; id: number; subId: number }>;
  stats: TextStats;
}
type LocalFootnote = { label: string; count: number } | { inline: GroupMeta };
interface Sec {
  first: boolean;
  touchedEnd: boolean;
  leaks: boolean;
  unsupported: string | null;
  headings: Heading[];
  footnotes: LocalFootnote[];
  groups: GroupMeta[];
}
type SectionEnv = {
  outline: OutlineItem[];
  references?: Record<string, Reference>;
  footnotes?: { refs?: Record<string, number>; list?: Array<{ label?: string; count?: number; content?: string; tokens?: Token[] }> };
  hasToc?: boolean;
  md2: Sec;
};

// What a section's text renders to, apart from the holes.
interface Rendered {
  parts: string[]; // HTML around the holes: parts[0] hole0 parts[1] hole1 ... parts[n]
  holes: number[]; // pairs [kind char code, number]
  blocks: BlockMap[]; // lines relative to the section
  tasks: TaskItem[];
  headings: Heading[];
  hasToc: boolean;
  taskCount: number;
  refs: number[]; // footnote references in the HTML: pairs [local id, local sub id (-1: inline footnote)]
  footnotes: LocalFootnote[];
  groups: GroupMeta[];
  stats: TextStats;
  frontMatter?: string;
  unsupported: string | null;
  tocHole: boolean;
  fill?: { line: number; rest: string; html: string; segs: Segment[] | null };
  placedAt?: { line: number; blocks: BlockMap[]; tasks: TaskItem[] }; // blocks and tasks with document lines, last time
}
interface Entry {
  text: string;
  first: boolean;
  newlines: number;
  clean: boolean;
  leaks: boolean; // the parse left state behind that reaches every later line: the rest of the document is one section
  unsupported: string | null; // seen already in the block phase: render whole
  refs: Array<[string, Reference]>;
  labels: string[];
  ctx: string | null;
  r: Rendered | null;
}
// The footnote section as last built: HTML around holes for its line numbers (D: an index into `lines`).
interface Tail {
  sig: string; // what it shows, apart from line numbers
  parts: string[];
  holes: number[];
  lines: number[]; // pairs [line relative to its section, footnote index]
  stats: TextStats;
  balanced?: boolean; // whether its HTML cuts into blocks at all (split-html.ts splitBlocks)
  // filled with the current line numbers; `hash`: the footnote section's segment hash (split-html.ts alignSegments), null when
  // the section's HTML does not cut cleanly (the page then cuts the whole HTML itself)
  fill: { key: string; html: string; hash: number | null } | null;
}
interface Mode {
  md: MarkdownIt;
  ok: boolean;
  phaseA: Array<(state: StateCore) => void>;
  phaseB: Array<(state: StateCore) => void>;
  cache: LRU<Entry>;
  footnoteRef?: RendererRule;
  TokenClass: typeof Token;
  options: RenderOptions;
  tocVersion: number;
  toc: string;
  tail: Tail | null;
  context: { carriers: Entry[]; ctx: Context } | null;
  skip: number; // whole renders still to do before trying sections again
  backoff: number;
}
interface Placed { entry: Entry; line: number; state: StateCore | null }

// The first section (the only one whose first line can open front matter) is cached apart: NUL never occurs in a text that
// gets here, so no other section's text can look like its key.
const keyOf = (text: string, first: boolean): string => (first ? `\0${text}` : text);
// The cache budget counts characters; an entry also holds objects (tokens, metadata), counted at a rough per-item rate.
function weightOf(e: Entry): number {
  let w = 256 + e.text.length;
  const r = e.r;
  if (r) {
    for (const p of r.parts) w += 2 * p.length; // the parts and the filled copy
    w += 48 * (r.blocks.length + r.tasks.length + r.headings.length + r.holes.length);
    for (const g of r.groups) w += 128 * g.tokens.length;
  }
  return w;
}

let groupIds = 0;

// A hole: NUL, a random word drawn when the bundle loads, the kind, a number, NUL. The renderer can emit NUL itself (KaTeX's
// `\char0`, front matter values with `\0` escapes), so a NUL alone proves nothing; the document cannot know the word, so it
// cannot forge a hole, and cutHoles refuses HTML with any NUL that is not one of ours.
const NONCE = Array.from({ length: 12 }, () => String.fromCharCode(97 + Math.floor(Math.random() * 26))).join('');
const hole = (kind: string, n: number | string): string => `\0${NONCE}${kind}${n}\0`;
const KINDS = 'LHKFTD';

const L = 76; // 'L' data-line value
const H = 72; // 'H' heading id attribute
const K = 75; // 'K' task checkbox id
const F = 70; // 'F' footnote reference
const T = 84; // 'T' [TOC] list
const D = 68; // 'D' data-line value in the footnote section
const TOO_MUCH = 'more re-parsing than the text is long';
// Decided before any work, so no reason to back off.
const CHEAP_SINGLE = 'a single section';
const CHEAP_HUGE = 'an edit inside a section that is most of the text';
// lazy: back off for 8, 16, ... 64 renders after sectioned work that ended in a whole render (the same text shape fails
// again on the next keystroke); upgrade = remember which shape failed and retry when it changes.
const BACKOFF_FIRST = 8;
const BACKOFF_MAX = 64;

// lazy: two option sets (the settings in use and the previous ones); upgrade = more if switching between several shows up.
const MODES = 2;
const modes = new Map<string, Mode>();
let crossCheckEvery = 0;
let crossCheckCount = 0;
let onMismatch: ((message: string) => void) | undefined;
// What the current call did: characters parsed in sections, sections (re-)rendered, merges; reported by lastRun() also when
// the call ended in a whole render (that work was then wasted).
let work = { sections: 0, parsed: 0, rendered: 0, merges: 0 };
let last = { mode: 'none' as 'none' | 'full' | 'sections', reason: '', ...work };

onFlavorRegistered((id) => {
  for (const key of modes.keys()) if (key.startsWith(`${id}|`)) modes.delete(key);
});

// annotate (core.ts) for a section: placeholders for line numbers and heading ids; footnote groups are left for later.
function sectionAnnotation(state: StateCore): AnnotateHooks {
  const sec = (state.env as Partial<SectionEnv>).md2;
  if (!sec) return { lines: () => null, heading: () => null }; // KaTeX's macro reset renders an empty text
  let group: GroupMeta | null = null;
  return {
    enter(t) {
      if (t.type !== GROUP) return true;
      group = t.meta as unknown as GroupMeta;
      return false;
    },
    lines(t, start, end) {
      if (!group) return [hole('L', start), hole('L', end)];
      group.lines.push(t);
      return null;
    },
    heading(t, text, explicit) {
      if (group) {
        sec.unsupported = 'heading in a footnote';
        return null;
      }
      sec.headings.push({ level: Number(t.tag.slice(1)), text, base: explicit === null ? slugBase(text) : null, explicit, line: t.map ? t.map[0] : -1 });
      return explicit === null ? hole('H', sec.headings.length - 1) : null;
    },
  };
}

// The footnote plugin's tail rule, per section: definitions leave the body (as the plugin does), and go with the
// section's inline footnotes behind GROUP markers at the end of the stream, so the core rules after this one treat them
// as they treat the plugin's footnote section. Numbering and the section itself wait for the whole document.
// lazy: this mirrors @mdit/plugin-footnote 1.1.2's tail rule (pinned in package.json; incremental.test.mjs checks the version
// and runs footnote-dense documents through both renderers); upgrade = re-check this and assemble() on every plugin update.
function sectionFootnoteTail(state: StateCore): void {
  const env = state.env as SectionEnv;
  const sec = env.md2;
  if (!sec) return; // KaTeX's macro reset renders an empty text
  const body: Token[] = [];
  const groups: GroupMeta[] = [];
  const group = (kind: GroupMeta['kind'], tokens: Token[], label?: string): GroupMeta => ({ id: ++groupIds, kind, label, tokens, lines: [], refs: [], stats: textStats('') });
  let def: GroupMeta | null = null;
  for (const t of state.tokens) {
    if (t.type === 'footnote_reference_open') {
      if (def) sec.unsupported = 'footnote definition inside a footnote definition';
      def = group('def', [], (t.meta as { label: string }).label);
    } else if (t.type === 'footnote_reference_close') {
      if (def) groups.push(def);
      def = null;
    } else if (def) def.tokens.push(t);
    else body.push(t);
  }
  sec.footnotes = (env.footnotes?.list ?? []).map((e) => {
    if (!e.tokens) return { label: e.label!, count: e.count ?? 0 };
    const open = new state.Token('paragraph_open', 'p', 1);
    open.block = true;
    const inline = new state.Token('inline', '', 0);
    inline.children = e.tokens;
    inline.content = e.content ?? '';
    const close = new state.Token('paragraph_close', 'p', -1);
    close.block = true;
    const g = group('inline', [open, inline, close]);
    groups.push(g);
    return { inline: g };
  });
  for (const g of groups) {
    const mark = new state.Token(GROUP, '', 0);
    mark.meta = g as unknown as Record<string, unknown>;
    body.push(mark, ...g.tokens);
  }
  sec.groups = groups;
  state.tokens = body;
}

function makeMode(o: RenderOptions): Mode {
  const md = build(o, sectionAnnotation);
  let ok = FLAVORS.has(o.flavor);
  for (const r of md.block.ruler.__rules__) {
    if (!KNOWN_BLOCK.has(r.name)) ok = false;
    const fn = r.fn;
    const name = r.name;
    const lookahead = LOOKAHEAD[name];
    const frontMatter = FRONT_MATTER.has(name);
    md.block.ruler.at(
      name,
      (state, start, end, silent) => {
        const sec = (state.env as Partial<SectionEnv>).md2;
        if (!sec) return fn(state, start, end, silent);
        if (frontMatter && !sec.first) return false; // only the document's own first line can open front matter
        if (silent || state.parentType !== 'root' || state.level !== 0) return fn(state, start, end, silent);
        const matched = fn(state, start, end, silent);
        if (matched ? state.line >= end && !ENDS_AT_CUT.has(name) : lookahead?.(state, start)) sec.touchedEnd = true;
        return matched;
      },
      { alt: r.alt },
    );
  }
  for (const r of [...md.inline.ruler.__rules__, ...md.inline.ruler2.__rules__]) if (!KNOWN_INLINE.has(r.name)) ok = false;
  for (const r of md.core.ruler.__rules__) if (!KNOWN_CORE.has(r.name)) ok = false;
  if (md.core.ruler.__rules__.some((r) => r.name === 'footnoteTail')) md.core.ruler.at('footnoteTail', sectionFootnoteTail);
  // markdown-it's own block rule (core `block` + ParserBlock.parse), keeping hold of the block state to look at it after the
  // parse: a rule that leaves it changed changes how everything after it parses, in the whole document as well (as
  // @mdit/plugin-alert did, see core.ts).
  const block = md.core.ruler.__rules__.find((r) => r.name === 'block')?.fn;
  if (block) {
    md.core.ruler.at('block', (state) => {
      const sec = (state.env as Partial<SectionEnv>).md2;
      if (!sec || state.inlineMode) return block(state);
      if (!state.src) return;
      const bs = new md.block.State(state.src, md, state.env, state.tokens);
      const lines = bs.lineMax;
      md.block.tokenize(bs, bs.line, bs.lineMax);
      if (bs.lineMax !== lines || bs.parentType !== 'root' || bs.blkIndent !== 0 || bs.level !== 0) sec.leaks = true;
    });
  } else ok = false;
  const footnoteRef = md.renderer.rules.footnote_ref;
  if (footnoteRef) {
    md.renderer.rules.footnote_ref = (tokens, idx, opts, env, slf) => {
      const n = (tokens[idx].meta as { md2Hole?: number } | null)?.md2Hole;
      return n === undefined ? footnoteRef(tokens, idx, opts, env, slf) : hole('F', n);
    };
  }
  if (md.renderer.rules.toc) md.renderer.rules.toc = (tokens, idx, _o, _env, slf) => `<nav class="toc"${slf.renderAttrs(tokens[idx])}>${hole('T', 0)}</nav>\n`;
  const enabled = md.core.ruler.__rules__.filter((r) => r.enabled).map((r) => r.name);
  const fns = md.core.ruler.getRules('');
  const split = Math.max(enabled.indexOf('block'), enabled.indexOf('strip_references')) + 1;
  if (split === 0) ok = false;
  return {
    md,
    ok,
    phaseA: fns.slice(0, split),
    phaseB: fns.slice(split),
    cache: new LRU<Entry>(cacheBudget(0)),
    footnoteRef,
    TokenClass: new md.core.State('', md, {}).Token,
    options: o,
    tocVersion: 0,
    toc: '',
    tail: null,
    context: null,
    skip: 0,
    backoff: 0,
  };
}

function modeFor(o: RenderOptions): Mode {
  const key = optionsKey(o);
  let mode = modes.get(key);
  if (mode) modes.delete(key); // re-inserted below: the Map's order is least recently used first
  else {
    mode = makeMode(o);
    if (modes.size >= MODES) modes.delete(modes.keys().next().value!);
  }
  modes.set(key, mode);
  return mode;
}

// HTML with holes -> the text around them and the holes ([kind, number] pairs). A heading id hole stands for the whole
// ` id="…"` attribute. null: a NUL that is not one of our holes (the document's own, e.g. KaTeX's `\char0`), or a hole
// that is not where it should be: that render is a whole one.
function cutHoles(html: string): { parts: string[]; holes: number[] } | null {
  const parts: string[] = [];
  const holes: number[] = [];
  for (let i = 0; ; ) {
    const a = html.indexOf('\0', i);
    if (a < 0) {
      parts.push(html.slice(i));
      return { parts, holes };
    }
    const k = a + 1 + NONCE.length;
    if (!html.startsWith(NONCE, a + 1) || !KINDS.includes(html[k] ?? '\0')) return null;
    let b = k + 1;
    while (b < html.length && html.charCodeAt(b) >= 48 && html.charCodeAt(b) <= 57) b++;
    if (b === k + 1 || html.charCodeAt(b) !== 0) return null;
    const kind = html.charCodeAt(k);
    let before = html.slice(i, a);
    let next = b + 1;
    if (kind === H) {
      if (!before.endsWith(' id="') || html.charCodeAt(next) !== 34) return null;
      before = before.slice(0, -5);
      next++;
    }
    parts.push(before);
    holes.push(kind, Number(html.slice(k + 1, b)));
    i = next;
  }
}

// parts[0] hole parts[1] hole ... with each hole's text from `value(kind, number)`.
function fillHoles(parts: string[], holes: number[], value: (kind: number, n: number) => string): string {
  let html = parts[0];
  for (let k = 0; k < holes.length; k += 2) html += value(holes[k], holes[k + 1]) + parts[k / 2 + 1];
  return html;
}

function addStats(to: TextStats, from: TextStats): void {
  to.words += from.words;
  to.characters += from.characters;
  to.charactersNoSpaces += from.charactersNoSpaces;
}

// --- block phase ----------------------------------------------------------------------------------------------------

function parseA(mode: Mode, text: string, first: boolean): { entry: Entry; state: StateCore } {
  const sec: Sec = { first, touchedEnd: false, leaks: false, unsupported: null, headings: [], footnotes: [], groups: [] };
  const env: SectionEnv = { outline: [], md2: sec };
  const state = new mode.md.core.State(text, mode.md, env);
  for (const rule of mode.phaseA) rule(state);
  // The token the next section's first block follows in the whole document: the last one that is not part of a footnote
  // definition (those move to the footnote section) and not a hidden leaf (the renderer looks past those). A hidden closing
  // token there would make the renderer start the next block with "\n" (markdown-it's renderToken).
  let hidden = false;
  let depth = 0;
  for (let i = state.tokens.length - 1; i >= 0; i--) {
    const t = state.tokens[i];
    if (t.type === 'footnote_reference_close') depth++;
    else if (t.type === 'footnote_reference_open') depth--;
    else if (depth === 0 && !(t.hidden && t.nesting === 0)) {
      hidden = t.hidden && t.nesting === -1;
      break;
    }
  }
  let newlines = 0;
  for (let p = text.indexOf('\n'); p >= 0; p = text.indexOf('\n', p + 1)) newlines++;
  const entry: Entry = {
    text,
    first,
    newlines,
    clean: !sec.touchedEnd && !hidden && !sec.leaks,
    leaks: sec.leaks,
    unsupported: unsupportedFootnote(state.tokens),
    refs: env.references ? Object.entries(env.references) : [],
    labels: env.footnotes?.refs ? Object.keys(env.footnotes.refs) : [],
    ctx: null,
    r: null,
  };
  return { entry, state };
}

// What the footnote section cannot hold here (sectionFootnoteTail / assemble), as far as the block phase shows it: a
// definition inside a definition, or a heading, a task-like item or a [TOC] in one. The inline phase checks the rest.
function unsupportedFootnote(tokens: Token[]): string | null {
  let depth = 0;
  for (let i = 0; i < tokens.length; i++) {
    const t = tokens[i];
    if (t.type === 'footnote_reference_open') {
      if (depth++) return 'footnote definition inside a footnote definition';
    } else if (t.type === 'footnote_reference_close') depth--;
    else if (depth) {
      if (t.type === 'heading_open') return 'heading in a footnote';
      if (t.type === 'inline' && /^\[[ xX]\][ \u00a0]/.test(t.content) && tokens[i - 2]?.type === 'list_item_open') return 'task in a footnote';
      if (t.type === 'inline' && /^\[toc\]$/i.test(t.content.trim())) return '[TOC] in a footnote';
    }
  }
  return null;
}

// The entry for a section's text: `hit` from the cache lookup already made for it, else parsed now (and cached).
function entryFor(mode: Mode, text: string, first: boolean, hit: Entry | undefined): { entry: Entry; state: StateCore | null } {
  if (hit) return { entry: hit, state: null };
  work.parsed += text.length;
  // A slice of the document keeps the whole document alive in both engines: the cache gets its own copy.
  const { entry, state } = parseA(mode, ownCopy(text), first);
  mode.cache.set(keyOf(entry.text, first), entry, weightOf(entry));
  return { entry, state };
}

// --- inline phase and HTML ------------------------------------------------------------------------------------------

function renderSection(mode: Mode, placed: Placed, ctx: Context): Rendered {
  const { entry } = placed;
  const state = placed.state ?? parseA(mode, entry.text, entry.first).state;
  placed.state = null; // the phase below consumes it
  const env = state.env as SectionEnv;
  env.references = ctx.references;
  // every label defined anywhere, -1 until referenced; the plugin writes its numbers into the section's own object
  env.footnotes = ctx.labels ? { refs: Object.create(ctx.labels) as Record<string, number> } : undefined;
  for (const rule of mode.phaseB) rule(state);
  const sec = env.md2;
  const tokens = state.tokens;
  let m = tokens.findIndex((t) => t.type === GROUP);
  if (m < 0) m = tokens.length;
  const body = tokens.slice(0, m);
  // the core rules after the tail may have replaced tokens: take each group's tokens from the stream again
  let current: GroupMeta | null = null;
  for (let i = m; i < tokens.length; i++) {
    const t = tokens[i];
    if (t.type === GROUP) {
      current = t.meta as unknown as GroupMeta;
      current.tokens = [];
    } else current!.tokens.push(t);
  }
  for (const g of sec.groups) {
    for (const t of g.tokens) {
      if (t.type === 'toc') sec.unsupported = '[TOC] in a footnote';
      for (const c of t.children ?? []) {
        if (c.type === 'checkbox_input') sec.unsupported = 'task in a footnote';
        if (c.type === 'footnote_ref') {
          if (g.kind === 'inline') sec.unsupported = 'footnote reference in an inline footnote';
          const meta = c.meta as { id: number; subId?: number };
          g.refs.push({ token: c, id: meta.id, subId: meta.subId ?? -1 });
        }
      }
    }
    g.stats = textStats(collectText(g.tokens));
  }
  const refs: number[] = [];
  let taskCount = 0;
  for (const t of body) {
    for (const c of t.children ?? []) {
      if (c.type === 'footnote_ref') {
        const meta = c.meta as { id: number; subId?: number; md2Hole?: number };
        meta.md2Hole = refs.length / 2;
        refs.push(meta.id, meta.subId ?? -1);
      } else if (c.type === 'checkbox_input' || c.type === 'label_open') {
        const name = c.type === 'checkbox_input' ? 'id' : 'for';
        const n = /^task-item-(\d+)$/.exec(String(c.attrGet(name) ?? ''));
        if (!n) continue;
        c.attrSet(name, hole('K', n[1]));
        if (c.type === 'checkbox_input') taskCount++;
      }
    }
  }
  const cut = cutHoles(mode.md.renderer.render(body, mode.md.options, env));
  const lines = entry.text.split('\n');
  const fm = body.find((t) => t.type === 'front_matter');
  const r: Rendered = {
    parts: cut?.parts ?? [''],
    holes: cut?.holes ?? [],
    blocks: blocksOf(body, lines),
    tasks: tasksOf(body, lines),
    headings: sec.headings,
    hasToc: env.hasToc === true,
    taskCount,
    refs,
    footnotes: sec.footnotes,
    groups: sec.groups,
    stats: textStats(collectText(body)),
    unsupported: cut ? sec.unsupported : 'a NUL in the HTML that is not one of the holes',
    tocHole: cut ? cut.holes.some((h, k) => k % 2 === 0 && h === T) : false,
  };
  if (fm) r.frontMatter = fm.meta as unknown as string;
  return r;
}

interface Context { key: string; references?: Record<string, Reference>; labels?: Record<string, number> }

function contextOf(mode: Mode, placed: Placed[]): Context {
  // The same entries carrying definitions as last time: the same context (entries are immutable once parsed).
  const carriers = placed.filter((p) => p.entry.refs.length || p.entry.labels.length).map((p) => p.entry);
  const prev = mode.context;
  if (prev && prev.carriers.length === carriers.length && prev.carriers.every((e, i) => e === carriers[i])) return prev.ctx;
  let references: Record<string, Reference> | undefined;
  let labels: Record<string, number> | undefined;
  for (const { entry } of placed) {
    for (const [label, value] of entry.refs) {
      references ??= {};
      if (references[label] === undefined) references[label] = value; // the first definition wins
    }
    for (const label of entry.labels) (labels ??= {})[label] = -1;
  }
  const key = JSON.stringify([
    references ? Object.entries(references).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)) : null,
    labels ? Object.keys(labels).sort() : null,
  ]);
  const ctx = { key, references, labels };
  mode.context = { carriers, ctx };
  return ctx;
}

// --- the document -----------------------------------------------------------------------------------------------------

function renderSections(mode: Mode, source: string): IncrementalResult | string {
  const o = mode.options;
  mode.cache.resize(cacheBudget(source.length));
  const cuts = scanCuts(source, { frontMatter: o.extensions.includes('frontMatter'), math: o.extensions.includes('math'), html: o.allowRawHTML });
  const starts = [0, ...cuts];
  const end = (i: number): number => (i < starts.length ? starts[i] : source.length);
  const texts = starts.map((a, i) => source.slice(a, end(i + 1)));
  // One cache lookup per section, made here (the merges below look up their own, longer texts).
  const hits = texts.map((text, i) => mode.cache.get(keyOf(text, i === 0)));
  if (SECTION.adaptive) {
    // Nothing to gain over one whole render: a single section (no blank line before a column-0 line: a long list, a table),
    // or an edit inside a section that is most of the text. A cold cache (nothing hits) is filled once regardless (the next
    // edit may well be elsewhere), and so are many new sections at once (a paste): only the next render pays for them.
    // lazy: 0.75 of the text is a guess at where re-parsing one section stops paying off against the assembly's overhead;
    // upgrade = measure the overhead per document and decide on that.
    if (starts.length === 1) return CHEAP_SINGLE;
    let largestMiss = 0;
    for (let i = 0; i < texts.length; i++) if (!hits[i]) largestMiss = Math.max(largestMiss, texts[i].length);
    if (hits.some(Boolean) && largestMiss > 0.75 * source.length) return CHEAP_HUGE;
  }
  // lazy: re-parsing more than the text is long (merges re-parse from the same start) costs more than one whole render;
  // upgrade = merge without re-parsing what was parsed already (keep the longer parse's tokens and verify cuts inside it).
  const budget = SECTION.adaptive ? source.length + 2048 : Infinity;
  const placed: Placed[] = [];
  let line = 0;
  for (let i = 0; i < starts.length; ) {
    let j = i + 1;
    let span = 1;
    let got = entryFor(mode, texts[i], i === 0, hits[i]);
    while (!got.entry.clean && j < starts.length) {
      j = got.entry.leaks ? starts.length : Math.min(starts.length, j + span);
      span *= 2;
      work.merges++;
      if (work.parsed > budget) return TOO_MUCH;
      const text = source.slice(starts[i], end(j));
      got = entryFor(mode, text, i === 0, mode.cache.get(keyOf(text, i === 0)));
    }
    if (work.parsed > budget) return TOO_MUCH;
    if (got.entry.unsupported) return got.entry.unsupported; // before rendering anything
    placed.push({ entry: got.entry, line, state: got.state });
    line += got.entry.newlines;
    i = j;
  }
  work.sections = placed.length;

  const ctx = contextOf(mode, placed);
  for (const p of placed) {
    const e = p.entry;
    if (!e.r || e.ctx !== ctx.key) {
      e.r = renderSection(mode, p, ctx);
      e.ctx = ctx.key;
      work.rendered++;
      mode.cache.set(keyOf(e.text, e.first), e, weightOf(e));
    }
    if (e.r.unsupported) return e.r.unsupported;
  }
  return assemble(mode, placed);
}

const fillTail = (tail: Tail, offsets: number[]): string =>
  fillHoles(tail.parts, tail.holes, (_kind, n) => String(tail.lines[2 * n] + offsets[tail.lines[2 * n + 1]]));

function assemble(mode: Mode, placed: Placed[]): IncrementalResult | string {
  const o = mode.options;
  const esc = mode.md.utils.escapeHtml;
  // Headings: ids deduplicated in document order, as annotate does.
  const seen = new Map<string, number>();
  const outline: OutlineItem[] = [];
  let hasToc = false;
  const slugs: string[][] = [];
  for (const { entry, line } of placed) {
    const r = entry.r!;
    hasToc ||= r.hasToc;
    const own: string[] = [];
    for (const h of r.headings) {
      const slug = h.explicit ?? dedupeSlug(h.base!, seen);
      own.push(slug);
      outline.push({ level: h.level, text: h.text, slug, line: h.line < 0 ? 0 : h.line + line });
    }
    slugs.push(own);
  }
  const ids = o.headingAnchors || hasToc;
  let toc = '';
  if (placed.some((p) => p.entry.r!.tocHole)) {
    toc = tocList(outline, esc);
    if (toc !== mode.toc) {
      mode.toc = toc;
      mode.tocVersion++;
    }
  }

  // Footnotes: the plugin numbers them in order of first reference over the whole document.
  const list: Array<{ label?: string; count: number; inline?: GroupMeta }> = [];
  const byLabel = new Map<string, number>();
  const local: number[][] = []; // per section: local id -> global id
  const base: number[][] = []; // per section: local id -> references to that footnote before this section
  for (const { entry } of placed) {
    const ids2: number[] = [];
    const before: number[] = [];
    for (const f of entry.r!.footnotes) {
      if ('inline' in f) {
        ids2.push(list.length);
        before.push(0);
        list.push({ count: 0, inline: f.inline });
      } else {
        let id = byLabel.get(f.label);
        if (id === undefined) {
          id = list.length;
          byLabel.set(f.label, id);
          list.push({ label: f.label, count: 0 });
        }
        ids2.push(id);
        before.push(list[id].count);
        list[id].count += f.count;
      }
    }
    local.push(ids2);
    base.push(before);
  }
  const metaOf = (s: number, localId: number, localSub: number) => {
    const id = local[s][localId];
    return localSub < 0 ? { id } : { id, subId: base[s][localId] + localSub, label: list[id].label };
  };
  const anchorEnv = {};
  const refHTML = (s: number, localId: number, localSub: number): string =>
    mode.footnoteRef!([{ meta: metaOf(s, localId, localSub) } as unknown as Token], 0, mode.md.options, anchorEnv, mode.md.renderer);

  // Sections' HTML with their holes filled; a section whose fill values did not change keeps last render's string.
  const htmls: string[] = [];
  const blocks: BlockMap[] = [];
  const tasks: TaskItem[] = [];
  const stats = { words: 0, characters: 0, charactersNoSpaces: 0 };
  let segments: Segment[] | null = [];
  let offset = 0; // in the HTML
  let taskBase = 0;
  for (let s = 0; s < placed.length; s++) {
    const { entry, line } = placed[s];
    const r = entry.r!;
    // everything the holes are filled with, apart from the line offset
    let rest = `${taskBase}|${ids ? 1 : 0}|${slugs[s].join('\u0001')}`;
    for (let k = 0; k < r.refs.length; k += 2) {
      const sub = r.refs[k + 1];
      rest += sub < 0 ? `|${local[s][r.refs[k]]}` : `|${local[s][r.refs[k]]}:${base[s][r.refs[k]] + sub}`;
    }
    if (r.tocHole) rest += `|${mode.tocVersion}`;
    if (r.fill?.line !== line || r.fill.rest !== rest) {
      const html = fillHoles(r.parts, r.holes, (kind, n) => {
        switch (kind) {
          case L: return String(n + line);
          case H: return ids && slugs[s][n] ? ` id="${esc(slugs[s][n])}"` : '';
          case K: return `task-item-${taskBase + n}`;
          case F: return refHTML(s, r.refs[2 * n], r.refs[2 * n + 1]);
          default: return toc; // T
        }
      });
      let segs: Segment[] | null = null;
      if (r.fill?.rest === rest && r.fill.html.length === html.length) {
        // Only the line numbers moved, and kept their width: the blocks sit where they did and hash alike (the hash
        // skips data-line attributes), so the cut is the same.
        segs = r.fill.segs;
      } else if (html === '') segs = [];
      else if (html.charCodeAt(0) === 60) {
        const split = splitBlocks(html);
        if (split && split.length === r.blocks.length) segs = split;
      }
      r.fill = { line, rest, html, segs };
    }
    const fill = r.fill!;
    htmls.push(fill.html);
    if (segments) {
      if (!fill.segs) segments = null;
      else {
        for (const g of fill.segs) segments.push({ start: g.start + offset, end: g.end + offset, hash: g.hash });
      }
    }
    offset += fill.html.length;
    if (r.placedAt?.line !== line) {
      r.placedAt = {
        line,
        blocks: r.blocks.map((b) => ({ lineStart: b.lineStart + line, lineEnd: b.lineEnd + line, hash: b.hash })),
        tasks: r.tasks.map((t) => ({ line: t.line + line, mark: t.mark + line, column: t.column })),
      };
    }
    for (const b of r.placedAt.blocks) blocks.push(b);
    for (const t of r.placedAt.tasks) tasks.push(t);
    addStats(stats, r.stats);
    taskBase += r.taskCount;
  }

  // The footnote section, built as the plugin's tail rule builds it; kept while what it shows (apart from line numbers,
  // which are holes) did not change.
  let tail = '';
  if (list.length) {
    const defs = new Map<string, { g: GroupMeta; s: number }>();
    placed.forEach(({ entry }, s) => {
      for (const g of entry.r!.groups) if (g.kind === 'def') defs.set(g.label!, { g, s }); // the last definition wins
    });
    const sig: string[] = [];
    const offsets: number[] = [];
    const picked = list.map((f) => {
      const def = f.inline ? undefined : defs.get(f.label!);
      const g = f.inline ?? def?.g;
      sig.push(`${f.label ?? ''}\u0002${f.count}\u0002${g ? g.id : -1}`);
      if (def) {
        for (const ref of def.g.refs) {
          const meta = metaOf(def.s, ref.id, ref.subId);
          sig.push(meta.subId === undefined ? `${meta.id}` : `${meta.id}:${meta.subId}`);
        }
      }
      offsets.push(def ? placed[def.s].line : 0);
      return { f, def, g };
    });
    const key = sig.join('\u0001');
    if (mode.tail?.sig !== key) {
      const Tok = mode.TokenClass;
      const out: Token[] = [new Tok('footnote_block_open', '', 1)];
      const tailStats = { words: 0, characters: 0, charactersNoSpaces: 0 };
      const lines: number[] = [];
      picked.forEach(({ f, def, g }, n) => {
        const open = new Tok('footnote_open', '', 1);
        open.meta = { id: n, label: f.label };
        out.push(open);
        if (g) {
          if (def) {
            for (const t of g.lines) {
              t.attrSet('data-line', hole('D', lines.length / 2));
              lines.push(t.map![0], n);
              t.attrSet('data-line-end', hole('D', lines.length / 2));
              lines.push(t.map![1], n);
            }
            for (const ref of g.refs) ref.token.meta = metaOf(def.s, ref.id, ref.subId);
          }
          out.push(...g.tokens);
          addStats(tailStats, g.stats);
        }
        const close = out[out.length - 1].type === 'paragraph_close' ? out.pop()! : null;
        for (let t = 0; t < (f.count > 0 ? f.count : 1); t++) {
          const anchor = new Tok('footnote_anchor', '', 0);
          anchor.meta = { id: n, subId: t, label: f.label };
          out.push(anchor);
        }
        if (close) out.push(close);
        out.push(new Tok('footnote_close', '', -1));
      });
      out.push(new Tok('footnote_block_close', '', -1));
      const cut = cutHoles(mode.md.renderer.render(out, mode.md.options, { outline }));
      if (!cut) return 'a NUL in the footnote section';
      mode.tail = { sig: key, parts: cut.parts, holes: cut.holes, lines, stats: tailStats, fill: null };
    }
    const t = mode.tail!;
    const fillKey = offsets.join(',');
    if (t.fill?.key !== fillKey) {
      const html = fillTail(t, offsets);
      // the markup's structure (line numbers do not change it), and alignSegments' test for the footnote section
      t.balanced ??= splitBlocks(html) !== null && html.startsWith('<hr class="footnotes-sep">');
      t.fill = { key: fillKey, html, hash: t.balanced ? hashRange(html, 0, html.length, [], 0, 0) : null };
    }
    tail = t.fill.html;
    addStats(stats, t.stats);
  }
  let html = htmls.join('') + tail;
  if (segments && tail) {
    // As alignSegments cuts it: the footnote section (it starts with its <hr>, footnote plugin version pinned by the tests)
    // is one segment of its own, after the last block's, hashed with its line numbers.
    const tailHash = mode.tail!.fill!.hash;
    const lastSeg = segments[segments.length - 1];
    if (tailHash === null || !lastSeg || lastSeg.end !== html.length - tail.length) segments = null;
    else segments.push({ start: lastSeg.end, end: html.length, hash: tailHash, tail: true });
  }
  if (segments === null) segments = alignSegments(html, splitBlocks(html), blocks.length); // what the page would compute
  const result: IncrementalResult = { html, blocks, tasks, outline, stats };
  const fm = placed[0]?.entry.r!.frontMatter;
  if (fm !== undefined) result.frontMatter = fm;
  result.segments = segments;
  if (o.extensions.includes('math')) mode.md.render('', { outline: [] }); // as renderResult: KaTeX's macro reset
  return result;
}

/** The live preview's renderer: `renderResult`'s result, byte for byte, computed section by section, plus `segments` (the
 *  HTML cut into its top-level blocks, what the page's DOM patch needs). */
export function renderIncremental(source: string, options: RenderOptions): IncrementalResult {
  work = { sections: 0, parsed: 0, rendered: 0, merges: 0 };
  const whole = (reason: string): IncrementalResult => {
    last = { mode: 'full', reason, ...work };
    return renderResult(source, options);
  };
  if (!FLAVORS.has(options.flavor)) return whole('flavor');
  if (options.sanitize) return whole('sanitize');
  if (source.includes('\r') || source.includes('\0')) return whole('CR or NUL in the text');
  if (definesTeXMacros(source, options)) return whole('TeX defines global macros');
  const mode = modeFor(options);
  if (!mode.ok) return whole('unknown rule');
  if (mode.skip > 0) {
    mode.skip--;
    return whole('backing off');
  }
  let result: IncrementalResult | string;
  try {
    result = renderSections(mode, source);
  } catch {
    // whatever went wrong, start over: the first time with an empty cache, while backing off with what is there
    if (!mode.backoff) mode.cache.clear();
    mode.tail = null;
    mode.context = null;
    result = 'exception';
  }
  if (typeof result === 'string') {
    if (SECTION.adaptive && result !== CHEAP_SINGLE && result !== CHEAP_HUGE) {
      // sectioned work that ended in a whole render: the next keystrokes would most likely do the same
      mode.backoff = Math.min(BACKOFF_MAX, mode.backoff ? mode.backoff * 2 : BACKOFF_FIRST);
      mode.skip = mode.backoff;
    }
    return whole(result);
  }
  mode.backoff = 0;
  last = { mode: 'sections', reason: '', ...work };
  if (crossCheckEvery > 0 && ++crossCheckCount % crossCheckEvery === 0) {
    const expected = renderResult(source, options);
    const { segments: _segments, ...got } = result;
    const a = JSON.stringify(got);
    const b = JSON.stringify(expected);
    if (a !== b) {
      let at = 0;
      while (at < a.length && a[at] === b[at]) at++;
      // offsets and counts only: the document's text must not reach the log
      const message = `incremental render differs from a whole render at JSON offset ${at} of ${a.length} / ${b.length} (${JSON.stringify(last)})`;
      for (const m of modes.values()) {
        m.cache.clear();
        m.tail = null;
        m.context = null;
      }
      onMismatch?.(message);
      return expected;
    }
  }
  return result;
}

export const incremental = {
  /** Debug: every `crossCheckEvery`-th incremental render is compared with a whole render; a difference goes to `onMismatch`
   *  and the whole render is returned. 0 (the default) = off. */
  configure(settings: {
    crossCheckEvery?: number;
    onMismatch?: (message: string) => void;
    sections?: Partial<typeof SECTION>; // tests: where cuts go and whether to fall back for speed (the defaults are tuned)
  }): void {
    if (settings.crossCheckEvery !== undefined) crossCheckEvery = Math.max(0, Math.floor(settings.crossCheckEvery));
    if (settings.onMismatch !== undefined) onMismatch = settings.onMismatch;
    if (settings.sections) Object.assign(SECTION, settings.sections);
  },
  /** Drops every cached section. */
  reset(): void {
    modes.clear();
  },
  /** What the last call did (tests, benchmarks). */
  lastRun(): typeof last {
    return { ...last };
  },
};

// --- cuts -----------------------------------------------------------------------------------------------------------------

const isBlank = (s: string, a: number, b: number): boolean => {
  for (let i = a; i < b; i++) {
    const c = s.charCodeAt(i);
    if (c !== 32 && c !== 9) return false;
  }
  return true;
};

// Column-0 characters that may start a section: not a space or tab (indented: a list item's or footnote's continuation, code),
// not `-` `+` `*` or a digit (a list item continuing the list above, front matter, `***`), not `:` or `{` (flavor syntax that
// attaches to the block above).
const startsSection = (c: number): boolean =>
  c !== 32 && c !== 9 && c !== 45 && c !== 43 && c !== 42 && !(c >= 48 && c <= 57) && c !== 58 && c !== 123;

export interface ScanOptions { frontMatter: boolean; math: boolean; html: boolean }
type Open = { marker: number; len: number; close?: RegExp };

const HTML_RAW = /^<(script|pre|style|textarea)(?=\s|>|$)/i; // markdown-it's HTML block type 1
// What the scanner skips over: up to three spaces, then ``` / ~~~ (3+), $$ (math on), <!-- or an HTML block of type 1 (raw
// HTML on). null: none starts here (or it closes on the same line).
function opener(s: string, a: number, b: number, o: ScanOptions): Open | null {
  let p = a;
  while (p < b && p - a < 3 && s.charCodeAt(p) === 32) p++;
  const c = s.charCodeAt(p);
  if (c === 36) {
    if (!o.math || s.charCodeAt(p + 1) !== 36) return null;
    const rest = s.slice(p + 2, b).trimEnd();
    return rest.length >= 2 && rest.endsWith('$$') ? null : { marker: 36, len: 2 }; // `$$ x $$` on one line closes itself
  }
  if (c === 60) {
    if (!o.html) return null;
    if (s.startsWith('<!--', p)) return s.slice(p + 4, b).includes('-->') ? null : { marker: 60, len: 0, close: /-->/ };
    const raw = HTML_RAW.exec(s.slice(p, b));
    if (!raw) return null;
    const close = new RegExp(`</${raw[1]}>`, 'i');
    return close.test(s.slice(p, b)) ? null : { marker: 60, len: 0, close };
  }
  if (c !== 96 && c !== 126) return null;
  let q = p;
  while (q < b && s.charCodeAt(q) === c) q++;
  if (q - p < 3) return null;
  if (c === 96 && s.slice(q, b).includes('`')) return null;
  return { marker: c, len: q - p };
}

function closes(s: string, a: number, b: number, open: Open): boolean {
  if (open.close) return open.close.test(s.slice(a, b));
  if (open.marker === 36) return s.slice(a, b).trimEnd().endsWith('$$');
  let p = a;
  while (p < b && p - a < 4 && s.charCodeAt(p) === 32) p++;
  if (p - a >= 4) return false;
  let q = p;
  while (q < b && s.charCodeAt(q) === open.marker) q++;
  return q - p >= open.len && isBlank(s, q, b);
}

// Content-defined: a cut after at least SECTION.min characters lands on a heading, or on a line whose first characters hash
// to 0 mod 8; after SECTION.max any candidate will do.
function selected(s: string, a: number, b: number): boolean {
  if (s.charCodeAt(a) === 35) return true;
  let h = 0x811c9dc5;
  for (let i = a; i < b && i < a + 24; i++) h = Math.imul(h ^ s.charCodeAt(i), 16777619);
  return (h >>> 0) % 8 === 0;
}

/** Character offsets where sections start (0 excluded), candidates for the verification described at the top of the file. */
export function scanCuts(s: string, o: ScanOptions): number[] {
  const cuts: number[] = [];
  const n = s.length;
  let pos = 0;
  if (o.frontMatter && (s.startsWith('---') || s.startsWith('+++'))) {
    // front matter runs to its closing line; without one there is nothing to cut (it may run to the end)
    const close = s.startsWith('---') ? /^(?:-{3,}|\.\.\.)[ \t]*$/ : /^\+\+\+[ \t]*$/;
    let p = s.indexOf('\n');
    for (;;) {
      if (p < 0) return cuts;
      const e = s.indexOf('\n', p + 1);
      if (close.test(s.slice(p + 1, e < 0 ? n : e))) {
        pos = e < 0 ? n : e + 1;
        break;
      }
      p = e;
    }
  }
  let prevBlank = false;
  let open: Open | null = null;
  let since = pos;
  while (pos < n) {
    let end = s.indexOf('\n', pos);
    if (end < 0) end = n;
    const blank = isBlank(s, pos, end);
    if (open) {
      if (closes(s, pos, end, open)) open = null;
    } else {
      if (prevBlank && !blank && pos > 0 && startsSection(s.charCodeAt(pos))) {
        const size = pos - since;
        if (size >= SECTION.max || (size >= SECTION.min && (SECTION.everyCandidate || selected(s, pos, end)))) {
          cuts.push(pos);
          since = pos;
        }
      }
      if (!blank) open = opener(s, pos, end, o);
    }
    prevBlank = blank;
    pos = end + 1;
  }
  return cuts;
}
