import SwiftUI
import AppKit

struct LiteLLMSettingsView: View {
    @State private var userID: String = LiteLLMConfig.shared.userID ?? ""
    @State private var keychainStatus: KeychainStatus = .checking
    @State private var testResult: TestResult?
    @State private var isTesting = false

    enum KeychainStatus { case checking, found, missing }
    enum TestResult { case success, failure(String) }

    var body: some View {
        Form {
            Section("LiteLLM") {
                TextField("User ID", text: $userID)
                    .onSubmit { LiteLLMConfig.shared.userID = userID }
                keychainStatusRow
                Text("Proxy: https://proxy-llm.infra.buk.cl/")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button(isTesting ? "Testing…" : "Test Connection") {
                    Task { await testConnection() }
                }
                .disabled(userID.isEmpty || keychainStatus != .found || isTesting)
                if let testResult { testResultRow(testResult) }
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { refreshKeychainStatus() }
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
                Text("com.buk.litellm not found in Keychain")
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
    }
}

#Preview {
    LiteLLMSettingsView()
}
