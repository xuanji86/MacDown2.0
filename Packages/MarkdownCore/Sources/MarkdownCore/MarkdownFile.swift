import CoreFoundation
import Foundation

public enum LineEnding: Sendable, Equatable {
    case lf, crlf
    /// A bare carriage return: classic Mac OS.
    case cr

    public var displayName: String {
        switch self {
        case .lf: "LF"
        case .crlf: "CRLF"
        case .cr: "CR"
        }
    }

    fileprivate var terminator: String {
        switch self {
        case .lf: "\n"
        case .crlf: "\r\n"
        case .cr: "\r"
        }
    }
}

/// The text encodings a Markdown file can be read and written in. Everything the editor sees is Unicode text; this is
/// only how it is turned into bytes on disk.
public enum TextEncoding: Sendable, Equatable, CaseIterable {
    case utf8, utf16LE, utf16BE, gb18030, shiftJIS, windows1252, macRoman

    public var displayName: String {
        switch self {
        case .utf8: "UTF-8"
        case .utf16LE: "UTF-16 LE"
        case .utf16BE: "UTF-16 BE"
        case .gb18030: "GB18030"
        case .shiftJIS: "Shift_JIS"
        case .windows1252: "Windows-1252"
        case .macRoman: "Mac Roman"
        }
    }

    var stringEncoding: String.Encoding {
        switch self {
        case .utf8: .utf8
        case .utf16LE: .utf16LittleEndian
        case .utf16BE: .utf16BigEndian
        case .gb18030:
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case .shiftJIS: .shiftJIS
        case .windows1252: .windowsCP1252
        case .macRoman: .macOSRoman
        }
    }

    /// The byte-order mark of the Unicode encodings; empty for the legacy ones, which have none.
    fileprivate var bom: Data {
        switch self {
        case .utf8: Data([0xEF, 0xBB, 0xBF])
        case .utf16LE: Data([0xFF, 0xFE])
        case .utf16BE: Data([0xFE, 0xFF])
        default: Data()
        }
    }

    /// Tried in this order, after UTF-8 and BOM-marked UTF-16, when the bytes are not valid UTF-8. Mac Roman is last
    /// because it defines every byte value: anything not claimed earlier ends up there instead of failing to open.
    static let legacyFallbacks: [TextEncoding] = [.gb18030, .shiftJIS, .windows1252, .macRoman]
}

/// A Markdown file as the editor sees it: always LF text, with the file's own encoding, line-ending style and BOM
/// remembered so saving restores them byte for byte. Pure functions, shared by the document class and the tests.
public struct MarkdownFile: Sendable, Equatable {
    public var text: String
    public var lineEnding: LineEnding
    public var encoding: TextEncoding
    public var hasBOM: Bool

    public init(text: String = "", lineEnding: LineEnding = .lf, encoding: TextEncoding = .utf8, hasBOM: Bool = false) {
        self.text = text
        self.lineEnding = lineEnding
        self.encoding = encoding
        self.hasBOM = hasBOM
    }

    public enum EncodeError: Error, Equatable {
        /// The text has characters the file's encoding cannot represent. Nothing is written; `characters` lists some of them.
        case unrepresentable(encoding: TextEncoding, characters: [Character])
    }

    /// "UTF-8 · LF": what the status bar shows.
    public var formatLabel: String {
        "\(encoding.displayName)\(hasBOM && encoding == .utf8 ? " BOM" : "") · \(lineEnding.displayName)"
    }

    // MARK: Reading

