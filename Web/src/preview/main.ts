// Preview page entry. Bundled as an IIFE exposing `globalThis.MacDown2Preview`; render.bundle.js
// (global `MacDown2`) is loaded before it. M0: full innerHTML replace per update, no block patching.
declare const MacDown2: { render(source: string, optionsJSON: string): string };

const doc = (): HTMLElement => document.getElementById('doc')!;
const errorBar = (): HTMLElement => document.getElementById('error')!;

// Renders `md` into article#doc and returns the metadata JSON ({blocks, outline, stats}) without the html.
// On failure the previous content stays, the error bar shows the message, and `{error}` is returned.
export function update(md: string, optionsJSON: string): string {
  try {
    const { html, ...meta } = JSON.parse(MacDown2.render(md, optionsJSON)) as { html: string };
    doc().innerHTML = html;
    errorBar().hidden = true;
    return JSON.stringify(meta);
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    errorBar().textContent = `Render error: ${message}`;
    errorBar().hidden = false;
    return JSON.stringify({ error: message });
  }
}
