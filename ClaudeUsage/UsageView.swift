import SwiftUI
import AppKit

struct UsageView: View {
    let accounts: [ClaudeAccount]
    let usageManagers: [UsageManager]
    @ObservedObject var liteLLMManager: LiteLLMManager
    @State private var showingSettings = false

    private static let usageSize = NSSize(width: 280, height: 320)
    private static let settingsSize = NSSize(width: 280, height: 280)

    private var anyLoading: Bool { usageManagers.contains { $0.isLoading } }
    private var mostRecentUpdate: Date? {
        usageManagers.compactMap(\.lastUpdated).max()
    }

    var body: some View {
        Group {
            if showingSettings {
                SettingsView(isVisible: showingSettings, onBack: { showingSettings = false })
            } else {
                usageContent
            }
        }
        .onChange(of: showingSettings) { isShowing in
            AppDelegate.shared?.popover?.contentSize = isShowing ? Self.settingsSize : Self.usageSize
        }
    }

    private var usageContent: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundColor(.accentColor)
                Text("Claude Usage")
                    .font(.headline)
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()

                if anyLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            ForEach(Array(zip(accounts, usageManagers)), id: \.0.id) { account, manager in
                AccountUsageSection(account: account, manager: manager, showsHeader: accounts.count > 1)
                if account.id != accounts.last?.id {
                    Divider()
                }
            }

            Divider()

            LiteLLMUsageSection(manager: liteLLMManager, onOpenSettings: { showingSettings = true })

            Divider()

