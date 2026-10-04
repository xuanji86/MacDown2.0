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
            SidebarView(model: model, preview: preview, status: status, jump: jump(toLine:))
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
        }
        .onChange(of: model.state) { WorkspaceRegistry.shared.persist() }
        .onChange(of: model.controller.activeURL) { _, url in model.sidebar.follow(url) }
        // Preview links to Markdown files under a workspace folder open in the app (PreviewNavigationDecider).
        .onChange(of: model.sidebar.folders.roots, initial: true) { _, roots in preview.workspaceRoots = roots }
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

/// A window with no tab: the way in (Cmd-O, Finder, Open Recent).
private struct EmptyWorkspaceView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text").font(.system(size: 40)).foregroundStyle(.tertiary)
            Text("没有打开的文件").font(.title3).foregroundStyle(.secondary)
            HStack {
                Button("打开…") { WorkspaceRegistry.shared.showOpenPanel() }
                Button("新建") { WorkspaceRegistry.shared.newUntitled() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
