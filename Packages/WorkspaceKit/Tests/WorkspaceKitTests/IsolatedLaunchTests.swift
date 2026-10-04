import Foundation
import Testing
@testable import WorkspaceKit

struct IsolatedLaunchTests {
    private let reserved: Set<String> = ["io.github.xuanji86.MacDown2"]

    private func launch(_ env: [String: String]) throws -> IsolatedLaunch? { try IsolatedLaunch(environment: env, reservedSuites: reserved) }

    @Test func noSuiteVariableMeansNoIsolation() throws {
        #expect(try launch([:]) == nil)
        #expect(try launch([IsolatedLaunch.rootVariable: "/tmp/x"]) == nil)
    }

    @Test func suiteAndRootAreRead() throws {
        let l = try #require(try launch([IsolatedLaunch.suiteVariable: "md2-test-1", IsolatedLaunch.rootVariable: "/tmp/md2"]))
        #expect(l.suiteName == "md2-test-1")
        #expect(l.allowedRoot?.path == "/tmp/md2")
    }

    @Test(arguments: ["", "io.github.xuanji86.MacDown2", "NSGlobalDomain", "Apple Global Domain", "a/b", "/tmp/x"])
    func unusableSuitesAreRefusedNotIgnored(_ suite: String) {
        #expect(throws: IsolatedLaunch.Failure.unusableSuite(suite)) { try launch([IsolatedLaunch.suiteVariable: suite]) }
    }

    @Test func noUsableRootOpensNothing() throws {
        for root in [nil, "", "relative/dir"] {
            var env = [IsolatedLaunch.suiteVariable: "s"]
            env[IsolatedLaunch.rootVariable] = root
            let l = try #require(try launch(env))
            #expect(l.allowedRoot == nil)
            #expect(!l.allows(URL(filePath: "/tmp/a.md")))
        }
    }

    @Test func insideTheRootOnly() throws {
        let l = try #require(try launch([IsolatedLaunch.suiteVariable: "s", IsolatedLaunch.rootVariable: "/tmp/md2"]))
        #expect(l.allows(URL(filePath: "/tmp/md2/a.md")))
        #expect(l.allows(URL(filePath: "/tmp/md2/sub/dir/a.md")))
        #expect(l.allows(URL(filePath: "/tmp/md2")))
        #expect(!l.allows(URL(filePath: "/tmp/md2-other/a.md")))  // a sibling that shares the prefix
        #expect(!l.allows(URL(filePath: "/tmp/a.md")))
        #expect(!l.allows(URL(filePath: "/tmp/md2/../a.md")))  // `..` out of the root
        #expect(!l.allows(URL(filePath: "/Users/someone/Documents/notes.md")))
    }

    @Test func symlinksAreFollowedBothWays() throws {
        let dir = try TempDir()
        defer { dir.cleanUp() }
        let root = try dir.dir("root")
        let outside = try dir.file("outside/secret.md")
        let inside = try dir.file("root/ok.md")
        try FileManager.default.createSymbolicLink(at: root.appending(path: "link.md"), withDestinationURL: outside)
        let l = try #require(try launch([IsolatedLaunch.suiteVariable: "s", IsolatedLaunch.rootVariable: root.path]))
        #expect(l.allows(inside))
        #expect(!l.allows(root.appending(path: "link.md")))  // lives in the root, points out of it
        // The same folder spelled through a link (as /var/folders vs /private/var/folders is) is still inside.
        let alias = dir.url.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        #expect(l.allows(alias.appending(path: "ok.md")))
    }
}
