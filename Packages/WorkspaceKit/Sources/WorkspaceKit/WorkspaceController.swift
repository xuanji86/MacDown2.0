import Foundation
import Observation

/// What a workspace window needs from the document layer. The app implements it on top of `NSDocument`; tests fake it.
/// Documents are identified by file URL, the backend keeps one live document per URL however many windows show it.
@MainActor
public protocol DocumentBackend: AnyObject {
    /// Loads the file (or finds it already loaded). Throws when it cannot be read.
    func load(_ url: URL) throws
    func isDirty(_ url: URL) -> Bool
    /// Last window holding a dirty document is about to let go: let the user save or discard. false = cancel.
    func confirmClose(_ url: URL, in window: UUID) async -> Bool
    /// No window shows the document any more: close it. Must detach window controllers first.
    func unload(_ url: URL)
    /// `url` became the window's current document (nil: the window shows none).
    func didActivate(_ url: URL?, in window: UUID)
}

/// One workspace window's tabs: `TabSession` decides, this carries out the effects against the document layer and keeps
/// the cross-window bookkeeping (a document shown in two windows is closed with the last one).
@MainActor @Observable
public final class WorkspaceController {
    public enum Mode: Sendable {
        /// Single click in the file tree: the preview tab.
        case preview
        /// Finder, Cmd-O, double click: a regular tab.
        case pinned
    }

    public let id: UUID
    public private(set) var session = TabSession()

    @ObservationIgnored private let ledger: DocumentLedger
    @ObservationIgnored private let backend: any DocumentBackend
    @ObservationIgnored private var closing = Set<String>()

    public init(id: UUID = UUID(), ledger: DocumentLedger, backend: any DocumentBackend) {
        self.id = id
        self.ledger = ledger
        self.backend = backend
    }

    public var activeURL: URL? { session.activeURL }
    public var openKeys: Set<String> { Set(session.tabs.map(\.id)) }
    public func holds(_ url: URL) -> Bool { session.tabs.contains { $0.id == url.fileKey } }

    // MARK: Opening

    /// Opens `url` as a tab; the file is read first, so an unreadable one changes nothing and throws.
    public func open(_ url: URL, as mode: Mode) throws {
        if !holds(url) { try backend.load(url) }
        if mode == .preview, let preview = session.previewURL, preview.fileKey != url.fileKey, backend.isDirty(preview) {
            run(session.edited(preview))  // a preview with unsaved changes is never replaced: it becomes a regular tab
        }
        run(mode == .preview ? session.singleClick(url) : session.doubleClick(url))
    }

    /// Restores a saved session: files that no longer open are dropped.
    public func restore(_ saved: TabSession) {
        guard session.tabs.isEmpty else { return }
        session = saved.pruned { (try? backend.load($0)) != nil }
        for tab in session.tabs { ledger.hold(tab.id, by: id) }
        backend.didActivate(session.activeURL, in: id)
    }

    // MARK: Tabs

    public func activate(_ url: URL) { run(session.activate(url)) }

    /// The user typed into `url`, saved it or double clicked its tab: a preview becomes a regular tab.
    public func pin(_ url: URL) {
        guard session.previewURL?.fileKey == url.fileKey else { return }  // no write, no observation churn per keystroke
        run(session.edited(url))
    }

    public func moveTab(_ url: URL, to index: Int) { run(session.move(url, to: index)) }

    /// Next / previous tab, wrapping around.
    public func select(offset: Int) {
        let tabs = session.tabs
        guard tabs.count > 1, let at = tabs.firstIndex(where: { $0.id == session.activeID }) else { return }
        activate(tabs[((at + offset) % tabs.count + tabs.count) % tabs.count].url)
    }

    /// Jump to the n-th tab (1-based); 9 is the last one, as in browsers.
    public func select(number: Int) {
        let tabs = session.tabs
        guard !tabs.isEmpty, number >= 1 else { return }
        activate(tabs[number == 9 ? tabs.count - 1 : min(number, tabs.count) - 1].url)
    }

    /// Closes the tab after the save prompt if its document has unsaved changes and no other window shows it.
    /// false = the user cancelled (or the tab is already being closed).
    @discardableResult
    public func close(_ url: URL) async -> Bool {
        let key = url.fileKey
        guard holds(url) else { return true }
        guard closing.insert(key).inserted else { return false }
        defer { closing.remove(key) }
        if ledger.holders(of: key) == [id], backend.isDirty(url) {
            guard await backend.confirmClose(url, in: id) else { return false }
        }
        run(session.close(url))  // a no-op when the tab went away while the sheet was up
        return true
    }

    /// Window close: every tab in turn, stops at the first cancel.
    public func closeAll() async -> Bool {
        for tab in session.tabs where !(await close(tab.url)) { return false }
        return true
    }

    /// The window is gone without closing its tabs one by one (app termination): let go of everything.
    public func detach() {
        for tab in session.tabs where ledger.release(tab.id, by: id) { backend.unload(tab.url) }
        session = TabSession()
        backend.didActivate(nil, in: id)
    }

    /// A document's file was renamed or moved (Finder, Rename…, Move To…, Save As). The caller has already re-keyed the
    /// shared ledger (it is one change for all windows); this is the window's own tab.
    public func documentMoved(from old: URL, to new: URL) {
        guard holds(old) else { return }
        session.moved(from: old, to: new)
        backend.didActivate(session.activeURL, in: id)
    }

    // MARK: Effects

    private func run(_ effects: [TabSession.Effect]) {
        for effect in effects {
            switch effect {
            case .opened(let url): ledger.hold(url.fileKey, by: id)
            case .activated(let url): backend.didActivate(url, in: id)
            case .pinned: break  // the state change is the effect; views observe the session
            case .closed(let url):
                if ledger.release(url.fileKey, by: id) { backend.unload(url) }
            }
        }
        if session.activeURL == nil { backend.didActivate(nil, in: id) }
    }
}
