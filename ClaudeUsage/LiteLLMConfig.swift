import Foundation

/// Local configuration for LiteLLM: User ID (not secret, in UserDefaults)
/// + reads the API key already provisioned in Keychain (com.buk.litellm / api-key).
/// The app never writes the API key — it only reads it and reports if it's missing.
final class LiteLLMConfig {
    static let shared = LiteLLMConfig()

    private static let userIDDefaultsKey = "litellm.userID"
    private static let keychainService = "com.buk.litellm"
    private static let keychainAccount = "api-key"

    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var userID: String? {
        get { defaults.string(forKey: Self.userIDDefaultsKey) }
        set { defaults.set(newValue, forKey: Self.userIDDefaultsKey) }
    }

    var isConfigured: Bool {
        guard let userID, !userID.isEmpty else { return false }
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