    /// Picks the encoding: UTF-8 (BOM or not), then UTF-16 by its BOM, then, when the bytes are not valid UTF-8, the legacy
    /// encodings in `TextEncoding.legacyFallbacks`. UTF-16 without a BOM is not guessed. A legacy encoding is only accepted when writing the text back gives
    /// exactly the bytes that were read, so what is opened can always be saved without change. It is still a guess: the
    /// user can reopen the file in another encoding (`decode(_:as:)`).
    public static func decode(_ data: Data) throws -> MarkdownFile {
        if let file = try? decode(data, as: .utf8) { return file }
        // FF FE 00 00 is a UTF-32 BOM, not UTF-16 text starting with NUL: leave it to the fallbacks.
        let utf32LE = data.starts(with: [0xFF, 0xFE, 0x00, 0x00])
        for encoding in [TextEncoding.utf16LE, .utf16BE] where data.starts(with: encoding.bom) && !utf32LE {
            if let file = try? decode(data, as: encoding) { return file }
        }
        // A NUL byte means this is not text in any single-byte or CJK encoding (typically UTF-16 without a BOM): refuse, do not garble.
        if !data.contains(0) {
            for encoding in TextEncoding.legacyFallbacks {
                if let file = try? decode(data, as: encoding) { return file }
            }
        }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }

    /// Strict decode in one given encoding (a BOM of that encoding is stripped and remembered). Fails when the bytes are not
    /// valid in it or would not write back identically, so a wrong choice cannot silently corrupt the file.
    public static func decode(_ data: Data, as encoding: TextEncoding) throws -> MarkdownFile {
        let hasBOM = !encoding.bom.isEmpty && data.starts(with: encoding.bom)
        let body = hasBOM ? data.dropFirst(encoding.bom.count) : data[...]
        guard let raw = String(data: body, encoding: encoding.stringEncoding) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        // UTF-8 that decoded is lossless by construction; everything else is proven.
        if encoding != .utf8, bytes(raw, encoding, hasBOM) != data { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return MarkdownFile(text: normalized(raw), lineEnding: detectLineEnding(raw), encoding: encoding, hasBOM: hasBOM)
    }

    // MARK: Writing

    /// The bytes to write. Throws `EncodeError.unrepresentable` instead of dropping or replacing characters the encoding
    /// has no code for; the caller offers to save as UTF-8 instead.
    public func encoded() throws -> Data {
        var out = Self.normalized(text)  // pasted text may carry CRLF or CR; settle on LF first
        if lineEnding != .lf { out = out.replacingOccurrences(of: "\n", with: lineEnding.terminator) }
        guard let data = Self.bytes(out, encoding, hasBOM) else {
            throw EncodeError.unrepresentable(encoding: encoding, characters: Self.unrepresentable(in: out, encoding))
        }
        return data
    }

    private static func bytes(_ s: String, _ encoding: TextEncoding, _ hasBOM: Bool) -> Data? {
        guard var data = s.data(using: encoding.stringEncoding, allowLossyConversion: false) else { return nil }
        if hasBOM { data.insert(contentsOf: encoding.bom, at: 0) }
        return data
    }

    /// A few distinct characters of `s` that `encoding` cannot hold, in order of appearance (for the message to the user).
    private static func unrepresentable(in s: String, _ encoding: TextEncoding, limit: Int = 8) -> [Character] {
        var seen = Set<Character>(), found: [Character] = []
        for ch in s where seen.insert(ch).inserted && String(ch).data(using: encoding.stringEncoding, allowLossyConversion: false) == nil {
            found.append(ch)
            if found.count == limit { break }
        }
        return found
    }

    // MARK: Line endings

    /// The style a file is saved back in. CRLF if it appears anywhere: a file that mixes CRLF with bare LF or CR is written
    /// out with CRLF throughout (normalising it, the same call the text editors on Windows make). Otherwise CR when the file
    /// has bare CRs and no LF at all (classic Mac), else LF.
    static func detectLineEnding(_ s: String) -> LineEnding {
        var crlf = false, bareCR = false, bareLF = false, afterCR = false
        for byte in s.utf8 {
            if byte == 0x0A {
                if afterCR { crlf = true } else { bareLF = true }
                afterCR = false
            } else {
                if afterCR { bareCR = true }
                afterCR = byte == 0x0D
            }
        }
        if afterCR { bareCR = true }
        if crlf { return .crlf }
        return bareCR && !bareLF ? .cr : .lf
    }

    // Foundation replace works on UTF-16, so "\r\n" is not treated as one Character like in Swift's own String API.
    public static func normalized(_ s: String) -> String {
        guard s.utf8.contains(0x0D) else { return s }
        return s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}
