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

[ -f build/vm/vnc ] && $VM exec true 2>/dev/null || $VM up
$VM install

# A fresh document and an isolated launch inside the VM (its own defaults suite, a fixed window frame on the VM's screen).
$VM exec 'pkill -x MacDown2 || true; rm -rf ~/md2e2e && mkdir ~/md2e2e && printf "# Hello\n\nSome text here.\n" > ~/md2e2e/notes.md'
# The file is opened through the app's control socket (App/TestControl.swift), with the system's nc: a file given to `open` from an
# ssh session never reaches the app (no open-documents event from outside the GUI session).
$VM exec 'open -n -a ~/Applications/MacDown2.app --env MACDOWN2_DEFAULTS_SUITE=macdown2-iso-vm --env MACDOWN2_ALLOWED_ROOT=$HOME/md2e2e \
  --env "MACDOWN2_TEST_WINDOW_FRAME=0 0 1024 730"; for _ in $(seq 1 50); do [ -S ~/md2e2e/.ctl ] && break; sleep 0.2; done; sleep 2
  (echo "{\"cmd\":\"open\",\"paths\":[\"notes.md\"]}"; sleep 1) | nc -U ~/md2e2e/.ctl >/dev/null'
sleep 3

failures=0
step=0
shot() { step=$((step + 1)); $DO capture "$OUT/$(printf '%02d' $step)-$1.png"; }
file() { $VM exec 'cat ~/md2e2e/notes.md'; }
check() {  # check <name> <expected substring of the saved file>
  if file | grep -qF -- "$2"; then echo "ok   $1"; else echo "FAIL $1 (file: $(file | tr '\n' '|'))"; failures=$((failures + 1)); fi
  shot "${1// /-}"
}

shot launched
# The editor is the left half (VNC coordinates are the VM screen's pixels, 2x points); click in it, go to the end, type, select the last word, Command-B, Command-S.
$DO click 400 600 pause 0.3 key cmd-down pause 0.2 key left pause 0.2  # before the final newline
$DO type " Typed in the VM" pause 0.3
$DO key shift-option-left pause 0.2 key cmd-b pause 0.3 key cmd-s pause 1
check "typing, cmd-B and cmd-S through the window server" "Some text here. Typed in the **VM**"

# Undo (Command-Z): the bold goes, the typing stays; save again.
$DO key cmd-z pause 0.3 key cmd-s pause 1
check "cmd-Z undoes the bold" "Typed in the VM"

$VM exec 'pkill -x MacDown2 || true'
echo
if [ "$failures" -eq 0 ]; then echo "e2e-vm: all passed (screenshots in $OUT/)"; else echo "e2e-vm: $failures failed (screenshots in $OUT/)"; exit 1; fi
