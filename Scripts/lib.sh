# Helpers shared by the scripts in Scripts/ and Scripts/vm/. Sourced, never run; plain POSIX sh, so the #!/bin/sh scripts can use it too.
# Functions that need ROOT_DIR (the repository) or die() (the caller's own: each script prefixes its messages differently) say so.

# The Debug app the isolated runs and the VM use: MACDOWN2_APP, else what `make app` builds. Needs ROOT_DIR.
app_path() { printf '%s\n' "${MACDOWN2_APP:-$ROOT_DIR/build/DerivedData/Build/Products/Debug/MacDown2.app}"; }

# die "$2" unless the app $1 is a Debug build with isolation support. Only a Debug build honours the isolation variables
# (the Debug configuration marks its Info.plist, MACDOWN2_ISOLATION_SUPPORTED in the project); a Release bundle would ignore
# them and use the user's real preferences domain. Needs die().
require_isolation_build() {
  [ "$(/usr/libexec/PlistBuddy -c 'Print :MacDown2IsolationSupported' "$1/Contents/Info.plist" 2>/dev/null || true)" = YES ] || die "$2"
}

# Builds Scripts/<name>.swift into build/<name> when that is missing or older and prints the tool's path; the compiler's output
# goes to stderr, and a failed build returns non-zero. Needs ROOT_DIR.
swift_tool() {
  _tool="$ROOT_DIR/build/$1"
  if [ ! -x "$_tool" ] || [ "$ROOT_DIR/Scripts/$1.swift" -nt "$_tool" ]; then
    mkdir -p "$ROOT_DIR/build" && swiftc -O "$ROOT_DIR/Scripts/$1.swift" -o "$_tool" >&2 || return 1
  fi
  printf '%s\n' "$_tool"
}

# xcodebuild and the Swift runtime bits need full Xcode even when xcode-select still points at the Command Line Tools
# (the Makefile does the same).
use_full_xcode() {
  case "$(xcode-select -p)" in
    *CommandLineTools*) [ ! -d /Applications/Xcode.app/Contents/Developer ] || export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ;;
  esac
}
