// Inline source map (PLAN M2, preview editing and two-way selection): for one top-level block, which characters of its rendered
// text come from which characters of its source, one UTF-16 unit at a time. Computed on demand for a single block (the page asks
// when a selection or an edit needs it), never as part of a render.
//
// The block's lines are parsed on their own by an instrumented copy of the renderer (same options, same plugins) that records,
// for every character of every text and code span token, where in the source it came from:
//   - text the inline parser collects ("pending") is always a slice of the source at a known position (the `text` rule, the
//     parser's one-character fallback, an unclosed backtick run, a lone `$`); the pending string is watched and each slice is
//     checked against the source before it is believed;
//   - tokens a rule pushes itself (emphasis and strikethrough markers, sub/sup, code spans) are placed from the rule's start
//     position, only when their markup and content are found exactly where the rule must have read them;
//   - whatever rewrites tokens afterwards (emphasis pairing, joining, typographer, emoji, linkify, task boxes) is followed by
//     aligning the text before and after (align.ts): characters it kept keep their place, the rest have none;
//   - escapes, entities, code span spaces turned from line breaks, link texts made by linkify or autolinks, math, footnote
//     references, raw HTML: no place (the page treats them as unmappable).
// Positions inside an inline token's content are then turned into positions in the block by its lines (each line of a paragraph's
// content is the end of its source line, the first one trimmed at the start and the last at the end).
//
// None of this is trusted on its own. The block is rendered once more with every placed character replaced by a sentinel (a
// private-use character, a different one for each), and the page compares the text the browser makes of that HTML with the text it
// shows: everything has to be identical once the sentinels are put back (source-map.ts), and each sentinel then says exactly where
// its character sits in the page. A block that differs at all is unmappable as a whole.
import type { MarkdownIt, StateInline, Token } from 'markdown-it';
import { alignKept } from './align.ts';
import { build, onFlavorRegistered, optionsKey, type RenderOptions } from './core.ts';

/** Definitions the block cannot see on its own: link reference definitions and footnote labels of the whole document. */
export interface BlockContext {
  references?: Record<string, unknown>;
  labels?: Record<string, number>;
}

/** The block rendered with code point `sentinels[i]` in place of the UTF-16 unit `originals[i]` found at block offset `offsets[i]`. */
export interface InlineProbe {
  html: string;
  sentinels: number[];
  originals: string;
  offsets: number[];
}

// Tokens whose content is rendered as text, in the order the renderer writes it.
const STREAM = new Set(['text', 'text_special', 'code_inline', 'emoji']);
// Tokens whose characters may be placed (and replaced by sentinels).
const CLAIMABLE = new Set(['text', 'code_inline']);
// lazy: the watched pending string costs O(length) per append; an inline token longer than this is not tracked (unmappable);
// upgrade = record appends without comparing the whole string.
const MAX_INLINE = 64 * 1024;
const PUA_FIRST = 0xe000;
const SENTINEL_RANGES: Array<[number, number]> = [[0xe000, 0xf8ff], [0xf0000, 0xffffd], [0x100000, 0x10fffd]];

interface Track {
  prov: WeakMap<Token, Int32Array>; // stream token -> per content unit, offset in the inline token's content (-1: none)
  seen: WeakSet<Token>; // placed (or given up on) already
  top: string | null; // content of the inline token the core rule is parsing
  state: StateInline | null; // the parser state of that parse (nested parses, e.g. image alt text, are not tracked)
  content: WeakMap<Token, string>; // inline token -> its content when it was parsed (plugins may change it later)
}

interface Instrumented {
  md: MarkdownIt;
  track: Track;
}

let fallbackAt = -1; // the position the parser's one-character fallback appends from (set just before it does)
const instances = new Map<string, Instrumented>();
onFlavorRegistered(() => instances.clear());

function instrumented(o: RenderOptions): Instrumented {
  const key = optionsKey(o);
  const cached = instances.get(key);
  if (cached) return cached;
  // lazy: one instance per option set, kept for the page's life (a handful); upgrade = an LRU like incremental.ts's modes
  const md = build({ ...o, sourceLines: false }, () => ({ lines: () => null, heading: () => null }));
  const track: Track = { prov: new WeakMap(), seen: new WeakSet(), top: null, state: null, content: new WeakMap() };
  instrument(md, track);
  const made = { md, track };
  instances.set(key, made);
  return made;
}

type Stream = { text: string; prov: Int32Array };

