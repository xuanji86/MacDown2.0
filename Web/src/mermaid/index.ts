// Mermaid chunk (PLAN 4.1.2): its own script, never part of render.bundle.js / preview.bundle.js. The preview page
// (preview/mermaid-loader.ts) and the offscreen print page (App/Export/PrintPage.swift) load it only when a document
// has a ```mermaid block. Bundled as an IIFE exposing `MacDown2Mermaid.renderAll(root, dark)`.
//
// The renderer emits every mermaid fence as `<pre class="mermaid-source"><code>…source…</code></pre>`, which is also
// what exports, Quick Look and JavaScriptCore show. This chunk upgrades such a block in place (same <pre> node, so
// the preview's block handles and `data-line` stay valid): the SVG goes in after the <code>, and CSS hides the code
// while `data-mermaid="ok"`. A diagram that fails keeps its source and gets the message under it.
import mermaid from 'mermaid';

const message = (e: unknown): string => (e instanceof Error ? e.message : String(e));

let configured = '';
let seq = 0;

async function svgOf(source: string, theme: string): Promise<string> {
  if (configured !== theme) {
    // `strict` sanitizes labels and disables click handlers; `suppressErrorRendering` makes a bad diagram throw
    // instead of inserting mermaid's own "syntax error" graphic into the page. Mermaid 12 defaults to `layout: elk`,
    // but elkjs is not in this chunk (EPL-2.0, see build.mjs): dagre is the default here, and a document that asks
    // for `layout: elk` gets the stub's error on its diagram.
    mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', layout: 'dagre', theme: theme as 'dark' | 'default', suppressErrorRendering: true });
    configured = theme;
  }
  return (await mermaid.render(`md2-mermaid-${seq++}`, source)).svg;
}

function show(pre: HTMLElement, theme: string, svg: string | null, error?: string): void {
  pre.querySelectorAll(':scope > .mermaid-svg, :scope > .mermaid-error').forEach((n) => n.remove());
  if (svg !== null) {
    const box = document.createElement('div');
    box.className = 'mermaid-svg';
    box.innerHTML = svg;
    pre.append(box);
  }
  if (error !== undefined) {
    const box = document.createElement('div');
    box.className = 'mermaid-error';
    box.setAttribute('role', 'alert');
    box.textContent = `Mermaid: ${error}`;
    pre.append(box);
  }
  pre.dataset.mermaid = svg !== null ? 'ok' : 'error';
  pre.dataset.mermaidTheme = theme;
}

// One pass at a time: mermaid keeps global state (config, temp nodes), and diagrams should land in document order.
let queue: Promise<void> = Promise.resolve();

/** Draws every mermaid block under `root` that is new or was drawn for another theme. Blocks already drawn are left
 *  alone, so a patch that kept a block never redraws it. Resolves when all of them are done; never rejects. */
export function renderAll(root: ParentNode, dark: boolean): Promise<void> {
  const theme = dark ? 'dark' : 'default';
  const pass = async (): Promise<void> => {
    const todo = [...root.querySelectorAll<HTMLElement>('pre.mermaid-source')].filter((p) => p.dataset.mermaidTheme !== theme);
    for (const pre of todo) {
      if (!pre.isConnected) continue; // replaced by a patch while an earlier diagram was drawing
      try {
        show(pre, theme, await svgOf(pre.querySelector('code')?.textContent ?? '', theme));
      } catch (e) {
        show(pre, theme, null, message(e));
      }
    }
  };
  queue = queue.then(pass, pass);
  return queue;
}
