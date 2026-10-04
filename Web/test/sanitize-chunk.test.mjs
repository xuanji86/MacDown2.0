// The sanitizer lives in sanitize.chunk.js, not in render.bundle.js. A render that asks for sanitized output without the chunk loaded
// must fail, never return the document's raw HTML; with the real chunk loaded (built here with the options of build.mjs, registered
// through the global `MacDown2` the way the app does) it sanitizes. This file runs in its own process, so nothing has registered yet.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runInThisContext } from 'node:vm';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';
import * as render from '../src/render/index.ts';

const here = dirname(fileURLToPath(import.meta.url));
const options = {
  flavor: 'markdown',
  extensions: ['tables', 'math', 'footnotes', 'taskLists'],
  hardBreaks: false,
  allowRawHTML: true,
  headingAnchors: true,
  codeHighlighting: true,
  codeLineNumbers: false,
  inlineDollarMath: false,
  frontMatterDisplay: 'hidden',
};
const hostile = '# T\n\n<img src=x onerror=alert(1)>\n\n<script>alert(2)</script>\n';

test('sanitize: true without the chunk throws and returns nothing', () => {
  assert.throws(() => render.renderResult(hostile, { ...options, sanitize: true }), /sanitize\.chunk\.js is not loaded/);
  assert.throws(() => JSON.parse(render.render(hostile, JSON.stringify({ ...options, sanitize: true }))), /not loaded/); // the string entry the JSC bridge calls
  assert.match(render.renderResult(hostile, options).html, /onerror/); // the preview's render is untouched
});

test('with the real chunk loaded the same render is sanitized, and a second render still is', async () => {
  const chunk = (
    await build({ entryPoints: [join(here, '../src/sanitize/index.ts')], bundle: true, write: false, format: 'iife', target: 'es2022', minify: true, tsconfigRaw: '{}', logLevel: 'warning' })
  ).outputFiles[0].text;
  globalThis.MacDown2 = render;
  runInThisContext(chunk, { filename: 'sanitize.chunk.js' });
  for (let i = 0; i < 2; i++) {
    const out = render.renderResult(hostile, { ...options, sanitize: true }).html;
    assert.doesNotMatch(out, /onerror|<script|alert/);
    assert.match(out, /<h1[^>]*>T<\/h1>/);
  }
});
