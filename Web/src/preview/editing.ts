// Text-level editing in the preview (PLAN M2). Typing, deleting and input-method composition inside the text of a paragraph,
// heading, list, quote or table become edits of the mapped source characters (source-map.ts), which the app applies through the
// editor (its undo manager, its typing coalescing) and renders again. Anything structural (Return, a rich paste, a drop, an edit
// across formatting or outside the mapped text) is refused with a short hint that the source pane is the place for it. Typed
// characters must show as typed: each edit is rendered first, and Markdown punctuation that would turn into markup is written
// backslash-escaped (`*` -> `\*`, `|` in a table -> `\|`); an edit that would still change more than its characters is refused.
//
// Only the block being edited is contenteditable (plaintext-only), from the click that puts the caret in it until focus leaves.
// The page never lets the browser change the DOM on its own: every cancelable input is prevented and done here, so the browser's
// own undo stack (which would sit in the document's undo manager next to the editor's steps) never gets an entry. An input
// method's composition cannot be prevented; it is let through and turned into one edit when it ends (or, where WebKit asks with
// `insertFromComposition`, prevented and inserted here like typing).
//
// Edits go out at once and are shown at once; the app applies them in order. A burst is the run of edits since the page last showed
// the app's text: each carries the render it started from (`base`) and its number in the burst (`seq`), plus the source it removes
// and the source around it, and the app applies edit n only when its editor holds exactly the text the page had before it (the
// render's text with edits 1 ..< n applied) and that text has those characters there; otherwise it refuses, and the page shows the
// app's text again. Edits in several blocks of one burst are fine: every map is kept in the burst's text (source-map.ts `rebase`,
// `shifted`). While a burst is in flight the renders the app sends that do not yet contain all of it are held back (the page already
// shows more), and so is every render while an input method composes: the block under the caret is never rebuilt under the user's
// hands. The render that catches up replaces the edited block and the caret goes back to the same source offset.
//
// Undo: each edit says whether it starts a new undo step. It continues the last one, as typing in the editor does, while it is next
// to the previous edit in the same block and nothing else changed the text in between.
import { post } from './bridge.ts';
import { blockNodes, type BlockHandle } from './scroll.ts';
import { lineOf, linesRange, shown } from './shown.ts';
import {
  blockText, edited, handleOf, insertionAt, literalEdit, mapBlock, NEWLINE, pointAt, pointIn, rebase, renderedBlock, shifted,
  sourceEdit, splitsPair, type BlockMapping, type BurstEdit, type Refusal, type SourceEdit,
} from './source-map.ts';
import { bridgeToken } from './tasks.ts';

export type HintKind = Refusal | 'paste' | 'structure' | 'stale';
type Hints = Partial<Record<HintKind, string>>;

// Blocks whose text may be edited here: the inline-text blocks. Code, math, HTML blocks, rules, diagrams, [TOC] are not.
const EDITABLE = new Set(['P', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'UL', 'OL', 'BLOCKQUOTE', 'TABLE', 'DIV']);
// lazy: a burst whose edits the app never answers is given up after this long (the page then asks for the app's text); while an
// input method composes the clock stops. upgrade = an explicit acknowledgement per edit if a slow app ever trips it.
let burstTimeoutMs = 2000;
// The source around an edit that goes with it, for the app to check its text has the same characters there.
const CONTEXT = 16;

let enabled = false;
let hints: Hints = {};

let host: HTMLElement | null = null; // the block element that is contenteditable
let hostHandle: BlockHandle | null = null;

interface Burst {
  base: number; // render the burst started from
  seq: number; // edits sent
  text: string; // that render's text with every sent edit applied
  edits: BurstEdit[]; // in order, each in the text before it
  maps: Map<BlockHandle, BlockMapping>; // the blocks edited in this burst, in step with the DOM, offsets in `text`
  caret: number; // source offset of the caret after the last edit
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
let pendingResync: HintKind | null = null; // a resync that had to wait for the composition to end
let heldBack = false; // a render was held back: once nothing is in flight any more, ask for the app's text again
let restoreCaret: { at: number; trusted: boolean } | null = null; // after a render: put the caret back at this source offset
let updating = false; // a render is being applied: the focus moving off a replaced block is not the user's
let forget: (h: BlockHandle) => void = () => {};
let timer: ReturnType<typeof setTimeout> | null = null;
// The last edit, for undo coalescing: its block (by first line: a rebuilt block is the same block) and the source offset after it.
let lastEdit: { line0: number; end: number } | null = null;
// Bumped by every edit and every render applied: a remembered caret (sticky) is good only until the next one.
let epoch = 0;

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

const elementOf = (h: BlockHandle): HTMLElement | null => (blockNodes(h).find((n) => n.nodeType === 1) as HTMLElement | undefined) ?? null;

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
  lastEdit = null; // a click is a caret jump: the next edit starts an undo step
  enter(h, el, r.cloneRange());
}