function instrument(md: MarkdownIt, track: Track): void {
  const shadows = new WeakMap<StateInline, number[]>();
  const Base = md.inline.State as unknown as new (src: string, md: MarkdownIt, env: unknown, out: Token[]) => StateInline;

  // The pending string, watched: every change to it keeps `shadow` (one source position per character) in step.
  class Tracked extends Base {
    constructor(src: string, mdi: MarkdownIt, env: unknown, out: Token[]) {
      super(src, mdi, env, out);
      const on = track.top !== null && track.state === null && src === track.top && src.length <= MAX_INLINE;
      if (on) track.state = this;
      let pending = '';
      const shadow: number[] = [];
      if (on) shadows.set(this, shadow);
      Object.defineProperty(this, 'pending', {
        configurable: true,
        enumerable: true,
        get: () => pending,
        set: (v: string) => {
          const old = pending;
          pending = v;
          if (on) follow(this, shadow, old, v);
        },
      });
    }

    pushPending(): Token {
      const shadow = shadows.get(this);
      const snapshot = shadow ? Int32Array.from(shadow) : null;
      const token = super.pushPending();
      if (snapshot) {
        track.prov.set(token, snapshot.length === token.content.length ? snapshot : new Int32Array(token.content.length).fill(-1));
        track.seen.add(token);
      }
      return token;
    }
  }
  md.inline.State = Tracked as unknown as typeof md.inline.State;

  function follow(state: StateInline, shadow: number[], old: string, v: string): void {
    const at = fallbackAt;
    fallbackAt = -1;
    if (v.length === 0) {
      shadow.length = 0;
    } else if (v.length > old.length && v.startsWith(old)) {
      // An append: the text rule, a lone backtick run or `$` append the source from `pos` on; the fallback the character before.
      const add = v.length - old.length;
      const from = at >= 0 ? at : state.pos;
      const ok = state.src.startsWith(v.slice(old.length), from);
      for (let i = 0; i < add; i++) shadow.push(ok ? from + i : -1);
    } else if (v.length < old.length && old.startsWith(v)) {
      shadow.length = v.length; // trailing spaces before a line break, a linkified scheme
    } else {
      shadow.length = 0;
      for (let i = 0; i < v.length; i++) shadow.push(-1);
    }
  }

  // The inline parser's loop, as markdown-it 15.0.2 has it, with the fallback's position announced to `follow`.
  md.inline.tokenize = function tokenize(state: StateInline): void {
    const rules = this.ruler.getRules('');
    const len = rules.length;
    const end = state.posMax;
    const maxNesting = state.md.options.maxNesting;
    while (state.pos < end) {
      const prevPos = state.pos;
      let ok = false;
      if (state.level < maxNesting) {
        for (let i = 0; i < len; i++) {
          ok = rules[i](state, false);
          if (ok) {
            if (prevPos >= state.pos) throw new Error("inline rule didn't increment state.pos");
            break;
          }
        }
      }
      if (ok) {
        if (state.pos >= end) break;
        continue;
      }
      fallbackAt = state.pos;
      state.pending += state.src[state.pos++];
      fallbackAt = -1;
    }
    if (state.pending) state.pushPending();
  };

  // Tokens a rule pushes itself are placed right after it ran (nested tokens, e.g. a link's text, were placed by their own rules).
  for (const rule of [...md.inline.ruler.__rules__]) {
    const fn = rule.fn;
    md.inline.ruler.at(
      rule.name,
      (state, silent) => {
        if (silent || state !== track.state) return fn(state, silent);
        const n0 = state.tokens.length;
        const p0 = state.pos;
        const ok = fn(state, silent);
        if (ok) place(state, n0, p0);
        if (ok && rule.name === 'link') shortcutLabel(state, n0, p0);
        return ok;
      },
      { alt: rule.alt },
    );
  }

  function place(state: StateInline, n0: number, p0: number): void {
    const src = state.src;
    let cursor = p0;
    let stopped = false;
    for (let i = n0; i < state.tokens.length; i++) {
      const t = state.tokens[i];
      if (track.seen.has(t)) continue;
      track.seen.add(t);
      if (!STREAM.has(t.type)) {
        if (stopped) continue;
        if (t.markup) {
          if (src.startsWith(t.markup, cursor)) cursor += t.markup.length;
          else stopped = true;
        } else if (t.content) stopped = true; // raw HTML, a formula, an image: not text we can place
        continue;
      }
      const p = new Int32Array(t.content.length).fill(-1);
      track.prov.set(t, p);
      if (stopped) continue;
      if (t.type === 'text_special') {
        // an escape or an entity: shown as one character, written as several; never placed
        if (t.markup && src.startsWith(t.markup, cursor)) cursor += t.markup.length;
        else stopped = true;
      } else if (t.type === 'code_inline') {
        // marker, raw content, marker; the content may have lost one space at each end and had line breaks made spaces
        const m = t.markup.length;
        const end = state.pos - m;
        if (!m || !src.startsWith(t.markup, cursor) || end < cursor + m) {
          stopped = true;
          continue;
        }
        const raw = src.slice(cursor + m, end);
        const shift = raw.length === t.content.length ? 0 : raw.length === t.content.length + 2 ? 1 : -1;
        if (shift >= 0) {
          for (let k = 0; k < t.content.length; k++) if (raw.charCodeAt(shift + k) === t.content.charCodeAt(k) && raw.charCodeAt(shift + k) !== 10) p[k] = cursor + m + shift + k;
        }
        cursor = state.pos;
      } else if (t.content && src.startsWith(t.content, cursor)) {
        for (let k = 0; k < t.content.length; k++) p[k] = cursor + k;
        cursor += t.content.length;
      } else stopped = true;
    }
  }

  // `[text]` and `[text][]`: the text is also the reference label, so editing it would point the link somewhere else (or nowhere,
  // and the brackets would show): its characters get no place.
  function shortcutLabel(state: StateInline, n0: number, p0: number): void {
    const end = state.pos;
    const labelEnd = state.md.helpers.parseLinkLabel(state, p0, true);
    if (labelEnd < 0) return;
    const rest = state.src.slice(labelEnd + 1, end);
    if (rest !== '' && rest !== '[]') return;
    let inside = false; // pending text the rule's first push flushed comes before the link_open, and stays
    for (let i = n0; i < state.tokens.length; i++) {
      const t = state.tokens[i];
      if (t.type === 'link_open') inside = true;
      else if (inside && STREAM.has(t.type)) track.prov.set(t, new Int32Array(t.content.length).fill(-1));
    }
  }

  // The token stream's text before and after a rewrite: the second gets the positions of the characters it kept.
  // What a rewrite may change, taken before it: the text-ish tokens and their contents (the text itself only when it did change).
  type Snapshot = { tokens: Token[]; contents: string[]; types: string[] };
  function snapshot(tokens: Token[]): Snapshot {
    const s: Snapshot = { tokens: [], contents: [], types: [] };
    for (const t of tokens) {
      if (!STREAM.has(t.type)) continue;
      s.tokens.push(t);
      s.contents.push(t.content);
      s.types.push(t.type);
    }
    return s;
  }
  function unchanged(s: Snapshot, tokens: Token[]): boolean {
    let i = 0;
    for (const t of tokens) {
      if (!STREAM.has(t.type)) continue;
      if (s.tokens[i] !== t || s.contents[i] !== t.content || s.types[i] !== t.type) return false;
      i++;
    }
    return i === s.tokens.length;
  }

  function stream(tokens: Token[], contents?: string[], types?: string[]): Stream {
    let text = '';
    const parts: Array<Int32Array | number> = [];
    tokens.forEach((t, i) => {
      const type = types ? types[i] : t.type;
      const content = contents ? contents[i] : t.content;
      if (!STREAM.has(type)) return;
      text += content;
      const p = track.prov.get(t);
      parts.push(type !== 'text_special' && p && p.length === content.length ? p : content.length);
    });
    const prov = new Int32Array(text.length).fill(-1);
    let at = 0;
    for (const part of parts) {
      if (typeof part === 'number') at += part;
      else {
        prov.set(part, at);
        at += part.length;
      }
    }
    return { text, prov };
  }

  function realign(before: Stream, tokens: Token[]): void {
    let text = '';
    for (const t of tokens) if (STREAM.has(t.type)) text += t.content;
    const kept = alignKept(before.text, text);
    let at = 0;
    for (const t of tokens) {
      if (!STREAM.has(t.type)) continue;
      const p = new Int32Array(t.content.length);
      for (let k = 0; k < p.length; k++) {
        const j = kept[at + k];
        p[k] = j >= 0 && t.type !== 'text_special' ? before.prov[j] : -1;
      }
      track.prov.set(t, p);
      at += p.length;
    }
  }

  // Inline parse: tokenize (placing as it goes), then the post-processing rules (emphasis pairing, fragment joining), followed.
  md.inline.parse = function parse(str: string, mdi: MarkdownIt, env: unknown, out: Token[]): void {
    const state = new this.State(str, mdi, env as Record<string, unknown>, out);
    this.tokenize(state);
    const own = state === track.state;
    const before = own ? stream(out) : null;
    for (const rule of this.ruler2.getRules('')) rule(state);
    if (before) realign(before, out);
  };

  // The core rule that runs the inline parser, naming each inline token's parse as the one to track.
  const core = md.core.ruler.__rules__;
  const inlineAt = core.findIndex((r) => r.name === 'inline');
  md.core.ruler.at('inline', (state) => {
    const tokens = state.tokens;
    for (let i = 0, l = tokens.length; i < l; i++) {
      const tok = tokens[i];
      if (tok.type !== 'inline') continue;
      track.content.set(tok, tok.content);
      track.top = tok.content;
      track.state = null;
      try {
        state.md.inline.parse(tok.content, state.md, state.env, tok.children!);
      } finally {
        track.top = null;
        track.state = null;
      }
    }
  });
  // Every core rule after it may rewrite the children (typographer, emoji, linkify, task boxes, joins): followed.
  for (const rule of core.slice(inlineAt + 1)) {
    const fn = rule.fn;
    md.core.ruler.at(
      rule.name,
      (state) => {
        const before: Array<[Token, Snapshot]> = [];
        for (const t of state.tokens) if (t.type === 'inline' && t.children) before.push([t, snapshot(t.children)]);
        fn(state);
        for (const [t, s] of before) {
          if (t.children && !unchanged(s, t.children)) realign(stream(s.tokens, s.contents, s.types), t.children);
        }
      },
      { alt: rule.alt },
    );
  }
}

