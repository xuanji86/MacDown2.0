import AppKit
import Foundation

/// Debug-only drivers for `Scripts/run-isolated.sh` launches, so behaviour that normally needs a keystroke can be checked
/// without sending the desktop any input: both are inert unless the launch is isolated, and Release builds have neither.
///
///   MACDOWN2_TEST_UNTITLED_TEXT=<text>    the first untitled document starts with this text, as if typed
///   MACDOWN2_TEST_TERMINATE_AFTER=<secs>  quit through the normal Cmd-Q path (the unsaved-documents review) after a delay
///   MACDOWN2_TEST_WINDOW_FRAME=<"x y w h" | max>  every workspace window takes this frame in screen points (bottom-left
///                                         origin), or the main screen's visible frame ("max": what zoom gives), once
enum IsolatedTestHooks {
    #if DEBUG
    private static func value(_ name: String) -> String? {
        guard AppDefaults.isIsolated else { return nil }
        return ProcessInfo.processInfo.environment[name]
    }
    private nonisolated(unsafe) static var typed = false
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

    @MainActor static func scheduleTermination() {
        #if DEBUG
        guard let raw = value("MACDOWN2_TEST_TERMINATE_AFTER"), let seconds = Double(raw) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
        #endif
    }
}
