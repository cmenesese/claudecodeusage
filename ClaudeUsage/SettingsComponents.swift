import SwiftUI
import AppKit

/// Titled section container for the popover's Settings screen, matching the
/// visual language of the usage cards (control-background fill, caption
/// labels). Generic over its content so a future settings section can reuse
/// it without depending on LiteLLM-specific types.
struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)

            if let footer {
                Text(footer)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}

/// Colored-dot + caption row for a status readout (e.g. Keychain lookup).
struct SettingsStatusRow: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

/// Success/failure label for a connection-test result.
struct SettingsResultLabel: View {
    let success: Bool
    let text: String

    var body: some View {
        Label(text, systemImage: success ? "checkmark.circle.fill" : "xmark.circle.fill")
            .font(.caption)
            .foregroundColor(success ? .green : .red)
    }
}
