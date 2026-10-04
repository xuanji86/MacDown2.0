import AppKit
import Foundation
import MarkdownCore
import PDFKit
import Testing

@testable import PrintKit

private let fixture = """
# 中文标题 Title

你好，世界。这是一段可以搜索和选择的中文文本，页面和文件都要能找到。See [the second page](#second-page) and [the web](https://example.com/).

```swift
let averyLongIdentifierThatWouldRunOffThePaperIfCodeBlocksDidNotWrapTheyShouldWrapInsteadOfBeingCutOffAtTheEdge = "END-OF-LONG-LINE"
```

| 名称 | Value |
|---|---|
| 文件 | one |
| 一二三 | two |

\\newpage

## Second page

after the break
"""

private func page(_ markdown: String, userCSS: String? = nil) async throws -> String {
    let html = try await JSCRenderer().render(markdown, options: RenderOptions()).html
    return HTMLExporter.document(body: html, title: "t", userCSS: userCSS)
}

@MainActor private func pdf(_ markdown: String, setup: PageSetup = PageSetup(locale: Locale(identifier: "en_US")), userCSS: String? = nil) async throws -> PDFDocument {
    PrintPage.becomeHeadless()
    let data = try await PrintPage.pdf(html: try await page(markdown, userCSS: userCSS), setup: setup)
    return try #require(PDFDocument(data: data))
}

@MainActor @Suite(.serialized) struct PDFTests {
    @Test func producesPaginatedPagesWithTheTextInThem() async throws {
        let doc = try await pdf(fixture)
        #expect(doc.pageCount == 2)  // the \newpage
        let text = try #require(doc.string)
        #expect(text.contains("Title") && text.contains("after the break"))
        #expect(text.contains("END-OF-LONG-LINE"))  // the long code line wrapped inside the page instead of being cut off
        #expect(try #require(doc.page(at: 0)?.string).contains("Second page") == false)  // and the break really moved it
        #expect(try #require(doc.page(at: 1)?.string).contains("Second page"))
    }

    @Test func cjkTextIsSearchableByTheRealCharacters() async throws {
        let doc = try await pdf(fixture)
        // The system CJK fonts write Kangxi radicals (⽂ for 文) into the text layer; print.css avoids them.
        for word in ["中文标题", "中文文本", "页面和文件", "一二三", "文件"] {
            #expect(!doc.findString(word, withOptions: []).isEmpty, "\(word) not found")
        }
        let text = try #require(doc.string)
        #expect(!text.unicodeScalars.contains { (0x2F00...0x2FDF).contains($0.value) || (0x2E80...0x2EFF).contains($0.value) }, "Kangxi/CJK radical code points in the text layer")
    }

    @Test func linksInsideTheDocumentStayLinksInThePDF() async throws {
        let doc = try await pdf(fixture)
        let annotations = (0..<doc.pageCount).flatMap { doc.page(at: $0)?.annotations ?? [] }
        let jump = try #require(annotations.first { $0.destination != nil })
        #expect(jump.destination.flatMap { $0.page.map(doc.index(for:)) } == 1)  // the heading on page 2
        #expect(annotations.contains { $0.url?.absoluteString == "https://example.com/" })
    }

    @Test func paperSizeOrientationAndMarginsAreTheSettings() async throws {
        var setup = PageSetup(locale: Locale(identifier: "en_US"))
        setup.paper = .a4
        var doc = try await pdf("hello", setup: setup)
        var size = try #require(doc.page(at: 0)).bounds(for: .mediaBox).size
        #expect(abs(size.width - 595.28) < 1 && abs(size.height - 841.89) < 1)

        setup.orientation = .landscape
        doc = try await pdf("hello", setup: setup)
        size = try #require(doc.page(at: 0)).bounds(for: .mediaBox).size
        #expect(abs(size.width - 841.89) < 1 && abs(size.height - 595.28) < 1)

        // The text starts inside the margin: 2 in on the left puts it at x >= 144 pt.
        setup.orientation = .portrait
        setup.left = 144
        setup.top = 144
        doc = try await pdf("hello", setup: setup)
        let selection = try #require(doc.findString("hello", withOptions: []).first)
        let box = selection.bounds(for: try #require(doc.page(at: 0)))
        #expect(box.minX >= 143 && (841.89 - box.maxY) >= 143)
    }

    @Test func aShortMarkdownFileIsOnePageAndAnEmptyOneStillWorks() async throws {
        #expect(try await pdf("# One\n\ntext").pageCount == 1)
        #expect(try await pdf("").pageCount >= 1)
    }

    @Test func printSettingsRoundTripThroughThePrintInfo() {
        var setup = PageSetup(locale: Locale(identifier: "en_US"))
        setup.paper = .a3
        setup.orientation = .landscape
        setup.top = 10
        setup.right = 20
        setup.bottom = 30
        setup.left = 40
        let back = PrintPage.pageSetup(from: PrintPage.printInfo(setup, base: NSPrintInfo(dictionary: [:])), previous: PageSetup(locale: Locale(identifier: "en_US")))
        #expect(back == setup)
    }
}
