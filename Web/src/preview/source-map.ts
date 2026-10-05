// The inline source map on the page (PLAN M2): for one block on screen, the source offset of each unit of its text (see
// render/inline-map.ts for how a block is probed, text-domain.ts for which text counts). Computed when a selection or an edit
// needs it, for that block only, and remembered while neither the block's text on the page nor its source changes.
//
// The pure parts (checks, where a typed character goes, what an edit does to the source) are exported for the node tests.
import { stripActiveContent } from './links.ts';
import type { BlockHandle } from './scroll.ts';
import { linesRange, shown, type RenderOptionsLike } from './shown.ts';
import { domainTexts, readProbe } from './text-domain.ts';

interface Probe { html: string; sentinels: string; originals: string; offsets: number[] }
interface Context { references?: Record<string, unknown>; labels?: Record<string, number> }
declare const MacDown2: {
  inlineMap?: {
    probe(text: string, options: RenderOptionsLike, first: boolean, context?: Context | null): Probe[];
    context(source: string, options: RenderOptionsLike): Context;
  };
};

export interface BlockMapping {
  handle: BlockHandle;
  texts: Text[];
  starts: number[]; // index in `text` where each text node starts
  text: string; // the block's text (text-domain.ts), as shown
  offsets: Int32Array; // per unit of `text`: its offset in the document's source, or -1
  start: number; // the block's source range [start, end): its lines, without the last newline
  end: number;
  placed: number; // units with an offset
}

// --- pure ---------------------------------------------------------------------------------------------------------------

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

/** The source offset a character typed at unit `k` of the block's text goes to, or -1 when it is not known. `prev` / `next`: the
 *  caret's text node holds unit k-1 / unit k. The character joins the text node the caret is in, so it goes right after the
 *  previous unit's source character when that one is in the caret's node (inside `**bold**` when typed at the end of "bold"),
 *  else right before the next one's. */
export function insertionAt(offsets: Int32Array, k: number, prev: boolean, next: boolean): number {
  if (prev && k > 0 && offsets[k - 1] >= 0) return offsets[k - 1] + 1;
  if (next && k < offsets.length && offsets[k] >= 0) return offsets[k];
  return -1;
}

export type Refusal = 'newline' | 'unmapped' | 'formatting';
export type SourceEdit = { from: number; to: number } | { refused: Refusal };

/** Units [k0, k1) of the block's text replaced by `data` (k0 = k1: typed at the caret), as an edit of the source: the same
 *  characters, or a refusal. A range must cover source characters that follow each other with nothing in between (deleting across
 *  `**` or a link's `](url)` would change the formatting, not the text); a line break typed or deleted is structure. */
export function sourceEdit(offsets: Int32Array, text: string, source: string, k0: number, k1: number, data: string, prev: boolean, next: boolean): SourceEdit {
  if (/[\r\n\u2028\u2029]/.test(data)) return { refused: 'newline' };
  let from: number;
  let to: number;
  if (k0 === k1) {
    from = to = insertionAt(offsets, k0, prev, next);
    if (from < 0) return { refused: 'unmapped' };
  } else {
    for (let k = k0; k < k1; k++) {
      if (offsets[k] < 0) return { refused: text.charCodeAt(k) === 10 ? 'newline' : 'unmapped' };
      if (k > k0 && offsets[k] !== offsets[k - 1] + 1) return { refused: 'formatting' };
    }
    from = offsets[k0];
    to = offsets[k1 - 1] + 1;
  }
  if (splitsPair(source, from) || splitsPair(source, to)) return { refused: 'unmapped' };
  return { from, to };
}

// --- on the page --------------------------------------------------------------------------------------------------------

export function blockNodes(h: BlockHandle): Node[] {
  const out: Node[] = [];
  for (let n: Node | null = h.first; n; n = n.nextSibling) {
    out.push(n);
    if (n === h.last) break;
  }
  return out;
}

let inert: HTMLElement | null = null;
function textOfHTML(html: string): string {
  inert ??= document.implementation.createHTMLDocument('').createElement('div');
  inert.innerHTML = html;
  stripActiveContent(inert);
  const text = domainTexts(inert.childNodes as unknown as ArrayLike<Text>).map((t) => t.data).join('');
  inert.replaceChildren();
  return text;
}

let context: { source: string; options: string; value: Context } | null = null;
function documentContext(options: RenderOptionsLike): Context {
  if (context?.source === shown.source && context.options === shown.optionsJSON) return context.value;
  const value = MacDown2.inlineMap!.context(shown.source, options);
  context = { source: shown.source, options: shown.optionsJSON, value };
  return value;
}

interface Cached { text: string; blockText: string; options: string; first: boolean; rel: Int32Array | null }
const cache = new WeakMap<BlockHandle, Cached>();

function probeRel(live: string, blockText: string, first: boolean, options: RenderOptionsLike): Int32Array | null {
  const map = MacDown2.inlineMap!;
  let probes = map.probe(blockText, options, first, null);
  if (!probes.length) return null;
  let rel = readProbes(live, probes, textOfHTML);
  if (!rel) {
    // Link references and footnotes defined elsewhere in the document: probe again with them.
    probes = map.probe(blockText, options, first, documentContext(options));
    rel = readProbes(live, probes, textOfHTML);
  }
  return rel && settle(rel, live, blockText) ? rel : null;
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

/** The map of a block on screen (null: plain Markdown only, and not for the footnote section); every unit may be -1. */
export function mapBlock(h: BlockHandle): BlockMapping | null {
  const options = shown.options;
  if (!options || options.flavor !== 'markdown' || !MacDown2.inlineMap || h.line0 >= h.line1) return null;
  const { texts, starts, text } = blockText(h);
  const [start, end] = linesRange(shown.source, h.line0, h.line1);
  const source = shown.source.slice(start, end);
  const first = h.line0 === 0;
  const c = cache.get(h);
  let rel: Int32Array | null;
  if (c && c.text === text && c.blockText === source && c.options === shown.optionsJSON && c.first === first) rel = c.rel;
  else {
    try {
      rel = probeRel(text, source, first, options);
    } catch {
      rel = null; // whatever went wrong, the block is unmappable
    }
    cache.set(h, { text, blockText: source, options: shown.optionsJSON, first, rel });
  }
  const offsets = new Int32Array(text.length).fill(-1);
  let placed = 0;
  if (rel) {
    for (let k = 0; k < rel.length; k++) {
      if (rel[k] < 0) continue;
      offsets[k] = rel[k] + start;
      placed++;
    }
  }
  return { handle: h, texts, starts, text, offsets, start, end, placed };
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
export function pointAt(m: BlockMapping, k: number, after: boolean): { node: Text; offset: number } | null {
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
