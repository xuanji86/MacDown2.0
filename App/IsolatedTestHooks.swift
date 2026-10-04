import AppKit
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
///   MACDOWN2_TEST_DUMP_MENUS=<secs>       after this many seconds, the app's language and every title in the main menu bar go to the
///                                         log (menus cannot be photographed window-only): category "menu-dump"
///                                         (the language itself is chosen with MACDOWN2_LANGUAGE in `Scripts/run-isolated.sh`)
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
    private static let tabLog = Logger(subsystem: "io.github.xuanji86.MacDown2", category: "tab-undo-hook")
    private static let hookLog = Logger(subsystem: "io.github.xuanji86.MacDown2", category: "task-toggle-hook")
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
            guard let seconds = value(name).flatMap(Double.init) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated(action) }
        }
        after("MACDOWN2_TEST_SHOW_OUTLINE") { WorkspaceRegistry.shared.orderedModels().first?.showOutline() }
        after("MACDOWN2_TEST_CLOSE_ACTIVE_TAB") { WorkspaceRegistry.shared.orderedModels().first?.closeActiveTab() }
        after("MACDOWN2_TEST_CLOSE_WINDOW") { WorkspaceRegistry.shared.orderedModels().first?.closeWindow() }
        after("MACDOWN2_TEST_REOPEN") { _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false) }
        after("MACDOWN2_TEST_DUMP_MENUS") { dumpMenus() }
        #endif
    }

    #if DEBUG
    /// Logs the language the app runs in and the title of every main-menu item ("File > Open Recent > Clear Menu").
    @MainActor private static func dumpMenus() {
        menuLog.info("language: \(Bundle.main.preferredLocalizations.joined(separator: ","), privacy: .public); AppleLanguages: \(UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.joined(separator: ",") ?? "-", privacy: .public)")
        func walk(_ menu: NSMenu, _ path: String) {
            for item in menu.items where !item.isSeparatorItem {
                let title = item.title.isEmpty ? (item.submenu?.title ?? "") : item.title
                let name = path.isEmpty ? title : "\(path) > \(title)"
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
        WorkspaceRegistry.shared.openWindow?()
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
