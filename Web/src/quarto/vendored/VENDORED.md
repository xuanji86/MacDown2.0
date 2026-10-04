# Vendored: Quarto markdown-it plugins

Source: <https://github.com/quarto-dev/quarto>, `packages/core/src/markdownit/` (plus `utils/` it imports and `packages/core/src/yaml.ts`)
at commit `a83c5cc597e61a28700ceacda86c15b9ef565e82` (2026-09-30, `main`).

Licence: **MIT**, Copyright Posit Software, PBC (the repo's `packages/core/package.json` and `apps/vscode/LICENSE`).
The task brief expected AGPL; the repository is MIT, which is compatible with this project's GPL-3.0 and only needs the
notice kept: it is in `LICENSE.txt` here and goes into `THIRD_PARTY_LICENSES.txt` via `build.mjs`. The files keep their
original headers (gridtables: Bas Verweij, yaml.ts: ParkSB, math.ts: derived from markdown-it-mathjax3).

Only `quarto.chunk.js` contains this code; the main render bundle never does (`Scripts/check-web-drift.sh` and
`Web/test/quarto.test.mjs` assert it). One year between syncs is fine (PLAN risk table): re-copy, re-apply the table below.

## Used

`callouts`, `cites`, `divs`, `figure-divs`, `figures`, `gridtables/`, `math`, `shortcodes`, `spans`, `table-captions`,
`yaml` (+ `utils/html|markdownit|tok`). Not used: `decorator.ts` (attribute pills on divs/headings, not wanted in a
preview), `index.ts`. `yaml.ts` is used for `renderFrontMatter` only: the core bundle already tokenises front matter and
keeps the raw text for the app, so `yamlPlugin`'s own block rule is not registered (it would duplicate the
`front_matter` rule name).

## Changes (everything else is verbatim; grep `MacDown2` in the files)

| File | Change | Why |
|---|---|---|
| `divs.ts` | open and close tokens get `map = [start, start + 1]` | the preview patches/scrolls per top-level block with a source line range; unmapped divs made every `.qmd` with a div rebuild the whole page. `quarto_div_map` in `../index.ts` stretches the open token to its closing line |
| `callouts.ts` | callout open token keeps the div's `map`; the title is HTML-escaped (`../escape.ts`); the scanning branch became a local `scan()` and the first token after the title goes through it | upstream dropped that token (a callout without a heading lost its first `<p>`, `Warning body.</p>`), and pushed it unexamined after a heading (a div or the closing `:::` as first child broke the depth count) |
| `cites.ts` | cite text is HTML-escaped | it was interpolated into `<code>` unescaped |
| `table-captions.ts` | `if (start)` -> `if (start !== undefined)` | a table that is token 0 (document starting with a table) never got its caption |
| `yaml.ts` | `renderFrontMatter` exported; every interpolated value HTML-escaped (title, subtitle, abstract, date, authors, affiliations, DOI, the remaining YAML); `loadYaml` comes from `core-yaml.ts` | values were interpolated into markup unescaped; raw HTML may be switched off |
| `core-yaml.ts` | new: `loadYaml` copied from `packages/core/src/yaml.ts` (the rest of that file needs `Metadata` etc.) | |

Dependencies added for the chunk: `markdown-it-attrs` 4.5.0 (the plugins rely on it for `{#id .class}`; PLAN 4.1.2),
`wcwidth` 1.0.1 (gridtables), `js-yaml` (already in the main bundle, bundled again here: the chunk cannot share it).

Not taken from upstream: `extend.ts`'s `kCloseDivNoBlock` text rewrite (it inserts lines, which would shift the source
map; the `divs` rule already lets `:::` interrupt a paragraph).
