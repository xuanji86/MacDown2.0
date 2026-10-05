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
// `insertFromComposition`, prevented and inserted here like typing). A composition over a selection replaces it (WebKit first
// sends `deleteByComposition`, which is let through too).
//
// Edits go out at once and are shown at once; the app applies them in order. A burst is the run of edits since the page last showed
// the app's text: it has the page's own number (counting up, so a late answer about an earlier burst never touches a later one),
// each edit carries the render the burst started from (`base`) and its number in the burst (`seq`), plus the source it removes and
// the source around it, and the app applies edit n only when its editor holds exactly the text the page had before it (the render's
// text with edits 1 ..< n applied) and that text has those characters there; otherwise it refuses, and the page shows the app's text
// again. Edits in several blocks of one burst are fine: every map is kept in the burst's text (source-map.ts `rebase`, `shifted`).
// While a burst is in flight the renders the app sends that do not yet contain all of it are held back (the page already shows
// more), and so is every render while an input method composes: the block under the caret is never rebuilt under the user's hands;
// when the composition ends, however it ends, a render held back meanwhile is asked for again. The render that catches up replaces
// the edited block and the caret (or selection) goes back to the same source offset it has now; the burst is over once that render
// is on the page.
//
// Undo: each edit says whether it starts a new undo step. It continues the last one, as typing in the editor does, only while it is
// next to the previous edit in the same block and the caret did not move in between (arrow keys, a click, a selection).
import { post } from './bridge.ts';
import { blockNodes, type BlockHandle } from './scroll.ts';
import { lineOf, shown } from './shown.ts';
import {
  blockText, carryContext, edited, handleOf, insertionAt, literalEdit, mapBlock, NEWLINE, pointAt, pointIn, rebase, renderedBlock,
  shifted, sourceEdit, splitsPair, type BlockMapping, type BurstEdit, type Refusal, type SourceEdit,
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
  id: number; // the page's number for it (`bursts`): refusals and the app's marks name it
  base: number; // render the burst started from
  seq: number; // edits sent
  text: string; // that render's text with every sent edit applied
  edits: BurstEdit[]; // in order, each in the text before it
  maps: Map<BlockHandle, BlockMapping>; // the blocks edited in this burst, in step with the DOM, offsets in `text`
  sentAt: number;
}
let burst: Burst | null = null;
let bursts = 0;

interface Composition {
  m: BlockMapping;
  text: string; // the block's text when it started
  k0: number; // the units it replaces (a selection it started over), [k0, k1)
  k1: number;
  prev: boolean;
  next: boolean;
  at: number | null; // the caret's remembered source offset when it started (sticky)
}
let composing: Composition | null = null;
let pendingResync: HintKind | null = null; // a resync that had to wait for the composition to end
let heldBack = false; // a render was held back: ask for the app's text again once nothing holds it back any more
// After a render: put the caret (or the selection [at, end)) back at these source offsets. `trusted`: offsets in the render's text.
let restoreCaret: { at: number; end: number; trusted: boolean } | null = null;
let ending: 'caught-up' | 'dropped' | null = null; // what the render being applied does to the burst (once it is on the page)
let updating = false; // a render is being applied: the focus moving off a replaced block is not the user's
let forget: (h: BlockHandle) => void = () => {};
let timer: ReturnType<typeof setTimeout> | null = null;
// The last edit, for undo coalescing: its block (by first line: a rebuilt block is the same block) and the source offset after it.
let lastEdit: { line0: number; end: number } | null = null;
// Where this page itself last put the caret (after an edit, after a render): a selection anywhere else is the user moving it.
let ownCaret: { node: Node | null; offset: number } | null = null;
// Bumped by every edit and every render applied: a remembered caret (sticky) is good only until the next one.
let epoch = 0;
let trace: string[] | null = null; // tests and the app's Debug hooks: the input events seen

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

function note(event: string): void {
  if (!trace) return;
  trace.push(event);
  if (trace.length > 64) trace.shift();
}

// --- hints ------------------------------------------------------------------------------------------------------------------

