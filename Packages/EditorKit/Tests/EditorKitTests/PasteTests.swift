import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import EditorKit

@MainActor
private final class PasteUndo: NSObject, NSTextViewDelegate {
    let manager = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { manager }
}

/// Image bytes for tests: a small solid image in the requested format.
private enum Fixture {
    static func bitmap(width: Int = 4, height: Int = 3) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<width { for y in 0..<height { rep.setColor(NSColor(red: 1, green: 0, blue: 0, alpha: 1), atX: x, y: y) } }
        return rep
    }
    static func png() -> Data { bitmap().representation(using: .png, properties: [:])! }
    static func jpeg() -> Data { bitmap().representation(using: .jpeg, properties: [:])! }
    static func tiff() -> Data { bitmap().tiffRepresentation! }
    /// HEIC through ImageIO (available on Apple Silicon and recent Intel Macs); nil where the encoder is missing.
    static func heic() -> Data? {
        let out = NSMutableData()
        guard let cg = bitmap().cgImage, let dest = CGImageDestinationCreateWithData(out, UTType.heic.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
    static func isPNG(_ d: Data) -> Bool { d.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) }
    static func isJPEG(_ d: Data) -> Bool { d.prefix(2) == Data([0xFF, 0xD8]) }

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "md2-paste-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func board() -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("macdown2.paste.\(UUID().uuidString)"))
        board.clearContents()
        return board
    }
}

struct PasteImageTests {
    // MARK: Naming

