import Foundation
import Testing

@testable import WorkspaceKit

@MainActor
private func waitMain(_ seconds: Double = 5, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return condition()
}

private func fp(_ text: String) -> ExternalChangeTracker.Disk { .present(FileFingerprint(Data(text.utf8))) }

struct ExternalChangeTrackerTests {
    @Test func fingerprintFollowsTheBytes() {
        #expect(FileFingerprint(Data("a".utf8)) == FileFingerprint(Data("a".utf8)))
        #expect(FileFingerprint(Data("a".utf8)) != FileFingerprint(Data("b".utf8)))
        #expect(FileFingerprint(Data("ab".utf8)) != FileFingerprint(Data("ba".utf8)))
    }

    @Test func firstProbeAdoptsWhatIsOnDisk() {
        var t = ExternalChangeTracker()
        #expect(t.probe(fp("a"), isDirty: false) == .none)
        #expect(t.synced == fp("a"))
        #expect(t.probe(fp("b"), isDirty: false) == .reload)
    }

    @Test func ownSaveIsNotAChange() {
        var t = ExternalChangeTracker(synced: fp("old"))
        t.didSync(fp("mine"))  // the save finished
        #expect(t.probe(fp("mine"), isDirty: false) == .none)  // its events arrive afterwards
        #expect(t.probe(fp("mine"), isDirty: true) == .none)
    }

    @Test func touchOrRewriteWithSameBytesIsNotAChange() {
        var t = ExternalChangeTracker(synced: fp("same"))
        #expect(t.probe(fp("same"), isDirty: false) == .none)
        #expect(t.probe(fp("same"), isDirty: true) == .none)
    }

