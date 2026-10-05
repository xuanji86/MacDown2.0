// Text-level editing in the preview (PLAN M2). Typing, deleting and input-method composition inside the text of a paragraph,
// heading, list, quote or table become edits of the mapped source characters (source-map.ts), which the app applies through the
// editor (its undo manager, its typing coalescing) and renders again. Anything structural (Return, a rich paste, a drop, an edit
// across formatting or outside the mapped text) is refused with a short hint that the source pane is the place for it.
//
// Only the block being edited is contenteditable (plaintext-only), from the click that puts the caret in it until focus leaves.
// The page never lets the browser change the DOM on its own: every cancelable input is prevented and done here, so the browser's
// own undo stack (which would sit in the document's undo manager next to the editor's steps) never gets an entry. An input
// method's composition cannot be prevented; it is let through and turned into one edit when it ends (or, where WebKit asks with
// `insertFromComposition`, prevented and inserted here like typing).
//
// Edits go out at once and are shown at once; the app applies them in order. A burst is the run of edits since the page last showed
// the app's text: each carries the render it started from (`base`) and its number in the burst (`seq`), and the app applies edit n
// only when its editor holds exactly the text the page had before it (the render's text with edits 1 ..< n applied); otherwise it
// refuses, and the page shows the app's text again. While a burst is in flight the renders the app sends that do not yet contain
// all of it are held back (the page already shows more), and so is every render while an input method composes: the block under
// the caret is never rebuilt under the user's hands. The render that catches up replaces the edited block and the caret goes back
// to the same source offset.
import { post } from './bridge.ts';
import type { BlockHandle } from './scroll.ts';
import { lineOf, linesRange, shown } from './shown.ts';
import { blockText, handleOf, insertionAt, mapBlock, pointAt, pointIn, sourceEdit, splitsPair, type BlockMapping, type Refusal, type SourceEdit } from './source-map.ts';
import { bridgeToken } from './tasks.ts';

export type HintKind = Refusal | 'paste' | 'structure' | 'stale';
type Hints = Partial<Record<HintKind, string>>;

// Blocks whose text may be edited here: the inline-text blocks. Code, math, HTML blocks, rules, diagrams, [TOC] are not.
const EDITABLE = new Set(['P', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'UL', 'OL', 'BLOCKQUOTE', 'TABLE', 'DIV']);
// lazy: a burst whose edits the app never answers is given up after this long (the page then asks for the app's text); upgrade =
// an explicit acknowledgement per edit if a slow app ever trips it.
const BURST_TIMEOUT_MS = 2000;

let enabled = false;
let hints: Hints = {};

let host: HTMLElement | null = null; // the block element that is contenteditable
let hostHandle: BlockHandle | null = null;

interface Burst {
  base: number; // render the burst started from
  seq: number; // edits sent
  text: string; // that render's text with every sent edit applied
  caret: number; // source offset of the caret after the last edit
  mapping: BlockMapping; // the edited block, kept in step with the DOM
  sentAt: number;
}
let burst: Burst | null = null;

interface Composition {
  m: BlockMapping;
  text: string; // the block's text when it started
  k0: number;
  k1: number;
  prev: boolean;
  next: boolean;
  at: number | null; // the caret's remembered source offset when it started (sticky)
}
let composing: Composition | null = null;
let heldBack = false; // a render was held back: once nothing is in flight any more, ask for the app's text again
let restoreCaret: number | null = null; // after the catching-up render: put the caret back at this source offset
let forget: (h: BlockHandle) => void = () => {};
let timer: ReturnType<typeof setTimeout> | null = null;

/** The app turns editing on or off (Settings ▸ Rendering ▸ Edit in preview) and hands over the hint texts in its language. */
export function setEditing(config: { enabled: boolean; hints?: Hints }): void {
  enabled = config.enabled;
  if (config.hints) hints = config.hints;
  if (!enabled) leave();
}

/** main.ts: how to make the next render rebuild a block (forget its key). */
export function onForget(fn: (h: BlockHandle) => void): void {
  forget = fn;
}

