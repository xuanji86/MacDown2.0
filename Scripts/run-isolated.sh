#!/bin/bash
# Launch the Debug build as a throwaway instance that cannot touch the user's real MacDown2 state.
#
#   Scripts/run-isolated.sh [file.md|dir...] copy the files / folders into a fresh temp dir, launch the app on them (a folder
#                                          opens as a workspace), print
#                                          PID / SUITE / ROOT / FILE / WINDOW lines (WINDOW <id> <w> <h>)
#   Scripts/run-isolated.sh --stop <pid>   quit that instance, delete its defaults suite and its temp dir
#
# Why not `open -n --env HOME=...`: cfprefsd ignores HOME, so such an instance still reads and writes the real
# io.github.xuanji86.MacDown2 domain (restores the user's windows and files, rewrites frames, adds recents).
# Instead the app (Debug builds only) honours two variables, set here:
#   MACDOWN2_DEFAULTS_SUITE   every preference read/write goes to this random suite; no window is restored unless the
#                             suite itself recorded it; window/split-view frame autosave and the system's recent
#                             documents are off; Sparkle is not started
#   MACDOWN2_ALLOWED_ROOT     the temp dir; the app refuses (and logs) any file outside it
# Only copies of your files are opened, so the originals are never edited. (A folder is copied whole: keep it small.)
#
# Screenshot just that window (never the whole screen):  screencapture -x -l <window id> shot.png
# App log of an isolated launch:  log show --last 2m --predicate 'subsystem == "io.github.xuanji86.MacDown2"'
#
# Env: MACDOWN2_APP overrides the app bundle (default: build/DerivedData/Build/Products/Debug/MacDown2.app, `make app`).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="${MACDOWN2_APP:-$ROOT_DIR/build/DerivedData/Build/Products/Debug/MacDown2.app}"
STATE_DIR="${TMPDIR:-/tmp}/macdown2-isolated-state"
SUITE_PREFIX="macdown2-iso-"
TEMP_PREFIX="macdown2-isolated."
REAL_DOMAIN="io.github.xuanji86.MacDown2"

die() { echo "run-isolated: $*" >&2; exit 1; }

winids() {  # prints "<id> <w> <h>" lines for the pid; builds the CoreGraphics helper on first use
  local tool="$ROOT_DIR/build/winid"
  if [ ! -x "$tool" ] || [ "$ROOT_DIR/Scripts/winid.swift" -nt "$tool" ]; then
    mkdir -p "$ROOT_DIR/build"
    swiftc -O "$ROOT_DIR/Scripts/winid.swift" -o "$tool" >&2
  fi
  "$tool" "$1"
}

app_pids() { pgrep -f "$APP/Contents/MacOS/" | sort || true; }

stop() {
  local pid="${1:-}"
  [[ "$pid" =~ ^[0-9]+$ ]] || die "usage: $0 --stop <pid>"
  local state="$STATE_DIR/$pid"
  [ -f "$state" ] || die "no isolated instance recorded for pid $pid (not started by this script?)"
  local suite root
  suite="$(sed -n 's/^SUITE=//p' "$state")"
  root="$(sed -n 's/^ROOT=//p' "$state")"
  # Never touch anything but what this script made: the real domain must be unreachable from here.
  [[ "$suite" == "$SUITE_PREFIX"* && "$suite" != "$REAL_DOMAIN"* ]] || die "refusing: suite '$suite' is not an isolated suite"
  [[ "$(basename "$root")" == "$TEMP_PREFIX"* && -d "$root" ]] || die "refusing: '$root' is not an isolated temp dir"
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
  fi
  defaults delete "$suite" 2>/dev/null || true
  rm -f "$HOME/Library/Preferences/$suite.plist"
  rm -rf "$root"
  rm -f "$state"
  echo "stopped pid $pid; deleted suite $suite and $root"
}

if [ "${1:-}" = "--stop" ]; then stop "${2:-}"; exit 0; fi
[ -d "$APP" ] || die "no app at $APP (run \`make app\`, or set MACDOWN2_APP)"

suite="$SUITE_PREFIX$(uuidgen | tr 'A-Z' 'a-z')"
root="$(mktemp -d "${TMPDIR:-/tmp}/${TEMP_PREFIX}XXXXXX")"
root="$(cd "$root" && pwd -P)"  # the app compares resolved paths; hand it the resolved one

copies=()
for f in "$@"; do
  [ -f "$f" ] || [ -d "$f" ] || { rm -rf "$root"; die "not a file or folder: $f"; }
  if [ -d "$f" ]; then name="$(basename "$(cd "$f" && pwd)")"; else name="$(basename "$f")"; fi  # "." has a name too
  cp -R "$f" "$root/$name"
  copies+=("$root/$name")
done

before="$(app_pids)"
extra=()
for name in MACDOWN2_TEST_UNTITLED_TEXT MACDOWN2_TEST_TERMINATE_AFTER MACDOWN2_TEST_WINDOW_FRAME MACDOWN2_TEST_EDIT_TEXT MACDOWN2_TEST_EDIT_AFTER MACDOWN2_TEST_PROMPT_ANSWER MACDOWN2_TEST_PROMPT_DELAY MACDOWN2_TEST_OPEN_SETTINGS MACDOWN2_TEST_TOOL_ENV_REREAD MACDOWN2_TEST_SEARCH MACDOWN2_TEST_SEARCH_REGEX MACDOWN2_TEST_SEARCH_OPEN MACDOWN2_TEST_TOGGLE_TASK_LINE MACDOWN2_TEST_TOGGLE_TASK_DELAY MACDOWN2_TEST_TOGGLE_TASK_LAYOUT MACDOWN2_TEST_TOGGLE_TASK_UNDO MACDOWN2_TEST_TOGGLE_TASK_SAVE; do  # Debug-only drivers (App/IsolatedTestHooks.swift)
  [ -n "${!name:-}" ] && extra+=(--env "$name=${!name}")
done
open -n -a "$APP" --env "MACDOWN2_DEFAULTS_SUITE=$suite" --env "MACDOWN2_ALLOWED_ROOT=$root" ${extra[@]+"${extra[@]}"} ${copies[@]+"${copies[@]}"}

pid=""
for _ in $(seq 1 100); do
  pid="$(comm -13 <(printf '%s\n' "$before") <(app_pids) | head -1)"
  [ -n "$pid" ] && break
  sleep 0.1
done
[ -n "$pid" ] || { rm -rf "$root"; die "the app did not start"; }

mkdir -p "$STATE_DIR"
printf 'SUITE=%s\nROOT=%s\n' "$suite" "$root" > "$STATE_DIR/$pid"

windows=""
for _ in $(seq 1 100); do
  windows="$(winids "$pid")"
  [ -n "$windows" ] && break
  sleep 0.1
done

echo "PID=$pid"
echo "SUITE=$suite"
echo "ROOT=$root"
for c in ${copies[@]+"${copies[@]}"}; do echo "FILE=$c"; done
if [ -n "$windows" ]; then printf '%s\n' "$windows" | sed 's/^/WINDOW=/'; else echo "WINDOW=(none yet; run build/winid $pid)"; fi
