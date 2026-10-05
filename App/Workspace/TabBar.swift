import EditorKit
import SwiftUI
import UniformTypeIdentifiers
import WorkspaceKit

/// What a dragged tab carries (the tab's file key); a private type, so the editor does not accept it as dropped text.
struct TabDragItem: Codable, Transferable {
    let id: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: "io.github.xuanji86.MacDown2.tab"))
    }
}

/// The tab strip (design 03 (b)): 34 pt under the toolbar, sharing the toolbar's glass (it has none of its own), the
/// active tab grows out of the editor's background. Minimal toolbar style (design "P3 Minimal"): 28 pt, 24 pt tabs, a hairline
/// under the strip; the tab strip is the only place the file name is shown. Driven by `TabSession`: the preview tab is italic and secondary,
/// double click / drag pins it, an unsaved document shows a dot that turns into the close button on hover.
struct TabBar: View {
    let model: WindowModel
    @AppStorage(ToolbarStyle.key) private var toolbarStyle = ToolbarStyle.default
    @AppStorage(AppearanceKey.editorTheme) private var themeName = AppearanceDefault.editorTheme
    @AppStorage(AppearanceKey.editorThemeFollowsSystem) private var followsSystem = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var dropTarget: String?


    /// A file's name; an untitled document's "Untitled N".
    private static func title(of tab: TabSession.Tab) -> String {
        tab.url.isUntitled ? (WorkspaceRegistry.shared.document(for: tab.url)?.displayName ?? "Untitled") : tab.url.lastPathComponent
    }

    var body: some View {
        let session = model.controller.session
        let compact = toolbarStyle == .minimal
        let height = toolbarStyle.tabBarHeight
        // The active tab is painted in the editor's colours (it grows out of the editor), whatever the system appearance is.
        let theme = ThemeLibrary.resolve(name: themeName, followSystem: followsSystem, systemIsDark: colorScheme == .dark)
        let activeFill = Color(nsColor: theme.background), activeInk = Color(nsColor: theme.text)
        ScrollViewReader { proxy in
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(session.tabs) { tab in
                    TabItem(
                        tab: tab, title: Self.title(of: tab), isActive: tab.id == session.activeID, fill: activeFill, ink: activeInk, compact: compact,
                        edited: WorkspaceRegistry.shared.document(for: tab.url)?.editedFlag,
                        isDropTarget: dropTarget == tab.id,
                        popover: Binding(
                            get: { model.renameDraft.map { $0.url.fileKey == tab.id && !$0.pickingFolder } ?? false },
                            set: { if !$0 { model.popoverDismissed() } }
                        ),
                        popoverContent: { model.renameDraft.map { RenamePopover(model: model, draft: $0) } },
                        select: { model.controller.activate(tab.url) },
                        pin: { model.controller.pin(tab.url) },
                        close: { model.closeTab(tab.url) },
                        beginRename: { model.beginTabRename(tab.url) },
                        reveal: { model.sidebar.perform(.revealInFinder, on: tab.url, isDirectory: false) },
                        copyPath: { model.sidebar.perform(.copyPath, on: tab.url, isDirectory: false) }
                    )
                    .draggable(TabDragItem(id: tab.id))
                    .dropDestination(for: TabDragItem.self) { items, _ in
                        guard let id = items.first?.id, let from = session.tabs.first(where: { $0.id == id }),
                              let to = session.tabs.firstIndex(where: { $0.id == tab.id }) else { return false }
                        model.controller.moveTab(from.url, to: to)
                        return true
                    } isTargeted: { dropTarget = $0 ? tab.id : (dropTarget == tab.id ? nil : dropTarget) }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: height, alignment: .bottom)
        }
        .scrollIndicators(.hidden)
        .frame(height: height)
        .overlay(alignment: .bottom) { if compact { Rectangle().fill(.primary.opacity(0.07)).frame(height: 1) } }
        // File > Rename… on a tab that is scrolled out of sight: bring it in so the popover has something to hang from.
        .onChange(of: model.renameDraft?.url.fileKey) { _, id in if let id { proxy.scrollTo(id) } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
        .accessibilityAddTraits(.isTabBar)
    }
}

private struct TabItem: View {
    let tab: TabSession.Tab
    let title: String
    let isActive: Bool
    let fill: Color
    /// Text colour on `fill` (the editor theme's), for the active tab; the others use the system's label colours.
    let ink: Color
    let compact: Bool
    let edited: EditedFlag?
    let isDropTarget: Bool
    /// The Name / Tags / Where popover hangs from this tab while it is true.
    @Binding var popover: Bool
    let popoverContent: () -> RenamePopover?
    let select: () -> Void
    let pin: () -> Void
    let close: () -> Void
    let beginRename: () -> Void
    let reveal: () -> Void
    let copyPath: () -> Void
    @State private var hovering = false
    /// Where the name is, in the tab's own coordinates: only a click on it (not the padding or the close button's slot) renames.
    @State private var titleFrame = CGRect.null

