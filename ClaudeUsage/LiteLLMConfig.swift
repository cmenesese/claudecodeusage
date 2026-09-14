import Foundation

/// Local configuration for LiteLLM: User ID and proxy URL (not secret, in
/// UserDefaults) + reads the API key already provisioned in Keychain
/// (com.litellm / api-key). The app never writes the API key — it only
/// reads it and reports if it's missing.
final class LiteLLMConfig {
    static let shared = LiteLLMConfig()

    private static let userIDDefaultsKey = "litellm.userID"
    private static let proxyURLDefaultsKey = "litellm.proxyURL"
    private static let keychainService = "com.litellm"
    private static let keychainAccount = "api-key"

    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var userID: String? {
        get { defaults.string(forKey: Self.userIDDefaultsKey) }
        set { defaults.set(newValue, forKey: Self.userIDDefaultsKey) }
    }

    /// The LiteLLM proxy base URL, e.g. "https://proxy-llm.infra.buk.cl".
    /// No default — each install points at its own proxy.
    var proxyURLString: String? {
        get { defaults.string(forKey: Self.proxyURLDefaultsKey) }
        set { defaults.set(newValue, forKey: Self.proxyURLDefaultsKey) }
    }

    var proxyURL: URL? {
        guard let proxyURLString, !proxyURLString.isEmpty else { return nil }
        return URL(string: proxyURLString)
    }

    var isConfigured: Bool {
        guard let userID, !userID.isEmpty, proxyURL != nil else { return false }
        return (try? readAPIKeyFromKeychain()) != nil
    }

    /// Same approach as getClaudeCodeToken() in UsageManager: uses the `security` CLI,
    /// which is already in the user's keychain ACL, avoiding the Keychain Access prompt.
    /// Never logs the value it reads.
    func readAPIKeyFromKeychain() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", Self.keychainService,
            "-a", Self.keychainAccount,
            "-w"
        ]
        let pipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw KeychainError.unexpectedError(status: -1)
        }

        guard process.terminationStatus == 0 else {
            let errorString = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw errorString.contains("could not be found")
                ? KeychainError.notLoggedIn
                : KeychainError.securityCommandFailed(errorString.isEmpty ? "Exit code \(process.terminationStatus)" : errorString)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let key = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw KeychainError.invalidData
        }
        return key
    }
}
