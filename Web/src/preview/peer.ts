// Two-way selection (PLAN M2): the editor's selection is shown here as a highlight, and the page's selection goes to the app as a
// source range for the editor to show the same way. Neither side's real selection is touched. Where the source map has no place
// for a character (a block it cannot map, markup only), the whole block stands in.
//
// The highlight is a CSS Custom Highlight (`::highlight(md2-peer)` in the preview styles): ranges over the existing DOM, nothing
// is inserted, so the block patcher never sees it. A render drops it; the app sends the editor's selection again after each one.
import { post } from './bridge.ts';
import type { BlockHandle } from './scroll.ts';
import { lineOf, linesRange, shown } from './shown.ts';
import { handleOf, mapBlock, pointIn, type BlockMapping } from './source-map.ts';
import { bridgeToken } from './tasks.ts';

const NAME = 'md2-peer';

interface HighlightRegistry {
  set(name: string, value: unknown): void;
  delete(name: string): void;
}
declare const Highlight: new (...ranges: Range[]) => unknown;
const registry = (): HighlightRegistry | null => (globalThis as { CSS?: { highlights?: HighlightRegistry } }).CSS?.highlights ?? null;

function wholeBlock(h: BlockHandle): Range {
  const r = document.createRange();
  r.setStartBefore(h.first);
  r.setEndAfter(h.last);
  return r;
}

/** The DOM ranges of the units of `m` whose source offsets fall in [from, to), one per run inside a text node. */
function rangesIn(m: BlockMapping, from: number, to: number): Range[] {
  const out: Range[] = [];
  for (let i = 0; i < m.texts.length; i++) {
    const s = m.starts[i];
    const n = m.texts[i].data.length;
    let run = -1;
    for (let k = s; k <= s + n; k++) {
      const inside = k < s + n && m.offsets[k] >= from && m.offsets[k] < to;
      if (inside && run < 0) run = k;
      else if (!inside && run >= 0) {
        const r = document.createRange();
        r.setStart(m.texts[i], run - s);
        r.setEnd(m.texts[i], k - s);
        out.push(r);
        run = -1;
      }
    }
  }
  return out;
}

/** Blocks whose lines meet lines l0 ..= l1 (the footnote section has none). */
function blocksOnLines(l0: number, l1: number): BlockHandle[] {
  const blocks = shown.blocks;
  let lo = 0;
  let hi = blocks.length;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (blocks[mid].line1 <= l0) lo = mid + 1;
    else hi = mid;
  }
  const out: BlockHandle[] = [];
  for (let i = lo; i < blocks.length && blocks[i].line0 <= l1; i++) if (blocks[i].line0 < blocks[i].line1) out.push(blocks[i]);
  return out;
}

/** Shows source range [from, to) of render `version` (what the editor has selected); returns how many ranges it highlights. A
 *  stale version or an empty range clears the highlight. */
export function highlightSource(from: number, to: number, version: number): number {
  const reg = registry();
  if (!reg) return 0; // lazy: WebKit and Chrome both have the Highlight API; upgrade = marker spans outside #doc's blocks
  reg.delete(NAME);
  if (version !== shown.version || !(from < to) || from < 0 || to > shown.source.length) return 0;
  const ranges: Range[] = [];
  const blocks = blocksOnLines(lineOf(shown.source, from), lineOf(shown.source, to - 1));
  blocks.forEach((h, i) => {
    const [start, end] = linesRange(shown.source, h.line0, h.line1);
    // Blocks inside the selection need no map; only the first and last can be partly selected.
    if ((from <= start && to >= end) || (i > 0 && i < blocks.length - 1)) {
      ranges.push(wholeBlock(h));
      return;
    }
    const m = mapBlock(h);
    const part = m && m.placed ? rangesIn(m, from, to) : [];
    if (part.length) ranges.push(...part);
    else if (to > start && from < end) ranges.push(wholeBlock(h));
  });
  if (ranges.length) reg.set(NAME, new Highlight(...ranges));
  return ranges.length;
}

export function clearHighlight(): void {
  registry()?.delete(NAME);
}

