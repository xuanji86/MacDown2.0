import Foundation
import MarkdownCore
import os
import QuickLookUI
import UniformTypeIdentifiers

/// Data-based Quick Look preview: render the file with the same JS bundle the app uses (in JavaScriptCore, no WebKit),
/// and hand Quick Look one static HTML page. The page logic lives in `MarkdownCore.QuickLookPage`.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    private static let log = Logger(subsystem: "io.github.xuanji86.MacDown2.QuickLook", category: "preview")

    private static func ms(_ d: Duration) -> Int { Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000) }

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let started = ContinuousClock.now
        // Bounded read: a multi-GB file must not be pulled into memory just to show its first page.
        let handle = try FileHandle(forReadingFrom: request.fileURL)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: QuickLookPage.maxBytes + 1) ?? Data()

        let utType = (try? request.fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier) ?? "net.daringfireball.markdown"

        // Per request on purpose: a fresh context costs ~one bundle evaluation, and nothing leaks between previews.
        let renderer = try JSCRenderer()
        let ready = ContinuousClock.now
        let page = try await QuickLookPage.make(data: data, utType: utType, renderer: renderer)
        let done = ContinuousClock.now
        Self.log.info("rendered \(data.count, privacy: .public) bytes: total \(Self.ms(done - started), privacy: .public) ms (JS context \(Self.ms(ready - started), privacy: .public), render+page \(Self.ms(done - ready), privacy: .public)), truncated=\(page.truncated, privacy: .public)")

        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 900, height: 700)) { reply in
            reply.stringEncoding = .utf8
            for a in page.attachments {
                reply.attachments[a.id] = QLPreviewReplyAttachment(data: a.data, contentType: UTType(filenameExtension: a.fileExtension) ?? .data)
            }
            return Data(page.html.utf8)
        }
        return reply
    }
}
