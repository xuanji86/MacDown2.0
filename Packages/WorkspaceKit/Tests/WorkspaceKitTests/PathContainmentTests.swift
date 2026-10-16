import Testing
@testable import WorkspaceKit

struct PathContainmentTests {
    @Test func aPathIsAtOrUnderItselfAndItsAncestors() {
        #expect("/a/b".isPath(atOrUnder: "/a/b"))
        #expect("/a/b/c.md".isPath(atOrUnder: "/a/b"))
        #expect("/a/b/c/d".isPath(atOrUnder: "/a"))
    }

    @Test func aSiblingWithTheSamePrefixIsNotInside() {
        #expect(!"/a/bc".isPath(atOrUnder: "/a/b"))
        #expect(!"/a/bc/d".isPath(atOrUnder: "/a/b"))
        #expect(!"/a".isPath(atOrUnder: "/a/b"))  // an ancestor is not inside its descendant
    }

    @Test func theVolumeRootContainsEveryAbsolutePath() {
        #expect("/".isPath(atOrUnder: "/"))
        #expect("/Users".isPath(atOrUnder: "/"))
        #expect("/Users/me/notes.md".isPath(atOrUnder: "/"))
        #expect(!"/Users".isPath(atOrUnder: "/Users/me"))
    }

    @Test func aTrailingSlashOnTheRootIsIgnored() {
        #expect("/a/b/c".isPath(atOrUnder: "/a/b/"))
        #expect("/a/b".isPath(atOrUnder: "/a/b/"))
        #expect(!"/a/bc".isPath(atOrUnder: "/a/b/"))
    }
}
