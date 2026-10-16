#!/bin/sh
# Fails if the committed WebAssets resources differ from a fresh build (the whole directory is generated).
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
res=$root/Packages/WebAssets/Sources/WebAssets/Resources
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
node "$root/Web/build.mjs" "$tmp"
diff -r "$tmp" "$res" || { echo "error: $res is stale; run 'make web' and commit the result" >&2; exit 1; }

# forbid <ERE> <what> <file>...: none of the files (in $res) may contain the pattern; the error says "<file> contains <what>".
forbid() {
  pattern=$1; what=$2; shift 2
  for f in "$@"; do
    if grep -q -E -e "$pattern" "$res/$f"; then echo "error: $f contains $what" >&2; exit 1; fi
  done
}
# require <file> <pattern> <what>: the file (in $res) must contain the pattern; the error says "<file> does not contain <what>".
require() { grep -q -e "$2" "$res/$1" || { echo "error: $1 does not contain $3" >&2; exit 1; }; }

# Chunk boundary (PLAN 4.1.2): no Quarto code, and no markdown-it-attrs, in the main bundle or the preview page's own script.
forbid 'quarto_callout|quarto_include|pandoc_div|curly_attributes|quarto-' 'Quarto code; it belongs in quarto.chunk.js' render.bundle.js preview.bundle.js
# Same for Mermaid: `flowchart-v2` is one of its diagram ids, so it only occurs where Mermaid itself is bundled.
forbid flowchart-v2 'Mermaid; it belongs in mermaid.chunk.js' render.bundle.js preview.bundle.js
# The sanitizer (parse5) is a chunk of its own: `abruptClosingOfEmptyComment` is one of its parse-error ids, so it only occurs where
# parse5 is bundled. The main bundle fails closed without the chunk; it must not carry it.
forbid abruptClosingOfEmptyComment 'parse5; it belongs in sanitize.chunk.js' render.bundle.js preview.bundle.js quarto.chunk.js mermaid.chunk.js
require sanitize.chunk.js abruptClosingOfEmptyComment parse5
# elkjs is EPL-2.0 without a GPL secondary-licence notice: not shippable under GPL-3.0 (build.mjs stubs it out).
forbid 'org\.eclipse\.elk|elkjs' 'elkjs (EPL-2.0, not GPL-3.0 compatible)' mermaid.chunk.js THIRD_PARTY_LICENSES.txt
require mermaid.chunk.js flowchart-v2 Mermaid
# Main bundle budget (PLAN 4.1.2: <= 800 KB minified).
size=$(wc -c < "$res/render.bundle.js")
[ "$size" -le $((800 * 1024)) ] || { echo "error: render.bundle.js is $size bytes, over its 800 KB budget" >&2; exit 1; }
