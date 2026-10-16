import Darwin
import ExtensionAPI
import Foundation
import Testing
import WorkspaceKit
@testable import QmdSearchExtension

/// Semantic search is set up in the background (models downloaded, the folder embedded) before its first query.
struct SetupTests {
    private struct Rig {
        let workspace: URL
        let qmd: FakeQmd
        let options: Box<QmdOptions>
        let remembered: Recorder<String>
        let forgotten: Recorder<String>
        let provider: QmdSearchProvider
        var engine: QmdEngine { provider.engine }

        /// `environment`: on top of a qmd cache and config folder of its own (never the user's).
        init(semantic: Bool = true, remembered ready: Set<String> = [], environment extra: [String: String] = [:], queryTimeout: Duration = .seconds(60),
             search: String = "[]") throws {
            let workspace = try temporaryFolder()
            let qmd = FakeQmd(answer: standardAnswers(collections: [("mine", realPath(workspace.path), nil)], search: search))
            let options = Box(QmdOptions(semantic: semantic, semanticReady: ready))
            let (remembered, forgotten) = (Recorder<String>(), Recorder<String>())
            let own = workspace.deletingLastPathComponent()
            var environment = ["XDG_CACHE_HOME": own.appending(path: "cache").path, "QMD_CONFIG_DIR": own.appending(path: "config").path]
            environment.merge(extra) { $1 }
            (self.workspace, self.qmd, self.options, self.remembered, self.forgotten) = (workspace, qmd, options, remembered, forgotten)
            provider = QmdSearchProvider(dependencies: QmdEngine.Dependencies(
                environment: try FakeEnvironment(extra: environment),
                makeSpawner: { qmd.makeSpawner($0) },
                options: { options.value },
                consent: { _ in .register },
                decline: { _ in },
                watchFolders: false,
                rememberSetup: { name, done in done ? remembered.add(name) : forgotten.add(name) },
                setupPollInterval: .milliseconds(10),
                queryTimeout: queryTimeout
            ), semantic: semantic)
        }

        func state() async -> SemanticSetup? { await engine.setupState("mine") }
        func board() async -> SemanticSetup { await MainActor.run { provider.semanticSetup(for: workspace) } }
        func semantic(_ text: String = "how it works") async throws -> [SearchHit] {
            try await collect(provider.search(SearchQuery(text: text, isSemantic: true), in: workspace))
        }
        func keyword(_ text: String = "works") async throws -> [SearchHit] { try await collect(provider.search(SearchQuery(text: text), in: workspace)) }
        var embeds: Int { qmd.commands.filter { $0.first == "embed" }.count }
        var queries: [[String]] { qmd.commands.filter { $0.first == "query" } }
    }

    @Test func preparingAFolderEmbedsItAndWarmsTheModelsUpBeforeTheFirstSemanticSearch() async throws {
        let rig = try Rig()
        #expect(try await rig.provider.prepare(workspace: rig.workspace) == .ready)
        #expect(await eventually(rig.state, { $0 == .ready }) == .ready)
        #expect(await eventually(rig.board, { $0 == .ready }) == .ready)
        #expect(rig.remembered.values == ["mine"])

        let setup = rig.qmd.commands.filter { ["embed", "query"].contains($0.first) }
        #expect(setup.count == 2)
        #expect(setup.first == ["embed", "-c", "mine"])
        let warmUp = try #require(setup.last)
        #expect(Array(warmUp.prefix(7)) == ["query", "-c", "mine", "-n", "1", "--format", "json"])
        #expect(warmUp.contains("--no-rerank") && warmUp.dropLast().last == "--" && warmUp.last?.hasPrefix("macdown2 setup ") == true)

        // The search itself only queries: the setup is not on its path.
        _ = try await rig.semantic()
        #expect(rig.embeds == 1)
        #expect(rig.queries.last == ["query", "-c", "mine", "-n", "30", "--format", "json", "--full-path", "--no-rerank", "--", "how it works"])
    }

