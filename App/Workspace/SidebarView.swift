import SwiftUI
import WorkspaceKit

/// The single sidebar (design C): a Files / Outline switch on top, the page below. Cmd-Ctrl-O jumps to the outline page.
struct SidebarView: View {
    @Bindable var model: WindowModel
    let preview: PreviewModel
    let status: EditorStatus
    let jump: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Picker("侧栏", selection: $model.sidebarSection) {
                Text("文件").tag(SidebarSection.files)
                Text("大纲").tag(SidebarSection.outline)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 6)
            switch model.sidebarSection {
            case .files:
                // lazy: placeholder until the file tree UI (WorkspaceKit's FileTreeModel) lands in the next step.
                Text("文件树即将推出")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .outline:
                OutlineList(preview: preview, status: status, jump: jump)
            }
        }
    }
}
