#!/bin/bash
# End-to-end smoke test through the control socket (App/TestControl.swift, Scripts/md2ctl): an isolated Debug instance launched in
# the background (the user's focus and files are never touched), driven with keys, menus, clicks, typing and an input method,
# checked against the editor's text and the preview's DOM. Screenshots of each step land in build/e2e/ (window only).
#
#   Scripts/e2e-smoke.sh        (`make e2e`; needs `make app` first)
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
OUT="build/e2e"
mkdir -p "$OUT"
export MD2CTL_TIMEOUT=20

work="$(mktemp -d)"
printf '# Hello\n\nSome *text* here.\n\n- [ ] task one\n' > "$work/notes.md"
for i in $(seq 1 40); do echo "- line $i"; done > "$work/long.md"  # longer than the window: the tab-switch step at the end
# ~1000 lines of headings, wrapping paragraphs, lists and code blocks: the zoom step at the end scrolls into the middle of it.
python3 - "$work/zoom.md" <<'PY'
import sys
out = []
for i in range(1, 101):
    out += [f"## Section {i}", "", "A paragraph long enough to wrap onto several rows in the editor, so that lines have different heights. " * 3, "",
            *[f"- item {i}.{k}" for k in range(1, 4)], "", "```", f"code {i}", "```", ""]
open(sys.argv[1], "w").write("\n".join(out))
PY
launch="$(MACDOWN2_BACKGROUND=1 MACDOWN2_LANGUAGE=en MACDOWN2_TEST_WINDOW_FRAME="100 100 1100 750" Scripts/run-isolated.sh "$work/zoom.md" "$work/long.md" "$work/notes.md")"
rm -rf "$work"
pid="$(sed -n 's/^PID=//p' <<<"$launch")"
trap 'Scripts/run-isolated.sh --stop "$pid" >/dev/null' EXIT

C() { Scripts/md2ctl "$pid" "$@"; }
failures=0
check() {  # check <name> <command...>: the command must succeed
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "ok   $name"; else echo "FAIL $name"; failures=$((failures + 1)); fi
  step=$((step + 1))
  local file; file="$(printf '%02d' "$step")-$(tr -cs 'A-Za-z0-9' '-' <<<"$name" | sed 's/-$//')"
  C shot "$OUT/$file.png" >/dev/null 2>&1 || true
}
step=0
text_has() {  # the editor's text has it, within 5 s (an edit made in the preview reaches the source asynchronously)
  for _ in $(seq 1 25); do C editor | grep -qF -- "$1" && return 0; sleep 0.2; done
  return 1
}
page() { C wait "$1" timeout=5; }

page "document.querySelector('#doc h1')" >/dev/null  # the preview has rendered

C focus target=editor
C select from=10 to=14
C key key=b modifiers=cmd >/dev/null
check "cmd-B bolds the selection" text_has 'S**ome** *text*'
check "preview shows the bold" page "document.querySelector('#doc strong')?.textContent === 'ome'"

C select from=0 to=0
C key key=2 modifiers=cmd >/dev/null
check "cmd-2 makes a level-2 heading" text_has '## Hello'
check "preview shows the h2" page "document.querySelector('#doc h2')?.textContent === 'Hello'"

C menu path="Edit > Undo"
check "undo through the Edit menu" text_has '"text": "# Hello'

C menu path="View > Preview Only"
check "View > Preview Only" bash -c "Scripts/md2ctl $pid state | grep -q '\"layout\": \"previewOnly\"'"
C menu path="View > Editor and Preview, Equal"
check "back to both panes" bash -c "Scripts/md2ctl $pid state | grep -q '\"layout\": \"both\"'"

# The task checkbox, clicked where the page draws it (the preview's origin from `state` plus the DOM rect).
origin="$(C state | python3 -c 'import json,sys; p=json.load(sys.stdin)["windows"][0]["preview"]; print(p[0], p[1])')"
read -r px py <<<"$origin"
box="$(C js script="const r = document.querySelector('#doc input[type=checkbox]').getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]" | python3 -c 'import json,sys; print(*json.load(sys.stdin))')"
read -r bx by <<<"$box"
C click x="$(python3 -c "print($px + $bx)")" y="$(python3 -c "print($py + $by)")" >/dev/null
check "clicking the preview checkbox ticks the source" text_has '- [x] task one'

# Preview editing: a click at the end of the paragraph, typed text, then an input method composing and committing.
para="$(C js script="const r = document.querySelector('#doc p').getBoundingClientRect(); return [r.right - 4, r.y + r.height / 2]" | python3 -c 'import json,sys; print(*json.load(sys.stdin))')"
read -r ex ey <<<"$para"
C click x="$(python3 -c "print($px + $ex)")" y="$(python3 -c "print($py + $ey)")" >/dev/null
sleep 0.5
C type target=preview text=" more"
C mark target=preview text="ni"
C mark target=preview text="nih"
check "an input method composes in the preview" page "document.querySelector('#doc [contenteditable]')?.textContent.endsWith('morenih')"
C type target=preview text="你好"
check "typing and IME in the preview reach the source" text_has 'here. more你好'

