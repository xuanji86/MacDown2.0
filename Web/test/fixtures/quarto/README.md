# Quarto example documents

Official `.qmd` examples used as render snapshots (`Web/test/quarto.test.mjs`, snapshots in `../../snapshots/quarto/`;
the Swift side renders them too, `Packages/QuartoExtension`). Copied verbatim from
<https://github.com/quarto-dev/quarto> (MIT, Posit Software, PBC) at commit `a83c5cc597e61a28700ceacda86c15b9ef565e82`:

| File | Source path in that repo |
|---|---|
| `quarto-syntax.qmd` | `apps/vscode-markdownit/test/fixtures/quarto-syntax.qmd` (the plugins' own syntax fixture: callouts, divs, figures, cells, shortcode, grid table, equations) |
| `valid-basics.qmd`, `valid-basics-2.qmd`, `valid-nesting.qmd`, `attr-equals.qmd`, `div-code-blocks.qmd`, `nested-checked-list.qmd`, `diagnostics-rich.qmd` | `apps/vscode/src/test/examples/<name>.qmd` (the VS Code extension's example documents) |

Regenerate the snapshots after an intended renderer change with `SNAPSHOT_UPDATE=1 npm test` in `Web/` and read the diff.
The snapshots are this renderer's own output, not Quarto's.
