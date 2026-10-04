// Prints the title of every Dock tile, one per line, read through Accessibility.
// usage: dock-tiles <Dock pid>. Used instead of osascript: on macOS 27 every osascript started from a terminal leaves a
// dead Dock tile named after that terminal, so asking System Events about the Dock was itself making the ghosts.
import ApplicationServices
import Foundation

guard CommandLine.arguments.count == 2, let pid = pid_t(CommandLine.arguments[1]) else { exit(64) }
guard AXIsProcessTrusted() else { FileHandle.standardError.write(Data("not trusted\n".utf8)); exit(2) }
func value(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, key as CFString, &v) == .success ? v : nil
}
let children = { (e: AXUIElement) in value(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
guard let list = children(AXUIElementCreateApplication(pid)).first(where: { value($0, kAXRoleAttribute) as? String == kAXListRole }) else { exit(1) }
for tile in children(list) { print(value(tile, kAXTitleAttribute) as? String ?? "") }