# Tab switches between a text longer than the window and a short one, both directions, each scrolled first (this used to hang
# the app in the highlighter's first visible-range lookup). The editor is first responder, as when typing: the layout manager then
# lays out the new text's caret line as soon as it is attached (a Debug assertion in the storage swap once tripped on that).
tabs_switch() {
  C focus target=editor >/dev/null || return 1
  for _ in 1 2 3; do
    C tab path=long.md >/dev/null && C select from=380 to=380 >/dev/null && text_has '- line 40' || return 1
    C tab path=notes.md >/dev/null && C select from=0 to=0 >/dev/null && text_has 'task one' || return 1
  done
}
check "switching tabs between a long and a short text" tabs_switch

settled_top() {  # sets $top: the editor's top line once two reads 0.3 s apart agree (the zoom reaches the editor a moment after the setting)
  local last=""
  for _ in $(seq 1 20); do
    top="$(C editor | python3 -c 'import json,sys; print(json.load(sys.stdin)["topLine"])')"
    [ "$top" = "$last" ] && return 0
    last="$top"; sleep 0.3
  done
}
# View > Zoom changes the editor's font size: the editor must keep its top source line (it used to keep only the pixel offset, so
# the panes ended up hundreds of lines apart). Levels as the Zoom menu sets them, shrinking below 75 % included.
zoom_keeps_top_line() {
  local log="$OUT/zoom-top-lines.txt" ok=0 level before
  : > "$log"
  C tab path=zoom.md >/dev/null && C focus target=editor >/dev/null && C defaults key=view.zoomPercent value:=100 >/dev/null || return 1
  C select from=18000 to=18000 >/dev/null
  settled_top
  echo "100%: top line $top" >> "$log"
  [ "${top%.*}" -gt 100 ] || { echo "the editor did not scroll into the middle" >> "$log"; return 1; }
  for level in 200 50 100 75 100; do
    before="$top"
    C defaults key=view.zoomPercent value:="$level" >/dev/null
    settled_top
    echo "-> $level%: top line $before -> $top" >> "$log"
    python3 -c "import sys; sys.exit(0 if abs($top - $before) <= 3 else 1)" || ok=1
  done
  return $ok
}
check "zooming keeps the editor's top line" zoom_keeps_top_line
cat "$OUT/zoom-top-lines.txt"

# The same for a theme switch: other colours only (Default Dark / Light), and one that changes the heading sizes (MacDown Classic).
theme_keeps_top_line() {
  local log="$OUT/theme-top-lines.txt" ok=0 name before
  : > "$log"
  C tab path=zoom.md >/dev/null && C focus target=editor >/dev/null && C defaults key=view.zoomPercent value:=100 >/dev/null || return 1
  C defaults key=editorTheme value="Default Dark" >/dev/null; sleep 1
  C select from=18000 to=18000 >/dev/null
  settled_top
  echo "Default Dark: top line $top" >> "$log"
  for name in "Default Light" "MacDown Classic" "Default Dark"; do
    before="$top"
    C defaults key=editorTheme value="$name" >/dev/null
    settled_top
    echo "-> $name: top line $before -> $top" >> "$log"
    python3 -c "import sys; sys.exit(0 if abs($top - $before) <= 3 else 1)" || ok=1
  done
  C defaults key=editorTheme value="MacDown Classic" >/dev/null
  return $ok
}
check "switching the editor theme keeps the top line" theme_keeps_top_line
cat "$OUT/theme-top-lines.txt"

# A zoom while an input method composes reaches the text when the composition is committed: the top line is kept through that too.
zoom_while_composing_keeps_top_line() {
  local log="$OUT/compose-top-lines.txt" ok=0 before
  : > "$log"
  C tab path=zoom.md >/dev/null && C focus target=editor >/dev/null && C defaults key=view.zoomPercent value:=100 >/dev/null || return 1
  C select from=18000 to=18000 >/dev/null
  settled_top
  before="$top"
  C mark text=ni >/dev/null
  C defaults key=view.zoomPercent value:=150 >/dev/null
  settled_top
  echo "composing, 100% -> 150%: top line $before -> $top" >> "$log"
  C type text="你" >/dev/null
  settled_top
  echo "committed: top line $before -> $top" >> "$log"
  python3 -c "import sys; sys.exit(0 if abs($top - $before) <= 0.5 else 1)" || ok=1
  C defaults key=view.zoomPercent value:=100 >/dev/null
  return $ok
}
check "a zoom while composing keeps the top line through the commit" zoom_while_composing_keeps_top_line
cat "$OUT/compose-top-lines.txt"

echo
if [ "$failures" -eq 0 ]; then echo "e2e smoke: all passed (screenshots in $OUT/)"; else echo "e2e smoke: $failures failed (screenshots in $OUT/)"; exit 1; fi
