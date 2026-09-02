import AppKit

/// Custom NSView that draws three traffic light circles (red, yellow, green).
final class TrafficLightView: NSView {
    private let lightRadius: CGFloat = 20
    private let lightGap: CGFloat = 16
    private let centerX: CGFloat = 50

    /// Colors for each light: red, yellow, green. Updated by the panel.
    var activeColors: Set<String> = [] {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let dimColor = NSColor(red: 0x3A/255.0, green: 0x3A/255.0, blue: 0x3A/255.0, alpha: 1)
        let outlineColor = NSColor(red: 0x55/255.0, green: 0x55/255.0, blue: 0x55/255.0, alpha: 1)

        let colors: [(String, NSColor)] = [
            ("red",    NSColor(red: 244/255, green: 67/255,  blue: 54/255,  alpha: 1)),
            ("yellow", NSColor(red: 255/255, green: 193/255, blue: 7/255,   alpha: 1)),
            ("green",  NSColor(red: 76/255,  green: 175/255, blue: 80/255,  alpha: 1)),
        ]

        var y: CGFloat = 30
        for (name, activeColor) in colors {
            let rect = NSRect(
                x: centerX - lightRadius,
                y: y - lightRadius,
                width: lightRadius * 2,
                height: lightRadius * 2
            )

            let fill = activeColors.contains(name) ? activeColor : dimColor
            ctx.setFillColor(fill.cgColor)
            ctx.setStrokeColor(outlineColor.cgColor)
            ctx.setLineWidth(2)

            let path = NSBezierPath(ovalIn: rect)
            path.fill()
            path.stroke()

            y += lightRadius * 2 + lightGap
        }
    }
}
