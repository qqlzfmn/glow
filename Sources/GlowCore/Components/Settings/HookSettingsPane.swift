import AppKit

/// Per-agent hook toggles plus Install All / Uninstall All. Shares the same
/// HookInstaller statics as the menu-bar "Install Hooks" submenu — both
/// sides read on-disk state on every show, so there is no shared mutable
/// state to drift.
final class HookSettingsPane: NSView, SettingsPane {
    let paneTitle = "Hooks"

    private struct AgentRow {
        let agent: HookInstaller.Agent
        let toggle: NSButton
        let status: NSTextField
    }

    private var agentRows: [AgentRow] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupContent()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupContent() {
        let title = makeSettingsLabel("Hooks", size: 14, bold: true)
        var views: [NSView] = [title]

        for (index, agent) in HookInstaller.Agent.allCases.enumerated() {
            let toggle = NSButton(
                checkboxWithTitle: agent.displayName,
                target: self,
                action: #selector(agentToggled(_:))
            )
            toggle.tag = index
            let status = makeSettingsLabel("", color: .secondaryLabelColor)
            let row = NSStackView(views: [toggle, status])
            row.orientation = .horizontal
            row.spacing = 12
            agentRows.append(AgentRow(agent: agent, toggle: toggle, status: status))
            views.append(row)
        }

        let installAll = NSButton(
            title: "Install All", target: self, action: #selector(installAllClicked)
        )
        installAll.bezelStyle = .rounded
        let uninstallAll = NSButton(
            title: "Uninstall All", target: self, action: #selector(uninstallAllClicked)
        )
        uninstallAll.bezelStyle = .rounded
        let buttonRow = NSStackView(views: [installAll, uninstallAll])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12
        views.append(buttonRow)

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
        ])
    }

    func paneWillAppear() {
        refresh()
    }

    /// Checkmarks and captions always derive from inspectAgent (disk),
    /// never from click intent — failures snap the UI back to reality.
    private func refresh() {
        for row in agentRows {
            let status = HookInstaller.inspectAgent(row.agent)
            row.toggle.state = status.installed ? .on : .off
            row.status.stringValue = status.message
        }
    }

    @objc private func agentToggled(_ sender: NSButton) {
        guard agentRows.indices.contains(sender.tag) else { return }
        let row = agentRows[sender.tag]
        let result = sender.state == .on
            ? HookInstaller.installAgentAndReport(row.agent)
            : HookInstaller.uninstallAgentAndReport(row.agent)
        if result.message.contains("failed") {
            presentSettingsError("\(row.agent.displayName): \(result.message)")
        }
        refresh()
    }

    @objc private func installAllClicked() {
        runForAllAgents { HookInstaller.installAgentAndReport($0) }
    }

    @objc private func uninstallAllClicked() {
        runForAllAgents { HookInstaller.uninstallAgentAndReport($0) }
    }

    private func runForAllAgents(_ op: (HookInstaller.Agent) -> HookInstaller.AgentStatus) {
        let messages = HookInstaller.Agent.allCases
            .map { "\($0.displayName): \(op($0).message)" }
        refresh()
        let alert = NSAlert()
        alert.messageText = "Hooks"
        alert.informativeText = messages.joined(separator: "\n")
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
