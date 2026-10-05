#!/bin/bash
# Window lifetime check (Debug build, isolated launch; run `make app` first). It drives the app without input events:
#   reopen:  the only window closes, the Dock click opens a new one          (1 window left)
#   second:  File > New Window opens a second window, the front one closes  (1 window left)
#   many:    three more windows open, then the three front ones close        (1 window left)
# and counts, with `heap`, the objects that belong to one window. Every scenario ends with one window, so there must be exactly
# one of each: a closed window leaves nothing behind. Also counts this app's WebContent processes (one per window's
# WebPage; a leaked PreviewModel keeps its process alive).
#
#   Scripts/check-window-leak.sh [reopen|second|many]     (default: all)
#
# Exit 1 when a closed window's objects are still alive.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
file="$(mktemp "${TMPDIR:-/tmp}/leakcheck.XXXXXX")"
mv "$file" "$file.md"
file="$file.md"
printf '# Leak check\n\nA paragraph.\n' > "$file"
pid=""
trap 'rm -f "$file"; [ -z "$pid" ] || "$ROOT_DIR/Scripts/run-isolated.sh" --stop "$pid" >/dev/null' EXIT

# WebContent processes are children of launchd, not of the app: the ones that appeared after the launch are this app's
# (the check assumes no other app starts web views meanwhile).
webcontent_pids() { pgrep -f com.apple.WebKit.WebContent | sort || true; }

# "<count> <class>" for the classes of one window (heap's columns: count, bytes, average, class name).
counts() {
  heap "$pid" 2>/dev/null | awk '
    $4 ~ /^(MacDown2\.)?(WindowModel|PreviewModel|EditorHandle|WindowCloseGuard)$/ ||
    $4 ~ /^(WebPage|AppKitWindowController|\.\.NSKVONotifying_SwiftUI\.AppKitWindow|\.\.NSKVONotifying_WebKit\.WebPageWebView)$/ { print $1, $4 }' | sort -k2
}

run() {
  local scenario="$1"
  echo "=== $scenario"
  # An app that cannot become active (the display is asleep) closes its windows differently from one somebody is working in:
  # wake the display (a power assertion, no input event) and keep it awake while the scenario runs.
  caffeinate -u -t 2
  caffeinate -d -t 40 &
  local baseline
  baseline="$(webcontent_pids)"
  local out
  case "$scenario" in
    # activate: the window is key, as it is when someone works in it (the menus see it)
    reopen) out="$(MACDOWN2_TEST_ACTIVATE=2 MACDOWN2_TEST_CLOSE_WINDOW=5 MACDOWN2_TEST_REOPEN=7 "$ROOT_DIR/Scripts/run-isolated.sh" "$file")" ;;
    second) out="$(MACDOWN2_TEST_ACTIVATE=2 MACDOWN2_TEST_NEW_WINDOW=5 MACDOWN2_TEST_CLOSE_WINDOW=9 "$ROOT_DIR/Scripts/run-isolated.sh" "$file")" ;;
    many) out="$(MACDOWN2_TEST_ACTIVATE=2 MACDOWN2_TEST_NEW_WINDOW=4,6,8 MACDOWN2_TEST_CLOSE_WINDOW=11,13,15 "$ROOT_DIR/Scripts/run-isolated.sh" "$file")" ;;
  esac
  pid="$(sed -n 's/^PID=//p' <<<"$out")"
  sleep 20
  local result
  result="$(counts)"
  echo "$result"
  echo "WebContent processes of this app: $(comm -13 <(printf '%s\n' "$baseline") <(webcontent_pids) | wc -l | tr -d ' ')"
  "$ROOT_DIR/Scripts/run-isolated.sh" --stop "$pid" >/dev/null
  pid=""
  # One window is left, so one of each (heap prints nothing for a class with no instance).
  local class n
  for class in WindowModel PreviewModel EditorHandle WebPage; do
    n="$(awk -v c="$class" '$2 == c { print $1 }' <<<"$result")"
    if [ "${n:-0}" != 1 ]; then echo "LEAK ($scenario): ${n:-0} $class alive, expected 1 (one window is open)"; return 1; fi
  done
  echo "OK ($scenario): nothing of a closed window is left"
}

status=0
for s in ${1:-reopen second many}; do run "$s" || status=1; done
exit $status
