// JS -> Swift channel: `window.webkit.messageHandlers.macdown2.postMessage(...)` (WebPage.Configuration
// .userContentController, PLAN 4.4.1). Fire-and-forget; silently a no-op outside the app (tests, plain browsers).
export type BridgeMessage =
  | { type: 'scroll'; line: number } // 0-based, fractional source line at the top of the viewport
  | { type: 'error'; stage: 'render' | 'script' | 'csp'; message: string }
  // a task-list checkbox was clicked (tasks.ts): the app owns the edit; `version` is the render the page shows, `token` the app's per-load secret
  | { type: 'toggleTask'; token: string; line: number; checked: boolean; version: number }
  // the preview's selection as a source range [from, to) of the text of render `version` (-1, -1: none), peer.ts
  | { type: 'selection'; token: string; version: number; from: number; to: number }
  // a text edit made in the preview (editing.ts): source [from, to) replaced by `text`, in the text of render `base` with this
  // burst's edits 1 ..< seq already applied; the app applies it only if its editor holds exactly that text
  | { type: 'previewEdit'; token: string; base: number; seq: number; from: number; to: number; text: string }
  // the page held back a render while an edit or an input method was in flight, and now wants the app's current text again
  | { type: 'resync'; token: string };

interface Host {
  webkit?: { messageHandlers?: { macdown2?: { postMessage(message: unknown): void } } };
}

export function post(message: BridgeMessage): void {
  try {
    (globalThis as Host).webkit?.messageHandlers?.macdown2?.postMessage(message);
  } catch {
    // nothing to report to: the channel itself is down
  }
}

export function errorText(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}
