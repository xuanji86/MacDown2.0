#!/bin/bash
# Launch the Debug build as a throwaway instance that cannot touch the user's real MacDown2 state.
#
#   Scripts/run-isolated.sh [file.md|dir...] copy the files / folders into a fresh temp dir, launch the app on them (a folder
#                                          opens as a workspace), print
#                                          PID / SUITE / ROOT / FILE / WINDOW lines (WINDOW <id> <w> <h>)
#   Scripts/run-isolated.sh --stop <pid>   quit that instance, delete its defaults suite and its temp dir. The pid is signalled only if it
#                                          is still the process this script started (same start time and executable); a reused
#                                          pid is reported and left alone
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
# Deep link: MACDOWN2_DEEPLINK='macdown2://open?path={ROOT}/notes.md&line=3' also hands that URL to the new instance (LaunchServices, as a
# browser would); {ROOT} is replaced by the temp dir. `open -n -a "$APP"` names this one bundle, so no other MacDown2 gets the link.
#
# Language: MACDOWN2_LANGUAGE=en or zh-Hans launches the instance in that language whatever the system's is.
#
# Screenshot just that window (never the whole screen):  screencapture -x -l <window id> shot.png
# App log of an isolated launch:  log show --last 2m --predicate 'subsystem == "io.github.xuanji86.MacDown2"'
#
# Env: MACDOWN2_APP overrides the app bundle (default: build/DerivedData/Build/Products/Debug/MacDown2.app, `make app`); it must
# still be a Debug build (Info.plist MacDown2IsolationSupported=YES): a Release bundle ignores the isolation variables.
# Two inputs with the same file name (/a/notes.md, /b/notes.md) land in $root and $root/dup2/ instead of overwriting each other.
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

