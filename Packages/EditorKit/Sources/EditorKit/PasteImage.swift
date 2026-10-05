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

    /// Phone photos and web photos: converted to JPEG (a PNG of a 12 MP photo is 10x the size). An image with transparency stays PNG.
    private static let lossyTypes: [UTType] = [.heic, .heif, .webP]
    private static let jpegQuality = 0.9

    /// What gets written for image bytes of type `type`: PNG, JPEG, GIF (animation) and SVG stay as they are; HEIC and WebP
    /// photos become JPEG (PNG when they have transparency); anything else the system can decode (TIFF, BMP ...) becomes PNG.
    /// nil when the bytes are not an image.
    // lazy: synchronous on the main thread; only conversions (TIFF/HEIC/WebP) cost anything. Move to a detached task, insert when done, if a
    // multi-megapixel paste ever feels slow.
    public static func encode(_ data: Data, type: UTType) -> PastedImage? {
        guard !data.isEmpty else { return nil }
        if type.conforms(to: .svg) {  // text, not decodable by ImageIO: keep as is when it at least looks like SVG
            return String(decoding: data.prefix(4096), as: UTF8.self).contains("<svg") ? PastedImage(data: data, fileExtension: "svg") : nil
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        if type.conforms(to: .png) { return PastedImage(data: data, fileExtension: "png") }
        if type.conforms(to: .jpeg) { return PastedImage(data: data, fileExtension: "jpg") }
        if type.conforms(to: .gif) { return PastedImage(data: data, fileExtension: "gif") }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let opaque = (properties?[kCGImagePropertyHasAlpha] as? Bool) != true
        if opaque, lossyTypes.contains(where: type.conforms(to:)) {
            return reencode(source, as: .jpeg).map { PastedImage(data: $0, fileExtension: "jpg") }
        }
        return reencode(source, as: .png).map { PastedImage(data: $0, fileExtension: "png") }
    }

    /// The first frame, upright (EXIF orientation applied: a phone's photo must not land sideways), as `type` (PNG or JPEG).
    private static func reencode(_ source: CGImageSource, as type: UTType) -> Data? {
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
        guard let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        let destinationOptions: [CFString: Any] = type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: jpegQuality] : [:]
        CGImageDestinationAddImage(destination, image, destinationOptions as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    // MARK: Pasteboard

    /// Image data types in the order they are tried: lossless first, so a screenshot's PNG is used rather than its TIFF twin.
    private static let dataTypes: [(NSPasteboard.PasteboardType, UTType)] = [
        (.png, .png), (NSPasteboard.PasteboardType(UTType.jpeg.identifier), .jpeg), (NSPasteboard.PasteboardType(UTType.heic.identifier), .heic), (.tiff, .tiff),
    ]
    private static let offered: [NSPasteboard.PasteboardType] = [.fileURL] + dataTypes.map(\.0)

    /// Whether `pasteboard` offers something that might be an image paste: a cheap look at the type list, nothing is read.
    /// Edit > Paste uses it, because NSTextView would grey the item out for a pasteboard with only image data.
    static func offersImage(on pasteboard: NSPasteboard) -> Bool { pasteboard.availableType(from: offered) != nil }

    /// What an image paste would use, found without reading or decoding any image.
    struct Candidates {
        enum Source {
            case file(URL, UTType)
            case data(NSPasteboard.PasteboardType, UTType)
        }
        var sources: [Source]
        let pasteboard: NSPasteboard
    }

    /// The image paste `pasteboard` offers, or nil when this is not one (so the normal paste runs):
    ///   * image files copied in Finder win (the pasteboard also carries their names as text);
    ///   * otherwise text wins (a spreadsheet range or a web selection comes with a picture of itself);
    ///   * otherwise image data (a screenshot, "Copy Image").
    static func candidates(on pasteboard: NSPasteboard) -> Candidates? {
        guard offersImage(on: pasteboard) else { return nil }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let types = urls.map { UTType(filenameExtension: $0.pathExtension) }
            if types.allSatisfy({ $0?.conforms(to: .image) == true }) {
                return Candidates(sources: zip(urls, types).map { .file($0, $1!) }, pasteboard: pasteboard)
            }
        }
        if pasteboard.availableType(from: [.string]) != nil { return nil }
        guard let (type, uti) = dataTypes.first(where: { pasteboard.availableType(from: [$0.0]) != nil }) else { return nil }
        return Candidates(sources: [.data(type, uti)], pasteboard: pasteboard)
    }

    /// Reads and encodes the candidates. Image files that cannot be used (unreadable, too big, outside `permits`) give nil: the
    /// normal paste runs, which pastes their names. Image data that cannot be used throws: the user copied an image and
    /// would otherwise see nothing happen.
    static func load(_ candidates: Candidates, permits: (URL) -> Bool = { _ in true }) throws -> [PastedImage]? {
        var images: [PastedImage] = []
        for source in candidates.sources {
            switch source {
            case .file(let url, let type):
                guard permits(url), (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 <= maxBytes,
                      let data = try? Data(contentsOf: url), let image = encode(data, type: type) else { return nil }
                images.append(image)
            case .data(let pasteboardType, let type):
                guard let data = candidates.pasteboard.data(forType: pasteboardType) else { throw PasteImageError.unreadable }
                guard data.count <= maxBytes else { throw PasteImageError.tooLarge }
                guard let image = encode(data, type: type) else { throw PasteImageError.unreadable }
                images.append(image)
            }
        }
        return images
    }

    /// `candidates` and `load` in one step (nil: not an image paste, or image files that cannot be used).
    public static func images(on pasteboard: NSPasteboard, permits: (URL) -> Bool = { _ in true }) throws -> [PastedImage]? {
        try candidates(on: pasteboard).flatMap { try load($0, permits: permits) }
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

    /// The alt text of an inserted image: not empty, so screen readers and a broken link both say something. The user can refine it.
    public static let altText = "image"

    /// `![image](images/x.png)` per path, one per line; the caret goes after the last one.
    public static func edit(forPaths paths: [String], replacing selection: NSRange) -> TextEdit {
        let text = paths.map { "![\(altText)](\($0))" }.joined(separator: "\n")
        return TextEdit(range: selection, replacement: text, selection: NSRange(location: selection.location + (text as NSString).length, length: 0))
    }
}
