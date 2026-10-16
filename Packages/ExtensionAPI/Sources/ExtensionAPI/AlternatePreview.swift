import Foundation

/// Another renderer for a flavor's documents, run by an external tool and shown in the preview instead of the app's own render
/// (Quarto real render, PLAN 4.6.2). Offered through `DocumentFlavor.alternatePreviewMode`; the app shows a
/// `Approximate | <title>` switch and a menu item for it and starts nothing by itself: only the user's switch does.
///
/// Nothing may look for the tool before `isAvailable()` (or the extension's settings pane) asks: a mode that is offered costs nothing.
@MainActor
public protocol AlternatePreviewMode: AnyObject {
    /// The segment next to "Approximate" ("Quarto").
    var title: String { get }
    /// The menu item that switches it on and off ("Render with Quarto").
    var commandTitle: String { get }
    /// What to ask before the first start in a document session (the tool will run the document's code); nil = do not ask.
    var confirmation: AlternatePreviewConfirmation? { get }
    /// Looks for the tool (the first call probes; later ones may answer from what was found).
    func isAvailable() async -> AlternatePreviewAvailability
    /// The session for the document at `fileURL`, shared by every window that shows it; made on first ask, not started.
    func session(for fileURL: URL) -> any AlternatePreviewSession
}

public enum AlternatePreviewAvailability: Sendable, Equatable {
    case available
    /// Why not, for an alert ("Quarto 1.4 or later was not found …").
    case unavailable(String)
}

public struct AlternatePreviewConfirmation: Sendable, Equatable {
    public var title: String
    public var message: String
    /// The button that goes ahead ("Render"); the other one is Cancel.
    public var confirmButton: String

    public init(title: String, message: String, confirmButton: String) {
        self.title = title
        self.message = message
        self.confirmButton = confirmButton
    }
}

public enum AlternatePreviewStatus: Sendable, Equatable {
    /// Not running: the app's own preview shows.
    case stopped
    /// The tool is starting and has not given a page yet.
    case starting
    /// The page is there and the tool is rendering again (after a save).
    case rendering
    /// The page is there and up to date with the file on disk.
    case ready
    /// The last render failed or the tool is gone (the text says which: "Quarto exited (code 1)"). The page, if any, stays.
    case failed(String)
}

/// One document's alternate preview. Observable in practice (the app's views read `url`, `status` and `lastRendered`).
@MainActor
public protocol AlternatePreviewSession: AnyObject {
    /// The page to show (a local server's); nil while starting, after a failed start and once stopped.
    var url: URL? { get }
    var status: AlternatePreviewStatus { get }
    /// When the tool last finished a render.
    var lastRendered: Date? { get }
    /// What to show under "View Log": the tool's error entries (else the end of its output).
    func logText() -> String
    /// Starts the tool; returns once there is a page or the start failed (see `status`). Does nothing while running.
    func start() async
    /// Stops the tool and everything it started; idempotent.
    func stop() async
}

extension AlternatePreviewStatus {
    /// Started by the user and not stopped since (a failed one counts: its banner says why until the user switches back).
    public var isActive: Bool { self != .stopped }
}
