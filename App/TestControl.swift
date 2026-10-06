#if DEBUG
import AppKit
import EditorKit
import Foundation
import OSLog
import WebKit
import WorkspaceKit

/// A control socket for agents driving an isolated launch (`Scripts/run-isolated.sh`, client `Scripts/md2ctl`): Debug builds only,
/// isolated launches only, a Unix socket at `<MACDOWN2_ALLOWED_ROOT>/.ctl` (the temp dir is the user's alone, the socket 0600).
///
/// One request per connection: a JSON object line `{"cmd": "...", ...}` in, a JSON line `{"ok": true, "result": ...}` or
/// `{"ok": false, "error": "..."}` out. Everything runs on the main actor, in this process: keys, clicks and typed text go to this
/// app's own windows (`NSWindow.sendEvent`, the text input methods), never through the window server, so nothing reaches the
/// desktop and the app does not need to be frontmost. `window` (any command) is a window number from `state`; the default is the
/// front workspace window. Points are window points from the window's top-left corner (a `screencapture -o -l` shot divided by
/// `scale`).
///
///   state                              app, windows (number, frame, scale, first responder, tabs, layout, editor selection, where the
///                                      editor and the preview are: a preview DOM rect + the preview's origin = a point for `click`)
///   open paths=[..]                    open files / folders (relative to the isolated root), as Finder would
///   tab path=..                        make that tab active
///   menu path="File > New Window"      perform a main-menu item by its titles (`menus` lists them; run with MACDOWN2_LANGUAGE=en)
///   menus                              every main-menu title, with [on] / [disabled]
///   focus target=editor|preview        make it first responder
///   type text=.. [target] [delay=ms]   type text, a character at a time, through the first responder's insertText:replacementRange:
///   mark text=.. [target]              an input method's marked text (setMarkedText:...); `type` commits, `unmark` ends it
///   unmark [target]
///   command selector=deleteBackward: [target]   doCommandBySelector:, what a key binding sends (insertNewline:, moveLeft:, ...)
///   key key=b modifiers=cmd,shift      a key press: menu key equivalents first (cmd/ctrl), then the window (keyDown / keyUp).
///                                      Special keys: return tab space escape delete forwarddelete left right up down home end pageup pagedown
///   click x= y= [count=1]              a left click (mouse down / up) at that point
///   scroll x= y= dy= [dx=0]            a scroll-wheel event at that point (pixels; negative dy moves towards the end)
///   editor                             the editor's text and selection
///   select from= to=                   the editor's selection (UTF-16 offsets)
///   js script=".." [args={..}]         run JavaScript in the preview page (an async function body: `return` a JSON value)
///   ax [depth=40]                      the window's accessibility tree, flattened (role, label, id, value, frame)
///   press id=.. | label=..             accessibilityPerformPress on the first element with that identifier / label
///   defaults key=.. [value=..]         read, or write, a preference in this launch's own suite
///   activate                           bring the app to the front (takes focus from the user: only when a test needs it)
///   quit                               terminate through the normal Cmd-Q path
@MainActor
enum TestControl {
    private static let log = Logger(subsystem: "io.github.xuanji86.MacDown2", category: "test-control")
    nonisolated static let socketName = ".ctl"

    struct Failure: Error { let message: String }

    static func start() {
        guard let root = AppDefaults.isolation?.allowedRoot else { return }
        installStandInKeyWindow()
        let path = root.appending(path: socketName).path
        do {
            let fd = try listen(on: path)
            Thread.detachNewThread { acceptLoop(fd) }
            log.info("listening on \(path, privacy: .public)")
        } catch {
            log.error("no control socket: \((error as? Failure)?.message ?? "\(error)", privacy: .public)")
        }
    }

    // MARK: Socket

