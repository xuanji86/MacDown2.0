// JS -> Swift channel: `window.webkit.messageHandlers.macdown2.postMessage(...)` (WebPage.Configuration
// .userContentController, PLAN 4.4.1). Fire-and-forget; silently a no-op outside the app (tests, plain browsers).
export type BridgeMessage =
  | { type: 'scroll'; line: number } // 0-based, fractional source line at the top of the viewport
  | { type: 'error'; stage: 'render' | 'script' | 'csp'; message: string }
  // a task-list checkbox was clicked (tasks.ts): the app owns the edit; `version` is the render the page shows, `token` the app's per-load secret
  | { type: 'toggleTask'; token: string; line: number; checked: boolean; version: number };

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
