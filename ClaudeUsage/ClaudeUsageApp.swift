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
    var usageManager = UsageManager()
    var sessionMonitor = SessionMonitor()
    var statusMonitor = StatusMonitor()
    var updateInstaller = UpdateInstaller()
    var timer: Timer?
    var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        // Hide dock icon - menubar only
        NSApp.setActivationPolicy(.accessory)

        // Present notification banners even when the app is considered active
        UNUserNotificationCenter.current().delegate = self

        setupStatusItem()
        setupPopover()
        setupWakeNotification()
        setupUsageObserver()
        startFetching()
        statusMonitor.start()

        // Request notification permission after launch completes (too early fails silently)
        if sessionMonitor.hooksInstalled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.sessionMonitor.requestNotificationPermission()
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
        // Auto-update status item when usage or error changes
        usageManager.$usage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)

        usageManager.$error
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)

        sessionMonitor.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)
    }

    @objc func handleWake() {
        // Delay refresh after wake to allow keychain to unlock
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            await usageManager.refresh()
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

            await usageManager.refresh()
            await usageManager.checkForUpdates()
        }

        // Refresh every 5 minutes
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.usageManager.refresh()
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
        popover?.contentViewController = NSHostingController(rootView: UsageView(manager: usageManager, sessionMonitor: sessionMonitor, statusMonitor: statusMonitor, updateInstaller: updateInstaller))
    }
    
    func updateStatusItem() {
        guard let button = statusItem?.button else { return }

        let attentionCount = sessionMonitor.needsAttentionSessions.count
        let bell = attentionCount > 0 ? "🔔\(attentionCount) " : ""

        if let usage = usageManager.usage {
            let sessionPct = usage.sessionPercentage
            let emoji = usageManager.statusEmoji
            button.title = "\(bell)\(emoji) \(sessionPct)%"
        } else if usageManager.error != nil {
            button.title = "\(bell)❌"
        } else {
            button.title = "\(bell)⏳"
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
            window.contentViewController = NSHostingController(rootView: ClaudeSettingsView(sessionMonitor: sessionMonitor, statusMonitor: statusMonitor))
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
        let statusURL = userInfo["status_url"] as? String
        Task { @MainActor in
            if let sessionId {
                self.sessionMonitor.focusSession(id: sessionId)
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