    @Test func nameIsDateTimeWithAsciiDigits() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        calendar.locale = Locale(identifier: "ar_SA")  // digits must not follow the locale
        let date = Date(timeIntervalSince1970: 1_791_000_000)  // 2026-10-03 04:00:00 UTC = 2026-10-02 21:00:00 PDT
        #expect(PasteImage.baseName(for: date, calendar: calendar) == "image-20261002-210000")
    }

    // MARK: Encoding

    @Test func pngAndJpegKeepTheirBytes() {
        let png = Fixture.png(), jpeg = Fixture.jpeg()
        #expect(PasteImage.encode(png, type: .png) == PastedImage(data: png, fileExtension: "png"))
        #expect(PasteImage.encode(jpeg, type: .jpeg) == PastedImage(data: jpeg, fileExtension: "jpg"))
    }

    @Test func tiffBecomesPNG() throws {
        let image = try #require(PasteImage.encode(Fixture.tiff(), type: .tiff))
        #expect(image.fileExtension == "png")
        #expect(Fixture.isPNG(image.data))
        let rep = try #require(NSBitmapImageRep(data: image.data))
        #expect(rep.pixelsWide == 4 && rep.pixelsHigh == 3)
    }

    @Test func heicBecomesPNG() throws {
        guard let heic = Fixture.heic() else { return }  // no HEIC encoder on this machine
        let image = try #require(PasteImage.encode(heic, type: .heic))
        #expect(image.fileExtension == "png" && Fixture.isPNG(image.data))
    }

    @Test func nonImagesAreRefused() {
        #expect(PasteImage.encode(Data("hello".utf8), type: .png) == nil)
        #expect(PasteImage.encode(Data(), type: .png) == nil)
        #expect(PasteImage.encode(Data("<html></html>".utf8), type: .svg) == nil)
        #expect(PasteImage.encode(Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8), type: .svg)?.fileExtension == "svg")
    }

    // MARK: Writing

    @Test func createsTheImagesFolderAndNeverOverwrites() throws {
        let folder = try Fixture.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = PastedImage(data: Fixture.png(), fileExtension: "png")
        let date = Date(timeIntervalSince1970: 1_791_000_000)
        let first = try PasteImage.write(image, besideDocumentIn: folder, date: date)
        let second = try PasteImage.write(image, besideDocumentIn: folder, date: date)  // same second
        let third = try PasteImage.write(image, besideDocumentIn: folder, date: date)
        #expect(first.hasPrefix("images/image-") && first.hasSuffix(".png"))
        #expect(second == first.replacingOccurrences(of: ".png", with: "-2.png"))
        #expect(third == first.replacingOccurrences(of: ".png", with: "-3.png"))
        #expect(try Data(contentsOf: folder.appending(path: first)) == image.data)

        // A file that is already there is left alone.
        let taken = folder.appending(path: "images").appending(path: second.replacingOccurrences(of: "images/", with: "").replacingOccurrences(of: "-2.png", with: "-4.png"))
        try Data("mine".utf8).write(to: taken)
        let fourth = try PasteImage.write(image, besideDocumentIn: folder, date: date)
        #expect(fourth.hasSuffix("-5.png"))
        #expect(try String(contentsOf: taken, encoding: .utf8) == "mine")
    }

    @Test func imagesThatIsAFileIsAnError() throws {
        let folder = try Fixture.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("x".utf8).write(to: folder.appending(path: "images"))
        #expect(throws: PasteImageError.self) { try PasteImage.write(PastedImage(data: Fixture.png(), fileExtension: "png"), besideDocumentIn: folder) }
    }

    @Test func aRefusedFolderIsNotCreated() throws {
        let folder = try Fixture.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: PasteImageError.self) {
            try PasteImage.write(PastedImage(data: Fixture.png(), fileExtension: "png"), besideDocumentIn: folder, permits: { _ in false })
        }
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "images").path))
    }

    // MARK: Pasteboard

    @Test func screenshotOnThePasteboardIsAnImage() throws {
        let board = Fixture.board()
        defer { board.releaseGlobally() }
        board.setData(Fixture.tiff(), forType: .tiff)
        board.setData(Fixture.png(), forType: .png)
        let images = try #require(try PasteImage.images(on: board))
        #expect(images.count == 1 && images[0].fileExtension == "png")
        #expect(images[0].data == Fixture.png() || Fixture.isPNG(images[0].data))
    }

    @Test func tiffOnlyPasteboardIsConverted() throws {
        let board = Fixture.board()
        defer { board.releaseGlobally() }
        board.setData(Fixture.tiff(), forType: .tiff)
        let images = try #require(try PasteImage.images(on: board))
        #expect(Fixture.isPNG(images[0].data))
    }

    @Test func textBesideAnImageStaysAText() throws {
        let board = Fixture.board()
        defer { board.releaseGlobally() }
        board.setString("A1\tB1", forType: .string)
        board.setData(Fixture.png(), forType: .png)  // a spreadsheet range also carries a picture of itself
        #expect(try PasteImage.images(on: board) == nil)
    }

    @Test func plainTextIsNotAnImage() throws {
        let board = Fixture.board()
        defer { board.releaseGlobally() }
        board.setString("hello", forType: .string)
        #expect(try PasteImage.images(on: board) == nil)
    }

    @Test func imageFilesCopiedInFinderAreRead() throws {
        let folder = try Fixture.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appending(path: "photo.jpeg"), shot = folder.appending(path: "shot.tiff")
        try Fixture.jpeg().write(to: photo)
        try Fixture.tiff().write(to: shot)
        let board = Fixture.board()
        defer { board.releaseGlobally() }
        board.writeObjects([photo as NSURL, shot as NSURL])
        board.setString("photo.jpeg", forType: .string)  // Finder also puts the names there
        let images = try #require(try PasteImage.images(on: board))
        #expect(images.map(\.fileExtension) == ["jpg", "png"])
        #expect(Fixture.isJPEG(images[0].data) && Fixture.isPNG(images[1].data))
    }

    @Test func aMixOfImageAndOtherFilesIsNotAnImagePaste() throws {
        let folder = try Fixture.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appending(path: "photo.png"), notes = folder.appending(path: "notes.txt")
        try Fixture.png().write(to: photo)
        try Data("n".utf8).write(to: notes)
        let board = Fixture.board()
        defer { board.releaseGlobally() }
        board.writeObjects([photo as NSURL, notes as NSURL])
        #expect(try PasteImage.images(on: board) == nil)
    }

    @Test func aFileThatIsNotReallyAnImageThrows() throws {
        let folder = try Fixture.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fake = folder.appending(path: "fake.png")
        try Data("not a png".utf8).write(to: fake)
        let board = Fixture.board()
        defer { board.releaseGlobally() }
        board.writeObjects([fake as NSURL])
        #expect(throws: PasteImageError.self) { try PasteImage.images(on: board) }
    }

    @Test func aFileOutsideThePermittedRootIsNotRead() throws {
        let folder = try Fixture.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appending(path: "photo.png")
        try Fixture.png().write(to: photo)
        let board = Fixture.board()
        defer { board.releaseGlobally() }
        board.writeObjects([photo as NSURL])
        #expect(throws: PasteImageError.self) { try PasteImage.images(on: board, permits: { _ in false }) }
    }

    // MARK: Markdown

    @Test func linkTextAndCaret() {
        let edit = PasteImage.edit(forPaths: ["images/a.png", "images/b.png"], replacing: NSRange(location: 3, length: 2))
        #expect(edit.replacement == "![](images/a.png)\n![](images/b.png)")
        #expect(edit.range == NSRange(location: 3, length: 2))
        #expect(edit.selection == NSRange(location: 3 + edit.replacement.utf16.count, length: 0))
    }
}

