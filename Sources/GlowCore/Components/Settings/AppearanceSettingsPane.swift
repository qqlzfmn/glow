import AppKit

/// Badge appearance section: embeds the existing BadgeAppearanceControls
/// strip (usage.json `badge` object) unchanged — it owns its own
/// persistence; this pane only hosts it and forwards the apply callback.
final class AppearanceSettingsPane: NSView, SettingsPane {
    let paneTitle = "Appearance"

    private let onBadgeChange: () -> Void
    private var badgeControls: BadgeAppearanceControls?

    init(onBadgeChange: @escaping () -> Void) {
        self.onBadgeChange = onBadgeChange
        super.init(frame: .zero)
        setupContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupContent() {
        let title = makeSettingsLabel("Appearance", size: 14, bold: true)
        let hint = makeSettingsLabel(
            "Customize the menu bar badge: font sizes, line spacing, colors.",
            color: .secondaryLabelColor
        )
        let controls = BadgeAppearanceControls(frame: .zero)
        // Not inside a stack: like the old window, pin it directly so its
        // intrinsic strip width cannot propagate up and stretch the window.
        controls.translatesAutoresizingMaskIntoConstraints = false
        // No intrinsic height (plain NSView): pin it, like the old window did.
        controls.heightAnchor.constraint(equalToConstant: 44).isActive = true
        controls.onApply = { [weak self] in self?.onBadgeChange() }
        badgeControls = controls

        addSubview(title)
        addSubview(hint)
        addSubview(controls)
        // Directly-added subviews default to autoresizing translation, whose
        // generated pin-at-origin constraints override the anchors below.
        for view in [title, hint] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),

            hint.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            hint.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),

            controls.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 16),
            controls.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
        ])
    }

    func paneWillAppear() {
        badgeControls?.reloadFromStore()
    }
}
