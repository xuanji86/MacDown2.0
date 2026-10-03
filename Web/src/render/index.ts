// Renderer entry point. Bundled as an IIFE exposing `globalThis.MacDown2`; the same bundle
// runs in the preview WebView and in JavaScriptCore (Quick Look, CLI, export, tests).
import markdownit, { type MarkdownIt, type StateCore, type Token } from 'markdown-it';
import { hash53, slugify, textStats, type TextStats } from './text.ts';

export interface RenderOptions {
  flavor: string;
  renderChunks?: string[];
  extensions: string[]; // 'tables' | 'strikethrough' | 'autolink' | 'smartPunctuation'
  hardBreaks: boolean;
  allowRawHTML: boolean;
  headingAnchors: boolean;
}

export interface BlockMap { lineStart: number; lineEnd: number; hash: number }
export interface OutlineItem { level: number; text: string; slug: string; line: number }
export interface RenderResult { html: string; blocks: BlockMap[]; outline: OutlineItem[]; stats: TextStats }

type FlavorSetup = (md: MarkdownIt, options: RenderOptions) => void;
interface Env { outline: OutlineItem[] }

const registry = new Map<string, FlavorSetup>([['markdown', () => {}]]);
const instances = new Map<string, MarkdownIt>();

// Flavor chunks (e.g. quarto.chunk.js) are loaded after this bundle and register themselves here.
export const flavors = {
  register(id: string, setup: FlavorSetup): void {
    registry.set(id, setup);
    for (const key of instances.keys()) if (key.startsWith(`${id}|`)) instances.delete(key);
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
function annotate(state: StateCore, headingAnchors: boolean): void {
  const env = state.env as Env;
  const seen = new Map<string, number>();
  const tokens = state.tokens;
  for (let i = 0; i < tokens.length; i++) {
    const t = tokens[i];
    if (t.map && t.nesting >= 0 && t.type !== 'inline') {
      t.attrSet('data-line', String(t.map[0]));
      t.attrSet('data-line-end', String(t.map[1]));
    }
    if (t.type === 'heading_open') {
      const text = plainText(tokens[i + 1]);
      const slug = slugify(text, seen);
      if (headingAnchors && slug) t.attrSet('id', slug);
      env.outline.push({ level: Number(t.tag.slice(1)), text, slug, line: t.map?.[0] ?? 0 });
    }
  }
}

function instance(o: RenderOptions): MarkdownIt {
  const setup = registry.get(o.flavor);
  if (!setup) throw new Error(`Unknown flavor "${o.flavor}"`);
  const ext = new Set(o.extensions);
  const key = `${o.flavor}|${JSON.stringify([[...ext].sort(), o.hardBreaks, o.allowRawHTML, o.headingAnchors])}`;
  const cached = instances.get(key);
  if (cached) return cached;

  const md = markdownit({
    html: o.allowRawHTML,
    linkify: ext.has('autolink'),
    typographer: ext.has('smartPunctuation'),
    breaks: o.hardBreaks,
  });
  if (!ext.has('tables')) md.disable('table');
  if (!ext.has('strikethrough')) md.disable('strikethrough');
  setup(md, o);
  md.core.ruler.push('macdown2_annotate', (state) => annotate(state, o.headingAnchors));
  instances.set(key, md);
  return md;
}

function collectText(tokens: Token[]): string {
  return tokens
    .filter((t) => t.type === 'inline')
    .map(plainText)
    .join('\n');
}

export function renderResult(source: string, options: RenderOptions): RenderResult {
  const md = instance(options);
  const env: Env = { outline: [] };
  const tokens = md.parse(source, env);
  const html = md.renderer.render(tokens, md.options, env);
  const lines = source.split('\n');
  const blocks = tokens
    .filter((t) => t.level === 0 && t.map && t.nesting >= 0 && t.type !== 'inline')
    .map((t) => {
      const [lineStart, lineEnd] = t.map!;
      return { lineStart, lineEnd, hash: hash53(lines.slice(lineStart, lineEnd).join('\n')) };
    });
  return { html, blocks, outline: env.outline, stats: textStats(collectText(tokens)) };
}

// String-in/string-out entry used across the JavaScriptCore and WebView bridges.
export function render(source: string, optionsJSON: string): string {
  return JSON.stringify(renderResult(source, JSON.parse(optionsJSON) as RenderOptions));
}
