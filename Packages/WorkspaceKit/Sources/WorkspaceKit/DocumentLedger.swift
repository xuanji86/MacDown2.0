import Foundation

/// Which workspace windows have which files open. One document instance can be shown in several windows (the same
/// file in two windows); a window closing its tab only lets go of the document once no window holds it any more, and
/// only then does closing the tab have to ask about unsaved changes.
@MainActor
public final class DocumentLedger {
    private var holders: [String: Set<UUID>] = [:]

    public init() {}

    public func hold(_ key: String, by window: UUID) { holders[key, default: []].insert(window) }

    /// `window` lets go of `key`. True when nobody holds it now.
    @discardableResult
    public func release(_ key: String, by window: UUID) -> Bool {
        holders[key]?.remove(window)
        guard holders[key]?.isEmpty ?? true else { return false }
        holders[key] = nil
        return true
    }

    public func holders(of key: String) -> Set<UUID> { holders[key] ?? [] }

    public func keys(heldBy window: UUID) -> Set<String> { Set(holders.filter { $0.value.contains(window) }.keys) }

    /// The file behind `old` now lives at `new` (rename / move).
    public func rekey(_ old: String, to new: String) {
        guard old != new, let ids = holders.removeValue(forKey: old) else { return }
        holders[new, default: []].formUnion(ids)
    }
}
