// Preview page entry. Bundled as an IIFE exposing `globalThis.MacDown2Preview`; render.bundle.js
// (global `MacDown2`) is loaded before it.
//
// update(md, options) renders, then either replaces article#doc (first load, option/flavor change, or when the
// HTML cannot be cut into the renderer's blocks) or patches it block by block: unchanged top-level blocks keep
// their DOM nodes (selection, image decode, scroll position, hover state all survive), only changed ones are
// swapped. Each block's nodes are followed by an invisible <!--md2--> comment so a block can be found again.
import { errorText, post } from './bridge.ts';
import { loadChunk } from './chunk-loader.ts';
import { planPatch } from './dom-patch.ts';
import { rewriteImages } from './images.ts';
import { rewriteLinks, startAnchorScrolling, stripActiveContent } from './links.ts';
import { renderMermaid } from './mermaid-loader.ts';
import { pageYToLine, recordAnchor, scrollToLine as scrollBlocksToLine, startAnchoring, startScrollReporting, type BlockHandle } from './scroll.ts';
import { alignSegments, splitBlocks, type Segment } from './split-html.ts';
import { DEFAULT_STYLE, styleLinks } from './styles.ts';
import { enableTaskCheckboxes, focusedTaskLine, restoreTaskFocus, setRenderVersion, startTaskToggling } from './tasks.ts';

// The app hands over its per-load token and, after refusing a toggle, asks the page to take back what the user flipped.
export { resyncTasks, setTaskToken } from './tasks.ts';

interface RenderBlock { lineStart: number; lineEnd: number; hash: number }
type Lines = Pick<RenderBlock, 'lineStart' | 'lineEnd'>
// `segments`: the HTML already cut into its blocks (renderIncremental does it per section), what alignSegments would return.
interface RenderResult { html: string; blocks: RenderBlock[]; outline: unknown[]; stats: unknown; segments?: Segment[] | null }
declare const MacDown2: {
  renderResult(source: string, options: unknown): RenderResult;
  renderIncremental?(source: string, options: unknown): RenderResult;
  incremental?: { configure(settings: { crossCheckEvery?: number; onMismatch?: (message: string) => void }): void };
};

// Debug builds of the app put `<meta name="md2-render-crosscheck" content="N">` into the page (PreviewAssetHandler): every N-th
// incremental render is then compared with a whole render, and a difference is reported like any other page error.
const crossCheck = Number(document.querySelector('meta[name="md2-render-crosscheck"]')?.getAttribute('content') ?? 0);
if (crossCheck > 0) {
  MacDown2.incremental?.configure({ crossCheckEvery: crossCheck, onMismatch: (message) => post({ type: 'error', stage: 'render', message }) });
}

const MARK = '<!--md2-->';
const doc = (): HTMLElement => document.getElementById('doc')!;
const errorBar = (): HTMLElement => document.getElementById('error')!;

interface State {
  options: string; // optionsJSON the DOM was built with; a different one means a full rebuild
  keys: number[]; // per block: content hash (data-line ignored) + line span
  blocks: BlockHandle[];
}
let state: State | null = null;

// Parsing happens in an inert document: images there do not load, so rewritten src values are the only ones fetched.
const scratch = document.implementation.createHTMLDocument('').createElement('div');
let docBase: string | null = null; // the document folder as a file URL with a trailing slash; relative links resolve against it
function parse(html: string): Node[] {
  scratch.innerHTML = html;
  stripActiveContent(scratch);
  rewriteImages(scratch);
  rewriteLinks(scratch, docBase);
  enableTaskCheckboxes(scratch);
  const nodes = Array.from(scratch.childNodes);
  scratch.replaceChildren();
  return nodes;
}

function handlesFrom(nodes: Node[]): BlockHandle[] {
  const out: BlockHandle[] = [];
  let first: Node | null = null;
  for (const n of nodes) {
    first ??= n;
    if (n.nodeType === 8 && (n as Comment).data === 'md2') {
      out.push({ first, last: n, line0: 0, line1: 0 });
      first = null;
    }
  }
  return out;
}

function remove(h: BlockHandle): void {
  for (let n: Node | null = h.first; n; ) {
    const next: Node | null = n.nextSibling;
    (n as ChildNode).remove();
    if (n === h.last) break;
    n = next;
  }
}

// Shift data-line / data-line-end of a kept block by `delta` lines (something above it gained or lost lines).
function shiftLines(h: BlockHandle, delta: number): void {
  for (let n: Node | null = h.first; n; n = n.nextSibling) {
    if (n.nodeType === 1) {
      const el = n as Element;
      for (const t of [el, ...el.querySelectorAll('[data-line]')]) {
        for (const attr of ['data-line', 'data-line-end']) {
          const v = t.getAttribute(attr);
          if (v !== null) t.setAttribute(attr, String(Number(v) + delta));
        }
      }
    }
    if (n === h.last) break;
  }
}

