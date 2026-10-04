// Links in the preview page. The page itself lives at macdown2-res://app/preview.html, so a relative `href` left alone would
// resolve against that and lose the document folder (`../notes/a.md` would collapse to macdown2-res://app/a.md). Instead
// relative links are resolved once, here, against the document folder as a file:// URL; the app's navigation decider
// (MarkdownCore LinkPolicy, App/Preview/PreviewNavigation.swift) then sees the real target and decides:
//   #anchor                 -> scrolled here, in the page (below); never a navigation
//   file:// .md/.qmd in the workspace -> opened in the app; any other file -> confirmed, then the system; executables never
//   http(s), mailto         -> the system browser / mail app
//   anything else           -> cancelled (the rendered page stays)

// Returns the absolute URL for a relative `href`, or null to leave it alone (in-page anchor, absolute URL of any scheme,
// empty). `base` is the document folder as a file URL with a trailing slash; null (unsaved document) leaves everything alone.
export function resolveLinkHref(href: string, base: string | null): string | null {
  if (!base) return null;
  const h = href.trim();
  if (!h || h.startsWith('#')) return null;
  if (/^[a-z][a-z0-9+.-]*:/i.test(h)) return null; // http:, file:, javascript:, ... stays as written; the app decides
  try {
    // `//host/x` has no meaning inside a local document: the usual reading is https
    return new URL(h.startsWith('//') ? `https:${h}` : h, base).href;
  } catch {
    return null;
  }
}

export function rewriteLinks(root: ParentNode, base: string | null): void {
  if (!base) return;
  for (const a of root.querySelectorAll('a[href], area[href]')) {
    const next = resolveLinkHref(a.getAttribute('href')!, base);
    if (next) a.setAttribute('href', next);
  }
}

// Elements that can carry code or navigate on their own (<meta http-equiv=refresh>, <base>) or load other documents.
// The page's CSP already refuses scripts and frames; removing them before they enter the page also covers what a CSP
// does not (meta refresh) and makes the page behave the same in every engine.
const INERT = 'script, iframe, frame, frameset, object, embed, applet, meta, base';
export function stripActiveContent(root: ParentNode): void {
  for (const el of root.querySelectorAll(INERT)) el.remove();
}

// In-page anchors scroll the page ourselves instead of navigating: works for heading ids, ids on any element and the
// old `<a name="x">` form, never reloads, never leaves history entries, and a missing target is a no-op, not a blank page.
export function scrollToFragment(fragment: string): boolean {
  let id = fragment;
  try {
    id = decodeURIComponent(fragment);
  } catch {
    // keep the raw text
  }
  if (id === '' || id.toLowerCase() === 'top') {
    scrollTo({ top: 0, behavior: 'instant' });
    return true;
  }
  const target = document.getElementById(id) ?? document.getElementsByName(id)[0];
  if (!target) return false;
  target.scrollIntoView({ block: 'start', behavior: 'instant' });
  return true;
}

export function startAnchorScrolling(): void {
  addEventListener('click', (e) => {
    if (e.defaultPrevented || !(e.target instanceof Element)) return;
    const a = e.target.closest('a[href], area[href]');
    const href = a?.getAttribute('href');
    if (!href?.startsWith('#')) return;
    e.preventDefault();
    scrollToFragment(href.slice(1));
  });
}
