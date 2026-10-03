import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { DEFAULT_STYLE, styleLinks } from '../src/preview/styles.ts';

const dir = new URL('../src/preview/preview-styles/', import.meta.url);
const { styles } = JSON.parse(readFileSync(new URL('styles.json', dir), 'utf8'));
const byId = new Map(styles.map((s) => [s.id, s]));

test('styleLinks: a fixed style is two plain links, hljs before the style', () => {
  assert.deepEqual(styleLinks('paper', null), [
    { kind: 'hljs', href: 'hljs-themes/stackoverflow-light.css' },
    { kind: 'style', href: 'preview-styles/paper.css' },
  ]);
  assert.deepEqual(styleLinks('paper', 'paper'), styleLinks('paper', null));
});

test('styleLinks: follow-system gates each side on prefers-color-scheme', () => {
  const links = styleLinks('github', 'github-dark');
  assert.deepEqual(
    links.map((l) => [l.href, l.media]),
    [
      ['hljs-themes/github.css', '(prefers-color-scheme: light)'],
      ['preview-styles/github.css', '(prefers-color-scheme: light)'],
      ['hljs-themes/github-dark.css', '(prefers-color-scheme: dark)'],
      ['preview-styles/github-dark.css', '(prefers-color-scheme: dark)'],
    ],
  );
});

test('styleLinks: an unknown id falls back to the default instead of leaving the page unstyled', () => {
  assert.deepEqual(styleLinks('gone', null), styleLinks(DEFAULT_STYLE, null));
});

test('registry: every style has a source file, a known hljs theme, and a consistent light/dark partner', () => {
  assert.ok(byId.has(DEFAULT_STYLE));
  for (const s of styles) {
    assert.ok(existsSync(new URL(`${s.id}.css`, dir)), `${s.id}.css missing`);
    assert.ok(['light', 'dark'].includes(s.appearance), s.id);
    assert.ok(
      existsSync(new URL(`../hljs-themes/${s.hljs}.css`, dir)) ||
        existsSync(new URL(`../../../node_modules/highlight.js/styles/${s.hljs}.css`, dir)),
      `${s.id}: hljs theme ${s.hljs} not found`,
    );
    if (s.pair) {
      const p = byId.get(s.pair);
      assert.ok(p, `${s.id}: pair ${s.pair} unknown`);
      assert.equal(p.pair, s.id, `${s.id}: pair is not mutual`);
      assert.notEqual(p.appearance, s.appearance, `${s.id}: pair has the same appearance`);
    }
  }
});

test('preview.html ships the default style as fixed links, with no prefers-color-scheme left in it', () => {
  const html = readFileSync(new URL('../preview.html', dir), 'utf8');
  const d = byId.get(DEFAULT_STYLE);
  assert.match(html, new RegExp(`href="hljs-themes/${d.hljs}.css" data-md2-style="hljs"`));
  assert.match(html, new RegExp(`href="preview-styles/${d.id}.css" data-md2-style="style"`));
  assert.doesNotMatch(html, /prefers-color-scheme/);
});
