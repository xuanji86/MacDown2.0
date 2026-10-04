#!/bin/sh
# Fails if the committed WebAssets resources differ from a fresh build (the whole directory is generated).
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
res=$root/Packages/WebAssets/Sources/WebAssets/Resources
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
node "$root/Web/build.mjs" "$tmp"
diff -r "$tmp" "$res" || { echo "error: $res is stale; run 'make web' and commit the result" >&2; exit 1; }
# Chunk boundary (PLAN 4.1.2): no Quarto code, and no markdown-it-attrs, in the main bundle or the preview page's own script.
for bundle in render.bundle.js preview.bundle.js; do
  if grep -q -e quarto_callout -e quarto_include -e pandoc_div -e curly_attributes -e 'quarto-' "$res/$bundle"; then
    echo "error: $bundle contains Quarto code; it belongs in quarto.chunk.js" >&2; exit 1
  fi
done
# Same for Mermaid: `flowchart-v2` is one of its diagram ids, so it only occurs where Mermaid itself is bundled.
for bundle in render.bundle.js preview.bundle.js; do
  if grep -q flowchart-v2 "$res/$bundle"; then
    echo "error: $bundle contains Mermaid; it belongs in mermaid.chunk.js" >&2; exit 1
  fi
done
grep -q flowchart-v2 "$res/mermaid.chunk.js" || { echo "error: mermaid.chunk.js does not contain Mermaid" >&2; exit 1; }
# Main bundle budget (PLAN 4.1.2: <= 800 KB minified).
size=$(wc -c < "$res/render.bundle.js")
[ "$size" -le $((800 * 1024)) ] || { echo "error: render.bundle.js is $size bytes, over its 800 KB budget" >&2; exit 1; }
