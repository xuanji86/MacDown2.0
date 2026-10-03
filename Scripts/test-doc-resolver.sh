#!/bin/sh
# Compiles App/Preview/DocumentFileResolver.swift (Foundation only) with a small assertion main and runs it.
# The app target has no unit-test bundle yet, so the path-traversal rules are checked here.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/main.swift" <<'SWIFT'
import Foundation

let fm = FileManager.default
let sandbox = fm.temporaryDirectory.appending(path: "resolver-\(UUID().uuidString)")
defer { try? fm.removeItem(at: sandbox) }
let doc = sandbox.appending(path: "doc")
try fm.createDirectory(at: doc.appending(path: "img"), withIntermediateDirectories: true)
try Data("png".utf8).write(to: doc.appending(path: "img/a b.png"))
try Data("secret".utf8).write(to: sandbox.appending(path: "secret.txt"))
try fm.createSymbolicLink(at: doc.appending(path: "out.txt"), withDestinationURL: sandbox.appending(path: "secret.txt"))
try fm.createSymbolicLink(at: doc.appending(path: "same.png"), withDestinationURL: doc.appending(path: "img/a b.png"))
try fm.createSymbolicLink(at: doc.appending(path: "outdir"), withDestinationURL: sandbox)

var failures = 0
func check(_ name: String, _ got: DocumentFileResolver.Result, _ want: (DocumentFileResolver.Result) -> Bool) {
    if !want(got) { print("FAIL \(name): \(got)"); failures += 1 }
}
func isFile(_ r: DocumentFileResolver.Result) -> Bool { if case .file = r { true } else { false } }

check("plain file", DocumentFileResolver.resolve(path: "/img/a b.png", root: doc), isFile)
check("dot segment", DocumentFileResolver.resolve(path: "/./img/./a b.png", root: doc), isFile)
check("symlink inside root", DocumentFileResolver.resolve(path: "/same.png", root: doc), isFile)
check("missing", DocumentFileResolver.resolve(path: "/nope.png", root: doc)) { $0 == .notFound }
check("directory", DocumentFileResolver.resolve(path: "/img", root: doc)) { $0 == .notFound }
check("empty path", DocumentFileResolver.resolve(path: "/", root: doc)) { $0 == .notFound }
check("no root yet", DocumentFileResolver.resolve(path: "/img/a b.png", root: nil)) { $0 == .notFound }
check("dotdot (decoded %2f)", DocumentFileResolver.resolve(path: "/img/../../secret.txt", root: doc)) { $0 == .forbidden }
check("dotdot up to root", DocumentFileResolver.resolve(path: "/../doc/img/a b.png", root: doc)) { $0 == .forbidden }
check("symlink file out of root", DocumentFileResolver.resolve(path: "/out.txt", root: doc)) { $0 == .forbidden }
check("symlink dir out of root", DocumentFileResolver.resolve(path: "/outdir/secret.txt", root: doc)) { $0 == .forbidden }
check("sibling with same prefix", DocumentFileResolver.resolve(path: "/../doc2/x", root: doc)) { $0 == .forbidden }
check("root through a symlink", DocumentFileResolver.resolve(path: "/img/a b.png", root: sandbox.appending(path: "doc/outdir/doc"))) { isFile($0) }

if failures > 0 { exit(1) }
print("doc resolver: all checks passed")
SWIFT

# CLT alone may lack the swift runtime bits; prefer full Xcode like the Makefile does.
if xcode-select -p | grep -q CommandLineTools && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
swiftc -o "$tmp/check" "$root/App/Preview/DocumentFileResolver.swift" "$tmp/main.swift"
"$tmp/check"