function onMouseDown(e: MouseEvent): void {
  // A link or a checkbox inside the block being edited works as everywhere else: leave edit mode before the click lands.
  if (host && e.target instanceof Element && host.contains(e.target) && e.target.closest('a[href], input')) leave();
}

function onFocusOut(e: FocusEvent): void {
  if (updating || composing) return; // a render replacing the block; the input method's own panels taking focus for a moment
  if (host && e.target === host && !(e.relatedTarget instanceof Node && host.contains(e.relatedTarget))) {
    lastEdit = null;
    leave();
  }
}

function onKeyDown(e: KeyboardEvent): void {
  if (host && e.key === 'Escape' && !e.isComposing) {
    lastEdit = null;
    host.blur();
    leave();
  }
}

// --- edits --------------------------------------------------------------------------------------------------------------------

/** The edited block's map, in step with the DOM and in the text the next edit applies to (the burst's). */
function current(): BlockMapping | null {
  if (!hostHandle) return null;
  if (!burst) return mapBlock(hostHandle);
  const kept = burst.maps.get(hostHandle);
  if (kept) return kept;
  const m = mapBlock(hostHandle);
  return m && rebase(m, burst.edits);
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
  if (!m || !hostHandle) return hint('unmapped');
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
  const refuse = (kind: HintKind): void => (done === 'none' ? hint(kind) : resync(kind));
  const v: SourceEdit = at === null || k1 !== k0
    ? sourceEdit(m, source, k0, k1, data, prev, next)
    : NEWLINE.test(data) ? { refused: 'newline' } : splitsPair(source, at) || at < m.start || at > m.end ? { refused: 'unmapped' } : { from: at, to: at };
  sticky = null;
  if ('refused' in v) return refuse(v.refused);
  // Rendered first: the block must show exactly what was typed, in the markup it has (else escaped, else refused).
  const expected = m.text.slice(0, k0) + data + m.text.slice(k1);
  let literal: ReturnType<typeof literalEdit>;
  try {
    const before = renderedBlock(source.slice(m.start, m.end), m);
    literal = literalEdit(source, m.start, m.end, v.from, v.to, data, expected, before, (block) => renderedBlock(block, m));
  } catch {
    literal = null;
  }
  if (!literal) return refuse('formatting'); // it would change the markup around it, escaped or not
  let caret: { node: Text; offset: number } | null = null;
  if (done !== 'all') {
    // Into the text node the caret belongs to: the one holding unit k0-1 when typing continues it, else unit k0's.
    const after = prev && k0 > 0 && m.offsets[k0 - 1] >= 0;
    const dom = done === 'deleted' ? { ...m, ...blockText(h) } : m;
    const start = k0 === k1 || done === 'deleted' ? pointAt(dom, k0, after) : pointAt(m, k0, false);
    if (!start) return refuse('unmapped');
    if (k1 > k0 && done === 'none') {
      const end = pointAt(m, k1, true);
      if (!end) return refuse('unmapped');
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
  if (now.text !== expected) return resync('stale');
  const token = bridgeToken();
  if (!token) return resync('stale');
  const delta = literal.insert.length - (v.to - v.from);
  const mapping = edited(m, k0, k1, literal.units.map((u) => v.from + u), literal.widths, delta, now);
  const step = !lastEdit || lastEdit.line0 !== h.line0 || (v.from !== lastEdit.end && v.to !== lastEdit.end);
  burst ??= { base: shown.version, seq: 0, text: shown.source, edits: [], maps: new Map(), caret: 0, sentAt: 0 };
  for (const [b, other] of burst.maps) if (b !== h) burst.maps.set(b, shifted(other, v.to, delta));
  burst.maps.set(h, mapping);
  burst.seq++;
  burst.edits.push({ from: v.from, to: v.to, len: literal.insert.length });
  burst.text = source.slice(0, v.from) + literal.insert + source.slice(v.to);
  burst.caret = v.from + literal.insert.length;
  burst.sentAt = performance.now();
  lastEdit = { line0: h.line0, end: burst.caret };
  epoch++;
  forget(h);
  post({
    type: 'previewEdit', token, base: burst.base, seq: burst.seq, from: v.from, to: v.to, text: literal.insert, step,
    removed: source.slice(v.from, v.to), before: source.slice(Math.max(0, v.from - CONTEXT), v.from), after: source.slice(v.to, v.to + CONTEXT),
  });
  if (caret) {
    const sel = getSelection();
    sel?.setBaseAndExtent(caret.node, caret.offset, caret.node, caret.offset);
    // Typing goes on right there: after the inserted source, also when it ends in something the page shows differently (an escape).
    sticky = { at: burst.caret, node: caret.node, offset: caret.offset, epoch };
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
  if (pendingResync) {
    // Something went wrong while it composed (the app refused an edit, a burst timed out): what it composed was made on a text the
    // app does not have. Show the app's text (the composed characters are not applied).
    const kind = pendingResync;
    pendingResync = null;
    return resync(kind);
  }
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
    if (!burst) return;
    // An input method is composing (a long look through candidates): the clock stops until it is done.
    if (composing || performance.now() - burst.sentAt < burstTimeoutMs) return armTimeout();
    resync('stale');
  }, burstTimeoutMs + 50);
}

/** Drops whatever is in flight and shows the app's text (`ask`: ask the app for it; a refusal already sends it). Never while an input
 *  method composes: that waits for the composition to end. */
function resync(kind: HintKind | null, ask = true): void {
  if (composing) {
    pendingResync = kind ?? 'stale';
    return;
  }
  if (kind) hint(kind);
  const h = hostHandle;
  if (burst) for (const b of burst.maps.keys()) forget(b);
  if (h) forget(h);
  burst = null;
  heldBack = false;
  lastEdit = null;
  if (timer) clearTimeout(timer);
  const token = bridgeToken();
  if (ask && token) post({ type: 'resync', token });
}

function releaseHeldBack(): void {
  if (heldBack && !busy()) {
    heldBack = false;
    const token = bridgeToken();
    if (token) post({ type: 'resync', token });
  }
}

/** The app refused edit `seq` of the burst started on render `base` (its text was not the one the edit was made on, or it could
 *  not apply it): if that is this page's burst, show the app's text. A refusal of a burst that is over already changes nothing. */
export function editRefused(kind: HintKind | null, base: number, seq: number): boolean {
  if (!burst || burst.base !== base || seq > burst.seq) return false;
  resync(kind ?? 'stale');
  return true;
}

/** main.ts, before applying a render of `md` that carries the app's mark of this page's edits (`edit`: base and seq of the last
 *  edit it contains, null when it is not made of them): 'defer' holds it back. */
export function beforeUpdate(md: string, edit: { base: number; seq: number } | null): 'apply' | 'defer' {
  if (composing) {
    heldBack = true;
    return 'defer';
  }
  updating = true;
  if (!burst) {
    // A render of something else: the caret goes back near where it was, but nothing typed next relies on that offset.
    const at = caretSource();
    restoreCaret = at === null ? null : { at, trusted: false };
    if (edit === null) lastEdit = null;
    return 'apply';
  }
  if (edit && edit.base === burst.base) {
    if (edit.seq === burst.seq && md === burst.text) {
      restoreCaret = host && document.activeElement === host ? { at: burst.caret, trusted: true } : null;
      burst = null;
      heldBack = false;
      if (timer) clearTimeout(timer);
      return 'apply';
    }
    if (edit.seq < burst.seq) {
      heldBack = true;
      updating = false;
      return 'defer';
    }
  }
  // The text moved on without these edits (an undo, a change on disk): show the app's.
  restoreCaret = host && document.activeElement === host ? { at: burst.caret, trusted: false } : null; // near enough for the caret
  for (const b of burst.maps.keys()) forget(b);
  burst = null;
  heldBack = false;
  lastEdit = null;
  if (timer) clearTimeout(timer);
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
  const at = insertionAt(m, p.k, p.prev, p.next);
  return at >= 0 ? at : null;
}

/** main.ts, after a render was applied to the DOM (or failed): the block being edited was rebuilt, so edit mode and the caret move
 *  to the new one (the focus went with the old). */
export function afterUpdate(): void {
  updating = false;
  epoch++;
  const caret = restoreCaret;
  restoreCaret = null;
  if (host && host.isConnected) return;
  leave();
  if (caret) reenterAt(caret.at, caret.trusted);
}

/** Edit mode on the block that holds source offset `at`, caret there (after the character before it when it can). `trusted`: `at`
 *  is an offset in the text on screen (else the caret is only placed near it, and typing goes by what the page shows). */
function reenterAt(at: number, trusted: boolean): void {
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
  sticky = trusted && !exact && p && at >= m.start && at <= m.end ? { at, node: p.node, offset: p.offset, epoch } : null;
}

// The caret's source offset where the page cannot tell it from the DOM: right after an edit (its source may end in an escape the page
// shows as one character) and after a render that hides what was just typed (a space at the end of a paragraph). Typing at that very
// DOM point, with nothing else changed since, goes there, as it would in the editor.
let sticky: { at: number; node: Text; offset: number; epoch: number } | null = null;
function stickyAt(): number | null {
  const s = sticky;
  if (!s || s.epoch !== epoch || !s.node.isConnected) return null;
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
    lastEdit = null;
    if (at === null) {
      enter(h, el, null);
      return true;
    }
    reenterAt(at, false);
    return host === el;
  },
  state: () => ({ editing: host !== null, burst: burst ? { base: burst.base, seq: burst.seq } : null, composing: composing !== null }),
  configure(settings: { burstTimeoutMs?: number }): void {
    if (settings.burstTimeoutMs !== undefined) burstTimeoutMs = settings.burstTimeoutMs;
  },
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