# A pid alone is not an identity: once the instance is gone the number can be handed to any process, e.g. the user's real
# MacDown2 with unsaved documents. So the launch records when the process started and which executable it runs, and
# --stop signals only a process that still matches both.
proc_start() { LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//; s/ *$//' || true; }
proc_comm() { ps -o comm= -p "$1" 2>/dev/null | sed 's/^ *//; s/ *$//' || true; }

stop() {
  local pid="${1:-}"
  [[ "$pid" =~ ^[0-9]+$ ]] || die "usage: $0 --stop <pid>"
  local state="$STATE_DIR/$pid"
  [ -f "$state" ] || die "no isolated instance recorded for pid $pid (not started by this script?)"
  local suite root start comm
  suite="$(sed -n 's/^SUITE=//p' "$state")"
  root="$(sed -n 's/^ROOT=//p' "$state")"
  start="$(sed -n 's/^START=//p' "$state")"
  comm="$(sed -n 's/^COMM=//p' "$state")"
  # Never touch anything but what this script made: the real domain must be unreachable from here.
  [[ "$suite" == "$SUITE_PREFIX"* && "$suite" != "$REAL_DOMAIN"* ]] || die "refusing: suite '$suite' is not an isolated suite"
  [[ "$(basename "$root")" == "$TEMP_PREFIX"* && -d "$root" ]] || die "refusing: '$root' is not an isolated temp dir"
  local note=""
  if kill -0 "$pid" 2>/dev/null; then
    if [ -n "$start" ] && [ -n "$comm" ] && [ "$(proc_start "$pid")" = "$start" ] && [ "$(proc_comm "$pid")" = "$comm" ]; then
      kill -TERM "$pid" 2>/dev/null || true
      for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
      # Checked again: the number must still be the same process before the unconditional signal.
      if kill -0 "$pid" 2>/dev/null && [ "$(proc_start "$pid")" = "$start" ] && [ "$(proc_comm "$pid")" = "$comm" ]; then kill -KILL "$pid" 2>/dev/null || true; fi
    else
      # Not the process this record was made for (or the record predates the identity check): leave it alone.
      note="; pid $pid is running something else now (record: started '${start:-?}', '${comm:-?}'; now: started '$(proc_start "$pid")', '$(proc_comm "$pid")'), so nothing was signalled"
    fi
  fi
  defaults delete "$suite" 2>/dev/null || true
  rm -f "$HOME/Library/Preferences/$suite.plist"
  rm -rf "$root"
  rm -f "$state"
  echo "stopped pid $pid; deleted suite $suite and $root$note"
}

if [ "${1:-}" = "--stop" ]; then stop "${2:-}"; exit 0; fi
[ -d "$APP" ] || die "no app at $APP (run \`make app\`, or set MACDOWN2_APP)"
# Only a Debug build honours the isolation variables; a Release bundle would ignore them and open the copies in the user's
# real preferences domain. The Debug configuration marks its Info.plist (MACDOWN2_ISOLATION_SUPPORTED in the project).
[ "$(/usr/libexec/PlistBuddy -c 'Print :MacDown2IsolationSupported' "$APP/Contents/Info.plist" 2>/dev/null || true)" = "YES" ] \
  || die "$APP is not a Debug build with isolation support (Info.plist has no MacDown2IsolationSupported=YES); refusing to launch. Run \`make app\`."

suite="$SUITE_PREFIX$(uuidgen | tr 'A-Z' 'a-z')"
root="$(mktemp -d "${TMPDIR:-/tmp}/${TEMP_PREFIX}XXXXXX")"
root="$(cd "$root" && pwd -P)"  # the app compares resolved paths; hand it the resolved one

copies=()
n=1
for f in "$@"; do
  [ -f "$f" ] || [ -d "$f" ] || { rm -rf "$root"; die "not a file or folder: $f"; }
  if [ -d "$f" ]; then name="$(basename "$(cd "$f" && pwd)")"; else name="$(basename "$f")"; fi  # "." has a name too
  # Inputs share $root so files next to each other stay next to each other; a second input with the same name (/a/notes.md and
  # /b/notes.md) gets its own subdirectory instead of silently overwriting the first copy.
  dest="$root"
  if [ -e "$root/$name" ]; then n=$((n + 1)); dest="$root/dup$n"; mkdir "$dest"; fi
  cp -R "$f" "$dest/$name"
  copies+=("$dest/$name")
done

before="$(app_pids)"
extra=()
for name in MACDOWN2_TEST_UNTITLED_TEXT MACDOWN2_TEST_TERMINATE_AFTER MACDOWN2_TEST_WINDOW_FRAME MACDOWN2_TEST_EDIT_TEXT MACDOWN2_TEST_EDIT_AFTER MACDOWN2_TEST_PROMPT_ANSWER MACDOWN2_TEST_PROMPT_DELAY MACDOWN2_TEST_OPEN_SETTINGS MACDOWN2_TEST_OPEN_SETTINGS_AFTER MACDOWN2_TEST_STATUS_BAR MACDOWN2_TEST_TOOL_ENV_REREAD MACDOWN2_TEST_SEARCH MACDOWN2_TEST_SEARCH_REGEX MACDOWN2_TEST_SEARCH_OPEN MACDOWN2_TEST_TOGGLE_TASK_LINE MACDOWN2_TEST_TOGGLE_TASK_DELAY MACDOWN2_TEST_TOGGLE_TASK_LAYOUT MACDOWN2_TEST_TOGGLE_TASK_UNDO MACDOWN2_TEST_TOGGLE_TASK_SAVE MACDOWN2_TEST_SHOW_OUTLINE MACDOWN2_TEST_CLOSE_ACTIVE_TAB MACDOWN2_TEST_CLOSE_WINDOW MACDOWN2_TEST_REOPEN MACDOWN2_TEST_NEW_WINDOW MACDOWN2_TEST_DUMP_MENUS MACDOWN2_TEST_ACTIVATE MACDOWN2_TEST_TOOLBAR_STYLE MACDOWN2_TEST_TOOLBAR_STYLE_FLIP MACDOWN2_TEST_DUMP_TOOLBAR MACDOWN2_TEST_TAB_RENAME MACDOWN2_TEST_TAB_RENAME_COMMIT MACDOWN2_TEST_TAB_RENAME_COMMIT_AFTER MACDOWN2_TEST_TAB_RENAME_TAGS MACDOWN2_TEST_TAB_RENAME_FOLDER MACDOWN2_TEST_PASTE MACDOWN2_TEST_PASTE_AFTER MACDOWN2_TEST_SCROLL_PAST_END MACDOWN2_TEST_SCROLL_TO_END MACDOWN2_TEST_EDITOR_THEME MACDOWN2_TEST_EDITOR_THEME_AFTER MACDOWN2_TEST_DUMP_EDITOR MACDOWN2_TEST_PREVIEW_EDIT MACDOWN2_TEST_PREVIEW_DELAY MACDOWN2_TEST_PREVIEW_TYPE MACDOWN2_TEST_PREVIEW_IME MACDOWN2_TEST_PREVIEW_BACKSPACE MACDOWN2_TEST_PREVIEW_UNDO MACDOWN2_TEST_PEER_SELECT MACDOWN2_TEST_PAGE_SELECT MACDOWN2_TEST_PREVIEW_AUTOCORRECT MACDOWN2_TEST_PREVIEW_IME_CANCEL MACDOWN2_TEST_PREVIEW_IME_OVER MACDOWN2_TEST_FOLLOW_CARET; do  # Debug-only drivers (App/IsolatedTestHooks.swift)
  [ -n "${!name:-}" ] && extra+=(--env "$name=${!name}")
done
# MACDOWN2_LANGUAGE=en|zh-Hans runs this instance in that language (the standard -AppleLanguages launch argument: it reaches this process
# only, and writes nothing to any preferences domain).
lang=()
[ -z "${MACDOWN2_LANGUAGE:-}" ] || lang=(--args -AppleLanguages "($MACDOWN2_LANGUAGE)")
link=()
[ -z "${MACDOWN2_DEEPLINK:-}" ] || link=("${MACDOWN2_DEEPLINK//\{ROOT\}/$root}")
open -n -a "$APP" --env "MACDOWN2_DEFAULTS_SUITE=$suite" --env "MACDOWN2_ALLOWED_ROOT=$root" ${extra[@]+"${extra[@]}"} ${copies[@]+"${copies[@]}"} ${link[@]+"${link[@]}"} ${lang[@]+"${lang[@]}"}

pid=""
for _ in $(seq 1 100); do
  pid="$(comm -13 <(printf '%s\n' "$before") <(app_pids) | head -1)"
  [ -n "$pid" ] && break
  sleep 0.1
done
[ -n "$pid" ] || { rm -rf "$root"; die "the app did not start"; }

mkdir -p "$STATE_DIR"
printf 'SUITE=%s\nROOT=%s\nSTART=%s\nCOMM=%s\n' "$suite" "$root" "$(proc_start "$pid")" "$(proc_comm "$pid")" > "$STATE_DIR/$pid"

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
