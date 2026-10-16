import ExtensionAPI
import Foundation
import Observation

/// Quarto real render (PLAN 4.6.2), the `AlternatePreviewMode` of the quarto flavor while the "Quarto real render" switch is on.
///
/// Holds the switch and the other settings, the result of looking for `quarto`, and one session per document (by standardized
/// path, so every window showing a file shares one `quarto preview`). Creating it probes nothing; `isAvailable()` (the user's first
/// switch to Quarto) and the settings pane are the only callers of the locator.
@MainActor @Observable
public final class QuartoRealRender: AlternatePreviewMode {
    enum Key {
        static let realRender = "realRender"
        static let askEveryTime = "askEveryTime"
        static let quartoPath = "quartoPath"
    }

    @ObservationIgnored private let settings: ExtensionSettingsStore
    @ObservationIgnored let toolEnvironment: any ToolEnvironment
    /// Runs `quarto --version` in the given environment; replaceable in tests.
    @ObservationIgnored private let makeSpawner: @Sendable ([String: String]) -> any ProcessSpawner
    @ObservationIgnored private let fallbackDirectories: [String]
    @ObservationIgnored private var sessions: [String: QuartoPreviewSession] = [:]
    @ObservationIgnored private var probing: Task<QuartoLookup, Never>?

    /// "Quarto real render" (default on). Off: the flavor offers no mode, and every running preview stops.
    public var isOn: Bool {
        didSet {
            guard isOn != oldValue else { return }
            settings.set(isOn, for: Key.realRender)
            if !isOn { Task { await stopAll() } }
        }
    }

    /// "Ask before rendering" (default on): confirm once per document session before the first start.
    public var asksEveryTime: Bool {
        didSet { settings.set(asksEveryTime, for: Key.askEveryTime) }
    }

    /// The manual quarto path; empty = find it.
    public var manualPath: String {
        didSet {
            guard manualPath != oldValue else { return }
            settings.set(manualPath.isEmpty ? nil : manualPath, for: Key.quartoPath)
            lookup = nil
        }
    }

    /// What the last look for quarto found; nil = not looked yet (or the path setting changed since).
    public private(set) var lookup: QuartoLookup?
    /// `QUARTO_PYTHON` / `QUARTO_R` in the tool environment, once it has been read for a lookup.
    public private(set) var environmentValues: [String: String] = [:]

    init(
        settings: ExtensionSettingsStore, toolEnvironment: any ToolEnvironment,
        makeSpawner: @escaping @Sendable ([String: String]) -> any ProcessSpawner = { SystemProcessSpawner(environment: $0) },
        fallbackDirectories: [String] = QuartoLocator.fallbackDirectories
    ) {
        self.settings = settings
        self.toolEnvironment = toolEnvironment
        self.makeSpawner = makeSpawner
        self.fallbackDirectories = fallbackDirectories
        isOn = settings.bool(Key.realRender) ?? true
        asksEveryTime = settings.bool(Key.askEveryTime) ?? true
        manualPath = settings.string(Key.quartoPath) ?? ""
    }

    // MARK: AlternatePreviewMode

    public var title: String { String(localized: L10n.resource("Quarto")) }
    public var commandTitle: String { L10n.commandTitle }

    public var confirmation: AlternatePreviewConfirmation? {
        asksEveryTime ? AlternatePreviewConfirmation(title: L10n.confirmTitle, message: L10n.confirmMessage, confirmButton: L10n.confirmButton) : nil
    }

    /// A quarto that was found is remembered; one that was not is looked for again next time (it may have been installed since).
    public func isAvailable() async -> AlternatePreviewAvailability {
        switch await probe() {
        case .found: .available
        case .notFound(let reason): .unavailable(reason)
        }
    }

    public func session(for fileURL: URL) -> any AlternatePreviewSession {
        let key = fileURL.standardizedFileURL.path
        if let session = sessions[key] { return session }
        let session = QuartoPreviewSession(fileURL: fileURL.standardizedFileURL, owner: self)
        sessions[key] = session
        return session
    }

    // MARK: Looking for quarto