/** An edit or a composition is in flight: the page's text is ahead of the app's. */
export function busy(): boolean {
  return burst !== null || composing !== null;
}

// --- hints ------------------------------------------------------------------------------------------------------------------

let hintTimer: ReturnType<typeof setTimeout> | null = null;
function hint(kind: HintKind): void {
  const text = hints[kind] ?? hints.structure;
  if (!text) return;
  let el = document.getElementById('md2-hint');
  if (!el) {
    el = document.createElement('div');
    el.id = 'md2-hint';
    el.setAttribute('role', 'status');
    el.setAttribute('aria-live', 'polite');
    document.body.append(el);
  }
  el.textContent = text;
  el.classList.add('shown');
  if (hintTimer) clearTimeout(hintTimer);
  hintTimer = setTimeout(() => el!.classList.remove('shown'), 2600);
}

// --- edit mode ----------------------------------------------------------------------------------------------------------------

function elementOf(h: BlockHandle): HTMLElement | null {
  for (let n: Node | null = h.first; n; n = n.nextSibling) {
    if (n.nodeType === 1) return n as HTMLElement;
    if (n === h.last) break;
  }
  return null;
}

function enter(h: BlockHandle, el: HTMLElement, caret: Range | null): void {
  if (host !== el) leave();
  host = el;
  hostHandle = h;
  el.setAttribute('contenteditable', 'plaintext-only');
  el.setAttribute('spellcheck', 'false');
  el.setAttribute('autocorrect', 'off');
  el.setAttribute('autocapitalize', 'off');
  if (document.activeElement !== el) el.focus({ preventScroll: true });
  if (caret) {
    const sel = getSelection();
    sel?.removeAllRanges();
    sel?.addRange(caret);
  }
}

function leave(): void {
  const el = host;
  host = null; // first: taking contenteditable away blurs the element, and its focusout comes back here
  hostHandle = null;
  if (el) for (const a of ['contenteditable', 'spellcheck', 'autocorrect', 'autocapitalize']) el.removeAttribute(a);
}

function onClick(e: MouseEvent): void {
  if (!enabled || !bridgeToken() || e.button !== 0 || !(e.target instanceof Element)) return;
  const target = e.target;
  if (!target.closest('#doc') || target.closest('a[href], input, button, img, video, audio, summary, [data-include]')) return;
  const sel = getSelection();
  if (!sel || sel.rangeCount === 0) return;
  const r = sel.getRangeAt(0);
  const h = handleOf(r.startContainer);
  if (!h || handleOf(r.endContainer) !== h) return;
  // A task item's text is a <label> for its checkbox: while editing is on, clicking it places the caret instead of ticking.
  const label = target.closest('label');
  if (host && hostHandle === h && host.isConnected) {
    if (label) e.preventDefault();
    return;
  }
  const el = elementOf(h);
  if (!el || !EDITABLE.has(el.tagName) || el.matches('nav.toc, .md2-page-break')) return;
  const m = mapBlock(h);
  if (!m || m.placed === 0) return;
  if (label) e.preventDefault();
  enter(h, el, r.cloneRange());
}

function onMouseDown(e: MouseEvent): void {
  // A link or a checkbox inside the block being edited works as everywhere else: leave edit mode before the click lands.
  if (host && e.target instanceof Element && host.contains(e.target) && e.target.closest('a[href], input')) leave();
}

function onFocusOut(e: FocusEvent): void {
  if (host && e.target === host && !(e.relatedTarget instanceof Node && host.contains(e.relatedTarget))) {
    if (composing) return; // the input method's own panels can take focus for a moment
    leave();
  }
}

function onKeyDown(e: KeyboardEvent): void {
  if (host && e.key === 'Escape' && !e.isComposing) {
    host.blur();
    leave();
  }
}

// --- edits --------------------------------------------------------------------------------------------------------------------

/** The edited block's map, in step with the DOM (during a burst the source has moved on past the render on screen). */
function current(): BlockMapping | null {
  if (!hostHandle) return null;
  if (burst && burst.mapping.handle === hostHandle) return burst.mapping;
  return mapBlock(hostHandle);
}