/** Where each unit of an inline token's content sits in the block: the content is the block's lines `map[0]`.. with their
 *  container prefix (quote marks, list indentation) removed and the whole trimmed, so each content line is the end of its source
 *  line (the first trimmed at the start, the last at the end, a heading's closing `#`s gone). -1 where that does not hold. */
export function contentOffsets(content: string, map: [number, number], lines: string[], lineStarts: number[]): Int32Array {
  const out = new Int32Array(content.length).fill(-1);
  const parts = content.split('\n');
  const [a, b] = map;
  if (parts.length > b - a) return out;
  let ci = 0;
  for (let j = 0; j < parts.length; j++) {
    const piece = parts[j];
    const line = lines[a + j] ?? '';
    const first = j === 0;
    const last = j === parts.length - 1;
    let p = -1;
    if (piece.length === 0) p = -1;
    else if (!last) p = line.endsWith(piece) ? line.length - piece.length : -1;
    else if (!first) {
      const e = line.trimEnd().length - piece.length;
      p = e >= 0 && line.startsWith(piece, e) ? e : -1;
    } else {
      const found = new Set<number>();
      const e1 = line.trimEnd().length - piece.length;
      if (e1 >= 0 && line.startsWith(piece, e1)) found.add(e1);
      const close = closingSequenceEnd(line);
      const e2 = close - piece.length;
      if (close >= 0 && e2 >= 0 && line.startsWith(piece, e2)) found.add(e2);
      if (found.size === 1) p = [...found][0];
      else if (found.size === 0) {
        // a table cell: anywhere in its row, if only once
        const i = line.indexOf(piece);
        if (i >= 0 && line.indexOf(piece, i + 1) < 0) p = i;
      }
    }
    if (p >= 0) for (let k = 0; k < piece.length; k++) out[ci + k] = lineStarts[a + j] + p + k;
    ci += piece.length + 1;
  }
  return out;
}

