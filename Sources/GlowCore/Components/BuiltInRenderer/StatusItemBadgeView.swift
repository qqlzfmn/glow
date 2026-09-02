import AppKit

/// Custom drawing surface for the menu bar item: lamp on the left, then a
/// vertical separator, then usage segments — value on top, label underneath
/// (iStat-style), separated by hairlines with breathing room. Replaces the
/// plain-icon + single-line-text rendering, which cannot do two-line rows.
final class StatusItemBadgeView: NSView {
    struct Segment {
        /// Top-line value, e.g. `62%` or `$53.2`.
        var value: String
        /// Bottom-line label, e.g. `5h` or `Balance`.
        var label: String
    }

    var lampColor: NSColor = .systemGreen
    var lampDimmed: Bool = false
    var segments: [Segment] = [] {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }

    private let lampDiameter: CGFloat = 13
    private let separatorGap: CGFloat = 5
    private let segmentPadding: CGFloat = 6
    private let valueFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    private let labelFont = NSFont.systemFont(ofSize: 7.5)

    override var intrinsicContentSize: NSSize {
        NSSize(width: fittingWidth(), height: super.intrinsicContentSize.height)
    }

    private func fittingWidth() -> CGFloat {
        // Lamp + right gap + first separator, then each segment cell with
        // its own surrounding hairline.
        var width = lampDiameter + separatorGap + 1 + separatorGap
        for segment in segments {
            let valueWidth = (segment.value as NSString).size(
                withAttributes: [.font: valueFont]
            ).width
            let labelWidth = (segment.label as NSString).size(
                withAttributes: [.font: labelFont]
            ).width
            width += max(valueWidth, labelWidth) + segmentPadding * 2 + 1 + separatorGap * 2
        }
        return ceil(width)
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
        x += lampDiameter + separatorGap

        for segment in segments {
            drawSeparator(at: x, midY: midY)
            x += 1 + separatorGap

            let attributes: [NSAttributedString.Key: Any] = [:]
            _ = attributes
            let valueSize = (segment.value as NSString).size(withAttributes: [.font: valueFont])
            let labelSize = (segment.label as NSString).size(withAttributes: [.font: labelFont])
            let cellWidth = max(valueSize.width, labelSize.width)

            // Value on top (bright), label underneath (dimmer).
            (segment.value as NSString).draw(
                at: NSPoint(x: x + (cellWidth - valueSize.width) / 2, y: bounds.height - valueSize.height - 1.5),
                withAttributes: [.font: valueFont, .foregroundColor: NSColor.labelColor]
            )
            (segment.label as NSString).draw(
                at: NSPoint(x: x + (cellWidth - labelSize.width) / 2, y: 1),
                withAttributes: [.font: labelFont, .foregroundColor: NSColor.secondaryLabelColor]
            )
            x += cellWidth + segmentPadding
        }
    }

    private func drawSeparator(at x: CGFloat, midY: CGFloat) {
        let line = NSRect(x: x, y: midY - 6, width: 1, height: 12)
        NSColor.separatorColor.setFill()
        NSBezierPath(rect: line).fill()
    }
}
