import Foundation

/// The sidebar's "Current location": the folder of the active document, which can be walked up with the path bar.
/// Following the document resets any manual navigation; an untitled document (no URL) leaves the location alone.
public struct CurrentLocation: Equatable, Sendable {
    public struct Segment: Equatable, Sendable, Identifiable {
        public let title: String
        public let url: URL
        public var id: String { url.fileKey }
    }

    public private(set) var directory: URL?

    public init(directory: URL? = nil) { self.directory = directory }

    /// The active document changed (or was saved/moved). nil = untitled, keep what is shown.
    public mutating func follow(documentURL: URL?) {
        if let documentURL { directory = documentURL.deletingLastPathComponent() }
    }

    /// Path bar click, or "up".
    public mutating func navigate(to url: URL) { directory = url }

    public var parent: URL? {
        guard let directory, directory.fileKey != "/" else { return nil }
        return directory.deletingLastPathComponent()
    }

    /// Path bar segments from the volume root down to the current folder. `rootTitle` names "/" (the UI passes the
    /// startup volume's name).
    public func segments(rootTitle: String = "/") -> [Segment] {
        guard let directory else { return [] }
        var out = [Segment(title: rootTitle, url: URL(filePath: "/", directoryHint: .isDirectory))]
        var url = URL(filePath: "/", directoryHint: .isDirectory)
        for part in directory.standardizedFileURL.pathComponents where part != "/" {
            url.append(path: part, directoryHint: .isDirectory)
            out.append(Segment(title: part, url: url))
        }
        return out
    }
}
