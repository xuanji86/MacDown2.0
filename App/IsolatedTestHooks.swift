import AppKit
import EditorKit
import Foundation
import OSLog
import WebKit
import WorkspaceKit

/// Debug-only drivers for `Scripts/run-isolated.sh` launches, so behaviour that normally needs a keystroke can be checked
/// without sending the desktop any input: all are inert unless the launch is isolated, and Release builds have none.
///
///   MACDOWN2_TEST_UNTITLED_TEXT=<text>    the first untitled document starts with this text, as if typed
///   MACDOWN2_TEST_TERMINATE_AFTER=<secs>  quit through the normal Cmd-Q path (the unsaved-documents review) after a delay
///   MACDOWN2_TEST_OPEN_SETTINGS=1         open the Settings window (as ⌘, does) once the app is up (after 1.5 s, or ...
///   MACDOWN2_TEST_OPEN_SETTINGS_AFTER=<secs>  ... after this many seconds: opened before the document window exists, it is the only one)
///   MACDOWN2_TEST_STATUS_BAR=1            show the status bar (View > Show Status Bar) in this launch's own defaults suite
///   MACDOWN2_TEST_TOOL_ENV_REREAD=1       also run the Settings "Re-read" (login-shell environment) action first
///   MACDOWN2_TEST_SEARCH=<query>          the first workspace window shows the sidebar's search page and runs this query (waits
///                                         up to 5 s for a workspace folder or active document to search in)
///   MACDOWN2_TEST_SEARCH_REGEX=1          with the above: the regex switch is on
///   MACDOWN2_TEST_SEARCH_OPEN=<n[,n...]>  with the above: once the results are in, opens the n-th hit (1-based) as a tab and
///                                         selects the match in the editor, as Return on it would; several: one a second
///   MACDOWN2_TEST_WINDOW_FRAME=<"x y w h" | max>  every workspace window takes this frame in screen points (bottom-left
///                                         origin), or the main screen's visible frame ("max": what zoom gives), once
///   MACDOWN2_TEST_EDIT_TEXT=<text>        <text> is appended to the first open file document, as if typed (it becomes unsaved), ...
///   MACDOWN2_TEST_EDIT_AFTER=<secs>       ... after this many seconds (default 2): the way to get a dirty document without input
///   MACDOWN2_TEST_PROMPT_ANSWER=keep|reload  answer the "changed on disk" sheet this way ...
///   MACDOWN2_TEST_PROMPT_DELAY=<secs>     ... after this many seconds (default 4; the sheet stays up that long to be photographed)
///   MACDOWN2_TEST_TOGGLE_TASK_LINE=<n>    the preview PAGE clicks the task checkbox on source line n, with its own JavaScript
///                                         (see `toggleTaskThroughPage`); `_DELAY`, `_LAYOUT=previewOnly`, `_UNDO=1` and `_SAVE=afterToggle|afterUndo` refine it
///   MACDOWN2_TEST_TAB_UNDO=<secs>         type into tab A, switch to B, open A in a second window and undo there, <secs> between the
///                                         steps (see `tabSwitchUndo`; needs two files open in the first window)
///   MACDOWN2_TEST_SHOW_OUTLINE=<secs>     the first window shows the sidebar's outline page after this many seconds
///   MACDOWN2_TEST_CLOSE_ACTIVE_TAB=<secs> the first window closes its active tab after this many seconds, as ⌘W does
///   MACDOWN2_TEST_CLOSE_WINDOW=<secs>     the first window closes, as the red button / ⇧⌘W does (`performClose`)
///   MACDOWN2_TEST_REOPEN=<secs>           the Dock icon is "clicked" (`applicationShouldHandleReopen`) after this many seconds
///   MACDOWN2_TEST_NEW_WINDOW=<secs>       a new workspace window opens after this many seconds, as File > New Window (⌥⌘N) does
///   MACDOWN2_TEST_ACTIVATE=<secs>         the app activates itself and brings its windows to the front after this many seconds, so a
///                                         background launch is photographed with live traffic lights and a painted preview
///   MACDOWN2_TEST_TOOLBAR_STYLE=minimal|classic  the launch's own defaults suite starts with this toolbar style (Settings ▸ Editor ▸ Window)
///   MACDOWN2_TEST_TOOLBAR_STYLE_FLIP=<secs>  after this many seconds the style switches to the other one, as the Settings picker does
///                                         (the live switch, photographed before / after)
///   MACDOWN2_TEST_DUMP_TOOLBAR=<secs>     after this many seconds, every window's toolbar style, items, visibility priorities and overflow-menu
///                                         forms go to the log (category "toolbar-dump")
///   MACDOWN2_TEST_TAB_RENAME=<secs>       the first window's active tab opens its Name / Tags / Where popover after this many seconds,
///                                         as a click on the active tab's name does (the stem selected, ready for a photo)
///   MACDOWN2_TEST_TAB_RENAME_COMMIT=<name> with `_AFTER=<secs>` (default 4 after the start): the popover applies <name> as typed, the
///                                         way Return does; `_TAGS=a,b` and `_FOLDER=<dir, relative to the isolated root>` set the other two rows first (an
///                                         untitled document is saved there, a saved file renamed / moved)
///   MACDOWN2_TEST_DUMP_MENUS=<secs>       after this many seconds, the app's language and every title in the main menu bar go to the
///                                         log (menus cannot be photographed window-only): category "menu-dump"
///                                         (the language itself is chosen with MACDOWN2_LANGUAGE in `Scripts/run-isolated.sh`)
///   MACDOWN2_TEST_PASTE=image|url         paste into the first window's editor through a private pasteboard (never the real clipboard):
///                                         `image` a generated TIFF (saved as PNG under images/ next to the document, or the "save first"
///                                         sheet for an untitled one), `url` https://example.com over the first word; `_AFTER=<secs>` (default 3)
///   MACDOWN2_TEST_SCROLL_PAST_END=1       the launch's own defaults suite starts with Settings ▸ Editor ▸ Scroll past the end on
///   MACDOWN2_TEST_SCROLL_TO_END=<secs>    after this many seconds the first editor scrolls as far down as it may
///   MACDOWN2_TEST_EDITOR_THEME=<name>     after `_AFTER=<secs>` (default 3) the launch's defaults suite picks this editor theme
///   MACDOWN2_TEST_DUMP_EDITOR=<secs>      after this many seconds the editor's scroll state, theme and the theme list (and the files the
///                                         themes folder skipped) go to the log (category "editor-dump")
///                                         The user themes folder of an isolated launch is `<root>/.macdown2-themes` (printed as ROOT).
///   MACDOWN2_TEST_PREVIEW_EDIT=<line>     preview editing (PLAN M2), without input events: the page puts the block on source line <line>
///                                         in edit mode with the caret at the end of that line's text, the preview's web view becomes
///                                         first responder, and the steps below go through its own text input methods (what a keyboard
///                                         and an input method reach), `MACDOWN2_TEST_PREVIEW_DELAY` (default 3) seconds apart:
///   MACDOWN2_TEST_PREVIEW_TYPE=<text>     ... typed one character at a time (`insertText:replacementRange:`)
///   MACDOWN2_TEST_PREVIEW_IME=<a,ab,abc>|<commit>  ... an input method composing a, ab, abc and committing <commit> (`setMarkedText:...`)
///   MACDOWN2_TEST_PREVIEW_BACKSPACE=<n>   ... n backspaces (`doCommandBySelector: deleteBackward:`)
///   MACDOWN2_TEST_PREVIEW_UNDO=1          ... then undo and redo through the responder chain, as Cmd-Z / Cmd-Shift-Z reach them
///   MACDOWN2_TEST_PREVIEW_AUTOCORRECT=1   ... first: the editor's spelling correction, text replacement, smart quotes and dashes on
///   MACDOWN2_TEST_PREVIEW_IME_CANCEL=<a,ab>  ... after the IME step: composing a, ab; the editor gets text typed at its end meanwhile;
///                                         then the composition is cancelled (empty marked text, unmarkText), as Escape does
///   MACDOWN2_TEST_PREVIEW_IME_OVER=<a>:<b>|<z,zh>|<commit>  ... characters a ..< b of the edited block selected, then composed over
///                                         (after each step the page's own record of WebKit's input events is logged too)
///   MACDOWN2_TEST_FOLLOW_CARET=<line>     before edit mode: "preview follows the caret" on, the preview focused, and a search result
///                                         on <line> revealed in the editor without focusing it; the preview's top line before/after
///   MACDOWN2_TEST_PEER_SELECT=<from>,<to> two-way selection: the editor (made first responder) selects source [from, to) and the
///                                         page's highlight is logged; `MACDOWN2_TEST_PAGE_SELECT=<line>:<a>:<b>` then selects characters
///                                         a ..< b of the first text node of the block on <line> in the page and logs what the editor shows.
///                                         Everything is logged: `log show --predicate 'category == "preview-edit-hook"'`
#if DEBUG
/// Debug builds log a closed window and its models going away (`WindowModel`, `PreviewModel`, `EditorHandle` deinit), to check that
/// nothing keeps a window's objects alive: `log show --predicate 'category == "lifetime"' --info`.
let debugLifetime = Logger(subsystem: "io.github.xuanji86.MacDown2", category: "lifetime")
#endif

