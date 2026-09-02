import AppKit

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var poller: SessionPoller?
    private var usageMonitor: UsageMonitor?
    private var statusBarController: StatusBarController?

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
        usageMonitor.onUsageUpdated = { [weak statusBarController] in
            statusBarController?.updateUsageBadge()
        }
        usageMonitor.start()
        poller.start()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        poller?.stop()
        usageMonitor?.stop()
    }
}
