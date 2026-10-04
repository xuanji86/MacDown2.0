import Foundation
import Testing
@testable import MarkdownCore

@Suite struct MarkdownFileTests {
    @Test func plainLFFileRoundTripsByteForByte() throws {
        let data = Data("# Title\n\nbody\n".utf8)
        let file = try MarkdownFile.decode(data)
        #expect(file == MarkdownFile(text: "# Title\n\nbody\n"))
        #expect(try file.encoded() == data)
    }

    @Test func crlfIsEditedAsLFAndWrittenBackAsCRLF() throws {
        let data = Data("a\r\nb\r\n".utf8)
        let file = try MarkdownFile.decode(data)
        #expect(file.text == "a\nb\n")
        #expect(file.lineEnding == .crlf)
        #expect(try file.encoded() == data)
    }

    @Test func textPastedWithCRLFIntoAnLFFileIsSettledToLF() throws {
        let file = MarkdownFile(text: "a\r\nb\n", lineEnding: .lf)
        #expect(try file.encoded() == Data("a\nb\n".utf8))
        // ...and does not double up in a CRLF file
        #expect(try MarkdownFile(text: "a\r\nb\n", lineEnding: .crlf).encoded() == Data("a\r\nb\r\n".utf8))
    }

    @Test func bomIsRememberedAndRestored() throws {
        let data = Data([0xEF, 0xBB, 0xBF] + Array("hi\n".utf8))
        let file = try MarkdownFile.decode(data)
        #expect(file.hasBOM)
        #expect(file.text == "hi\n")  // the BOM is not part of the text
        #expect(try file.encoded() == data)
        #expect(try MarkdownFile.decode(Data("hi\n".utf8)).hasBOM == false)
    }

    @Test func emptyFileAndCJKSurvive() throws {
        #expect(try MarkdownFile.decode(Data()) == MarkdownFile())
        let cjk = Data("中文 🇯🇵\n".utf8)
        #expect(try MarkdownFile.decode(cjk).encoded() == cjk)
    }

    // MARK: Line endings

    @Test func aBareCRIsAnOldMacLineEndingAndComesBackAsCR() throws {
        let data = Data("a\rb\r\rc".utf8)
        let file = try MarkdownFile.decode(data)
        #expect(file.text == "a\nb\n\nc")
        #expect(file.lineEnding == .cr)
        #expect(try file.encoded() == data)
    }

    @Test func mixedLineEndingsFollowTheDocumentedRule() throws {
        // CRLF anywhere: the whole file is written back with CRLF.
        let withCRLF = try MarkdownFile.decode(Data("a\r\nb\nc\rd".utf8))
        #expect(withCRLF.text == "a\nb\nc\nd")
        #expect(withCRLF.lineEnding == .crlf)
        #expect(try withCRLF.encoded() == Data("a\r\nb\r\nc\r\nd".utf8))
        // Bare LF and bare CR without CRLF: LF wins (CR is only chosen when there is no LF at all).
        #expect(try MarkdownFile.decode(Data("a\nb\rc".utf8)).lineEnding == .lf)
        // A CR at the very end still counts as a CR, a lone CRLF as CRLF.
        #expect(try MarkdownFile.decode(Data("a\r".utf8)).lineEnding == .cr)
        #expect(try MarkdownFile.decode(Data("a\r\n".utf8)).lineEnding == .crlf)
        #expect(try MarkdownFile.decode(Data("no newline".utf8)).lineEnding == .lf)
    }

    @Test func pastedCRIsSettledToTheFilesStyle() throws {
        #expect(try MarkdownFile(text: "a\rb\n", lineEnding: .crlf).encoded() == Data("a\r\nb\r\n".utf8))
        #expect(try MarkdownFile(text: "a\r\nb\rc", lineEnding: .cr).encoded() == Data("a\rb\rc".utf8))
    }

    // MARK: Encodings

    /// Text that is valid in the encoding and, for the legacy ones, not valid UTF-8.
    private static let samples: [(TextEncoding, String)] = [
        (.utf8, "# 标题\n中文 🇯🇵 é\n"),
        (.utf16LE, "# 标题\n中文 🇯🇵 é\n"),
        (.utf16BE, "# 标题\n中文 🇯🇵 é\n"),
        (.gb18030, "# 标题\n中文，你好 𠀀\n"),
        (.shiftJIS, "# 見出し\nこんにちは、世界\n"),
        (.windows1252, "café “quoted” – €5\n"),
        (.macRoman, "Å Ö ∑ ™\n"),
    ]

