#!/bin/sh
# Core packages, QuickLook and CLI must not import extension modules; TextKit 2 / ObjectiveC guards repo-wide.
cd "$(dirname "$0")/.." || exit 1
fail=0
g() { grep -rnE --include='*.swift' --exclude-dir=.build --exclude-dir=build --exclude-dir=node_modules --exclude-dir=.claude "$@"; }

dirs=
for d in Packages/MarkdownCore Packages/EditorKit Packages/PreviewKit Packages/WebAssets Packages/ExtensionAPI Packages/WorkspaceKit QuickLook CLI; do
  [ -d "$d" ] && dirs="$dirs $d"
done
# shellcheck disable=SC2086
if [ -n "$dirs" ] && g '\bimport[[:space:]]+(QuartoExtension|QmdSearchExtension)\b' $dirs; then
  echo "error: core code imports an extension module" >&2; fail=1
fi
if g '\.layoutManager\b|\bimport[[:space:]]+ObjectiveC\b' .; then
  echo "error: .layoutManager (TextKit 1) or import ObjectiveC is forbidden" >&2; fail=1
fi
exit $fail