// Source lines per segment; the footnote tail has no block, it sits at the end of the last one.
function linesOf(segs: Segment[], blocks: RenderBlock[]): Lines[] {
  const end = blocks.length ? blocks[blocks.length - 1].lineEnd : 0;
  return segs.map((s, j) => (s.tail ? { lineStart: end, lineEnd: end } : blocks[j]));
}

const keyOf = (s: Segment, l: Lines): number => s.hash + l.lineEnd - l.lineStart;

function replaceAll(html: string, segs: Segment[] | null, lines: Lines[] | null, options: string): void {
  const y = scrollY;
  const nodes = parse(segs ? segs.map((s) => html.slice(s.start, s.end) + MARK).join('') : html);
  const handles = segs ? handlesFrom(nodes) : [];
  const frag = document.createDocumentFragment();
  for (const n of nodes) frag.appendChild(n);
  doc().replaceChildren(frag);
  scrollTo({ top: y, behavior: 'instant' });
  if (segs && handles.length === segs.length) {
    handles.forEach((h, j) => ((h.line0 = lines![j].lineStart), (h.line1 = lines![j].lineEnd)));
    state = { options, keys: segs.map((s, j) => keyOf(s, lines![j])), blocks: handles };
  } else state = null; // a user comment spelled <!--md2--> got in the way: show it, patch next time
}

// Returns how many blocks were created.
function patch(html: string, segs: Segment[], lines: Lines[], st: State): number {
  const keys = segs.map((s, j) => keyOf(s, lines[j]));
  const { prefix, suffix, matches } = planPatch(st.keys, keys);
  const old = st.blocks;
  const n = old.length;
  const m = keys.length;
  const kept = new Map(matches.map(([i, j]) => [j, i]));
  const keptOld = new Set(kept.values());
  for (let i = prefix; i < n - suffix; i++) if (!keptOld.has(i)) remove(old[i]);

  const next: BlockHandle[] = new Array(m);
  for (let j = 0; j < prefix; j++) next[j] = old[j];
  for (let k = 0; k < suffix; k++) next[m - 1 - k] = old[n - 1 - k];
  let anchor: Node | null = suffix ? next[m - suffix].first : null; // insert before this; null = append
  let created = 0;
  for (let j = m - suffix - 1; j >= prefix; j--) {
    const reuse = kept.get(j);
    if (reuse !== undefined) next[j] = old[reuse];
    else {
      const nodes = parse(html.slice(segs[j].start, segs[j].end) + MARK);
      const [h] = handlesFrom(nodes);
      if (!h) throw new Error('block lost its marker');
      h.line0 = lines[j].lineStart; // fresh HTML already carries the new data-line values
      for (const node of nodes) doc().insertBefore(node, anchor);
      next[j] = h;
      created++;
    }
    anchor = next[j].first;
  }
  for (let j = 0; j < m; j++) {
    const h = next[j];
    if (!segs[j].tail && h.line0 !== lines[j].lineStart) shiftLines(h, lines[j].lineStart - h.line0);
    h.line0 = lines[j].lineStart;
    h.line1 = lines[j].lineEnd;
  }
  st.keys = keys;
  st.blocks = next;
  return created;
}

// Renders `md` into article#doc and returns the metadata JSON ({blocks, outline, stats, perf}) without the html.
// `version` is the app's counter for this render; checkbox clicks carry it back so the app knows which text the page shows.
// On a render failure the previous content stays, the error bar shows the message, the error goes to Swift over
// the bridge, and `{error}` is returned.
export function update(md: string, optionsJSON: string, version = 0): string {
  const t0 = performance.now();
  const focusedTask = focusedTaskLine();
  try {
    const options = JSON.parse(optionsJSON) as { flavor: string };
    const { html, segments, ...meta } = (MacDown2.renderIncremental ?? MacDown2.renderResult)(md, options);
    const t1 = performance.now();
    const usable = segments !== undefined ? segments : alignSegments(html, splitBlocks(html), meta.blocks.length);
    const lines = usable && linesOf(usable, meta.blocks);
    const t2 = performance.now();
    let mode: 'full' | 'patch' | 'full-unsplit' = 'full';
    let created = 0;
    if (!usable) {
      replaceAll(html, null, null, optionsJSON);
      mode = 'full-unsplit';
    } else if (state && state.options === optionsJSON && lines) {
      try {
        created = patch(html, usable, lines!, state);
        mode = 'patch';
      } catch (e) {
        replaceAll(html, usable, lines, optionsJSON); // DOM and state may disagree now: rebuild
        post({ type: 'error', stage: 'script', message: `patch failed, rebuilt: ${errorText(e)}` });
      }
    } else replaceAll(html, usable, lines, optionsJSON);
    if (mode !== 'patch') doc().dataset.flavor = options.flavor;
    const t3 = performance.now();
    errorBar().hidden = true;
    setRenderVersion(version);
    restoreTaskFocus(focusedTask);
    anchorAfterRender();
    renderMermaid(doc()); // async; draws the diagrams that are new in the DOM, the metadata below does not wait for it
    const ms = (a: number, b: number): number => Math.round((b - a) * 100) / 100;
    return JSON.stringify({ ...meta, perf: { mode, created, render: ms(t0, t1), split: ms(t1, t2), apply: ms(t2, t3), patch: ms(t1, t3), total: ms(t0, t3) } });
  } catch (e) {
    const message = errorText(e);
    errorBar().textContent = `Render error: ${message}`;
    errorBar().hidden = false;
    post({ type: 'error', stage: 'render', message });
    return JSON.stringify({ error: message });
  }
}

