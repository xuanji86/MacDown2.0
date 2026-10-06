#!/bin/bash
# End-to-end test with real input, inside the test VM: key presses and clicks reach MacDown2 through the VM's window server
# (VNC), exactly as from a keyboard, and the result is checked in the file the app saved. Screenshots of the VM's screen go to
# build/vm/e2e/. Nothing runs on, or is sent to, the host's desktop.
#
#   Scripts/vm/e2e-vm.sh        (`make e2e-vm`; needs `make app`; starts the VM if it is not up)
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"
VM=Scripts/vm/vm.sh
DO=Scripts/vm/vmdo
OUT=build/vm/e2e
rm -rf "$OUT"; mkdir -p "$OUT"

[ -f "build/vm/${MD2_VM:-md2-test}/vnc" ] && $VM exec true 2>/dev/null || $VM up
$VM install

# The app's control socket inside the VM, through the system's nc (no python there without the developer tools).
# lazy: nc stops at the end of its input, so it is kept open half a second for the reply; a slower reply would be cut off
ctl() {
  local reply
  reply="$($VM exec "(echo $(printf '%q' "$1"); sleep 0.5) | nc -U ~/md2e2e/.ctl")"
  python3 -c 'import json,sys; r=json.loads(sys.argv[1]); sys.exit(0 if r.get("ok") else "control socket: " + str(r.get("error")))' "$reply" || return 1
  printf '%s\n' "$reply"
}

# A fresh document and an isolated launch in a defaults suite of its own (nothing restored from an earlier run).
suite="macdown2-iso-vm-$(uuidgen | tr 'A-Z' 'a-z')"
$VM exec 'pkill -x MacDown2 || true; rm -rf ~/md2e2e && mkdir ~/md2e2e && printf "# Hello\n\nSome text here.\n" > ~/md2e2e/notes.md'
trap '$VM exec "pkill -x MacDown2; defaults delete '"$suite"'; rm -f ~/Library/Preferences/'"$suite"'.plist" >/dev/null 2>&1 || true' EXIT
$VM exec "open -n -a ~/Applications/MacDown2.app --env MACDOWN2_DEFAULTS_SUITE=$suite --env MACDOWN2_ALLOWED_ROOT=\$HOME/md2e2e \
  --env 'MACDOWN2_TEST_WINDOW_FRAME=0 0 1024 730'; for _ in \$(seq 1 100); do [ -S ~/md2e2e/.ctl ] && exit 0; sleep 0.2; done; exit 1" \
  || { echo "e2e-vm: the app's control socket did not appear in 20 s" >&2; exit 1; }
sleep 2
# The file is opened through the socket: a file given to `open` from an ssh session never reaches the app (no open-documents
# event from outside the GUI session). Only an explicit save may write it: the autosave interval is set long.
ctl '{"cmd":"open","paths":["notes.md"]}' >/dev/null
ctl '{"cmd":"autosave","delay":3600}' >/dev/null
sleep 2

# Where to click: the editor's middle, from the app's own account of its window (window points; the VM's screen is 2x).
point="$(ctl '{"cmd":"state"}' | python3 -c '
import json, sys
s = json.load(sys.stdin)["result"]; w = next(w for w in s["windows"] if "tabs" in w)
x, y, width, height = w["frame"]; ex, ey, ew, eh = w["editor"]["frame"]
screen_top = 768 - (y + height)          # lazy: assumes the VM screen is 1024x768 points (the image default)
print(int((x + ex + ew / 2) * w["scale"]), int((screen_top + ey + eh / 2) * w["scale"]))')"
read -r cx cy <<<"$point"

failures=0
step=0
shot() { step=$((step + 1)); $DO capture "$OUT/$(printf '%02d' $step)-$1.png"; }
file() { $VM exec 'cat ~/md2e2e/notes.md'; }
check() {  # check <name> <python condition on `text`, the saved file>
  if file | python3 -c "import sys; text = sys.stdin.read(); sys.exit(0 if ($2) else 1)"; then echo "ok   $1"
  else echo "FAIL $1 (file: $(file | tr '\n' '|'))"; failures=$((failures + 1)); fi
  shot "$(tr -cs 'A-Za-z0-9' '-' <<<"$1" | sed 's/-$//')"
}

shot launched
# Click in the editor, go to the end of the last line, type, select the last word, Command-B; nothing is saved yet.
$DO click "$cx" "$cy" pause 0.3 key cmd-down pause 0.2 key left pause 0.2  # before the final newline
$DO type " Typed in the VM" pause 0.3 key shift-option-left pause 0.2 key cmd-b pause 1
check "typing and cmd-B are not saved on their own" 'text == "# Hello\n\nSome text here.\n"'
$DO key cmd-s pause 1
check "cmd-S saves typing and cmd-B" 'text == "# Hello\n\nSome text here. Typed in the **VM**\n"'

# Command-Z: the bold goes, the typing stays; save again.
$DO key cmd-z pause 0.3 key cmd-s pause 1
check "cmd-Z undoes exactly the bold" 'text == "# Hello\n\nSome text here. Typed in the VM\n"'

echo
if [ "$failures" -eq 0 ]; then echo "e2e-vm: all passed (screenshots in $OUT/)"; else echo "e2e-vm: $failures failed (screenshots in $OUT/)"; exit 1; fi
