import Foundation

/// Local configuration for LiteLLM: email + proxy URL (not secret, in
/// UserDefaults) + reads the account password already provisioned in
/// Keychain (com.litellm-password / <email>). The app never writes the
/// password — it only reads it and reports if it's missing.
///
/// The User ID and the API key used for requests are NOT stored here: they
/// are derived at runtime from a `/v2/login` call and cached in memory by
/// LiteLLMManager — see LiteLLMManager.cachedSession.
final class LiteLLMConfig {
    static let shared = LiteLLMConfig()

    private static let emailDefaultsKey = "litellm.email"
    private static let proxyURLDefaultsKey = "litellm.proxyURL"
    private static let keychainService = "com.litellm-password"

    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var email: String? {
        get { defaults.string(forKey: Self.emailDefaultsKey) }
        set { defaults.set(newValue, forKey: Self.emailDefaultsKey) }
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
        guard let email, !email.isEmpty, proxyURL != nil else { return false }
        return (try? readPasswordFromKeychain()) != nil
    }

    /// Same approach as getClaudeCodeToken() in UsageManager: uses the `security` CLI,
    /// which is already in the user's keychain ACL, avoiding the Keychain Access prompt.
    /// Never logs the value it reads. The Keychain account is the configured email —
    /// looking it up before the email is set is treated as "not found".
    func readPasswordFromKeychain() throws -> String {
        guard let email, !email.isEmpty else { throw KeychainError.notLoggedIn }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", Self.keychainService,
            "-a", email,
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
        guard let password = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !password.isEmpty else {
            throw KeychainError.invalidData
        }
        return password
    }
}
