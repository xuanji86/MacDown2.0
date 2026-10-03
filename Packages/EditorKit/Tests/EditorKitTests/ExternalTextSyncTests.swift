import AppKit
import Testing
@testable import EditorKit

private final class Doc {}

struct ExternalTextSyncTests {
    @Test func theEditorsOwnWritesAreNotReloaded() {
        let doc = Doc()
        var sync = ExternalTextSync(document: doc, text: "a")
        sync.editorDidWrite("ab")
        #expect(sync.reloadText(document: doc, modelText: "ab") == nil)
    }

    @Test func aModelChangeBehindTheEditorsBackIsReloadedOnce() {
        let doc = Doc()
        var sync = ExternalTextSync(document: doc, text: "old")
        #expect(sync.reloadText(document: doc, modelText: "reverted") == "reverted")
        #expect(sync.reloadText(document: doc, modelText: "reverted") == nil)
        // and the next keystroke is compared against the reloaded text, not the stale one
        sync.editorDidWrite("reverted!")
        #expect(sync.reloadText(document: doc, modelText: "reverted!") == nil)
    }

    @Test func aDifferentDocumentInstanceIsDetectedAndReloadedWhenTheTextDiffers() {
        let first = Doc(), second = Doc()
        var sync = ExternalTextSync(document: first, text: "one")
        #expect(sync.isSameDocument(first))
        #expect(!sync.isSameDocument(second))
        #expect(sync.reloadText(document: second, modelText: "two") == "two")
        #expect(sync.isSameDocument(second))
    }

    @Test func aDifferentInstanceWithIdenticalTextKeepsTheEditorAsItIs() {
        let first = Doc(), second = Doc()
        var sync = ExternalTextSync(document: first, text: "same")
        #expect(sync.reloadText(document: second, modelText: "same") == nil)
        #expect(sync.isSameDocument(second))
    }

    @Test func staleEditorContentCannotOverwriteAnExternalChange() {
        // The data-loss scenario: model changed externally, editor still holds "old", user types.
        let doc = Doc()
        var sync = ExternalTextSync(document: doc, text: "old")
        let reload = sync.reloadText(document: doc, modelText: "new from disk")
        #expect(reload == "new from disk")  // the editor is told to show it before any keystroke can be written back
    }

    @Test func selectionsSurviveAReload() {
        // edit in the middle: before stays, after shifts, inside clamps
        let old = "hello brave world", new = "hello wonderful, brave new world"
        #expect(ExternalTextSync.remap(NSRange(location: 2, length: 0), from: old, to: new) == NSRange(location: 2, length: 0))
        #expect(ExternalTextSync.remap(NSRange(location: 17, length: 0), from: old, to: new) == NSRange(location: 32, length: 0))
        #expect(ExternalTextSync.remap(NSRange(location: 12, length: 5), from: old, to: new).location >= 6)
        // everything replaced / emptied: never out of bounds
        #expect(ExternalTextSync.remap(NSRange(location: 5, length: 3), from: "abcdefghij", to: "") == NSRange(location: 0, length: 0))
        let r = ExternalTextSync.remap(NSRange(location: 9, length: 1), from: "abcdefghij", to: "xyz")
        #expect(NSMaxRange(r) <= 3)
    }
}

@MainActor
struct ReloadTextTests {
    @Test func reloadingKeepsSelectionAndRestylesTheNewText() async throws {
        let view = ViewTests.makeSizedView("# one\n\nbody text\n")
        view.setSelectedRange(NSRange(location: 12, length: 4))  // "text"
        view.reloadText("# one\n\nbody text\n\nadded *later*\n")
        #expect(view.string == "# one\n\nbody text\n\nadded *later*\n")
        #expect(view.selectedRange() == NSRange(location: 12, length: 4))
        let italic = await eventually {
            (view.textStorage?.attribute(.font, at: 27, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.italic) == true
        }
        #expect(italic)
    }

    @Test func reloadingWithIdenticalTextIsANoOp() {
        let view = ViewTests.makeSizedView("same")
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.reloadText("same")
        #expect(view.selectedRange() == NSRange(location: 2, length: 0))
    }
}
