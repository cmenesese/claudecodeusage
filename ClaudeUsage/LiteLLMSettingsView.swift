import SwiftUI
import AppKit

/// LiteLLM configuration, embedded directly in the popover's Settings screen.
struct LiteLLMSettingsView: View {
    let isVisible: Bool

    @State private var proxyURLString: String = LiteLLMConfig.shared.proxyURLString ?? ""
    @State private var email: String = LiteLLMConfig.shared.email ?? ""
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
                Text("Email")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("", text: $email, prompt: Text("you@buk.cl"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        LiteLLMConfig.shared.email = email
                        refreshKeychainStatus()
                    }
            }

            SettingsStatusRow(color: keychainStatus == .found ? .green : .red, text: keychainStatusText)

            Button(isTesting ? "Testing…" : "Test Connection") {
                Task { await testConnection() }
            }
            .disabled(email.isEmpty || !isProxyURLValid || keychainStatus != .found || isTesting)

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
        .onChange(of: email) { _ in
            LiteLLMConfig.shared.email = email
            refreshKeychainStatus()
        }
    }

    private var keychainStatusText: String {
        switch keychainStatus {
        case .checking: return "Checking Keychain…"
        case .found: return "Password found"
        case .missing: return "No password found in Keychain (com.litellm-password) for this email"
        }
    }

    private func refreshKeychainStatus() {
        keychainStatus = (try? LiteLLMConfig.shared.readPasswordFromKeychain()) != nil ? .found : .missing
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
