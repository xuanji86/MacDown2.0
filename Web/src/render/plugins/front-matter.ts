// YAML front matter at the very top of the document (`---` fences, via markdown-it-front-matter).
// The raw text always lands in RenderResult.frontMatter; `display` only decides what the preview shows.
// The element is emitted in every mode (hidden / table / raw text) so each block token keeps a DOM node.
import type { MarkdownIt, Token } from 'markdown-it';
import frontMatterPlugin from 'markdown-it-front-matter';
import { load } from 'js-yaml';

export type FrontMatterDisplay = 'hidden' | 'table';

function cell(value: unknown): string {
  if (value === null || value === undefined) return '';
  if (value instanceof Date) return value.toISOString().replace(/T00:00:00\.000Z$/, '');
  return typeof value === 'object' ? JSON.stringify(value) : String(value);
}

export function frontMatter(md: MarkdownIt, display: FrontMatterDisplay): void {
  md.use(frontMatterPlugin, () => {});
  const esc = md.utils.escapeHtml;
  md.renderer.rules.front_matter = (tokens: Token[], idx, _o, _env, slf) => {
    const t = tokens[idx];
    const attrs = slf.renderAttrs(t);
    if (display === 'hidden') return `<div class="front-matter" hidden${attrs}></div>\n`;
    let data: unknown;
    try {
      data = load(t.meta as unknown as string);
    } catch {
      data = undefined;
    }
    // Not a mapping (or unparsable): show the source as is.
    if (typeof data !== 'object' || data === null || Array.isArray(data)) {
      return `<pre class="front-matter"${attrs}><code>${esc(t.meta as unknown as string)}</code></pre>\n`;
    }
    const rows = Object.entries(data as Record<string, unknown>)
      .map(([k, v]) => `<tr><th>${esc(k)}</th><td>${esc(cell(v))}</td></tr>`)
      .join('');
    return `<table class="front-matter"${attrs}><tbody>${rows}</tbody></table>\n`;
  };
}
