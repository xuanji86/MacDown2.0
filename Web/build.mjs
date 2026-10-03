// Builds the vendored web assets: render.bundle.js, preview.bundle.js (+ preview.html, preview-styles/),
// flavors.json, THIRD_PARTY_LICENSES.txt.
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
cpSync(join(here, 'src/preview/preview-styles'), join(outDir, 'preview-styles'), { recursive: true });

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
writeFileSync(join(outDir, 'THIRD_PARTY_LICENSES.txt'), notices.join(`\n${'-'.repeat(72)}\n\n`));
