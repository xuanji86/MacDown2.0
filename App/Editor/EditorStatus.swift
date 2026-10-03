import EditorKit
import Foundation
import MarkdownCore
import Observation

/// Caret position and selection counts for the status bar and the outline's current-section highlight. Selection changes
/// arrive on every keystroke and every drag step, so the numbers are recomputed at most once per `interval`.
@MainActor @Observable
final class EditorStatus {
    /// 0-based; the views add one.
    private(set) var line = 0
    private(set) var column = 0
    /// Counts of the selected text, nil without a selection.
    private(set) var selection: TextStats?

    static let interval = Duration.milliseconds(60)
    @ObservationIgnored private var pending: Task<Void, Never>?

    func selectionChanged(in textView: MarkdownTextView) {
        guard pending == nil else { return }  // the scheduled refresh reads the latest selection
        pending = Task { [weak self, weak textView] in
            try? await Task.sleep(for: Self.interval)
            guard let self else { return }
            pending = nil
            if let textView { refresh(from: textView) }
        }
    }

    private func refresh(from textView: MarkdownTextView) {
        let (line, column) = (textView.caretLine, textView.caretColumn)
        if line != self.line { self.line = line }
        if column != self.column { self.column = column }
        let range = textView.selectedRange()
        // lazy: counts the whole selection on the main thread (regex + grapheme walk; select-all on a 1 MB file is a
        // one-off hitch), move to a background task if that shows up.
        let stats = range.length > 0 ? TextStats(counting: (textView.string as NSString).substring(with: range)) : nil
        if stats != selection { selection = stats }
    }
}