    @Test func whileTheSetupRunsTheSemanticEntryWaitsAndKeywordSearchWorks() async throws {
        let rig = try Rig(search: #"[{"file":"/nowhere/x.md","line":1}]"#)
        let gate = Gate()
        rig.qmd.delay = { args in if args.first == "embed" { await gate.wait() } }
        _ = try await rig.provider.prepare(workspace: rig.workspace)

        let preparing = SemanticSetup.preparing(L10n.setupText(.embedding(files: 1)))  // `collection list` says 1 file
        #expect(await eventually(rig.board, { $0 == preparing }) == preparing)
        await #expect(throws: QmdError.failed(status: 0, message: L10n.semanticNotReady)) { _ = try await rig.semantic() }
        #expect(rig.queries.isEmpty)
        _ = try await rig.keyword()
        #expect(rig.qmd.commands.last?.first == "search")
        #expect(await rig.state() == preparing)

        gate.pass()
        #expect(await eventually(rig.board, { $0 == .ready }) == .ready)
        _ = try await rig.semantic()
        #expect(rig.queries.last?.last == "how it works")
    }

    @Test func theSetupIsNotBoundByTheSearchTimeout() async throws {
        let rig = try Rig(queryTimeout: .milliseconds(200))
        rig.qmd.delay = { args in if args.first == "query" { try? await Task.sleep(for: .milliseconds(600)) } }
        _ = try await rig.provider.prepare(workspace: rig.workspace)
        #expect(await eventually(rig.state, { if case .preparing? = $0 { false } else { true } }) == .ready)
        // The same delay in a search is cut off.
        await #expect(throws: QmdError.failed(status: 1, message: L10n.semanticFailed(L10n.timedOut(0)))) { _ = try await rig.semantic() }
    }

    @Test func progressReadsDownloadsFromQmdsModelCache() async throws {
        let cache = try temporaryFolder("cache")
        let models = cache.appending(path: "qmd/models").path
        let rig = try Rig(environment: ["XDG_CACHE_HOME": cache.path])
        let gate = Gate()
        rig.qmd.delay = { args in
            guard args.first == "embed" else { return }
            try? FileManager.default.createDirectory(atPath: models, withIntermediateDirectories: true)
            try? writeSparse(models + "/hf_org_model.gguf.ipull", size: 64 << 20, written: 1 << 20)
            await gate.wait()
        }
        _ = try await rig.provider.prepare(workspace: rig.workspace)
        _ = await eventually({ gate.waited }, { $0 == 1 })  // the file is written
        let progress = try #require(QmdFiles.downloads(in: models))
        #expect(progress.total == 64 << 20 && progress.done >= 1 << 20 && progress.done < progress.total)
        let downloading = SemanticSetup.preparing(L10n.downloadingText(done: progress.done, total: progress.total))
        #expect(await eventually(rig.board, { $0 == downloading }) == downloading)

        // Downloaded (renamed): the step shows again.
        try FileManager.default.moveItem(atPath: models + "/hf_org_model.gguf.ipull", toPath: models + "/hf_org_model.gguf")
        let embedding = SemanticSetup.preparing(L10n.setupText(.embedding(files: 1)))
        #expect(await eventually(rig.board, { $0 == embedding }) == embedding)
        gate.pass()
        #expect(await eventually(rig.state, { $0 == .ready }) == .ready)
    }

    @Test func cancellingStopsTheSetupAndRetryRunsItAgain() async throws {
        let rig = try Rig()
        let gate = Gate()
        rig.qmd.delay = { args in if args.first == "embed" { await gate.wait() } }
        _ = try await rig.provider.prepare(workspace: rig.workspace)
        _ = await eventually({ gate.waited }, { $0 == 1 })

        await MainActor.run { rig.provider.cancelSemanticSetup(for: rig.workspace) }
        let stopped = SemanticSetup.failed(L10n.setupStopped)
        #expect(await eventually(rig.board, { $0 == stopped }) == stopped)
        #expect(rig.queries.isEmpty && rig.remembered.values.isEmpty)
        await #expect(throws: QmdError.failed(status: 0, message: L10n.setupStopped)) { _ = try await rig.semantic() }
        // Not started again on its own (another prepare, a search): only Retry does.
        _ = try await rig.provider.prepare(workspace: rig.workspace)
        #expect(rig.embeds == 1)

        gate.pass()
        await MainActor.run { rig.provider.retrySemanticSetup(for: rig.workspace) }
        #expect(await eventually(rig.board, { $0 == .ready }) == .ready)
        #expect(rig.embeds == 2 && rig.remembered.values == ["mine"])
    }

    @Test func aFailedSetupShowsWhyUntilRetriedAndKeywordSearchKeepsWorking() async throws {
        let rig = try Rig()
        let normal = standardAnswers(collections: [("mine", realPath(rig.workspace.path), nil)])
        rig.qmd.answer = { $0.first == "embed" ? .init(stderr: "Error: sqlite-vec is not available", status: 1) : normal($0) }
        _ = try await rig.provider.prepare(workspace: rig.workspace)
        let failed = SemanticSetup.failed(L10n.setupFailed("Error: sqlite-vec is not available"))
        #expect(await eventually(rig.board, { $0 == failed }) == failed)
        await #expect(throws: QmdError.failed(status: 0, message: L10n.setupFailed("Error: sqlite-vec is not available"))) { _ = try await rig.semantic() }
        #expect(try await rig.keyword().isEmpty)
        #expect(rig.queries.isEmpty)

        rig.qmd.answer = normal
        await MainActor.run { rig.provider.retrySemanticSetup(for: rig.workspace) }
        #expect(await eventually(rig.board, { $0 == .ready }) == .ready)
    }

    @Test func anotherEmbedHoldingQmdsLockIsAFailureNotASetup() async throws {
        let rig = try Rig()
        let normal = standardAnswers(collections: [("mine", realPath(rig.workspace.path), nil)])
        rig.qmd.answer = { $0.first == "embed" ? .init(stdout: "Another embed process is already running. Skipping.\n") : normal($0) }
        _ = try await rig.provider.prepare(workspace: rig.workspace)
        let failed = SemanticSetup.failed(L10n.setupFailed(L10n.embedBusy))
        #expect(await eventually(rig.state, { $0 == failed }) == failed)
        #expect(rig.remembered.values.isEmpty)
    }

    @Test func aFinishedSetupIsRememberedWhileQmdStillHasTheModels() async throws {
        let root = try temporaryFolder("qmd")
        let models = root.appending(path: "cache/qmd/models")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "config"), withIntermediateDirectories: true)
        try Data("""
        collections:
          mine:
            path: /x
        models:
          embed: hf:org/embed-GGUF/embed-Q8_0.gguf
          generate: "hf:org/gen-gguf/gen-q4_k_m.gguf"
          rerank: hf:org/rerank-GGUF/rerank-q8_0.gguf
        """.utf8).write(to: root.appending(path: "config/index.yml"))
        for file in ["hf_org_embed-Q8_0.gguf", "hf_org_gen-q4_k_m.gguf"] { try Data("GGUF".utf8).write(to: models.appending(path: file)) }
        let environment = ["XDG_CACHE_HOME": root.appending(path: "cache").path, "QMD_CONFIG_DIR": root.appending(path: "config").path]

