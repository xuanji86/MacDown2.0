// Renderer entry point. Bundled as an IIFE exposing `globalThis.MacDown2`; the same bundle
// runs in the preview WebView and in JavaScriptCore (Quick Look, CLI, export, tests).
import markdownit, { type MarkdownIt, type RendererRule, type StateCore, type Token } from 'markdown-it';
import { alert } from '@mdit/plugin-alert';
import { footnote } from '@mdit/plugin-footnote';
import { katex } from '@mdit/plugin-katex';
import { mark } from '@mdit/plugin-mark';
import { sub } from '@mdit/plugin-sub';
import { sup } from '@mdit/plugin-sup';
import { tasklist } from '@mdit/plugin-tasklist';
import emojiPlugin from 'markdown-it-emoji/lib/full.mjs';
import { cjkEmphasis } from './plugins/cjk-emphasis.ts';
import { codeBlocks } from './plugins/code.ts';
import { frontMatter, type FrontMatterDisplay } from './plugins/front-matter.ts';
import { pageBreak } from './plugins/page-break.ts';
import { toc } from './plugins/toc.ts';
import { underline } from './plugins/underline.ts';
import { createIncremental } from './incremental.ts';
import type { Segment } from '../preview/split-html.ts';
import { LRU, ownCopy } from './lru.ts';
import { hash53, slugify, textStats, type TextStats } from './text.ts';

export interface RenderOptions {
  flavor: string;
  renderChunks?: string[];
  // 'tables' | 'strikethrough' | 'autolink' | 'smartPunctuation' | 'mark' | 'sup' | 'sub' | 'underline'
  // | 'footnotes' | 'taskLists' | 'math' | 'toc' | 'frontMatter' | 'cjkEmphasis' | 'emoji'
  extensions: string[];
  hardBreaks: boolean;
  allowRawHTML: boolean;
  headingAnchors: boolean;
  codeHighlighting: boolean;
  codeLineNumbers: boolean;
  inlineDollarMath: boolean; // `$…$`; `$$…$$`, `\(…\)` and `\[…\]` are always on with `math`
  // Tag blocks with `data-line` / `data-line-end` (scroll sync, DOM patch); default on. Off for output that leaves the app: the
  // attributes are never written, so nothing has to be cut out of finished HTML afterwards (text could look like them).
  sourceLines?: boolean;
  frontMatterDisplay: FrontMatterDisplay;
  // Text of files a flavor may read while rendering, by path relative to the document folder (the app reads them
  // beforehand; a flavor chunk finds them in `env.files`). Not part of the instance cache key.
  files?: Record<string, string>;
  // Output that leaves the app (Copy HTML, export, PDF, CLI): active content removed from `html` by sanitize.chunk.js, which must be
  // loaded (JSCRenderer does it); without it the render throws rather than return the document's raw HTML. The preview does not set it.
  sanitize?: boolean;
}

export interface BlockMap { lineStart: number; lineEnd: number; hash: number }
export interface OutlineItem { level: number; text: string; slug: string; line: number }
// A task-list checkbox, as the renderer saw it in this text. `line`: the source line the preview page reports for it (its
// `data-line`: the item's paragraph in a loose item, else the item); `mark`: the line holding the `[ ]` (differs from `line`
// only when the item starts with an empty bullet line); `column`: UTF-16 offset of that `[` within line `mark`, whatever
// precedes it (quote marks, list markers, a footnote label), -1 if it could not be located. The app edits the source from
// this, not from its own idea of Markdown.
export interface TaskItem { line: number; mark: number; column: number }
export interface RenderResult {
  html: string;
  blocks: BlockMap[];
  tasks: TaskItem[];
  outline: OutlineItem[];
  stats: TextStats;
  frontMatter?: string; // raw text between the `---` (YAML) or `+++` (TOML, Hugo) fences; absent when there is none or the extension is off
}

type FlavorSetup = (md: MarkdownIt, options: RenderOptions) => void;
type Env = { outline: OutlineItem[]; hasToc?: boolean; files?: Record<string, string> }; // a type alias (not interface) so it is assignable to markdown-it's Env

