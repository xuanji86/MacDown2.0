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
/// active tab grows out of the editor's background. Driven by `TabSession`: the preview tab is italic and secondary,
/// double click / drag pins it, an unsaved document shows a dot that turns into the close button on hover.
struct TabBar: View {
    let model: WindowModel
    @AppStorage(AppearanceKey.editorTheme) private var themeName = AppearanceDefault.editorTheme
    @AppStorage(AppearanceKey.editorThemeFollowsSystem) private var followsSystem = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var dropTarget: String?

    private var activeFill: Color {
        Color(nsColor: ThemeLibrary.resolve(name: themeName, followSystem: followsSystem, systemIsDark: colorScheme == .dark).background)
    }

    /// A file's name; an untitled document's "Untitled N".
    private static func title(of tab: TabSession.Tab) -> String {
        tab.url.isUntitled ? (WorkspaceRegistry.shared.document(for: tab.url)?.displayName ?? "Untitled") : tab.url.lastPathComponent
    }

    var body: some View {
        let session = model.controller.session
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(session.tabs) { tab in
                    TabItem(
                        tab: tab, title: Self.title(of: tab), isActive: tab.id == session.activeID, fill: activeFill,
                        edited: WorkspaceRegistry.shared.document(for: tab.url)?.editedFlag,
                        isDropTarget: dropTarget == tab.id,
                        select: { model.controller.activate(tab.url) },
                        pin: { model.controller.pin(tab.url) },
                        close: { model.closeTab(tab.url) }
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
            .frame(height: 34, alignment: .bottom)
        }
        .scrollIndicators(.hidden)
        .frame(height: 34)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("标签")
        .accessibilityAddTraits(.isTabBar)
    }
}

private struct TabItem: View {
    let tab: TabSession.Tab
    let title: String
    let isActive: Bool
    let fill: Color
    let edited: EditedFlag?
    let isDropTarget: Bool
    let select: () -> Void
    let pin: () -> Void
    let close: () -> Void
    @State private var hovering = false

    private var isEdited: Bool { edited?.value ?? false }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12.5))
                .italic(tab.isPreview)
                .foregroundStyle(tab.isPreview ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            // One slot for the dot and the close button, so the tab does not change width on hover.
            ZStack {
                if isEdited && !hovering {
                    Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                } else if hovering || isActive {
                    Button(action: close) { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("关闭标签 (⌘W)")
                }
            }
            .frame(width: 14, height: 14)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(minWidth: 60, maxWidth: 200)
        .frame(height: 28)
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
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: pin)
        .onTapGesture(perform: select)
        .animation(.easeOut(duration: 0.15), value: tab.isPreview)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue([tab.isPreview ? "预览" : nil, isEdited ? "有未保存的修改" : nil].compactMap { $0 }.joined(separator: "，"))
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "关闭标签", close)
        .accessibilityAction(named: "固定标签", pin)
    }
}
