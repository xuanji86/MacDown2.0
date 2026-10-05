// Section-incremental rendering for the live preview (`renderIncremental` in index.ts). The result is byte for byte what
// `renderResult` returns for the same text; a keystroke re-renders the section of the document it falls in, not all of it.
//
// Sections. The text is cut before line L when line L-1 is blank and line L starts in column 0 with a character that cannot
// continue anything above it (not a space, tab, list marker `- + *` or digit, `:` or `{`), outside what the scanner sees as a
// fenced code block, `$$` formula, HTML comment or front matter. At such a line markdown-it's root loop is between two blocks:
// every block above ended at the blank line, or (lists, footnote definitions) ends because line L is not indented and not a
// list item; nothing below depends on lines above (rules do not look back), except through `env`. The scanner is only a
// heuristic: each cut is *verified* by the parse of the section above it (a section is parsed as a document of its own):
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
// the sections' definitions each time, as the footnote plugin builds it.
//
// Rendered whole instead (`full`): flavors other than plain Markdown (Quarto's plugins carry state across blocks: divs,
// attributes, captions, includes), CR or NUL in the text, TeX that defines global macros (they reach later formulas),
// headings / tasks / [TOC] inside footnote definitions, footnote references inside inline footnotes, sanitized output, any
// rule this file does not know, or more re-parsing than a whole render would cost.
import type { MarkdownIt, RendererRule, StateBlock, StateCore, Token } from 'markdown-it';
import type { BlockMap, OutlineItem, RenderOptions, RenderResult, TaskItem } from './index.ts';
import { alignSegments, splitBlocks, type Segment } from '../preview/split-html.ts';
import { tocList } from './plugins/toc.ts';
import { LRU, ownCopy } from './lru.ts';
import { dedupeSlug, slugBase, textStats, type TextStats } from './text.ts';

export interface IncrementalDeps {
  full(source: string, options: RenderOptions): RenderResult;
  build(options: RenderOptions, annotate: (state: StateCore) => void): MarkdownIt;
  key(options: RenderOptions): string;
  plainText(inline: Token | undefined): string;
  collectText(tokens: Token[]): string;
  blocksOf(tokens: Token[], lines: string[]): BlockMap[];
  tasksOf(tokens: Token[], lines: string[]): TaskItem[];
  canMemoTeX(source: string, options: RenderOptions): boolean;
}

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

// lazy: section sizes are fixed heuristics (a 4-16 KB section re-parses in well under a millisecond); upgrade = tune per
// document size if typing in very large sections shows up.
const SECTION = { min: 1024, max: 16 * 1024, everyCandidate: false }; // tests shrink these to cut at every candidate
// Characters of source + HTML (and a share for objects) kept per option set: room for a few versions of the document (an
// entry weighs about 5x its text), at least 16M, at most 64M.
const cacheBudget = (chars: number): number => Math.min(64, Math.max(16, Math.ceil((chars * 16) / 2 ** 20))) * 2 ** 20;
const GROUP = 'md2_footnote_group';

type Reference = { title: string; href: string };
interface Heading { level: number; text: string; base: string | null; explicit: string | null; line: number }
interface GroupMeta {
  id: number; // identity for the footnote section's cache
  kind: 'def' | 'inline';
  label?: string;
  tokens: Token[];
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
  groupLines: Token[];
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
  groupLines: Token[];
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
  unsupported: string | null;
  refs: Array<[string, Reference]>;
  labels: string[];
  ctx: string | null;
  r: Rendered | null;
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
  tail: { sig: string; html: string; stats: TextStats } | null;
}
interface Placed { entry: Entry; start: number; line: number; state: StateCore | null }

const keyOf = (e: Entry): string => (e.first ? `\u0001${e.text}` : e.text);
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

const L = 76; // 'L' data-line value
const H = 72; // 'H' heading id attribute
const K = 75; // 'K' task checkbox id
const F = 70; // 'F' footnote reference
const T = 84; // 'T' [TOC] list

