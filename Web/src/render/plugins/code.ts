// Fenced code blocks: optional highlight.js (class output; themes are CSS files), optional per-line
// spans for CSS-counter line numbers, and a `data-lang` attribute the preview CSS can show as a label.
// `data-line` lands on <pre> (the top-level element), not on <code> as markdown-it's default does.
// A ```mermaid fence is an ordinary code block plus `class="mermaid-source"`: where scripts run (preview, print) the
// mermaid chunk swaps it for the diagram, everywhere else (HTML export, copy, Quick Look, JSC) it simply stays code.
import type { MarkdownIt, Token } from 'markdown-it';
import hljs from 'highlight.js/lib/core';
import bash from 'highlight.js/lib/languages/bash';
import c from 'highlight.js/lib/languages/c';
import cpp from 'highlight.js/lib/languages/cpp';
import csharp from 'highlight.js/lib/languages/csharp';
import css from 'highlight.js/lib/languages/css';
import diff from 'highlight.js/lib/languages/diff';
import dockerfile from 'highlight.js/lib/languages/dockerfile';
import go from 'highlight.js/lib/languages/go';
import graphql from 'highlight.js/lib/languages/graphql';
import ini from 'highlight.js/lib/languages/ini';
import java from 'highlight.js/lib/languages/java';
import javascript from 'highlight.js/lib/languages/javascript';
import json from 'highlight.js/lib/languages/json';
import kotlin from 'highlight.js/lib/languages/kotlin';
import latex from 'highlight.js/lib/languages/latex';
import less from 'highlight.js/lib/languages/less';
import lua from 'highlight.js/lib/languages/lua';
import makefile from 'highlight.js/lib/languages/makefile';
import markdown from 'highlight.js/lib/languages/markdown';
import objectivec from 'highlight.js/lib/languages/objectivec';
import perl from 'highlight.js/lib/languages/perl';
import php from 'highlight.js/lib/languages/php';
import plaintext from 'highlight.js/lib/languages/plaintext';
import powershell from 'highlight.js/lib/languages/powershell';
import python from 'highlight.js/lib/languages/python';
import r from 'highlight.js/lib/languages/r';
import ruby from 'highlight.js/lib/languages/ruby';
import rust from 'highlight.js/lib/languages/rust';
import scss from 'highlight.js/lib/languages/scss';
import shell from 'highlight.js/lib/languages/shell';
import sql from 'highlight.js/lib/languages/sql';
import swift from 'highlight.js/lib/languages/swift';
import typescript from 'highlight.js/lib/languages/typescript';
import xml from 'highlight.js/lib/languages/xml';
import yaml from 'highlight.js/lib/languages/yaml';

// lazy: the common languages only (aliases such as js/ts/py/sh/html/objc/c++/toml come with them);
// anything else renders as plain escaped text. Upgrade = add an import line here.
const languages = {
  bash, c, cpp, csharp, css, diff, dockerfile, go, graphql, ini, java, javascript, json, kotlin, latex, less, lua,
  makefile, markdown, objectivec, perl, php, plaintext, powershell, python, r, ruby, rust, scss, shell, sql, swift,
  typescript, xml, yaml,
};
for (const [name, def] of Object.entries(languages)) hljs.registerLanguage(name, def);

export interface CodeOptions { highlight: boolean; lineNumbers: boolean }

// Wraps each line in <span class="line">, closing and reopening hljs spans that cross a line break.
export function wrapLines(html: string): string {
  const lines: string[] = [];
  const open: string[] = [];
  let cur = '';
  for (const part of html.replace(/\n$/, '').split(/(<span[^>]*>|<\/span>|\n)/)) {
    if (part === '\n') {
      lines.push(cur + '</span>'.repeat(open.length));
      cur = open.join('');
      continue;
    }
    cur += part;
    if (part.startsWith('<span')) open.push(part);
    else if (part === '</span>') open.pop();
  }
  lines.push(cur);
  return `${lines.map((l) => `<span class="line">${l}</span>`).join('\n')}\n`;
}

export function codeBlocks(md: MarkdownIt, { highlight, lineNumbers }: CodeOptions): void {
  md.renderer.rules.fence = (tokens: Token[], idx, _o, _env, slf) => {
    const t = tokens[idx];
    const lang = t.info.trim().split(/\s+/)[0] ?? '';
    const known = highlight && lang !== '' && hljs.getLanguage(lang) !== undefined;
    let body = known
      ? hljs.highlight(t.content, { language: lang, ignoreIllegals: true }).value
      : md.utils.escapeHtml(t.content);
    if (lineNumbers && t.content !== '') body = wrapLines(body);

    const pre = { attrs: (t.attrs ?? []).map((a) => [...a]) } as Token;
    if (lang) pre.attrs!.push(['data-lang', lang]);
    for (const cls of [lang === 'mermaid' ? 'mermaid-source' : '', lineNumbers ? 'line-numbers' : '']) {
      const have = pre.attrs!.find(([k]) => k === 'class'); // a flavor (markdown-it-attrs) may have set one already
      if (cls && have) have[1] += ` ${cls}`;
      else if (cls) pre.attrs!.push(['class', cls]);
    }
    const codeClass = [known ? 'hljs' : '', lang ? `language-${lang}` : ''].filter(Boolean).join(' ');
    const code = codeClass ? ` class="${md.utils.escapeHtml(codeClass)}"` : '';
    return `<pre${slf.renderAttrs(pre)}><code${code}>${body}</code></pre>\n`;
  };
}
