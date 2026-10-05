// `[TOC]` on a paragraph of its own -> nested heading list. The list is built at render time from
// env.outline (filled by the annotate core rule), so the block's HTML changes whenever the headings do.
import type { MarkdownIt, Token } from 'markdown-it';
import type { OutlineItem } from '../core.ts';

const TOC = /^\[toc\]$/i;

export function toc(md: MarkdownIt): void {
  md.core.ruler.after('inline', 'macdown2_toc', (state) => {
    const tokens = state.tokens;
    for (let i = 0; i + 2 < tokens.length; i++) {
      if (tokens[i].type !== 'paragraph_open' || tokens[i + 1].type !== 'inline' || !TOC.test(tokens[i + 1].content.trim())) continue;
      const t = new state.Token('toc', '', 0);
      t.block = true;
      t.map = tokens[i].map;
      t.level = tokens[i].level;
      tokens.splice(i, 3, t);
      (state.env as { hasToc?: boolean }).hasToc = true;
    }
  });
  md.renderer.rules.toc = (tokens: Token[], idx, _o, env, slf) =>
    `<nav class="toc"${slf.renderAttrs(tokens[idx])}>${tocList((env as { outline?: OutlineItem[] }).outline ?? [], md.utils.escapeHtml)}</nav>\n`;
}

// lazy: a heading that skips levels (h1 then h3) nests one list deeper, and one that climbs back
// past a skipped level (h1, h3, h2) lands beside the nearest open level; upgrade = track levels per branch.
export function tocList(outline: OutlineItem[], esc: (s: string) => string): string {
  const items = outline.filter((o) => o.slug);
  if (!items.length) return '';
  const levels: number[] = [];
  let html = '';
  for (const { level, text, slug } of items) {
    if (!levels.length || level > levels[levels.length - 1]) {
      html += '<ul>';
      levels.push(level);
    } else {
      html += '</li>';
      while (levels.length > 1 && level < levels[levels.length - 1]) {
        html += '</ul></li>';
        levels.pop();
      }
    }
    html += `<li><a href="#${esc(slug)}">${esc(text)}</a>`;
  }
  return `${html}</li>${'</ul></li>'.repeat(levels.length - 1)}</ul>`;
}
