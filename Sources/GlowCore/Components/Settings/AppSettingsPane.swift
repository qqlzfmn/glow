import AppKit

/// App-level settings: launchd auto-start toggle. Reads/writes the same
/// LaunchdManager the menu's Install All flow uses.
final class AppSettingsPane: NSView, SettingsPane {
    let paneTitle = "App"

    private var launchdToggle: NSButton?
    private var statusLabel: NSTextField?

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
        let title = makeSettingsLabel("App", size: 14, bold: true)
        let toggle = NSButton(
            checkboxWithTitle: "Start Glow at login",
            target: self,
            action: #selector(launchdToggled)
        )
        launchdToggle = toggle
        let status = makeSettingsLabel("", color: .secondaryLabelColor)
        statusLabel = status

        let stack = NSStackView(views: [title, toggle, status])
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

    /// Both the toggle state and the caption derive from the plist on disk,
    /// so an external change (CLI, manual launchctl) is picked up on every
    /// show.
    private func refresh() {
        let installed = LaunchdManager.isInstalled
        launchdToggle?.state = installed ? .on : .off
        statusLabel?.stringValue = installed
            ? "Auto-start installed (\(LaunchdManager.plistLabel))."
            : "Not installed — Glow won't start at login."
    }

    @objc private func launchdToggled() {
        if launchdToggle?.state == .on {
            do {
                try LaunchdManager.install()
            } catch {
                presentSettingsError("Auto-start setup failed: \(error)")
            }
        } else {
            LaunchdManager.uninstall()
        }
        refresh()
    }
}