// --- the page's selection -> the editor ---------------------------------------------------------------------------------------

/** The node a boundary point stands for: the node itself, or the child of a container at the offset (the one before, for an end). */
function nodeAt(container: Node, offset: number, end: boolean): Node | null {
  if (container.nodeType === 3 || container.nodeType === 8) return container;
  const kids = container.childNodes;
  if (!kids.length) return container;
  return end ? kids[Math.max(0, offset - 1)] ?? null : kids[Math.min(offset, kids.length - 1)] ?? null;
}

/** The source range of the page's selection, [from, to), or null when there is none in #doc (or nothing of it maps to the source). */
export function selectedSource(): [number, number] | null {
  const sel = getSelection();
  const doc = document.getElementById('doc');
  if (!sel || !doc || sel.rangeCount === 0 || sel.isCollapsed) return null;
  const r = sel.getRangeAt(0);
  if (!doc.contains(r.commonAncestorContainer) && r.commonAncestorContainer !== doc) return null;
  const startNode = nodeAt(r.startContainer, r.startOffset, false);
  const endNode = nodeAt(r.endContainer, r.endOffset, true);
  let hs = startNode ? handleOf(startNode) : null;
  let he = endNode ? handleOf(endNode) : null;
  if (!hs || !he) {
    // An end in something that is not a block (the footnote section): the blocks the selection covers.
    const inside = shown.blocks.filter((h) => h.line0 < h.line1 && r.intersectsNode(h.first));
    hs ??= inside[0] ?? null;
    he ??= inside[inside.length - 1] ?? null;
  }
  if (!hs || !he || hs.line0 >= hs.line1 || he.line0 >= he.line1) return null;
  const [bs] = linesRange(shown.source, hs.line0, hs.line1);
  const [, be] = linesRange(shown.source, he.line0, he.line1);
  let from = bs;
  let to = be;
  const ms = mapBlock(hs);
  const me = hs === he ? ms : mapBlock(he);
  const ps = ms && handleOf(r.startContainer) === hs ? pointIn(ms, r.startContainer, r.startOffset) : null;
  const pe = me && handleOf(r.endContainer) === he ? pointIn(me, r.endContainer, r.endOffset) : null;
  const limit = hs === he && pe ? pe.k : Infinity;
  if (ms && ps) {
    for (let k = ps.k; k < ms.offsets.length && k < limit; k++) {
      if (ms.offsets[k] >= 0) {
        from = ms.offsets[k];
        break;
      }
    }
  }
  if (me && pe) {
    const floor = hs === he && ps ? ps.k : 0;
    for (let k = pe.k - 1; k >= floor; k--) {
      if (me.offsets[k] >= 0) {
        to = me.offsets[k] + 1;
        break;
      }
    }
  }
  if (from >= to) [from, to] = [bs, be]; // nothing in it maps: the blocks
  return [from, to];
}

let muted: () => boolean = () => false;
/** While an edit is on its way the page's text is ahead of the app's: no selection reports then. */
export function muteSelectionWhile(predicate: () => boolean): void {
  muted = predicate;
}

let reported = '';
function report(): void {
  const token = bridgeToken();
  if (!token || muted()) return;
  const range = selectedSource();
  const key = range ? `${shown.version}:${range[0]}:${range[1]}` : '';
  if (key === reported) return;
  reported = key;
  post({ type: 'selection', token, version: shown.version, from: range ? range[0] : -1, to: range ? range[1] : -1 });
}

/** A new render: the next selection report is sent even if it names the same range. */
export function selectionStale(): void {
  reported = '\0';
}

export function startSelectionReporting(): void {
  let queued = false;
  document.addEventListener('selectionchange', () => {
    if (queued) return;
    queued = true;
    // A timer, not a frame: WebKit holds animation frames back while the window is hidden or covered, and the editor still shows it.
    setTimeout(() => {
      queued = false;
      report();
    }, 16);
  });
  // Working in the preview: the editor's selection is no longer the one to show.
  document.addEventListener('mousedown', (e) => {
    if (e.target instanceof Node && document.getElementById('doc')?.contains(e.target)) clearHighlight();
  }, true);
}
