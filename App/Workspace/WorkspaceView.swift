import EditorKit
import SwiftUI
import WorkspaceKit

/// A workspace window (PLAN 4.11, direction C): one sidebar with a Files / Outline switch, tabs over the editor and
/// preview. The editor, the preview page and the scroll sync belong to the window, not to a document: switching tabs
/// only swaps the text they show.
struct WorkspaceView: View {
    @State private var model = WindowModel()
    @State private var preview = PreviewModel()
    @State private var scrollSync = ScrollSyncController()
    @State private var editor = EditorHandle()
    @State private var status = EditorStatus()
    @State private var titleGuard = HiddenTitleGuard()
    @State private var chrome = ToolbarStyleGuard()
    @AppStorage(ToolbarStyle.key) private var toolbarStyle = ToolbarStyle.default

    private var visibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { model.sidebarVisible ? .all : .detailOnly },
            // While a saved state is being applied SwiftUI still reports the layout it was first built with (`.all`).
            set: { if !model.isRestoring { model.userSetSidebar(visible: $0 != .detailOnly) } }
        )
    }

    private var title: String { model.activeDocument?.displayName ?? "MacDown2" }

    var body: some View {
        NavigationSplitView(columnVisibility: visibility) {
            SidebarView(model: model, preview: preview, status: status, jump: jump(toLine:), openHit: open(hit:pinned:))
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 400)
        } detail: {
            Group {
                if let url = model.controller.activeURL, let document = WorkspaceRegistry.shared.document(for: url) {
                    DocumentView(
                        model: model, document: document, fileURL: url,
                        preview: preview, scrollSync: scrollSync, editor: editor, status: status
                    )
                } else {
                    EmptyWorkspaceView()
                }
            }
            .safeAreaBar(edge: .top, spacing: 0) {
                if !model.controller.session.tabs.isEmpty { TabBar(model: model) }
            }
            // Folders dropped on the window enter workspace mode; Markdown files open as tabs.
            .dropDestination(for: URL.self) { urls, _ in
                model.sidebar.drop(urls)
                return !urls.isEmpty
            }
        }
        .navigationTitle(title)
        // The system draws a window title leading-aligned inside the detail column; the original MacDown centres it over
        // the whole title bar. So the system one is hidden (the window keeps its title for the Window menu and
        // accessibility) and, in the Classic toolbar style, this one is drawn in its place. Minimal has no title text at all:
        // the tab strip carries the file name.
        .overlay(alignment: .top) {
            if toolbarStyle == .classic { CenteredTitle(title: title, edited: model.activeDocument?.editedFlag.value ?? false) }
        }
        .onChange(of: toolbarStyle, initial: true) { _, style in chrome.style = style }
        .background(WindowAccessor { window in
            titleGuard.hideTitle(of: window)
            chrome.attach(window)
            IsolatedTestHooks.applyWindowFrame(window)
            WorkspaceRegistry.shared.attach(window, to: model)
        })
        .focusedSceneValue(\.workspace, model)
        .onAppear {
            WorkspaceRegistry.shared.register(model)
        }
        .task {
            try? await Task.sleep(for: .milliseconds(600))
            model.isRestoring = false
            IsolatedTestHooks.showSearch(in: model) { open(hit: $0, pinned: true) }
        }
        .onChange(of: model.state) { WorkspaceRegistry.shared.persist() }
        .onChange(of: model.controller.activeURL) { _, url in
            model.sidebar.follow(url)
            if url == nil { preview.clear() }  // no document: no outline or counts of the one that was closed
        }
        // Preview links to Markdown files under a workspace folder open in the app (PreviewNavigationDecider).
        .onChange(of: model.sidebar.folders.roots, initial: true) { _, roots in preview.workspaceRoots = roots }
    }

    /// Search result: opens the file (a click = the preview tab, Return = a regular one) and selects the match once the editor
    /// shows it. A file that is not Markdown goes to its own app and gets no selection.
    private func open(hit: SearchHit, pinned: Bool) {
        model.sidebar.open(hit.file, pinned: pinned)
        guard model.controller.holds(hit.file), let line = hit.line else { return }
        editor.reveal(key: hit.file.fileKey, line: line - 1, columns: hit.columns, focus: model.layout.showsEditor)
    }

    /// Outline click: the caret and both panes go to the heading's line, whatever the scroll sync settings.
    private func jump(toLine line: Int) {
        editor.goTo(line: line, focus: model.layout.showsEditor)
        preview.scroll(toLine: Double(line))
    }
}

/// Keeps the system window title hidden: SwiftUI puts it back whenever the navigation title or toolbar changes.
@MainActor private final class HiddenTitleGuard {
    private var observation: NSKeyValueObservation?

    func hideTitle(of window: NSWindow) {
        window.titleVisibility = .hidden
        observation = window.observe(\.titleVisibility, options: .new) { window, _ in
            if window.titleVisibility != .hidden { MainActor.assumeIsolated { window.titleVisibility = .hidden } }
        }
    }
}