    @Test func cleanDocumentReloadsOnceForABurst() {
        var t = ExternalChangeTracker(synced: fp("v0"))
        #expect(t.probe(fp("v20"), isDirty: false) == .reload)
        t.didSync(fp("v20"))  // the caller re-read the file: the last of the writes
        for _ in 0..<20 { #expect(t.probe(fp("v20"), isDirty: false) == .none) }
    }

    @Test func dirtyDocumentPromptsOnceWhateverHappensWhileAsking() {
        var t = ExternalChangeTracker(synced: fp("base"))
        #expect(t.probe(fp("theirs 1"), isDirty: true) == .prompt)
        #expect(t.isPrompting)
        for i in 2...20 { #expect(t.probe(fp("theirs \(i)"), isDirty: true) == .none) }
        #expect(t.isPrompting)
    }

    @Test func keepMineAcknowledgesTheFileAndAsksAgainOnlyForNewChanges() {
        var t = ExternalChangeTracker(synced: fp("base"))
        _ = t.probe(fp("theirs"), isDirty: true)
        t.keepMine(acknowledging: fp("theirs"))
        #expect(!t.isPrompting)
        #expect(t.probe(fp("theirs"), isDirty: true) == .none)
        #expect(t.probe(fp("theirs 2"), isDirty: true) == .prompt)
    }

    @Test func reloadingClosesThePrompt() {
        var t = ExternalChangeTracker(synced: fp("base"))
        _ = t.probe(fp("theirs"), isDirty: true)
        t.didSync(fp("theirs"))
        #expect(!t.isPrompting)
        #expect(t.probe(fp("theirs"), isDirty: false) == .none)
    }

    @Test func aSaveWhileAskingClosesThePrompt() {
        var t = ExternalChangeTracker(synced: fp("base"))
        _ = t.probe(fp("theirs"), isDirty: true)
        t.didSync(fp("mine"))  // Save Anyway
        #expect(!t.isPrompting)
    }

    @Test func changedBackWhileAskingCancelsThePrompt() {
        var t = ExternalChangeTracker(synced: fp("base"))
        _ = t.probe(fp("theirs"), isDirty: true)
        #expect(t.probe(fp("base"), isDirty: true) == .none)
        #expect(!t.isPrompting)
    }

    @Test func promptThatCannotBeShownAsksAgainNextTime() {
        var t = ExternalChangeTracker(synced: fp("base"))
        _ = t.probe(fp("theirs"), isDirty: true)
        t.promptNotShown()
        #expect(t.probe(fp("theirs"), isDirty: true) == .prompt)
    }

    @Test func deletionKeepsTheTextAndIsReportedOnce() {
        var t = ExternalChangeTracker(synced: fp("a"))
        #expect(t.probe(.missing, isDirty: false) == .markMissing)
        #expect(t.isMissing)
        #expect(t.probe(.missing, isDirty: false) == .none)
        #expect(t.probe(.missing, isDirty: true) == .none)
    }

    @Test func deletionWhileAskingEndsThePrompt() {
        var t = ExternalChangeTracker(synced: fp("a"))
        _ = t.probe(fp("b"), isDirty: true)
        #expect(t.probe(.missing, isDirty: true) == .markMissing)
        #expect(!t.isPrompting && t.isMissing)
    }

    @Test func reappearingWithNewBytesIsAModification() {
        var t = ExternalChangeTracker(synced: fp("a"))
        _ = t.probe(.missing, isDirty: false)
        #expect(t.probe(fp("b"), isDirty: false) == .reload)
        t.didSync(fp("b"))
        #expect(!t.isMissing)
    }

    @Test func reappearingWithNewBytesWhileDirtyPrompts() {
        var t = ExternalChangeTracker(synced: fp("a"))
        _ = t.probe(.missing, isDirty: true)
        #expect(t.probe(fp("b"), isDirty: true) == .prompt)
    }

    @Test func reappearingWithTheSameBytesStillReloadsAMarkerOnlyDocument() {
        var t = ExternalChangeTracker(synced: fp("a"))
        _ = t.probe(.missing, isDirty: false)  // the document is marked edited only because the file is gone
        #expect(t.probe(fp("a"), isDirty: false) == .reload)  // revert clears the marker
        t.didSync(fp("a"))
        #expect(!t.isMissing)
    }

    @Test func reappearingWithTheSameBytesKeepsTheUsersEdits() {
        var t = ExternalChangeTracker(synced: fp("a"))
        _ = t.probe(.missing, isDirty: true)
        #expect(t.probe(fp("a"), isDirty: true) == .none)
        #expect(!t.isMissing)
    }

    @Test func savingWhileMissingBringsTheFileBack() {
        var t = ExternalChangeTracker(synced: fp("a"))
        _ = t.probe(.missing, isDirty: true)
        t.didSync(fp("mine"))
        #expect(!t.isMissing)
        #expect(t.probe(fp("mine"), isDirty: false) == .none)
    }
}

/// Real FSEvents on a temp directory, with a stand-in for the document that re-reads the file on `.reload`.
@MainActor
private final class Harness {
    let url: URL
    var actions: [ExternalChangeTracker.Action] = []
    var settled = 0
    var dirty = false
    var monitor: ExternalFileMonitor!

    init(_ t: TempDir, name: String = "doc.md", text: String = "v0") throws {
        url = try t.file(name, text)
        monitor = ExternalFileMonitor(
            url: url, synced: fp(text), settle: .milliseconds(150), ignoreSelf: false, isDirty: { [unowned self] in dirty },
            onAction: { [unowned self] action in
                actions.append(action)
                if action == .reload, let data = try? Data(contentsOf: url) { monitor.didSync(.present(FileFingerprint(data))) }
            },
            onSettled: { [unowned self] in settled += 1 })
        #expect(monitor.start())
    }

    func quiet(_ ms: Int = 900) async { try? await Task.sleep(for: .milliseconds(ms)) }
    func begin() async { await quiet(350) }  // FSEvents needs a moment before it sees changes
    func atomicReplace(with text: String) throws {
        let tmp = url.deletingLastPathComponent().appending(path: ".tmp-\(UUID().uuidString)")
        try Data(text.utf8).write(to: tmp)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}

@MainActor
struct ExternalFileMonitorTests {
    @Test func inPlaceWriteReloadsOnce() async throws {
        let t = try TempDir(); defer { t.cleanUp() }
        let h = try Harness(t); defer { h.monitor.stop() }
        await h.begin()
        try Data("v1".utf8).write(to: h.url)
        #expect(await waitMain { h.actions.count >= 1 })
        await h.quiet()
        #expect(h.actions == [.reload])
    }

    @Test func atomicReplaceReloadsOnce() async throws {
        let t = try TempDir(); defer { t.cleanUp() }
        let h = try Harness(t); defer { h.monitor.stop() }
        await h.begin()
        try h.atomicReplace(with: "replaced")
        #expect(await waitMain { h.actions.count >= 1 })
        await h.quiet()
        #expect(h.actions == [.reload])
    }

    @Test func ownSaveNeverReloads() async throws {
        let t = try TempDir(); defer { t.cleanUp() }
        let h = try Harness(t); defer { h.monitor.stop() }
        await h.begin()
        try Data("saved by us".utf8).write(to: h.url)
        h.monitor.didSync(fp("saved by us"))  // what the document's save does
        await h.quiet()
        #expect(h.actions.isEmpty)
    }

    @Test func touchChangesNothing() async throws {
        let t = try TempDir(); defer { t.cleanUp() }
        let h = try Harness(t); defer { h.monitor.stop() }
        await h.begin()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: h.url.path)
        try Data("v0".utf8).write(to: h.url)  // same bytes again
        await h.quiet()
        #expect(h.actions.isEmpty)
    }

    @Test func burstOfTwentyWritesIsOneReload() async throws {
        let t = try TempDir(); defer { t.cleanUp() }
        let h = try Harness(t); defer { h.monitor.stop() }
        await h.begin()
        for i in 1...20 { try Data("burst \(i)".utf8).write(to: h.url) }
        #expect(await waitMain { h.actions.count >= 1 })
        await h.quiet(1200)
        #expect(h.actions == [.reload])
        #expect(h.monitor.tracker.synced == fp("burst 20"))
    }

    @Test func deleteThenRecreate() async throws {
        let t = try TempDir(); defer { t.cleanUp() }
        let h = try Harness(t); defer { h.monitor.stop() }
        await h.begin()
        try FileManager.default.removeItem(at: h.url)
        #expect(await waitMain { h.actions == [.markMissing] })
        await h.quiet(500)
        #expect(h.actions == [.markMissing])
        try Data("back".utf8).write(to: h.url)
        #expect(await waitMain { h.actions.count >= 2 })
        await h.quiet()
        #expect(h.actions == [.markMissing, .reload])
        #expect(!h.monitor.tracker.isMissing)
    }

    @Test func movedAwayIsMissing() async throws {
        let t = try TempDir(); defer { t.cleanUp() }
        let h = try Harness(t); defer { h.monitor.stop() }
        await h.begin()
        try FileManager.default.moveItem(at: h.url, to: t.url.appending(path: "elsewhere.md"))
        #expect(await waitMain { h.actions == [.markMissing] })
    }

    @Test func dirtyDocumentGetsOnePromptEvenIfTheFileKeepsChanging() async throws {
        let t = try TempDir(); defer { t.cleanUp() }
        let h = try Harness(t); defer { h.monitor.stop() }
        h.dirty = true
        await h.begin()
        try Data("theirs 1".utf8).write(to: h.url)
        #expect(await waitMain { h.actions == [.prompt] })
        for i in 2...6 {
            try Data("theirs \(i)".utf8).write(to: h.url)
            try await Task.sleep(for: .milliseconds(400))
        }
        #expect(h.actions == [.prompt])
        #expect(h.monitor.tracker.isPrompting)
        // The user keeps their text: the file as it is now is acknowledged, a later change asks again.
        h.monitor.keepMine()
        await h.quiet(500)
        #expect(h.actions == [.prompt])
        try Data("theirs 7".utf8).write(to: h.url)
        #expect(await waitMain { h.actions.count == 2 })
        #expect(h.actions == [.prompt, .prompt])
    }

    @Test func stoppedMonitorSaysNothing() async throws {
        let t = try TempDir(); defer { t.cleanUp() }
        let h = try Harness(t)
        await h.begin()
        h.monitor.stop()
        try Data("v1".utf8).write(to: h.url)
        await h.quiet()
        #expect(h.actions.isEmpty)
    }

    @Test func settledIsReportedForOtherFilesInTheFolder() async throws {
        let t = try TempDir(); defer { t.cleanUp() }
        let h = try Harness(t); defer { h.monitor.stop() }
        try t.dir("img")
        await h.begin()
        try t.file("img/a.png", "x")
        #expect(await waitMain { h.settled >= 1 })
        #expect(h.actions.isEmpty)
    }

    @Test func onlyLocalFilesAreWatchable() throws {
        let t = try TempDir(); defer { t.cleanUp() }
        #expect(ExternalFileMonitor.isWatchable(t.url))
        #expect(!ExternalFileMonitor.isWatchable(URL(string: "https://example.com/a.md")!))
        #expect(!ExternalFileMonitor.isWatchable(URL(fileURLWithPath: "/definitely/not/here")))
    }
}
