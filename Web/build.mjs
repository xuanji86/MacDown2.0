// Builds the vendored web assets: render.bundle.js, preview.bundle.js (+ preview.html, preview-styles/*.css + styles.json),
// katex/ (CSS + woff2 fonts), hljs-themes/, flavors.json, THIRD_PARTY_LICENSES.txt.
// Usage: node build.mjs [outDir]   (default: the WebAssets package resources; drift check passes a temp dir)
import { build } from 'esbuild';
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
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
  logLevel: 'warning',
});
cpSync(join(here, 'src/preview/preview.html'), join(outDir, 'preview.html'));

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

// License texts of every npm package that ended up in a bundle.
const packages = new Set();
for (const input of Object.keys(metafile.inputs)) {
  const m = input.match(/node_modules\/((?:@[^/]+\/)?[^/]+)\//);
  if (m) packages.add(m[1]);
}
const notices = [...packages].sort().map((name) => {
  const root = join(here, 'node_modules', name);
  const { version, license } = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
  const file = readdirSync(root).find((f) => /^licen[sc]e/i.test(f));
  if (!file) throw new Error(`${name}: no LICENSE file to bundle`);
  return `${name} ${version} (${license})\n\n${readFileSync(join(root, file), 'utf8').trim()}\n`;
});
notices.push(readFileSync(join(here, 'src/render/katex-fonts-license.txt'), 'utf8').trim() + '\n');
writeFileSync(join(outDir, 'THIRD_PARTY_LICENSES.txt'), notices.join(`\n${'-'.repeat(72)}\n\n`));