let hintTimer: ReturnType<typeof setTimeout> | null = null;
function hint(kind: HintKind): void {
  note(`hint ${kind}`);
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
  if (!host || !(e.target instanceof Element) || !host.contains(e.target)) return;
  lastEdit = null; // the caret goes where the click is: a new undo step, also when it lands where it was
  // A link or a checkbox inside the block being edited works as everywhere else: leave edit mode before the click lands.
  if (e.target.closest('a[href], input')) leave();
}

// Keys that move the caret: like NSTextView, a move ends the typing step even when the caret comes back to the same place.
const MOVES = new Set(['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', 'Home', 'End', 'PageUp', 'PageDown']);

function onFocusOut(e: FocusEvent): void {
  if (updating || composing) return; // a render replacing the block; the input method's own panels taking focus for a moment
  if (host && e.target === host && !(e.relatedTarget instanceof Node && host.contains(e.relatedTarget))) {
    lastEdit = null;
    leave();
  }
}

function onKeyDown(e: KeyboardEvent): void {
  if (host && !e.isComposing && MOVES.has(e.key)) lastEdit = null;
  if (host && e.key === 'Escape' && !e.isComposing) {
    lastEdit = null;
    host.blur();
    leave();
  }
}

/** The caret moved, and not by this page (an edit, a render): the next edit starts a new undo step, as in the editor (keys and clicks
 *  are caught as they happen, `onKeyDown` / `onMouseDown`; this catches the rest: a selection made by other means, assistive tools). */
function onSelectionChange(): void {
  if (!lastEdit || composing) return;
  const sel = getSelection();
  if (!ownCaret || !sel || !sel.isCollapsed || sel.anchorNode !== ownCaret.node || sel.anchorOffset !== ownCaret.offset) lastEdit = null;
}

