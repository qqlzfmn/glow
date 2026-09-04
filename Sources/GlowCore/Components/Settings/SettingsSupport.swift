import AppKit

// MARK: - Shared helpers for settings panes

/// Label factory shared by the settings panes (title / caption / status
/// styles stay consistent across sections).
func makeSettingsLabel(
    _ text: String,
    size: CGFloat = 11,
    bold: Bool = false,
    color: NSColor = .labelColor
) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = bold
        ? NSFont.systemFont(ofSize: size, weight: .semibold)
        : NSFont.systemFont(ofSize: size)
    label.textColor = color
    label.lineBreakMode = .byTruncatingTail
    return label
}

/// Modal error alert shared by the settings panes; never fails silently.
func presentSettingsError(_ message: String) {
    let alert = NSAlert()
    alert.messageText = "Settings"
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    alert.runModal()
}
