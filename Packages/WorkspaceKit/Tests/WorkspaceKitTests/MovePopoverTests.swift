import Foundation
import Testing
@testable import WorkspaceKit

struct MoveDestinationTests {
    @Test func aFileCanChangeNameAndFolderInOneStep() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        let notes = try t.file("a/notes.md"); let other = try t.dir("b")
        let target = try FileOperations.destination(moving: notes, as: "plan.md", into: other)
        #expect(target.path == other.appending(path: "plan.md").path)
    }

    @Test func aTakenNameInTheChosenFolderIsRefused() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        let notes = try t.file("a/notes.md"); let other = try t.dir("b"); try t.file("b/notes.md")
        #expect(throws: FileOperations.Failure.exists("notes.md")) { try FileOperations.destination(moving: notes, as: "notes.md", into: other) }
        #expect(throws: FileOperations.Failure.invalidName) { try FileOperations.destination(moving: notes, as: "a/b.md", into: other) }
    }

    @Test func aFirstSaveNeedsAFreeValidName() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        try t.file("taken.md")
        #expect(try FileOperations.destination(newFile: " fresh.md ", in: t.url).lastPathComponent == "fresh.md")
        #expect(throws: FileOperations.Failure.exists("taken.md")) { try FileOperations.destination(newFile: "taken.md", in: t.url) }
        #expect(throws: FileOperations.Failure.invalidName) { try FileOperations.destination(newFile: "  ", in: t.url) }
    }
}

struct WhereChoicesTests {
    private let home = URL(filePath: "/Users/me", directoryHint: .isDirectory)

    @Test func theCurrentFolderIsFirstAndNothingRepeats() {
        let docs = home.appending(path: "Documents", directoryHint: .isDirectory)
        let proj = home.appending(path: "proj", directoryHint: .isDirectory)
        let out = WhereChoices.folders(current: proj, workspace: [proj], recents: [docs, proj], home: home, exists: { _ in true })
        #expect(out.map(\.lastPathComponent) == ["proj", "Documents", "Desktop", "Downloads"])
    }

    @Test func missingFoldersAreLeftOutButTheCurrentOneStays() {
        let gone = home.appending(path: "gone", directoryHint: .isDirectory)
        let out = WhereChoices.folders(current: gone, workspace: [], recents: [], home: home, exists: { $0.lastPathComponent == "Desktop" })
        #expect(out.map(\.lastPathComponent) == ["gone", "Desktop"])
    }

    @Test func theListIsCapped() {
        let many = (0..<20).map { home.appending(path: "r\($0)", directoryHint: .isDirectory) }
        #expect(WhereChoices.folders(current: many[0], workspace: [], recents: many, home: home, exists: { _ in true }).count == WhereChoices.limit)
    }
}
