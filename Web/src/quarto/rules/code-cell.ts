// Quarto code cells, shown but never run (PLAN 4.6.1).
//   ```{python}            -> a cell: language badge, a small table of its `#|` options, highlighted code
//   ```{.python}           -> plain highlighted code (Quarto's non-executable form)
//   `{python} expr`, `r expr` -> inline cell: <code class="inline-cell" data-lang="…">
// The fence rule must run before markdown-it-attrs, which would take `{python}` for an attribute block.
import type { MarkdownIt, StateCore, Token } from 'markdown-it';
import { escapeHtml } from '../escape.ts';
import { loadYaml } from '../vendored/core-yaml.ts';

const CELL = /^\{([A-Za-z][\w+-]*)(?:[\s,][^}]*)?\}$/; // {python}, {r, echo=FALSE}; a leading "." is the non-executable form
const PLAIN = /^\{\.([A-Za-z][\w+-]*)(?:\s[^}]*)?\}$/; // {.python .numberLines}
const OPTION_LINE = /^(?:#|\/\/|%%)\|[ \t]?(.*)$/;
const INLINE = /^(?:\{([A-Za-z][\w+-]*)\}|(r))\s+(\S[\s\S]*)$/; // `{python} expr`, `r expr`
const HLJS_ALIAS: Record<string, string> = { ojs: 'javascript', jl: 'julia' };
const MAX_OPTION_VALUE = 80; // lazy: long option values (fig-cap prose) are cut in the header table; the code view is unaffected

export interface CellMeta {
  lang: string;
  options: [string, string][];
  inner: Token; // an ordinary fence (language + code without the option lines) the core renderer highlights
}

// Leading `#|` lines are the cell's options (YAML after the comment prefix).
function splitOptions(code: string): { options: [string, string][]; body: string } {
  const lines = code.split('\n');
  let n = 0;
  const yaml: string[] = [];
  while (n < lines.length && OPTION_LINE.test(lines[n])) yaml.push(OPTION_LINE.exec(lines[n++])![1]);
  if (n === 0) return { options: [], body: code };
  let options: [string, string][];
  try {
    const parsed = loadYaml(yaml.join('\n'));
    options =
      parsed && typeof parsed === 'object' && !Array.isArray(parsed)
        ? Object.entries(parsed as Record<string, unknown>).map(([k, v]) => [k, typeof v === 'string' ? v : JSON.stringify(v)])
        : yaml.map((l) => ['', l]);
  } catch {
    options = yaml.map((l) => ['', l]); // not YAML: show the lines as they are
  }
  return { options, body: lines.slice(n).join('\n') };
}

export function codeCells(md: MarkdownIt): void {
  const fence = md.renderer.rules.fence!;

  md.core.ruler.before('curly_attributes', 'quarto_code_cells', (state: StateCore) => {
    for (const t of state.tokens) {
      if (t.type !== 'fence') continue;
      const info = t.info.trim();
      const plain = PLAIN.exec(info);
      if (plain) {
        t.info = plain[1];
        continue;
      }
      const cell = CELL.exec(info);
      if (!cell) continue;
      const lang = cell[1];
      const { options, body } = splitOptions(t.content);
      const inner = new state.Token('fence', 'code', 0);
      inner.info = HLJS_ALIAS[lang] ?? lang;
      inner.content = body;
      t.type = 'quarto_cell';
      t.info = '';
      t.meta = { lang, options, inner } satisfies CellMeta;
    }
  });

  md.renderer.rules.quarto_cell = (tokens, idx, opts, env, slf) => {
    const t = tokens[idx];
    const { lang, options, inner } = t.meta as unknown as CellMeta;
    const label = options.find(([k]) => k === 'label')?.[1];
    const cut = (v: string): string => (v.length > MAX_OPTION_VALUE ? `${v.slice(0, MAX_OPTION_VALUE)}…` : v);
    const rows = options.map(([k, v]) => `<tr><th>${escapeHtml(k)}</th><td>${escapeHtml(cut(v))}</td></tr>`).join('');
    const table = rows ? `<table class="quarto-cell-options"><tbody>${rows}</tbody></table>` : '';
    const attrs = { attrs: [...(t.attrs ?? [])] } as Token;
    attrs.attrs!.push(['data-lang', lang]);
    if (label && /^[\w:.-]+$/.test(label)) attrs.attrs!.push(['id', label]); // `fig-`/`tbl-` labels are cross-reference targets
    const code = fence([inner], 0, opts, env, slf);
    return (
      `<div class="quarto-cell"${slf.renderAttrs(attrs)}>` +
      `<div class="quarto-cell-header"><span class="quarto-cell-lang">${escapeHtml(lang)}</span>` +
      `<span class="quarto-cell-note">code cell · not executed</span>${table}</div>${code}</div>\n`
    );
  };

  // Inline cells: after the inline pass, so code spans already exist.
  md.core.ruler.push('quarto_inline_cells', (state: StateCore) => {
    for (const t of state.tokens) {
      if (t.type !== 'inline') continue;
      for (const c of t.children ?? []) {
        if (c.type !== 'code_inline') continue;
        const m = INLINE.exec(c.content);
        if (!m) continue;
        c.attrJoin('class', 'inline-cell');
        c.attrSet('data-lang', m[1] ?? m[2]);
        c.content = m[3];
      }
    }
  });
}
