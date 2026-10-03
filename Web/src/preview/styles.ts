// Which stylesheets the preview page links for a given preview style (registry: preview-styles/styles.json, also read
// by the app for its menu). Pure so it can be tested without a DOM.
import registry from './preview-styles/styles.json' with { type: 'json' };

export interface StyleLink {
  kind: 'style' | 'hljs';
  href: string;
  media?: string;
}

const byId = new Map<string, { id: string; hljs: string }>(registry.styles.map((s) => [s.id, s]));
export const DEFAULT_STYLE: string = registry.default;

function linksFor(id: string, media?: string): StyleLink[] {
  const s = byId.get(id) ?? byId.get(DEFAULT_STYLE)!; // unknown id (stale preference): fall back, never leave the page unstyled
  const hljs: StyleLink = { kind: 'hljs', href: `hljs-themes/${s.hljs}.css` };
  const style: StyleLink = { kind: 'style', href: `preview-styles/${s.id}.css` };
  if (media) hljs.media = style.media = media;
  return [hljs, style];
}

/** Fixed style (`dark` null or equal): plain links. Otherwise the light one only applies under `prefers-color-scheme:
 *  light` and the dark one under `dark`: the browser switches with the system, no JS involved. */
export function styleLinks(light: string, dark: string | null): StyleLink[] {
  if (dark === null || dark === light) return linksFor(light);
  return [...linksFor(light, '(prefers-color-scheme: light)'), ...linksFor(dark, '(prefers-color-scheme: dark)')];
}
