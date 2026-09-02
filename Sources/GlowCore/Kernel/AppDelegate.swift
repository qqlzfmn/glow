import AppKit

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var poller: SessionPoller?
    private var usageMonitor: UsageMonitor?
    private var statusBarController: StatusBarController?
    private var providerSettings: ProviderSettingsWindowController?

    public override init() {}

    public func applicationDidFinishLaunching(_ notification: Notification) {
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

        // Usage monitor: discovered providers only; without credentials it
        // stays inert (badge absent, menu shows just "Refresh Usage").
        let usageMonitor = UsageMonitor()
        self.usageMonitor = usageMonitor

        statusBarController = StatusBarController(poller: poller, usageMonitor: usageMonitor)
        statusBarController?.openProviderSettings = { [weak self] in
            self?.showProviderSettings()
        }
        usageMonitor.onUsageUpdated = { [weak statusBarController] in
            statusBarController?.updateUsageBadge()
        }
        usageMonitor.start()
        poller.start()
    }

    /// Lazily create and present the Provider Settings window. Saving in the
    /// window triggers an immediate UsageMonitor re-discovery + poll.
    private func showProviderSettings() {
        if providerSettings == nil {
            providerSettings = ProviderSettingsWindowController(onRefresh: { [weak self] in
                self?.usageMonitor?.refreshNow()
            })
        }
        providerSettings?.showWindow(nil)
        providerSettings?.window?.makeKeyAndOrderFront(nil)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        poller?.stop()
        usageMonitor?.stop()
    }
}
