import Foundation

/// A match to select in the file with this key (0-based `line`, UTF-16 `columns` inside it).
public struct RevealRequest: Equatable, Sendable {
    public let key: String
    public let line: Int
    public let columns: Range<Int>?
    public let focus: Bool

    public init(key: String, line: Int, columns: Range<Int>?, focus: Bool) {
        self.key = key
        self.line = line
        self.columns = columns
        self.focus = focus
    }
}

/// Holds a search result until the editor shows its file: opening a tab only changes the window's active document, the
/// editor swaps its text later. Each call returns the request to carry out now, if any. A request is dropped at the first
/// time the shown file changes without it matching, so it can never fire on some later tab switch.
public struct RevealTracker: Sendable {
    /// File key of the document the editor shows (nil: untitled or none).
    public private(set) var shownKey: String?
    public private(set) var pending: RevealRequest?

    public init() {}

    /// A result was chosen: now if its file is on screen, else when it gets there.
    public mutating func request(_ request: RevealRequest) -> RevealRequest? {
        pending = request
        return takeIfShown()
    }

    /// The editor now shows the document with this key (a tab switch, or the editor was just made).
    public mutating func bound(key: String?) -> RevealRequest? {
        shownKey = key
        defer { pending = nil }
        return takeIfShown()
    }

    /// The shown document may have a new key without being another document (first save of an Untitled, a rename).
    public mutating func sync(key: String?) -> RevealRequest? {
        key == shownKey ? nil : bound(key: key)
    }

    private mutating func takeIfShown() -> RevealRequest? {
        guard let request = pending, request.key == shownKey else { return nil }
        pending = nil
        return request
    }
}
