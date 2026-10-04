import Foundation
import Testing
@testable import WorkspaceKit

struct RenameNameTests {
    @Test func aTypedStemKeepsTheFilesExtension() {
        #expect(RenameName.normalized(typed: "plan", current: "notes.md") == "plan.md")
        #expect(RenameName.normalized(typed: "plan", current: "notes.qmd") == "plan.qmd")
        #expect(RenameName.normalized(typed: "  plan \n", current: "notes.md") == "plan.md")
    }

    @Test func anExtensionTheUserTypedIsRespected() {
        #expect(RenameName.normalized(typed: "plan.markdown", current: "notes.md") == "plan.markdown")
        #expect(RenameName.normalized(typed: "plan.txt", current: "notes.md") == "plan.txt")
        #expect(RenameName.normalized(typed: "plan.MD", current: "notes.md") == "plan.MD")
    }

    @Test func aDotThatIsNotAnExtensionDoesNotCount() {
        #expect(RenameName.normalized(typed: "v1.2", current: "notes.md") == "v1.2.md")
        #expect(RenameName.normalized(typed: "Dr. Smith", current: "notes.md") == "Dr. Smith.md")
        #expect(RenameName.normalized(typed: "plan.", current: "notes.md") == "plan.md")
        #expect(RenameName.normalized(typed: "a.b.md", current: "notes.md") == "a.b.md")
    }

    @Test func aFileWithoutAnExtensionStaysWithout() {
        #expect(RenameName.normalized(typed: "plan", current: "README") == "plan")
    }

    @Test func nothingTypedIsEmpty() {
        #expect(RenameName.normalized(typed: "", current: "notes.md") == "")
        #expect(RenameName.normalized(typed: "  ", current: "notes.md") == "")
        #expect(RenameName.normalized(typed: "...", current: "notes.md") == "")
    }

    @Test func theSameNameComesBackEqualSoACallerCanSeeNoChange() {
        #expect(RenameName.normalized(typed: "notes", current: "notes.md") == "notes.md")
        #expect(RenameName.normalized(typed: "Untitled 2", current: "Untitled 2.md") == "Untitled 2.md")
    }

    @Test func theStemIsSelectedNotTheExtension() {
        let name = "my notes.v2.md"
        #expect(String(name[..<RenameName.stemEnd(in: name)]) == "my notes.v2")
        let plain = "Untitled 2"
        #expect(RenameName.stemEnd(in: plain) == plain.endIndex)
        let numeric = "v1.2"
        #expect(RenameName.stemEnd(in: numeric) == numeric.endIndex)
    }
}
