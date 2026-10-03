#!/bin/sh
# Compiles App/Document/ScrollSyncGate.swift (Foundation only) with a small assertion main and runs it.
# The app target has no unit-test bundle yet, so the ping-pong rules are checked here.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/main.swift" <<'SWIFT'
import Foundation

var failures = 0
func check(_ name: String, _ got: Bool, _ want: Bool) {
    if got != want { print("FAIL \(name): got \(got), want \(want)"); failures += 1 }
}

var gate = ScrollSyncGate()  // window 0.15 s
check("first event is accepted", gate.accept(.editor, at: 0), true)
check("same side keeps going", gate.accept(.editor, at: 0.05), true)
check("echo from the other side right after is dropped", gate.accept(.preview, at: 0.10), false)
check("window slides with accepted events (0.05 + 0.15 = 0.20)", gate.accept(.preview, at: 0.19), false)
check("other side accepted once the window passed", gate.accept(.preview, at: 0.21), true)
check("and now the editor is the echo", gate.accept(.editor, at: 0.25), false)
check("dropped events do not extend the window", gate.accept(.editor, at: 0.37), true)  // 0.21 + 0.15 = 0.36

var g = ScrollSyncGate()
var leaked = false
for i in 0..<100 {
    let t = Double(i) * 0.016
    _ = g.accept(.preview, at: t)
    if g.accept(.editor, at: t + 0.001) { leaked = true }
}
check("continuous scrolling on one side never lets the other through", leaked, false)

if failures > 0 { exit(1) }
print("scroll sync gate: all checks passed")
SWIFT

# CLT alone may lack the swift runtime bits; prefer full Xcode like the Makefile does.
if xcode-select -p | grep -q CommandLineTools && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
swiftc -o "$tmp/check" "$root/App/Document/ScrollSyncGate.swift" "$tmp/main.swift"
"$tmp/check"
