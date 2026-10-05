import Foundation

/// What the preview renders next and what the page shows, as plain state (`PreviewModel` drives it: it owns the page, the timing
/// and the one render in flight). Text waits here, newest wins, so a burst of typing costs one render per finished one and the
/// last text is always rendered; a different document starts from nothing; and a checkbox click is matched against the text the
/// page actually shows, not the one a render still on its way will show.
public struct RenderQueue: Sendable {
    /// One render handed out by `begin`: its text and the version the page is given (it reports the version it shows with each
    /// checkbox click).
    public struct Ticket: Sendable, Equatable {
        public let text: String
        public let version: Int
        fileprivate let generation: Int
    }

    /// What the page shows once a render has answered: its text and version, and the checkboxes the renderer found in it
    /// (nil when the answer could not be read: a click is then refused).
    public struct Displayed: Sendable, Equatable {
        public let version: Int
        public let text: String
        public let tasks: [TaskItem]?
    }

    /// The document's newest text, rendered or not.
    public private(set) var latest: String?
    public private(set) var displayed: Displayed?
    private var pending: String?
    private var document: ObjectIdentifier?
    private var versions = 0
    private var generation = 0

    public init() {}

    /// Text waits: it replaces whatever was waiting, and is the next `begin`.
    public mutating func submit(_ text: String) {
        latest = text
        pending = text
    }

    /// The pane shows `document`. A different one than before drops the previous one's text, waiting and shown, and returns true:
    /// its text must not be rendered with the new document's settings, and renders still on their way no longer count (`landed`).
    public mutating func show(_ document: ObjectIdentifier) -> Bool {
        guard document != self.document else { return false }
        clear()
        self.document = document
        return true
    }

    /// No document: nothing of the last one stays.
    public mutating func clear() {
        generation += 1
        document = nil
        latest = nil
        pending = nil
        displayed = nil
    }

    /// The page was loaded again: it shows nothing of what it showed.
    public mutating func pageReloaded() { displayed = nil }

    /// The next render, nil when nothing waits.
    public mutating func begin() -> Ticket? {
        guard let text = pending else { return nil }
        pending = nil
        versions += 1
        return Ticket(text: text, version: versions, generation: generation)
    }

    /// The page answered `ticket`'s render. False when the document changed meanwhile: the answer is not shown to the window.
    /// A render that failed is simply never landed; `displayed` stays what the page still shows.
    @discardableResult
    public mutating func landed(_ ticket: Ticket, tasks: [TaskItem]?) -> Bool {
        guard ticket.generation == generation else { return false }
        displayed = Displayed(version: ticket.version, text: ticket.text, tasks: tasks)
        return true
    }

    /// How long to leave the page alone before the next render of a burst: as long as the last one took (so on a heavy document
    /// it is at most about half busy), nil when nothing waits.
    public func gap(afterRenderTaking elapsed: Duration) -> Duration? { pending == nil ? nil : elapsed }

    /// What a checkbox click that reports `version` is about: the text and checkboxes of that render, while the page still shows
    /// it (a newer render on its way does not change that); nil when it is not the shown one or its checkboxes are unknown. The
    /// editor still applies the change only if its text is still exactly `text`.
    public func toggleTarget(version: Int) -> Displayed? {
        guard let displayed, displayed.version == version, displayed.tasks != nil else { return nil }
        return displayed
    }
}