// The end of an ATX heading's text when the line closes with `#`s (markdown-it's heading rule): -1 when it does not.
function closingSequenceEnd(line: string): number {
  let max = line.length;
  while (max > 0 && (line.charCodeAt(max - 1) === 32 || line.charCodeAt(max - 1) === 9)) max--;
  let tmp = max;
  while (tmp > 0 && line.charCodeAt(tmp - 1) === 35) tmp--;
  if (tmp === max || tmp === 0) return -1;
  const before = line.charCodeAt(tmp - 1);
  if (before !== 32 && before !== 9) return -1;
  return line.slice(0, tmp).trimEnd().length;
}

/** The block `text` (its source lines joined, block-relative offsets) parsed and rendered on its own with `options`, `context`
 *  standing in for the rest of the document; `first`: the block is the document's first (only it may open front matter). Returns
 *  one probe per batch of placed characters (one, unless a block places more characters than there are free private-use code
 *  points, about 137 000), or an empty list when nothing could be placed. */
export function probeBlock(text: string, options: RenderOptions, first: boolean, context?: BlockContext | null): InlineProbe[] {
  const o = first || !options.extensions.includes('frontMatter') ? options : { ...options, extensions: options.extensions.filter((e) => e !== 'frontMatter') };
  const { md, track } = instrumented(o);
  const env: Record<string, unknown> = { outline: [] };
  if (context?.references) env.references = { ...context.references };
  if (context?.labels) env.footnotes = { refs: { ...context.labels } };
  const lines = text.split('\n');
  const lineStarts: number[] = [];
  for (let i = 0, at = 0; i < lines.length; i++) {
    lineStarts.push(at);
    at += lines[i].length + 1;
  }
  let tokens: Token[];
  try {
    tokens = md.parse(text, env);
  } finally {
    if (o.extensions.includes('math')) md.render('', { outline: [] }); // KaTeX's global macros reset, as renderResult does
  }
  // Claims: (token, unit, block offset), in rendering order.
  const claimed: Array<{ t: Token; k: number; at: number }> = [];
  let row: [number, number] | null = null; // a table cell's inline token has no lines of its own: its row's
  for (const tok of tokens) {
    if (tok.type === 'tr_open') row = tok.map as [number, number] | null;
    else if (tok.type === 'tr_close') row = null;
    const map = (tok.map ?? row) as [number, number] | null;
    if (tok.type !== 'inline' || !map || !tok.children) continue;
    const content = track.content.get(tok);
    if (content === undefined) continue;
    const offsets = contentOffsets(content, map, lines, lineStarts);
    for (const t of tok.children) {
      if (!CLAIMABLE.has(t.type)) continue;
      const p = track.prov.get(t);
      if (!p || p.length !== t.content.length) continue;
      for (let k = 0; k < p.length; k++) {
        const at = p[k] >= 0 ? offsets[p[k]] : -1;
        if (at >= 0 && text.charCodeAt(at) === t.content.charCodeAt(k)) claimed.push({ t, k, at });
      }
    }
  }
  if (!claimed.length) return [];
  // The footnote section comes after the block, never inside it.
  const tail = tokens.findIndex((t) => t.type === 'footnote_block_open');
  const body = tail < 0 ? tokens : tokens.slice(0, tail);
  // Sentinels: private-use code points the block does not contain, the BMP's first (one unit each), then planes 15 and 16 (a
  // surrogate pair each: the probe's text is then longer than the page's, readProbe walks both).
  const used = new Set<number>();
  for (const ch of text) {
    const c = ch.codePointAt(0)!;
    if (c >= PUA_FIRST) used.add(c);
  }
  const free: number[] = [];
  for (const [lo, hi] of SENTINEL_RANGES) {
    for (let c = lo; c <= hi && free.length < claimed.length; c++) if (!used.has(c)) free.push(c);
  }
  if (!free.length) return [];
  const probes: InlineProbe[] = [];
  const contents = new Map<Token, string>();
  for (const { t } of claimed) contents.set(t, t.content);
  try {
    for (let from = 0; from < claimed.length; from += free.length) {
      const batch = claimed.slice(from, from + free.length);
      const units = new Map<Token, string[]>();
      for (const { t } of batch) if (!units.has(t)) units.set(t, contents.get(t)!.split(''));
      const sentinels: number[] = [];
      let originals = '';
      const offsets: number[] = [];
      batch.forEach(({ t, k, at }, i) => {
        const u = units.get(t)!;
        originals += u[k];
        u[k] = String.fromCodePoint(free[i]);
        sentinels.push(free[i]);
        offsets.push(at);
      });
      for (const [t, u] of units) t.content = u.join('');
      let html: string;
      try {
        html = md.renderer.render(body, md.options, env);
      } finally {
        if (o.extensions.includes('math')) md.render('', { outline: [] });
      }
      probes.push({ html, sentinels, originals, offsets });
      for (const [t, c] of contents) t.content = c;
    }
  } finally {
    for (const [t, c] of contents) t.content = c;
  }
  return probes;
}

/** The whole document's link reference definitions and footnote labels (block phase only), for blocks that use them. */
export function documentContext(source: string, options: RenderOptions): BlockContext {
  const { md } = instrumented(options);
  const env: Record<string, unknown> = {};
  md.block.parse(source.replace(/\r\n?/g, '\n').replace(/\0/g, '�'), md, env, []);
  const found = env as { references?: Record<string, unknown>; footnotes?: { refs?: Record<string, number> } };
  return { references: found.references, labels: found.footnotes?.refs };
}

export const inlineMap = { probe: probeBlock, context: documentContext };
