import Foundation
import CoreGraphics

// usage: winid <pid>
// Prints "<window id> <width> <height>" for every on-screen layer-0 window owned by <pid>, largest first. CoreGraphics only
// (no AppKit), so it never shows up in the Dock or steals focus; the id is what `screencapture -l <id>` wants, which
// captures that one window and nothing else. Built on demand by Scripts/run-isolated.sh.
guard CommandLine.arguments.count == 2, let pid = Int(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: winid <pid>\n".utf8))
    exit(2)
}
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
var found: [(id: Int, w: Int, h: Int)] = []
for w in list where (w[kCGWindowOwnerPID as String] as? Int) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    found.append((w[kCGWindowNumber as String] as? Int ?? 0, Int(b["Width"] ?? 0), Int(b["Height"] ?? 0)))
}
for f in found.sorted(by: { $0.w * $0.h > $1.w * $1.h }) { print(f.id, f.w, f.h) }
