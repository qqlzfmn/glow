import AppKit

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var poller: SessionPoller?
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

        statusBarController = StatusBarController(poller: poller)
        poller.start()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        poller?.stop()
    }
}
