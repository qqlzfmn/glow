import AppKit

/// A single section of the settings window. Panes are created once and kept
/// alive (switching only toggles `isHidden`), so their state survives
/// section switches; `paneWillAppear` lets a pane re-read on-disk state
/// every time it becomes visible.
protocol SettingsPane: NSView {
    var paneTitle: String { get }
    func paneWillAppear()
}

extension SettingsPane {
    func paneWillAppear() {}
}

/// App-level settings window: a sidebar (App / Appearance / Providers /
/// Hooks) on the left, the selected pane on the right.
final class SettingsWindowController: NSWindowController {
    /// Sidebar width; panes fill the rest of the 640pt window.
    private static let sidebarWidth: CGFloat = 150

    private var panes: [SettingsPane] = []
    private var sidebarButtons: [NSButton] = []

    init(onRefresh: @escaping () -> Void, onBadgeChange: @escaping () -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Glow Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        setupContent(onRefresh: onRefresh, onBadgeChange: onBadgeChange)
        selectPane(at: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        // Re-read on-disk state on every reopen (config may have changed
        // via CLI or another process while the window was closed).
        currentPane()?.paneWillAppear()
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func currentPane() -> SettingsPane? {
        panes.first { $0.isHidden == false }
    }

    // MARK: - Layout

    private func setupContent(onRefresh: @escaping () -> Void, onBadgeChange: @escaping () -> Void) {
        guard let content = window?.contentView else { return }

        panes = [
            AppSettingsPane(),
            AppearanceSettingsPane(onBadgeChange: onBadgeChange),
            ProviderSettingsPane(onRefresh: onRefresh),
            HookSettingsPane(),
        ]

        let sidebar = NSStackView()
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 6
        sidebar.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        for (index, pane) in panes.enumerated() {
            let button = NSButton(
                title: pane.paneTitle,
                target: self,
                action: #selector(sidebarClicked(_:))
            )
            button.bezelStyle = .texturedRounded
            button.tag = index
            button.widthAnchor.constraint(
                equalToConstant: Self.sidebarWidth - 16
            ).isActive = true
            sidebar.addArrangedSubview(button)
            sidebarButtons.append(button)
        }

        sidebar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(sidebar)
        for pane in panes {
            pane.translatesAutoresizingMaskIntoConstraints = false
            pane.isHidden = true
            content.addSubview(pane)
        }

        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.leadingAnchor.constraint(
                equalTo: content.leadingAnchor, constant: 12
            ),
            sidebar.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),
        ])

        // All panes share the same content frame; visibility switches via
        // isHidden so pane state (form drafts, selection) survives switches.
        let paneLeading = sidebar.trailingAnchor
        for pane in panes {
            NSLayoutConstraint.activate([
                pane.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
                pane.leadingAnchor.constraint(equalTo: paneLeading, constant: 12),
                pane.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
                pane.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            ])
        }
    }

    // MARK: - Switching

    @objc private func sidebarClicked(_ sender: NSButton) {
        selectPane(at: sender.tag)
    }

    private func selectPane(at index: Int) {
        guard index < panes.count else { return }
        for (i, pane) in panes.enumerated() {
            pane.isHidden = i != index
        }
        for (i, button) in sidebarButtons.enumerated() {
            button.contentTintColor = i == index ? .controlAccentColor : .labelColor
        }
        panes[index].paneWillAppear()
    }
}