struct SmartPasteTests {
    private func edit(_ clipboard: String, _ text: String, _ selection: NSRange) -> TextEdit? {
        SmartPaste.linkEdit(clipboard: clipboard, selection: selection, in: text as NSString)
    }

    @Test func urlOverSelectionBecomesALink() {
        let e = edit("https://example.com/a?b=1", "see the docs now", NSRange(location: 8, length: 4))
        #expect(e?.replacement == "[docs](https://example.com/a?b=1)")
        #expect(e?.range == NSRange(location: 8, length: 4))
        #expect(e?.selection == NSRange(location: 8 + "[docs](https://example.com/a?b=1)".utf16.count, length: 0))
    }

    @Test func surroundingBlanksOfTheURLAreIgnoredAndCJKWorks() {
        #expect(edit("  https://example.com\n", "中文文档", NSRange(location: 0, length: 4))?.replacement == "[中文文档](https://example.com)")
        #expect(edit("mailto:a@b.com", "me", NSRange(location: 0, length: 2))?.replacement == "[me](mailto:a@b.com)")
    }

    @Test func ordinaryPastesStayOrdinary() {
        let text = "some words here"
        let word = NSRange(location: 5, length: 5)
        #expect(edit("https://example.com", text, NSRange(location: 5, length: 0)) == nil)  // no selection
        #expect(edit("example.com", text, word) == nil)  // no scheme
        #expect(edit("https://example.com and more", text, word) == nil)  // not only a URL
        #expect(edit("https://example.com\nhttps://b.com", text, word) == nil)  // two URLs
        #expect(edit("javascript:alert(1)", text, word) == nil)
        #expect(edit("file:///etc/passwd", text, word) == nil)
        #expect(edit("https://", text, word) == nil)  // no host
        #expect(edit("hello", text, word) == nil)
        #expect(edit("https://example.com", "a\nb", NSRange(location: 0, length: 3)) == nil)  // spans lines
        #expect(edit("https://example.com", "a [b] c", NSRange(location: 2, length: 3)) == nil)  // brackets would need escaping
        #expect(edit("https://example.com", "   ", NSRange(location: 0, length: 3)) == nil)  // blank
        #expect(edit("https://b.com", "https://a.com", NSRange(location: 0, length: 13)) == nil)  // replacing a URL by a URL
        #expect(edit("https://example.com", "abc", NSRange(location: 2, length: 5)) == nil)  // stale range
    }

