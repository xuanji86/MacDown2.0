import AppKit
import EditorKit
import Foundation
import Observation

enum FindMode: String, CaseIterable, Identifiable {
    case find = "Find"
    case replace = "Replace"

    var id: String { rawValue }
}

@MainActor @Observable
final class FindModel {
    var isPresented: Bool = false {
        didSet {
            if isPresented != oldValue {
                if isPresented {
                    updateMatches()
                } else {
                    clearHighlights()
                }
            }
        }
    }

    var mode: FindMode = .find {
        didSet {
            if mode != oldValue {
                statusMessage = nil
            }
        }
    }

    var findText: String = "" {
        didSet {
            if findText != oldValue {
                statusMessage = nil
                updateMatches(preserveActive: false)
            }
        }
    }

    var replaceText: String = ""

    var isCaseSensitive: Bool = false {
        didSet {
            if isCaseSensitive != oldValue {
                statusMessage = nil
                updateMatches(preserveActive: true)
            }
        }
    }

    var isRegex: Bool = false {
        didSet {
            if isRegex != oldValue {
                statusMessage = nil
                updateMatches(preserveActive: true)
            }
        }
    }

    private(set) var matches: [NSRange] = []
    private(set) var currentMatchIndex: Int = 0
    private(set) var hasInvalidRegex: Bool = false
    private(set) var statusMessage: String?

    private(set) var focusTick: Int = 0
    private(set) var focusReplaceTick: Int = 0

    weak var editor: EditorHandle?

    init() {}

    /// Binds `FindModel` to the editor handle of the active document.
    func bind(editor: EditorHandle) {
        self.editor = editor
        editor.onTextChange = { [weak self] in
            self?.editorTextDidChange()
        }
        editor.textView?.onCancelOperation = { [weak self] in
            guard let self, self.isPresented else { return false }
            self.dismiss()
            return true
        }
    }

    func present(replace: Bool = false) {
        if replace {
            mode = .replace
        }
        if !isPresented {
            if findText.isEmpty, let selected = editor?.selectedString, !selected.isEmpty, !selected.contains("\n") {
                findText = selected
            }
            isPresented = true
        }
        focusTick += 1
        updateMatches(preserveActive: true)
    }

    func dismiss() {
        isPresented = false
        clearHighlights()
        editor?.makeFirstResponder()
    }

    func focusReplace() {
        focusReplaceTick += 1
    }

    func useSelectionForFind() {
        if let selected = editor?.selectedString, !selected.isEmpty {
            findText = selected
        }
        present(replace: false)
    }

    func editorTextDidChange() {
        guard isPresented else { return }
        updateMatches(preserveActive: true)
    }

    func updateMatches(preserveActive: Bool = false) {
        guard let text = editor?.textString, !findText.isEmpty else {
            matches = []
            currentMatchIndex = 0
            hasInvalidRegex = false
            clearHighlights()
            return
        }

        let (found, invalidRegex) = FindEngine.findMatches(
            in: text,
            query: findText,
            isRegex: isRegex,
            isCaseSensitive: isCaseSensitive
        )
        hasInvalidRegex = invalidRegex
        matches = found

        if found.isEmpty {
            currentMatchIndex = 0
            clearHighlights()
            return
        }

        let caretLocation = editor?.selectedRange?.location ?? 0
        if preserveActive {
            currentMatchIndex = FindEngine.nextIndex(in: found, currentLocation: caretLocation, currentIndex: -1)
        } else {
            currentMatchIndex = FindEngine.nextIndex(in: found, currentLocation: caretLocation, currentIndex: -1)
            let target = found[currentMatchIndex]
            editor?.selectAndScrollTo(range: target)
        }

        if isPresented {
            editor?.showFindHighlights(found, activeIndex: currentMatchIndex)
        }
    }

    func findNext() {
        if !isPresented {
            present(replace: false)
            return
        }
        guard !matches.isEmpty else { return }
        let caretLocation = editor?.selectedRange?.location ?? 0
        currentMatchIndex = FindEngine.nextIndex(in: matches, currentLocation: caretLocation, currentIndex: currentMatchIndex)
        let target = matches[currentMatchIndex]
        editor?.selectAndScrollTo(range: target)
        editor?.showFindHighlights(matches, activeIndex: currentMatchIndex)
    }

    func findPrevious() {
        if !isPresented {
            present(replace: false)
            return
        }
        guard !matches.isEmpty else { return }
        let caretLocation = editor?.selectedRange?.location ?? 0
        currentMatchIndex = FindEngine.previousIndex(in: matches, currentLocation: caretLocation, currentIndex: currentMatchIndex)
        let target = matches[currentMatchIndex]
        editor?.selectAndScrollTo(range: target)
        editor?.showFindHighlights(matches, activeIndex: currentMatchIndex)
    }

    func replaceCurrent() {
        guard let editor, editor.isEditable, !matches.isEmpty, currentMatchIndex < matches.count,
              let text = editor.textString else { return }
        let matchRange = matches[currentMatchIndex]
        let replacement = FindEngine.replacementString(
            for: matchRange, in: text, query: findText, replaceText: replaceText,
            isRegex: isRegex, isCaseSensitive: isCaseSensitive
        )
        guard let newRange = editor.replaceMatch(range: matchRange, with: replacement) else { return }

        let (found, _) = FindEngine.findMatches(
            in: editor.textString ?? "",
            query: findText,
            isRegex: isRegex,
            isCaseSensitive: isCaseSensitive
        )
        matches = found
        if found.isEmpty {
            currentMatchIndex = 0
            clearHighlights()
        } else {
            currentMatchIndex = FindEngine.nextIndex(in: found, currentLocation: NSMaxRange(newRange), currentIndex: -1)
            let nextTarget = found[currentMatchIndex]
            editor.selectAndScrollTo(range: nextTarget)
            editor.showFindHighlights(found, activeIndex: currentMatchIndex)
        }
    }

    func replaceAll() {
        guard let editor, editor.isEditable, !matches.isEmpty, let text = editor.textString else { return }
        var replacements: [(range: NSRange, string: String)] = []
        for r in matches {
            let repl = FindEngine.replacementString(
                for: r, in: text, query: findText, replaceText: replaceText,
                isRegex: isRegex, isCaseSensitive: isCaseSensitive
            )
            replacements.append((r, repl))
        }

        let count = editor.replaceMatches(replacements)
        statusMessage = count == 1 ? String(localized: "1 replaced") : String(localized: "\(count) replaced")

        updateMatches(preserveActive: false)
    }

    func replaceAndFindNext() {
        replaceCurrent()
    }

    func clearHighlights() {
        editor?.clearFindHighlights()
    }
}