const graphemes = new Intl.Segmenter(undefined, { granularity: 'grapheme' });
/** The grapheme before / after unit k of `text`, as [start, end). */
function graphemeAround(text: string, k: number, backward: boolean): [number, number] | null {
  let before: [number, number] | null = null;
  for (const { index, segment } of graphemes.segment(text)) {
    const end = index + segment.length;
    if (backward) {
      if (end > k) break;
      before = [index, end];
    } else if (index >= k) return [index, end];
  }
  return backward ? before : null;
}

function onBeforeInput(e: InputEvent): void {
  if (!host || !(e.target instanceof Node) || !host.contains(e.target)) return;
  const type = e.inputType;
  if (type === 'insertCompositionText' || type === 'deleteCompositionText') return; // the input method's; finished at its end
  if (!e.cancelable) {
    // Not ours to stop: let it happen, then show the app's text again.
    setTimeout(() => resync('structure'), 0);
    return;
  }
  e.preventDefault();
  switch (type) {
    case 'insertText':
    case 'insertReplacementText':
    case 'insertFromYank':
      return typed(e, e.data ?? e.dataTransfer?.getData('text/plain') ?? '');
    case 'insertFromComposition':
      if (composing) return finishComposition(e.data ?? '', false);
      return typed(e, e.data ?? '');
    case 'insertFromPaste':
    case 'insertFromPasteAsQuotation': {
      const types = e.dataTransfer ? Array.from(e.dataTransfer.types) : [];
      const text = e.dataTransfer?.getData('text/plain') ?? '';
      if (!text || types.some((t) => t !== 'text/plain')) return hint('paste'); // formatting, files: the source pane
      return typed(e, text);
    }
    case 'deleteContentBackward':
    case 'deleteContentForward':
    case 'deleteWordBackward':
    case 'deleteWordForward':
    case 'deleteSoftLineBackward':
    case 'deleteSoftLineForward':
    case 'deleteHardLineBackward':
    case 'deleteHardLineForward':
    case 'deleteByCut':
    case 'deleteContent':
      return typed(e, '');
    case 'insertParagraph':
    case 'insertLineBreak':
      return hint('newline');
    default:
      return hint('structure'); // formatting commands, drops, undo of the browser's own (it has none of ours)
  }
}

/** The DOM range an input replaces: the browser's target range, else the selection; a deletion at a caret takes the grapheme. */
function replacedRange(e: InputEvent, m: BlockMapping): { k0: number; k1: number; prev: boolean; next: boolean } | null {
  const target = e.getTargetRanges?.()[0];
  const sel = getSelection();
  const range = target ?? (sel && sel.rangeCount ? sel.getRangeAt(0) : null);
  if (!range) return null;
  const p0 = pointIn(m, range.startContainer, range.startOffset);
  const p1 = range.collapsed ? p0 : pointIn(m, range.endContainer, range.endOffset);
  if (!p0 || !p1) return null;
  let { k: k0 } = p0;
  let { k: k1 } = p1;
  if (k0 === k1 && e.inputType.startsWith('delete')) {
    // No target range (or a collapsed one): one grapheme; word and line deletions need the browser's range.
    if (e.inputType !== 'deleteContentBackward' && e.inputType !== 'deleteContentForward') return null;
    const g = graphemeAround(m.text, k0, e.inputType === 'deleteContentBackward');
    if (!g) return null;
    [k0, k1] = g;
  }
  return { k0, k1, prev: p0.prev, next: p0.next };
}

function typed(e: InputEvent, data: string): void {
  const m = current();
  if (!m || !hostHandle) return;
  const at = replacedRange(e, m);
  if (!at) return hint('unmapped');
  if (at.k0 === at.k1 && !data) return;
  commit(m, at.k0, at.k1, data, at.prev, at.next, 'none', at.k0 === at.k1 ? stickyAt() : null);
}