        // Remembered, models there: ready at once, nothing runs.
        let rig = try Rig(remembered: ["mine"], environment: environment)
        _ = try await rig.provider.prepare(workspace: rig.workspace)
        #expect(await rig.state() == .ready)
        #expect(rig.embeds == 0 && rig.queries.isEmpty)

        // Reranking needs a model that is not there: set up again (the warm-up then reranks, which fetches it).
        rig.options.value.rerank = true
        await rig.engine.semanticSettingsChanged()
        #expect(await eventually(rig.state, { $0 == .ready }) == .ready)
        #expect(rig.embeds == 1 && rig.queries.last?.contains("--no-rerank") == false)

        // qmd's cache was cleared: a new launch sets up again even though it was remembered.
        try FileManager.default.removeItem(at: models)
        let relaunched = try Rig(remembered: ["mine"], environment: environment)
        _ = try await relaunched.provider.prepare(workspace: relaunched.workspace)
        #expect(await eventually(relaunched.state, { $0 == .ready }) == .ready)
        #expect(relaunched.embeds == 1)
    }

    @Test func aRememberedSetupWithoutEmbeddingsIsSetUpAgainOnce() async throws {
        let rig = try Rig(remembered: ["mine"])  // its own empty qmd cache: no models
        _ = try await rig.provider.prepare(workspace: rig.workspace)
        #expect(await eventually(rig.state, { $0 == .ready }) == .ready)
        #expect(rig.embeds == 1)

        let normal = standardAnswers(collections: [("mine", realPath(rig.workspace.path), nil)])
        rig.qmd.answer = { args in
            args.first == "query" && args.last == "lost" ? .init(stdout: "[]", stderr: "Warning: 5 documents (100%) need embeddings. Run 'qmd embed' for better results.") : normal(args)
        }
        #expect(try await rig.semantic("lost").isEmpty)
        #expect(rig.forgotten.values == ["mine"])
        #expect(await eventually(rig.state, { $0 == .ready }) == .ready)
        #expect(rig.embeds == 2)
        #expect(try await rig.semantic("lost").isEmpty)
        #expect(rig.embeds == 2)  // once per session: no loop
    }

    @Test func switchingSemanticSearchOffStopsTheSetupAndOnStartsIt() async throws {
        let rig = try Rig()
        let gate = Gate()
        rig.qmd.delay = { args in if args.first == "embed" { await gate.wait() } }
        _ = try await rig.provider.prepare(workspace: rig.workspace)
        _ = await eventually({ gate.waited }, { $0 == 1 })

        rig.options.value.semantic = false
        rig.provider.setSemantic(false)
        await rig.engine.semanticSettingsChanged()
        #expect(await rig.state() == nil)
        #expect(await rig.board() == .ready)  // nothing to wait for: the sparkles button is gone
        #expect(rig.provider.capabilities == .keyword)

        gate.pass()
        rig.options.value.semantic = true
        rig.provider.setSemantic(true)
        await rig.engine.semanticSettingsChanged()
        #expect(await eventually(rig.board, { $0 == .ready }) == .ready)
        #expect(rig.embeds == 2 && rig.remembered.values == ["mine"])
    }

    @Test func semanticOffNeverSetsUp() async throws {
        let rig = try Rig(semantic: false)
        _ = try await rig.provider.prepare(workspace: rig.workspace)
        _ = try await rig.keyword()
        #expect(await rig.state() == nil && rig.embeds == 0 && rig.queries.isEmpty)
    }
}

