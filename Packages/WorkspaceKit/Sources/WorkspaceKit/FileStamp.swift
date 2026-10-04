import Foundation

/// Size and modification date of a file, to tell later whether it changed (the preview uses it for the images it loaded).
/// Read with `FileManager.attributesOfItem`, not `URL.resourceValues`: a `URL` object caches the values it has returned, so a
/// second stamp of the same `URL` would report the first one's size and date even after the file was overwritten or deleted.
public struct FileStamp: Equatable, Sendable {
    public let size: Int?
    public let modified: Date?

    /// A missing file has no size and no date.
    public init(of url: URL) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        size = (attributes?[.size] as? NSNumber)?.intValue
        modified = attributes?[.modificationDate] as? Date
    }
}
