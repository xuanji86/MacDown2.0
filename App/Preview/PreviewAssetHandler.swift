import Foundation
import MarkdownCore
import UniformTypeIdentifiers
import WebAssets
import WebKit
import WorkspaceKit

/// The directory `macdown2-res://doc/...` resolves against. `urlSchemeHandlers` cannot change after the `WebPage`
/// exists (PLAN 4.4.2 pitfall 1), so the handler holds this box and the model updates it when the document moves.
final class DocumentRoot: @unchecked Sendable {
    private let lock = NSLock()
    private var directory: URL?
    private var roots: [URL] = []
    private var served: [URL: FileStamp] = [:]
    var url: URL? {
        get { lock.withLock { directory } }
        set { lock.withLock { directory = newValue; served = [:] } }
    }
    /// Open workspace folders: besides the document's own folder, a link to a Markdown file under one of these opens in the app.
    var workspaceRoots: [URL] {
        get { lock.withLock { roots } }
        set { lock.withLock { roots = newValue } }
    }

    /// A file the page just asked for (`stamp` taken before it was read, so a change in between shows up as changed).
    func served(_ file: URL, stamp: FileStamp) { lock.withLock { served[file] = stamp } }

    /// The files the page loaded from the document's folder whose size or date is not what it was at load time.
    func changedServedFiles() -> [URL] {
        let snapshot = lock.withLock { served }
        return snapshot.filter { FileStamp(of: $0.key) != $0.value }.map(\.key)
    }

    /// The page is being rebuilt: it will ask for what it shows again.
    func forgetServedFiles() { lock.withLock { served = [:] } }
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
            case .file(let f):
                file = f
                documentRoot.served(f, stamp: FileStamp(of: f))
            case .forbidden: file = nil; status = 403
            case .notFound: file = nil
            }
        default:
            file = nil
        }
        guard let file, var data = try? Data(contentsOf: file) else { return (status, "text/plain", nil) }
        if url.host == "app", url.path == "/preview.html" {
            // The switch is read on every load of the page, so a change in Settings only needs the page reloaded.
            data = Self.withNonce(data, blockRemoteImages: RemoteContent.blocksImages(in: AppDefaults.store))
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return (200, mime, data)
    }

    /// Every load of the page gets a fresh CSP nonce: the `<meta>` policy and our `<script nonce>` tags share it,
    /// so only the tags in this file run (CSP only; the bundles themselves are not user-controlled).
    static func withNonce(_ html: Data, blockRemoteImages: Bool = false) -> Data {
        guard let text = String(data: html, encoding: .utf8) else { return html }
        var page = RemoteContent.previewPage(text, blockingImages: blockRemoteImages)
        #if DEBUG
        page = withRenderCrossCheck(page)
        #endif
        return Data(page.replacingOccurrences(of: nonceToken, with: UUID().uuidString).utf8)
    }

    #if DEBUG
    /// Debug builds have the page compare every 20th incremental render with a whole render (Web/src/render/incremental.ts);
    /// a difference is logged as "preview render error: incremental render differs …". `MACDOWN2_RENDER_CROSSCHECK=<n>` sets
    /// the interval, 0 turns it off. Release builds never check.
    static func withRenderCrossCheck(_ page: String) -> String {
        let every = ProcessInfo.processInfo.environment["MACDOWN2_RENDER_CROSSCHECK"].flatMap { Int($0) } ?? 20
        guard every > 0 else { return page }
        return page.replacingOccurrences(of: "<head>", with: "<head>\n<meta name=\"md2-render-crosscheck\" content=\"\(every)\">")
    }
    #endif

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
