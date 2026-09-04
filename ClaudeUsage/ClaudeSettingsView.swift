import SwiftUI
import Foundation

/// Reads and writes one Claude account's global config files (CLAUDE.md, settings.json)
@MainActor
class ClaudeConfigManager: ObservableObject {
    let account: ClaudeAccount

    @Published var claudeMdText: String = ""
    @Published var cleanupPeriodDays: String = ""
    @Published var statusMessage: String?
    @Published var loadError: String?

    init(account: ClaudeAccount) {
        self.account = account
    }

    var claudeDir: URL { account.configDir }
    var claudeMdURL: URL { claudeDir.appendingPathComponent("CLAUDE.md") }
    var settingsJsonURL: URL { claudeDir.appendingPathComponent("settings.json") }

    func load() {
        loadError = nil
        statusMessage = nil

        claudeMdText = (try? String(contentsOf: claudeMdURL, encoding: .utf8)) ?? ""

        if let data = try? Data(contentsOf: settingsJsonURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let days = (json["cleanupPeriodDays"] as? NSNumber)?.intValue {
                cleanupPeriodDays = String(days)
            } else {
                cleanupPeriodDays = ""
            }
        } else if FileManager.default.fileExists(atPath: settingsJsonURL.path) {
            loadError = "Could not parse settings.json"
        } else {
            cleanupPeriodDays = ""
        }
    }

    func saveClaudeMd() {
        do {
            try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
            try claudeMdText.write(to: claudeMdURL, atomically: true, encoding: .utf8)
            statusMessage = "Saved CLAUDE.md"
        } catch {
            statusMessage = "Failed to save CLAUDE.md: \(error.localizedDescription)"
        }
    }

    /// Updates only cleanupPeriodDays, preserving every other key in settings.json
    func saveCleanupPeriod() {
        let trimmed = cleanupPeriodDays.trimmingCharacters(in: .whitespaces)

        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsJsonURL) {
            guard let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                statusMessage = "settings.json is not valid JSON — not overwriting it"
                return
            }
            json = existing
        }

        if trimmed.isEmpty {
            json.removeValue(forKey: "cleanupPeriodDays")
        } else if let days = Int(trimmed), days > 0 {
            json["cleanupPeriodDays"] = days
        } else {
            statusMessage = "Retention must be a positive number of days"
            return
        }

        do {
            try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: settingsJsonURL, options: .atomic)
            statusMessage = trimmed.isEmpty ? "Retention reset to Claude Code default (30 days)" : "Saved: keep conversations \(trimmed) days"
        } catch {
            statusMessage = "Failed to save settings.json: \(error.localizedDescription)"
        }
    }
}

/// Settings window. Session Alerts, Conversation Retention, and CLAUDE.md apply
/// to whichever account is selected in the picker; Claude Status Alerts is
/// account-agnostic (status.claude.com doesn't know about Claude accounts).
struct ClaudeSettingsView: View {
    let accounts: [ClaudeAccount]
    let sessionMonitors: [SessionMonitor]
    let configManagers: [ClaudeConfigManager]
    @ObservedObject var statusMonitor: StatusMonitor
    @State private var selectedIndex = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "gearshape.fill")
                    .foregroundColor(.accentColor)
                Text("Claude Code Settings")
                    .font(.headline)
                Spacer()
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            if accounts.count > 1 {
                Picker("Account", selection: $selectedIndex) {
                    ForEach(accounts.indices, id: \.self) { i in
                        Text(accounts[i].name).tag(i)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding()

                Divider()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AccountScopedSettings(
                        sessionMonitor: sessionMonitors[selectedIndex],
                        config: configManagers[selectedIndex]
                    )
                    .id(accounts[selectedIndex].id)

                    Divider()

                    // Claude service status alerts (account-agnostic)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Claude Status Alerts")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Text("Get a notification when status.claude.com reports an outage — and when service recovers. Checked every 5 minutes.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Toggle("Alert when Claude status changes", isOn: Binding(
                            get: { statusMonitor.alertsEnabled },
                            set: { statusMonitor.alertsEnabled = $0 }
                        ))
                        .toggleStyle(.switch)
                    }
                }
                .padding()
            }

            Divider()

            // Status footer
            HStack {
                if let status = configManagers[selectedIndex].statusMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundColor(status.hasPrefix("Saved") || status.hasPrefix("Retention") ? .green : .orange)
                }
                Spacer()
                Text(accounts[selectedIndex].isLegacyDefault ? "~/.claude" : "~/.claude-accounts/\(accounts[selectedIndex].name)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(width: 520, height: 520)
    }
}

