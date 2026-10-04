import Foundation
import MarkdownCore
import PDFKit
import Testing

@testable import PrintKit

/// Where a page boundary falls depends on the text above it, so each case is tried with the block at 24 different heights
/// (16 filler paragraphs +/- one, and a last paragraph of 1 to 8 lines): with the rules in print.css / PrintPage switched
/// off, a loop like this does split code blocks, tables and headings from their text (checked when they were written).
@MainActor @Suite(.serialized) struct PaginationTests {
    private func pages(_ markdown: String) async throws -> [String] {
        let html = try await JSCRenderer().render(markdown, options: RenderOptions()).html
        let data = try await PrintPage.pdf(html: HTMLExporter.document(body: html, title: "t"), setup: PageSetup(locale: Locale(identifier: "en_US")))
        let doc = try #require(PDFDocument(data: data))
        return (0..<doc.pageCount).map { doc.page(at: $0)?.string ?? "" }
    }

    private func filler(paragraphs n: Int, tailLines k: Int) -> String {
        (1...n).map { "filler line \($0)\n" }.joined(separator: "\n") + "\n" + (1...k).map { "tail line \($0)" }.joined(separator: "  \n") + "\n\n"
    }

    private func heights(_ body: (String) async throws -> Void) async throws {
        PrintPage.becomeHeadless()
        for n in 14...16 { for k in 1...8 { try await body(filler(paragraphs: n, tailLines: k)) } }
    }

    @Test func aCodeBlockIsNeverSplitAcrossPages() async throws {
        let code = "```\n" + (1...8).map { "code row \($0)" }.joined(separator: "\n") + "\n```\n"
        try await heights { above in
            let p = try await pages(above + code)
            if p.count > 1 { #expect(!(p[0].contains("code row") && p[1].contains("code row")), "code split after \(above.count) characters") }
        }
    }

    @Test func aShortTableIsNeverSplitAcrossPages() async throws {
        let table = "| a | b |\n|---|---|\n" + (1...6).map { "| cell\($0) | v\($0) |" }.joined(separator: "\n") + "\n"
        try await heights { above in
            let p = try await pages(above + table)
            if p.count > 1 { #expect(!(p[0].contains("cell") && p[1].contains("cell")), "table split after \(above.count) characters") }
        }
    }

    @Test func aHeadingIsNeverAloneAtTheFootOfAPage() async throws {
        try await heights { above in
            let p = try await pages(above + "## HEADING-X\n\nthe paragraph after the heading\n")
            if p.count > 1 { #expect(!(p[0].contains("HEADING-X") && !p[0].contains("the paragraph after")), "heading orphaned after \(above.count) characters") }
        }
    }
}
