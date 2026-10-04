import Foundation

/// A window's workspace mode (PLAN 4.11). No roots = browse mode (favorites / current location / recents); one or more
/// roots = workspace mode (the sidebar shows only these folders' trees). Per window, saved with the window.
public struct WorkspaceFolders: Equatable, Sendable {
    public private(set) var roots: [URL] = []

    public init(roots: [URL] = []) {
        for root in roots { add(root) }
    }

    public var isActive: Bool { !roots.isEmpty }
    public var rootKeys: Set<String> { Set(roots.map(\.fileKey)) }

    /// "MyBook" for one root, "2 folders" for several (the chip's title).
    public var title: String {
        switch roots.count {
        case 0: return ""
        case 1: return roots[0].lastPathComponent
        default: return L10n.folders(roots.count)
        }
    }

    /// Enters workspace mode or adds a root. false when it is already one.
    @discardableResult
    public mutating func add(_ url: URL) -> Bool {
        guard !rootKeys.contains(url.fileKey) else { return false }
        roots.append(url)
        return true
    }

    /// Removing the last root leaves workspace mode.
    public mutating func remove(_ url: URL) { roots.removeAll { $0.fileKey == url.fileKey } }

    /// Back to browse mode.
    public mutating func close() { roots = [] }

    /// Roots that still exist as folders (a relaunch after the folder was moved or deleted).
    public func existing(fileManager: FileManager = .default) -> WorkspaceFolders {
        WorkspaceFolders(roots: roots.filter {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: $0.path, isDirectory: &isDirectory) && isDirectory.boolValue
        })
    }
}
