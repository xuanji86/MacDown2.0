import SwiftUI
import UniformTypeIdentifiers

enum LineEnding: Sendable {
    case lf, crlf
}

/// What `snapshot` hands to the (non-main-actor) writer.
struct DocumentSnapshot: Sendable {
    var text: String
    var lineEnding: LineEnding
    var hasBOM: Bool
}

/// UTF-8 Markdown file. The editor always works on LF text; the original line-ending style and BOM are
/// remembered at read time and restored on save.
final class MarkdownDocument: ReferenceFileDocument, @unchecked Sendable {
    // @unchecked: `text` is only touched from the main actor (editor delegate, preview, snapshot).
    static let readableContentTypes: [UTType] = [.markdown]

    @Published var text: String
    let lineEnding: LineEnding
    let hasBOM: Bool

    init() {
        text = ""
        lineEnding = .lf
        hasBOM = false
    }

    required init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        let bom = Data([0xEF, 0xBB, 0xBF])
        hasBOM = data.starts(with: bom)
        // Strict decode: invalid UTF-8 must fail the open, never silently corrupt on the next save.
        guard let raw = String(data: hasBOM ? data.dropFirst(bom.count) : data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        lineEnding = raw.contains("\r\n") ? .crlf : .lf
        text = Self.normalized(raw)
    }

    func snapshot(contentType: UTType) throws -> DocumentSnapshot {
        DocumentSnapshot(text: text, lineEnding: lineEnding, hasBOM: hasBOM)
    }

    func fileWrapper(snapshot: DocumentSnapshot, configuration: WriteConfiguration) throws -> FileWrapper {
        var out = Self.normalized(snapshot.text)  // pasted text may carry CRLF; settle on LF first
        if snapshot.lineEnding == .crlf { out = out.replacingOccurrences(of: "\n", with: "\r\n") }
        var data = Data(out.utf8)
        if snapshot.hasBOM { data.insert(contentsOf: [0xEF, 0xBB, 0xBF], at: 0) }
        return FileWrapper(regularFileWithContents: data)
    }

    // Foundation replace works on UTF-16, so "\r\n" is not treated as one Character like in Swift's own String API.
    static func normalized(_ s: String) -> String { s.replacingOccurrences(of: "\r\n", with: "\n") }
}
