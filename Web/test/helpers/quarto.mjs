// Loads the real quarto.chunk.js (built in memory with the same options as build.mjs) next to the render module, the
// way the app does: the chunk finds `MacDown2.flavors` as a global and registers itself.
import { build } from 'esbuild';
import { runInThisContext } from 'node:vm';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as render from '../../src/render/index.ts';

const here = dirname(fileURLToPath(import.meta.url));

export async function chunkSource() {
  const result = await build({
    entryPoints: [join(here, '../../src/quarto/index.ts')],
    bundle: true,
    write: false,
    format: 'iife',
    target: 'es2022',
    minify: true,
    legalComments: 'none',
    tsconfigRaw: '{}',
    logLevel: 'warning',
  });
  return result.outputFiles[0].text;
}

export async function loadQuarto() {
  globalThis.MacDown2 = render;
  runInThisContext(await chunkSource(), { filename: 'quarto.chunk.js' });
  return render;
}

export const ALL_EXTENSIONS = ['tables', 'strikethrough', 'autolink', 'mark', 'sup', 'sub', 'underline', 'footnotes', 'taskLists', 'math', 'toc', 'frontMatter', 'cjkEmphasis'];

export const quartoOptions = (over = {}) => ({
  flavor: 'quarto',
  renderChunks: ['quarto.chunk.js'],
  extensions: ALL_EXTENSIONS,
  hardBreaks: false,
  allowRawHTML: true,
  headingAnchors: true,
  codeHighlighting: true,
  codeLineNumbers: false,
  inlineDollarMath: false,
  frontMatterDisplay: 'hidden',
  ...over,
});

/** HTML without the source-line attributes, for readable assertions. */
export const plain = (html) => html.replace(/ data-line(?:-end)?="\d+"/g, '').trim();
