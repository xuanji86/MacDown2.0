// DOM side of scroll sync: line <-> y over the live blocks, and the rAF-throttled "top visible line" report.
// Two levels: top-level blocks (binary search), then the data-line leaves inside the block that was hit
// (long lists, tables, quoted runs), so a 300-line list does not scroll linearly across its whole height.
import { post } from './bridge.ts';
import { lastLE, lineToY, yToLine, type Anchor } from './scroll-map.ts';

// One top-level block as it sits in the page: the nodes first..last (last is the marker comment) and its source lines.
export interface BlockHandle {
  first: Node;
  last: Node;
  line0: number;
  line1: number;
  leaves?: HTMLElement[];
}

/** A block's nodes, first ..= last (the marker comment). The one walk over a block every module uses. */
export function blockNodes(h: BlockHandle): Node[] {
  const out: Node[] = [];
  for (let n: Node | null = h.first; n; n = n.nextSibling) {
    out.push(n);
    if (n === h.last) break;
  }
  return out;
}

export const elements = (h: BlockHandle): HTMLElement[] => blockNodes(h).filter((n): n is HTMLElement => n.nodeType === 1);

// Deepest elements carrying data-line, in document order (cached until the block is replaced).
function leavesOf(h: BlockHandle): HTMLElement[] {
  if (h.leaves) return h.leaves;
  const out: HTMLElement[] = [];
  for (const el of elements(h)) {
    const marked = el.hasAttribute('data-line') ? [el, ...el.querySelectorAll<HTMLElement>('[data-line]')] : [...el.querySelectorAll<HTMLElement>('[data-line]')];
    for (const m of marked) if (!m.querySelector('[data-line]')) out.push(m);
  }
  return (h.leaves = out);
}

const boxOf = (el: Element): { top: number; bottom: number } => {
  const r = el.getBoundingClientRect();
  return { top: r.top + scrollY, bottom: r.bottom + scrollY };
};

function blockAnchor(blocks: BlockHandle[], i: number): Anchor {
  const h = blocks[i];
  const els = elements(h);
  if (els.length) return { line0: h.line0, line1: h.line1, top: boxOf(els[0]).top, bottom: boxOf(els[els.length - 1]).bottom };
  // comment-only block: no box, sits where the next block starts
  for (let j = i + 1; j < blocks.length; j++) {
    const next = elements(blocks[j]);
    if (next.length) {
      const top = boxOf(next[0]).top;
      return { line0: h.line0, line1: h.line1, top, bottom: top };
    }
  }
  const end = document.documentElement.scrollHeight;
  return { line0: h.line0, line1: h.line1, top: end, bottom: end };
}

function leafAnchor(leaves: HTMLElement[], i: number): Anchor {
  const el = leaves[i];
  return { line0: Number(el.getAttribute('data-line')), line1: Number(el.getAttribute('data-line-end')), ...boxOf(el) };
}

// y of the top of source line `line` (fractional ok), in page coordinates.
export function lineToPageY(blocks: BlockHandle[], line: number): number {
  const n = blocks.length;
  const y = lineToY(line, n, (i) => blockAnchor(blocks, i));
  const hit = lastLE(n, (i) => blocks[i].line0, line);
  if (hit < 0 || line >= blocks[hit].line1) return y;
  const leaves = leavesOf(blocks[hit]);
  if (leaves.length < 2 || line < leafAnchor(leaves, 0).line0 || line >= leafAnchor(leaves, leaves.length - 1).line1) return y;
  return lineToY(line, leaves.length, (i) => leafAnchor(leaves, i));
}

// Source line at page height `y`.
export function pageYToLine(blocks: BlockHandle[], y: number): number {
  const n = blocks.length;
  const line = yToLine(y, n, (i) => blockAnchor(blocks, i));
  const hit = lastLE(n, (i) => blockAnchor(blocks, i).top, y);
  if (hit < 0 || y >= blockAnchor(blocks, hit).bottom) return line;
  const leaves = leavesOf(blocks[hit]);
  if (leaves.length < 2 || y < leafAnchor(leaves, 0).top || y >= leafAnchor(leaves, leaves.length - 1).bottom) return line;
  return yToLine(y, leaves.length, (i) => leafAnchor(leaves, i));
}

// Scroll anchoring. WebKit has none (and the preview style switches Chrome's off), so when the layout moves under a
// still viewport (an image or a Mermaid diagram above it arrives, KaTeX fonts change a formula's size, the window is
// resized) the content that was at the top would drift away from the line the editor shows. The anchor is the element
// at the top of the viewport and how far into it the viewport top lies; a ResizeObserver puts it back after the layout
// settled. It is recorded on every scroll and after each render (main.ts), never in between, so a render that
// inserts or removes blocks does not move the page by itself, only late layout changes do.
interface ScrollAnchor {
  el: HTMLElement;
  offset: number;
}
let anchor: ScrollAnchor | null = null;

export function recordAnchor(blocks: BlockHandle[]): void {
  const y = scrollY;
  const n = blocks.length;
  const hit = lastLE(n, (i) => blockAnchor(blocks, i).top, y);
  if (hit < 0) {
    anchor = null;
    return;
  }
  const leaves = leavesOf(blocks[hit]);
  const k = lastLE(leaves.length, (i) => leafAnchor(leaves, i).top, y);
  const el = k >= 0 ? leaves[k] : elements(blocks[hit])[0];
  anchor = el ? { el, offset: y - boxOf(el).top } : null;
}

function reanchor(): void {
  if (!anchor?.el.isConnected) return; // replaced by a render: the next recordAnchor picks a new one
  const want = Math.max(0, Math.round(boxOf(anchor.el).top + anchor.offset));
  if (Math.abs(want - scrollY) < 1) return;
  scrollTo({ top: want, behavior: 'instant' });
  programmaticY = scrollY; // the page moved itself: not a user scroll, nothing to report
}

export function startAnchoring(article: HTMLElement): void {
  new ResizeObserver(reanchor).observe(article);
}

// Scroll the page so source line `line` is at the top. Instant (no animation); the scroll event it causes is
// not reported back, so the native side can drive the preview without echo.
let programmaticY: number | null = null;
export function scrollToLine(blocks: BlockHandle[], line: number): void {
  const y = Math.max(0, Math.round(lineToPageY(blocks, line)));
  if (Math.abs(y - scrollY) < 1) return;
  scrollTo({ top: y, behavior: 'instant' });
  programmaticY = scrollY;
  recordAnchor(blocks);
}

// Reports the top visible line to Swift on user scrolling: at most once per animation frame, only when it moved.
export function startScrollReporting(getBlocks: () => BlockHandle[]): void {
  let queued = false;
  let last = -1;
  addEventListener(
    'scroll',
    () => {
      if (queued) return;
      queued = true;
      requestAnimationFrame(() => {
        queued = false;
        const echo = programmaticY !== null && Math.abs(scrollY - programmaticY) < 1;
        programmaticY = null;
        if (!echo) recordAnchor(getBlocks()); // a programmatic scroll recorded its own anchor when it happened, before any layout shift
        if (echo) {
          last = -1; // the native side moved us; the next user scroll reports even if it lands on an old value
          return;
        }
        const line = Math.round(pageYToLine(getBlocks(), scrollY) * 100) / 100;
        if (line === last) return;
        last = line;
        post({ type: 'scroll', line });
      });
    },
    { passive: true },
  );
}