/// The per-account portion of settings: session alerts, retention, CLAUDE.md.
/// Given a `.id(account.id)` by the parent so switching accounts resets
/// `alertsEnabled` and re-triggers `onAppear` instead of reusing stale state.
private struct AccountScopedSettings: View {
    @ObservedObject var sessionMonitor: SessionMonitor
    @ObservedObject var config: ClaudeConfigManager
    @State private var alertsEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Session alerts (hooks in settings.json)
            VStack(alignment: .leading, spacing: 8) {
                Text("Session Alerts")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text("Get a 🔔 in the menu bar and a macOS notification when a Claude Code session is waiting for your permission or input. Installs status hooks into this account's settings.json (your other settings and hooks are preserved). Takes effect for newly started Claude Code sessions.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Alert when a session needs attention", isOn: $alertsEnabled)
                    .toggleStyle(.switch)
                    .onChange(of: alertsEnabled) { newValue in
                        guard newValue != sessionMonitor.hooksInstalled else { return }
                        do {
                            try sessionMonitor.setEnabled(newValue)
                            config.statusMessage = newValue
                                ? "Saved: session hooks installed"
                                : "Saved: session hooks removed"
                        } catch {
                            alertsEnabled = !newValue
                            config.statusMessage = "Failed: \(error.localizedDescription)"
                        }
                    }

                if alertsEnabled {
                    Toggle("Show notification pop-ups", isOn: Binding(
                        get: { sessionMonitor.popupNotificationsEnabled },
                        set: { sessionMonitor.popupNotificationsEnabled = $0 }
                    ))
                    .toggleStyle(.switch)
                    .padding(.leading, 16)

                    VStack(alignment: .leading, spacing: 4) {
                        switch sessionMonitor.notificationsAuthorized {
                        case false:
                            Label("Notifications for ClaudeUsage are turned off in System Settings", systemImage: "bell.slash.fill")
                                .font(.caption)
                                .foregroundColor(.orange)
                            Button("Open Notification Settings") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
                            }
                            .font(.caption)
                        case nil:
                            Label("Notification permission not granted yet", systemImage: "bell.badge")
                                .font(.caption)
                                .foregroundColor(.orange)
                            Button("Request Permission") {
                                sessionMonitor.requestNotificationPermission()
                            }
                            .font(.caption)
                        default:
                            Label("Notifications allowed", systemImage: "bell.fill")
                                .font(.caption)
                                .foregroundColor(.green)
                            Button("Send Test Notification") {
                                sessionMonitor.sendTestNotification()
                            }
                            .font(.caption)
                        }

                        if let error = sessionMonitor.notificationError {
                            Text("Permission error: \(error)")
                                .font(.caption)
                                .foregroundColor(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.leading, 16)
                }
            }

            Divider()

            // Conversation retention (settings.json)
            VStack(alignment: .leading, spacing: 8) {
                Text("Conversation Retention")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text("How long Claude Code keeps local conversation transcripts (cleanupPeriodDays in this account's settings.json). Leave empty for the default of 30 days.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    TextField("30", text: $config.cleanupPeriodDays)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("days")
                        .foregroundColor(.secondary)
                    Button("Save") {
                        config.saveCleanupPeriod()
                    }
                }
            }

            Divider()

            // Working preferences (CLAUDE.md)
            VStack(alignment: .leading, spacing: 8) {
                Text("How You Like to Work")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text("Global instructions Claude Code reads in every project (this account's CLAUDE.md). Describe your preferences: coding style, tools, how you want Claude to communicate.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextEditor(text: $config.claudeMdText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 220)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                    )

                HStack {
                    Button("Save CLAUDE.md") {
                        config.saveClaudeMd()
                    }
                    Button("Reload") {
                        config.load()
                    }
                    Spacer()
                }
            }

            if let error = config.loadError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .onAppear {
            config.load()
            alertsEnabled = sessionMonitor.hooksInstalled
            sessionMonitor.refreshNotificationAuthStatus()
        }
    }
}

#Preview {
    let account = ClaudeAccount(id: "default", name: "default", configDir: ClaudeAccountDiscovery.legacyClaudeDir, isLegacyDefault: true)
    ClaudeSettingsView(
        accounts: [account],
        sessionMonitors: [SessionMonitor(account: account)],
        configManagers: [ClaudeConfigManager(account: account)],
        statusMonitor: StatusMonitor()
    )
}
