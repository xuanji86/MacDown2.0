// `{{< include file.qmd >}}` on a line of its own: the file's blocks are rendered in place, inside one
// <div class="quarto-include"> (one block for the preview's patching and scroll sync, mapped to the include line).
//
// The renderer cannot read files, so the app hands over every file the document can reach as `env.files`
// (`RenderOptions.files`: path relative to the document folder -> text; PLAN 4.6.1). This rule enforces the
// limits itself, whatever the map holds: paths stay inside the document folder, at most MAX_DEPTH levels,
// and a file that is already being included is refused (cycles).
// The Swift side (`QuartoIncludes`) walks the same paths with `resolveInclude`'s rules; keep the two in step.
import type { MarkdownIt, StateBlock, Token } from 'markdown-it';
import { escapeHtml } from '../escape.ts';

export const MAX_DEPTH = 5;

const INCLUDE = /^\{\{<\s*include\s+(?:"([^"]+)"|'([^']+)'|(\S+?))\s*>\}\}\s*$/;

type IncludeEnv = { files?: Record<string, string>; includeStack?: string[]; quartoOpenDivs?: Record<string, number>; quartoDivLevel?: number };

/** Path of `target` (as written in an include) relative to the document folder, given the folder of the file that
 *  contains it (`''` = the document folder). null: absolute, a URL, or outside the document folder. */
export function resolveInclude(fromDir: string, target: string): string | null {
  if (/^[a-z][a-z0-9+.-]*:/i.test(target) || target.startsWith('/') || target.includes('\0') || target.includes('\\')) return null;
  const parts = fromDir ? fromDir.split('/') : [];
  for (const seg of target.split('/')) {
    if (seg === '' || seg === '.') continue;
    if (seg === '..') {
      if (parts.length === 0) return null;
      parts.pop();
    } else parts.push(seg);
  }
  return parts.length ? parts.join('/') : null;
}

const dirOf = (path: string): string => path.slice(0, Math.max(0, path.lastIndexOf('/')));

export function include(md: MarkdownIt): void {
  md.block.ruler.before('paragraph', 'quarto_include', (state: StateBlock, start: number, _end: number, silent: boolean) => {
    const line = state.src.slice(state.bMarks[start] + state.tShift[start], state.eMarks[start]);
    if (state.sCount[start] - state.blkIndent >= 4 || !line.startsWith('{{<')) return false;
    const m = INCLUDE.exec(line.trim());
    if (!m) return false;
    if (silent) return true;

    const env = state.env as IncludeEnv;
    const stack = env.includeStack ?? [];
    const target = m[1] ?? m[2] ?? m[3];
    const fail = (reason: string): true => {
      const t = state.push('quarto_include_error', 'div', 0);
      t.block = true;
      t.map = [start, start + 1];
      t.meta = { target, reason };
      state.line = start + 1;
      return true;
    };

    const path = resolveInclude(stack.length ? dirOf(stack[stack.length - 1]) : '', target);
    if (path === null) return fail('outside the document folder');
    if (stack.length >= MAX_DEPTH) return fail(`more than ${MAX_DEPTH} levels deep`);
    if (stack.includes(path)) return fail('circular include');
    const text = env.files?.[path];
    if (text === undefined) return fail('not found');

    // Block-parse the file into tokens of its own and splice them between our wrapper tokens: the rest of the pipeline
    // (inline pass, attributes, callouts, ...) then runs once over everything, as if the text had been written here.
    // The env is shared (footnotes, references) except for the div bookkeeping and the include stack.
    const saved = { divs: env.quartoOpenDivs, level: env.quartoDivLevel, stack: env.includeStack };
    env.quartoOpenDivs = {};
    env.quartoDivLevel = 0;
    env.includeStack = [...stack, path];
    const inner: Token[] = [];
    try {
      md.block.parse(text.replace(/\r\n?/g, '\n').replace(/\0/g, '\uFFFD'), md, env, inner);
    } finally {
      env.quartoOpenDivs = saved.divs;
      env.quartoDivLevel = saved.level;
      env.includeStack = saved.stack;
    }
    const open = state.push('quarto_include_open', 'div', 1);
    open.block = true;
    open.map = [start, start + 1];
    open.attrs = [['class', 'quarto-include'], ['data-include', path]];
    let unclosed = 0; // a div the file leaves open must not swallow what follows the include
    for (const t of inner) {
      if (t.type === 'front_matter') continue; // the included file's own YAML header is not content
      t.level += state.level;
      if (t.map) t.map = [start, start + 1];
      if (t.type === 'pandoc_div_open') unclosed++;
      else if (t.type === 'pandoc_div_close' && unclosed > 0) unclosed--;
      state.tokens.push(t);
    }
    for (; unclosed > 0; unclosed--) {
      const close = new state.Token('pandoc_div_close', 'div', -1);
      close.block = true;
      state.tokens.push(close);
    }
    state.push('quarto_include_close', 'div', -1).block = true;
    state.line = start + 1;
    return true;
  });

  md.renderer.rules.quarto_include_error = (tokens: Token[], idx, _o, _env, slf) => {
    const t = tokens[idx];
    const { target, reason } = t.meta as { target: string; reason: string };
    return `<div class="quarto-include quarto-include-error"${slf.renderAttrs(t)}>include <code>${escapeHtml(target)}</code>: ${reason}</div>\n`;
  };
}