    nonisolated private static func listen(on path: String) throws -> Int32 {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw Failure(message: "socket path too long: \(path)") }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(message: "socket: errno \(errno)") }
        unlink(path)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 8) == 0 else {
            close(fd)
            throw Failure(message: "bind/listen \(path): errno \(errno)")
        }
        return fd
    }

    nonisolated private static func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            // A client gone before its reply (a timeout, Ctrl-C) must not kill the app with SIGPIPE.
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            Thread.detachNewThread { serve(client) }  // a client that never sends its line holds up only itself
        }
    }

    nonisolated private static func serve(_ client: Int32) {
        var request = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        // lazy: one request line of at most 64 MiB per connection, which is all md2ctl sends
        while request.count < 64 << 20 {
            let n = read(client, &chunk, chunk.count)
            if n <= 0 { break }
            request.append(contentsOf: chunk[0..<n])
            if chunk[0..<n].contains(0x0A) { break }
        }
        let received = request
        Task { @MainActor in
            let reply = await respond(to: received)
            reply.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let n = write(client, buffer.baseAddress! + offset, buffer.count - offset)
                    if n <= 0 { break }
                    offset += n
                }
            }
            close(client)
        }
    }

    private static func respond(to request: Data) async -> Data {
        var reply: [String: Any]
        do {
            guard let args = try JSONSerialization.jsonObject(with: request) as? [String: Any], let cmd = args["cmd"] as? String else {
                throw Failure(message: "expected a JSON object with \"cmd\"")
            }
            reply = ["ok": true, "result": json(try await run(cmd, args))]
        } catch let failure as Failure {
            reply = ["ok": false, "error": failure.message]
        } catch {
            reply = ["ok": false, "error": "\(error)"]
        }
        var data = (try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])) ?? Data("{\"ok\":false,\"error\":\"unencodable reply\"}".utf8)
        data.append(0x0A)
        return data
    }

    /// JavaScript and accessibility values may not be JSON as they come (NaN, Date, URL ...): those become strings.
    private static func json(_ value: Any?) -> Any {
        guard let value else { return NSNull() }
        return JSONSerialization.isValidJSONObject(["v": value]) ? value : String(describing: value)
    }

    // MARK: Commands

    private static func run(_ cmd: String, _ args: [String: Any]) async throws -> Any? {
        switch cmd {
        case "state": return state()
        case "open":
            guard let paths = args["paths"] as? [String] else { throw Failure(message: "open needs paths=[...]") }
            let root = AppDefaults.isolation?.allowedRoot
            WorkspaceRegistry.shared.open(paths.map { URL(filePath: $0, relativeTo: root).absoluteURL.resolvingSymlinksInPath() })
            return nil
        case "tab":
            let model = try workspace(args)
            let path = try string(args, "path")
            let tabs = model.controller.session.tabs
            let full = URL(filePath: path, relativeTo: AppDefaults.isolation?.allowedRoot).absoluteURL.resolvingSymlinksInPath().path
            let named = tabs.filter { $0.url.lastPathComponent == path }
            // a path (absolute, or relative to the isolated root), else a file name that only one tab has
            guard let tab = tabs.first(where: { describe($0.url) == path || $0.url.resolvingSymlinksInPath().path == full }) ?? (named.count == 1 ? named.first : nil) else {
                throw Failure(message: named.count > 1 ? "several tabs are called \(path): give its path" : "no tab \(path)")
            }
            model.controller.activate(tab.url)
            return nil
        case "menu":
            _ = try window(args)  // the stand-in key window first: SwiftUI's commands act on the focused scene
            return try performMenu(try string(args, "path"))
        case "menus":
            _ = try window(args)
            return menuTitles()
        case "focus":
            let window = try window(args)
            guard window.makeFirstResponder(try target(args, in: window, required: true)) else { throw Failure(message: "refused first responder") }
            return nil
        case "type":
            let window = try window(args)
            let view = try target(args, in: window)
            let delay = int(args, "delay") ?? 20
            for c in try string(args, "text") {
                try send(view, "insertText:replacementRange:", String(c) as NSString, NSRange(location: NSNotFound, length: 0))
                if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
            }
            return nil
        case "mark":
            let window = try window(args)
            let text = try string(args, "text") as NSString
            try send(try target(args, in: window), "setMarkedText:selectedRange:replacementRange:", text, NSRange(location: text.length, length: 0), NSRange(location: NSNotFound, length: 0))
            return nil
        case "unmark":
            let window = try window(args)
            let view = try target(args, in: window)
            guard view.responds(to: NSSelectorFromString("unmarkText")) else { throw Failure(message: "\(type(of: view)) has no unmarkText") }
            view.perform(NSSelectorFromString("unmarkText"))
            return nil
        case "command":
            let window = try window(args)
            let view = try target(args, in: window)
            let selector = NSSelectorFromString(try string(args, "selector"))
            let doCommand = NSSelectorFromString("doCommandBySelector:")
            guard view.responds(to: doCommand) else { throw Failure(message: "\(type(of: view)) has no doCommandBySelector:") }
            typealias Fn = @convention(c) (AnyObject, Selector, Selector) -> Void
            unsafeBitCast(view.method(for: doCommand), to: Fn.self)(view, doCommand, selector)
            return nil
        case "key": return try key(args)
        case "click": return try click(args)
        case "scroll": return try scroll(args)
        case "editor":
            let editor = try self.editor(in: try window(args))
            let selection = editor.selectedRange()
            return ["text": editor.string, "selection": [selection.location, selection.length], "marked": editor.hasMarkedText()]
        case "select":
            let editor = try self.editor(in: try window(args))
            guard let from = int(args, "from"), let to = int(args, "to"), 0 <= from, from <= to, to <= (editor.string as NSString).length else { throw Failure(message: "select needs 0 <= from <= to <= length") }
            editor.setSelectedRange(NSRange(location: from, length: to - from))
            editor.scrollRangeToVisible(editor.selectedRange())
            return nil
        case "js":
            guard let web = webView(in: try window(args)) else { throw Failure(message: "no preview in this window") }
            return try await web.callAsyncJavaScript(try string(args, "script"), arguments: args["args"] as? [String: Any] ?? [:], contentWorld: .page)
        case "ax": return accessibilityTree(try window(args), depth: int(args, "depth") ?? 40)
        case "press": return try press(args)
        case "defaults":
            let key = try string(args, "key")
            if args.keys.contains("value") {
                let value = args["value"]
                if value is NSNull { AppDefaults.store.removeObject(forKey: key) }
                else if let value, PropertyListSerialization.propertyList(value, isValidFor: .binary) { AppDefaults.store.set(value, forKey: key) }
                else { throw Failure(message: "value is not a property list (a null inside it?)") }
            }
            return AppDefaults.store.object(forKey: key)
        case "activate":
            NSApp.activate(ignoringOtherApps: true)  // deprecated, but the plain activate() is refused while another app is in front
            try window(args).makeKeyAndOrderFront(nil)  // only the window commands act on: the others keep their order
            return nil
        case "quit":
            DispatchQueue.main.async { NSApp.terminate(nil) }  // after this reply is written
            return nil
        default: throw Failure(message: "unknown command \(cmd)")
        }
    }

    private static func string(_ args: [String: Any], _ name: String) throws -> String {
        guard let value = args[name] as? String else { throw Failure(message: "missing \(name)=...") }
        return value
    }

    /// A number given as a number or as a string (`md2ctl ... from=3` sends "3").
    private static func number(_ args: [String: Any], _ name: String) -> Double? {
        (args[name] as? NSNumber)?.doubleValue ?? (args[name] as? String).flatMap(Double.init)
    }

    /// nil for anything that is not a whole number in range (NaN, inf, 1e300 would trap in Int(_:)); `Int32` likewise.
    private static func int(_ args: [String: Any], _ name: String) -> Int? { number(args, name).flatMap { Int(exactly: $0.rounded()) } }
    private static func int32(_ args: [String: Any], _ name: String) -> Int32? { number(args, name).flatMap { Int32(exactly: $0.rounded()) } }

    private static func describe(_ url: URL) -> String { url.isFileURL ? url.path : url.absoluteString }

    // MARK: Windows and views

    private static func window(_ args: [String: Any]) throws -> NSWindow {
        let window: NSWindow
        if let number = int(args, "window") {
            guard let found = NSApp.windows.first(where: { $0.windowNumber == number }) else { throw Failure(message: "no window \(number)") }
            window = found
        } else {
            guard let front = WorkspaceRegistry.shared.orderedModels().first?.window else { throw Failure(message: "no workspace window") }
            window = front
        }
        standInKey(window)
        keepPainting(window)
        return window
    }

    /// A window behind another app's is occluded, and WebKit stops rendering an occluded page (`visibilityState` "hidden",
    /// no animation frames): the preview would never catch up with the editor nor show in a screenshot. Off for the windows driven here.
    private static func keepPainting(_ window: NSWindow) {
        // WKWebView SPI, the switch WebKit's own tests use. Called through its setter: KVC would find no setter for an
        // underscored key and write the ivar directly.
        let getter = NSSelectorFromString("_windowOcclusionDetectionEnabled"), setter = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        typealias Get = @convention(c) (AnyObject, Selector) -> Bool
        typealias Set = @convention(c) (AnyObject, Selector, Bool) -> Void
        func walk(_ view: NSView) {
            if let web = view as? WKWebView, web.responds(to: getter), web.responds(to: setter),
               unsafeBitCast(web.method(for: getter), to: Get.self)(web, getter) {
                unsafeBitCast(web.method(for: setter), to: Set.self)(web, setter, false)
                // A page already hidden stays so until WebKit looks at its visibility again: a hide and show makes it look.
                web.isHidden = true
                web.isHidden = false
            }
            view.subviews.forEach(walk)
        }
        window.contentView.map(walk)
    }

    // MARK: Stand-in key window

    /// The window commands act on while the app is in the background (the user is working in another app): AppKit and SwiftUI see
    /// it as the key and main window, so menus validate and shortcuts, clicks in the preview, focus rings and the caret behave as if
    /// it were in front; the window server, and so the desktop, is never told. The app becoming active for real ends it.
    nonisolated(unsafe) fileprivate static weak var standIn: NSWindow?

    private static func standInKey(_ window: NSWindow) {
        guard standIn !== window, standIn != nil || !NSApp.isActive else { return }
        let previous = standIn
        standIn = window
        previous?.resignKey()
        previous?.resignMain()
        window.becomeMain()
        window.becomeKey()  // what AppKit calls on a key change: the window's own bookkeeping and didBecomeKeyNotification
    }

    private static func installStandInKeyWindow() {
        func swap(_ cls: AnyClass, _ original: Selector, _ replacement: Selector) {
            guard let o = class_getInstanceMethod(cls, original), let r = class_getInstanceMethod(cls, replacement) else { return log.error("cannot swizzle \(NSStringFromSelector(original), privacy: .public)") }
            method_exchangeImplementations(o, r)
        }
        swap(NSWindow.self, #selector(getter: NSWindow.isKeyWindow), #selector(getter: NSWindow.ctl_isKeyWindow))
        swap(NSApplication.self, #selector(getter: NSApplication.keyWindow), #selector(getter: NSApplication.ctl_keyWindow))
        swap(NSApplication.self, #selector(getter: NSApplication.isActive), #selector(getter: NSApplication.ctl_isActive))
        swap(NSWindow.self, #selector(getter: NSWindow.isMainWindow), #selector(getter: NSWindow.ctl_isMainWindow))
        swap(NSApplication.self, #selector(getter: NSApplication.mainWindow), #selector(getter: NSApplication.ctl_mainWindow))
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                // AppKit never made the stand-in key: undo by hand what was done by hand, then AppKit's own key window rules.
                let previous = TestControl.standIn
                TestControl.standIn = nil
                if let previous, !previous.isKeyWindow { previous.resignKey() }
                if let previous, !previous.isMainWindow { previous.resignMain() }
            }
        }
    }

    private static func workspace(_ args: [String: Any]) throws -> WindowModel {
        let window = try window(args)
        guard let model = WorkspaceRegistry.shared.models.values.first(where: { $0.window === window }) else { throw Failure(message: "not a workspace window") }
        return model
    }

    private static func descendant<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { descendant(type, in: $0) }.first
    }

    private static func editor(in window: NSWindow) throws -> MarkdownTextView {
        guard let editor = descendant(MarkdownTextView.self, in: window.contentView) else { throw Failure(message: "no editor in this window") }
        return editor
    }

    private static func webView(in window: NSWindow) -> WKWebView? { descendant(WKWebView.self, in: window.contentView) }

    /// `target=editor|preview`, or (when not required) whatever is first responder now.
    private static func target(_ args: [String: Any], in window: NSWindow, required: Bool = false) throws -> NSResponder {
        switch args["target"] as? String {
        case "editor": return try editor(in: window)
        case "preview":
            guard let web = webView(in: window) else { throw Failure(message: "no preview in this window") }
            return web
        case nil where !required:
            guard let responder = window.firstResponder else { throw Failure(message: "no first responder") }
            return responder
        default: throw Failure(message: "target=editor|preview")
        }
    }

    /// Text input methods called directly, as AppKit calls them for a key press or an input method (WKWebView's are not public API).
    private static func send(_ view: NSResponder, _ name: String, _ text: NSString, _ ranges: NSRange...) throws {
        let selector = NSSelectorFromString(name)
        guard view.responds(to: selector) else { throw Failure(message: "\(type(of: view)) (the first responder?) has no \(name); focus target=editor|preview first") }
        if ranges.count == 1 {
            typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, NSRange) -> Void
            unsafeBitCast(view.method(for: selector), to: Fn.self)(view, selector, text, ranges[0])
        } else {
            typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, NSRange, NSRange) -> Void
            unsafeBitCast(view.method(for: selector), to: Fn.self)(view, selector, text, ranges[0], ranges[1])
        }
    }

    private static func state() -> [String: Any] {
        let registry = WorkspaceRegistry.shared
        let windows: [[String: Any]] = NSApp.orderedWindows.filter(\.isVisible).map { window in
            keepPainting(window)
            let f = window.frame
            var entry: [String: Any] = [
                "window": window.windowNumber, "title": window.title, "key": window.isKeyWindow, "scale": window.backingScaleFactor,
                "frame": [f.minX, f.minY, f.width, f.height],
                "firstResponder": window.firstResponder.map { String(describing: type(of: $0)) } ?? "-",
            ]
            if let model = registry.models.values.first(where: { $0.window === window }) {
                let session = model.controller.session
                entry["layout"] = "\(model.layout.mode)"
                entry["sidebar"] = model.sidebarVisible ? "\(model.sidebarSection)" : "hidden"
                entry["roots"] = model.sidebar.folders.roots.map(\.path)
                entry["tabs"] = session.tabs.map { ["path": describe($0.url), "active": $0.id == session.activeID, "dirty": registry.isDirty($0.url)] }
            }
            // Where the panes are, in the window points `click` takes: a preview DOM rect (getBoundingClientRect) plus this origin.
            func frame(_ view: NSView?) -> Any {
                guard let view, !view.isHiddenOrHasHiddenAncestor, view.window === window else { return NSNull() }
                let r = view.convert(view.bounds, to: nil)
                return [r.minX, window.frame.height - r.maxY, r.width, r.height]
            }
            if let editor = try? editor(in: window) {
                let selection = editor.selectedRange()
                entry["editor"] = ["length": (editor.string as NSString).length, "selection": [selection.location, selection.length],
                                   "focused": window.firstResponder === editor, "frame": frame(editor.enclosingScrollView)]
            }
            entry["preview"] = frame(webView(in: window))
            return entry
        }
        return [
            "pid": ProcessInfo.processInfo.processIdentifier, "active": NSApp.isActive, "standInKey": standIn?.windowNumber ?? NSNull(),
            "language": Bundle.main.preferredLocalizations.first ?? "-", "root": AppDefaults.isolation?.allowedRoot?.path ?? "-",
            "windows": windows,
        ]
    }

    // MARK: Menus

    private static func clean(_ title: String) -> String {
        title.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "").trimmingCharacters(in: .whitespaces)
    }

    /// What AppKit does just before a menu shows: SwiftUI fills the menu and brings its items up to date then.
    private static func open(_ menu: NSMenu) {
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.delegate?.menuWillOpen?(menu)
        menu.update()
        menu.delegate?.menuDidClose?(menu)
    }

    private static func performMenu(_ path: String) throws -> Any? {
        var menu = NSApp.mainMenu
        let parts = path.components(separatedBy: ">").map(clean)
        for (index, part) in parts.enumerated() {
            guard let current = menu else { throw Failure(message: "no menu at \(part)") }
            open(current)
            let titles = current.items.map { clean($0.title.isEmpty ? $0.submenu?.title ?? "" : $0.title).lowercased() }
            // the exact title, else the one title that starts with it ("Undo" for "Undo Typing")
            let prefixed = titles.indices.filter { titles[$0].hasPrefix(part.lowercased()) }
            guard let at = titles.firstIndex(of: part.lowercased()) ?? (prefixed.count == 1 ? prefixed.first : nil) else {
                throw Failure(message: "no menu item \"\(part)\" in \(current.items.map(\.title).filter { !$0.isEmpty })")
            }
            let item = current.items[at]
            if index == parts.count - 1 {
                guard item.isEnabled else { throw Failure(message: "\(path) is disabled") }  // up to date: `open` just refreshed it
                current.performActionForItem(at: at)
                return nil
            }
            menu = item.submenu
        }
        return nil
    }

    private static func menuTitles() -> [String] {
        var titles: [String] = []
        func walk(_ menu: NSMenu, _ path: String) {
            open(menu)
            for item in menu.items where !item.isSeparatorItem {
                let title = item.title.isEmpty ? (item.submenu?.title ?? "") : item.title
                let name = path.isEmpty ? title : "\(path) > \(title)"
                titles.append(name + (item.state == .on ? " [on]" : "") + (item.isEnabled || item.submenu != nil ? "" : " [disabled]"))
                if let submenu = item.submenu { walk(submenu, name) }
            }
        }
        if let main = NSApp.mainMenu { walk(main, "") }
        return titles
    }

    // MARK: Events

    /// ANSI key codes 0 ... 50, by position (`·` = no key on a US layout). lazy: US layout only; others need UCKeyTranslate.
    private static let keyCodes = Array("asdfhgzxcv·bqweryt123465=97-80]ou[ip\rlj'k;\\,/nm.\t `")
    private static let specialKeys: [String: (code: UInt16, chars: String)] = [
        "return": (36, "\r"), "tab": (48, "\t"), "space": (49, " "), "escape": (53, "\u{1B}"), "delete": (51, "\u{7F}"),
        "forwarddelete": (117, String(UnicodeScalar(NSDeleteFunctionKey)!)),
        "left": (123, String(UnicodeScalar(NSLeftArrowFunctionKey)!)), "right": (124, String(UnicodeScalar(NSRightArrowFunctionKey)!)),
        "down": (125, String(UnicodeScalar(NSDownArrowFunctionKey)!)), "up": (126, String(UnicodeScalar(NSUpArrowFunctionKey)!)),
        "home": (115, String(UnicodeScalar(NSHomeFunctionKey)!)), "end": (119, String(UnicodeScalar(NSEndFunctionKey)!)),
        "pageup": (116, String(UnicodeScalar(NSPageUpFunctionKey)!)), "pagedown": (121, String(UnicodeScalar(NSPageDownFunctionKey)!)),
    ]

    // lazy: US layout only, like `keyCodes`
    private static let shifted: [String: String] = Dictionary(uniqueKeysWithValues: zip("1234567890-=[]\\;',./`".map(String.init), "!@#$%^&*()_+{}|:\"<>?~".map(String.init)))

    private static func key(_ args: [String: Any]) throws -> Any? {
        let window = try window(args)
        let name = try string(args, "key").lowercased()
        let given = args["modifiers"] as? [String] ?? (args["modifiers"] as? String)?.split(separator: ",").map(String.init) ?? []  // [..] or "cmd,shift"
        let names = Set(given.map { $0.lowercased() })
        var flags: NSEvent.ModifierFlags = []
        if names.contains("cmd") { flags.insert(.command) }
        if names.contains("shift") { flags.insert(.shift) }
        if names.contains("option") || names.contains("alt") { flags.insert(.option) }
        if names.contains("ctrl") || names.contains("control") { flags.insert(.control) }
        let code: UInt16, plain: String
        if let special = specialKeys[name] {
            (code, plain) = special
            if special.code >= 115 { flags.insert([.function, .numericPad]) }
        } else if name.count == 1, let at = keyCodes.firstIndex(of: Character(name)), name != "·" {
            (code, plain) = (UInt16(at), name)
        } else {
            throw Failure(message: "unknown key \(name)")
        }
        let chars = flags.contains(.shift) ? (shifted[plain] ?? plain.uppercased()) : plain
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                             context: nil, characters: chars, charactersIgnoringModifiers: plain, isARepeat: false, keyCode: code)
        }
        guard let down = event(.keyDown), let up = event(.keyUp) else { throw Failure(message: "could not make the key event") }
        if !flags.intersection([.command, .control]).isEmpty {
            for menu in NSApp.mainMenu?.items.compactMap(\.submenu) ?? [] { open(menu) }  // as menuTitles: items current before matching
            // AppKit's order: the key window's views, then the menu bar.
            if window.performKeyEquivalent(with: down) { return "window" }
            if NSApp.mainMenu?.performKeyEquivalent(with: down) == true { return "menu" }
        }
        window.sendEvent(down)
        window.sendEvent(up)
        return "keyDown"
    }

    private static func point(_ args: [String: Any], in window: NSWindow) throws -> NSPoint {
        guard let x = number(args, "x"), let y = number(args, "y") else { throw Failure(message: "needs x= y= (points from the window's top-left)") }
        return NSPoint(x: x, y: window.frame.height - y)  // the window's base coordinates are bottom-left
    }

    private static func click(_ args: [String: Any]) throws -> Any? {
        let window = try window(args)
        let at = try point(args, in: window)
        let count = max(1, int(args, "count") ?? 1)
        for n in 1...count {
            func event(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: n, pressure: type == .leftMouseDown ? 1 : 0)
            }
            guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { throw Failure(message: "could not make the mouse event") }
            // A view may track the drag in a loop of its own (NSTextView does), reading the queue until the button comes up: the
            // mouse up waits there (this app's own queue) before the mouse down is sent.
            NSApp.postEvent(up, atStart: false)
            window.sendEvent(down)
            // A view that does not track (WKWebView forwards and returns) left it queued: send it now, so a double click goes
            // down, up, down, up.
            if let queued = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) { window.sendEvent(queued) }
        }
        return window.contentView?.hitTest(at).map { String(describing: type(of: $0)) }
    }

    private static func scroll(_ args: [String: Any]) throws -> Any? {
        let window = try window(args)
        let at = try point(args, in: window)
        guard let dy = int32(args, "dy") ?? (args["dy"] == nil ? 0 : nil), let dx = int32(args, "dx") ?? (args["dx"] == nil ? 0 : nil) else { throw Failure(message: "dy= dx= must be whole numbers") }
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { throw Failure(message: "could not make the scroll event") }
        // An event made from a CGEvent belongs to no window, and then its locationInWindow is its screen location: placed so
        // that the two agree, the view under the point (and WebKit's own hit test) see the right spot. Global display
        // coordinates are top-left based.
        cg.location = CGPoint(x: at.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - at.y)
        guard let event = NSEvent(cgEvent: cg), abs(event.locationInWindow.x - at.x) < 1, abs(event.locationInWindow.y - at.y) < 1,
              let view = window.contentView?.hitTest(at) else { throw Failure(message: "could not aim the scroll event at that point") }
        view.scrollWheel(with: event)
        return String(describing: type(of: view))
    }

    // MARK: Accessibility

    private struct Node {
        let element: NSAccessibilityProtocol
        let depth: Int
    }

    private static func nodes(_ window: NSWindow, depth limit: Int) -> [Node] {
        var out: [Node] = []
        func walk(_ element: NSAccessibilityProtocol, _ depth: Int) {
            out.append(Node(element: element, depth: depth))
            guard depth < limit, out.count < 5000 else { return }  // lazy: 5000 elements, more than any window here has
            for child in element.accessibilityChildren() ?? [] {
                if let child = child as? NSAccessibilityProtocol { walk(child, depth + 1) }
            }
        }
        walk(window, 0)
        return out
    }

    private static func describe(_ node: Node, in window: NSWindow) -> [String: Any] {
        let e = node.element
        let f = e.accessibilityFrame()
        var entry: [String: Any] = [
            "d": node.depth, "role": e.accessibilityRole()?.rawValue ?? "-",
            "frame": [f.minX - window.frame.minX, window.frame.maxY - f.maxY, f.width, f.height].map { ($0 * 10).rounded() / 10 },
        ]
        if let label = e.accessibilityLabel() ?? e.accessibilityTitle(), !label.isEmpty { entry["label"] = label }
        if let id = e.accessibilityIdentifier(), !id.isEmpty { entry["id"] = id }
        if let value = e.accessibilityValue() { entry["value"] = String(String(describing: value).prefix(200)) }
        if !e.isAccessibilityEnabled() { entry["disabled"] = true }
        return entry
    }

    private static func accessibilityTree(_ window: NSWindow, depth: Int) -> [[String: Any]] {
        nodes(window, depth: depth).map { describe($0, in: window) }
    }

    private static func press(_ args: [String: Any]) throws -> Any? {
        let window = try window(args)
        let id = args["id"] as? String, label = args["label"] as? String
        guard id != nil || label != nil else { throw Failure(message: "press needs id= or label=") }
        guard let node = nodes(window, depth: 60).first(where: { node in
            (id != nil && node.element.accessibilityIdentifier() == id) || (label != nil && (node.element.accessibilityLabel() ?? node.element.accessibilityTitle()) == label)
        }) else { throw Failure(message: "no element with \(id.map { "id \($0)" } ?? "label \(label!)")") }
        var pressed = describe(node, in: window)
        pressed["handled"] = node.element.accessibilityPerformPress()  // SwiftUI buttons act and still answer false
        return pressed
    }
}

private extension NSWindow {
    @objc nonisolated var ctl_isKeyWindow: Bool { TestControl.standIn === self || self.ctl_isKeyWindow }  // swapped: this calls the original
    @objc nonisolated var ctl_isMainWindow: Bool { TestControl.standIn === self || self.ctl_isMainWindow }
}

private extension NSApplication {
    @objc nonisolated var ctl_keyWindow: NSWindow? { self.ctl_keyWindow ?? TestControl.standIn }
    @objc nonisolated var ctl_mainWindow: NSWindow? { self.ctl_mainWindow ?? TestControl.standIn }
    @objc nonisolated var ctl_isActive: Bool { self.ctl_isActive || TestControl.standIn != nil }
}
#endif