/** Units [k0, k1) of `m` replaced by `data`: checked, shown, sent. `done`: what the browser did to the DOM already ('all': the
 *  whole edit, an input method's commit; 'deleted': only the removal of [k0, k1)). `at`: typing goes to this source offset (the
 *  caret's remembered place, see `sticky`) instead of next to its neighbours. */
function commit(m: BlockMapping, k0: number, k1: number, data: string, prev: boolean, next: boolean, done: 'none' | 'deleted' | 'all', at: number | null = null): void {
  const h = m.handle;
  const source = burst?.text ?? shown.source;
  const v: SourceEdit = at === null || k1 !== k0
    ? sourceEdit(m.offsets, m.text, source, k0, k1, data, prev, next)
    : /[\r\n\u2028\u2029]/.test(data) ? { refused: 'newline' } : splitsPair(source, at) ? { refused: 'unmapped' } : { from: at, to: at };
  sticky = null;
  if ('refused' in v) {
    if (done !== 'none') resync(v.refused);
    else hint(v.refused);
    return;
  }
  let caret: { node: Text; offset: number } | null = null;
  if (done !== 'all') {
    // Into the text node the caret belongs to: the one holding unit k0-1 when typing continues it, else unit k0's.
    const after = prev && k0 > 0 && m.offsets[k0 - 1] >= 0;
    const dom = done === 'deleted' ? { ...m, ...blockText(h) } : m;
    const start = k0 === k1 || done === 'deleted' ? pointAt(dom, k0, after) : pointAt(m, k0, false);
    if (!start) return done === 'none' ? hint('unmapped') : resync('unmapped');
    if (k1 > k0 && done === 'none') {
      const end = pointAt(m, k1, true);
      if (!end) return hint('unmapped');
      const r = document.createRange();
      r.setStart(start.node, start.offset);
      r.setEnd(end.node, end.offset);
      r.deleteContents();
    }
    start.node.insertData(start.offset, data);
    caret = { node: start.node, offset: start.offset + data.length };
  }
  // The block's text now, which must be exactly the old one with the edit made.
  const now = blockText(h);
  if (now.text !== m.text.slice(0, k0) + data + m.text.slice(k1)) return resync('stale');
  const delta = data.length - (v.to - v.from);
  const offsets = new Int32Array(now.text.length);
  offsets.set(m.offsets.subarray(0, k0), 0);
  for (let i = 0; i < data.length; i++) offsets[k0 + i] = v.from + i;
  for (let k = k1; k < m.offsets.length; k++) offsets[k - k1 + k0 + data.length] = m.offsets[k] >= 0 ? m.offsets[k] + delta : -1;
  const mapping: BlockMapping = { ...m, texts: now.texts, starts: now.starts, text: now.text, offsets, end: m.end + delta, placed: m.placed + data.length - (k1 - k0) };
  const token = bridgeToken();
  if (!token) return resync('stale');
  burst ??= { base: shown.version, seq: 0, text: shown.source, caret: 0, mapping, sentAt: 0 };
  burst.seq++;
  burst.text = source.slice(0, v.from) + data + source.slice(v.to);
  burst.caret = v.from + data.length;
  burst.mapping = mapping;
  burst.sentAt = performance.now();
  forget(h);
  post({ type: 'previewEdit', token, base: burst.base, seq: burst.seq, from: v.from, to: v.to, text: data });
  if (caret) {
    const sel = getSelection();
    sel?.setBaseAndExtent(caret.node, caret.offset, caret.node, caret.offset);
  }
  armTimeout();
}

// --- input methods ------------------------------------------------------------------------------------------------------------

function onCompositionStart(): void {
  if (!host) return;
  const m = current();
  const sel = getSelection();
  if (!m || !sel || !sel.rangeCount) {
    composing = { m: m ?? ({ handle: hostHandle } as BlockMapping), text: '', k0: -1, k1: -1, prev: false, next: false, at: null };
    return;
  }
  const r = sel.getRangeAt(0);
  const p0 = pointIn(m, r.startContainer, r.startOffset);
  const p1 = r.collapsed ? p0 : pointIn(m, r.endContainer, r.endOffset);
  composing = { m, text: m.text, k0: p0?.k ?? -1, k1: p1?.k ?? -1, prev: p0?.prev ?? false, next: p0?.next ?? false, at: stickyAt() };
}

