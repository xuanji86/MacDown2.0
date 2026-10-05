// The inline source map on the page (PLAN M2): for one block on screen, the source offset of each unit of its text (see
// render/inline-map.ts for how a block is probed, text-domain.ts for which text counts). Computed when a selection or an edit
// needs it, for that block only, and remembered while neither the block's text on the page nor its source changes.
//
// The pure parts (checks, where a typed character goes, what an edit does to the source, moving a map through edits, whether an
// edit shows as typed) are exported for the node tests.
import { stripActiveContent } from './links.ts';
import { blockNodes, type BlockHandle } from './scroll.ts';
import { linesRange, shown, type RenderOptionsLike } from './shown.ts';
import { domainTexts, readProbe } from './text-domain.ts';

interface Probe { html: string; sentinels: number[]; originals: string; offsets: number[] }
interface Context { references?: Record<string, unknown>; labels?: Record<string, number> }
declare const MacDown2: {
  inlineMap?: {
    probe(text: string, options: RenderOptionsLike, first: boolean, context?: Context | null): Probe[];
    render(text: string, options: RenderOptionsLike, first: boolean, context?: Context | null): string;
    context(source: string, options: RenderOptionsLike): Context;
  };
};

export interface BlockMapping {
  handle: BlockHandle;
  texts: Text[];
  starts: number[]; // index in `text` where each text node starts
  text: string; // the block's text (text-domain.ts), as shown
  offsets: Int32Array; // per unit of `text`: where its source starts, or -1
  widths: Uint8Array | null; // per unit: how many source units it takes (a backslash escape typed here: 2); null = 1 each
  start: number; // the block's source range [start, end): its lines, without the last newline
  end: number;
  placed: number; // units with an offset
  context: boolean; // the probe needed the document's definitions (link references, footnotes)
}

// --- pure ---------------------------------------------------------------------------------------------------------------

/** Line breaks, as both sides count them (PreviewEditChain.swift has the same set): typing or deleting one is structure. */
export const NEWLINE = new RegExp('[\n\r\v\f' + String.fromCharCode(0x85, 0x2028, 0x2029) + ']');

/** What the page requires of a probe's answer (block-relative `rel`): placed units in strictly increasing source order, each the
 *  very character the source has there. */
export function settle(rel: Int32Array, live: string, blockText: string): boolean {
  let last = -1;
  for (let k = 0; k < rel.length; k++) {
    const o = rel[k];
    if (o < 0) continue;
    if (o <= last || blockText.charCodeAt(o) !== live.charCodeAt(k)) return false;
    last = o;
  }
  return true;
}

/** Every probe of a block read against the page's text: null if any of them disagrees with it. */
export function readProbes(live: string, probes: Probe[], textOf: (html: string) => string): Int32Array | null {
  if (!probes.length) return null;
  let out: Int32Array | null = null;
  for (const p of probes) {
    const r = readProbe(live, textOf(p.html), p);
    if (!r) return null;
    if (!out) out = r;
    else for (let k = 0; k < r.length; k++) if (r[k] >= 0) out[k] = r[k];
  }
  return out;
}

const isLow = (c: number): boolean => c >= 0xdc00 && c <= 0xdfff;
const isHigh = (c: number): boolean => c >= 0xd800 && c <= 0xdbff;
/** Offset `at` falls between the two halves of a surrogate pair. */
export const splitsPair = (s: string, at: number): boolean => at > 0 && at < s.length && isHigh(s.charCodeAt(at - 1)) && isLow(s.charCodeAt(at));

const width = (m: Pick<BlockMapping, 'widths'>, k: number): number => (m.widths ? m.widths[k] || 1 : 1);

/** The source offset a character typed at unit `k` of the block's text goes to, or -1 when it is not known. `prev` / `next`: the
 *  caret's text node holds unit k-1 / unit k. The character joins the text node the caret is in, so it goes right after the
 *  previous unit's source when that one is in the caret's node (inside `**bold**` when typed at the end of "bold"), else right
 *  before the next one's. */
export function insertionAt(m: Pick<BlockMapping, 'offsets' | 'widths'>, k: number, prev: boolean, next: boolean): number {
  const o = m.offsets;
  if (prev && k > 0 && o[k - 1] >= 0) return o[k - 1] + width(m, k - 1);
  if (next && k < o.length && o[k] >= 0) return o[k];
  return -1;
}

export type Refusal = 'newline' | 'unmapped' | 'formatting';
export type SourceEdit = { from: number; to: number } | { refused: Refusal };

/** Units [k0, k1) of the block's text replaced by `data` (k0 = k1: typed at the caret), as an edit of the source: the same
 *  characters, or a refusal. A range must cover source characters that follow each other with nothing in between (deleting across
 *  `**` or a link's `](url)` would change the formatting, not the text); a line break typed or deleted is structure. The source
 *  characters the edit removes must be the shown ones (`source` is the text the edit applies to). */
