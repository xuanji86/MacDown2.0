import ExtensionAPI
import SwiftUI

/// What floats at the top of the preview: the flavor badge ("Quarto · 近似预览", tooltip says what is not done) and, for a
/// document an extension would handle while it is off, a one-line hint to switch it on (PLAN 4.6).
struct PreviewNotices: View {
    let badge: FlavorBadge?
    let hint: AppExtensions.DisabledHint?

    var body: some View {
        VStack(spacing: 6) {
            if let badge {
                Text(badge.title)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .glassEffect(.regular, in: .capsule)
                    .help(badge.help)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityHint(badge.help)
            }
            if let hint { DisabledHintBanner(hint: hint) }
        }
        .padding(8)
    }
}

/// "启用 Quarto 扩展以获得 callout / 交叉引用预览" [打开设置] [不再提示]. Gone for good after "不再提示".
private struct DisabledHintBanner: View {
    let hint: AppExtensions.DisabledHint
    @AppStorage private var dismissed: Bool

    init(hint: AppExtensions.DisabledHint) {
        self.hint = hint
        _dismissed = AppStorage(wrappedValue: false, hint.dismissKey, store: AppExtensions.preferences)
    }

    var body: some View {
        if !dismissed {
            HStack(spacing: 10) {
                Text(hint.message).font(.callout)
                SettingsLink { Text("打开设置") }
                Button("不再提示") { dismissed = true }
            }
            .buttonStyle(.link)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
        }
    }
}
