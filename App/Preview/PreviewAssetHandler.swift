import Foundation
import UniformTypeIdentifiers
import WebAssets
import WebKit

/// Serves the files in `WebAssets/Resources` to the preview page as `macdown2-res://app/<path>`.
///
/// Why not a `file://` URL: `WebPage` has no `loadFileURL(_:allowingReadAccessTo:)`. Measured on macOS 27 (unsandboxed,
/// ad-hoc signed): `page.load(fileURL)` neither finishes nor throws, so the preview stays blank with nothing in the log.
/// A scheme handler needs no file access, and the page's CSP `'self'` then means exactly "our scheme + host".
/// (`macdown2-res://doc/...` for images next to the document is M1.)
struct PreviewAssetHandler: URLSchemeHandler {
    static let scheme = "macdown2-res"
    static let previewURL = URL(string: "\(scheme)://app/preview.html")!

    func reply(for request: URLRequest) -> AsyncThrowingStream<URLSchemeTaskResult, any Error> {
        AsyncThrowingStream { continuation in
            let url = request.url ?? Self.previewURL
            let file = Self.resolve(url)
            let data = file.flatMap { try? Data(contentsOf: $0) }
            let status = data == nil ? 404 : 200
            let mime = file.flatMap { UTType(filenameExtension: $0.pathExtension)?.preferredMIMEType } ?? "application/octet-stream"
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": mime, "Cache-Control": "no-store"]
            )!
            continuation.yield(.response(response))
            if let data { continuation.yield(.data(data)) }
            continuation.finish()
        }
    }

    /// Maps `/a/b.css` into the Resources folder; anything that escapes it resolves to nil. `url.path` is already
    /// percent-decoded, so `%2e%2e` arrives here as `..` and is caught by the prefix check after standardizing.
    static func resolve(_ url: URL) -> URL? {
        guard url.host == "app",
              let root = WebAssets.url("preview.html")?.deletingLastPathComponent().resolvingSymlinksInPath()
        else { return nil }
        let file = root.appending(path: url.path).standardizedFileURL.resolvingSymlinksInPath()
        return file.path.hasPrefix(root.path + "/") ? file : nil
    }
}