function onCompositionEnd(e: CompositionEvent): void {
  if (composing) finishComposition(e.data ?? '', true);
}

/** The composition is over: the committed text, already in the DOM (`inDOM`) or to put there (WebKit's insertFromComposition). */
function finishComposition(data: string, inDOM: boolean): void {
  const c = composing;
  composing = null;
  if (!c) return;
  if (c.k0 < 0 || !c.m.texts) return resync('unmapped');
  if (!data && c.k0 === c.k1) {
    // Cancelled, nothing replaced: the DOM must be as it was.
    if (blockText(c.m.handle).text !== c.text) return resync('stale');
    return releaseHeldBack();
  }
  const at = c.k0 === c.k1 ? c.at : null;
  if (inDOM) return commit(c.m, c.k0, c.k1, data, c.prev, c.next, 'all', at);
  // WebKit asks to insert the committed text itself: its composition is gone from the DOM, and with it whatever it replaced.
  const left = blockText(c.m.handle).text;
  if (left === c.text) return commit(c.m, c.k0, c.k1, data, c.prev, c.next, 'none', at);
  if (left === c.text.slice(0, c.k0) + c.text.slice(c.k1)) return commit(c.m, c.k0, c.k1, data, c.prev, c.next, 'deleted');
  resync('stale');
}

// --- renders --------------------------------------------------------------------------------------------------------------------

function armTimeout(): void {
  if (timer) clearTimeout(timer);
  timer = setTimeout(() => {
    timer = null;
    if (burst && performance.now() - burst.sentAt >= BURST_TIMEOUT_MS) resync('stale');
  }, BURST_TIMEOUT_MS + 50);
}

/** Drops whatever is in flight and asks for the app's text, which then replaces the edited block. */
function resync(kind: HintKind | null): void {
  if (kind) hint(kind);
  const h = burst?.mapping.handle ?? hostHandle;
  if (h) forget(h);
  burst = null;
  composing = null;
  heldBack = false;
  const token = bridgeToken();
  if (token) post({ type: 'resync', token });
}

function releaseHeldBack(): void {
  if (heldBack && !busy()) {
    heldBack = false;
    const token = bridgeToken();
    if (token) post({ type: 'resync', token });
  }
}

/** The app refused an edit (its text was not the one the edit was made on, or it could not apply it): show its text again. */
export function editRefused(kind: HintKind | null): void {
  resync(kind ?? 'stale');
}

/** main.ts, before applying a render of `md` that carries the app's mark of this page's edits (`edit`: base and seq of the last
 *  edit it contains, null when it is not made of them): 'defer' holds it back. */
export function beforeUpdate(md: string, edit: { base: number; seq: number } | null): 'apply' | 'defer' {
  if (composing) {
    heldBack = true;
    return 'defer';
  }
  if (!burst) {
    restoreCaret = caretSource();
    return 'apply';
  }
  if (edit && edit.base === burst.base) {
    if (edit.seq === burst.seq && md === burst.text) {
      restoreCaret = host && document.activeElement === host ? burst.caret : null;
      burst = null;
      heldBack = false;
      if (timer) clearTimeout(timer);
      return 'apply';
    }
    if (edit.seq < burst.seq) {
      heldBack = true;
      return 'defer';
    }
  }
  // The text moved on without these edits (an undo, a change on disk, a refusal): show the app's.
  restoreCaret = host && document.activeElement === host ? burst.caret : null; // near enough: it only places the caret
  forget(burst.mapping.handle);
  burst = null;
  heldBack = false;
  return 'apply';
}

/** The source offset of the caret in the block being edited, while it has the focus. */
function caretSource(): number | null {
  if (!host || document.activeElement !== host) return null;
  const m = current();
  const sel = getSelection();
  if (!m || !sel || !sel.rangeCount) return null;
  const r = sel.getRangeAt(0);
  const p = pointIn(m, r.endContainer, r.endOffset);
  if (!p) return null;
  const at = insertionAt(m.offsets, p.k, p.prev, p.next);
  return at >= 0 ? at : null;
}

