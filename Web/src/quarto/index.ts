// quarto.chunk.js: the `quarto` flavor (PLAN 4.6.1, approximate preview). Loaded after render.bundle.js, only for a
// .qmd document while the Quarto extension is on; it registers itself with the main bundle and nothing else.
// Plugins: quarto-dev/quarto's markdown-it set (vendored/, see VENDORED.md) + code cells and include (rules/).
// Nothing here runs code or reads files by itself.
import type { MarkdownIt, StateCore, Token } from 'markdown-it';
import attrs from 'markdown-it-attrs';
import type { RenderOptions } from '../render/index.ts';
import { escapeHtml } from './escape.ts';
import { codeCells } from './rules/code-cell.ts';
import { include } from './rules/include.ts';
import { pandocBlankLine } from './rules/pandoc-blank-line.ts';
import { calloutPlugin } from './vendored/callouts';
import { citationPlugin } from './vendored/cites';
import { divPlugin } from './vendored/divs';
import { figureDivsPlugin } from './vendored/figure-divs';
import { figuresPlugin } from './vendored/figures';
import gridTableRulePlugin from './vendored/gridtables';
import { mathjaxPlugin } from './vendored/math';
import { shortcodePlugin } from './vendored/shortcodes';
import { spansPlugin } from './vendored/spans';
import { tableCaptionPlugin } from './vendored/table-captions';
import { renderFrontMatter } from './vendored/yaml';

declare const MacDown2: { flavors: { register(id: string, setup: (md: MarkdownIt, options: RenderOptions) => void): void } };

// `{#id .class key=val}` blocks may set anything but event handlers and URLs (raw HTML may be switched off, and
// Quick Look shows the page without a CSP).
const ATTRIBUTE = /^(?!on|href$|src|action|formaction|xlink)[\w:.-]+$/i;

// Divs are block rules without a source map in markdown-it; give each open token the span of its div (the preview
// patches and scrolls per mapped top-level block) and close any div the document left open, as Pandoc does.
function mapDivs(state: StateCore): void {
  const open: Token[] = [];
  for (const t of state.tokens) {
    if (t.type === 'pandoc_div_open') open.push(t);
    else if (t.type === 'pandoc_div_close') {
      const o = open.pop();
      if (o?.map && t.map) o.map = [o.map[0], t.map[1]];
    }
  }
  const lines = state.src.replace(/\n$/, '').split('\n').length;
  // Before the footnote section, which the footnote plugin appends to the token list.
  const tail = state.tokens.findIndex((t) => t.type === 'footnote_block_open');
  const closes: Token[] = [];
  while (open.length) {
    const o = open.pop()!;
    if (o.map) o.map = [o.map[0], lines];
    const close = new state.Token('pandoc_div_close', 'div', -1);
    close.block = true;
    closes.push(close);
  }
  state.tokens.splice(tail < 0 ? state.tokens.length : tail, 0, ...closes);
}

// A table caption (`: text` under a table) is moved into the table by the vendored plugin but keeps its own source map,
// which would make it a block of its own: fold the line into the table's span instead.
function mapCaptions(state: StateCore): void {
  const t = state.tokens;
  for (let i = 0; i < t.length; i++) {
    if (t[i].type !== 'table_caption' || t[i].nesting !== 1) continue;
    const cap = t[i].map;
    for (let j = i - 1; j >= 0 && cap; j--) {
      if (t[j].type === 'table_open') {
        if (t[j].map) t[j].map = [t[j].map![0], Math.max(t[j].map![1], cap[1])];
        break;
      }
    }
    t[i].map = null;
  }
}

const XREF = /^-?@((fig|tbl|eq|lst|sec|thm|lem|cor|prp|cnj|def|exm|exr)-[\w.-]*\w)([,;]*)$/; // the cite plugin leaves a trailing comma on the key
const XREF_LABEL: Record<string, string> = {
  fig: 'Figure', tbl: 'Table', eq: 'Equation', lst: 'Listing', sec: 'Section', thm: 'Theorem', lem: 'Lemma',
  cor: 'Corollary', prp: 'Proposition', cnj: 'Conjecture', def: 'Definition', exm: 'Example', exr: 'Exercise',
};

function setup(md: MarkdownIt, o: RenderOptions): void {
  const math = o.extensions.includes('math');
  const katexInline = md.renderer.rules.math_inline;
  const katexBlock = md.renderer.rules.math_block;

  md.use(spansPlugin);
  md.use(attrs, { allowedAttributes: [ATTRIBUTE] });
  md.use(figuresPlugin, { figcaption: true });
  md.use(gridTableRulePlugin);
  md.use(divPlugin);
  md.core.ruler.push('quarto_div_map', mapDivs);
  md.use(figureDivsPlugin);
  md.use(tableCaptionPlugin);
  md.core.ruler.push('quarto_caption_map', mapCaptions);
  md.use(citationPlugin);
  md.use(calloutPlugin);
  md.use(shortcodePlugin);
  md.use(codeCells);
  md.use(include);
  md.use(pandocBlankLine); // last: it edits the paragraph-terminator chain the plugins above have added to

  // `@fig-x` and friends link to their anchor; the label number needs the whole project, so it stays "?".
  const cite = md.renderer.rules.quarto_cite!;
  md.renderer.rules.quarto_cite = (tokens, idx, opts, env, slf) => {
    const m = XREF.exec(tokens[idx].content);
    return m
      ? `<a class="quarto-xref" href="#${escapeHtml(m[1])}">${XREF_LABEL[m[2]]} ?</a>${m[3]}`
      : cite(tokens, idx, opts, env, slf);
  };

  // The title block replaces the plain front matter element (still one element per block).
  if (md.renderer.rules.front_matter) {
    md.renderer.rules.front_matter = (tokens, idx, _o, _env, slf) =>
      `<div class="quarto-title-block"${slf.renderAttrs(tokens[idx])}>${renderFrontMatter(tokens, idx)}</div>\n`;
  }

  // Quarto's `$` rules (Pandoc's: `$x$` is math, `$$ … $$ {#eq-id}` may carry an id) replace the KaTeX plugin's dollar
  // rules; the vendored renderers produce MathJax markup, so KaTeX's own renderers go back in.
  if (math) {
    md.inline.ruler.disable('math_inline_dollar', true);
    md.block.ruler.disable('math_block_dollar', true);
    md.use(mathjaxPlugin);
    md.renderer.rules.math_inline = katexInline;
    md.renderer.rules.math_block = (tokens, idx, opts, env, slf) => {
      const html = katexBlock!(tokens, idx, opts, env, slf);
      const id = /^\{#([\w:.-]+)/.exec(tokens[idx].info)?.[1];
      return id ? html.replace(/^<p/, `<p id="${id}"`) : html;
    };
  }
}

MacDown2.flavors.register('quarto', setup);