const registry = new Map<string, FlavorSetup>([['markdown', () => {}]]);
const instances = new Map<string, MarkdownIt>();

// Flavor chunks (e.g. quarto.chunk.js) are loaded after this bundle and register themselves here.
// sanitize.chunk.js registers the HTML sanitizer here (parse5 is too big for this bundle, and the preview never needs it).
let sanitizeFn: ((html: string) => string) | undefined;
export const sanitizer = {
  register(fn: (html: string) => string): void {
    sanitizeFn = fn;
  },
};

export const flavors = {
  register(id: string, setup: FlavorSetup): void {
    registry.set(id, setup);
    for (const key of instances.keys()) if (key.startsWith(`${id}|`)) instances.delete(key);
    sections.forget(`${id}|`);
  },
  has(id: string): boolean {
    return registry.has(id);
  },
};

function plainText(inline: Token | undefined): string {
  return (inline?.children ?? [])
    .filter((c) => c.type === 'text' || c.type === 'code_inline')
    .map((c) => c.content)
    .join('');
}

// Runs last in the core chain: tags block tokens with source line ranges (scroll sync, DOM patch),
// assigns heading ids and collects the outline.
function annotate(state: StateCore, headingAnchors: boolean, sourceLines: boolean): void {
  const env = state.env as Env;
  const seen = new Map<string, number>();
  const tokens = state.tokens;
  for (let i = 0; i < tokens.length; i++) {
    const t = tokens[i];
    // GitHub alert: the plugin starts the block one line late (after the `[!NOTE]` marker line), which would leave that line
    // out of the block's range and its hash; the title token carries the real first line.
    if (t.type === 'alert_open' && t.map && tokens[i + 1]?.map) t.map[0] = tokens[i + 1].map![0];
    if (sourceLines && t.map && t.nesting >= 0 && t.type !== 'inline') {
      t.attrSet('data-line', String(t.map[0]));
      t.attrSet('data-line-end', String(t.map[1]));
    }
    if (t.type === 'heading_open') {
      const text = plainText(tokens[i + 1]);
      // an explicit `{#id}` (flavors that load markdown-it-attrs) wins over the generated slug
      const explicit = t.attrGet('id');
      const slug = explicit === null ? slugify(text, seen) : String(explicit);
      // [TOC] links need the ids even when anchors are switched off
      if ((headingAnchors || env.hasToc) && slug) t.attrSet('id', slug);
      env.outline.push({ level: Number(t.tag.slice(1)), text, slug, line: t.map?.[0] ?? 0 });
    }
  }
}

// GitHub shows the marker as "Note", "Tip", ...; the plugin would print whatever case the author typed.
const alertTitle: RendererRule = (tokens, idx) => {
  const kind = tokens[idx].content.toLowerCase();
  return `<p class="markdown-alert-title">${kind[0].toUpperCase()}${kind.slice(1)}</p>\n`;
};

// Everything the options change about a markdown-it instance (`files` and `sanitize` do not).
function optionsKey(o: RenderOptions): string {
  return `${o.flavor}|${JSON.stringify([
    [...new Set(o.extensions)].sort(),
    o.hardBreaks,
    o.allowRawHTML,
    o.headingAnchors,
    o.codeHighlighting,
    o.codeLineNumbers,
    o.inlineDollarMath,
    o.frontMatterDisplay,
    o.sourceLines !== false,
  ])}`;
}

// KaTeX output is a pure function of (formula, display mode) as long as no formula defines a global macro (`\gdef`,
// `\xdef`, `\global...`): those persist into the formulas after it within one render. A render whose text has one skips the
// memo (and the incremental renderer renders it whole). lazy: a fixed character budget; upgrade = per-document budgets.
const GLOBAL_TEX = /\\(?:gdef|xdef|global)/;
const typeset = new LRU<string>(4 * 1024 * 1024);
let typesetMemo = true;
const memoTeX = (kind: string, tex: string, render: () => string): string => {
  if (!typesetMemo) return render();
  const key = kind + tex;
  let html = typeset.get(key);
  if (html === undefined) {
    html = ownCopy(render());
    typeset.set(ownCopy(key), html, key.length + html.length);
  }
  return html;
};
function definesTeXMacros(source: string, options: RenderOptions): boolean {
  if (!options.extensions.includes('math')) return false;
  return GLOBAL_TEX.test(source) || Object.values(options.files ?? {}).some((text) => GLOBAL_TEX.test(text));
}

