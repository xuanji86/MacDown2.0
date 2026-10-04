import AppKit
import Foundation
import WorkspaceKit

/// Debug-only drivers for `Scripts/run-isolated.sh` launches, so behaviour that normally needs a keystroke can be checked
/// without sending the desktop any input: both are inert unless the launch is isolated, and Release builds have neither.
///
///   MACDOWN2_TEST_UNTITLED_TEXT=<text>    the first untitled document starts with this text, as if typed
///   MACDOWN2_TEST_TERMINATE_AFTER=<secs>  quit through the normal Cmd-Q path (the unsaved-documents review) after a delay
///   MACDOWN2_TEST_OPEN_SETTINGS=1         open the Settings window (as ⌘, does) once the app is up
///   MACDOWN2_TEST_TOOL_ENV_REREAD=1       also run the Settings "重新抓取" (re-read login-shell environment) action first
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
enum IsolatedTestHooks {
    #if DEBUG
    private static func value(_ name: String) -> String? {
        guard AppDefaults.isIsolated else { return nil }
        return ProcessInfo.processInfo.environment[name]
    }
    private nonisolated(unsafe) static var typed = false
    private nonisolated(unsafe) static var searched = false
    private nonisolated(unsafe) static var framed = Set<Int>()
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
        guard value("MACDOWN2_TEST_OPEN_SETTINGS") == "1" else { return }
        let reread = value("MACDOWN2_TEST_TOOL_ENV_REREAD") == "1"
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if reread { await AppExtensions.loginShell.reread() }
            NSApp.activate()
            // The "Settings…" item (⌘,) of the app menu, activated directly; no key event is sent.
            if let menu = NSApp.mainMenu?.items.first?.submenu, let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) {
                menu.performActionForItem(at: index)
            }
        }
        #endif
    }

    @MainActor static func scheduleTermination() {
        #if DEBUG
        guard let raw = value("MACDOWN2_TEST_TERMINATE_AFTER"), let seconds = Double(raw) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
        #endif
    }
}
