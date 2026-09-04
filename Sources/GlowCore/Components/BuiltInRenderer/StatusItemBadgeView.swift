import AppKit

/// Custom drawing surface for the menu bar item: lamp on the left, then a
/// vertical hairline, then usage segments — value on top, label
/// underneath (iStat-style). The last segment carries no trailing
/// separator, so the badge ends flush with its content.
final class StatusItemBadgeView: NSView {
    struct Segment {
        /// Top-line value, e.g. `62%` or `$53.2`.
        var value: String
        /// Bottom-line label, e.g. `5 Hours` or `Balance`.
        var label: String
    }

    var lampColor: NSColor = .systemGreen
    var lampDimmed: Bool = false
    /// Rendering overrides from usage.json (`badge`); `.standard` keeps
    /// the built-in look.
    var badgeAppearance: BadgeAppearance = .standard {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }
    var segments: [Segment] = [] {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }

    private let lampDiameter: CGFloat = 12
    private let lampGap: CGFloat = 6          // lamp ↔ first hairline
    private let hairlineGap: CGFloat = 6      // hairline ↔ segment content
    private let segmentPadding: CGFloat = 2   // content inset inside a cell

    private var valueFont: NSFont {
        NSFont.systemFont(
            ofSize: badgeAppearance.valueFontSize ?? BadgeAppearance.defaultValueFontSize,
            weight: .regular
        )
    }
    private var labelFont: NSFont {
        NSFont.systemFont(
            ofSize: badgeAppearance.labelFontSize ?? BadgeAppearance.defaultLabelFontSize
        )
    }
    /// `lineSpacing` is split above/below the badge center so the block
    /// stays vertically centered as it spreads.
    private var lineSpread: CGFloat { (badgeAppearance.lineSpacing ?? 0) / 2 }

    /// Hex override or the dynamic system color that follows the menu
    /// bar appearance.
    private func foregroundColor(_ hex: String?) -> NSColor {
        hex.flatMap { NSColor(hexRGBA: $0) } ?? .labelColor
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(fittingWidth()), height: super.intrinsicContentSize.height)
    }

    private func fittingWidth() -> CGFloat {
        // Lamp, hairline, then each cell; no trailing hairline or padding
        // after the last segment.
        var width = lampDiameter + lampGap + 1 + hairlineGap
        for segment in segments {
            let valueWidth = (segment.value as NSString).size(
                withAttributes: [.font: valueFont]
            ).width
            let labelWidth = (segment.label as NSString).size(
                withAttributes: [.font: labelFont]
            ).width
            width += max(valueWidth, labelWidth) + segmentPadding * 2 + 1 + hairlineGap * 2
        }
        // Trim the trailing hairline + gap of the last cell.
        if !segments.isEmpty {
            width -= (1 + hairlineGap * 2)
        }
        return width
    }

    override func draw(_ dirtyRect: NSRect) {
        let midY = bounds.midY
        var x: CGFloat = 0

        // Lamp: filled circle, dimmed when the flash phase is off.
        let lamp = lampDimmed ? lampColor.withAlphaComponent(0.25) : lampColor
        lamp.setFill()
        NSBezierPath(
            ovalIn: NSRect(x: x, y: midY - lampDiameter / 2, width: lampDiameter, height: lampDiameter)
        ).fill()
        x += lampDiameter + lampGap

        for segment in segments {
            // One leading hairline per segment — never a trailing one, or
            // consecutive segments render a double bar.
            drawHairline(at: x, midY: midY)
            x += 1 + hairlineGap

            let valueSize = (segment.value as NSString).size(withAttributes: [.font: valueFont])
            let labelSize = (segment.label as NSString).size(withAttributes: [.font: labelFont])
            let cellWidth = max(valueSize.width, labelSize.width)

            // Value on top, label underneath, tight two-line block
            // vertically centered — both at full label color.
            (segment.value as NSString).draw(
                at: NSPoint(x: x + (cellWidth - valueSize.width) / 2, y: midY + 1 + lineSpread),
                withAttributes: [.font: valueFont, .foregroundColor: foregroundColor(badgeAppearance.valueColor)]
            )
            (segment.label as NSString).draw(
                at: NSPoint(x: x + (cellWidth - labelSize.width) / 2, y: midY - labelSize.height - lineSpread),
                withAttributes: [.font: labelFont, .foregroundColor: foregroundColor(badgeAppearance.labelColor)]
            )
            x += cellWidth + segmentPadding * 2
        }
    }

    private func drawHairline(at x: CGFloat, midY: CGFloat) {
        let line = NSRect(x: x, y: midY - 8, width: 1, height: 16)
        foregroundColor(badgeAppearance.separatorColor).setFill()
        NSBezierPath(rect: line).fill()
    }
}

extension NSColor {
    /// `#RRGGBB` / `RRGGBB` (case-insensitive); nil on anything else.
    convenience init?(hexRGBA text: String) {
        guard let rgb = BadgeAppearance.parseHex(text) else { return nil }
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }
}
