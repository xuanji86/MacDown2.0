import AppKit
import SwiftUI
import WorkspaceKit

/// The popover that hangs from a tab: Name (the stem selected, not the extension), Tags (Finder tags) and Where (the folder),
/// as the system's title-bar popover shows them for a document, which cannot be anchored to a tab. Return applies it; so does
/// a click elsewhere, for a saved file. Esc cancels. An untitled document has a Save button: that is its first save.
struct RenamePopover: View {
    let model: WindowModel
    @Bindable var draft: RenameDraft
    @FocusState private var nameFocused: Bool
    @State private var selection: TextSelection?
    @State private var escapeMonitor = KeyMonitor()

    private static let other = URL(filePath: "/macdown2-other-folder", directoryHint: .isDirectory)

    private var whereChoice: Binding<URL> {
        Binding(get: { draft.folder }, set: { new in
            if new == Self.other { model.chooseFolder(for: draft) } else { draft.folder = new }
        })
    }

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 10) {
            GridRow {
                Text("Name:").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                TextField("Name:", text: $draft.name, selection: $selection)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit { model.saveRename() }
            }
            GridRow {
                Text("Tags:").foregroundStyle(.secondary)
                TagField(tags: $draft.tags)
            }
            GridRow {
                Text("Where:").foregroundStyle(.secondary)
                Picker("Where:", selection: whereChoice) {
                    ForEach(draft.folderChoices, id: \.self) { folder in
                        Label {
                            Text(folder.lastPathComponent)
                        } icon: {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path)).resizable().frame(width: 16, height: 16)
                        }
                        .tag(folder)
                    }
                    Divider()
                    Text("Other…").tag(Self.other)
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if draft.isUntitled {
                GridRow {
                    Color.clear.frame(width: 0, height: 0)
                    HStack {
                        Spacer()
                        Button("Cancel") { model.cancelTabRename() }
                            .keyboardShortcut(.cancelAction)
                        Button("Save") { model.saveRename() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 330)
        .task {
            nameFocused = true
            // The field editor selects everything when it takes focus; the stem-only selection has to come after that.
            try? await Task.sleep(for: .milliseconds(80))
            selection = TextSelection(range: draft.name.startIndex..<RenameName.stemEnd(in: draft.name))
        }
        .onAppear { escapeMonitor.start { model.cancelTabRename() } }
        .onDisappear { escapeMonitor.stop() }
    }
}

/// Esc anywhere in the popover (the field being edited, the tag field, the menu) cancels it; the popover's own Esc would close
/// it like a click elsewhere, which applies the name.
@MainActor private final class KeyMonitor {
    private var token: Any?

    func start(onEscape: @escaping @MainActor () -> Void) {
        stop()
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, !event.isARepeat else { return event }
            MainActor.assumeIsolated(onEscape)
            return nil
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}

/// Finder tags as tokens (what Finder's own tag field is), completing from the colour labels' names.
private struct TagField: NSViewRepresentable {
    @Binding var tags: [String]

    func makeNSView(context: Context) -> NSTokenField {
        let field = NSTokenField()
        field.delegate = context.coordinator
        field.objectValue = tags
        field.tokenStyle = .rounded
        field.tokenizingCharacterSet = CharacterSet(charactersIn: ",")
        field.setAccessibilityLabel(String(localized: "Tags:"))
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        return field
    }

    // The field owns its text while it is edited: pushing the binding back in would reset the caret.
    func updateNSView(_ field: NSTokenField, context: Context) { context.coordinator.tags = $tags }

    func makeCoordinator() -> Coordinator { Coordinator(tags: $tags) }

    final class Coordinator: NSObject, NSTokenFieldDelegate {
        var tags: Binding<[String]>
        init(tags: Binding<[String]>) { self.tags = tags }

        func controlTextDidChange(_ note: Notification) { push(note) }
        func controlTextDidEndEditing(_ note: Notification) { push(note) }

        private func push(_ note: Notification) {
            guard let field = note.object as? NSTokenField else { return }
            tags.wrappedValue = ((field.objectValue as? [String]) ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }

        func tokenField(_ tokenField: NSTokenField, completionsForSubstring substring: String, indexOfToken tokenIndex: Int, indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?) -> [Any]? {
            NSWorkspace.shared.fileLabels.filter { $0.range(of: substring, options: [.anchored, .caseInsensitive]) != nil }
        }
    }
}
