import AppKit

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var poller: SessionPoller?
    private var usageMonitor: UsageMonitor?
    private var statusBarController: StatusBarController?
    private var settingsWindow: SettingsWindowController?

    public override init() {}

    public func applicationDidFinishLaunching(_ notification: Notification) {
        installHiddenEditMenu()

        // Ensure state directory exists.
        do {
            try FileManager.default.createDirectory(
                atPath: StatePaths.stateDir, withIntermediateDirectories: true
            )
        } catch {
            fputs("glow: cannot create state dir \(StatePaths.stateDir): \(error)\n", stderr)
        }

        // Start polling.
        let poller = SessionPoller()
        self.poller = poller

        // Usage monitor: providers come only from the explicit config; with
        // nothing configured the badge stays empty and the menu shows just
        // "Refresh Usage" / "Configure Providers…".
        let usageMonitor = UsageMonitor()
        self.usageMonitor = usageMonitor

        statusBarController = StatusBarController(poller: poller, usageMonitor: usageMonitor)
        statusBarController?.openSettings = { [weak self] in
            self?.showSettings()
        }
        usageMonitor.onUsageUpdated = { [weak statusBarController] in
            statusBarController?.updateUsageBadge()
        }
        usageMonitor.start()
        poller.start()
    }

    /// Lazily create and present the Settings window. Saving a provider
    /// triggers an immediate UsageMonitor re-discovery + poll; appearance
    /// changes redraw the menu bar badge without waiting for a poll.
    private func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(
                onRefresh: { [weak self] in
                    self?.usageMonitor?.refreshNow()
                },
                onBadgeChange: { [weak statusBarController] in
                    statusBarController?.updateUsageBadge()
                }
            )
        }
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    /// LSUIElement apps have no menu bar, so the standard Edit shortcuts
    /// (Cmd+C/V/X/A) never fire in text fields. Install a main menu that is
    /// never shown but provides the key equivalents for the Settings window.
    private func installHiddenEditMenu() {
        let mainMenu = NSMenu()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        mainMenu.setSubmenu(edit, for: NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""))
        NSApp.mainMenu = mainMenu
    }

    public func applicationWillTerminate(_ notification: Notification) {
        poller?.stop()
        usageMonitor?.stop()
    }
}