enum IsolatedTestHooks {
    #if DEBUG
    private static func value(_ name: String) -> String? {
        guard AppDefaults.isIsolated else { return nil }
        return ProcessInfo.processInfo.environment[name]
    }
    private nonisolated(unsafe) static var typed = false
    private nonisolated(unsafe) static var searched = false
    private nonisolated(unsafe) static var framed = Set<Int>()
    private nonisolated(unsafe) static var toggled = false
    private nonisolated(unsafe) static var tabUndoRan = false
    private nonisolated(unsafe) static var previewEditRan = false
    private static let tabLog = Logger(subsystem: "io.github.xuanji86.MacDown2", category: "tab-undo-hook")
    static let editLog = Logger(subsystem: "io.github.xuanji86.MacDown2", category: "preview-edit-hook")
    private static let hookLog = Logger(subsystem: "io.github.xuanji86.MacDown2", category: "task-toggle-hook")
    private static let toolbarLog = Logger(subsystem: "io.github.xuanji86.MacDown2", category: "toolbar-dump")
    private static let editorLog = Logger(subsystem: "io.github.xuanji86.MacDown2", category: "editor-dump")
    private static let menuLog = Logger(subsystem: "io.github.xuanji86.MacDown2", category: "menu-dump")
    #endif

    @MainActor static func typeIntoUntitled(_ model: WindowModel) {
        #if DEBUG
        guard !typed, let text = value("MACDOWN2_TEST_UNTITLED_TEXT"), let doc = model.activeDocument, doc.isPristine else { return }
        typed = true
        doc.text = text
        doc.noteUserEdit()
        #endif
    }

