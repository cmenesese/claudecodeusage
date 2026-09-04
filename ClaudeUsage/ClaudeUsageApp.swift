import SwiftUI
import Combine
import UserNotifications

@main
struct ClaudeUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static private(set) var shared: AppDelegate?

    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var settingsWindow: NSWindow?

    var accounts: [ClaudeAccount] = []
    var usageManagers: [UsageManager] = []
    var sessionMonitors: [SessionMonitor] = []
    var configManagers: [ClaudeConfigManager] = []

    var statusMonitor = StatusMonitor()
    var updateChecker = AppUpdateChecker()
    var updateInstaller = UpdateInstaller()
    var timer: Timer?
    var cancellables = Set<AnyCancellable>()

    /// Which account's data is currently shown in the menu bar title, when
    /// there's more than one account (see `cycleStatusItemTimer`).
    var statusCycleIndex = 0
    var cycleStatusItemTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        // Hide dock icon - menubar only
        NSApp.setActivationPolicy(.accessory)

        // Present notification banners even when the app is considered active
        UNUserNotificationCenter.current().delegate = self

        accounts = ClaudeAccountDiscovery.discoverAccounts()
        usageManagers = accounts.map { UsageManager(account: $0) }
        sessionMonitors = accounts.map { SessionMonitor(account: $0) }
        configManagers = accounts.map { ClaudeConfigManager(account: $0) }

        setupStatusItem()
        setupPopover()
        setupWakeNotification()
        setupUsageObserver()
        setupStatusCycling()
        startFetching()
        statusMonitor.start()

        // Request notification permission after launch completes (too early fails silently)
        if sessionMonitors.contains(where: { $0.hooksInstalled }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.sessionMonitors.forEach { $0.requestNotificationPermission() }
            }
        }
    }

    /// With more than one account, alternate which account's % is shown in
    /// the menu bar title every few seconds instead of always showing the
    /// worst one — chosen over a static combined display for more visibility
    /// into each account's usage at a glance.
    func setupStatusCycling() {
        guard usageManagers.count > 1 else { return }
        cycleStatusItemTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.usageManagers.isEmpty else { return }
                self.statusCycleIndex = (self.statusCycleIndex + 1) % self.usageManagers.count
                self.updateStatusItem()
            }
        }
    }

    func setupWakeNotification() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    func setupUsageObserver() {
        // Auto-update status item when any account's usage, error, or sessions change
        for manager in usageManagers {
            manager.$usage
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.updateStatusItem() }
                .store(in: &cancellables)

            manager.$error
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.updateStatusItem() }
                .store(in: &cancellables)
        }

        for monitor in sessionMonitors {
            monitor.$sessions
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.updateStatusItem() }
                .store(in: &cancellables)
        }
    }

    @objc func handleWake() {
        // Delay refresh after wake to allow keychain to unlock
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            await refreshAllAccounts()
        }
    }

    private func refreshAllAccounts() async {
        await withTaskGroup(of: Void.self) { group in
            for manager in usageManagers {
                group.addTask { await manager.refresh() }
            }
        }
    }

    func startFetching() {
        // Initial fetch and update check
        Task {
            // If system recently booted (within 60 seconds), wait before accessing keychain
            // The keychain/login system takes time to be fully available after boot
            let uptime = ProcessInfo.processInfo.systemUptime
            if uptime < 60 {
                let delaySeconds = max(30 - uptime, 5) // Wait until ~30s after boot, minimum 5s
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }

            await refreshAllAccounts()
            await updateChecker.checkForUpdates()
        }

        // Refresh every 5 minutes
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshAllAccounts()
            }
        }
    }

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.title = "⏳"
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    func setupPopover() {
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 280, height: 320)
        popover?.behavior = .transient
        popover?.contentViewController = NSHostingController(rootView: UsageView(
            accounts: accounts,
            usageManagers: usageManagers,
            sessionMonitors: sessionMonitors,
            statusMonitor: statusMonitor,
            updateChecker: updateChecker,
            updateInstaller: updateInstaller
        ))
    }

    func updateStatusItem() {
        guard let button = statusItem?.button else { return }

        let attentionCount = sessionMonitors.reduce(0) { $0 + $1.needsAttentionSessions.count }
        let bell = attentionCount > 0 ? "🔔\(attentionCount) " : ""

        guard !usageManagers.isEmpty else {
            button.title = "\(bell)⏳"
            return
        }

        let index = min(statusCycleIndex, usageManagers.count - 1)
        let manager = usageManagers[index]
        let account = accounts[index]
        // Only prefix with the account name when there's more than one to disambiguate
        let prefix = (accounts.count > 1 && !account.isLegacyDefault) ? "\(account.name) " : ""

        if let usage = manager.usage {
            let emoji = manager.statusEmoji
            let valueText: String
            if !usage.hasSessionLimit && !usage.hasWeeklyLimit,
               let used = usage.extraUsageUsedCredits, let limit = usage.extraUsageMonthlyLimit {
                // Budget-only account (e.g. Enterprise) — no session/weekly % to show,
                // so show spend against the monthly budget instead.
                valueText = "$\(Int(used / 100))/$\(Int(limit / 100))"
            } else {
                valueText = "\(usage.sessionPercentage)%"
            }
            button.title = "\(bell)\(prefix)\(emoji) \(valueText)"
        } else if manager.error != nil {
            button.title = "\(bell)\(prefix)❌"
        } else {
            button.title = "\(bell)\(prefix)⏳"
        }
    }

    func openSettingsWindow() {
        popover?.performClose(nil)

        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "ClaudeUsage Settings"
            window.contentViewController = NSHostingController(rootView: ClaudeSettingsView(
                accounts: accounts,
                sessionMonitors: sessionMonitors,
                configManagers: configManagers,
                statusMonitor: statusMonitor
            ))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let sessionId = userInfo["session_id"] as? String
        let accountId = userInfo["account_id"] as? String
        let statusURL = userInfo["status_url"] as? String
        Task { @MainActor in
            if let sessionId {
                if let accountId, let index = self.accounts.firstIndex(where: { $0.id == accountId }) {
                    self.sessionMonitors[index].focusSession(id: sessionId)
                } else {
                    // No account_id (e.g. an older queued notification) — search all accounts
                    for monitor in self.sessionMonitors where monitor.sessions.contains(where: { $0.id == sessionId }) {
                        monitor.focusSession(id: sessionId)
                        break
                    }
                }
            } else if let statusURL, let url = URL(string: statusURL) {
                NSWorkspace.shared.open(url)
            }
            completionHandler()
        }
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button, let popover = popover else { return }
        
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            
            // Bring to front
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