/// Applies `ToolbarStyle` to the window's own `toolbarStyle`, live, and puts it back whenever SwiftUI resets it (it re-applies
/// the scene's `.windowToolbarStyle` when the toolbar's content changes). In Minimal it also adjusts what SwiftUI cannot:
/// the layout toggle is the last item the system folds into its » menu (`NSToolbarItem.visibilityPriority`; SwiftUI has no
/// overflow priority), and every » entry is named by its label ("Bold") instead of its glyph ("B"), without icons so the
/// menu is uniform.
@MainActor private final class ToolbarStyleGuard {
    private weak var window: NSWindow?
    private var styleObservation: NSKeyValueObservation?
    private var updateObserver: NSObjectProtocol?
    var style = ToolbarStyle.default { didSet { apply() } }

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        apply()
        styleObservation = window.observe(\.toolbarStyle, options: .new) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.apply() }
        }
        // SwiftUI creates, replaces and renames the toolbar's items on its own schedule and NSToolbar does not announce it;
        // the check below is a few comparisons over ~20 items, so it simply runs on every window update.
        // lazy: per-update polling; a KVO observer on `NSToolbar.items` did not fire reliably, an owned NSToolbar would replace this.
        updateObserver = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
    }

    private func apply() {
        guard let window else { return }
        if window.toolbarStyle != style.windowStyle { window.toolbarStyle = style.windowStyle }
        // SwiftUI's own items (the sidebar toggle) have system identifiers; ours are UUIDs, and the last two are the layout
        // toggle and its presets arrow.
        let ours = window.toolbar?.items.filter { $0.view != nil && !$0.itemIdentifier.rawValue.hasPrefix("com.apple.") } ?? []
        for (index, item) in ours.enumerated() {
            let priority: NSToolbarItem.VisibilityPriority = style == .minimal && index >= ours.count - 2 ? .high : .standard
            if item.visibilityPriority != priority { item.visibilityPriority = priority }
            if style == .minimal, !item.label.isEmpty, let entry = item.menuFormRepresentation {
                if entry.title != item.label { entry.title = item.label }
                if entry.image != nil { entry.image = nil }
            }
        }
    }
}

/// The window title in the title bar row, centred between the traffic lights and the window's right edge. An unsaved
/// document gets the system's dimmer "— Edited" after its name, as AppKit's own title does.
private struct CenteredTitle: View {
    let title: String
    let edited: Bool

    /// AppKit's own (localized) word, so it follows the system language like the titles of other apps' windows do.
    private static let editedWord = Bundle(for: NSWindow.self).localizedString(forKey: "Edited", value: "Edited", table: "AutosaveButton")

    var body: some View {
        (Text(title) + (edited ? Text(verbatim: " — \(Self.editedWord)").fontWeight(.regular).foregroundStyle(.tertiary) : Text(verbatim: "")))
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 90)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .ignoresSafeArea(.container, edges: .top)
    }
}

enum WorkspaceScene {
    static let id = "workspace"
}

extension FocusedValues {
    @Entry var workspace: WindowModel?
}

/// A window with no tab (the last one was closed, or a restored window had none): the way in is Open (Cmd-O, Finder, Open Recent),
/// a new Markdown document (Cmd-N) or the sidebar. Drawn in the editor theme's colours, so it reads as the empty editor area.
private struct EmptyWorkspaceView: View {
    @AppStorage(AppearanceKey.editorTheme) private var themeName = AppearanceDefault.editorTheme
    @AppStorage(AppearanceKey.editorThemeFollowsSystem) private var followsSystem = false
    @Environment(\.colorScheme) private var colorScheme

    private var theme: EditorTheme { ThemeLibrary.resolve(name: themeName, followSystem: followsSystem, systemIsDark: colorScheme == .dark) }

    var body: some View {
        let ink = Color(nsColor: theme.text)
        VStack(spacing: 14) {
            Image(systemName: "doc.text").font(.system(size: 40)).foregroundStyle(ink.opacity(0.3))
            Text("No Open Files").font(.title3).foregroundStyle(ink.opacity(0.55))
            HStack(spacing: 10) {
                Button("Open…") { WorkspaceRegistry.shared.showOpenPanel() }
                Button("New Markdown Document") { WorkspaceRegistry.shared.newUntitled() }
            }
            .buttonStyle(QuietButtonStyle(ink: ink))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: theme.background))
    }
}

/// A flat pill in the theme's text colour: the empty state's two choices, quiet next to the editor they stand in for.
private struct QuietButtonStyle: ButtonStyle {
    let ink: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(ink.opacity(0.8))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(ink.opacity(configuration.isPressed ? 0.16 : 0.08), in: Capsule())
            .contentShape(Capsule())
    }
}