struct ModelCacheTests {
    @Test func downloadsAreTheBlocksOnDiskOfThePreallocatedFiles() throws {
        let dir = try temporaryFolder("models").path
        #expect(QmdFiles.downloads(in: dir) == nil)
        #expect(QmdFiles.downloads(in: dir + "/missing") == nil)
        try Data("GGUF".utf8).write(to: URL(filePath: dir + "/done.gguf"))
        #expect(QmdFiles.downloads(in: dir) == nil)
        try writeSparse(dir + "/a.gguf.ipull", size: 32 << 20, written: 2 << 20)
        let progress = try #require(QmdFiles.downloads(in: dir))
        #expect(progress.total == 32 << 20)
        #expect(progress.done >= 2 << 20 && progress.done < 8 << 20)
    }

    @Test func theConfiguredModelsAreReadFromIndexYml() {
        let yaml = """
        collections:
          embed:
            path: /a collection called embed
        models:
          embed: hf:a/b/e.gguf
          generate: 'hf:a/b/g.gguf'
          rerank: /models/r.gguf
        other:
          embed: nope
        """
        #expect(QmdFiles.configuredModels(yaml) == ["embed": "hf:a/b/e.gguf", "generate": "hf:a/b/g.gguf", "rerank": "/models/r.gguf"])
        #expect(QmdFiles.configuredModels("collections: {}\n").isEmpty)
    }

    @Test func theModelsArePresentWhenQmdCouldLoadThem() throws {
        let root = try temporaryFolder("qmd")
        let cache = root.appending(path: "cache").path, config = root.appending(path: "config").path
        try FileManager.default.createDirectory(atPath: cache + "/models", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: config, withIntermediateDirectories: true)
        // No index.yml: any model will do, and there is none.
        #expect(!QmdFiles.modelsPresent(cache: cache, config: config, rerank: false))
        try Data().write(to: URL(filePath: cache + "/models/hf_x_old.gguf"))
        #expect(QmdFiles.modelsPresent(cache: cache, config: config, rerank: false))

        let local = root.appending(path: "r.gguf").path
        try Data("models:\n  embed: hf:x/e-GGUF/e.gguf\n  generate: hf:x/g-GGUF/g.gguf\n  rerank: \(local)\n".utf8).write(to: URL(filePath: config + "/index.yml"))
        #expect(!QmdFiles.modelsPresent(cache: cache, config: config, rerank: false))
        try Data().write(to: URL(filePath: cache + "/models/hf_x_e.gguf"))
        try Data().write(to: URL(filePath: cache + "/models/hf_x_g.gguf.ipull"))  // still downloading
        #expect(!QmdFiles.modelsPresent(cache: cache, config: config, rerank: false))
        try FileManager.default.moveItem(atPath: cache + "/models/hf_x_g.gguf.ipull", toPath: cache + "/models/hf_x_g.gguf")
        #expect(QmdFiles.modelsPresent(cache: cache, config: config, rerank: false))
        #expect(!QmdFiles.modelsPresent(cache: cache, config: config, rerank: true))
        try Data().write(to: URL(filePath: local))
        #expect(QmdFiles.modelsPresent(cache: cache, config: config, rerank: true))

        #expect(QmdFiles.cacheDirectory(["HOME": "/h"]) == "/h/.cache/qmd")
        #expect(QmdFiles.cacheDirectory(["HOME": "/h", "XDG_CACHE_HOME": ""]) == "/h/.cache/qmd")
        #expect(QmdFiles.configDirectory(["HOME": "/h", "XDG_CONFIG_HOME": "/x"]) == "/x/qmd")
        #expect(QmdFiles.configDirectory(["HOME": "/h", "XDG_CONFIG_HOME": "/x", "QMD_CONFIG_DIR": "/q"]) == "/q")
    }
}

