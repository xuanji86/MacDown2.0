import Foundation
import Testing
@testable import CLIKit

private func app(in s: Scratch) throws -> (app: URL, helper: URL) {
    let helper = try s.write("MacDown2.app/Contents/Helpers/macdown2", "#!/bin/sh\n")
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
    return (s.root.appending(path: "MacDown2.app"), helper)
}

@Test func installCreatesALinkAndRecognisesItAgain() throws {
    let s = try Scratch(); defer { s.remove() }
    let (_, helper) = try app(in: s)
    let bin = s.root.appending(path: "home/.local/bin")  // does not exist yet
    #expect(CLIInstaller.state(link: bin.appending(path: "macdown2"), helper: helper) == .notInstalled)
    let link = try CLIInstaller.install(helper: helper, into: bin, replace: false)
    #expect(link.path == bin.appending(path: "macdown2").path)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == helper.path)
    #expect(CLIInstaller.state(link: link, helper: helper) == .installed)
}

@Test func aLinkIntoAnotherCopyOfTheAppIsElsewhere() throws {
    let s = try Scratch(); defer { s.remove() }
    let (_, helper) = try app(in: s)
    let other = try s.write("Other.app/Contents/Helpers/macdown2")
    let bin = s.root.appending(path: "bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: bin.appending(path: "macdown2"), withDestinationURL: other)
    #expect(CLIInstaller.state(link: bin.appending(path: "macdown2"), helper: helper) == .elsewhere("a link to \(other.path)"))
    // Without replace the existing link is an error from the OS, not silently replaced…
    #expect(throws: (any Error).self) { try CLIInstaller.install(helper: helper, into: bin, replace: false) }
    // …with it, the link now points here.
    try CLIInstaller.install(helper: helper, into: bin, replace: true)
    #expect(CLIInstaller.state(link: bin.appending(path: "macdown2"), helper: helper) == .installed)
}

@Test func aRegularFileIsAskedAboutAndAFolderIsNeverReplaced() throws {
    let s = try Scratch(); defer { s.remove() }
    let (_, helper) = try app(in: s)
    let file = try s.write("bin/macdown2", "something else")
    #expect(CLIInstaller.state(link: file, helper: helper) == .elsewhere("an existing file"))
    try CLIInstaller.install(helper: helper, into: file.deletingLastPathComponent(), replace: true)
    #expect(CLIInstaller.state(link: file, helper: helper) == .installed)

    let folder = s.root.appending(path: "bin2/macdown2")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: folder.appending(path: "keep.txt"))
    #expect(throws: (any Error).self) { try CLIInstaller.install(helper: helper, into: folder.deletingLastPathComponent(), replace: true) }
    #expect(FileManager.default.fileExists(atPath: folder.appending(path: "keep.txt").path))
}

@Test func aDanglingLinkCountsAsSomethingElse() throws {
    let s = try Scratch(); defer { s.remove() }
    let (_, helper) = try app(in: s)
    let bin = s.root.appending(path: "bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: bin.appending(path: "macdown2").path, withDestinationPath: "/nonexistent/macdown2")
    #expect(CLIInstaller.state(link: bin.appending(path: "macdown2"), helper: helper) == .elsewhere("a link to /nonexistent/macdown2"))
    try CLIInstaller.install(helper: helper, into: bin, replace: true)
    #expect(CLIInstaller.state(link: bin.appending(path: "macdown2"), helper: helper) == .installed)
}

@Test func installWithoutTheToolInTheBundleFails() throws {
    let s = try Scratch(); defer { s.remove() }
    #expect(throws: (any Error).self) { try CLIInstaller.install(helper: s.root.appending(path: "none"), into: s.root.appending(path: "bin"), replace: false) }
}

@Test func directoryPrefersAWritableHomebrewBin() throws {
    let s = try Scratch(); defer { s.remove() }
    let home = s.root.appending(path: "home")
    let brew = s.root.appending(path: "brew-bin")
    #expect(CLIInstaller.directory(home: home, homebrew: brew) == home.appending(path: ".local/bin", directoryHint: .isDirectory))  // absent
    try FileManager.default.createDirectory(at: brew, withIntermediateDirectories: true)
    #expect(CLIInstaller.directory(home: home, homebrew: brew) == brew)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: brew.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path) }
    #expect(CLIInstaller.directory(home: home, homebrew: brew) == home.appending(path: ".local/bin", directoryHint: .isDirectory))  // not writable
}

@Test func pathHintMentionsTheFolder() {
    #expect(CLIInstaller.pathHint(directory: URL(fileURLWithPath: "/Users/x/.local/bin")).contains("/Users/x/.local/bin"))
    #expect(CLIInstaller.pathHint(directory: URL(fileURLWithPath: "/opt/homebrew/bin")).contains("Homebrew"))
}
