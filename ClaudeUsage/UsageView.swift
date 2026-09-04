import SwiftUI
import AppKit
import ServiceManagement

struct UsageView: View {
    let accounts: [ClaudeAccount]
    let usageManagers: [UsageManager]
    let sessionMonitors: [SessionMonitor]
    @ObservedObject var statusMonitor: StatusMonitor
    @ObservedObject var updateChecker: AppUpdateChecker
    @ObservedObject var updateInstaller: UpdateInstaller
    @StateObject private var combinedSessions = CombinedSessionsStore()
    @Environment(\.openURL) var openURL
    @State private var launchAtLogin: Bool = {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }()

    private var anyLoading: Bool { usageManagers.contains { $0.isLoading } }
    private var mostRecentUpdate: Date? {
        usageManagers.compactMap(\.lastUpdated).max()
    }

    var body: some View {
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

            // Update available banner
            if let newVersion = updateChecker.updateAvailable {
                updateBanner(newVersion)
            }

            Divider()

            // Live Claude Code sessions (when alert hooks are installed for any account)
            if !combinedSessions.sessions.isEmpty {
                sessionsSection()
                Divider()
            }

            ForEach(Array(zip(accounts, usageManagers)), id: \.0.id) { account, manager in
                AccountUsageSection(account: account, manager: manager, showsHeader: accounts.count > 1)
                if account.id != accounts.last?.id {
                    Divider()
                }
            }

            Divider()

            // Claude service status (from status.claude.com)
            statusRow()

            Divider()

            // Footer
            footerView()
        }
        .frame(width: 280)
        .onAppear {
            combinedSessions.configure(accounts: accounts, sessionMonitors: sessionMonitors)
        }
    }

    @ViewBuilder
    func sessionsSection() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CLAUDE SESSIONS")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            ForEach(combinedSessions.sessions) { labeled in
                Button(action: {
                    AppDelegate.shared?.popover?.performClose(nil)
                    sessionMonitor(for: labeled.account)?.focusSession(labeled.session)
                }) {
                    HStack(spacing: 8) {
                        Text(sessionIcon(labeled.session))
                            .font(.caption)

                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(labeled.session.projectName)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                if accounts.count > 1 {
                                    Text("· \(labeled.account.name)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Text(sessionLabel(labeled.session))
                                .font(.caption2)
                                .foregroundColor(labeled.session.status == .needsAttention && !labeled.session.acknowledged ? .orange : .secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Text(labeled.session.updatedAt.formatted(.relative(presentation: .named)))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Jump to this session's terminal window")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func sessionMonitor(for account: ClaudeAccount) -> SessionMonitor? {
        guard let index = accounts.firstIndex(of: account) else { return nil }
        return sessionMonitors[index]
    }

    func sessionIcon(_ session: ClaudeSession) -> String {
        switch session.status {
        case .needsAttention: return session.acknowledged ? "🔕" : "🔔"
        case .running: return "⚙️"
        case .finished: return "✅"
        }
    }

    func sessionLabel(_ session: ClaudeSession) -> String {
        switch session.status {
        case .needsAttention:
            if session.acknowledged { return "Waiting (seen)" }
            return session.message.isEmpty ? "Needs your input" : session.message
        case .running:
            return "Working…"
        case .finished:
            return "Finished"
        }
    }

    @ViewBuilder
    func updateBanner(_ newVersion: String) -> some View {
        VStack(spacing: 4) {
            switch updateInstaller.state {
            case .idle:
                if let downloadURL = updateChecker.updateDownloadURL {
                    Button(action: {
                        Task { await updateInstaller.installUpdate(from: downloadURL) }
                    }) {
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("Update to v\(newVersion) & Relaunch")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                } else {
                    // No zip asset found — fall back to manual download
                    Button(action: {
                        openURL(URL(string: "https://github.com/richhickson/claudecodeusage/releases/latest")!)
                    }) {
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("Update Available: v\(newVersion)")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
            case .downloading:
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.6)
                    Text("Downloading v\(newVersion)…").font(.caption)
                }
            case .installing:
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.6)
                    Text("Verifying & installing…").font(.caption)
                }
            case .relaunching:
                Text("Relaunching…").font(.caption)
            case .failed(let message):
                Text("Update failed: \(message)")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Download manually") {
                    openURL(URL(string: "https://github.com/richhickson/claudecodeusage/releases/latest")!)
                }
                .font(.caption)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    func statusRow() -> some View {
        if let indicator = statusMonitor.indicator {
            Button(action: {
                openURL(URL(string: StatusMonitor.statusPageURL)!)
            }) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor(indicator))
                        .frame(width: 8, height: 8)
                    Text(statusMonitor.statusDescription.isEmpty ? "Claude status" : statusMonitor.statusDescription)
                        .font(.caption)
                        .foregroundColor(indicator == "none" ? .secondary : .primary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(statusMonitor.incidentName.isEmpty ? "Open status.claude.com" : statusMonitor.incidentName)
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    func statusColor(_ indicator: String) -> Color {
        switch indicator {
        case "none": return .green
        case "minor": return .yellow
        case "major": return .orange
        default: return .red // critical
        }
    }

    @ViewBuilder
    func footerView() -> some View {
        VStack(spacing: 8) {
            Button(action: {
                Task { await updateChecker.checkForUpdates() }
            }) {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Check for Updates")
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .padding(.top, 8)

            Toggle("Launch at Login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.caption)
                .onChange(of: launchAtLogin) { newValue in
                    do {
                        if newValue {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = !newValue
                    }
                }
                .padding(.horizontal)

            Divider()

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
                        }
                    }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(anyLoading)

                Button(action: {
                    openURL(URL(string: "https://claude.ai")!)
                }) {
                    Image(systemName: "globe")
                }
                .buttonStyle(.borderless)

                Button(action: {
                    AppDelegate.shared?.openSettingsWindow()
                }) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Claude Code settings (CLAUDE.md, retention)")

                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal)

            Divider()

            Button(action: {
                openURL(URL(string: "https://x.com/richhickson")!)
            }) {
                Text("Created by @richhickson")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(.bottom, 8)
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
        sessionMonitors: [SessionMonitor(account: account)],
        statusMonitor: StatusMonitor(),
        updateChecker: AppUpdateChecker(),
        updateInstaller: UpdateInstaller()
    )
}