export function sourceEdit(m: Pick<BlockMapping, 'offsets' | 'widths' | 'text'>, source: string, k0: number, k1: number, data: string, prev: boolean, next: boolean): SourceEdit {
  if (NEWLINE.test(data)) return { refused: 'newline' };
  const o = m.offsets;
  let from: number;
  let to: number;
  if (k0 === k1) {
    from = to = insertionAt(m, k0, prev, next);
    if (from < 0) return { refused: 'unmapped' };
    // the neighbour it is placed by must be in the source where the map says
    const k = prev && k0 > 0 && o[k0 - 1] >= 0 ? k0 - 1 : k0;
    if (source.charCodeAt(o[k] + width(m, k) - 1) !== m.text.charCodeAt(k)) return { refused: 'unmapped' };
  } else {
    for (let k = k0; k < k1; k++) {
      if (o[k] < 0) return { refused: NEWLINE.test(m.text[k]) ? 'newline' : 'unmapped' };
      if (k > k0 && o[k] !== o[k - 1] + width(m, k - 1)) return { refused: 'formatting' };
      // what is there must be what is shown (an escape `\*` shows as its second character)
      const w = width(m, k);
      if (source.charCodeAt(o[k] + w - 1) !== m.text.charCodeAt(k)) return { refused: 'unmapped' };
    }
    from = o[k0];
    to = o[k1 - 1] + width(m, k1 - 1);
  }
  if (from < 0 || to > source.length || splitsPair(source, from) || splitsPair(source, to)) return { refused: 'unmapped' };
  return { from, to };
}

/** One edit of a burst: source [from, to) of the text before it replaced by `len` units. */
export interface BurstEdit { from: number; to: number; len: number }

/** A map of the render on screen moved into the text with a burst's edits made (they were in other blocks), or null when one of
 *  them reached into this block. */
export function rebase<M extends Pick<BlockMapping, 'offsets' | 'start' | 'end' | 'placed'>>(m: M, edits: readonly BurstEdit[]): M | null {
  if (!edits.length) return m;
  let start = m.start;
  let end = m.end;
  for (const e of edits) {
    // an edit that reaches into the block (or types inside it) means the block is not the one this map was made of
    if ((e.to > start && e.from < end) || (e.from === e.to && e.from > start && e.from < end)) return null;
    if (e.from >= end) continue;
    const delta = e.len - (e.to - e.from);
    start += delta;
    end += delta;
  }
  const offsets = m.offsets.map((o) => (o >= 0 ? o + start - m.start : -1));
  return { ...m, offsets, start, end };
}

/** The same map after its units [k0, k1) were replaced by `data` (`units`: the source offsets the new units start at, -1 for
 *  none; `widths` theirs) and the source by `delta` units: the units after the edit move with the source. */
export function edited<M extends BlockMapping>(m: M, k0: number, k1: number, units: number[], widths: number[], delta: number, now: Pick<BlockMapping, 'texts' | 'starts' | 'text'>): M {
  const n = now.text.length;
  const offsets = new Int32Array(n);
  const w = new Uint8Array(n).fill(1);
  offsets.set(m.offsets.subarray(0, k0), 0);
  if (m.widths) w.set(m.widths.subarray(0, k0), 0);
  units.forEach((o, i) => {
    offsets[k0 + i] = o;
    w[k0 + i] = widths[i];
  });
  for (let k = k1; k < m.offsets.length; k++) {
    const j = k - k1 + k0 + units.length;
    offsets[j] = m.offsets[k] >= 0 ? m.offsets[k] + delta : -1;
    w[j] = width(m, k);
  }
  let placed = 0;
  for (let k = 0; k < n; k++) if (offsets[k] >= 0) placed++;
  return { ...m, ...now, offsets, widths: w.some((x) => x !== 1) ? w : null, end: m.end + delta, placed };
}

/** The map of another block moved past an edit (source up to `to` replaced, `delta` = new length - old): blocks after it move. */
export function shifted<M extends BlockMapping>(m: M, to: number, delta: number): M {
  if (m.start < to || delta === 0) return m;
  return { ...m, offsets: m.offsets.map((o) => (o >= 0 ? o + delta : -1)), start: m.start + delta, end: m.end + delta };
}