// A render must not move the page, but whatever lays out late afterwards (images, Mermaid, fonts) keeps the top line in
// place (scroll.ts). The anchor is taken in the next frame, once the new DOM has been laid out, before the observer fires.
let anchorQueued = false;
let observing = false;
function anchorAfterRender(): void {
  if (!observing) {
    observing = true;
    startAnchoring(doc()); // the script runs in <head>, the article exists from the first render on
  }
  if (anchorQueued) return;
  anchorQueued = true;
  requestAnimationFrame(() => {
    anchorQueued = false;
    recordAnchor(state?.blocks ?? []);
  });
}

// Flavor chunks and stylesheets (PLAN 4.4.3): the app names the ones the document's flavor needs before every update. A
// chunk (a script that registers the flavor with render.bundle.js) is loaded once per page (chunk-loader.ts);
// a flavor stylesheet is linked while its flavor is in use and dropped otherwise. With no flavor, nothing is loaded.
export async function useFlavor(flavor: { chunks: string[]; stylesheets: string[] }): Promise<void> {
  await Promise.all(flavor.chunks.map(loadChunk));
  const wanted = new Set(flavor.stylesheets);
  const links = Array.from(document.head.querySelectorAll<HTMLLinkElement>('link[data-md2-flavor]'));
  for (const l of links) if (!wanted.has(l.getAttribute('href') ?? '')) l.remove();
  const have = new Set(links.map((l) => l.getAttribute('href')));
  await Promise.all(
    [...wanted].filter((href) => !have.has(href)).map(
      (href) =>
        new Promise<void>((resolve) => {
          const el = document.createElement('link');
          el.rel = 'stylesheet';
          el.href = href;
          el.dataset.md2Flavor = '';
          el.onload = el.onerror = () => resolve(); // an unstyled flavor beats a blocked preview
          document.head.append(el);
        }),
    ),
  );
}

// Forget the block table: the next update rebuilds the whole page (document directory changed, theme swap, ...).
export function invalidate(): void {
  state = null;
}

// The document folder (`file:///.../`, null for no folder). Relative links are resolved against it when a block enters the
// page, so a different folder means the kept blocks hold stale hrefs: the next update rebuilds.
export function setBase(base: string | null): void {
  if (base === docBase) return;
  docBase = base;
  state = null;
}

export function scrollToLine(line: number): void {
  scrollBlocksToLine(state?.blocks ?? [], line);
}

// 0-based, fractional source line at the top of the viewport; also what the scroll reports carry.
export function visibleTopLine(): number {
  return pageYToLine(state?.blocks ?? [], scrollY);
}

// Swap the preview style (and its highlight.js theme) without reloading the page: the new <link>s go in after the old
// ones, which are dropped once every new one has loaded (or failed), so there is never an unstyled frame. `dark` null
// = fixed style; otherwise `light` applies under prefers-color-scheme: light and `dark` under dark.
let appliedStyle = JSON.stringify(styleLinks(DEFAULT_STYLE, null)); // what preview.html ships with
export function setStyle(light: string, dark: string | null): void {
  const links = styleLinks(light, dark);
  const key = JSON.stringify(links);
  if (key === appliedStyle) return;
  appliedStyle = key;
  const old = Array.from(document.head.querySelectorAll('link[data-md2-style]'));
  let pending = links.length;
  const loaded = (): void => {
    if (--pending > 0) return;
    old.forEach((l) => l.remove());
    renderMermaid(doc()); // light <-> dark changes the Mermaid theme
  };
  for (const l of links) {
    const el = document.createElement('link');
    el.rel = 'stylesheet';
    el.href = l.href;
    if (l.media) el.media = l.media;
    el.dataset.md2Style = l.kind;
    el.onload = el.onerror = loaded;
    document.head.append(el);
  }
}

startScrollReporting(() => state?.blocks ?? []);
startAnchorScrolling();
startTaskToggling();
addEventListener('error', (e) => post({ type: 'error', stage: 'script', message: `${e.message} (${e.filename}:${e.lineno})` }));
addEventListener('unhandledrejection', (e) => post({ type: 'error', stage: 'script', message: errorText(e.reason) }));
document.addEventListener('securitypolicyviolation', (e) => post({ type: 'error', stage: 'csp', message: `${e.violatedDirective} blocked ${e.blockedURI}` }));
