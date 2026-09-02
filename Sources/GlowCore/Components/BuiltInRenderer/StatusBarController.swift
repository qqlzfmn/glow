import AppKit
import Combine

/// Manages the NSStatusItem (menu bar icon) and its menu.
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let poller: SessionPoller
    private var pollerCancellable: AnyCancellable?
    private var flashTimer: Timer?

    private weak var usageMonitor: UsageMonitor?
    private var usageBadgeText: String = ""
    private var panel: DetailPanelWindow?
    private var signalStartedAt: TimeInterval = 0
    private var isFlashing: Bool = false
    private var currentSignal: String = "idle"

    init(poller: SessionPoller, usageMonitor: UsageMonitor?) {
        self.poller = poller
        self.usageMonitor = usageMonitor
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        setupMenu()
        updateIcon(aggregateSignal: "idle", isFlashOn: true)

        pollerCancellable = poller.statePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.handleStateUpdate(state)
            }
    }

    // MARK: - Menu

    private func setupMenu() {
        let menu = NSMenu()

        let detailsItem = NSMenuItem(title: "Show Details", action: #selector(togglePanel), keyEquivalent: "d")
        detailsItem.target = self
        menu.addItem(detailsItem)

        // Usage submenu — contents rebuilt on every open (NSMenuDelegate).
        let usageMenu = NSMenu(title: "Usage")
        let usageItem = NSMenuItem(title: "Usage", action: nil, keyEquivalent: "")
        usageItem.submenu = usageMenu
        menu.addItem(usageItem)
        usageMenu.delegate = self

        menu.addItem(NSMenuItem.separator())

        // Install Hooks → per-agent submenu
        let installMenu = NSMenu(title: "Install Hooks")
        for agent in HookInstaller.Agent.allCases {
            let item = NSMenuItem(
                title: agent.displayName,
                action: #selector(installHooksForAgent(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = agent.rawValue
            item.state = HookInstaller.inspectAgent(agent).installed ? .on : .off
            installMenu.addItem(item)
        }
        installMenu.addItem(NSMenuItem.separator())
        let allItem = NSMenuItem(title: "Install All", action: #selector(installHooks), keyEquivalent: "")
        allItem.target = self
        installMenu.addItem(allItem)
        installMenu.addItem(NSMenuItem.separator())
        let uninstallItem = NSMenuItem(title: "Uninstall All", action: #selector(uninstallHooks), keyEquivalent: "")
        uninstallItem.target = self
        installMenu.addItem(uninstallItem)

        let installItem = NSMenuItem(title: "Install Hooks", action: nil, keyEquivalent: "")
        installItem.submenu = installMenu
        menu.addItem(installItem)

        menu.addItem(NSMenuItem.separator())

        let clearItem = NSMenuItem(title: "Clear State", action: #selector(clearState), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - State Handling

    private func handleStateUpdate(_ state: SessionPoller.State) {
        let signalName = state.aggregateSignal
        let def = SIGNAL_DEFINITIONS[signalName]
        let wasRepeating = isFlashing

        currentSignal = signalName

        if def?.isRepeating == true {
            if !wasRepeating || signalStartedAt == 0 {
                signalStartedAt = CACurrentMediaTime()
            }
            isFlashing = true
            startFlashTimer()
        } else {
            isFlashing = false
            stopFlashTimer()
            updateIcon(aggregateSignal: signalName, isFlashOn: true)
        }

        // Update panel.
        if let panel = panel, panel.isVisible {
            panel.updateSignal(
                name: def?.name ?? signalName,
                summary: def?.summary ?? "",
                sessionCount: state.sessionCount,
                isRepeating: def?.isRepeating ?? false,
                flashColor: SIGNAL_DEFINITIONS[signalName]?.color.colorKey ?? "grey"
            )
        }
    }

    private func startFlashTimer() {
        stopFlashTimer()
        flashTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tickFlash()
        }
        tickFlash()
    }

    private func stopFlashTimer() {
        flashTimer?.invalidate()
        flashTimer = nil
    }

    private func tickFlash() {
        let elapsed = CACurrentMediaTime() - signalStartedAt
        let flashOn = Int(elapsed / 0.5) % 2 == 0
        updateIcon(aggregateSignal: currentSignal, isFlashOn: flashOn)
    }

    // MARK: - Icon Rendering

    private func updateIcon(aggregateSignal: String, isFlashOn: Bool) {
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size, flipped: false) { [self] rect in
            let color: NSColor
            if isFlashOn {
                color = self.colorForSignal(aggregateSignal)
            } else {
                color = self.dimColorForSignal(aggregateSignal)
            }

            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            color.setFill()
            path.fill()

            return true
        }
        image.isTemplate = false

        statusItem.button?.image = image
        statusItem.button?.title = usageBadgeText
    }

    private func colorForSignal(_ signal: String) -> NSColor {
        let def = SIGNAL_DEFINITIONS[signal]
        return def?.color.nsColor ?? SignalColor.grey.nsColor
    }

    private func dimColorForSignal(_ signal: String) -> NSColor {
        let def = SIGNAL_DEFINITIONS[signal]
        return def?.color.dimColor ?? SignalColor.grey.dimColor
    }


    // MARK: - Actions

    @objc private func togglePanel() {
        if let panel = panel, panel.isVisible {
            panel.orderOut(nil)
            return
        }

        if panel == nil {
            let panelWidth: CGFloat = 260
            let panelHeight: CGFloat = 340
            panel = DetailPanelWindow(
                contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
                styleMask: [.nonactivatingPanel, .titled, .closable],
                backing: .buffered,
                defer: true
            )
        }

        let state = poller.currentState
        let def = SIGNAL_DEFINITIONS[state.aggregateSignal]
        panel?.updateSignal(
            name: def?.name ?? state.aggregateSignal,
            summary: def?.summary ?? "",
            sessionCount: state.sessionCount,
            isRepeating: def?.isRepeating ?? false,
            flashColor: SIGNAL_DEFINITIONS[state.aggregateSignal]?.color.colorKey ?? "grey"
        )
        panel?.showPanel()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// Manually clear all tracked session state and reset the light to idle.
    /// Safety valve for when an agent finishes but its clearing hook doesn't fire.
    @objc private func clearState() {
        let alert = NSAlert()
        alert.messageText = "Clear State?"
        alert.informativeText = "Reset the signal light to idle and forget all tracked agent sessions."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try SessionStore.clearSessionState()
        } catch {
            let failAlert = NSAlert()
            failAlert.messageText = "Clear State Failed"
            failAlert.informativeText = "\(error)"
            failAlert.alertStyle = .warning
            failAlert.addButton(withTitle: "OK")
            failAlert.runModal()
            return
        }
        poller.refresh()
    }

    /// Toggle one agent's hooks: uninstalled → install (checkmark appears),
    /// installed → uninstall (checkmark removed). Failures alert; success is
    /// reflected by the checkmark when the menu is next opened.
    @objc private func installHooksForAgent(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let agent = HookInstaller.Agent(rawValue: raw) else { return }

        let wasInstalled = HookInstaller.inspectAgent(agent).installed
        let result = wasInstalled
            ? HookInstaller.uninstallAgentAndReport(agent)
            : HookInstaller.installAgentAndReport(agent)

        let succeeded = wasInstalled ? !result.installed : result.installed
        if !succeeded {
            let alert = NSAlert()
            alert.messageText = "\(agent.displayName) Hooks"
            alert.informativeText = result.message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
    @objc private func installHooks() {
        let agents = HookInstaller.Agent.allCases

        // Run installation for all agents without interactive prompts.
        var messages: [String] = []
        for agent in agents {
            let result = HookInstaller.installAgentAndReport(agent)
            messages.append("\(agent.displayName): \(result.message)")
        }

        let alert = NSAlert()
        alert.messageText = "Hooks Installed"
        alert.informativeText = messages.joined(separator: "\n")
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()

        // Also offer to set up launchd auto-start.
        if !LaunchdManager.isInstalled {
            let launchAlert = NSAlert()
            launchAlert.messageText = "Auto-start on login?"
            launchAlert.informativeText = "Would you like Glow to start automatically when you log in?"
            launchAlert.alertStyle = .informational
            launchAlert.addButton(withTitle: "Yes")
            launchAlert.addButton(withTitle: "Not Now")
            if launchAlert.runModal() == .alertFirstButtonReturn {
                do {
                    try LaunchdManager.install()
                } catch {
                    let failAlert = NSAlert()
                    failAlert.messageText = "Auto-start Setup Failed"
                    failAlert.informativeText = "\(error)"
                    failAlert.alertStyle = .warning
                    failAlert.addButton(withTitle: "OK")
                    failAlert.runModal()
                }
            }
        }
    }

    @objc private func uninstallHooks() {
        var messages: [String] = []
        for agent in HookInstaller.Agent.allCases {
            let result = HookInstaller.uninstallAgentAndReport(agent)
            messages.append("\(agent.displayName): \(result.message)")
        }

        let alert = NSAlert()
        alert.messageText = "Hooks Uninstalled"
        alert.informativeText = messages.joined(separator: "\n")
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Usage

extension StatusBarController: NSMenuDelegate {
    /// Rebuild the Usage submenu on every open so provider rows always
    /// reflect the latest usage.json snapshot.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.title == "Usage" {
            guard let usageMonitor else { return }
            menu.removeAllItems()
            for item in usageMonitor.menuItems() {
                menu.addItem(item)
            }
        } else if menu.title == "Install Hooks" {
            // Re-inspect on every open so checkmarks mirror on-disk state
            // even when hooks were changed via CLI or by another process.
            for item in menu.items {
                guard let raw = item.representedObject as? String,
                      let agent = HookInstaller.Agent(rawValue: raw) else { continue }
                item.state = HookInstaller.inspectAgent(agent).installed ? .on : .off
            }
        }
    }
}

extension StatusBarController {
    /// Re-read usage.json and refresh the badge text next to the lamp icon.
    func updateUsageBadge() {
        usageBadgeText = UsageBadge.badgeText(for: UsageStore.readUsage())
        updateIcon(aggregateSignal: currentSignal, isFlashOn: isFlashing)
    }
}