// One markdown-it instance with every plugin the options ask for; `annotate` is the last core rule.
function build(o: RenderOptions, annotateRule: (state: StateCore) => void): MarkdownIt {
  const setup = registry.get(o.flavor);
  if (!setup) throw new Error(`Unknown flavor "${o.flavor}"`);
  const ext = new Set(o.extensions);
  const md = markdownit({
    html: o.allowRawHTML,
    linkify: ext.has('autolink'),
    typographer: ext.has('smartPunctuation'),
    breaks: o.hardBreaks,
  });
  if (!ext.has('tables')) md.disable('table');
  if (!ext.has('strikethrough')) md.disable('strikethrough');
  if (ext.has('cjkEmphasis')) md.use(cjkEmphasis);
  // Math registers its inline rules before `escape`/`emphasis`, so `_` and `*` inside formulas are never emphasis.
  if (ext.has('math')) {
    md.use(katex, {
      delimiters: 'all',
      logger: () => 'ignore' as const, // KaTeX's default logger calls console.warn, which JavaScriptCore contexts may lack
    });
    // The plugin has no `$$`-only mode, so drop its inline `$…$` rule ("$5 and $10" is not a formula).
    if (!o.inlineDollarMath) md.inline.ruler.disable('math_inline_dollar');
    const mathInline = md.renderer.rules.math_inline!;
    md.renderer.rules.math_inline = (tokens, idx, opts, env, slf) =>
      memoTeX('i', tokens[idx].content, () => mathInline(tokens, idx, opts, env, slf));
    // The plugin renders `<p class='katex-block'>` without the token's attrs; keep data-line on the block.
    const mathBlock = md.renderer.rules.math_block!;
    md.renderer.rules.math_block = (tokens, idx, opts, env, slf) =>
      memoTeX('b', tokens[idx].content, () => mathBlock(tokens, idx, opts, env, slf)).replace(/^<p/, `<p${slf.renderAttrs(tokens[idx])}`);
  }
  if (ext.has('emoji')) md.use(emojiPlugin, { shortcuts: {} }); // `:smile:` only; `:)` and friends would rewrite plain text
  md.use(alert, { titleRenderer: alertTitle }); // `> [!NOTE]` … `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]`, `[!CAUTION]`
  // The plugin's rule, checked as a terminator (silent), can return with `lineMax` cut short and `parentType` left at 'alert':
  // from then on blank lines are not skipped, which shifts every later block's source lines, and a list item after it can
  // loop forever (`.\n>[!WARNING]\n-\n$` hung the page). A check must not change the state: put both back.
  const alertRule = md.block.ruler.__rules__.find((r) => r.name === 'alert')!;
  const alertCheck = alertRule.fn;
  md.block.ruler.at(
    'alert',
    (state, start, end, silent) => {
      if (!silent) return alertCheck(state, start, end, silent);
      const { lineMax, parentType } = state;
      const found = alertCheck(state, start, end, silent);
      state.lineMax = lineMax;
      state.parentType = parentType;
      return found;
    },
    { alt: alertRule.alt },
  );
  if (ext.has('mark')) md.use(mark);
  if (ext.has('sup')) md.use(sup);
  if (ext.has('sub')) md.use(sub);
  if (ext.has('footnotes')) md.use(footnote);
  if (ext.has('taskLists')) md.use(tasklist);
  if (ext.has('underline')) md.use(underline);
  if (ext.has('toc')) md.use(toc);
  md.use(pageBreak); // always on: `\newpage` as text is never what anyone wants
  if (ext.has('frontMatter')) md.use(frontMatter, o.frontMatterDisplay === 'table' ? 'table' : 'hidden');
  md.use(codeBlocks, { highlight: o.codeHighlighting, lineNumbers: o.codeLineNumbers });
  setup(md, o);
  md.core.ruler.push('macdown2_annotate', annotateRule);
  return md;
}