    @MainActor static func showSearch(in model: WindowModel, open: @escaping @MainActor (SearchHit) -> Void) {
        #if DEBUG
        guard !searched, let query = value("MACDOWN2_TEST_SEARCH") else { return }
        searched = true
        let openIndexes = (value("MACDOWN2_TEST_SEARCH_OPEN") ?? "").split(separator: ",").compactMap { Int($0) }
        Task { @MainActor in
            for _ in 0..<50 where model.search.scopeTitle.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            model.showSearch()
            model.search.isRegex = value("MACDOWN2_TEST_SEARCH_REGEX") == "1"
            model.search.query = query
            model.search.start()
            guard !openIndexes.isEmpty else { return }
            await model.search.task?.value
            let hits = model.search.hits
            for index in openIndexes where hits.indices.contains(index - 1) {
                open(hits[index - 1])
                try? await Task.sleep(for: .seconds(1))  // each one after the editor has switched
            }
        }
        #endif
    }

    @MainActor static func applyWindowFrame(_ window: NSWindow) {
        #if DEBUG
        guard let raw = value("MACDOWN2_TEST_WINDOW_FRAME"), framed.insert(window.windowNumber).inserted else { return }
        let numbers = raw.split(separator: " ").compactMap { Double($0) }
        let frame: NSRect
        if raw == "max", let screen = window.screen ?? NSScreen.main { frame = screen.visibleFrame }
        else if numbers.count == 4 { frame = NSRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]) }
        else { return }
        window.setFrame(frame, display: true)
        #endif
    }

    @MainActor static func scheduleEdit() {
        #if DEBUG
        guard let text = value("MACDOWN2_TEST_EDIT_TEXT") else { return }
        let seconds = value("MACDOWN2_TEST_EDIT_AFTER").flatMap(Double.init) ?? 2
        NSDocumentController.shared.autosavingDelay = 10  // long enough to change the file behind the unsaved edit first
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated {
                guard let doc = NSDocumentController.shared.documents.lazy.compactMap({ $0 as? MarkdownDocument }).first(where: { $0.fileURL != nil }) else { return }
                doc.text += text
                doc.noteUserEdit()
            }
        }
        #endif
    }

    /// A sheet's button cannot be pressed without input: answer it from here instead (the same completion handler runs).
    @MainActor static func answer(_ alert: NSAlert, on window: NSWindow) {
        #if DEBUG
        guard let answer = value("MACDOWN2_TEST_PROMPT_ANSWER") else { return }
        let seconds = value("MACDOWN2_TEST_PROMPT_DELAY").flatMap(Double.init) ?? 4
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            window.endSheet(alert.window, returnCode: answer == "reload" ? .alertSecondButtonReturn : .alertFirstButtonReturn)
        }
        #endif
    }

    @MainActor static func scheduleSettings() {
        #if DEBUG
        if value("MACDOWN2_TEST_STATUS_BAR") == "1" { AppDefaults.store.set(true, forKey: WindowChromeKey.statusBar) }
        if let style = value("MACDOWN2_TEST_TOOLBAR_STYLE").flatMap(ToolbarStyle.init(rawValue:)) { AppDefaults.store.set(style.rawValue, forKey: ToolbarStyle.key) }
        if let seconds = value("MACDOWN2_TEST_TOOLBAR_STYLE_FLIP").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                let current = AppDefaults.store.string(forKey: ToolbarStyle.key).flatMap(ToolbarStyle.init(rawValue:)) ?? .default
                AppDefaults.store.set((current == .minimal ? ToolbarStyle.classic : .minimal).rawValue, forKey: ToolbarStyle.key)
            }
        }
        if value("MACDOWN2_TEST_SCROLL_PAST_END") == "1" { AppDefaults.store.set(true, forKey: EditorViewSettings.Key.scrollPastEnd) }
        if let name = value("MACDOWN2_TEST_EDITOR_THEME") {
            let seconds = value("MACDOWN2_TEST_EDITOR_THEME_AFTER").flatMap(Double.init) ?? 3
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { AppDefaults.store.set(name, forKey: AppearanceKey.editorTheme) }
        }
        guard value("MACDOWN2_TEST_OPEN_SETTINGS") == "1" else { return }
        let reread = value("MACDOWN2_TEST_TOOL_ENV_REREAD") == "1"
        let delay = value("MACDOWN2_TEST_OPEN_SETTINGS_AFTER").flatMap(Double.init) ?? 1.5
        Task {
            try? await Task.sleep(for: .seconds(delay))
            if reread { await AppExtensions.loginShell.reread() }
            NSApp.activate()
            // The "Settings…" item (⌘,) of the app menu, activated directly; no key event is sent.
            if let menu = NSApp.mainMenu?.items.first?.submenu, let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) {
                menu.performActionForItem(at: index)
            }
        }
        #endif
    }

    /// Closing things without a keystroke: the first window's active tab, the first window, then a Dock click, each after its
    /// own delay (seconds). The registry's front window at that moment is the one acted on.
    @MainActor static func scheduleCloses() {
        #if DEBUG
        func after(_ name: String, _ action: @escaping @MainActor () -> Void) {
            // "5" or, to repeat the action, "5,8,11".
            for seconds in (value(name) ?? "").split(separator: ",").compactMap({ Double($0) }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated(action) }
            }
        }
        after("MACDOWN2_TEST_SHOW_OUTLINE") { WorkspaceRegistry.shared.orderedModels().first?.showOutline() }
        after("MACDOWN2_TEST_CLOSE_ACTIVE_TAB") { WorkspaceRegistry.shared.orderedModels().first?.closeActiveTab() }
        after("MACDOWN2_TEST_CLOSE_WINDOW") { WorkspaceRegistry.shared.orderedModels().first?.closeWindow() }
        after("MACDOWN2_TEST_REOPEN") { _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false) }
        after("MACDOWN2_TEST_NEW_WINDOW") { WorkspaceRegistry.shared.requestWindow() }
        after("MACDOWN2_TEST_ACTIVATE") {
            NSApp.activate(ignoringOtherApps: true)  // deprecated, but the plain activate() is refused while another app is in front
            for window in NSApp.windows where window.isVisible && window.canBecomeKey { window.makeKeyAndOrderFront(nil) }
        }
        after("MACDOWN2_TEST_DUMP_MENUS") { dumpMenus() }
        after("MACDOWN2_TEST_SCROLL_TO_END") {
            guard let editor = firstEditor() else { return editorLog.error("scroll hook: no editor") }
            editor.scroll(toLine: Double(editor.string.trimmingCharacters(in: .newlines).split(separator: "\n", omittingEmptySubsequences: false).count - 1))  // the last text line: it clamps to the scroll limit
            editorLog.info("scroll hook: offset now \(editor.enclosingScrollView?.contentView.bounds.origin.y ?? -1, privacy: .public)")
        }
        after("MACDOWN2_TEST_DUMP_EDITOR") { dumpEditor() }
        if let kind = value("MACDOWN2_TEST_PASTE") {
            let seconds = value("MACDOWN2_TEST_PASTE_AFTER").flatMap(Double.init) ?? 3
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { pasteIntoEditor(kind) } }
        }
        after("MACDOWN2_TEST_DUMP_TOOLBAR") { dumpToolbar() }
        after("MACDOWN2_TEST_TAB_RENAME") {
            guard let model = WorkspaceRegistry.shared.orderedModels().first, let url = model.controller.activeURL else { return }
            // A popover closes when the app is not active (a background launch): activate first, as a click would have.
            NSApp.activate(ignoringOtherApps: true)
            model.window?.makeKeyAndOrderFront(nil)
            model.beginTabRename(url)
        }
        if let typed = value("MACDOWN2_TEST_TAB_RENAME_COMMIT") {
            let seconds = (value("MACDOWN2_TEST_TAB_RENAME").flatMap(Double.init) ?? 0) + (value("MACDOWN2_TEST_TAB_RENAME_COMMIT_AFTER").flatMap(Double.init) ?? 4)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                MainActor.assumeIsolated {
                    guard let model = WorkspaceRegistry.shared.orderedModels().first, let draft = model.renameDraft else { return }
                    draft.name = typed
                    if let tags = value("MACDOWN2_TEST_TAB_RENAME_TAGS") { draft.tags = tags.split(separator: ",").map(String.init) }
                    if let folder = value("MACDOWN2_TEST_TAB_RENAME_FOLDER") { draft.folder = URL(filePath: folder, directoryHint: .isDirectory, relativeTo: AppDefaults.isolation?.allowedRoot).absoluteURL }
                    model.saveRename()
                }
            }
        }
        #endif
    }

    #if DEBUG
    @MainActor private static func firstEditor() -> MarkdownTextView? {
        func find(_ view: NSView) -> MarkdownTextView? {
            if let editor = view as? MarkdownTextView { return editor }
            return view.subviews.lazy.compactMap(find).first
        }
        return WorkspaceRegistry.shared.orderedModels().first?.window?.contentView.flatMap(find)
    }

    /// Pastes from a pasteboard of its own, so the real clipboard is never read or written.
    @MainActor private static func pasteIntoEditor(_ kind: String) {
        guard let editor = firstEditor() else { return editorLog.error("paste hook: no editor") }
        let board = NSPasteboard(name: NSPasteboard.Name("macdown2.test.paste.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        if kind == "url" {
            let text = editor.string as NSString
            let word = text.rangeOfCharacter(from: .alphanumerics)
            guard word.location != NSNotFound else { return editorLog.error("paste hook: no word to select") }
            var end = word.location
            while end < text.length, CharacterSet.alphanumerics.contains(Unicode.Scalar(text.character(at: end)) ?? " ") { end += 1 }
            editor.setSelectedRange(NSRange(location: word.location, length: end - word.location))
            board.setString("https://example.com", forType: .string)
        } else {
            let size = NSSize(width: 360, height: 160)
            let image = NSImage(size: size, flipped: false) { rect in
                NSGradient(starting: .systemTeal, ending: .systemIndigo)?.draw(in: rect, angle: 20)
                NSAttributedString(string: "pasted image", attributes: [.font: NSFont.boldSystemFont(ofSize: 28), .foregroundColor: NSColor.white]).draw(at: NSPoint(x: 90, y: 60))
                return true
            }
            board.setData(image.tiffRepresentation, forType: .tiff)
        }
        editorLog.info("paste hook: \(kind, privacy: .public) handled=\(editor.pasteIfSmart(from: board), privacy: .public)")
    }

    @MainActor private static func dumpEditor() {
        guard let editor = firstEditor(), let scrollView = editor.enclosingScrollView else { return editorLog.error("dump: no editor") }
        let clip = scrollView.contentView
        editorLog.info("scroll: offset \(clip.bounds.origin.y, privacy: .public) of text height \(editor.frame.height, privacy: .public), window \(clip.bounds.height, privacy: .public), top line \(editor.topVisibleLine, privacy: .public), past end \(editor.viewSettings.scrollsPastEnd, privacy: .public)")
        editorLog.info("theme: \(editor.theme.name, privacy: .public) background \(String(describing: editor.theme.background), privacy: .public)")
        let store = UserThemeFolder.store
        editorLog.info("themes: \(store.all.map(\.name).joined(separator: " | "), privacy: .public); folder \(store.directory.path, privacy: .public)")
        for skipped in store.skipped { editorLog.info("skipped theme file: \(skipped.file, privacy: .public): \(skipped.reason, privacy: .public)") }
    }

    /// Logs the language the app runs in and the title of every main-menu item ("File > Open Recent > Clear Menu").
    @MainActor private static func dumpToolbar() {
        for window in NSApp.windows {
            guard let toolbar = window.toolbar else { continue }
            toolbarLog.info("toolbar: style \(window.toolbarStyle.rawValue, privacy: .public), \(toolbar.items.count, privacy: .public) items, title bar height \(window.frame.height - window.contentLayoutRect.height, privacy: .public)")
            for item in toolbar.items {
                let menu = item.menuFormRepresentation?.title ?? "-"
                let rep = item.menuFormRepresentation.map { "\(type(of: $0)) action=\($0.action.map(NSStringFromSelector) ?? "nil") target=\($0.target.map { String(describing: type(of: $0)) } ?? "nil") image=\($0.image != nil) enabled=\($0.isEnabled)" } ?? "-"
                toolbarLog.info("  rep \(rep, privacy: .public)")
                let submenu = item.menuFormRepresentation?.submenu?.items.map(\.title).joined(separator: "|") ?? "-"
                toolbarLog.info("item \(item.itemIdentifier.rawValue, privacy: .public) label=\(item.label, privacy: .public) priority=\(item.visibilityPriority.rawValue, privacy: .public) view=\(item.view.map { String(describing: type(of: $0)) } ?? "-", privacy: .public) width=\(item.view?.frame.width ?? 0, privacy: .public) menu=\(menu, privacy: .public) sub=\(submenu, privacy: .public)")
            }
        }
    }

    @MainActor private static func dumpMenus() {
        menuLog.info("language: \(Bundle.main.preferredLocalizations.joined(separator: ","), privacy: .public); AppleLanguages: \(UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.joined(separator: ",") ?? "-", privacy: .public)")
        func walk(_ menu: NSMenu, _ path: String) {
            menu.update()  // SwiftUI fills a menu when AppKit asks (menuNeedsUpdate), as it does just before the menu opens
            for item in menu.items where !item.isSeparatorItem {
                let title = item.title.isEmpty ? (item.submenu?.title ?? "") : item.title
                let name = (path.isEmpty ? title : "\(path) > \(title)") + (item.state == .on ? " [on]" : "")
                menuLog.info("menu: \(name, privacy: .public)")
                if let submenu = item.submenu { walk(submenu, name) }
            }
        }
        if let main = NSApp.mainMenu { walk(main, "") }
    }
    #endif

    @MainActor static func scheduleTermination() {
        #if DEBUG
        guard let raw = value("MACDOWN2_TEST_TERMINATE_AFTER"), let seconds = Double(raw) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
        #endif
    }

    /// Drives PLAN I-5 without any input event. Once the preview has rendered and `MACDOWN2_TEST_TOGGLE_TASK_DELAY` seconds
    /// (default 4: time for a "before" screenshot) have passed, the page clicks the checkbox of the item on source line
    /// `MACDOWN2_TEST_TOGGLE_TASK_LINE` through its own JavaScript, so the real page -> token and version check -> editor path
    /// runs. `MACDOWN2_TEST_TOGGLE_TASK_LAYOUT=previewOnly` switches to that layout first. `MACDOWN2_TEST_TOGGLE_TASK_UNDO=1`
    /// then makes the preview's web view the first responder, as after a real click on it, and sends `undo:` to the first
    /// responder in its chain that answers it (what Cmd-Z reaches). Everything found is logged:
    /// `log show --predicate 'category == "task-toggle-hook"'`.
    @MainActor static func toggleTaskThroughPage(model: WindowModel, preview: PreviewModel, editor: EditorHandle, document: MarkdownDocument) async {
        #if DEBUG
        guard !toggled, let raw = value("MACDOWN2_TEST_TOGGLE_TASK_LINE"), let line = Int(raw) else { return }
        toggled = true
        for _ in 0..<100 where preview.metadata == nil { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .seconds(Double(value("MACDOWN2_TEST_TOGGLE_TASK_DELAY") ?? "") ?? 4))
        if value("MACDOWN2_TEST_TOGGLE_TASK_LAYOUT") == "previewOnly" {
            model.userSetLayout(SplitLayout(mode: .previewOnly))
            editor.resignFocus()
            try? await Task.sleep(for: .seconds(4))  // room for a screenshot of the layout before the click
        }
        hookLog.info("editor shown: \(model.layout.showsEditor, privacy: .public); text view alive: \(editor.textView != nil, privacy: .public); edited before: \(document.isDocumentEdited, privacy: .public)")
        let found = try? await preview.page.callJavaScript(
            "const box = [...document.querySelectorAll('input.task-list-item-checkbox')].find((b) => b.closest('[data-line]')?.dataset.line === String(line)); if (!box) return false; box.click(); return true",
            arguments: ["line": line])
        hookLog.info("page clicked line \(line): \(String(describing: found), privacy: .public)")
        try? await Task.sleep(for: .seconds(1.5))
        hookLog.info("after toggle: edited=\(document.isDocumentEdited, privacy: .public) canUndo=\(document.undoManager?.canUndo ?? false, privacy: .public) action=\(document.undoManager?.undoActionName ?? "-", privacy: .public) line=\(lineText(document.text, line), privacy: .public) editorLine=\(lineText(editor.textView?.string ?? "", line), privacy: .public)")
        if value("MACDOWN2_TEST_TOGGLE_TASK_SAVE") == "afterToggle" { await autosave(document) }

        guard value("MACDOWN2_TEST_TOGGLE_TASK_UNDO") == "1" else { return }
        // The isolated instance is not frontmost (no key window), so the menu cannot be driven; the first responder is set
        // where a real click would leave it and the responder chain is walked by hand: the first one that answers `undo:` is
        // what Cmd-Z / Edit > Undo would reach, and it gets the action.
        guard let window = editor.textView?.window, let web = webView(in: window) else { return }
        hookLog.info("first responder set to the web view: \(window.makeFirstResponder(web), privacy: .public)")
        var chain: [String] = []
        var responder: NSResponder? = window.firstResponder
        var handler: NSResponder?
        while let current = responder {
            let answers = current.responds(to: Selector(("undo:")))
            chain.append("\(type(of: current))\(answers ? "(undo:)" : "")")
            if answers, handler == nil { handler = current }
            responder = current.nextResponder
        }
        hookLog.info("responder chain: \(chain.joined(separator: " > "), privacy: .public); window.undoManager is the document's: \(window.undoManager === document.undoManager, privacy: .public)")
        handler?.perform(Selector(("undo:")), with: nil)
        try? await Task.sleep(for: .seconds(1))
        hookLog.info("after undo: line=\(lineText(document.text, line), privacy: .public) editorLine=\(lineText(editor.textView?.string ?? "", line), privacy: .public) edited=\(document.isDocumentEdited, privacy: .public) canUndo=\(document.undoManager?.canUndo ?? false, privacy: .public) canRedo=\(document.undoManager?.canRedo ?? false, privacy: .public)")
        if value("MACDOWN2_TEST_TOGGLE_TASK_SAVE") == "afterUndo" { await autosave(document) }
        #endif
    }

    /// Drives the tab-switch / second-window undo scenario without input, on the first two tabs (a.md, b.md) of the first window,
    /// `MACDOWN2_TEST_TAB_UNDO=<secs>` apart: A is shown and "X" typed into the editor through its editing path; the window moves to
    /// B; a second window opens A; A's undo manager undoes (what Edit > Undo in window 2 does) and redoes. The text of both
    /// documents and of every editor in the app is logged after each step (`log show --predicate 'category == "tab-undo-hook"'`),
    /// so screenshots taken between the steps can be matched to them.
    @MainActor static func tabSwitchUndo(model: WindowModel, editor: EditorHandle) async {
        #if DEBUG
        guard !tabUndoRan, let raw = value("MACDOWN2_TEST_TAB_UNDO"), let step = Double(raw) else { return }
        tabUndoRan = true
        for _ in 0..<100 where model.controller.session.tabs.count < 2 || editor.textView == nil { try? await Task.sleep(for: .milliseconds(100)) }
        let urls = model.controller.session.tabs.map(\.url)
        guard urls.count >= 2, let a = WorkspaceRegistry.shared.document(for: urls[0]), let b = WorkspaceRegistry.shared.document(for: urls[1]),
              let first = editor.textView else { return tabLog.error("needs two open files and an editor") }
        func snapshot(_ label: String) {
            let editors = NSApp.windows.compactMap { $0.contentView.flatMap(markdownEditor) }.map { "[\($0.string.debugDescription)]" }
            tabLog.info("\(label, privacy: .public): A=\(a.text.debugDescription, privacy: .public) B=\(b.text.debugDescription, privacy: .public) editors=\(editors.joined(separator: " "), privacy: .public) canUndoA=\(a.undoManager?.canUndo ?? false, privacy: .public)")
        }
        func pause() async { try? await Task.sleep(for: .seconds(step)) }

        model.controller.activate(urls[0])
        await pause()
        snapshot("1 window 1 shows A")
        first.setSelectedRange(NSRange(location: (first.string as NSString).length, length: 0))
        first.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
        await pause()
        snapshot("2 typed X in A")
        model.controller.activate(urls[1])
        await pause()
        snapshot("3 window 1 shows B")
        WorkspaceRegistry.shared.requestWindow()
        for _ in 0..<50 where WorkspaceRegistry.shared.orderedModels().count < 2 { try? await Task.sleep(for: .milliseconds(100)) }
        guard let other = WorkspaceRegistry.shared.orderedModels().first(where: { $0 !== model }) else { return tabLog.error("no second window") }
        try? other.controller.open(urls[0], as: .pinned)
        await pause()
        snapshot("4 window 2 opened A")
        a.undoManager?.undo()
        await pause()
        snapshot("5 undo (from window 2)")
        a.undoManager?.redo()
        await pause()
        snapshot("6 redo")
        a.undoManager?.undo()
        model.controller.activate(urls[0])
        await pause()
        snapshot("7 undo again, window 1 back on A")
        #endif
    }

    /// Drives preview editing and two-way selection without input events (see the list at the top): the page's own edit mode, then the
    /// preview's web view's text input methods called directly, in this process, as AppKit calls them for a key press or an input
    /// method; nothing reaches the desktop.
    @MainActor static func previewEditing(model: WindowModel, preview: PreviewModel, editor: EditorHandle, document: MarkdownDocument) async {
        #if DEBUG
        guard !previewEditRan, value("MACDOWN2_TEST_PREVIEW_EDIT") != nil || value("MACDOWN2_TEST_PEER_SELECT") != nil || value("MACDOWN2_TEST_FOLLOW_CARET") != nil else { return }
        previewEditRan = true
        for _ in 0..<100 where preview.metadata == nil { try? await Task.sleep(for: .milliseconds(100)) }
        let step = Double(value("MACDOWN2_TEST_PREVIEW_DELAY") ?? "") ?? 3
        func pause(_ seconds: Double = step) async { try? await Task.sleep(for: .seconds(seconds)) }
        func state(_ label: String) {
            editLog.info("\(label, privacy: .public): text=\(document.text.debugDescription, privacy: .public) editor=\((editor.textView?.string ?? "-").debugDescription, privacy: .public) canUndo=\(document.undoManager?.canUndo ?? false, privacy: .public) undo=\(document.undoManager?.undoActionName ?? "-", privacy: .public) canRedo=\(document.undoManager?.canRedo ?? false, privacy: .public)")
        }
        await pause()
        guard let window = editor.textView?.window, let web = webView(in: window) else { return editLog.error("no web view") }
        state("start")

        if let raw = value("MACDOWN2_TEST_PEER_SELECT") {
            let n = raw.split(separator: ",").compactMap { Int($0) }
            if n.count == 2, let textView = editor.textView {
                window.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: n[0], length: n[1] - n[0]))
                await pause(1)
                let shown = try? await preview.page.callJavaScript("return [...(CSS.highlights.get('md2-peer') ?? [])].map((r) => JSON.stringify(r.toString())).join(' + ')")
                editLog.info("editor selected \(n[0], privacy: .public)..<\(n[1], privacy: .public): page highlights \(String(describing: shown), privacy: .public)")
                await pause()
            }
            if let page = value("MACDOWN2_TEST_PAGE_SELECT")?.split(separator: ":").compactMap({ Int($0) }), page.count == 3 {
                window.makeFirstResponder(web)
                let ok = try? await preview.page.callJavaScript(
                    "const e = [...document.querySelectorAll('#doc [data-line]')].find((x) => x.dataset.line === String(line)); const w = e && document.createTreeWalker(e, NodeFilter.SHOW_TEXT); const t = w && w.nextNode(); if (!t) return false; getSelection().setBaseAndExtent(t, a, t, b); return true",
                    arguments: ["line": page[0], "a": page[1], "b": page[2]])
                await pause(1)
                editLog.info("page selected (\(String(describing: ok), privacy: .public)): editor shows \(editor.textView?.peerHighlightRanges.description ?? "-", privacy: .public)")
                await pause()
            }
        }

        if let target = value("MACDOWN2_TEST_FOLLOW_CARET").flatMap(Int.init), let key = document.fileURL?.fileKey {
            // "Preview follows the caret" on; the preview has the focus, not the editor; a search result is revealed in the editor
            // without focusing it (the workspace search's path): the preview must follow.
            AppDefaults.store.set(true, forKey: ScrollSyncPreferences.followCaretKey)
            window.makeFirstResponder(web)
            await pause(1)
            let before = try? await preview.page.callJavaScript("return MacDown2Preview.visibleTopLine()")
            editor.reveal(key: key, line: target, columns: 0..<1, focus: false)
            await pause(1)
            let after = try? await preview.page.callJavaScript("return MacDown2Preview.visibleTopLine()")
            editLog.info("follow caret: revealed line \(target, privacy: .public) with the editor not focused (first responder \(String(describing: type(of: window.firstResponder)), privacy: .public)): preview top line \(String(describing: before), privacy: .public) -> \(String(describing: after), privacy: .public)")
            await pause()
        }

        guard let line = value("MACDOWN2_TEST_PREVIEW_EDIT").flatMap(Int.init) else { return }
        // the end of the line's text: the caret goes after its last character
        let lines = document.text.split(separator: "\n", omittingEmptySubsequences: false)
        let end = lines.prefix(line + 1).reduce(0) { $0 + $1.utf16.count + 1 } - 1
        let entered = try? await preview.page.callJavaScript("return MacDown2Preview.editingForTests.enterAt(line, at)", arguments: ["line": line, "at": end])
        editLog.info("edit mode on line \(line, privacy: .public) at \(end, privacy: .public): \(String(describing: entered), privacy: .public); web view first responder: \(window.makeFirstResponder(web), privacy: .public)")
        await pause(1)

        let insertText = NSSelectorFromString("insertText:replacementRange:")
        let setMarked = NSSelectorFromString("setMarkedText:selectedRange:replacementRange:")
        let command = NSSelectorFromString("doCommandBySelector:")
        let none = NSRange(location: NSNotFound, length: 0)
        func typeText(_ s: String) {
            guard web.responds(to: insertText) else { return editLog.error("web view has no insertText:replacementRange:") }
            typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, NSRange) -> Void
            unsafeBitCast(web.method(for: insertText), to: Fn.self)(web, insertText, s as NSString, none)
        }
        func mark(_ s: String) {
            guard web.responds(to: setMarked) else { return editLog.error("web view has no setMarkedText:selectedRange:replacementRange:") }
            typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, NSRange, NSRange) -> Void
            unsafeBitCast(web.method(for: setMarked), to: Fn.self)(web, setMarked, s as NSString, NSRange(location: (s as NSString).length, length: 0), none)
        }
        // The page's own record of the input events WebKit sent (`editingForTests.events`), logged after each step.
        _ = try? await preview.page.callJavaScript("MacDown2Preview.editingForTests.configure({ trace: true })")
        func events(_ label: String) async {
            let seen = try? await preview.page.callJavaScript("return JSON.stringify([MacDown2Preview.editingForTests.events(), MacDown2Preview.editingForTests.state()])")
            let page = try? await preview.page.callJavaScript("return [...document.querySelectorAll('#doc > *')].map((e) => e.textContent).join('|')")
            editLog.info("\(label, privacy: .public): page events \(String(describing: seen), privacy: .public); page text \(String(describing: page).debugDescription, privacy: .public)")
        }
        if value("MACDOWN2_TEST_PREVIEW_AUTOCORRECT") == "1", let textView = editor.textView {
            // The editor's own automatic changes on (this launch's text view only): what the preview types must still reach the source as typed.
            textView.isContinuousSpellCheckingEnabled = true
            textView.isAutomaticSpellingCorrectionEnabled = true
            textView.isAutomaticTextReplacementEnabled = true
            textView.isAutomaticQuoteSubstitutionEnabled = true
            textView.isAutomaticDashSubstitutionEnabled = true
            editLog.info("editor: spelling correction, text replacement, smart quotes and dashes on")
        }
        if let text = value("MACDOWN2_TEST_PREVIEW_TYPE") {
            for c in text { typeText(String(c)); try? await Task.sleep(for: .milliseconds(80)) }
            await pause(1)
            state("typed \(text)")
            await events("typed")
            await pause()
        }
        if let raw = value("MACDOWN2_TEST_PREVIEW_IME") {
            let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
            for s in parts.first?.split(separator: ",") ?? [] { mark(String(s)); try? await Task.sleep(for: .milliseconds(150)) }
            await pause(1)  // the composition on screen (underlined), for a photo
            if parts.count == 2 { typeText(parts[1]) }
            await pause(1)
            state("composed \(raw)")
            await events("composed")
            await pause()
        }
        if let raw = value("MACDOWN2_TEST_PREVIEW_IME_CANCEL") {
            // An input method composes; meanwhile the text changes elsewhere (typed in the editor at the end); the composition is
            // cancelled (Escape: the input method clears its marked text). The page must show the change at once.
            for s in raw.split(separator: ",") { mark(String(s)); try? await Task.sleep(for: .milliseconds(150)) }
            if let textView = editor.textView {
                textView.insertText(" (changed elsewhere)", replacementRange: NSRange(location: (textView.string as NSString).length - 1, length: 0))
            }
            await pause(1)
            await events("composing, the text changed elsewhere")
            mark("")
            let unmark = NSSelectorFromString("unmarkText")
            if web.responds(to: unmark) { web.perform(unmark) }
            await pause(1)
            state("composition cancelled")
            await events("composition cancelled")
            await pause()
        }
        if let raw = value("MACDOWN2_TEST_PREVIEW_IME_OVER") {
            // `<a>:<b>|<z,zh>|<commit>`: characters a ..< b of the edited block's first text node selected, then composed over.
            let parts = raw.split(separator: "|").map(String.init)
            let ends = parts.first?.split(separator: ":").compactMap { Int($0) } ?? []
            if parts.count == 3, ends.count == 2 {
                let selected = try? await preview.page.callJavaScript(
                    "const e = document.querySelector('#doc [contenteditable]'); const w = e && document.createTreeWalker(e, NodeFilter.SHOW_TEXT); const t = w && w.nextNode(); if (!t) return null; getSelection().setBaseAndExtent(t, a, t, b); return getSelection().toString()",
                    arguments: ["a": ends[0], "b": ends[1]])
                await pause(1)
                for s in parts[1].split(separator: ",") { mark(String(s)); try? await Task.sleep(for: .milliseconds(150)) }
                await pause(1)
                typeText(parts[2])
                await pause(1)
                state("composed over \(String(describing: selected))")
                await events("composed over a selection")
                await pause()
            }
        }
        if let n = value("MACDOWN2_TEST_PREVIEW_BACKSPACE").flatMap(Int.init), web.responds(to: command) {
            typealias Fn = @convention(c) (AnyObject, Selector, Selector) -> Void
            for _ in 0..<n { unsafeBitCast(web.method(for: command), to: Fn.self)(web, command, #selector(NSResponder.deleteBackward(_:))); try? await Task.sleep(for: .milliseconds(80)) }
            await pause(1)
            state("\(n) backspace(s)")
            await pause()
        }
        guard value("MACDOWN2_TEST_PREVIEW_UNDO") == "1" else { return }
        // What Cmd-Z reaches with the preview focused: the first responder in the chain that answers undo:.
        func send(_ action: String) {
            var chain: [String] = []
            var responder: NSResponder? = window.firstResponder
            var handler: NSResponder?
            while let current = responder {
                let answers = current.responds(to: Selector((action)))
                chain.append("\(type(of: current))\(answers ? "(\(action))" : "")")
                if answers, handler == nil { handler = current }
                responder = current.nextResponder
            }
            editLog.info("\(action, privacy: .public) responder chain: \(chain.joined(separator: " > "), privacy: .public)")
            handler?.perform(Selector((action)), with: nil)
        }
        window.makeFirstResponder(web)
        send("undo:")
        await pause(1)
        state("after undo")
        await pause()
        send("redo:")
        await pause(1)
        state("after redo")
        #endif
    }

    #if DEBUG
    private static func markdownEditor(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView, text.isEditable { return text }
        return view.subviews.lazy.compactMap(markdownEditor).first
    }

    /// Writes the document to its (temp-dir copy) file now, as the system's autosave would later, so the bytes can be compared.
    @MainActor private static func autosave(_ document: MarkdownDocument) async {
        let error: Error? = await withCheckedContinuation { continuation in
            document.autosave(withImplicitCancellability: false) { continuation.resume(returning: $0) }
        }
        hookLog.info("saved: \(error.map { String(describing: $0) } ?? "ok", privacy: .public)")
    }

    private static func lineText(_ text: String, _ line: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return line < lines.count ? String(lines[line]) : "(none)"
    }

    private static func webView(in window: NSWindow?) -> WKWebView? {
        func find(_ view: NSView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap(find).first
        }
        return window?.contentView.flatMap(find)
    }
    #endif
}
