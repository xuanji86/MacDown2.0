// Front matter at the very top of the document: YAML between `---` fences (via markdown-it-front-matter) or TOML between
// `+++` fences (Hugo; the rule below). The raw text always lands in RenderResult.frontMatter; `display` only decides what
// the preview shows. The element is emitted in every mode (hidden / table / raw text) so each block token keeps a DOM node.
import type { MarkdownIt, StateBlock, Token } from 'markdown-it';
import frontMatterPlugin from 'markdown-it-front-matter';
import { load } from 'js-yaml';
import { parse as parseToml } from 'smol-toml';

export type FrontMatterDisplay = 'hidden' | 'table';

function cell(value: unknown): string {
  if (value === null || value === undefined) return '';
  if (value instanceof Date) return value.toISOString().replace(/T00:00:00\.000Z$/, '');
  return typeof value === 'object' ? JSON.stringify(value) : String(value);
}

// `+++` on the first line, TOML, `+++` on a line of its own. An unclosed `+++` is not front matter (Hugo needs the closing
// fence too), unlike the YAML rule, which runs to the end of the document.
function tomlFrontMatter(state: StateBlock, startLine: number, endLine: number, silent: boolean): boolean {
  const lineText = (n: number): string => state.src.slice(state.bMarks[n], state.eMarks[n]).trimEnd();
  if (startLine !== 0 || state.tShift[0] !== 0 || lineText(0) !== '+++') return false;
  let close = 1;
  while (close < endLine && lineText(close) !== '+++') close++;
  if (close >= endLine) return false;
  if (silent) return true;
  const token = state.push('front_matter', '', 0);
  token.hidden = true;
  token.block = true;
  token.markup = '+++';
  token.map = [0, close + 1];
  // meta carries the raw text, as in the YAML plugin (Token.meta is typed as a record there, a string in practice)
  token.meta = (close > 1 ? state.src.slice(state.bMarks[1], state.bMarks[close] - 1) : '') as unknown as Record<string, unknown>;
  state.line = close + 1;
  return true;
}

function parseFront(raw: string, toml: boolean): unknown {
  try {
    return toml ? parseToml(raw) : load(raw);
  } catch {
    return undefined;
  }
}

export function frontMatter(md: MarkdownIt, display: FrontMatterDisplay): void {
  md.use(frontMatterPlugin, () => {});
  md.block.ruler.before('table', 'front_matter_toml', tomlFrontMatter);
  const esc = md.utils.escapeHtml;
  md.renderer.rules.front_matter = (tokens: Token[], idx, _o, _env, slf) => {
    const t = tokens[idx];
    const attrs = slf.renderAttrs(t);
    if (display === 'hidden') return `<div class="front-matter" hidden${attrs}></div>\n`;
    const raw = t.meta as unknown as string;
    const data = parseFront(raw, t.markup === '+++');
    // Not a mapping (or unparsable): show the source as is.
    if (typeof data !== 'object' || data === null || Array.isArray(data)) {
      return `<pre class="front-matter"${attrs}><code>${esc(raw)}</code></pre>\n`;
    }
    const rows = Object.entries(data as Record<string, unknown>)
      .map(([k, v]) => `<tr><th>${esc(k)}</th><td>${esc(cell(v))}</td></tr>`)
      .join('');
    return `<table class="front-matter"${attrs}><tbody>${rows}</tbody></table>\n`;
  };
}