// ASCII punctuation: every character a backslash escapes in CommonMark.
const ESCAPABLE = /[!-/:-@[-`{-~]/g;
const squeeze = (s: string): string => s.replace(/[ \t]/g, '');
export interface Rendered { text: string; tags: string }

/** What to put into the source for `data` typed over source [from, to) of the block [start, end) so that the block shows exactly
 *  `expected` (its shown text with the edit made) in the same markup as `before` (the block rendered as it is): `data` itself, or
 *  with its ASCII punctuation backslash-escaped (`*` -> `\*`, `|` -> `\|`, `<` -> `\<`); null when neither does, or for a deletion
 *  that would change more than the deleted characters. Spaces and tabs are left out of the text comparison: Markdown hides them at
 *  the ends of lines (a space typed after the last word shows only with the next one), and they never carry markup alone.
 *  `units`: per unit of `data`, its offset in the inserted text (-1: an escape), `widths` the source units each takes.
 *  lazy: one or two renders of the whole block per edit (measured: a 1.2 KB paragraph 0.8 ms, a 92 KB list 20 ms; blocks over
 *  MAX_BLOCK never get here); upgrade = render only the edited inline run (list item, table cell) when big blocks are edited a lot. */
export function literalEdit(
  source: string, start: number, end: number, from: number, to: number, data: string, expected: string, before: Rendered,
  render: (block: string) => Rendered,
): { insert: string; units: number[]; widths: number[] } | null {
  const block = (insert: string): string => source.slice(start, from) + insert + source.slice(to, end);
  const shows = (insert: string): boolean => {
    const r = render(block(insert));
    return r.tags === before.tags && squeeze(r.text) === squeeze(expected);
  };
  if (shows(data)) return { insert: data, units: Array.from({ length: data.length }, (_, i) => i), widths: new Array(data.length).fill(1) };
  if (!data) return null;
  let insert = '';
  const units: number[] = [];
  const widths: number[] = [];
  for (let i = 0; i < data.length; i++) {
    const c = data[i];
    ESCAPABLE.lastIndex = 0;
    if (ESCAPABLE.test(c)) {
      units.push(insert.length);
      widths.push(2);
      insert += `\\${c}`;
    } else {
      units.push(insert.length);
      widths.push(1);
      insert += c;
    }
  }
  return insert !== data && shows(insert) ? { insert, units, widths } : null;
}

// --- on the page --------------------------------------------------------------------------------------------------------

let inert: HTMLElement | null = null;
function parsedText(html: string): { text: string; tags: string } {
  inert ??= document.implementation.createHTMLDocument('').createElement('div');
  inert.innerHTML = html;
  stripActiveContent(inert);
  const text = domainTexts(inert.childNodes as unknown as ArrayLike<Text>).map((t) => t.data).join('');
  const tags = Array.from(inert.querySelectorAll('*'), (e) => e.localName).join(' ');
  inert.replaceChildren();
  return { text, tags };
}
const textOfHTML = (html: string): string => parsedText(html).text;

// The document's definitions (link references, footnote labels), per text. Edits made here never change them: a definition is not a
// block the page edits, and an edit that would make or unmake one changes the block's markup, which the page refuses. So the render
// that catches up with a burst keeps them (`carryContext`); only a text from elsewhere (the editor, the disk) is parsed again.
let context: { source: string; options: string; value: Context } | null = null;
function documentContext(options: RenderOptionsLike): Context {
  if (context?.source === shown.source && context.options === shown.optionsJSON) return context.value;
  const value = MacDown2.inlineMap!.context(shown.source, options);
  context = { source: shown.source, options: shown.optionsJSON, value };
  return value;
}

/** editing.ts: the render of `to` that is about to replace `from` on the page is `from` with this page's edits made. */
export function carryContext(from: string, to: string): void {
  if (context?.source === from) context.source = to;
}

interface Cached { text: string; blockText: string; options: string; first: boolean; rel: Int32Array | null; context: boolean }
// lazy: a block is probed whole (measured: a 2 KB paragraph 2-4 ms, an 80 KB list of 1800 items about 40-70 ms, again after every
// edit in it); past this it is unmappable; upgrade = probe the list item or table row that holds the caret instead of the block.
const MAX_BLOCK = 64 * 1024;
const cache = new WeakMap<BlockHandle, Cached>();

function probeRel(live: string, blockText: string, first: boolean, options: RenderOptionsLike): { rel: Int32Array | null; context: boolean } {
  const map = MacDown2.inlineMap!;
  let probes = map.probe(blockText, options, first, null);
  if (!probes.length) return { rel: null, context: false };
  let rel = readProbes(live, probes, textOfHTML);
  let context = false;
  if (!rel) {
    // Link references and footnotes defined elsewhere in the document: probe again with them.
    probes = map.probe(blockText, options, first, documentContext(options));
    rel = readProbes(live, probes, textOfHTML);
    context = true;
  }
  return { rel: rel && settle(rel, live, blockText) ? rel : null, context };
}

/** The block's text as the page shows it, with node boundaries. */
export function blockText(h: BlockHandle): { texts: Text[]; starts: number[]; text: string } {
  const texts = domainTexts(blockNodes(h) as unknown as ArrayLike<Text>);
  const starts: number[] = [];
  let text = '';
  for (const t of texts) {
    starts.push(text.length);
    text += t.data;
  }
  return { texts, starts, text };
}

/** The map of a block on screen, in the source of the render on screen (null: plain Markdown only, and not for the footnote
 *  section); every unit may be -1. */
export function mapBlock(h: BlockHandle): BlockMapping | null {
  const options = shown.options;
  if (!options || options.flavor !== 'markdown' || !MacDown2.inlineMap || h.line0 >= h.line1) return null;
  const { texts, starts, text } = blockText(h);
  const [start, end] = linesRange(shown.source, h.line0, h.line1);
  const source = shown.source.slice(start, end);
  const first = h.line0 === 0;
  let c = cache.get(h);
  if (!c || c.text !== text || c.blockText !== source || c.options !== shown.optionsJSON || c.first !== first) {
    let found: { rel: Int32Array | null; context: boolean } = { rel: null, context: false };
    if (source.length <= MAX_BLOCK) {
      try {
        found = probeRel(text, source, first, options);
      } catch {
        // whatever went wrong, the block is unmappable
      }
    }
    c = { text, blockText: source, options: shown.optionsJSON, first, ...found };
    cache.set(h, c);
  }
  const offsets = new Int32Array(text.length).fill(-1);
  let placed = 0;
  if (c.rel) {
    for (let k = 0; k < c.rel.length; k++) {
      if (c.rel[k] < 0) continue;
      offsets[k] = c.rel[k] + start;
      placed++;
    }
  }
  return { handle: h, texts, starts, text, offsets, widths: null, start, end, placed, context: c.context };
}

/** The block's source `text` rendered on its own with the document's definitions (a `[^1]` typed must find the footnote defined
 *  elsewhere): its text and its elements. A text without `[` cannot use a definition, and is rendered without them. */
export function renderedBlock(text: string, m: Pick<BlockMapping, 'handle'>): Rendered {
  const options = shown.options!;
  const html = MacDown2.inlineMap!.render(text, options, m.handle.line0 === 0, text.includes('[') ? documentContext(options) : null);
  return parsedText(html);
}

/** A DOM point inside the block's text as a unit index and the text node it is in (a point between nodes, or in an element, is
 *  moved to the start of the text node after it, or the end of the one before it when there is none); null when it is not in the
 *  block's text. */
export function pointIn(m: BlockMapping, node: Node, offset: number): { k: number; node: Text; offset: number; prev: boolean; next: boolean } | null {
  if (node.nodeType === 3) {
    const i = m.texts.indexOf(node as Text);
    if (i < 0) return null;
    const len = (node as Text).data.length;
    return { k: m.starts[i] + offset, node: node as Text, offset, prev: offset > 0, next: offset < len };
  }
  const at = document.createRange();
  try {
    at.setStart(node, offset);
  } catch {
    return null;
  }
  // the first text node at or after the point
  let i = 0;
  while (i < m.texts.length && at.comparePoint(m.texts[i], 0) < 0) i++;
  if (i < m.texts.length) return { k: m.starts[i], node: m.texts[i], offset: 0, prev: false, next: m.texts[i].data.length > 0 };
  if (i > 0) {
    const t = m.texts[i - 1];
    return { k: m.starts[i - 1] + t.data.length, node: t, offset: t.data.length, prev: t.data.length > 0, next: false };
  }
  return null;
}

/** The DOM point at unit `k` of the block's text: in the node that holds unit k-1 when `after` (typing continues it), else unit k's. */
export function pointAt(m: Pick<BlockMapping, 'texts' | 'starts' | 'text'>, k: number, after: boolean): { node: Text; offset: number } | null {
  if (!m.texts.length) return null;
  for (let i = 0; i < m.texts.length; i++) {
    const s = m.starts[i];
    const e = s + m.texts[i].data.length;
    if (after ? k > s && k <= e : k >= s && k < e) return { node: m.texts[i], offset: k - s };
  }
  const last = m.texts[m.texts.length - 1];
  if (k >= m.text.length) return { node: last, offset: last.data.length };
  return { node: m.texts[0], offset: 0 };
}

/** The block that holds `node` (a node inside #doc), by binary search over the blocks in document order. */
export function handleOf(node: Node): BlockHandle | null {
  const blocks = shown.blocks;
  let lo = 0;
  let hi = blocks.length - 1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    const h = blocks[mid];
    const before = h.first.compareDocumentPosition(node);
    if (h.first !== node && before & Node.DOCUMENT_POSITION_PRECEDING) hi = mid - 1;
    else {
      const after = h.last.compareDocumentPosition(node);
      if (h.last !== node && after & Node.DOCUMENT_POSITION_FOLLOWING && !(after & Node.DOCUMENT_POSITION_CONTAINED_BY)) lo = mid + 1;
      else return h;
    }
  }
  return null;
}