    @Test func unbalancedParenthesesInTheURLAreEncoded() {
        #expect(SmartPaste.url(in: "https://en.wikipedia.org/wiki/Foo_(bar)") == "https://en.wikipedia.org/wiki/Foo_(bar)")
        #expect(SmartPaste.url(in: "https://example.com/a)b") == "https://example.com/a%29b")
        #expect(SmartPaste.url(in: "https://example.com/a(b") == "https://example.com/a%28b")
    }
}

@MainActor
struct PasteViewTests {
    private let undo = PasteUndo()

    private func makeView(_ text: String, selection: NSRange, documentURL: URL?) -> MarkdownTextView {
        let view = ViewTests.makeSizedView(text)
        view.delegate = undo
        view.setSelectedRange(selection)
        view.documentURL = { documentURL }
        return view
    }

    @Test func pastingAnImageSavesItAndInsertsTheLinkAsOneUndoStep() throws {
        let folder = try Fixture.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let view = makeView("before after", selection: NSRange(location: 7, length: 0), documentURL: folder.appending(path: "doc.md"))
        let board = Fixture.board()
        defer { board.releaseGlobally() }
        board.setData(Fixture.tiff(), forType: .tiff)

        #expect(view.pasteIfSmart(from: board))
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "images").path)
        #expect(files.count == 1 && files[0].hasPrefix("image-") && files[0].hasSuffix(".png"))
        let link = "![](images/\(files[0]))"
        #expect(view.string == "before \(link)after")
        #expect(view.selectedRange() == NSRange(location: 7 + link.utf16.count, length: 0))  // caret after the link

        undo.manager.undo()
        #expect(view.string == "before after")
        #expect(!undo.manager.canUndo)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "images").appending(path: files[0]).path), "the file stays")
    }

    @Test func anUnsavedDocumentWritesNothingAndAsksToSave() throws {
        let view = makeView("text", selection: NSRange(location: 4, length: 0), documentURL: nil)
        var problems: [String] = []
        view.onPasteImageProblem = { problem in
            if case .needsSavedDocument = problem { problems.append("save") } else { problems.append("other") }
        }
        let board = Fixture.board()
        defer { board.releaseGlobally() }
        board.setData(Fixture.png(), forType: .png)
        #expect(view.pasteIfSmart(from: board))
        #expect(problems == ["save"])
        #expect(view.string == "text")
    }

    @Test func aRefusedFolderReportsAndInsertsNothing() throws {
        let folder = try Fixture.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let view = makeView("text", selection: NSRange(location: 4, length: 0), documentURL: folder.appending(path: "doc.md"))
        view.pastePermits = { _ in false }
        var failed = false
        view.onPasteImageProblem = { if case .failed = $0 { failed = true } }
        let board = Fixture.board()
        defer { board.releaseGlobally() }
        board.setData(Fixture.png(), forType: .png)
        #expect(view.pasteIfSmart(from: board))
        #expect(failed)
        #expect(view.string == "text")
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "images").path))
    }

    @Test func withoutADocumentHookImagesAreNotHandled() {
        let view = ViewTests.makeSizedView("text")  // documentURL not set: image paste is off
        let board = Fixture.board()
        defer { board.releaseGlobally() }
        board.setData(Fixture.png(), forType: .png)
        #expect(!view.pasteIfSmart(from: board))
    }

    @Test func plainTextPasteIsLeftToTheSystem() {
        let view = makeView("some text", selection: NSRange(location: 0, length: 4), documentURL: URL(filePath: "/tmp/x/doc.md"))
        let board = Fixture.board()
        defer { board.releaseGlobally() }
        board.setString("plain words", forType: .string)
        #expect(!view.pasteIfSmart(from: board))
        board.clearContents()
        board.setString("https://example.com", forType: .string)
        #expect(view.pasteIfSmart(from: board))
        #expect(view.string == "[some](https://example.com) text")
        undo.manager.undo()
        #expect(view.string == "some text")
    }
}
