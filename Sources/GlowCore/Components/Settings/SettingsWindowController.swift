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
        window.center()
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
        guard let window = self.window, let content = window.contentView else { return }

        panes = [
            AppSettingsPane(),
            AppearanceSettingsPane(onBadgeChange: onBadgeChange),
            ProviderSettingsPane(onRefresh: onRefresh),
            HookSettingsPane(),
        ]

        let sidebar = NSStackView()
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 4
        sidebar.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        for (index, pane) in panes.enumerated() {
            let button = self.sidebarButton(
                title: pane.paneTitle, tag: index
            )
            // Attach FIRST, then pin: activating constraints between views
            // without a common ancestor throws (same lesson as the old
            // window's detail stack).
            sidebar.addArrangedSubview(button)
            // Pin both edges (with a 10pt inset): every entry stretches to
            // the widest title, so the sidebar width derives from content,
            // not constants.
            button.leadingAnchor.constraint(
                equalTo: sidebar.leadingAnchor, constant: 10
            ).isActive = true
            button.trailingAnchor.constraint(
                equalTo: sidebar.trailingAnchor, constant: -10
            ).isActive = true
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

        // Pin the content size: pane constraints must solve INSIDE the
        // fixed window, never push it around (without this the layout
        // engine resized the content to pane fitting sizes).
        window.styleMask.remove(.resizable)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 640),
            content.heightAnchor.constraint(equalToConstant: 480),
        ])
    }

    // MARK: - Switching

    /// Borderless, layer-backed sidebar entry; the selected entry gets an
    /// accent-filled rounded background (texturedRounded's tint proved
    /// indistinguishable from unselected entries on a dark menu bar app).
    /// Width comes from the entries' intrinsic sizes (widest title wins);
    /// the controller pins both edges to the stack so entries stay equal.
    private func sidebarButton(title: String, tag: Int) -> NSButton {
        let button = NSButton(
            title: title,
            target: self,
            action: #selector(sidebarClicked(_:))
        )
        button.isBordered = false
        button.alignment = .left
        button.tag = tag
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.contentTintColor = .labelColor
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    @objc private func sidebarClicked(_ sender: NSButton) {
        selectPane(at: sender.tag)
    }

    private func selectPane(at index: Int) {
        guard index < panes.count else { return }
        for (i, pane) in panes.enumerated() {
            let showing = i == index
            pane.isHidden = !showing
            // Hidden subtrees are skipped by the layout engine; a pane that
            // was never laid out keeps stale frames when first shown.
            if showing {
                pane.needsLayout = true
                pane.layoutSubtreeIfNeeded()
            }
        }
        for (i, button) in sidebarButtons.enumerated() {
            let selected = i == index
            button.layer?.backgroundColor = selected
                ? NSColor.controlAccentColor.cgColor
                : NSColor.clear.cgColor
            button.contentTintColor = selected ? .controlAccentColor : .labelColor
            // Accent background needs white text for contrast; unselected
            // entries keep the adaptive label color.
            button.attributedTitle = NSAttributedString(
                string: button.title,
                attributes: [
                    .foregroundColor: selected
                        ? NSColor.white
                        : NSColor.labelColor,
                    .font: NSFont.systemFont(ofSize: 13),
                ]
            )
        }
        panes[index].paneWillAppear()
    }
}
