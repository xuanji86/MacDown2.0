import AppKit
import Testing
@testable import EditorKit

struct ExternalTextSyncTests {
    @Test func theEditorsOwnWritesAreNotReloaded() {
        var sync = ExternalTextSync(text: "a")
        sync.editorDidWrite("ab")
        #expect(sync.reloadText(modelText: "ab") == nil)
    }

    @Test func aModelChangeBehindTheEditorsBackIsReloadedOnce() {
        var sync = ExternalTextSync(text: "old")
        #expect(sync.reloadText(modelText: "reverted") == "reverted")
        #expect(sync.reloadText(modelText: "reverted") == nil)
        // and the next keystroke is compared against the reloaded text, not the stale one
        sync.editorDidWrite("reverted!")
        #expect(sync.reloadText(modelText: "reverted!") == nil)
    }

    @Test func matchesTellsWhetherTheModelAlreadyHoldsAText() {
        var sync = ExternalTextSync(text: "a")
        #expect(sync.matches("a") && !sync.matches("ab"))
        sync.editorDidWrite("ab")
        #expect(sync.matches("ab") && !sync.matches("a"))
    }

    @Test func staleEditorContentCannotOverwriteAnExternalChange() {
        // The data-loss scenario: model changed externally, editor still holds "old", user types.
        var sync = ExternalTextSync(text: "old")
        let reload = sync.reloadText(modelText: "new from disk")
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
