import Foundation

/// Preview / pinned tab state machine of one workspace window. Pure logic: it decides, the UI (or the window layer)
/// carries out the returned effects.
///
/// Rules: at most one preview tab. Single click opens a file in the preview tab, replacing whatever the previous
/// preview showed. Double click, or the first edit, pins it. A file is open at most once (tabs are keyed by
/// `URL.fileKey`): opening it again activates the existing tab, and a single click on a pinned file never turns it
/// back into a preview.
public struct TabSession: Codable, Equatable, Sendable {
    public struct Tab: Codable, Equatable, Sendable, Identifiable {
        public let url: URL
        public var isPreview: Bool
        public var id: String { url.fileKey }
    }

    public enum Effect: Equatable, Sendable {
        case opened(URL)
        case closed(URL)
        case pinned(URL)
        case activated(URL)
    }

    public private(set) var tabs: [Tab] = []
    public private(set) var activeID: String?

    public init() {}

    public var activeURL: URL? { tabs.first { $0.id == activeID }?.url }
    public var previewURL: URL? { tabs.first(where: \.isPreview)?.url }

    // MARK: Opening

    public mutating func singleClick(_ url: URL) -> [Effect] {
        if tabs.contains(where: { $0.id == url.fileKey }) { return activate(url) }
        let tab = Tab(url: url, isPreview: true)
        if let at = tabs.firstIndex(where: \.isPreview) {  // the preview slot is reused in place
            let old = tabs[at].url
            tabs[at] = tab
            activeID = tab.id
            return [.opened(url), .activated(url), .closed(old)]  // old goes last: a window layer must not lose its only tab first
        }
        return insert(tab)
    }

    public mutating func doubleClick(_ url: URL) -> [Effect] {
        guard let at = tabs.firstIndex(where: { $0.id == url.fileKey }) else { return insert(Tab(url: url, isPreview: false)) }
        var effects: [Effect] = []
        if tabs[at].isPreview {
            tabs[at].isPreview = false
            effects.append(.pinned(tabs[at].url))
        }
        return effects + activate(url)
    }

    /// The user typed into `url`: a preview becomes a regular tab.
    public mutating func edited(_ url: URL) -> [Effect] {
        guard let at = tabs.firstIndex(where: { $0.id == url.fileKey && $0.isPreview }) else { return [] }
        tabs[at].isPreview = false
        return [.pinned(url)]
    }

    // MARK: Closing and switching

    /// Closing the active tab activates its right neighbour, else its left one.
    public mutating func close(_ url: URL) -> [Effect] {
        guard let at = tabs.firstIndex(where: { $0.id == url.fileKey }) else { return [] }
        let closed = tabs.remove(at: at)
        var effects: [Effect] = [.closed(closed.url)]
        if closed.id == activeID {
            activeID = tabs.isEmpty ? nil : tabs[min(at, tabs.count - 1)].id
            if let next = activeURL { effects.append(.activated(next)) }
        }
        return effects
    }

    public mutating func activate(_ url: URL) -> [Effect] {
        guard tabs.contains(where: { $0.id == url.fileKey }), activeID != url.fileKey else { return [] }
        activeID = url.fileKey
        return [.activated(url)]
    }

    /// The file behind a tab was renamed or moved. If `new` is already open, the two tabs merge into that one.
    public mutating func moved(from old: URL, to new: URL) {
        guard let at = tabs.firstIndex(where: { $0.id == old.fileKey }), old.fileKey != new.fileKey else { return }
        let wasActive = tabs[at].id == activeID
        if tabs.contains(where: { $0.id == new.fileKey }) {
            tabs.remove(at: at)
        } else {
            tabs[at] = Tab(url: new, isPreview: tabs[at].isPreview)
        }
        if wasActive { activeID = new.fileKey }  // the surviving tab carries the new key either way
    }

    // MARK: Internals

    /// New tabs open to the right of the active one (at the end when nothing is active).
    private mutating func insert(_ tab: Tab) -> [Effect] {
        let at = tabs.firstIndex { $0.id == activeID }.map { $0 + 1 } ?? tabs.count
        tabs.insert(tab, at: at)
        activeID = tab.id
        return [.opened(tab.url), .activated(tab.url)]
    }
}
