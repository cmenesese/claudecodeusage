import SwiftUI
import AppKit
import ServiceManagement

/// The popover's Settings screen — swapped in over UsageView's content
/// rather than opened as a separate window. Composes LiteLLMSettingsView
/// with a Launch-at-Login section so a later settings addition has a
/// natural home without reworking this file.
struct SettingsView: View {
    /// Whether this screen is the one currently shown in the popover —
    /// forwarded to LiteLLMSettingsView to drive its Keychain refresh.
    let isVisible: Bool
    let onBack: () -> Void

    @State private var launchAtLogin: Bool = {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)

                Text("Settings")
                    .font(.headline)

                Spacer()
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                LiteLLMSettingsView(isVisible: isVisible)

                SettingsSection(title: "General") {
                    Toggle("Launch at Login", isOn: $launchAtLogin)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .onChange(of: launchAtLogin) { newValue in
                            do {
                                if newValue {
                                    try SMAppService.mainApp.register()
                                } else {
                                    try SMAppService.mainApp.unregister()
                                }
                            } catch {
                                launchAtLogin = !newValue
                            }
                        }
                }
            }
            .padding()
        }
        .frame(width: 280)
    }
}

#Preview {
    SettingsView(isVisible: true, onBack: {})
}
