import Foundation
import MarkdownCore
import PDFKit
import Testing

@testable import PrintKit

private let us = PageSetup(locale: Locale(identifier: "en_US"))

private func text(of pdf: Data) throws -> String { try #require(PDFDocument(data: pdf)?.string) }

/// The print page is the document's own: nothing in the document may send it somewhere else, and Mermaid (drawn by the app's own
/// script, in its own content world) still works under the page's script-refusing CSP.
@MainActor @Suite(.serialized) struct SafetyTests {
    /// A page of somebody else's the document tries to send the printout to: served from this machine (no network in a test).
    private final class Attacker {
        let process = Process()
        let directory = FileManager.default.temporaryDirectory.appending(path: "PrintKitTests-attacker-\(UUID().uuidString)", directoryHint: .isDirectory)
        let port = Int.random(in: 20000..<60000)
        var markup: String { #"<meta http-equiv="refresh" content="0;url=http://127.0.0.1:\#(port)/attack.html">"# }

        init() throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("<!doctype html><p>ATTACKER-PAGE</p>".utf8).write(to: directory.appending(path: "attack.html"))
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1", "--directory", directory.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            Thread.sleep(forTimeInterval: 1)
        }

        deinit {
            process.terminate()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test func aMetaRefreshIsRemovedBeforeTheLoad() async throws {
        PrintPage.becomeHeadless()
        let attack = try Attacker()
        let html = "<!doctype html><html><head>\(attack.markup)</head><body><p>ORIGINAL-PAGE</p></body></html>"
        let pdf = try await PrintPage.pdf(html: html, setup: us, removingAutoNavigation: true, settle: .seconds(1))
        let text = try text(of: pdf)
        #expect(text.contains("ORIGINAL-PAGE") && !text.contains("ATTACKER-PAGE"))
    }

    @Test func theNavigationPolicyCancelsWhatTheMarkupFilterMissed() async throws {
        PrintPage.becomeHeadless()
        // The filter is switched off here: only the delegate stands between the refresh and the printout.
        let attack = try Attacker()
        let html = "<!doctype html><html><head>\(attack.markup)</head><body><p>ORIGINAL-PAGE</p></body></html>"
        let pdf = try await PrintPage.pdf(html: html, setup: us, removingAutoNavigation: false, settle: .seconds(1))
        let text = try text(of: pdf)
        #expect(text.contains("ORIGINAL-PAGE") && !text.contains("ATTACKER-PAGE"))
    }

    @Test func aHostileDocumentPrintsAsText() async throws {
        PrintPage.becomeHeadless()
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../MarkdownCore/Tests/MarkdownCoreTests/Fixtures/own/hostile.md").standardizedFileURL
        let markdown = try String(contentsOf: url, encoding: .utf8)
        let body = try await JSCRenderer().render(markdown, options: RenderOptions().forExport).html
        let pdf = try await PrintPage.pdf(html: HTMLExporter.document(body: body, title: "hostile"), setup: us, removingAutoNavigation: true, settle: .seconds(1))
        let text = try text(of: pdf)
        #expect(text.contains("Hostile document") && text.contains("Parser stress"))  // the whole document, from its first heading to its last
    }

    @Test func mermaidStillDrawsUnderTheExportCSP() async throws {
        PrintPage.becomeHeadless()
        let body = try await JSCRenderer().render("# Diagram\n\n```mermaid\ngraph TD\n  A[Alpha node] --> B[Beta node]\n```\n", options: RenderOptions().forExport).html
        let page = HTMLExporter.document(body: body, title: "m")
        #expect(page.contains("script-src 'none'"))
        let text = try text(of: try await PrintPage.pdf(html: page, setup: us))
        #expect(text.contains("Alpha node") && text.contains("Beta node"))
        #expect(!text.contains("graph TD"), "the diagram was not drawn: its source is still there")
    }
}
