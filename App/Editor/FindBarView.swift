import EditorKit
import SwiftUI

/// Find & Replace banner docked at the top of the editor, following Xcode's interface and workflow.
struct FindBarView: View {
    @Bindable var find: FindModel
    let editor: EditorHandle

    enum FieldFocus: Hashable {
        case find
        case replace
    }
    @FocusState private var focusedField: FieldFocus?

    var body: some View {
        VStack(spacing: 4) {
            findRow
            if find.mode == .replace {
                replaceRow
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Color(nsColor: .windowBackgroundColor)
                .overlay(alignment: .bottom) {
                    Divider()
                }
        )
        .onAppear {
            focusedField = .find
        }
        .onChange(of: find.focusTick) {
            focusedField = .find
        }
        .onChange(of: find.focusReplaceTick) {
            focusedField = .replace
        }
    }

    private var findRow: some View {
        HStack(spacing: 8) {
            modeMenu
            findField
            matchCountView
            navigationButtons
            doneButton
        }
        .frame(height: 26)
    }

    private var modeMenu: some View {
        Menu {
            Button("Find") { find.mode = .find }
            Button("Replace") {
                find.mode = .replace
                find.focusReplace()
            }
        } label: {
            HStack(spacing: 3) {
                Text(find.mode == .find ? "Find" : "Replace")
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Find Mode")
    }

    private var findField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("Find", text: $find.findText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focusedField, equals: .find)
                .onKeyPress(.return) {
                    if NSEvent.modifierFlags.contains(.shift) {
                        find.findPrevious()
                    } else {
                        find.findNext()
                    }
                    return .handled
                }
                .onKeyPress(.tab) {
                    if find.mode == .replace {
                        focusedField = .replace
                        return .handled
                    }
                    return .ignored
                }
                .onExitCommand {
                    find.dismiss()
                }

            if !find.findText.isEmpty {
                Button {
                    find.findText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }

            Button {
                find.isCaseSensitive.toggle()
            } label: {
                Text(verbatim: "Aa")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(find.isCaseSensitive ? Color.white : Color.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(find.isCaseSensitive ? Color.accentColor : Color.primary.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
            .help("Match Case (Case Sensitive)")
            .accessibilityLabel("Match Case")

            Button {
                find.isRegex.toggle()
            } label: {
                Text(verbatim: ".*")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(find.isRegex ? Color.white : Color.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(find.isRegex ? Color.accentColor : Color.primary.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
            .help("Regular Expression")
            .accessibilityLabel("Regular Expression")
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
                )
        )
    }

    private var matchCountView: some View {
        Group {
            if let status = find.statusMessage {
                Text(verbatim: status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if find.findText.isEmpty {
                Text(verbatim: "")
                    .font(.system(size: 11))
            } else if find.hasInvalidRegex {
                Text("Invalid regex")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            } else if find.matches.isEmpty {
                Text("No matches")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text("\(find.currentMatchIndex + 1) of \(find.matches.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private var navigationButtons: some View {
        HStack(spacing: 2) {
            Button {
                find.findPrevious()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(find.matches.isEmpty)
            .help("Previous (⇧⌘G)")

            Button {
                find.findNext()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(find.matches.isEmpty)
            .help("Next (⌘G)")
        }
    }

    private var doneButton: some View {
        Button("Done") {
            find.dismiss()
        }
        .font(.system(size: 11))
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Done (Esc)")
    }

    private var replaceRow: some View {
        HStack(spacing: 8) {
            Color.clear
                .frame(width: 58, height: 1)

            replaceField

            Button("Replace") {
                find.replaceCurrent()
            }
            .font(.system(size: 11))
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(find.matches.isEmpty || !editor.isEditable)
            .help("Replace current match")

            Button("All") {
                find.replaceAll()
            }
            .font(.system(size: 11))
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(find.matches.isEmpty || !editor.isEditable)
            .help("Replace all matches")
        }
        .frame(height: 26)
    }

    private var replaceField: some View {
        HStack(spacing: 5) {
            Image(systemName: "pencil")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            TextField("Replace", text: $find.replaceText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focusedField, equals: .replace)
                .onKeyPress(.return) {
                    find.replaceAndFindNext()
                    return .handled
                }
                .onKeyPress(.tab) {
                    if NSEvent.modifierFlags.contains(.shift) {
                        focusedField = .find
                        return .handled
                    }
                    return .ignored
                }
                .onExitCommand {
                    find.dismiss()
                }

            if !find.replaceText.isEmpty {
                Button {
                    find.replaceText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
                )
        )
    }
}