    /// Looks for quarto (reading the login shell's environment first, PLAN 4.16), unless one was found already. `force`: look again.
    @discardableResult
    func probe(force: Bool = false) async -> QuartoLookup {
        if !force, case .found = lookup { return lookup! }
        if let probing { return await probing.value }
        let manual = manualPath, makeSpawner = makeSpawner, fallbackDirectories = fallbackDirectories, toolEnvironment = toolEnvironment
        let task = Task { () -> QuartoLookup in
            let snapshot = await toolEnvironment.snapshot()
            let found = await QuartoLocator.locate(manualPath: manual, environment: snapshot, spawner: makeSpawner(snapshot.environment), fallbackDirectories: fallbackDirectories)
            self.environmentValues = snapshot.environment.filter { $0.key == "QUARTO_PYTHON" || $0.key == "QUARTO_R" }
            return found
        }
        probing = task
        let result = await task.value
        probing = nil
        // A path changed while looking: that answer is about the old one.
        if manual == manualPath { lookup = result }
        return result
    }

    /// The settings pane: look only when the switch is on (off means no probing at all).
    public func probeForSettings(force: Bool) async {
        guard isOn else { return }
        await probe(force: force)
    }

    /// Sessions with a process (tests).
    var runningSessions: Int { sessions.values.filter { $0.status.isActive }.count }

    /// Stops every document's preview (switch off, extension off). Sessions stay known; they are stopped, not running.
    func stopAll() async {
        let running = Array(sessions.values)
        sessions = [:]
        for session in running { await session.stop() }
    }
}

/// One document's `quarto preview` as the app sees it: page URL, status, last render time, log.
@MainActor @Observable
final class QuartoPreviewSession: AlternatePreviewSession {
    let fileURL: URL
    private(set) var url: URL?
    private(set) var status: AlternatePreviewStatus = .stopped
    private(set) var lastRendered: Date?

    @ObservationIgnored private weak var owner: QuartoRealRender?
    @ObservationIgnored private var process: QuartoPreviewProcess?
    @ObservationIgnored private var listener: Task<Void, Never>?
    /// What "View Log" shows when there is no process (a failed start, or one that exited).
    @ObservationIgnored private var lastLog: String?

    init(fileURL: URL, owner: QuartoRealRender) {
        self.fileURL = fileURL
        self.owner = owner
    }

    func logText() -> String {
        if let process { return liveLogText(process) }
        return lastLog ?? L10n.emptyLog
    }

    /// The live process's log, read now: error entries from its JSON log file, else the end of what it printed.
    private func liveLogText(_ process: QuartoPreviewProcess) -> String {
        let errors = QuartoLog.errors(in: process.logFile)
        let lines = errors.isEmpty ? process.console.lines : errors
        return lines.isEmpty ? L10n.emptyLog : lines.joined(separator: "\n")
    }

    func start() async {
        guard process == nil, status != .starting, let owner else { return }
        status = .starting
        url = nil
        lastLog = nil
        guard case .found(let location) = await owner.probe() else {
            if case .notFound(let reason) = owner.lookup ?? .notFound(L10n.quartoNotFound) {
                lastLog = reason
                status = .failed(reason)
            }
            return
        }
        // Stopped while looking.
        guard status == .starting else { return }
        let environment = await owner.toolEnvironment.snapshot().environment
        guard status == .starting else { return }
        let process = QuartoPreviewProcess(quarto: location.path, document: fileURL, environment: environment)
        self.process = process
        listener = Task { [weak self] in
            for await event in process.events {
                self?.apply(event, from: process)
            }
        }
        do {
            let page = try await process.start()
            guard self.process === process else { return }
            url = page
            if status == .starting { status = .ready }
        } catch {
            guard self.process === process else { return }
            self.process = nil
            listener?.cancel()
            lastLog = await process.logText()
            status = .failed(Self.message(for: error))
        }
    }

    func stop() async {
        guard status != .stopped || process != nil else { return }
        let running = process
        process = nil
        listener?.cancel()
        listener = nil
        url = nil
        status = .stopped
        await running?.stop()
    }

    private func apply(_ event: QuartoPreviewProcess.Event, from process: QuartoPreviewProcess) {
        guard self.process === process else { return }
        switch event {
        case .rendering:
            if url != nil { status = .rendering }
        case .rendered(let date):
            lastRendered = date
            if url != nil { status = .ready }
        case .renderFailed:
            status = .failed(L10n.renderFailed)
        case .exited(let code):
            self.process = nil
            lastLog = liveLogText(process)
            Task { [weak self] in
                let text = await process.logText()  // the error entries read just before the log file was deleted
                self?.lastLog = text
            }
            status = .failed(L10n.exited(Int(code)))
        }
    }

    private static func message(for error: any Error) -> String {
        switch error as? QuartoPreviewProcess.StartError {
        case .launch(let reason): L10n.launchFailed(reason)
        case .timedOut: L10n.startTimedOut
        case .exited(let code): L10n.exited(Int(code))
        case .stopped, nil: L10n.launchFailed(error.localizedDescription)
        }
    }
}