function rememberCaret(): void {
  const sel = getSelection();
  ownCaret = sel && sel.rangeCount && sel.isCollapsed ? { node: sel.anchorNode, offset: sel.anchorOffset } : null;
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
  if (trace) note(`beforeinput ${type}${e.cancelable ? '' : ' (not cancelable)'} ${JSON.stringify(e.data ?? '')}`);
  if (type === 'insertCompositionText' || type === 'deleteCompositionText') return; // the input method's; finished at its end
  if (type === 'deleteByComposition') {
    // An input method starting over a selection takes the selection out first (WebKit, before or after compositionstart): the
    // composition replaces it. Let through; the composition's record has the selection.
    if (!composing) startComposition(e.getTargetRanges?.()[0] ?? currentRange());
    return;
  }
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

function currentRange(): Range | null {
  const sel = getSelection();
  return sel && sel.rangeCount ? sel.getRangeAt(0) : null;
}

/** The DOM range an input replaces: the browser's target range, else the selection; a deletion at a caret takes the grapheme. */
function replacedRange(e: InputEvent, m: BlockMapping): { k0: number; k1: number; prev: boolean; next: boolean } | null {
  const range = e.getTargetRanges?.()[0] ?? currentRange();
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

/** Units [k0, k1) of `m` replaced by `data`: checked, shown, sent; false when refused. `done`: what the browser did to the DOM already
 *  ('all': the whole edit, an input method's commit; 'deleted': only the removal of [k0, k1)). `at`: typing goes to this source offset
 *  (the caret's remembered place, see `sticky`) instead of next to its neighbours. A refusal shows its hint; when the DOM may have
 *  changed (`done`) or `resyncOnRefusal`, it also shows the app's text again. */
function commit(m: BlockMapping, k0: number, k1: number, data: string, prev: boolean, next: boolean, done: 'none' | 'deleted' | 'all', at: number | null = null, resyncOnRefusal = false): boolean {
  const h = m.handle;
  const source = burst?.text ?? shown.source;
  const refuse = (kind: HintKind): false => {
    if (done === 'none' && !resyncOnRefusal) hint(kind);
    else resync(kind);
    return false;
  };
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
  if (now.text !== expected) {
    if (trace) note(`the block shows ${JSON.stringify(now.text)}, not ${JSON.stringify(expected)}`);
    resync('stale');
    return false;
  }
  const token = bridgeToken();
  if (!token) {
    resync('stale');
    return false;
  }
  const delta = literal.insert.length - (v.to - v.from);
  const mapping = edited(m, k0, k1, literal.units.map((u) => v.from + u), literal.widths, delta, now);
  const step = !lastEdit || lastEdit.line0 !== h.line0 || (v.from !== lastEdit.end && v.to !== lastEdit.end);
  burst ??= { id: ++bursts, base: shown.version, seq: 0, text: shown.source, edits: [], maps: new Map(), sentAt: 0 };
  for (const [b, other] of burst.maps) if (b !== h) burst.maps.set(b, shifted(other, v.to, delta));
  burst.maps.set(h, mapping);
  burst.seq++;
  burst.edits.push({ from: v.from, to: v.to, len: literal.insert.length });
  burst.text = source.slice(0, v.from) + literal.insert + source.slice(v.to);
  burst.sentAt = performance.now();
  const end = v.from + literal.insert.length;
  lastEdit = { line0: h.line0, end };
  epoch++;
  forget(h);
  post({
    type: 'previewEdit', token, burst: burst.id, base: burst.base, seq: burst.seq, from: v.from, to: v.to, text: literal.insert, step,
    removed: source.slice(v.from, v.to), before: source.slice(Math.max(0, v.from - CONTEXT), v.from), after: source.slice(v.to, v.to + CONTEXT),
  });
  if (caret) {
    getSelection()?.setBaseAndExtent(caret.node, caret.offset, caret.node, caret.offset);
    // Typing goes on right there: after the inserted source, also when it ends in something the page shows differently (an escape).
    sticky = { at: end, node: caret.node, offset: caret.offset, epoch };
  }
  rememberCaret();
  armTimeout();
  return true;
}

// --- input methods ------------------------------------------------------------------------------------------------------------

function onCompositionStart(): void {
  note('compositionstart');
  if (host && !composing) startComposition(currentRange());
}

/** A composition starts, replacing `r` (the selection, collapsed or not). */
function startComposition(r: AbstractRange | null): void {
  const m = current();
  if (!m || !r) {
    composing = { m: m ?? ({ handle: hostHandle } as BlockMapping), text: '', k0: -1, k1: -1, prev: false, next: false, at: null };
    return;
  }
  const p0 = pointIn(m, r.startContainer, r.startOffset);
  const p1 = r.collapsed ? p0 : pointIn(m, r.endContainer, r.endOffset);
  composing = { m, text: m.text, k0: p0?.k ?? -1, k1: p1?.k ?? -1, prev: p0?.prev ?? false, next: p0?.next ?? false, at: r.collapsed ? stickyAt() : null };
}

function onCompositionEnd(e: CompositionEvent): void {
  note(`compositionend ${JSON.stringify(e.data ?? '')}`);
  if (composing) finishComposition(e.data ?? '', true);
}

/** The composition is over: the committed text, already in the DOM (`inDOM`) or to put there (WebKit's insertFromComposition). Every
 *  way out leaves nothing held back: a render that waited for the composition is asked for again. */
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
  const h = c.m.handle;
  if (!data && c.k0 === c.k1) {
    // Cancelled (Escape), nothing replaced: the DOM must be as it was.
    if (!respace(h, c.text)) return resync('stale');
    return releaseHeldBack();
  }
  const at = c.k0 === c.k1 ? c.at : null;
  if (inDOM) {
    respace(h, c.text.slice(0, c.k0) + data + c.text.slice(c.k1)); // else the commit's own check finds it
    commit(c.m, c.k0, c.k1, data, c.prev, c.next, 'all', at);
  } else {
    // WebKit asks to insert the committed text itself: its composition is gone from the DOM, and with it whatever it replaced. A
    // refusal shows the app's text: the composed characters are gone, and a render may have waited for the composition.
    if (trace) note(`insert ${JSON.stringify(data)} over [${c.k0}, ${c.k1}) of ${JSON.stringify(c.text)}: block has ${JSON.stringify(blockText(h).text)}`);
    if (respace(h, c.text)) commit(c.m, c.k0, c.k1, data, c.prev, c.next, 'none', at, true);
    else if (respace(h, c.text.slice(0, c.k0) + c.text.slice(c.k1))) commit(c.m, c.k0, c.k1, data, c.prev, c.next, 'deleted');
    else resync('stale');
  }
  releaseHeldBack();
}

/** The block shows `want`, but for spaces WebKit's editing wrote as U+00A0 (a space at the edge of a text node, which would collapse:
 *  seen when an input method replaces a selection): those are made spaces again, the caret and selection kept. False when it shows
 *  anything else. */
function respace(h: BlockHandle, want: string): boolean {
  const now = blockText(h);
  if (now.text === want) return true;
  if (now.text.length !== want.length) return false;
  const fixes: number[] = [];
  for (let i = 0; i < want.length; i++) {
    const a = now.text.charCodeAt(i);
    const b = want.charCodeAt(i);
    if (a === b) continue;
    if (a !== 0xa0 || b !== 0x20) return false;
    fixes.push(i);
  }
  const sel = getSelection();
  const kept = sel && sel.rangeCount ? [sel.anchorNode, sel.anchorOffset, sel.focusNode, sel.focusOffset] as const : null;
  for (const i of fixes) {
    let j = now.starts.length - 1;
    while (now.starts[j] > i) j--;
    now.texts[j].replaceData(i - now.starts[j], 1, ' ');
  }
  if (kept && kept[0] && kept[2]) sel!.setBaseAndExtent(kept[0], kept[1], kept[2], kept[3]);
  note(`respaced ${fixes.length}`);
  return true;
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

/** Drops whatever is in flight and asks the app for its text. Never while an input method composes: that waits for its end. */
function resync(kind: HintKind | null): void {
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
  if (token) post({ type: 'resync', token });
}

/** A render was held back and nothing holds it back any more (no composition): ask for the app's text again. A burst in flight
 *  stays; the render that comes back is judged by its mark like any other. */
function releaseHeldBack(): void {
  if (!heldBack || composing) return;
  heldBack = false;
  const token = bridgeToken();
  if (token) post({ type: 'resync', token });
}

/** The app refused edit `seq` of burst `id` (its text was not the one the edit was made on, or it could not apply it): if that is
 *  this page's burst, show the app's text. A refusal of a burst that is over already changes nothing. */
export function editRefused(kind: HintKind | null, id: number, seq: number): boolean {
  if (!burst || burst.id !== id || seq > burst.seq) return false;
  resync(kind ?? 'stale');
  return true;
}

/** main.ts, before applying a render of `md` that carries the app's mark of this page's edits (`edit`: the burst and the number of
 *  the last of its edits it contains, null when it is not made of them): 'defer' holds it back. */
export function beforeUpdate(md: string, edit: { burst: number; seq: number } | null): 'apply' | 'defer' {
  const ours = burst !== null && edit !== null && edit.burst === burst.id;
  if (composing || (ours && edit!.seq < burst!.seq)) {
    heldBack = true;
    return 'defer';
  }
  updating = true;
  // The caret as it is now (the user may have moved it since the last edit), as source offsets of the text on screen.
  const at = selectionSource();
  if (!burst) {
    // A render of something else: the caret goes back near where it was, but nothing typed next relies on that offset.
    restoreCaret = at && { ...at, trusted: false };
    if (edit === null) lastEdit = null;
    ending = null;
    return 'apply';
  }
  // It catches up with the burst (exactly its text), or the text moved on without these edits (an undo, a change on disk).
  ending = ours && edit!.seq === burst.seq && md === burst.text ? 'caught-up' : 'dropped';
  if (ending === 'caught-up') carryContext(shown.source, md); // its definitions are the ones the burst started from
  restoreCaret = at && { ...at, trusted: ending === 'caught-up' };
  return 'apply';
}

/** The source offsets of the selection in the block being edited ([at, end), equal for a caret), while it has the focus. */
function selectionSource(): { at: number; end: number } | null {
  if (!host || document.activeElement !== host) return null;
  const remembered = stickyAt();
  if (remembered !== null) return { at: remembered, end: remembered };
  const m = current();
  const r = currentRange();
  if (!m || !r) return null;
  const p1 = pointIn(m, r.endContainer, r.endOffset);
  const p0 = r.collapsed ? p1 : pointIn(m, r.startContainer, r.startOffset);
  if (!p0 || !p1) return null;
  const end = insertionAt(m, p1.k, p1.prev, p1.next);
  const at = r.collapsed ? end : insertionAt(m, p0.k, p0.prev, p0.next);
  return at >= 0 && end >= at ? { at, end } : null;
}

/** main.ts, after a render was applied to the DOM (`ok`) or failed: the block being edited was rebuilt, so edit mode and the caret move
 *  to the new one (the focus went with the old). The burst ends here, once the render that ends it is on the page. A failed render
 *  leaves the page as it was; if it was to end the burst, the burst goes (the edits on the page are the app's) and edit mode with it,
 *  so nothing is typed on top of a render that did not happen. */
export function afterUpdate(ok: boolean): void {
  updating = false;
  const end = ending;
  ending = null;
  const caret = restoreCaret;
  restoreCaret = null;
  if (end && burst) {
    if (end === 'dropped' || !ok) {
      for (const b of burst.maps.keys()) forget(b);
      lastEdit = null;
    }
    burst = null;
    heldBack = false;
    if (timer) clearTimeout(timer);
    if (!ok) leave();
  }
  if (!ok) return; // the old content stays: so does edit mode (unless a burst ended with it)
  heldBack = false; // whatever was held back is older than this render
  epoch++;
  if (host && host.isConnected) return;
  leave();
  if (caret) reenterAt(caret.at, caret.trusted, caret.end);
}

/** Where source offset `at` goes in `m`: unit k, in the node of the unit before it (`after`); `exact` when a unit starts or ends
 *  there (else the source has characters there the page does not show: a space typed at the end of a line, which Markdown drops). */
function placeOf(m: BlockMapping, at: number): { k: number; after: boolean; exact: boolean } | null {
  let k = -1;
  let after = false;
  for (let i = 0; i < m.offsets.length; i++) {
    const o = m.offsets[i];
    if (o === at - 1) return { k: i + 1, after: true, exact: true };
    if (o === at) return { k: i, after: false, exact: true };
    if (o >= 0 && o < at) [k, after] = [i + 1, true];
    else if (o > at) {
      if (k < 0) k = i;
      break;
    }
  }
  return k < 0 ? null : { k, after, exact: false };
}

/** Edit mode on the block that holds source offset `at`, caret there (after the character before it when it can), or the selection
 *  [at, end). `trusted`: `at` is an offset in the text on screen (else the caret is only placed near it, and typing goes by what the
 *  page shows). */
function reenterAt(at: number, trusted: boolean, end = at): void {
  const line = lineOf(shown.source, at);
  const h = shown.blocks.find((b) => b.line0 <= line && line < b.line1);
  if (!h) return;
  const el = elementOf(h);
  const m = mapBlock(h);
  if (!el || !m) return;
  const place = placeOf(m, at);
  if (!place) return enter(h, el, null);
  const p = pointAt(m, place.k, place.after);
  if (!p) return enter(h, el, null);
  const r = document.createRange();
  r.setStart(p.node, p.offset);
  r.collapse(true);
  const last = end > at ? placeOf(m, end) : null;
  const q = last && pointAt(m, last.k, last.after);
  if (q) r.setEnd(q.node, q.offset);
  enter(h, el, r);
  rememberCaret();
  sticky = trusted && !q && !place.exact && at >= m.start && at <= m.end ? { at, node: p.node, offset: p.offset, epoch } : null;
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
  document.addEventListener('selectionchange', onSelectionChange);
}

// Tests (and the app's Debug hooks) drive edit mode without a pointer and read what happened.
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
  state: () => ({
    editing: host !== null, burst: burst ? { id: burst.id, base: burst.base, seq: burst.seq } : null, composing: composing !== null, heldBack,
  }),
  configure(settings: { burstTimeoutMs?: number; trace?: boolean }): void {
    if (settings.burstTimeoutMs !== undefined) burstTimeoutMs = settings.burstTimeoutMs;
    if (settings.trace !== undefined) trace = settings.trace ? [] : null;
  },
  /** The input events seen since the last call (with `configure({ trace: true })`). */
  events(): string[] {
    const out = trace ?? [];
    if (trace) trace = [];
    return out;
  },
};