/** main.ts, after a render was applied to the DOM: the block being edited was rebuilt, so edit mode and the caret move to the
 *  new one (the focus went with the old). */
export function afterUpdate(): void {
  const caret = restoreCaret;
  restoreCaret = null;
  if (host && host.isConnected) return;
  leave();
  if (caret !== null) reenterAt(caret);
}

/** Edit mode on the block that holds source offset `at`, caret there (after the character before it when it can). */
function reenterAt(at: number): void {
  const line = lineOf(shown.source, at);
  const h = shown.blocks.find((b) => b.line0 <= line && line < b.line1);
  if (!h) return;
  const el = elementOf(h);
  const m = mapBlock(h);
  if (!el || !m) return;
  // Right after the character before `at`, or right before the one at it; else (the source has characters there the page does not
  // show: a space typed at the end of a line, which Markdown drops) after the last shown one before it, remembering `at` itself.
  let k = -1;
  let after = false;
  let exact = false;
  for (let i = 0; i < m.offsets.length; i++) {
    const o = m.offsets[i];
    if (o === at - 1) {
      [k, after, exact] = [i + 1, true, true];
      break;
    }
    if (o === at) {
      [k, after, exact] = [i, false, true];
      break;
    }
    if (o >= 0 && o < at) [k, after] = [i + 1, true];
    else if (o > at) {
      if (k < 0) k = i;
      break;
    }
  }
  if (k < 0) return enter(h, el, null);
  const p = pointAt(m, k, after);
  const r = document.createRange();
  if (p) r.setStart(p.node, p.offset);
  r.collapse(true);
  enter(h, el, p ? r : null);
  sticky = !exact && p && at >= m.start && at <= m.end ? { at, node: p.node, offset: p.offset, version: shown.version } : null;
}

// The caret's source offset when the page cannot show it (see reenterAt): typing at that very DOM point, with nothing else changed
// since, goes there, as it would in the editor (a space typed at the end of a paragraph, then the next word).
let sticky: { at: number; node: Text; offset: number; version: number } | null = null;
function stickyAt(): number | null {
  const s = sticky;
  if (!s || burst || s.version !== shown.version || !s.node.isConnected) return null;
  const sel = getSelection();
  if (!sel || !sel.isCollapsed || sel.anchorNode !== s.node || sel.anchorOffset !== s.offset) return null;
  return s.at;
}

export function startEditing(): void {
  document.addEventListener('click', onClick, true);
  document.addEventListener('mousedown', onMouseDown, true);
  document.addEventListener('focusout', onFocusOut, true);
  document.addEventListener('keydown', onKeyDown, true);
  document.addEventListener('beforeinput', onBeforeInput, true);
  document.addEventListener('compositionstart', onCompositionStart, true);
  document.addEventListener('compositionend', onCompositionEnd, true);
}

// Tests drive edit mode without a pointer.
export const editingForTests = {
  enterAt(line: number, at: number | null): boolean {
    const h = shown.blocks.find((b) => b.line0 <= line && line < b.line1);
    const el = h && elementOf(h);
    if (!h || !el) return false;
    if (at === null) {
      enter(h, el, null);
      return true;
    }
    reenterAt(at);
    return host === el;
  },
  state: () => ({ editing: host !== null, burst: burst ? { base: burst.base, seq: burst.seq } : null, composing: composing !== null }),
  /** The map of the block on `line`, timed (benchmarks). */
  mapLine(line: number): { ms: number; placed: number; units: number } | null {
    const h = shown.blocks.find((b) => b.line0 <= line && line < b.line1);
    if (!h) return null;
    const t0 = performance.now();
    const m = mapBlock(h);
    return { ms: performance.now() - t0, placed: m?.placed ?? 0, units: m?.text.length ?? 0 };
  },
  linesRange,
};
