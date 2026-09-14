import SwiftUI
import AppKit

/// LiteLLM configuration, embedded directly in the popover's Settings screen
/// (previously its own NSWindow via LiteLLMSettingsWindowController).
struct LiteLLMSettingsView: View {
    /// Whether the Settings screen is the one currently shown in the popover.
    /// Since this view can stay mounted across popover show/hide, onAppear
    /// alone won't catch every re-entry into Settings — this drives an
    /// explicit Keychain re-check whenever the screen becomes visible again.
    let isVisible: Bool

    @State private var proxyURLString: String = LiteLLMConfig.shared.proxyURLString ?? ""
    @State private var userID: String = LiteLLMConfig.shared.userID ?? ""
    @State private var keychainStatus: KeychainStatus = .checking
    @State private var testResult: TestResult?
    @State private var isTesting = false

    enum KeychainStatus { case checking, found, missing }
    enum TestResult { case success, failure(String) }

    private var isProxyURLValid: Bool {
        !proxyURLString.isEmpty && URL(string: proxyURLString) != nil
    }

    var body: some View {
        SettingsSection(title: "LiteLLM") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Proxy URL")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("", text: $proxyURLString, prompt: Text("https://your-litellm-proxy.example.com"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { LiteLLMConfig.shared.proxyURLString = proxyURLString }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("User ID")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("", text: $userID)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { LiteLLMConfig.shared.userID = userID }
            }

            SettingsStatusRow(color: keychainStatus == .found ? .green : .red, text: keychainStatusText)

            Button(isTesting ? "Testing…" : "Test Connection") {
                Task { await testConnection() }
            }
            .disabled(userID.isEmpty || !isProxyURLValid || keychainStatus != .found || isTesting)

            if let testResult {
                switch testResult {
                case .success:
                    SettingsResultLabel(success: true, text: "Connected successfully")
                case .failure(let message):
                    SettingsResultLabel(success: false, text: message)
                }
            }
        }
        .onAppear { refreshKeychainStatus() }
        .onChange(of: isVisible) { visible in
            if visible { refreshKeychainStatus() }
        }
        .onChange(of: proxyURLString) { _ in
            LiteLLMConfig.shared.proxyURLString = proxyURLString
        }
        .onChange(of: userID) { _ in
            LiteLLMConfig.shared.userID = userID
        }
    }

    private var keychainStatusText: String {
        switch keychainStatus {
        case .checking: return "Checking Keychain…"
        case .found: return "API key found"
        case .missing: return "com.litellm not found in Keychain"
        }
    }

    private func refreshKeychainStatus() {
        keychainStatus = (try? LiteLLMConfig.shared.readAPIKeyFromKeychain()) != nil ? .found : .missing
    }

    private func testConnection() async {
        isTesting = true
        testResult = nil
        defer { isTesting = false }

        let manager = LiteLLMManager(config: LiteLLMConfig.shared)
        await manager.refresh()
        if let error = manager.error {
            testResult = .failure(error)
        } else {
            testResult = .success
        }
    }
}

#Preview {
    LiteLLMSettingsView(isVisible: true)
        .padding()
        .frame(width: 280)
}
