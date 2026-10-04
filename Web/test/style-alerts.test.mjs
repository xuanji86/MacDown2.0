// Every preview style has to carry GitHub alerts: the shared structure in _base.css, and a palette of its own that reads on
// that style's page colour (the title is 600-weight body-size text: WCAG AA, 4.5:1).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { renderResult } from '../src/render/index.ts';

const dir = new URL('../src/preview/preview-styles/', import.meta.url);
const read = (name) => readFileSync(new URL(name, dir), 'utf8');
const { styles } = JSON.parse(read('styles.json'));
const baseCSS = read('_base.css');
const KINDS = ['note', 'tip', 'important', 'warning', 'caution'];

const rootVars = (css) => {
  const vars = {};
  for (const block of css.matchAll(/:root\s*\{([^}]*)\}/g)) for (const m of block[1].matchAll(/(--[\w-]+)\s*:\s*([^;]+);/g)) vars[m[1]] = m[2].trim();
  return vars;
};
const luminance = (hex) => {
  const [r, g, b] = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255).map((c) => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
};
const contrast = (a, b) => {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
};

test('_base.css styles the alert box, its title with a mask icon, and each of the five kinds', () => {
  assert.match(baseCSS, /\.markdown-alert\s*\{/);
  assert.match(baseCSS, /\.markdown-alert-title\s*\{/);
  assert.match(baseCSS, /\.markdown-alert-title::before\s*\{[^}]*mask:/);
  for (const k of KINDS) {
    assert.match(baseCSS, new RegExp(`\\.markdown-alert-${k}\\s*\\{[^}]*--alert-color: var\\(--alert-${k}\\)[^}]*--alert-icon: url\\("data:image/svg\\+xml`), k);
    assert.ok(`--alert-${k}` in rootVars(baseCSS), `${k} has a default colour`);
  }
});

test('the renderer emits exactly the classes the stylesheet knows', () => {
  for (const k of KINDS) {
    const { html } = renderResult(`> [!${k.toUpperCase()}]\n> body`, { flavor: 'markdown', extensions: [], hardBreaks: false, allowRawHTML: true, headingAnchors: true, codeHighlighting: true, codeLineNumbers: false, inlineDollarMath: false, frontMatterDisplay: 'hidden' });
    assert.match(html, new RegExp(`class="markdown-alert markdown-alert-${k}"`));
    assert.match(html, /class="markdown-alert-title"/);
    assert.ok(baseCSS.includes(`.markdown-alert-${k} `), k);
  }
});

for (const { id } of styles) {
  test(`style ${id}: its own five alert colours, readable on its page`, () => {
    const own = rootVars(read(`${id}.css`));
    const all = { ...rootVars(baseCSS), ...own };
    for (const k of KINDS) {
      const c = own[`--alert-${k}`];
      assert.match(c ?? '', /^#[0-9a-f]{6}$/i, `${id} sets --alert-${k}`);
      const ratio = contrast(c, all['--bg']);
      assert.ok(ratio >= 4.5, `${id}: --alert-${k} ${c} on ${all['--bg']} is ${ratio.toFixed(2)}:1`);
    }
    assert.equal(new Set(KINDS.map((k) => own[`--alert-${k}`])).size, 5, `${id}: the five kinds are told apart`);
  });
}
