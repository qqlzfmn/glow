import AppKit

/// Bottom-strip controls of the Provider Settings window for the menu
/// bar badge look: value/label font sizes, line spacing, and
/// value/label/separator colors. A working copy of the stored appearance
/// is mutated only by controls the user actually touches — untouched
/// color wells leave the field nil so the dynamic system label color
/// (light/dark adaptive) survives. Every change is sanitized, persisted
/// to the `badge` object in usage.json, and announced via `onApply` so
/// the host can redraw the status item immediately.
final class BadgeAppearanceControls: NSView {
    /// Fired after a change has been persisted; the host redraws the badge.
    var onApply: (() -> Void)?

    /// Working copy of the stored appearance; mutated only by user actions.
    private var working: BadgeAppearance = .standard

    var valueSizeField: NSTextField?
    var labelSizeField: NSTextField?
    var spacingField: NSTextField?
    var valueWell: NSColorWell?
    var labelWell: NSColorWell?
    var separatorWell: NSColorWell?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout

    private func setupContent() {
        let title = makeLabel("Badge")
        let valueSize = makeSizeField(action: #selector(valueSizeChanged))
        let labelSize = makeSizeField(action: #selector(labelSizeChanged))
        let spacing = makeSizeField(action: #selector(spacingChanged))
        valueSizeField = valueSize
        labelSizeField = labelSize
        spacingField = spacing

        let value = makeWell(action: #selector(valueColorChanged))
        let label = makeWell(action: #selector(labelColorChanged))
        let separator = makeWell(action: #selector(separatorColorChanged))
        valueWell = value
        labelWell = label
        separatorWell = separator

        let reset = NSButton(title: "Reset", target: self, action: #selector(resetClicked))
        reset.bezelStyle = .rounded

        let row = NSStackView(views: [
            title,
            makeGroup(caption: "Value Size", control: valueSize),
            makeGroup(caption: "Label Size", control: labelSize),
            makeGroup(caption: "Line Spacing", control: spacing),
            makeGroup(caption: "Value", control: value),
            makeGroup(caption: "Label", control: label),
            makeGroup(caption: "Line", control: separator),
            reset,
        ])
        row.orientation = .horizontal
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func makeGroup(caption: String, control: NSView) -> NSView {
        let label = makeLabel(caption)
        label.font = NSFont.systemFont(ofSize: 9)
        let group = NSStackView(views: [label, control])
        group.orientation = .vertical
        group.alignment = .centerX
        group.spacing = 1
        return group
    }

    private func makeSizeField(action: Selector) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = "auto"
        field.widthAnchor.constraint(equalToConstant: 40).isActive = true
        field.heightAnchor.constraint(equalToConstant: 22).isActive = true
        field.target = self
        field.action = action
        return field
    }

    private func makeWell(action: Selector) -> NSColorWell {
        let well = NSColorWell()
        well.widthAnchor.constraint(equalToConstant: 40).isActive = true
        well.heightAnchor.constraint(equalToConstant: 22).isActive = true
        well.target = self
        well.action = action
        return well
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    // MARK: - Data flow

    /// Snap every control to the current stored appearance (window reload
    /// and post-poll refresh). Reads usage.json itself so the window stays
    /// thin.
    func reloadFromStore() {
        working = (UsageStore.readUsage().badge ?? .standard).sanitized
        valueSizeField?.stringValue = formatSize(working.valueFontSize ?? BadgeAppearance.defaultValueFontSize)
        labelSizeField?.stringValue = formatSize(working.labelFontSize ?? BadgeAppearance.defaultLabelFontSize)
        spacingField?.stringValue = formatSize(working.lineSpacing ?? 0)
        valueWell?.color = resolvedColor(working.valueColor)
        labelWell?.color = resolvedColor(working.labelColor)
        separatorWell?.color = resolvedColor(working.separatorColor)
    }

    private func resolvedColor(_ hex: String?) -> NSColor {
        hex.flatMap { NSColor(hexRGBA: $0) } ?? .labelColor
    }

    private func formatSize(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// Parse a size field; nil when the text is not a usable number. On
    /// failure the field snaps back to the working value, mirroring the
    /// poll-seconds field behavior.
    private func readSize(_ field: NSTextField?, current: Double?) -> Double? {
        guard let text = field?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, let value = Double(text), value.isFinite else {
            field?.stringValue = formatSize(current ?? 0)
            return nil
        }
        return value
    }

    // MARK: - Actions

    @objc func valueSizeChanged() {
        guard let raw = readSize(valueSizeField, current: working.valueFontSize ?? BadgeAppearance.defaultValueFontSize) else { return }
        working.valueFontSize = raw
        apply()
    }

    @objc func labelSizeChanged() {
        guard let raw = readSize(labelSizeField, current: working.labelFontSize ?? BadgeAppearance.defaultLabelFontSize) else { return }
        working.labelFontSize = raw
        apply()
    }

    @objc func spacingChanged() {
        guard let raw = readSize(spacingField, current: working.lineSpacing ?? 0) else { return }
        working.lineSpacing = raw
        apply()
    }

    @objc func valueColorChanged() {
        working.valueColor = hex(valueWell)
        apply()
    }

    @objc func labelColorChanged() {
        working.labelColor = hex(labelWell)
        apply()
    }

    @objc func separatorColorChanged() {
        working.separatorColor = hex(separatorWell)
        apply()
    }

    @objc func resetClicked() {
        working = .standard
        apply()
        reloadFromStore()
    }

    private func hex(_ well: NSColorWell?) -> String? {
        guard let color = well?.color.usingColorSpace(.deviceRGB) else { return nil }
        return BadgeAppearance.hexString(
            BadgeRGB(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
        )
    }

    /// Sanitize, persist to usage.json, and notify the host. An all-default
    /// result clears the `badge` object so the file stays minimal.
    private func apply() {
        let appearance = working.sanitized
        var file = UsageStore.readUsage()
        file.badge = appearance == .standard ? nil : appearance
        do {
            try UsageStore.writeUsage(file)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Badge Appearance"
            alert.informativeText = "Cannot update usage.json: \(error)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        onApply?()
    }
}