struct HighlightTests {
    private func marked(_ line: String, _ query: String, wholeWords: Bool) -> [String] {
        let (text, ranges) = QmdMapping.shorten(line, terms: QmdMapping.terms(of: query), wholeWords: wholeWords)
        return ranges.map { (text as NSString).substring(with: NSRange($0)) }
    }

    @Test func semanticResultsMarkWholeWordsOnly() {
        let line = "The watering of plants in spring; inside, the rain."
        #expect(marked(line, "the plants in", wholeWords: true) == ["The", "plants", "in", "the"])
        // A keyword search keeps the built-in search's substring matching.
        #expect(marked(line, "in", wholeWords: false).count == 5)  // watering, in, spring, inside, rain
        #expect(marked("Café, CAFÉ and cafeteria", "cafe", wholeWords: true) == ["Café", "CAFÉ"])
        #expect(marked("snake_case and case", "case", wholeWords: true) == ["case"])
        #expect(marked("C++ and ObjC++ code", "C++", wholeWords: true) == ["C++"])
        #expect(marked("2026-10 and 20261", "2026", wholeWords: true) == ["2026"])
    }

    @Test func termsInScriptsWithoutSpacesStillMatchInsideText() {
        #expect(marked("我们一起学习中文测试的方法", "中文 测试", wholeWords: true) == ["中文测试"])  // adjacent marks merge
        #expect(marked("API接口和APIs", "API", wholeWords: true) == ["API"])
        #expect(marked("日本語のテキストです", "テキスト", wholeWords: true) == ["テキスト"])
        #expect(marked("한국어문장입니다", "문장", wholeWords: true) == ["문장"])
    }

    @Test func aSemanticSearchHighlightsWholeWordsAndAKeywordSearchSubstrings() async throws {
        let workspace = try temporaryFolder()
        let real = realPath(workspace.path)
        let search = #"[{"file":"\#(real)/a.md","line":1,"snippet":"@@ -1,1 @@ (0 before, 0 after)\nWatering the fern in winter\n"}]"#
        let qmd = FakeQmd(answer: standardAnswers(collections: [("mine", real, nil)], search: search))
        let provider = makeProvider(qmd: qmd, environment: try FakeEnvironment(), options: QmdOptions(semantic: true))
        _ = try await provider.prepare(workspace: workspace)
        #expect(await eventually({ await provider.engine.setupState("mine") }, { $0 == .ready }) == .ready)
        func marks(_ query: SearchQuery) async throws -> [String] {
            let hit = try #require(try await collect(provider.search(query, in: workspace)).first)
            return hit.highlights.map { (hit.snippet as NSString).substring(with: NSRange($0)) }
        }
        #expect(try await marks(SearchQuery(text: "in", isSemantic: true)) == ["in"])
        #expect(try await marks(SearchQuery(text: "in")) == ["in", "in", "in"])  // also inside "Watering" and "winter"
    }
}

/// A file of `size` bytes with only its first `written` bytes on disk, like a download node-llama-cpp preallocated.
func writeSparse(_ path: String, size: Int, written: Int) throws {
    let fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
    guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
    defer { close(fd) }
    guard ftruncate(fd, off_t(size)) == 0 else { throw CocoaError(.fileWriteUnknown) }
    let chunk = [UInt8](repeating: 7, count: written)
    guard pwrite(fd, chunk, written, 0) == written else { throw CocoaError(.fileWriteUnknown) }
}
