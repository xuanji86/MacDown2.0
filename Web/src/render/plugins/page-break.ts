// A page break for PDF / print, written on a line of its own:
//   <div style="page-break-after: always"></div>   Typora, VS Code, md-to-pdf, Marked, ... (what Insert Page Break writes)
//   \newpage  \pagebreak  \clearpage               Pandoc, Quarto, R Markdown
//   {{< pagebreak >}}                              Quarto shortcode
// All of them become `<div class="md2-page-break">`: a thin dashed rule on screen, a CSS page break when printed (the
// stylesheets own both). This is a block rule of our own rather than a pass over the raw HTML, so it also works with
// "raw HTML" switched off, and the page needs no inline style (the preview's CSP would allow it, a stricter one would not).
import type { MarkdownIt, Token } from 'markdown-it';

const MARKER = new RegExp(
  '^(?:' +
    [
      String.raw`\\(?:newpage|pagebreak|clearpage)`,
      String.raw`\{\{<\s*pagebreak\s*>\}\}`,
      String.raw`<div\s+style\s*=\s*(["'])\s*(?:page-break-(?:after|before)\s*:\s*always|break-(?:after|before)\s*:\s*page)\s*;?\s*\1\s*>\s*</div>`,
    ].join('|') +
    ')$',
  'i',
);

export function pageBreak(md: MarkdownIt): void {
  md.block.ruler.before(
    'html_block',
    'macdown2_page_break',
    (state, start, _end, silent) => {
      if (state.sCount[start] - state.blkIndent >= 4) return false;
      const line = state.src.slice(state.bMarks[start] + state.tShift[start], state.eMarks[start]).trim();
      if (!MARKER.test(line)) return false;
      if (!silent) {
        const token = state.push('page_break', 'div', 0);
        token.block = true;
        token.markup = line;
        token.map = [start, start + 1];
      }
      state.line = start + 1;
      return true;
    },
    { alt: ['paragraph', 'reference', 'blockquote'] },
  );
  md.renderer.rules.page_break = (tokens: Token[], idx, _options, _env, slf) =>
    `<div class="md2-page-break"${slf.renderAttrs(tokens[idx])} aria-hidden="true"></div>\n`;
}
