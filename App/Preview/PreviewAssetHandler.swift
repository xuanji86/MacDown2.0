import Foundation
import UniformTypeIdentifiers
import WebAssets
import WebKit

/// The directory `macdown2-res://doc/...` resolves against. `urlSchemeHandlers` cannot change after the `WebPage`
/// exists (PLAN 4.4.2 pitfall 1), so the handler holds this box and the model updates it when the document moves.
final class DocumentRoot: @unchecked Sendable {
    private let lock = NSLock()
    private var directory: URL?
    var url: URL? {
        get { lock.withLock { directory } }
        set { lock.withLock { directory = newValue } }
    }
}

/// Serves two hosts of the `macdown2-res` scheme to the preview page:
/// - `app`: the files in `WebAssets/Resources` (`macdown2-res://app/<path>`);
/// - `doc`: files in the current document's directory, for relative images (`macdown2-res://doc/<path>`).
///
/// Why not a `file://` URL: `WebPage` has no `loadFileURL(_:allowingReadAccessTo:)`. Measured on macOS 27 (unsandboxed,
/// ad-hoc signed): `page.load(fileURL)` neither finishes nor throws, so the preview stays blank with nothing in the log.
struct PreviewAssetHandler: URLSchemeHandler {
    static let scheme = "macdown2-res"
    static let previewURL = URL(string: "\(scheme)://app/preview.html")!
    static let nonceToken = "__CSP_NONCE__"

    let documentRoot: DocumentRoot

    func reply(for request: URLRequest) -> AsyncThrowingStream<URLSchemeTaskResult, any Error> {
        AsyncThrowingStream { continuation in
            let url = request.url ?? Self.previewURL
            let (status, mime, data) = load(url)
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": mime, "Cache-Control": "no-store"]
            )!
            continuation.yield(.response(response))
            if let data { continuation.yield(.data(data)) }
            continuation.finish()
        }
    }

    // lazy: reads the whole file into memory before replying (no streaming, no Range); fine for images next to a
    // Markdown file. Upgrade path: yield .data in chunks if large media shows up.
    private func load(_ url: URL) -> (status: Int, mime: String, data: Data?) {
        let file: URL?
        var status = 404
        switch url.host {
        case "app":
            file = Self.resolve(url)
        case "doc":
            switch DocumentFileResolver.resolve(path: url.path, root: documentRoot.url) {
            case .file(let f): file = f
            case .forbidden: file = nil; status = 403
            case .notFound: file = nil
            }
        default:
            file = nil
        }
        guard let file, var data = try? Data(contentsOf: file) else { return (status, "text/plain", nil) }
        if url.host == "app", url.path == "/preview.html" { data = Self.withNonce(data) }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return (200, mime, data)
    }

    /// Every load of the page gets a fresh CSP nonce: the `<meta>` policy and our `<script nonce>` tags share it,
    /// so only the tags in this file run (CSP only; the bundles themselves are not user-controlled).
    static func withNonce(_ html: Data) -> Data {
        guard let text = String(data: html, encoding: .utf8) else { return html }
        return Data(text.replacingOccurrences(of: nonceToken, with: UUID().uuidString).utf8)
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
