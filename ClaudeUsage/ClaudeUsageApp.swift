import SwiftUI

@main
struct ClaudeUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var usageManager = UsageManager()
    var timer: Timer?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon - menubar only
        NSApp.setActivationPolicy(.accessory)
        
        setupStatusItem()
        setupPopover()
        
        // Initial fetch
        Task {
            await usageManager.refresh()
            await MainActor.run {
                updateStatusItem()
            }
        }
        
        // Refresh every 2 minutes
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task {
                await self?.usageManager.refresh()
                await MainActor.run {
                    self?.updateStatusItem()
                }
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
        popover?.contentViewController = NSHostingController(rootView: UsageView(manager: usageManager))
    }
    
    func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        
        if let usage = usageManager.usage {
            let sessionPct = Int(usage.sessionUtilization * 100)
            let emoji = usageManager.statusEmoji
            button.title = "\(emoji) \(sessionPct)%"
        } else if usageManager.error != nil {
            button.title = "❌"
        } else {
            button.title = "⏳"
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
