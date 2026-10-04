import Foundation
import Testing
@testable import MarkdownCore

@Suite struct MarkdownFileTests {
    @Test func plainLFFileRoundTripsByteForByte() throws {
        let data = Data("# Title\n\nbody\n".utf8)
        let file = try MarkdownFile.decode(data)
        #expect(file == MarkdownFile(text: "# Title\n\nbody\n"))
        #expect(file.encoded() == data)
    }

    @Test func crlfIsEditedAsLFAndWrittenBackAsCRLF() throws {
        let data = Data("a\r\nb\r\n".utf8)
        let file = try MarkdownFile.decode(data)
        #expect(file.text == "a\nb\n")
        #expect(file.lineEnding == .crlf)
        #expect(file.encoded() == data)
    }

    @Test func textPastedWithCRLFIntoAnLFFileIsSettledToLF() {
        let file = MarkdownFile(text: "a\r\nb\n", lineEnding: .lf)
        #expect(file.encoded() == Data("a\nb\n".utf8))
        // ...and does not double up in a CRLF file
        #expect(MarkdownFile(text: "a\r\nb\n", lineEnding: .crlf).encoded() == Data("a\r\nb\r\n".utf8))
    }

    @Test func bomIsRememberedAndRestored() throws {
        let data = Data([0xEF, 0xBB, 0xBF] + Array("hi\n".utf8))
        let file = try MarkdownFile.decode(data)
        #expect(file.hasBOM)
        #expect(file.text == "hi\n")  // the BOM is not part of the text
        #expect(file.encoded() == data)
        #expect(try MarkdownFile.decode(Data("hi\n".utf8)).hasBOM == false)
    }

    @Test func invalidUTF8FailsInsteadOfCorrupting() {
        #expect(throws: (any Error).self) { try MarkdownFile.decode(Data([0x68, 0xFF, 0xFE, 0x69])) }
    }

    @Test func emptyFileAndCJKSurvive() throws {
        #expect(try MarkdownFile.decode(Data()) == MarkdownFile())
        let cjk = Data("中文 🇯🇵\n".utf8)
        #expect(try MarkdownFile.decode(cjk).encoded() == cjk)
    }
}