export function createIncremental(deps: IncrementalDeps) {
  const modes = new Map<string, Mode>();
  let crossCheckEvery = 0;
  let crossCheckCount = 0;
  let onMismatch: ((message: string) => void) | undefined;
  let last = { mode: 'none' as 'none' | 'full' | 'sections', reason: '', sections: 0, parsed: 0, rendered: 0, merges: 0 };

  function sectionAnnotate(o: RenderOptions) {
    const sourceLines = o.sourceLines !== false;
    return (state: StateCore): void => {
      const sec = (state.env as Partial<SectionEnv>).md2;
      if (!sec) return; // KaTeX's macro reset renders an empty text
      const tokens = state.tokens;
      let group = false;
      for (let i = 0; i < tokens.length; i++) {
        const t = tokens[i];
        if (t.type === GROUP) {
          group = true;
          continue;
        }
        // as annotate() in index.ts, holes instead of numbers and ids
        if (t.type === 'alert_open' && t.map && tokens[i + 1]?.map) t.map[0] = tokens[i + 1].map![0];
        if (sourceLines && t.map && t.nesting >= 0 && t.type !== 'inline') {
          if (group) sec.groupLines.push(t); // set when the footnote section is put together
          else {
            t.attrSet('data-line', `\0L${t.map[0]}\0`);
            t.attrSet('data-line-end', `\0L${t.map[1]}\0`);
          }
        }
        if (t.type === 'heading_open') {
          if (group) {
            sec.unsupported = 'heading in a footnote';
            continue;
          }
          const text = deps.plainText(tokens[i + 1]);
          const explicit = t.attrGet('id');
          if (explicit === null) t.attrSet('id', `\0H${sec.headings.length}\0`);
          sec.headings.push({
            level: Number(t.tag.slice(1)),
            text,
            base: explicit === null ? slugBase(text) : null,
            explicit: explicit === null ? null : String(explicit),
            line: t.map ? t.map[0] : -1,
          });
        }
      }
    };
  }

  // The footnote plugin's tail rule, per section: definitions leave the body (as the plugin does), and go with the
  // section's inline footnotes behind GROUP markers at the end of the stream, so the core rules after this one treat them
  // as they treat the plugin's footnote section. Numbering and the section itself wait for the whole document.
  function sectionFootnoteTail(state: StateCore): void {
    const env = state.env as SectionEnv;
    const sec = env.md2;
    if (!sec) return; // KaTeX's macro reset renders an empty text
    const body: Token[] = [];
    const groups: GroupMeta[] = [];
    let def: GroupMeta | null = null;
    for (const t of state.tokens) {
      if (t.type === 'footnote_reference_open') {
        if (def) sec.unsupported = 'footnote definition inside a footnote definition';
        def = { id: ++groupIds, kind: 'def', label: (t.meta as { label: string }).label, tokens: [], refs: [], stats: textStats('') };
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
      const g: GroupMeta = { id: ++groupIds, kind: 'inline', tokens: [open, inline, close], refs: [], stats: textStats('') };
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
    const md = deps.build(o, sectionAnnotate(o));
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
    // parse: a rule that leaves it changed changes how everything after it parses, in the whole document as well
    // (@mdit/plugin-alert, checked as a terminator, can leave `lineMax` short: blank lines are then no longer skipped).
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
        const hole = (tokens[idx].meta as { md2Hole?: number } | null)?.md2Hole;
        return hole === undefined ? footnoteRef(tokens, idx, opts, env, slf) : `\0F${hole}\0`;
      };
    }
    if (md.renderer.rules.toc) md.renderer.rules.toc = (tokens, idx, _o, _env, slf) => `<nav class="toc"${slf.renderAttrs(tokens[idx])}>\0T0\0</nav>\n`;
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
    };
  }

  function modeFor(o: RenderOptions): Mode {
    const key = deps.key(o);
    let mode = modes.get(key);
    if (!mode) {
      mode = makeMode(o);
      if (modes.size >= 2) modes.delete(modes.keys().next().value!); // the settings in use, and the previous ones
      modes.set(key, mode);
    }
    return mode;
  }

  // --- block phase --------------------------------------------------------------------------------------------------

  function parseA(mode: Mode, text: string, first: boolean): { entry: Entry; state: StateCore } {
    const sec: Sec = { first, touchedEnd: false, leaks: false, unsupported: null, headings: [], groupLines: [], footnotes: [], groups: [] };
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
      unsupported: sec.unsupported,
      refs: env.references ? Object.entries(env.references) : [],
      labels: env.footnotes?.refs ? Object.keys(env.footnotes.refs) : [],
      ctx: null,
      r: null,
    };
    return { entry, state };
  }

  function entryFor(mode: Mode, text: string, first: boolean, fresh: { chars: number }): { entry: Entry; state: StateCore | null } {
    const hit = mode.cache.get(first ? `\u0001${text}` : text);
    if (hit) return { entry: hit, state: null };
    fresh.chars += text.length;
    // A slice of the document keeps the whole document alive in both engines: the cache gets its own copy.
    const { entry, state } = parseA(mode, ownCopy(text), first);
    mode.cache.set(keyOf(entry), entry, weightOf(entry));
    return { entry, state };
  }

  // --- inline phase and HTML ------------------------------------------------------------------------------------------

  function renderSection(mode: Mode, placed: Placed, ctx: Context): Rendered {
    const { entry } = placed;
    const state = placed.state ?? parseA(mode, entry.text, entry.first).state;
    placed.state = null; // the phase below consumes it
    const env = state.env as SectionEnv;
    env.references = ctx.references;
    env.footnotes = ctx.labels ? { refs: { ...ctx.labels } } : undefined;
    for (const rule of mode.phaseB) rule(state);
    const sec = env.md2;
    const tokens = state.tokens;
    let m = tokens.findIndex((t) => t.type === GROUP);
    if (m < 0) m = tokens.length;
    const body = tokens.slice(0, m);
    for (const g of sec.groups) {
      // the core rules after the tail may have replaced tokens; take the group's tokens from the stream again
      const at = tokens.findIndex((t) => (t.meta as unknown) === g);
      let end = at + 1;
      while (end < tokens.length && tokens[end].type !== GROUP) end++;
      g.tokens = tokens.slice(at + 1, end);
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
      g.stats = textStats(deps.collectText(g.tokens));
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
          c.attrSet(name, `\0K${n[1]}\0`);
          if (c.type === 'checkbox_input') taskCount++;
        }
      }
    }
    const html = mode.md.renderer.render(body, mode.md.options, env);
    const parts: string[] = [];
    const holes: number[] = [];
    let unsupported = sec.unsupported;
    for (let i = 0; ; ) {
      const a = html.indexOf('\0', i);
      if (a < 0) {
        parts.push(html.slice(i));
        break;
      }
      const b = html.indexOf('\0', a + 1);
      if (b < 0) {
        unsupported = 'stray hole marker';
        parts.push(html.slice(i));
        break;
      }
      const kind = html.charCodeAt(a + 1);
      let before = html.slice(i, a);
      let next = b + 1;
      if (kind === H) {
        // the whole ` id="…"` attribute is the hole: it is left out when there is no id
        if (!before.endsWith(' id="') || html.charCodeAt(next) !== 34) unsupported = 'heading id not where expected';
        before = before.slice(0, -5);
        next++;
      }
      parts.push(before);
      holes.push(kind, Number(html.slice(a + 2, b)));
      i = next;
    }
    const lines = entry.text.split('\n');
    const fm = body.find((t) => t.type === 'front_matter');
    const r: Rendered = {
      parts,
      holes,
      blocks: deps.blocksOf(body, lines),
      tasks: deps.tasksOf(body, lines),
      headings: sec.headings,
      hasToc: env.hasToc === true,
      taskCount,
      refs,
      footnotes: sec.footnotes,
      groups: sec.groups,
      groupLines: sec.groupLines,
      stats: textStats(deps.collectText(body)),
      unsupported,
      tocHole: holes.some((h, k) => k % 2 === 0 && h === T),
    };
    if (fm) r.frontMatter = fm.meta as unknown as string;
    return r;
  }

  interface Context { key: string; references?: Record<string, Reference>; labels?: Record<string, number> }

  function contextOf(placed: Placed[]): Context {
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
    return { key, references, labels };
  }

  // --- the document -----------------------------------------------------------------------------------------------------

  function renderSections(mode: Mode, source: string): IncrementalResult | string {
    mode.cache.resize(cacheBudget(source.length));
    const cuts = scanCuts(source, mode.options.extensions.includes('frontMatter'));
    const starts = [0, ...cuts];
    const fresh = { chars: 0 };
    const budget = source.length * 2 + 65536; // more re-parsing than this and a whole render is cheaper
    const placed: Placed[] = [];
    let merges = 0;
    let line = 0;
    for (let i = 0; i < starts.length; ) {
      let j = i + 1;
      let span = 1;
      const from = starts[i];
      let got = entryFor(mode, source.slice(from, j < starts.length ? starts[j] : source.length), i === 0, fresh);
      while (!got.entry.clean && j < starts.length) {
        j = got.entry.leaks ? starts.length : Math.min(starts.length, j + span);
        span *= 2;
        merges++;
        got = entryFor(mode, source.slice(from, j < starts.length ? starts[j] : source.length), i === 0, fresh);
        if (fresh.chars > budget) return 'too much re-parsing';
      }
      if (got.entry.unsupported) return got.entry.unsupported;
      placed.push({ entry: got.entry, start: from, line, state: got.state });
      line += got.entry.newlines;
      i = j;
    }
    if (fresh.chars > budget) return 'too much re-parsing';

    const ctx = contextOf(placed);
    let rendered = 0;
    for (const p of placed) {
      const e = p.entry;
      if (!e.r || e.ctx !== ctx.key) {
        e.r = renderSection(mode, p, ctx);
        e.ctx = ctx.key;
        rendered++;
        mode.cache.set(keyOf(e), e, weightOf(e));
      }
      if (e.r.unsupported) return e.r.unsupported;
    }
    const result = assemble(mode, placed);
    last = { mode: 'sections', reason: '', sections: placed.length, parsed: fresh.chars, rendered, merges };
    return result;
  }

  function assemble(mode: Mode, placed: Placed[]): IncrementalResult {
    const o = mode.options;
    const esc = mode.md.utils.escapeHtml;
    // Headings: ids deduplicated in document order, as annotate() does.
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
    const anchorEnv = {};
    const refHTML = (s: number, localId: number, localSub: number): string => {
      const id = local[s][localId];
      const meta = localSub < 0 ? { id } : { id, subId: base[s][localId] + localSub, label: list[id].label };
      return mode.footnoteRef!([{ meta } as unknown as Token], 0, mode.md.options, anchorEnv, mode.md.renderer);
    };

    // Sections' HTML with their holes filled; a section whose fill values did not change keeps last render's string.
    const htmls: string[] = [];
    const blocks: BlockMap[] = [];
    const tasks: TaskItem[] = [];
    const stats = { words: 0, characters: 0, charactersNoSpaces: 0 };
    let segments: Segment[] | null = [];
    let offset = 0; // in the HTML
    let taskBase = 0;
    let lastWithBlocks = -1;
    let lastWithBlocksAt = 0;
    let lastWithBlocksSegs = 0;
    for (let s = 0; s < placed.length; s++) {
      const { entry, line } = placed[s];
      const r = entry.r!;
      // everything the holes are filled with, apart from the line offset
      let rest = `${taskBase}|${ids ? 1 : 0}|${slugs[s].join('\u0001')}`;
      const refFills: string[] = [];
      for (let k = 0; k < r.refs.length; k += 2) refFills.push(refHTML(s, r.refs[k], r.refs[k + 1]));
      if (refFills.length) rest += `|${refFills.join('')}`;
      if (r.tocHole) rest += `|${mode.tocVersion}`;
      if (r.fill?.line !== line || r.fill.rest !== rest) {
        let html = r.parts[0];
        for (let k = 0; k < r.holes.length; k += 2) {
          const n = r.holes[k + 1];
          switch (r.holes[k]) {
            case L: html += String(n + line); break;
            case H: html += ids && slugs[s][n] ? ` id="${esc(slugs[s][n])}"` : ''; break;
            case K: html += `task-item-${taskBase + n}`; break;
            case F: html += refFills[n]; break;
            case T: html += toc; break;
          }
          html += r.parts[k / 2 + 1];
        }
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
          if (fill.segs.length) {
            lastWithBlocks = s;
            lastWithBlocksAt = offset;
            lastWithBlocksSegs = segments.length;
          }
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
      stats.words += r.stats.words;
      stats.characters += r.stats.characters;
      stats.charactersNoSpaces += r.stats.charactersNoSpaces;
      taskBase += r.taskCount;
    }

    // The footnote section, built as the plugin's tail rule builds it; kept while nothing it shows changed.
    let tail = '';
    if (list.length) {
      const defs = new Map<string, { g: GroupMeta; s: number }>();
      placed.forEach(({ entry }, s) => {
        for (const g of entry.r!.groups) if (g.kind === 'def') defs.set(g.label!, { g, s }); // the last definition wins
      });
      const metaOf = (s: number, localId: number, localSub: number) => {
        const id = local[s][localId];
        return localSub < 0 ? { id } : { id, subId: base[s][localId] + localSub, label: list[id].label };
      };
      const sig: string[] = [];
      const picked = list.map((f) => {
        const def = f.inline ? undefined : defs.get(f.label!);
        const g = f.inline ?? def?.g;
        sig.push(`${f.label ?? ''}\u0002${f.count}\u0002${g ? g.id : -1}\u0002${def ? placed[def.s].line : -1}`);
        if (def) for (const ref of def.g.refs) sig.push(JSON.stringify(metaOf(def.s, ref.id, ref.subId)));
        return { f, def, g };
      });
      const key = sig.join('\u0001');
      if (mode.tail?.sig !== key) {
        const Tok = mode.TokenClass;
        const out: Token[] = [new Tok('footnote_block_open', '', 1)];
        const tailStats = { words: 0, characters: 0, charactersNoSpaces: 0 };
        picked.forEach(({ f, def, g }, n) => {
          const open = new Tok('footnote_open', '', 1);
          open.meta = { id: n, label: f.label };
          out.push(open);
          if (g) {
            if (def) {
              const line = placed[def.s].line;
              for (const t of placed[def.s].entry.r!.groupLines) {
                if (!g.tokens.includes(t)) continue;
                t.attrSet('data-line', String(t.map![0] + line));
                t.attrSet('data-line-end', String(t.map![1] + line));
              }
              for (const ref of g.refs) ref.token.meta = metaOf(def.s, ref.id, ref.subId);
            }
            out.push(...g.tokens);
            tailStats.words += g.stats.words;
            tailStats.characters += g.stats.characters;
            tailStats.charactersNoSpaces += g.stats.charactersNoSpaces;
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
        mode.tail = { sig: key, html: mode.md.renderer.render(out, mode.md.options, { outline }), stats: tailStats };
      }
      tail = mode.tail!.html;
      stats.words += mode.tail!.stats.words;
      stats.characters += mode.tail!.stats.characters;
      stats.charactersNoSpaces += mode.tail!.stats.charactersNoSpaces;
    }
    let html = htmls.join('') + tail;
    if (segments && tail) {
      // The newline before the footnote rule belongs to the last block's segment, and the footnote section is one segment
      // of its own (split-html.ts alignSegments): cut that stretch again.
      if (lastWithBlocks < 0) segments = null;
      else {
        const rest = html.slice(lastWithBlocksAt);
        const n = segments.length - lastWithBlocksSegs;
        const again = alignSegments(rest, splitBlocks(rest), n);
        if (!again) segments = null;
        else segments.splice(lastWithBlocksSegs, n, ...again.map((g) => ({ ...g, start: g.start + lastWithBlocksAt, end: g.end + lastWithBlocksAt })));
      }
    }
    if (segments === null) segments = alignSegments(html, splitBlocks(html), blocks.length); // what the page would compute
    const result: IncrementalResult = { html, blocks, tasks, outline, stats };
    const fm = placed[0]?.entry.r!.frontMatter;
    if (fm !== undefined) result.frontMatter = fm;
    result.segments = segments;
    if (o.extensions.includes('math')) mode.md.render('', { outline: [] }); // as renderResult: KaTeX's macro reset
    return result;
  }

  function render(source: string, options: RenderOptions): IncrementalResult {
    const whole = (reason: string): IncrementalResult => {
      last = { mode: 'full', reason, sections: 0, parsed: source.length, rendered: 0, merges: 0 };
      return deps.full(source, options);
    };
    if (!FLAVORS.has(options.flavor)) return whole('flavor');
    if (options.sanitize) return whole('sanitize');
    if (source.includes('\r') || source.includes('\0')) return whole('CR or NUL in the text');
    if (!deps.canMemoTeX(source, options)) return whole('TeX defines global macros');
    const mode = modeFor(options);
    if (!mode.ok) return whole('unknown rule');
    let result: IncrementalResult | string;
    try {
      result = renderSections(mode, source);
    } catch (e) {
      mode.cache.clear(); // whatever went wrong, start over; the whole render below reports a real error itself
      result = `error: ${e instanceof Error ? e.message : String(e)}`;
    }
    if (typeof result === 'string') return whole(result);
    if (crossCheckEvery > 0 && ++crossCheckCount % crossCheckEvery === 0) {
      const expected = deps.full(source, options);
      const { segments: _segments, ...got } = result;
      const a = JSON.stringify(got);
      const b = JSON.stringify(expected);
      if (a !== b) {
        let at = 0;
        while (at < a.length && a[at] === b[at]) at++;
        const message = `incremental render differs from a whole render at JSON offset ${at}: …${JSON.stringify(a.slice(Math.max(0, at - 60), at + 60))} vs …${JSON.stringify(b.slice(Math.max(0, at - 60), at + 60))}`;
        for (const m of modes.values()) m.cache.clear();
        onMismatch?.(message);
        return expected;
      }
    }
    return result;
  }

  const api = {
    /** Debug: every `crossCheckEvery`-th incremental render is compared with a whole render; a difference goes to `onMismatch`
     *  and the whole render is returned. 0 (the default) = off. */
    configure(settings: {
      crossCheckEvery?: number;
      onMismatch?: (message: string) => void;
      sections?: { min: number; max: number; everyCandidate: boolean }; // tests: where cuts go (the defaults are tuned for speed)
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

  return {
    render,
    api,
    forget(prefix: string): void {
      for (const key of modes.keys()) if (key.startsWith(prefix)) modes.delete(key);
    },
  };
}

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

// A fence or `$$` opener as the scanner sees it: up to three spaces, then ``` / ~~~ (3+) or $$. Returns [marker, length] or null.
function opener(s: string, a: number, b: number): [number, number] | null {
  let p = a;
  while (p < b && p - a < 3 && s.charCodeAt(p) === 32) p++;
  const c = s.charCodeAt(p);
  if (c === 36) {
    if (s.charCodeAt(p + 1) !== 36) return null;
    const rest = s.slice(p + 2, b).trimEnd();
    return rest.length >= 2 && rest.endsWith('$$') ? null : [36, 2]; // `$$ x $$` on one line closes itself
  }
  if (c === 60 && s.startsWith('<!--', p)) return s.slice(p + 4, b).includes('-->') ? null : [60, 0];
  if (c !== 96 && c !== 126) return null;
  let q = p;
  while (q < b && s.charCodeAt(q) === c) q++;
  if (q - p < 3) return null;
  if (c === 96 && s.slice(q, b).includes('`')) return null;
  return [c, q - p];
}

function closes(s: string, a: number, b: number, marker: number, len: number): boolean {
  if (marker === 36) return s.slice(a, b).trimEnd().endsWith('$$');
  if (marker === 60) return s.slice(a, b).includes('-->');
  let p = a;
  while (p < b && p - a < 4 && s.charCodeAt(p) === 32) p++;
  if (p - a >= 4) return false;
  let q = p;
  while (q < b && s.charCodeAt(q) === marker) q++;
  return q - p >= len && isBlank(s, q, b);
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
export function scanCuts(s: string, frontMatter: boolean): number[] {
  const cuts: number[] = [];
  const n = s.length;
  let pos = 0;
  if (frontMatter && (s.startsWith('---') || s.startsWith('+++'))) {
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
  let marker = 0;
  let len = 0;
  let since = pos;
  while (pos < n) {
    let end = s.indexOf('\n', pos);
    if (end < 0) end = n;
    const blank = isBlank(s, pos, end);
    if (marker) {
      if (closes(s, pos, end, marker, len)) marker = 0;
    } else {
      if (prevBlank && !blank && pos > 0 && startsSection(s.charCodeAt(pos))) {
        const size = pos - since;
        if (size >= SECTION.max || (size >= SECTION.min && (SECTION.everyCandidate || selected(s, pos, end)))) {
          cuts.push(pos);
          since = pos;
        }
      }
      const o = blank ? null : opener(s, pos, end);
      if (o) [marker, len] = o;
    }
    prevBlank = blank;
    pos = end + 1;
  }
  return cuts;
}
