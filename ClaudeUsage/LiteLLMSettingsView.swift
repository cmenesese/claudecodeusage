import SwiftUI
import AppKit

struct LiteLLMSettingsView: View {
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
        Form {
            Section("LiteLLM") {
                TextField("Proxy URL", text: $proxyURLString, prompt: Text("https://your-litellm-proxy.example.com"))
                    .onSubmit { LiteLLMConfig.shared.proxyURLString = proxyURLString }
                TextField("User ID", text: $userID)
                    .onSubmit { LiteLLMConfig.shared.userID = userID }
                keychainStatusRow
                Button(isTesting ? "Testing…" : "Test Connection") {
                    Task { await testConnection() }
                }
                .disabled(userID.isEmpty || !isProxyURLValid || keychainStatus != .found || isTesting)
                if let testResult { testResultRow(testResult) }
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { refreshKeychainStatus() }
        .onReceive(NotificationCenter.default.publisher(for: .liteLLMSettingsWindowShown)) { _ in
            refreshKeychainStatus()
        }
        .onChange(of: proxyURLString) { _ in
            LiteLLMConfig.shared.proxyURLString = proxyURLString
        }
        .onChange(of: userID) { _ in
            LiteLLMConfig.shared.userID = userID
        }
    }

    @ViewBuilder
    private var keychainStatusRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(keychainStatus == .found ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            switch keychainStatus {
            case .checking:
                Text("Checking Keychain…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            case .found:
                Text("API key found")
                    .font(.caption)
                    .foregroundColor(.secondary)
            case .missing:
                Text("com.litellm not found in Keychain")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func testResultRow(_ result: TestResult) -> some View {
        switch result {
        case .success:
            Label("Connected successfully", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundColor(.green)
        case .failure(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundColor(.red)
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

/// Simple window controller hosting `LiteLLMSettingsView`, mirroring the pattern
/// of the now-removed ClaudeSettingsView window — new and minimal, without the
/// session/retention controls that were deliberately dropped.
@MainActor
final class LiteLLMSettingsWindowController: NSWindowController {
    static let shared = LiteLLMSettingsWindowController()

    private init() {
        let hostingController = NSHostingController(rootView: LiteLLMSettingsView())
        let window = NSWindow(contentViewController: hostingController)
        window.title = "LiteLLM Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .liteLLMSettingsWindowShown, object: nil)
    }
}

extension Notification.Name {
    static let liteLLMSettingsWindowShown = Notification.Name("liteLLMSettingsWindowShown")
}

#Preview {
    LiteLLMSettingsView()
}
