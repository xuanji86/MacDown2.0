import Foundation

/// Decides when the editor must reload text from the document model.
///
/// The editor writes keystrokes to the model and never reads them back, so anything else that changes the model
/// (Revert To / Browse All Versions, an external file change, SwiftUI handing the view a different document
/// instance) leaves the editor showing stale text; the next keystroke would then overwrite the model with it.
/// This struct remembers the last text both sides agreed on and the document instance it belongs to.
public struct ExternalTextSync {
    private var document: AnyObject
    private var lastSyncedText: String

    public init(document: AnyObject, text: String) {
        self.document = document
        self.lastSyncedText = text
    }

    /// The editor just wrote `text` into the model.
    public mutating func editorDidWrite(_ text: String) {
        lastSyncedText = text
    }

    /// Compare the model with what the editor has. Returns the text to load into the editor, or nil when the model
    /// still holds what the editor last wrote. A different document instance with identical text needs no reload.
    public mutating func reloadText(document: AnyObject, modelText: String) -> String? {
        self.document = document
        guard modelText != lastSyncedText else { return nil }
        lastSyncedText = modelText
        return modelText
    }

    public func isSameDocument(_ other: AnyObject) -> Bool { document === other }

    /// Where a selection should land after the text changed from `old` to `new`: positions in the unchanged prefix
    /// stay, positions in the unchanged suffix shift with it, positions inside the replaced middle clamp into the
    /// new middle.
    public static func remap(_ range: NSRange, from old: String, to new: String) -> NSRange {
        let a = Array(old.utf16), b = Array(new.utf16)
        var prefix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        func map(_ p: Int) -> Int {
            if p <= prefix { return p }
            if p >= a.count - suffix { return p + b.count - a.count }
            return min(p, b.count - suffix)
        }
        let start = min(map(range.location), b.count), end = min(max(map(NSMaxRange(range)), start), b.count)
        return NSRange(location: start, length: end - start)
    }
}