    private var isEdited: Bool { edited?.value ?? false }
    private var isMissing: Bool { edited?.missing ?? false }

    var body: some View {
        HStack(spacing: 6) {
            if isMissing {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.orange)
                    .help("The file was deleted or moved on disk. Your text is still here; saving will recreate the file.")
            }
            Text(title)
                .font(.system(size: compact ? 12 : 12.5))
                .italic(tab.isPreview)
                .foregroundStyle(isActive ? AnyShapeStyle(ink.opacity(tab.isPreview ? 0.6 : 1)) : AnyShapeStyle(tab.isPreview ? .secondary : .primary))
                .lineLimit(1)
                .truncationMode(.middle)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { titleFrame = $0 }
            // One slot for the dot and the close button, so the tab does not change width on hover.
            ZStack {
                if isEdited && !hovering {
                    Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                } else if hovering || isActive {
                    Button(action: close) { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(isActive ? AnyShapeStyle(ink.opacity(0.6)) : AnyShapeStyle(.secondary))
                        .help(Text("Close Tab") + Text(verbatim: " (⌘W)"))
                }
            }
            .frame(width: 14, height: 14)
        }
        .padding(.leading, compact ? 14 : 12)
        .padding(.trailing, compact ? 9 : 8)
        .frame(minWidth: 60, maxWidth: 200)
        .frame(height: compact ? 24 : 28)
        .background {
            if isActive {
                UnevenRoundedRectangle(topLeadingRadius: 9, topTrailingRadius: 9).fill(fill)
            } else if isDropTarget {
                UnevenRoundedRectangle(topLeadingRadius: 9, topTrailingRadius: 9).fill(Color.accentColor.opacity(0.25))
            } else if hovering {
                UnevenRoundedRectangle(topLeadingRadius: 9, topTrailingRadius: 9).fill(Color.primary.opacity(0.07))
            }
        }
        .contentShape(Rectangle())
        .coordinateSpace(.named(Self.space))
        .onHover { hovering = $0 }
        // A double click pins a preview tab. The single click below only fires once SwiftUI has seen that no second click follows
        // (the system's double-click interval), so a double click never opens the popover. On the tab that is already active, a
        // click on the name opens it (Finder's "click again on a selected item"); anywhere else it just switches to the tab.
        .onTapGesture(count: 2, perform: pin)
        .onTapGesture(count: 1, coordinateSpace: .named(Self.space)) { point in
            if isActive, titleFrame.insetBy(dx: -6, dy: -6).contains(point) { beginRename() } else { select() }
        }
        .popover(isPresented: $popover, arrowEdge: .bottom) { popoverContent() }
        .contextMenu {
            Button("Rename…", action: beginRename)
            if !tab.url.isUntitled {
                Button("Reveal in Finder", action: reveal)
                Button("Copy Path", action: copyPath)
            }
            Divider()
            Button("Close Tab", action: close)
        }
        .animation(.easeOut(duration: 0.15), value: tab.isPreview)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(ListFormatter.localizedString(byJoining: [
            tab.isPreview ? String(localized: "Preview") : nil,
            isMissing ? String(localized: "File deleted or moved") : nil,
            isEdited ? String(localized: "Has unsaved changes") : nil,
        ].compactMap { $0 }))
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Close Tab", close)
        .accessibilityAction(named: "Pin Tab", pin)
        .accessibilityAction(named: "Rename", beginRename)
    }

    private static let space = "tab-item"
}
