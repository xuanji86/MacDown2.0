#!/bin/sh
# Fails if the committed WebAssets resources differ from a fresh build (the whole directory is generated).
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
res=$root/Packages/WebAssets/Sources/WebAssets/Resources
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
node "$root/Web/build.mjs" "$tmp"
diff -r "$tmp" "$res" || { echo "error: $res is stale; run 'make web' and commit the result" >&2; exit 1; }
