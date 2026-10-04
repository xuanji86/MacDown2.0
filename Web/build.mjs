// Builds the vendored web assets: render.bundle.js, preview.bundle.js (+ preview.html, preview-styles/*.css + styles.json),
// katex/ (CSS + woff2 fonts), hljs-themes/, flavors.json, quarto.chunk.js + quarto-approx.css, mermaid.chunk.js,
// print.css, THIRD_PARTY_LICENSES.txt.
// Usage: node build.mjs [outDir]   (default: the WebAssets package resources; drift check passes a temp dir)
import { build } from 'esbuild';
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const outDir = process.argv[2] ?? join(here, '../Packages/WebAssets/Sources/WebAssets/Resources');
mkdirSync(outDir, { recursive: true });

const { metafile } = await build({
  entryPoints: [join(here, 'src/render/index.ts')],
  outfile: join(outDir, 'render.bundle.js'),
  bundle: true,
  format: 'iife',
  globalName: 'MacDown2',
  target: 'es2022',
  minify: true,
  legalComments: 'none', // third-party notices go to THIRD_PARTY_LICENSES.txt instead
  metafile: true,
  tsconfigRaw: '{}', // tsconfig.json is for tsc only; its `strict` would make esbuild prepend "use strict" to the bundles
  logLevel: 'warning',
});

// Preview page: its own bundle (no npm deps, so nothing to add to the license notices) + static files as-is.
await build({
  entryPoints: [join(here, 'src/preview/main.ts')],
  outfile: join(outDir, 'preview.bundle.js'),
  bundle: true,
  format: 'iife',
  globalName: 'MacDown2Preview',
  target: 'es2022',
  minify: true,
  legalComments: 'none',
  tsconfigRaw: '{}', // tsconfig.json is for tsc only; its `strict` would make esbuild prepend "use strict" to the bundles
  logLevel: 'warning',
});
cpSync(join(here, 'src/preview/preview.html'), join(outDir, 'preview.html'));
cpSync(join(here, 'src/preview/print.css'), join(outDir, 'print.css')); // paper rules; HTMLExporter inlines it into exported / printed pages

// Quarto flavor chunk (PLAN 4.1.2): loaded after render.bundle.js, only for .qmd while the extension is on. markdown-it
// itself is not bundled (the chunk only imports its types), the main bundle never contains any of this.
const quarto = await build({
  entryPoints: [join(here, 'src/quarto/index.ts')],
  outfile: join(outDir, 'quarto.chunk.js'),
  bundle: true,
  format: 'iife',
  target: 'es2022',
  minify: true,
  legalComments: 'none',
  metafile: true,
  tsconfigRaw: '{}',
  logLevel: 'warning',
});
cpSync(join(here, 'src/quarto/quarto-approx.css'), join(outDir, 'quarto-approx.css'));
const CHUNK_BUDGET = 120 * 1024; // PLAN 4.1.2
const chunkSize = statSync(join(outDir, 'quarto.chunk.js')).size;
if (chunkSize > CHUNK_BUDGET) throw new Error(`quarto.chunk.js is ${chunkSize} bytes, over the ${CHUNK_BUDGET} budget`);

// Mermaid chunk (PLAN 4.1.2): the preview page loads it with a nonce'd <script> and the print page evaluates it, only when
// a document has a mermaid block. It is big (every diagram type, d3, layout engines) and deliberately in neither
// bundle above; Scripts/check-web-drift.sh asserts it does not leak into them.
//
// elkjs (Mermaid's optional `layout: elk`) is EPL-2.0 with no GPL secondary-licence notice, which GPL-3.0 cannot ship
// with, so it is replaced by a stub: dagre (the default layout) is untouched, and a document that asks for ELK gets a
// clear error on its diagram. Two hooks: the `elkjs` package itself, and Mermaid's own `elk-<hash>.mjs` layout module
// (its only importer; the hash changes with the pinned version, and the drift check fails if elk code ever leaks in).
const ELK_STUB = `export const render = async () => { throw new Error('ELK 布局未内置（许可原因）/ ELK layout is not bundled (licence)'); };
export default class ELK { constructor() { throw new Error('ELK 布局未内置（许可原因）/ ELK layout is not bundled (licence)'); } }`;
const withoutElk = {
  name: 'without-elk',
  setup(b) {
    b.onResolve({ filter: /^elkjs(\/|$)|\/elk-[A-Z0-9]+\.mjs$/ }, (a) => ({ path: a.path, namespace: 'elk-stub' }));
    b.onLoad({ filter: /.*/, namespace: 'elk-stub' }, () => ({ contents: ELK_STUB, loader: 'js' }));
  },
};
const mermaid = await build({
  plugins: [withoutElk],
  entryPoints: [join(here, 'src/mermaid/index.ts')],
  outfile: join(outDir, 'mermaid.chunk.js'),
  bundle: true,
  format: 'iife',
  globalName: 'MacDown2Mermaid',
  target: 'es2022',
  minify: true,
  legalComments: 'none',
  metafile: true,
  tsconfigRaw: '{}',
  logLevel: 'warning',
});

