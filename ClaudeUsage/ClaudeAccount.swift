import Foundation
import CryptoKit

/// A Claude Code account configuration directory, either the legacy default
/// (`~/.claude`) or one of the per-account directories under
/// `~/.claude-accounts/<name>` set up via `CLAUDE_CONFIG_DIR`.
struct ClaudeAccount: Identifiable, Equatable, Codable {
    let id: String
    let name: String
    let configDir: URL
    let isLegacyDefault: Bool

    /// Name of the macOS Keychain "generic password" item holding this account's
    /// Claude Code OAuth credentials.
    ///
    /// Reverse-engineered by comparing calculated hashes against real Keychain
    /// item names (Keychain Access), not from Anthropic documentation — see
    /// Artifacts/dual-account-plan.md §3 for the verification and the risk this
    /// carries if the algorithm changes in a future Claude Code release.
    var keychainServiceName: String {
        isLegacyDefault
            ? "Claude Code-credentials"
            : "Claude Code-credentials-\(Self.configDirHash(configDir))"
    }

    /// First 8 hex chars of SHA-256(absolute path to configDir), lowercase.
    static func configDirHash(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}

/// Discovers Claude Code accounts from `~/.claude-accounts/*`, falling back to
/// a single synthetic "default" account pointing at `~/.claude` when that root
/// doesn't exist (preserves current single-account behavior for other forks).
enum ClaudeAccountDiscovery {
    /// Files that live directly under the accounts root but aren't account
    /// directories (see `~/.claude-accounts/switch.sh` / `claude-switch`).
    private static let nonAccountEntries: Set<String> = ["current", "switch.sh"]

    static var homeDirectory: URL {
        let home: String
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            home = String(cString: dir)
        } else {
            home = NSHomeDirectory()
        }
        return URL(fileURLWithPath: home)
    }

    static var accountsRoot: URL {
        homeDirectory.appendingPathComponent(".claude-accounts")
    }

    static var legacyClaudeDir: URL {
        homeDirectory.appendingPathComponent(".claude")
    }

    /// Name of the account marked active in `~/.claude-accounts/current`, for
    /// UI purposes only ("● active" badge) — never used to decide which
    /// accounts to show; all discovered accounts are always shown.
    static var activeAccountName: String? {
        let currentFile = accountsRoot.appendingPathComponent("current")
        guard let text = try? String(contentsOf: currentFile, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func discoverAccounts(fileManager: FileManager = .default) -> [ClaudeAccount] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: accountsRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let entries = try? fileManager.contentsOfDirectory(
                at: accountsRoot,
                includingPropertiesForKeys: [.isDirectoryKey]
              ) else {
            return [legacyAccount()]
        }

        let accounts = entries
            .filter { entry in
                let name = entry.lastPathComponent
                return !nonAccountEntries.contains(name)
                    && !name.localizedCaseInsensitiveContains("backup")
                    && isAccountDirectory(entry, fileManager: fileManager)
            }
            .map { dir -> ClaudeAccount in
                let name = dir.lastPathComponent
                return ClaudeAccount(id: name, name: name, configDir: dir, isLegacyDefault: false)
            }
            .sorted { $0.name < $1.name }

        return accounts.isEmpty ? [legacyAccount()] : accounts
    }

    private static func isAccountDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        let hasClaudeJson = fileManager.fileExists(atPath: url.appendingPathComponent(".claude.json").path)
        let hasSettingsJson = fileManager.fileExists(atPath: url.appendingPathComponent("settings.json").path)
        return hasClaudeJson || hasSettingsJson
    }

    private static func legacyAccount() -> ClaudeAccount {
        ClaudeAccount(id: "default", name: "default", configDir: legacyClaudeDir, isLegacyDefault: true)
    }
}
