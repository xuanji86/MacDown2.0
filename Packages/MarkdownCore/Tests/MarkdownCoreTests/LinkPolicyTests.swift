import Foundation
import Testing
@testable import MarkdownCore

/// The four classes of link in the preview (ISSUE-REVIEW 3.D): in-page anchor, Markdown file in the workspace, any other
/// file (confirmed, never executables), web. Plus everything hostile.md throws at the decider.
struct PolicyTree {
    let sandbox = FileManager.default.temporaryDirectory.appending(path: "linkpolicy-\(UUID().uuidString)")
    var doc: URL { sandbox.appending(path: "doc") }
    var workspace: URL { sandbox.appending(path: "workspace") }
    let page = URL(string: "macdown2-res://app/preview.html")!

    init() throws {
        let fm = FileManager.default
        for dir in ["doc/notes", "doc/Tool.app/Contents/MacOS", "doc/plain-folder", "workspace/sub", "other"] {
            try fm.createDirectory(at: sandbox.appending(path: dir), withIntermediateDirectories: true)
        }
        func write(_ path: String, _ bytes: [UInt8], mode: Int = 0o644) throws {
            let url = sandbox.appending(path: path)
            try Data(bytes).write(to: url)
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
        let text = { (s: String) in Array(s.utf8) }
        try write("doc/a.md", text("# a"))
        try write("doc/b c.md", text("# spaces"))
        try write("doc/notes/readme.markdown", text("# n"))
        try write("doc/q.qmd", text("# q"))
        try write("doc/synced.md", text("# synced"), mode: 0o755)  // OneDrive and friends set the execute bit on everything
        try write("doc/report.pdf", text("%PDF-1.4"))
        try write("doc/synced.pdf", text("%PDF-1.4"), mode: 0o755)
        try write("doc/pic.png", [0x89, 0x50, 0x4E, 0x47])
        try write("doc/run.sh", text("#!/bin/sh\necho hi\n"), mode: 0o755)
        try write("doc/plain.sh", text("echo hi\n"))  // no execute bit, no shebang: still a shell script by name
        try write("doc/Setup.pkg", text("xar!"))
        try write("doc/disguised.txt", [0xCF, 0xFA, 0xED, 0xFE, 0, 0, 0, 0])  // Mach-O under a harmless name
        try write("doc/notes.txt", text("just notes"))
        try write("doc/shebang.txt", text("#!/bin/sh\nrm -rf /\n"), mode: 0o755)
        try write("doc/noext", text("data"), mode: 0o755)
        try write("doc/Tool.app/Contents/MacOS/tool", text("#!/bin/sh\n"), mode: 0o755)
        try write("workspace/w.md", text("# w"))
        try write("workspace/sub/deep.qmd", text("# deep"))
        try write("other/outside.md", text("# outside"))
        try fm.createSymbolicLink(at: doc.appending(path: "link-to-sh.md"), withDestinationURL: URL(filePath: "/bin/sh"))
        try fm.createSymbolicLink(at: doc.appending(path: "link-out.md"), withDestinationURL: sandbox.appending(path: "other/outside.md"))
        try fm.createSymbolicLink(at: doc.appending(path: "link-in.md"), withDestinationURL: doc.appending(path: "a.md"))
    }

    func remove() { try? FileManager.default.removeItem(at: sandbox) }
    func policy(roots: [URL]? = nil) -> LinkPolicy { LinkPolicy(pageURL: page, roots: roots ?? [doc]) }
    func fileURL(_ path: String) -> URL { URL(filePath: sandbox.path + "/" + path) }
}

private func decide(_ policy: LinkPolicy, _ url: String, click: Bool = true) -> LinkPolicy.Decision {
    policy.decide(URL(string: url)!, isLinkActivation: click)
}

// MARK: 1. In-page anchors

@Test func anchorsStayInThePage() throws {
    let t = try PolicyTree(); defer { t.remove() }
    let p = t.policy()
    // `#slug`, a hand written `<a name>` and any `id` all resolve to the page URL plus a fragment
    for fragment in ["#slug", "#manual-anchor", "#%E5%AE%89%E8%A3%85", "#footnote1", "#a-b_c.d"] {
        #expect(decide(p, "macdown2-res://app/preview.html\(fragment)") == .allow, "\(fragment)")
    }
    #expect(decide(p, "macdown2-res://app/preview.html#x", click: false) == .allow)
}

@Test func theOwnPageLoadsAndReloadsButIsNotALinkTarget() throws {
    let t = try PolicyTree(); defer { t.remove() }
    let p = t.policy()
    #expect(decide(p, "macdown2-res://app/preview.html", click: false) == .allow)  // the initial load
    #expect(decide(p, "macdown2-res://app/preview.html", click: true) == .refuse(.notALink))  // `<a href="">` would reload the page and lose its state
    #expect(decide(p, "macdown2-res://app/other.html#x") == .refuse(.notALink))
    #expect(decide(p, "macdown2-res://doc/a.md") == .refuse(.notALink))
    #expect(decide(p, "macdown2-res://doc/a.md", click: false) == .refuse(.notALink))
    #expect(decide(p, "macdown2-res://evil/preview.html#x") == .refuse(.notALink))
}

// MARK: 2. Markdown files in the workspace open in the app

@Test func markdownFilesInTheDocumentFolderOpenInTheApp() throws {
    let t = try PolicyTree(); defer { t.remove() }
    let p = t.policy()
    let resolved = { (path: String) in t.fileURL(path).resolvingSymlinksInPath() }
    #expect(decide(p, t.fileURL("doc/a.md").absoluteString) == .openInApp(resolved("doc/a.md")))
    #expect(decide(p, t.fileURL("doc/a.md").absoluteString + "#section") == .openInApp(resolved("doc/a.md")))  // the fragment is the opener's business
    #expect(decide(p, t.fileURL("doc/b c.md").absoluteString) == .openInApp(resolved("doc/b c.md")))  // percent-encoded space
    #expect(decide(p, t.fileURL("doc/notes/readme.markdown").absoluteString) == .openInApp(resolved("doc/notes/readme.markdown")))
    #expect(decide(p, t.fileURL("doc/q.qmd").absoluteString) == .openInApp(resolved("doc/q.qmd")))
    #expect(decide(p, t.fileURL("doc/notes/../a.md").absoluteString) == .openInApp(resolved("doc/a.md")))  // `..` inside the folder
    #expect(decide(p, t.fileURL("doc/synced.md").absoluteString) == .openInApp(resolved("doc/synced.md")), "an execute bit on a note changes nothing")
    #expect(decide(p, t.fileURL("doc/link-in.md").absoluteString) == .openInApp(resolved("doc/a.md")))  // a symlink that stays inside
}

@Test func workspaceFoldersCountAsTheWorkspace() throws {
    let t = try PolicyTree(); defer { t.remove() }
    let solo = t.policy()
    let withWorkspace = t.policy(roots: [t.doc, t.workspace])
    let w = t.fileURL("workspace/sub/deep.qmd").resolvingSymlinksInPath()
    #expect(decide(solo, w.absoluteString) == .confirmOpenWithSystem(w), "outside every root: asks first")
    #expect(decide(withWorkspace, w.absoluteString) == .openInApp(w))
    #expect(decide(withWorkspace, t.fileURL("workspace/w.md").absoluteString) == .openInApp(t.fileURL("workspace/w.md").resolvingSymlinksInPath()))
}

@Test func markdownOutsideTheWorkspaceAndSymlinkEscapesAreNotOpenedSilently() throws {
    let t = try PolicyTree(); defer { t.remove() }
    let p = t.policy()
    let outside = t.fileURL("other/outside.md").resolvingSymlinksInPath()
    #expect(decide(p, outside.absoluteString) == .confirmOpenWithSystem(outside))
    #expect(decide(p, t.fileURL("doc/../other/outside.md").absoluteString) == .confirmOpenWithSystem(outside))  // `..` out of the folder
    #expect(decide(p, t.fileURL("doc/link-out.md").absoluteString) == .confirmOpenWithSystem(outside), "a note that is a symlink out of the workspace")
    #expect(decide(p, t.fileURL("doc/nope.md").absoluteString) == .refuse(.missing))  // nothing is created for a dead link
}

@Test func aSymlinkNamedLikeANoteThatPointsAtABinaryIsRefused() throws {
    let t = try PolicyTree(); defer { t.remove() }
    #expect(decide(t.policy(), t.fileURL("doc/link-to-sh.md").absoluteString) == .refuse(.executable))
}

// MARK: 3. Other files: confirm, then the system; executables never

@Test func otherFilesAskFirst() throws {
    let t = try PolicyTree(); defer { t.remove() }
    let p = t.policy()
    for path in ["doc/report.pdf", "doc/pic.png", "doc/notes.txt", "doc/plain-folder", "doc/synced.pdf" /* execute bit on a document */] {
        let file = URL(filePath: t.fileURL(path).resolvingSymlinksInPath().path, directoryHint: path.hasSuffix("folder") ? .isDirectory : .notDirectory)
        #expect(decide(p, t.fileURL(path).absoluteString) == .confirmOpenWithSystem(file), "\(path)")
    }
    #expect(decide(p, "file://localhost" + t.fileURL("doc/report.pdf").path) == .confirmOpenWithSystem(t.fileURL("doc/report.pdf").resolvingSymlinksInPath()))
}

@Test func executablesAreAlwaysRefused() throws {
    let t = try PolicyTree(); defer { t.remove() }
    let p = t.policy()
    let refused = [
        "doc/Tool.app", "doc/Tool.app/Contents/MacOS/tool", "doc/run.sh", "doc/plain.sh", "doc/Setup.pkg",
        "doc/disguised.txt",  // Mach-O bytes under a .txt name
        "doc/shebang.txt",  // script with the execute bit under a .txt name
        "doc/noext",  // execute bit, no type
    ]
    for path in refused { #expect(decide(p, t.fileURL(path).absoluteString) == .refuse(.executable), "\(path)") }
    // the system's own: a real app bundle, a real binary, scripts by extension even if they do not exist as such here
    for url in ["file:///Applications/Calculator.app", "file:///System/Applications/Calculator.app", "file:///usr/bin/true", "file:///bin/sh", "file:///usr/bin/python3"] {
        let exists = FileManager.default.fileExists(atPath: URL(string: url)!.path)
        let decision = decide(p, url)
        if exists { #expect(decision == .refuse(.executable), "\(url)") } else { #expect(decision == .refuse(.missing), "\(url)") }
    }
}

@Test func executablesAreRefusedEvenInsideTheWorkspaceAndEvenNamedLikeNotes() throws {
    let t = try PolicyTree(); defer { t.remove() }
    let p = t.policy(roots: [t.doc, t.sandbox])
    #expect(decide(p, t.fileURL("doc/run.sh").absoluteString) == .refuse(.executable))
    #expect(decide(p, t.fileURL("doc/Tool.app").absoluteString) == .refuse(.executable))
}

@Test func filesOnOtherHostsAreRefused() throws {
    let t = try PolicyTree(); defer { t.remove() }
    let p = t.policy()
    #expect(decide(p, "file://server/share/doc.md") == .refuse(.remoteHost))
    #expect(decide(p, "file://evil.example/etc/passwd") == .refuse(.remoteHost))
}

// MARK: 4. The web

@Test func webLinksGoToTheSystemBrowser() throws {
    let t = try PolicyTree(); defer { t.remove() }
    let p = t.policy()
    for url in ["https://example.com/page", "http://example.com/page?x=1#y", "mailto:someone@example.com"] {
        #expect(decide(p, url) == .openExternally(URL(string: url)!), "\(url)")
    }
    #expect(decide(p, "https:///nohost") == .refuse(.unsupportedScheme))
}

// MARK: Everything else (hostile.md)

@Test func hostileSchemesAreRefused() throws {
    let t = try PolicyTree(); defer { t.remove() }
    let p = t.policy()
    for url in [
        "javascript:__p('x')", "JaVaScRiPt:alert(1)", "data:text/html,<script>alert(1)</script>",
        "blob:https://example.com/00000000-0000-0000-0000-000000000000", "x-apple.systempreferences:com.apple.preference.security",
        "ssh://root@example.com", "smb://example.com/share", "vnc://example.com", "afp://example.com/x", "ftp://example.com/x",
        "tel:+15555550100", "sms:+15555550100", "itms-apps://apps.apple.com/app/id1", "view-source:https://example.com",
    ] {
        #expect(decide(p, url) == .refuse(.unsupportedScheme), "\(url)")
    }
}

@Test func navigationsNoClickCausedAreCancelled() throws {
    let t = try PolicyTree(); defer { t.remove() }
    let p = t.policy()
    // meta refresh, location = ..., form submissions, window.open from script: none of them is a link activation
    for url in ["https://example.com/refresh", t.fileURL("doc/a.md").absoluteString, "file:///etc/passwd", "mailto:a@b.c", "javascript:1"] {
        let decision = decide(p, url, click: false)
        #expect(decision == .refuse(.notALink) || decision == .refuse(.unsupportedScheme), "\(url) -> \(decision)")
    }
    #expect(decide(p, "about:blank", click: false) == .allow)
    #expect(decide(p, "about:blank", click: true) == .refuse(.unsupportedScheme))
}

@Test func hostileMarkdownFixtureLinksAllEndUpRefusedOrConfirmed() throws {
    // The links hostile.md contains, as the page resolves them against a document folder (Web/test/hostile.test.mjs pins that list).
    let t = try PolicyTree(); defer { t.remove() }
    let p = t.policy()
    let base = t.doc.absoluteString + "/"
    let root = t.sandbox.absoluteString + "/"
    let cases: [(String, (LinkPolicy.Decision) -> Bool)] = [
        ("file:///Applications/Calculator.app", { if case .refuse = $0 { true } else { false } }),  // refused: executable or missing on a machine without it
        ("file:///usr/bin/true", { $0 == .refuse(.executable) }),
        ("file://server/share/doc.md", { $0 == .refuse(.remoteHost) }),
        (base + "run.sh", { $0 == .refuse(.executable) }),
        (base + "Tool.app", { $0 == .refuse(.executable) }),
        (base + "Setup.pkg", { $0 == .refuse(.executable) }),
        (base + "notes/readme.markdown", { if case .openInApp = $0 { true } else { false } }),
        (root + "other/outside.md", { if case .confirmOpenWithSystem = $0 { true } else { false } }),
        (base + "report.pdf", { if case .confirmOpenWithSystem = $0 { true } else { false } }),
        (base + "does-not-exist.md", { $0 == .refuse(.missing) }),
        ("file:///etc/passwd", { if case .confirmOpenWithSystem = $0 { true } else { false } }),  // a plain file: the user is asked
    ]
    for (url, check) in cases { #expect(check(decide(p, url)), "\(url) -> \(decide(p, url))") }
}