// Preview styles: _base.css is prepended to every <style>.css; styles.json (the registry, also bundled into the page and
// read by the app) says which hljs theme and light/dark partner each one has.
const stylesDir = join(here, 'src/preview/preview-styles');
const base = readFileSync(join(stylesDir, '_base.css'), 'utf8');
const registry = JSON.parse(readFileSync(join(stylesDir, 'styles.json'), 'utf8'));
mkdirSync(join(outDir, 'preview-styles'), { recursive: true });
cpSync(join(stylesDir, 'styles.json'), join(outDir, 'preview-styles/styles.json'));
for (const { id } of registry.styles) {
  writeFileSync(join(outDir, 'preview-styles', `${id}.css`), `${base}\n${readFileSync(join(stylesDir, `${id}.css`), 'utf8')}`);
}

// KaTeX stylesheet + fonts. Only woff2 is shipped (every WebKit this app runs on has it), so the woff/ttf
// fallbacks are dropped from the CSS instead of left pointing at files that are not there.
const katexDist = join(here, 'node_modules/katex/dist');
mkdirSync(join(outDir, 'katex/fonts'), { recursive: true });
writeFileSync(
  join(outDir, 'katex/katex.min.css'),
  readFileSync(join(katexDist, 'katex.min.css'), 'utf8').replace(/,url\([^)]+\.woff\) format\("woff"\),url\([^)]+\.ttf\) format\("truetype"\)/g, ''),
);
for (const f of readdirSync(join(katexDist, 'fonts')).filter((f) => f.endsWith('.woff2'))) {
  cpSync(join(katexDist, 'fonts', f), join(outDir, 'katex/fonts', f));
}

// highlight.js themes (unminified, so each file keeps its author/licence header).
const hljsThemes = ['github', 'github-dark', 'xcode', 'atom-one-light', 'atom-one-dark', 'monokai', 'a11y-light', 'a11y-dark', 'stackoverflow-light'];
mkdirSync(join(outDir, 'hljs-themes'), { recursive: true });
for (const name of hljsThemes) {
  cpSync(join(here, 'node_modules/highlight.js/styles', `${name}.css`), join(outDir, 'hljs-themes', `${name}.css`));
}
// Our own themes (stock Solarized is too faint to read, see the files): same folder, same naming.
cpSync(join(here, 'src/preview/hljs-themes'), join(outDir, 'hljs-themes'), { recursive: true });

// flavors.json: merged from src/<flavor>/manifest.json (Quick Look / CLI read it without linking extensions).
const flavors = {};
for (const dir of readdirSync(join(here, 'src'))) {
  const manifest = join(here, 'src', dir, 'manifest.json');
  if (existsSync(manifest)) flavors[dir] = JSON.parse(readFileSync(manifest, 'utf8'));
}
writeFileSync(join(outDir, 'flavors.json'), `${JSON.stringify(flavors, null, 2)}\n`);

// License texts of every npm package that ended up in a bundle. Mermaid's dependency tree may nest packages
// (node_modules/a/node_modules/b), so the innermost node_modules segment names the package and gives its directory.
const packages = new Map();
for (const input of [...Object.keys(metafile.inputs), ...Object.keys(quarto.metafile.inputs), ...Object.keys(mermaid.metafile.inputs)]) {
  const m = input.slice(Math.max(input.indexOf('node_modules/'), 0)).match(/^(.*node_modules\/(?:@[^/]+\/)?[^/]+)\//); // input paths are relative to the cwd
  if (m) packages.set(m[1], join(here, m[1]));
}
const notices = [...packages.values()].sort().map((root) => {
  const { name, version, license } = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
  const file = readdirSync(root).find((f) => /^licen[sc]e/i.test(f));
  if (!file) throw new Error(`${name}: no LICENSE file to bundle`);
  const label = typeof license === 'string' ? ` (${license})` : ''; // khroma ships a LICENSE file but no license field
  return `${name} ${version}${label}\n\n${readFileSync(join(root, file), 'utf8').trim()}\n`;
});
notices.push(readFileSync(join(here, 'src/render/katex-fonts-license.txt'), 'utf8').trim() + '\n');
notices.push(readFileSync(join(here, 'src/quarto/vendored/LICENSE.txt'), 'utf8').trim() + '\n');
notices.push(readFileSync(join(here, 'src/render/tomorrow-theme-license.txt'), 'utf8').trim() + '\n');
writeFileSync(join(outDir, 'THIRD_PARTY_LICENSES.txt'), notices.join(`\n${'-'.repeat(72)}\n\n`));
