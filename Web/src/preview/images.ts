// Relative image paths in the rendered document point at files next to the .md; the page itself lives at
// macdown2-res://app/, so they are rewritten to macdown2-res://doc/<path>. The Swift handler resolves `doc`
// against the current document directory and refuses anything that leaves it (App/Preview/DocumentFileResolver.swift).

const DOC = 'macdown2-res://doc/';
const DOT = /^(\.|%2e)$/i; // URL parsers treat %2e as a dot too
const DOTDOT = /^(\.|%2e)(\.|%2e)$/i;

// Returns the rewritten URL, or null when `src` must stay as it is (absolute URL, data:, root-relative, empty)
// or climbs out of the document directory (left alone so it does not resolve to anything).
export function resolveImageSrc(src: string): string | null {
  if (!src || src.startsWith('/') || src.startsWith('#') || /^[a-z][a-z0-9+.-]*:/i.test(src)) return null;
  const [, path, rest] = /^([^?#]*)(.*)$/s.exec(src)!;
  const out: string[] = [];
  for (const part of path.split('/')) {
    if (part === '' || DOT.test(part)) continue;
    if (DOTDOT.test(part)) {
      if (out.pop() === undefined) return null;
    } else out.push(part);
  }
  return out.length ? DOC + out.join('/') + rest : null;
}

// Runs on detached (inert) nodes, before they enter the page, so the browser never requests the wrong URL.
export function rewriteImages(root: ParentNode): void {
  for (const img of root.querySelectorAll('img[src]')) {
    const next = resolveImageSrc(img.getAttribute('src')!);
    if (next) img.setAttribute('src', next);
  }
}
