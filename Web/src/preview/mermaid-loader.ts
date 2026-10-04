// Mermaid in the preview (PLAN 4.4.3 step 4): after every update, blocks the renderer marked `pre.mermaid-source` that
// are not drawn yet are handed to mermaid.chunk.js, which is fetched the first time there is one. Blocks the patch kept
// are already drawn (same DOM node) and are skipped by the chunk, so only changed diagrams are redrawn. A style swap
// that flips light/dark redraws everything with the matching Mermaid theme.
import { errorText, post } from './bridge.ts';
import { loadChunk } from './chunk-loader.ts';

declare const MacDown2Mermaid: { renderAll(root: ParentNode, dark: boolean): Promise<void> };

// Every dark preview style sets `color-scheme: dark` on :root (a user style would too, for native dark controls), so it
// doubles as the "this style is dark" flag and covers follow-system pairs without a registry lookup.
const isDark = (): boolean => getComputedStyle(document.documentElement).colorScheme.includes('dark');

export function renderMermaid(root: ParentNode): void {
  if (!root.querySelector('pre.mermaid-source')) return; // no diagrams: never touch the big chunk
  const dark = isDark();
  const stale = root.querySelectorAll<HTMLElement>(`pre.mermaid-source:not([data-mermaid-theme="${dark ? 'dark' : 'default'}"])`);
  if (!stale.length) return;
  loadChunk('mermaid.chunk.js').then(
    () => MacDown2Mermaid.renderAll(root, dark),
    (e: unknown) => {
      post({ type: 'error', stage: 'script', message: errorText(e) });
      for (const pre of stale) {
        pre.querySelector(':scope > .mermaid-error')?.remove();
        const box = pre.appendChild(document.createElement('div'));
        box.className = 'mermaid-error';
        box.textContent = `Mermaid: ${errorText(e)}`;
      }
    },
  );
}

// Follow-system styles switch light/dark through CSS alone; redraw when the system does.
matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => renderMermaid(document));
