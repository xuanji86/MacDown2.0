import ExtensionAPI
import Foundation
import Testing
import WorkspaceKit
@testable import QmdSearchExtension

/// Collections, an update command, and failures that change while the app runs.
struct ChangingQmdTests {
    @Test func aCollectionThatGainsAnUpdateCommandLaterStillBlocksTheAutomaticUpdate() async throws {
        let workspace = try temporaryFolder()
        let real = realPath(workspace.path)
        let qmd = FakeQmd(answer: standardAnswers(collections: [("mine", real, nil)]))
        let provider = makeProvider(qmd: qmd, environment: try FakeEnvironment(), updateInterval: .zero)
        #expect(try await provider.prepare(workspace: workspace) == .ready)  // no hook yet
        qmd.answer = standardAnswers(collections: [("mine", real, nil), ("repo", "/repo", "git pull")])
        _ = try await collect(provider.search(SearchQuery(text: "x"), in: workspace))
        #expect(!qmd.commands.contains(["update"]))
        #expect(await provider.engine.status.updatesBlockedBy == ["repo"])
    }

    @Test func aFailedUpdateIsTriedAgain() async throws {
        let workspace = try temporaryFolder()
        let real = realPath(workspace.path)
        let normal = standardAnswers(collections: [("mine", real, nil)])
        let qmd = FakeQmd(answer: { $0 == ["update"] ? .init(stderr: "Error: database is locked", status: 1) : normal($0) })
        let provider = makeProvider(qmd: qmd, environment: try FakeEnvironment(), updateInterval: .zero)
        _ = try await collect(provider.search(SearchQuery(text: "x"), in: workspace))
        _ = try await collect(provider.search(SearchQuery(text: "x"), in: workspace))
        #expect(qmd.commands.filter { $0 == ["update"] }.count == 2)  // still dirty after the failure
        qmd.answer = normal
        _ = try await collect(provider.search(SearchQuery(text: "x"), in: workspace))
        _ = try await collect(provider.search(SearchQuery(text: "x"), in: workspace))
        #expect(qmd.commands.filter { $0 == ["update"] }.count == 3)  // clean after the success
    }

    @Test func ourCollectionLeftInDefaultQueriesIsExcludedWhenReused() async throws {
        let workspace = try temporaryFolder()
        let real = realPath(workspace.path)
        let name = QmdMapping.collectionName(forRealRoot: real)
        let qmd = FakeQmd(answer: standardAnswers(collections: [(name, real, nil)]))  // `show` says "Include: yes"
        let provider = makeProvider(qmd: qmd, environment: try FakeEnvironment())
        #expect(try await provider.prepare(workspace: workspace) == .ready)
        #expect(qmd.commands.contains(["collection", "exclude", name]))
        #expect(!provider.folderActions(for: workspace).isEmpty)

        // A user's own collection is left as it is.
        let userQmd = FakeQmd(answer: standardAnswers(collections: [("notes", real, nil)]))
        #expect(try await makeProvider(qmd: userQmd, environment: try FakeEnvironment()).prepare(workspace: workspace) == .ready)
        #expect(!userQmd.commands.contains { $0.count > 1 && $0[1] == "exclude" })
    }

    @Test func aFailedRegistrationIsStillExcluded() async throws {
        let workspace = try temporaryFolder()
        let normal = standardAnswers(collections: [])
        let qmd = FakeQmd(answer: { $0.prefix(2) == ["collection", "add"] ? .init(stderr: "Error: EACCES", status: 1) : normal($0) })
        let provider = makeProvider(qmd: qmd, environment: try FakeEnvironment())
        #expect(try await provider.prepare(workspace: workspace) == .unavailable(L10n.noteFailed("Error: EACCES")))
        let name = QmdMapping.collectionName(forRealRoot: realPath(workspace.path))
        #expect(qmd.commands.suffix(2) == [["collection", "add", realPath(workspace.path), "--name", name, "--mask", QmdMapping.mask], ["collection", "exclude", name]])
    }

    @Test func aParentCollectionWhoseTopResultsAreAllElsewhereLetsTheBuiltinSearchAnswer() async throws {
        let parent = try temporaryFolder("notes")
        let workspace = parent.appending(path: "book", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let elsewhere = (0..<500).map { #"{"file":"\#(realPath(parent.path))/other\#($0).md","line":1}"# }
        let qmd = FakeQmd(answer: standardAnswers(collections: [("notes", realPath(parent.path), nil)], search: "[" + elsewhere.joined(separator: ",") + "]"))
        let provider = makeProvider(qmd: qmd, environment: try FakeEnvironment())
        await #expect(throws: QmdError.failed(status: 0, message: L10n.crowdedOut)) {
            _ = try await collect(provider.search(SearchQuery(text: "x"), in: workspace))
        }
        // Fewer than a full page and none here: simply no matches.
        qmd.answer = standardAnswers(collections: [("notes", realPath(parent.path), nil)], search: "[" + elsewhere.prefix(3).joined(separator: ",") + "]")
        #expect(try await collect(provider.search(SearchQuery(text: "x"), in: workspace)).isEmpty)
    }

    @Test func askingAgainForDeclinedFoldersPreparesThemAgain() async throws {
        let workspace = try temporaryFolder()
        let qmd = FakeQmd(answer: standardAnswers(collections: []))
        let asked = Recorder<QmdConsentRequest>()
        let provider = makeProvider(qmd: qmd, environment: try FakeEnvironment(), consent: .declined, asked: asked)
        #expect(try await provider.prepare(workspace: workspace) == .unavailable(""))
        #expect(try await provider.prepare(workspace: workspace) == .unavailable(""))
        #expect(asked.values.count == 1)
        await provider.engine.resetUnavailable()  // the settings no longer list it (the fake options never did)
        #expect(try await provider.prepare(workspace: workspace) == .unavailable(""))
        #expect(asked.values.count == 2)
    }
}
