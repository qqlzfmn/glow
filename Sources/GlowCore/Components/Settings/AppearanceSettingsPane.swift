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
        // Autoresizing-mask constraints from the initial frame fight the
        // explicit constraints below (same lesson as the old window).
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.onApply = { [weak self] in self?.onBadgeChange() }
        badgeControls = controls

        let stack = NSStackView(views: [title, hint, controls])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
        ])
    }

    func paneWillAppear() {
        badgeControls?.reloadFromStore()
    }
}
