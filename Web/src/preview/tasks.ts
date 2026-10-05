// Task-list checkboxes in the live preview. The renderer emits them `disabled` (so Quick Look, export, print and
// `macdown2 render` stay static); only this page enables them, and only once the app has handed over its per-load token.
//
// A click does not edit anything here. It posts {token, line, mark, column, checked, version} to the app: `line` is the source
// line of the element holding the checkbox (data-line, kept current by the patcher), `mark` / `column` where the renderer found its
// `[ ]` (the render's task list, shown.ts), `checked` the state the user asked for, `version` the render the page shows (main.ts
// passes the app's counter into every update). The app checks the token, that version against the renders it sent (their text), that
// the text has a `[ ]` / `[x]` there and that its editor still holds that text; it edits the source, and the next render brings the
// new state in through the normal block patch. One listener on the document serves every checkbox,
// including those of blocks that arrive later.
import { post } from './bridge.ts';
import { shown } from './shown.ts';

const BOX = 'input.task-list-item-checkbox';

let token: string | null = null; // set by the app after each load; nothing is clickable before that
let version = 0; // the render the page shows; 0 = none yet

export function setTaskToken(value: string | null): void {
  token = value;
}

/** The app's per-load token (every message that asks for something carries it); null before the app handed it over. */
export function bridgeToken(): string | null {
  return token;
}

export function setRenderVersion(value: number): void {
  version = value;
}

// The source line a checkbox belongs to: its paragraph in a loose item, its list item otherwise. Null when the line is
// unknown or untrustworthy: no line at all, or inside a block rendered from another file (`data-include`: a flavor's
// include), whose lines are that file's, not the document's.
function taskLine(box: Element): number | null {
  if (box.closest('[data-include]')) return null;
  const raw = box.closest('[data-line]')?.getAttribute('data-line');
  const line = raw === null || raw === undefined ? NaN : Number(raw);
  return Number.isInteger(line) && line >= 0 ? line : null;
}

// Called on freshly parsed HTML, before it enters the page. Raw `<input class="task-list-item-checkbox">` typed by the
// author gets the same treatment: the app refuses a line that is not a task item.
export function enableTaskCheckboxes(root: ParentNode): void {
  if (token === null) return;
  for (const box of root.querySelectorAll(`${BOX}[disabled]`)) {
    if (taskLine(box) !== null) box.removeAttribute('disabled');
  }
}

// The app refused a toggle (or it could not be applied): put every checkbox back to what the source says. A kept block
// is never re-created, so a box the user flipped would otherwise keep showing a state the text does not have.
export function resyncTasks(): void {
  for (const box of document.querySelectorAll<HTMLInputElement>(BOX)) box.checked = box.defaultChecked;
}

// A toggle re-renders the block that holds the box, so a keyboard user would lose the focus after each Space: the line of
// the focused box is taken before a render and focus goes back to the box on that line afterwards.
export function focusedTaskLine(): number | null {
  const el = document.activeElement;
  return el instanceof HTMLInputElement && el.matches(BOX) ? taskLine(el) : null;
}

export function restoreTaskFocus(line: number | null): void {
  if (line === null || document.activeElement?.matches(BOX)) return;
  for (const box of document.querySelectorAll<HTMLInputElement>(BOX)) {
    if (taskLine(box) === line) return box.focus({ preventScroll: true });
  }
}

export function startTaskToggling(): void {
  document.addEventListener('click', (e) => {
    const box = e.target;
    if (!(box instanceof HTMLInputElement) || !box.matches(BOX)) return;
    // By now the browser has already flipped the box: `checked` is the state the user wants. Shown optimistically; the
    // render that follows the edit makes it real, `resyncTasks` takes it back if the app says no.
    const line = taskLine(box);
    if (token === null || line === null) {
      e.preventDefault();
      return;
    }
    const task = shown.tasks.find((t) => t.line === line);
    post({ type: 'toggleTask', token, line, mark: task?.mark ?? -1, column: task?.column ?? -1, checked: box.checked, version });
  });
}
