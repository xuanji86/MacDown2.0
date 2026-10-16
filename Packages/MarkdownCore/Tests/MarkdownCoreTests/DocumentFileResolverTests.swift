import Foundation
import Testing
@testable import MarkdownCore

/// A document folder with an image, a sibling secret outside it, and symlinks in and out.
struct ResolverTree {
    let sandbox = FileManager.default.temporaryDirectory.appending(path: "resolver-\(UUID().uuidString)")
    var doc: URL { sandbox.appending(path: "doc") }

    init() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: doc.appending(path: "img"), withIntermediateDirectories: true)
        try Data("png".utf8).write(to: doc.appending(path: "img/a b.png"))
        try Data("secret".utf8).write(to: sandbox.appending(path: "secret.txt"))
        try fm.createSymbolicLink(at: doc.appending(path: "out.txt"), withDestinationURL: sandbox.appending(path: "secret.txt"))
        try fm.createSymbolicLink(at: doc.appending(path: "same.png"), withDestinationURL: doc.appending(path: "img/a b.png"))
        try fm.createSymbolicLink(at: doc.appending(path: "outdir"), withDestinationURL: sandbox)
    }

    func remove() { try? FileManager.default.removeItem(at: sandbox) }
}

private func isFile(_ r: DocumentFileResolver.Result) -> Bool { if case .file = r { true } else { false } }

@Test func resolverAcceptsFilesInsideTheDocumentFolder() throws {
    let t = try ResolverTree(); defer { t.remove() }
    #expect(isFile(DocumentFileResolver.resolve(path: "/img/a b.png", root: t.doc)))
    #expect(isFile(DocumentFileResolver.resolve(path: "/./img/./a b.png", root: t.doc)))
    #expect(isFile(DocumentFileResolver.resolve(path: "/same.png", root: t.doc)))  // symlink that stays inside
    #expect(isFile(DocumentFileResolver.resolve(path: "/img/a b.png", root: t.sandbox.appending(path: "doc/outdir/doc"))))  // root reached through a symlink
}

@Test func resolverReportsMissingThings() throws {
    let t = try ResolverTree(); defer { t.remove() }
    #expect(DocumentFileResolver.resolve(path: "/nope.png", root: t.doc) == .notFound)
    #expect(DocumentFileResolver.resolve(path: "/img", root: t.doc) == .notFound)  // directory
    #expect(DocumentFileResolver.resolve(path: "/", root: t.doc) == .notFound)
    #expect(DocumentFileResolver.resolve(path: "/img/a b.png", root: nil) == .notFound)
}

@Test func resolverRefusesToLeaveTheDocumentFolder() throws {
    let t = try ResolverTree(); defer { t.remove() }
    #expect(DocumentFileResolver.resolve(path: "/img/../../secret.txt", root: t.doc) == .forbidden)
    #expect(DocumentFileResolver.resolve(path: "/../doc/img/a b.png", root: t.doc) == .forbidden)
    #expect(DocumentFileResolver.resolve(path: "/out.txt", root: t.doc) == .forbidden)  // symlink file pointing out
    #expect(DocumentFileResolver.resolve(path: "/outdir/secret.txt", root: t.doc) == .forbidden)  // symlink dir pointing out
    #expect(DocumentFileResolver.resolve(path: "/../doc2/x", root: t.doc) == .forbidden)  // sibling sharing the name prefix
}

@Test func isInsideComparesWholePathComponents() {
    func file(_ path: String) -> URL { URL(fileURLWithPath: path) }
    let root = file("/a/b")
    #expect(file("/a/b/c").isInside(root))
    #expect(file("/a/b/c/d.md").isInside(root))
    #expect(!file("/a/bc").isInside(root))  // shares the prefix, is not a child
    #expect(!file("/a/bc/d").isInside(root))
    #expect(!file("/a").isInside(root))
    #expect(!file("/a/b").isInside(root))  // the root itself is not inside it...
    #expect(file("/a/b").isInside(root, orSame: true))  // ...unless asked
    #expect(!file("/a/bc").isInside(root, orSame: true))
    // a trailing slash on the root changes nothing
    #expect(file("/a/b/c").isInside(URL(fileURLWithPath: "/a/b/", isDirectory: true)))
    #expect(!file("/a/bc").isInside(URL(fileURLWithPath: "/a/b/", isDirectory: true)))
    // the filesystem root contains everything
    #expect(file("/a").isInside(file("/")))
    #expect(file("/a/b/c").isInside(file("/")))
}