    @Test(arguments: [LineEnding.lf, .crlf, .cr])
    func everyEncodingAndLineEndingRoundTripsByteForByte(_ ending: LineEnding) throws {
        for (encoding, text) in Self.samples {
            let eol = ending.testTerminator
            let body = text.replacingOccurrences(of: "\n", with: eol)
            for bom in [false, true] where bom ? !encoding.testBOM.isEmpty : true {
                var data = try #require(body.data(using: encoding.stringEncoding))
                if bom { data.insert(contentsOf: encoding.testBOM, at: 0) }
                // Explicitly chosen encoding: always exactly that encoding.
                let chosen = try MarkdownFile.decode(data, as: encoding)
                #expect(chosen.text == text, "\(encoding) \(ending) bom=\(bom)")
                #expect(chosen.lineEnding == ending)
                #expect(chosen.hasBOM == bom)
                #expect(try chosen.encoded() == data, "\(encoding) \(ending) bom=\(bom)")
                // Auto-detected: whichever encoding it guessed, the file saves back unchanged (UTF-16 without a BOM is not guessed).
                if encoding == .utf16LE || encoding == .utf16BE, !bom { continue }
                let guessed = try MarkdownFile.decode(data)
                #expect(try guessed.encoded() == data, "auto \(encoding) \(ending) bom=\(bom)")
            }
        }
    }

    @Test func detectionOrderUTF8ThenUTF16ByBOMThenLegacy() throws {
        func detect(_ s: String, _ e: String.Encoding, bom: [UInt8] = []) throws -> MarkdownFile {
            try MarkdownFile.decode(Data(bom) + #require(s.data(using: e)))
        }
        #expect(try detect("héllo 中文\n", .utf8).encoding == .utf8)
        #expect(try detect("héllo\n", .utf8, bom: [0xEF, 0xBB, 0xBF]) == MarkdownFile(text: "héllo\n", encoding: .utf8, hasBOM: true))
        #expect(try detect("héllo\n", .utf16LittleEndian, bom: [0xFF, 0xFE]) == MarkdownFile(text: "héllo\n", encoding: .utf16LE, hasBOM: true))
        #expect(try detect("héllo\n", .utf16BigEndian, bom: [0xFE, 0xFF]) == MarkdownFile(text: "héllo\n", encoding: .utf16BE, hasBOM: true))
        #expect(try detect("你好，世界\n", .utf8).encoding == .utf8)  // valid UTF-8 always wins over a legacy guess
        #expect(try detect("# 标题\n中文，你好\n", Self.gb18030).encoding == .gb18030)
        #expect(try detect("café “quoted”\n", .windowsCP1252).encoding == .windows1252)
        #expect(try detect("Å Ö\n", .macOSRoman).encoding == .macRoman)  // 0x81 is undefined in Windows-1252
        // Half-width katakana in Shift_JIS are single bytes that GB18030 rejects.
        #expect(try detect("ｱｲｳ\n", .shiftJIS).encoding == .shiftJIS)
    }

    @Test func aWrongExplicitChoiceFailsInsteadOfCorrupting() throws {
        let gbk = try #require("你好".data(using: Self.gb18030))
        #expect(throws: (any Error).self) { try MarkdownFile.decode(gbk, as: .utf8) }
        #expect(throws: (any Error).self) { try MarkdownFile.decode(Data([0x68, 0x00, 0x69]), as: .utf16LE) }  // odd length
    }

    @Test func utf16WithoutABOMAndUTF32AreRefusedNotGarbled() throws {
        // `data(using: .utf32LittleEndian)` carries no BOM of its own; add it.
        let utf32 = Data([0xFF, 0xFE, 0x00, 0x00]) + (try #require("hi 中文\r\n".data(using: .utf32LittleEndian)))
        #expect(throws: (any Error).self) { try MarkdownFile.decode(utf32) }
        let utf16 = try #require("中文 é\r\n".data(using: .utf16LittleEndian))  // no BOM
        #expect(throws: (any Error).self) { try MarkdownFile.decode(utf16) }
        // ...but the user can still pick it explicitly.
        #expect(try MarkdownFile.decode(utf16, as: .utf16LE).text == "中文 é\n")
    }

    @Test func unrepresentableCharactersRefuseToSaveAndNameTheOffenders() throws {
        let file = MarkdownFile(text: "café 😀 你好\n", encoding: .windows1252)
        do {
            _ = try file.encoded()
            Issue.record("must not encode")
        } catch let MarkdownFile.EncodeError.unrepresentable(encoding, characters) {
            #expect(encoding == .windows1252)
            #expect(characters == ["😀", "你", "好"])
        }
        // The same text is fine as UTF-8, with the same line-ending style: that is the offered way out.
        var utf8 = file
        utf8.encoding = .utf8
        #expect(try utf8.encoded() == Data("café 😀 你好\n".utf8))
    }

    @Test func formatLabelShowsEncodingAndLineEnding() {
        #expect(MarkdownFile().formatLabel == "UTF-8 · LF")
        #expect(MarkdownFile(lineEnding: .crlf, encoding: .gb18030).formatLabel == "GB18030 · CRLF")
        #expect(MarkdownFile(lineEnding: .cr, encoding: .utf8, hasBOM: true).formatLabel == "UTF-8 BOM · CR")
    }

    private static let gb18030 = TextEncoding.gb18030.stringEncoding
}

private extension TextEncoding {
    var testBOM: Data { self == .utf8 ? Data([0xEF, 0xBB, 0xBF]) : self == .utf16LE ? Data([0xFF, 0xFE]) : self == .utf16BE ? Data([0xFE, 0xFF]) : Data() }
}

private extension LineEnding {
    var testTerminator: String { self == .lf ? "\n" : self == .crlf ? "\r\n" : "\r" }
}