            // Footer
            footerView()
        }
        .frame(width: 280)
    }

    @ViewBuilder
    func footerView() -> some View {
        VStack(spacing: 8) {
            HStack {
                if let lastUpdated = mostRecentUpdate {
                    Text("Updated \(lastUpdated.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: {
                    Task {
                        await withTaskGroup(of: Void.self) { group in
                            for manager in usageManagers {
                                group.addTask { await manager.refresh() }
                            }
                            group.addTask { await liteLLMManager.refresh() }
                        }
                    }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(anyLoading)

                Button(action: {
                    showingSettings = true
                }) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")

                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    func launchClaudeCLI() {
        let script = """
        tell application "Terminal"
            activate
            do script "claude"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }
}

/// One account's usage block: header (when more than one account is shown),
/// then either its error, its data, or a loading spinner — independent of
/// every other account's state.
private struct AccountUsageSection: View {
    let account: ClaudeAccount
    @ObservedObject var manager: UsageManager
    let showsHeader: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader {
                HStack(spacing: 6) {
                    Circle()
                        .fill(ClaudeAccountDiscovery.activeAccountName == account.name ? Color.green : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                    Text(account.name)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 12)
            }

            if let error = manager.error {
                errorView(error)
            } else if let usage = manager.usage {
                usageContent(usage)
            } else {
                loadingView()
            }
        }
    }

    @ViewBuilder
    func usageContent(_ usage: UsageData) -> some View {
        VStack(spacing: 16) {
            // Session usage (hidden for budget-only accounts, e.g. Enterprise, where
            // the API returns no five_hour block at all)
            if usage.hasSessionLimit {
                UsageRow(
                    title: "Session",
                    subtitle: "5-hour window",
                    percentage: usage.sessionPercentage,
                    resetsAt: usage.sessionResetsAt,
                    color: colorForPercentage(usage.sessionPercentage)
                )
            }

            // Weekly usage (hidden for budget-only accounts, see above)
            if usage.hasWeeklyLimit {
                UsageRow(
                    title: "Weekly",
                    subtitle: "7-day window",
                    percentage: usage.weeklyPercentage,
                    resetsAt: usage.weeklyResetsAt,
                    color: colorForPercentage(usage.weeklyPercentage)
                )
            }

            // Model-scoped weekly limits (Fable, Opus, etc.)
            ForEach(usage.modelLimits, id: \.name) { limit in
                UsageRow(
                    title: limit.name,
                    subtitle: "Model weekly limit",
                    percentage: limit.percentage,
                    resetsAt: limit.resetsAt,
                    color: colorForPercentage(limit.percentage)
                )
            }

            // Sonnet only (if available)
            if let sonnetPct = usage.sonnetPercentage {
                UsageRow(
                    title: "Sonnet Only",
                    subtitle: "Model-specific",
                    percentage: sonnetPct,
                    resetsAt: usage.sonnetResetsAt,
                    color: colorForPercentage(sonnetPct)
                )
            }

            // Extra usage / overage (if enabled)
            if usage.extraUsageEnabled, let limit = usage.extraUsageMonthlyLimit, let used = usage.extraUsageUsedCredits {
                OverageRow(
                    usedDollars: used / 100,
                    limitDollars: limit / 100,
                    percentage: usage.extraUsagePercentage ?? 0
                )
            }
        }
        .padding()
    }

    @ViewBuilder
    func errorView(_ error: String) -> some View {
        VStack(spacing: 12) {
            if error.contains("Not logged in") {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.largeTitle)
                    .foregroundColor(.blue)

                Text("Not Signed In")
                    .font(.headline)

                Text("This app uses credentials from Claude Code stored in the macOS Keychain.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Text("Please run `claude` in Terminal and log in first.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Button("Open Terminal & Run Claude") {
                    launchClaudeCLI()
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)

                Button("Install Claude Code") {
                    NSWorkspace.shared.open(URL(string: "https://docs.anthropic.com/en/docs/claude-code/overview")!)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundColor(.orange)

                Text(error)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    func loadingView() -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading usage data...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    func colorForPercentage(_ pct: Int) -> Color {
        if pct >= 90 { return .red }
        if pct >= 70 { return .orange }
        return .green
    }

    func launchClaudeCLI() {
        let script = """
        tell application "Terminal"
            activate
            do script "claude"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }
}

struct UsageRow: View {
    let title: String
    let subtitle: String
    let percentage: Int
    let resetsAt: Date?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text("\(percentage)%")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(color)
            }

            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(NSColor.separatorColor))
                        .frame(height: 8)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(color)
                        .frame(width: geometry.size.width * CGFloat(percentage) / 100, height: 8)
                }
            }
            .frame(height: 8)

            // Reset time
            if let resetsAt = resetsAt {
                HStack {
                    Image(systemName: "clock")
                        .font(.caption2)
                    Text("Resets \(formatTimeRemaining(resetsAt))")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    func formatTimeRemaining(_ date: Date) -> String {
        let now = Date()
        let diff = date.timeIntervalSince(now)

        if diff <= 0 { return "soon" }

        let hours = Int(diff / 3600)
        let minutes = Int((diff.truncatingRemainder(dividingBy: 3600)) / 60)

        if hours > 24 {
            let days = hours / 24
            let remainingHours = hours % 24
            return "in \(days)d \(remainingHours)h"
        }

        return "in \(hours)h \(minutes)m"
    }
}

struct OverageRow: View {
    let usedDollars: Double
    let limitDollars: Double
    let percentage: Int

    var color: Color {
        if percentage >= 90 { return .red }
        if percentage >= 70 { return .orange }
        return .blue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Overage")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("Extra usage this month")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("$\(String(format: "%.2f", usedDollars))")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(color)
                    Text("of $\(String(format: "%.0f", limitDollars)) limit")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(NSColor.separatorColor))
                        .frame(height: 8)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(color)
                        .frame(width: geometry.size.width * CGFloat(min(percentage, 100)) / 100, height: 8)
                }
            }
            .frame(height: 8)
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}

#Preview {
    let account = ClaudeAccount(id: "default", name: "default", configDir: ClaudeAccountDiscovery.legacyClaudeDir, isLegacyDefault: true)
    UsageView(
        accounts: [account],
        usageManagers: [UsageManager(account: account)],
        liteLLMManager: LiteLLMManager()
    )
}
