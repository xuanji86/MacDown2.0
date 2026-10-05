import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Why an image paste could not go through. The app turns each case into a localized message.
public enum PasteImageError: Error {
    /// The pasteboard holds an image (or image file) that cannot be decoded.
    case unreadable
    /// Over `PasteImage.maxBytes`.
    case tooLarge
    /// The destination (or source file) is outside what an isolated launch may touch.
    case notPermitted(URL)
    /// `images` exists next to the document but is a file.
    case imagesIsNotAFolder(URL)
    case io(any Error)
}

/// An image ready to be written next to the document.
public struct PastedImage: Equatable, Sendable {
    public var data: Data
    /// Without the dot: "png", "jpg", "gif", "svg".
    public var fileExtension: String
}

/// Paste an image: read it from the pasteboard (`images(on:)`), encode it (`encode`), save it under `<document folder>/images/`
/// with a date-time name (`write`), and build the Markdown that points at it. The text view wires these together
/// (`MarkdownTextView.paste`); everything here is a plain function so it can be tested without a view.
public enum PasteImage {
    /// The folder next to the document that holds pasted images.
    public static let folderName = "images"
    /// lazy: whole file in memory; larger images are refused instead of streamed (screenshots and photos are far below this).
    public static let maxBytes = 64 << 20

    // MARK: Encoding

    /// What gets written for image bytes of type `type`: PNG, JPEG, GIF (animation) and SVG stay as they are, anything else
    /// the system can decode (TIFF, HEIC, WebP, BMP ...) becomes PNG. nil when the bytes are not an image.
    public static func encode(_ data: Data, type: UTType) -> PastedImage? {
        guard !data.isEmpty else { return nil }
        if type.conforms(to: .svg) {  // text, not decodable by ImageIO: keep as is when it at least looks like SVG
            return String(decoding: data.prefix(4096), as: UTF8.self).contains("<svg") ? PastedImage(data: data, fileExtension: "svg") : nil
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        if type.conforms(to: .png) { return PastedImage(data: data, fileExtension: "png") }
        if type.conforms(to: .jpeg) { return PastedImage(data: data, fileExtension: "jpg") }
        if type.conforms(to: .gif) { return PastedImage(data: data, fileExtension: "gif") }
        return png(from: source).map { PastedImage(data: $0, fileExtension: "png") }
    }

    /// The first frame as an upright PNG (EXIF orientation applied: a phone's HEIC must not land sideways).
    private static func png(from source: CGImageSource) -> Data? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? Int) ?? 0, height = (properties?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        guard width > 0, height > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    // MARK: Pasteboard

    /// Image data types in the order they are tried: lossless first, so a screenshot's PNG is used rather than its TIFF twin.
    private static let dataTypes: [(NSPasteboard.PasteboardType, UTType)] = [
        (.png, .png), (NSPasteboard.PasteboardType(UTType.jpeg.identifier), .jpeg), (NSPasteboard.PasteboardType(UTType.heic.identifier), .heic), (.tiff, .tiff),
    ]

    /// The images `pasteboard` offers, or nil when this is not an image paste (so the normal paste runs).
    ///   * image files copied in Finder win (the pasteboard also carries their names as text);
    ///   * otherwise text wins (a spreadsheet range or a web selection comes with a picture of itself);
    ///   * otherwise image data (a screenshot, "Copy Image").
    /// `permits` is asked before a file is read. Throws when an image is claimed but cannot be used: nothing is silently dropped.
    public static func images(on pasteboard: NSPasteboard, permits: (URL) -> Bool = { _ in true }) throws -> [PastedImage]? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let types = urls.map { UTType(filenameExtension: $0.pathExtension) }
            if types.allSatisfy({ $0?.conforms(to: .image) == true }) {
                return try zip(urls, types).map { url, type in
                    guard permits(url) else { throw PasteImageError.notPermitted(url) }
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    guard size <= maxBytes else { throw PasteImageError.tooLarge }
                    guard let data = try? Data(contentsOf: url), let image = encode(data, type: type!) else { throw PasteImageError.unreadable }
                    return image
                }
            }
        }
        if pasteboard.string(forType: .string) != nil { return nil }
        for (pasteboardType, type) in dataTypes {
            guard let data = pasteboard.data(forType: pasteboardType) else { continue }
            guard data.count <= maxBytes else { throw PasteImageError.tooLarge }
            guard let image = encode(data, type: type) else { throw PasteImageError.unreadable }
            return [image]
        }
        return nil
    }

    // MARK: Writing

    /// "image-20261005-143207": local time, ASCII digits only (no locale, no spaces: the name goes into a Markdown link as is).
    public static func baseName(for date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "image-%04d%02d%02d-%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// Saves `image` as `<documentFolder>/images/<date-time>.<ext>` and returns the path relative to the document
    /// ("images/image-20261005-143207.png"). Creates `images` if missing. Never overwrites: the file is created with `O_EXCL`,
    /// and a name that is taken gets "-2", "-3" ... (several pastes within one second, or a file already there).
    /// `permits` is asked about the images folder (the document's folder while `images` does not exist yet) before anything is created.
    public static func write(_ image: PastedImage, besideDocumentIn documentFolder: URL, date: Date = Date(), calendar: Calendar = Calendar(identifier: .gregorian),
                             permits: (URL) -> Bool = { _ in true }) throws -> String {
        let folder = documentFolder.appending(path: folderName, directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory)
        // An existing folder is judged as it is (a symlink to elsewhere is followed); one that does not exist yet by the document's
        // folder: a path that is not there cannot be resolved reliably (/private/var vs /var), and nothing can point out of a new folder.
        guard permits(exists ? folder : documentFolder) else { throw PasteImageError.notPermitted(exists ? folder : documentFolder) }
        if exists {
            guard isDirectory.boolValue else { throw PasteImageError.imagesIsNotAFolder(folder) }
        } else {
            do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) } catch { throw PasteImageError.io(error) }
        }
        let base = baseName(for: date, calendar: calendar)
        // lazy: 999 same-second collisions give up with EEXIST; a counter per folder if anyone pastes that fast
        for n in 1...999 {
            let name = (n == 1 ? base : "\(base)-\(n)") + "." + image.fileExtension
            let path = folder.appending(path: name).path
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            if fd < 0 {
                if errno == EEXIST { continue }
                throw PasteImageError.io(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
            }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: image.data)
                try handle.close()
            } catch {
                try? FileManager.default.removeItem(atPath: path)  // never leave half an image behind
                throw PasteImageError.io(error)
            }
            return "\(folderName)/\(name)"
        }
        throw PasteImageError.io(POSIXError(.EEXIST))
    }

    /// `![](images/x.png)` per path, one per line; the caret goes after the last one.
    public static func edit(forPaths paths: [String], replacing selection: NSRange) -> TextEdit {
        let text = paths.map { "![](\($0))" }.joined(separator: "\n")
        return TextEdit(range: selection, replacement: text, selection: NSRange(location: selection.location + (text as NSString).length, length: 0))
    }
}
