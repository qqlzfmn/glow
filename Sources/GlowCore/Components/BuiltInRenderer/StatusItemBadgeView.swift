import AppKit

/// Custom drawing surface for the menu bar item: lamp on the left, then a
/// faint vertical hairline, then usage segments — value on top, label
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
    var segments: [Segment] = [] {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }

    private let lampDiameter: CGFloat = 12
    private let lampGap: CGFloat = 6          // lamp ↔ first hairline
    private let hairlineGap: CGFloat = 6      // hairline ↔ segment content
    private let segmentPadding: CGFloat = 2   // content inset inside a cell
    private let valueFont = NSFont.systemFont(ofSize: 11, weight: .regular)
    private let labelFont = NSFont.systemFont(ofSize: 7.5)
    private let separatorColor = NSColor.labelColor.withAlphaComponent(0.30)

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

            // Value on top (bright), label underneath (secondary), tight
            // two-line block vertically centered.
            (segment.value as NSString).draw(
                at: NSPoint(x: x + (cellWidth - valueSize.width) / 2, y: midY + 1),
                withAttributes: [.font: valueFont, .foregroundColor: NSColor.labelColor]
            )
            (segment.label as NSString).draw(
                at: NSPoint(x: x + (cellWidth - labelSize.width) / 2, y: midY - labelSize.height - 1),
                withAttributes: [.font: labelFont, .foregroundColor: NSColor.secondaryLabelColor]
            )
            x += cellWidth + segmentPadding * 2
        }
    }

    private func drawHairline(at x: CGFloat, midY: CGFloat) {
        let line = NSRect(x: x, y: midY - 6, width: 1, height: 12)
        separatorColor.setFill()
        NSBezierPath(rect: line).fill()
    }
}
