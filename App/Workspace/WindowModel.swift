import AppKit
import Combine
import Observation
import SwiftUI
import WorkspaceKit

/// Everything one workspace window keeps: its tabs (`WorkspaceController`), which sidebar page shows, and the
/// editor/preview split. `state` is what a relaunch restores.
@MainActor @Observable
final class WindowModel {
    let controller: WorkspaceController
    var sidebarSection = SidebarSection.files
    var sidebarVisible = true
    var splitMode = SplitLayout.Mode.both.rawValue
    var editorFraction = 0.5

    // AppKit side, filled in once the window exists.
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored var windowController: NSWindowController?
    @ObservationIgnored var editedSink: AnyCancellable?
    @ObservationIgnored var closeGuard: WindowCloseGuard?
    @ObservationIgnored var isRegistered = false
    /// True from creation until the first moments of the window have passed (see `WorkspaceView`).
    @ObservationIgnored var isRestoring = true

    init(registry: WorkspaceRegistry = .shared) {
        // Deliberately free of side effects: SwiftUI may build this more than once before it keeps one (`register` does the rest).
        controller = WorkspaceController(ledger: registry.ledger, backend: registry)
    }

    var layout: SplitLayout {
        get { SplitLayout(mode: SplitLayout.Mode(rawValue: splitMode) ?? .both, editorFraction: editorFraction) }
        set {
            splitMode = newValue.mode.rawValue
            editorFraction = newValue.editorFraction
        }
    }

    var state: WorkspaceWindowState {
        WorkspaceWindowState(
            id: controller.id, session: controller.session, sidebarSection: sidebarSection,
            sidebarVisible: sidebarVisible, splitMode: splitMode, editorFraction: editorFraction
        )
    }

    func apply(_ saved: WorkspaceWindowState) {
        sidebarSection = saved.sidebarSection
        sidebarVisible = saved.sidebarVisible
        splitMode = SplitLayout.Mode(rawValue: saved.splitMode)?.rawValue ?? SplitLayout.Mode.both.rawValue
        editorFraction = min(max(saved.editorFraction, SplitLayout.minFraction), SplitLayout.maxFraction)
        controller.restore(saved.session)
    }

    var activeDocument: MarkdownDocument? { controller.activeURL.flatMap { WorkspaceRegistry.shared.document(for: $0) } }

    /// ⌘⌃O: the outline page, and the sidebar shown.
    func showOutline() {
        sidebarSection = .outline
        sidebarVisible = true
    }

    /// ⌘W: closes the active tab; with no tab left it closes the window.
    func closeActiveTab() {
        guard let url = controller.activeURL else { window?.performClose(nil); return }
        closeTab(url)
    }

    /// Closes a tab after the save prompt; the window goes with its last tab (design: closing the last tab closes the window).
    func closeTab(_ url: URL) {
        Task {
            if await controller.close(url), controller.session.tabs.isEmpty { window?.close() }
        }
    }

    func closeWindow() { window?.performClose(nil) }

    /// Does closing this window have to ask about unsaved changes?
    var needsCloseReview: Bool {
        controller.session.tabs.contains { tab in
            WorkspaceRegistry.shared.isDirty(tab.url) && WorkspaceRegistry.shared.ledger.holders(of: tab.id) == [controller.id]
        }
    }
}

/// The window's delegate is SwiftUI's; this stands in front of it to run the save review on ✕ and ⌘⇧W, and passes
/// everything else through.
@MainActor
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    nonisolated(unsafe) private weak var original: (any NSWindowDelegate)?  // only touched on the main thread
    private weak var model: WindowModel?

    init(model: WindowModel, original: (any NSWindowDelegate)?) {
        self.model = model
        self.original = original
    }

    override func responds(to aSelector: Selector!) -> Bool { super.responds(to: aSelector) || original?.responds(to: aSelector) == true }
    override func forwardingTarget(for aSelector: Selector!) -> Any? { original?.responds(to: aSelector) == true ? original : nil }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let original, original.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))), original.windowShouldClose?(sender) == false { return false }
        guard let model, model.needsCloseReview else { return true }
        // The review is asynchronous (sheets), so: say no now, close for real when every dirty tab was dealt with.
        Task {
            if await model.controller.closeAll() { sender.close() }
        }
        return false
    }
}

/// Hands the hosting `NSWindow` to `onWindow` as soon as the view is in one.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { Probe(onWindow: onWindow) }
    func updateNSView(_ view: NSView, context: Context) { (view as? Probe)?.onWindow = onWindow }

    final class Probe: NSView {
        var onWindow: (NSWindow) -> Void
        init(onWindow: @escaping (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            guard let window else { return }
            DispatchQueue.main.async { [onWindow] in onWindow(window) }
        }
    }
}
