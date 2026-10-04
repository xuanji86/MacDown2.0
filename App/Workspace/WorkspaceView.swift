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
    @Environment(\.openWindow) private var openWindow

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
        // accessibility) and this one is drawn in its place.
        .overlay(alignment: .top) { CenteredTitle(title: title, edited: model.activeDocument?.editedFlag.value ?? false) }
        .background(WindowAccessor { window in
            titleGuard.hideTitle(of: window)
            IsolatedTestHooks.applyWindowFrame(window)
            WorkspaceRegistry.shared.attach(window, to: model)
        })
        .focusedSceneValue(\.workspace, model)
        .onAppear {
            WorkspaceRegistry.shared.openWindow = { openWindow(id: WorkspaceScene.id) }
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

/// The window title in the title bar row, centred between the traffic lights and the window's right edge. An unsaved
/// document gets the system's dimmer "— Edited" after its name, as AppKit's own title does.
private struct CenteredTitle: View {
    let title: String
    let edited: Bool

    /// AppKit's own (localized) word, so it follows the system language like the titles of other apps' windows do.
    private static let editedWord = Bundle(for: NSWindow.self).localizedString(forKey: "Edited", value: "Edited", table: "AutosaveButton")

    var body: some View {
        (Text(title) + (edited ? Text(" — \(Self.editedWord)").fontWeight(.regular).foregroundStyle(.tertiary) : Text("")))
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
            Text("没有打开的文件").font(.title3).foregroundStyle(ink.opacity(0.55))
            HStack(spacing: 10) {
                Button("打开…") { WorkspaceRegistry.shared.showOpenPanel() }
                Button("新建 Markdown") { WorkspaceRegistry.shared.newUntitled() }
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
