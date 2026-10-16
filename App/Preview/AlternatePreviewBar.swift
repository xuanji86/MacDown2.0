import AppKit
import ExtensionAPI
import OSLog
import SwiftUI

private let log = Logger(subsystem: "io.github.xuanji86.MacDown2", category: "alternate-preview")

/// One document's real render (PLAN 4.6.2): the running session, if the user switched it on, and whether they already agreed to
/// run this document's code in this session (asked once per opened document). Shared by every window showing the document.
@MainActor @Observable
final class AlternatePreviewState {
    var session: (any AlternatePreviewSession)?
    /// The file the user agreed to render (asked once per opened document); a move or Save As to another path asks again, so a
    /// document moved into a Quarto project gets the project question.
    private var confirmedURL: URL?
    /// The availability check and the question before a start; cancelled by `switchOff` (the document closed or moved meanwhile).
    private var starting: Task<Void, Never>?
    /// An availability check or the confirmation is under way: a second click must not ask twice.
    var switching: Bool { starting != nil }

    /// The real render is on (starting, showing, or failed with its banner up).
    var isActive: Bool { session?.status.isActive == true }

    /// The real render `flavor` offers for the document at `fileURL`; none for an untitled document (no file for the tool to render).
    static func mode(of flavor: (any DocumentFlavor)?, fileURL: URL?) -> (any AlternatePreviewMode)? {
        fileURL == nil ? nil : flavor?.alternatePreviewMode
    }

    /// The menu item and the `Approximate | <title>` switch: back to the app's own preview when the real render is on, else
    /// `switchOn`.
    func toggle(_ mode: any AlternatePreviewMode, fileURL: URL, window: NSWindow?) {
        if isActive { switchOff() } else { switchOn(mode, fileURL: fileURL, window: window) }
    }

    /// The user switched the preview to `mode` (segmented control, menu item). Never called by anything else: nothing starts by itself.
    /// Looks for the tool first (an alert when it is missing), then asks before running the document's code, once per document session.
    /// A `switchOff` while that is under way cancels it, and nothing is started after a cancel.
    func switchOn(_ mode: any AlternatePreviewMode, fileURL: URL, window: NSWindow?) {
        guard !isActive, starting == nil else { return }
        starting = Task {
            defer { if !Task.isCancelled { starting = nil } }  // a cancel has cleared it already (and a new start may be under way)
            let availability = await mode.isAvailable()
            log.info("real render: availability \(String(describing: availability), privacy: .public)")
            guard !Task.isCancelled else { return }
            if case .unavailable(let reason) = availability {
                await Self.alert(title: String(localized: "Real rendering is not available"), message: reason, button: nil, in: window)
                return
            }
            if confirmedURL != fileURL.standardizedFileURL, let ask = mode.confirmation(for: fileURL) {
                let go = await Self.alert(title: ask.title, message: ask.message, button: ask.confirmButton, in: window)
                log.info("real render: confirmation answered \(go ? "render" : "cancel", privacy: .public)")
                guard go, !Task.isCancelled else { return }
                confirmedURL = fileURL.standardizedFileURL
                mode.confirmed(for: fileURL)
            }
            let session = mode.session(for: fileURL)
            self.session = session
            await session.start()  // a `switchOff` from here on stops the session itself
        }
    }

    /// Back to the app's own preview: a start that is still asking is cancelled, a running tool is stopped at once (SIGTERM, SIGKILL
    /// after 3 s). Also when the document closes or its file moves (the tool would go on with the old path).
    func switchOff() {
        starting?.cancel()
        starting = nil
        guard let session else { return }
        Task { await session.stop() }
    }

    /// A sheet on `window` (a modal alert without one). With `button`: [Cancel] [button], true for `button`; without: just OK.
    @discardableResult
    private static func alert(title: String, message: String, button: String?, in window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let button {
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.addButton(withTitle: button)
        }
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            alert.present(on: window) { continuation.resume(returning: $0) }
            if let window { IsolatedTestHooks.answer(alert, on: window) }  // isolated Debug runs only: MACDOWN2_TEST_PROMPT_ANSWER=reload is the second button
        }
        return button != nil && response == .alertSecondButtonReturn
    }
}

/// The thin bar on top of the preview of a document whose flavor has a real render: `[Approximate | Quarto]` · last render time ·
/// status · [Log], and "Unsaved changes are not rendered yet" while the editor is ahead of the file Quarto renders.
struct AlternatePreviewBar: View {
    let mode: any AlternatePreviewMode
    let state: AlternatePreviewState
    let fileURL: URL
    let edited: EditedFlag
    @State private var shownLog: String?

    var body: some View {
        HStack(spacing: 8) {
            Picker(selection: Binding(get: { state.isActive }, set: { on in if on != state.isActive { toggle() } })) {
                Text("Approximate").tag(false)
                Text(verbatim: mode.title).tag(true)
            } label: {
                Text("Preview")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(state.switching)
            .help(mode.commandTitle)
            if let session = state.session, session.status.isActive {
                status(session)
                if edited.value {
                    Text("Unsaved changes are not rendered yet").foregroundStyle(.orange).lineLimit(1).layoutPriority(1)
                }
                Spacer(minLength: 4)
                Button("Log") { shownLog = session.logText() }
            } else {
                Spacer(minLength: 0)
            }
        }
        .font(.caption)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
        .sheet(item: Binding(get: { shownLog.map(LogText.init) }, set: { shownLog = $0?.text })) { text in
            LogSheet(title: mode.title, text: text.text)
        }
    }

    private func toggle() {
        state.toggle(mode, fileURL: fileURL, window: NSApp.keyWindow)
    }

    @ViewBuilder private func status(_ session: any AlternatePreviewSession) -> some View {
        switch session.status {
        case .starting:
            ProgressView().controlSize(.mini)
            Text("Starting…").lineLimit(1)
        case .rendering:
            ProgressView().controlSize(.mini)
            Text("Rendering…").lineLimit(1)
        case .ready:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
            if let date = session.lastRendered {
                Text("Last rendered \(date.formatted(date: .omitted, time: .standard))").lineLimit(1)
            }
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).accessibilityHidden(true)
            Text(verbatim: message).lineLimit(1).truncationMode(.tail).help(message)
        case .stopped:
            EmptyView()
        }
    }
}

private struct LogText: Identifiable {
    let text: String
    var id: String { text }
}

/// "View Log": the tool's error entries (or the end of its output), selectable.
private struct LogSheet: View {
    let title: String
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: title).font(.headline)
            ScrollView {
                Text(verbatim: text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 200, maxHeight: 420)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 560)
    }
}
