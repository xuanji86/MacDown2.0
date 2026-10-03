import EditorKit
import Foundation

/// UserDefaults keys; a Settings page binds the same ones with `@AppStorage`.
enum ScrollSyncPreferences {
    static let syncKey = "scrollSync"  // default on
    static let followCaretKey = "previewFollowsCaret"  // default off (PLAN Q4)
}

/// Keeps editor and preview at the same source line. Both panes already speak 0-based fractional source lines (the
/// page maps line <-> y over its block table, the editor over its layout fragments), so this only relays lines, with
/// a ping-pong gate and one delivery per frame.
@MainActor
final class ScrollSyncController {
    var isEnabled = true
    var followsCaret = false

    private weak var editor: MarkdownTextView?
    private var preview: PreviewModel?
    private var gate = ScrollSyncGate()
    private var pendingEditor: Double?
    private var pendingPreview: Double?
    private var pendingPreviewIsCaret = false  // caret following works with sync switched off
    private var frame: Task<Void, Never>?
    private var lastCaretLine = -1
    private static let caretLeadLines = 3.0  // keeps a few lines of context above the caret line in the preview

    func attach(editor: MarkdownTextView) {
        self.editor = editor
        editor.onVisibleLineChange = { [weak self] line in
            MainActor.assumeIsolated { self?.report(.editor, line: line) }
        }
    }

    func attach(preview: PreviewModel) {
        self.preview = preview
        preview.onVisibleLineChange = { [weak self] line in
            MainActor.assumeIsolated { self?.report(.preview, line: line) }
        }
    }

    /// Selection moved in the editor; scrolls the preview to the caret line when the caret changed lines.
    func caretMoved(in textView: MarkdownTextView) {
        guard followsCaret else { return }
        let line = textView.caretLine
        guard line != lastCaretLine else { return }
        lastCaretLine = line
        guard gate.accept(.editor, at: ProcessInfo.processInfo.systemUptime) else { return }
        pendingPreview = max(0, Double(line) - Self.caretLeadLines)
        pendingPreviewIsCaret = true
        scheduleFrame()
    }

    private func report(_ side: ScrollSyncGate.Side, line: Double) {
        guard isEnabled, gate.accept(side, at: ProcessInfo.processInfo.systemUptime) else { return }
        if side == .editor { pendingPreview = line; pendingPreviewIsCaret = false } else { pendingEditor = line }
        scheduleFrame()
    }

    /// Latest line wins; at most one delivery per ~frame however fast the reports come in.
    private func scheduleFrame() {
        guard frame == nil else { return }
        frame = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled, let self else { return }
            frame = nil
            // Checked at delivery, not when queued: turning sync off stops scrolling at once (MacDown #441).
            if let line = pendingPreview {
                pendingPreview = nil
                if isEnabled || pendingPreviewIsCaret { preview?.scroll(toLine: line) }
            }
            if let line = pendingEditor {
                pendingEditor = nil
                if isEnabled { editor?.scroll(toLine: line) }
            }
        }
    }

    deinit { frame?.cancel() }
}