function instance(o: RenderOptions): MarkdownIt {
  const key = optionsKey(o);
  const cached = instances.get(key);
  if (cached) return cached;
  const md = build(o, (state) => annotate(state, o.headingAnchors, o.sourceLines !== false));
  instances.set(key, md);
  return md;
}

function collectText(tokens: Token[]): string {
  return tokens
    .filter((t) => t.type === 'inline')
    .map(plainText)
    .join('\n');
}

// Top-level blocks with their source line ranges and a hash of those lines.
function blocksOf(tokens: Token[], lines: string[]): BlockMap[] {
  return tokens
    .filter((t) => t.level === 0 && t.map && t.nesting >= 0 && t.type !== 'inline')
    .map((t) => {
      const [lineStart, lineEnd] = t.map!;
      return { lineStart, lineEnd, hash: hash53(lines.slice(lineStart, lineEnd).join('\n')) };
    });
}

function tasksOf(tokens: Token[], lines: string[]): TaskItem[] {
  const tasks: TaskItem[] = [];
  for (let i = 2; i < tokens.length; i++) {
    const t = tokens[i];
    if (t.type !== 'inline' || !t.map || t.children?.[0]?.type !== 'checkbox_input') continue;
    const owner = tokens[i - 1].hidden ? tokens[i - 2] : tokens[i - 1]; // a tight item's paragraph is not rendered, so its <li> carries the line
    if (!owner.map) continue;
    // The inline content starts at the `[` (the container's prefix is already stripped, leading blanks trimmed) and runs to the
    // end of its first source line, so that line ends with it: the last occurrence in the source line is the box.
    const head = t.content.split('\n', 1)[0];
    tasks.push({ line: owner.map[0], mark: t.map[0], column: (lines[t.map[0]] ?? '').lastIndexOf(head) });
  }
  return tasks;
}

export function renderResult(source: string, options: RenderOptions): RenderResult {
  const md = instance(options);
  const env: Env = { outline: [], files: options.files };
  let tokens: Token[];
  let html: string;
  typesetMemo = !definesTeXMacros(source, options);
  try {
    tokens = md.parse(source, env);
    html = md.renderer.render(tokens, md.options, env);
  } finally {
    // The KaTeX plugin clears macros defined with \gdef when `md.render` finishes, but we call parse and
    // renderer.render ourselves, so run an empty render to get the same reset.
    if (options.extensions.includes('math')) md.render('', { outline: [] });
    typesetMemo = true;
  }
  const lines = source.split('\n');
  const blocks = blocksOf(tokens, lines);
  const tasks = tasksOf(tokens, lines);
  const fm = tokens.find((t) => t.type === 'front_matter');
  if (options.sanitize && !sanitizeFn) throw new Error('sanitize was requested but sanitize.chunk.js is not loaded; refusing to return unsanitized HTML');
  const result: RenderResult = { html: options.sanitize ? sanitizeFn!(html) : html, blocks, tasks, outline: env.outline, stats: textStats(collectText(tokens)) };
  if (fm) result.frontMatter = fm.meta as unknown as string;
  return result;
}

// The live preview's entry: the same result as `renderResult` (byte for byte), computed per section of the document so a
// keystroke re-renders only the section it touched (incremental.ts), plus the HTML cut into its top-level blocks
// (`segments`, what the page's DOM patch needs). Documents or options it cannot do that for are rendered whole.
const sections = createIncremental({
  full: renderResult,
  build,
  key: optionsKey,
  plainText,
  collectText,
  blocksOf,
  tasksOf,
  canMemoTeX: (source, options) => !definesTeXMacros(source, options),
});
export const incremental = sections.api;
export function renderIncremental(source: string, options: RenderOptions): RenderResult & { segments?: Segment[] | null } {
  return sections.render(source, options);
}

// String-in/string-out entry used across the JavaScriptCore and WebView bridges.
export function render(source: string, optionsJSON: string): string {
  return JSON.stringify(renderResult(source, JSON.parse(optionsJSON) as RenderOptions));
}
