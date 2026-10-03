import MarkdownCore
import SwiftUI

/// Heading outline from the last render, indented by level; the section holding the caret is highlighted.
struct OutlineInspector: View {
    let preview: PreviewModel
    let status: EditorStatus
    /// Called with the heading's 0-based source line.
    let jump: (Int) -> Void

    var body: some View {
        let outline = preview.metadata?.outline ?? []
        let current = outline.currentIndex(forLine: status.line)
        let base = outline.map(\.level).min() ?? 1  // a document that starts at ## is not indented
        if outline.isEmpty {
            Text("没有标题").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(outline.enumerated()), id: \.element.line) { index, item in
                        Button { jump(item.line) } label: {
                            Text(item.text.isEmpty ? "—" : item.text)
                                .fontWeight(item.level == base ? .semibold : .regular)
                                .lineLimit(2)
                                .padding(.leading, CGFloat(item.level - base) * 14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(item.line)
                        .listRowBackground(index == current ? Color.accentColor.opacity(0.22) : nil)
                    }
                }
                .onChange(of: current) { _, new in
                    if let new { proxy.scrollTo(outline[new].line) }
                }
            }
        }
    }
}
