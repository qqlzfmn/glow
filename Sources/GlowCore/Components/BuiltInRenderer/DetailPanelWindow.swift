import AppKit

/// Floating panel that shows traffic light animation and signal details.
final class DetailPanelWindow: NSPanel {
    private let trafficLightView: TrafficLightView
    private let signalLabel: NSTextField
    private let summaryLabel: NSTextField
    private let sessionLabel: NSTextField

    private var displayLink: CVDisplayLink?
    private var signalStartedAt: TimeInterval = 0
    private var isRepeating: Bool = false
    private var flashColor: String = "green"
    private var pollInterval: TimeInterval = 0.5

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        // Create subviews before calling super.
        trafficLightView = TrafficLightView(
            frame: NSRect(x: 0, y: 0, width: 100, height: 170)
        )

        signalLabel = NSTextField(labelWithString: "—")
        signalLabel.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        signalLabel.textColor = NSColor(red: 0xCC/255, green: 0xCC/255, blue: 0xCC/255, alpha: 1)
        signalLabel.backgroundColor = .clear
        signalLabel.isBezeled = false
        signalLabel.isEditable = false
        signalLabel.isSelectable = false

        summaryLabel = NSTextField(labelWithString: "")
        summaryLabel.font = NSFont.systemFont(ofSize: 11)
        summaryLabel.textColor = NSColor(red: 0x99/255, green: 0x99/255, blue: 0x99/255, alpha: 1)
        summaryLabel.backgroundColor = .clear
        summaryLabel.isBezeled = false
        summaryLabel.isEditable = false
        summaryLabel.isSelectable = false
        summaryLabel.maximumNumberOfLines = 3
        summaryLabel.preferredMaxLayoutWidth = 228

        sessionLabel = NSTextField(labelWithString: "")
        sessionLabel.font = NSFont.systemFont(ofSize: 10)
        sessionLabel.textColor = NSColor(red: 0x77/255, green: 0x77/255, blue: 0x77/255, alpha: 1)
        sessionLabel.backgroundColor = .clear
        sessionLabel.isBezeled = false
        sessionLabel.isEditable = false
        sessionLabel.isSelectable = false

        super.init(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: true
        )

        setupWindow()
        layoutContent()
        setupDisplayLink()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public

    func updateSignal(
        name: String,
        summary: String,
        sessionCount: Int,
        isRepeating: Bool,
        flashColor: String
    ) {
        self.isRepeating = isRepeating
        self.flashColor = flashColor
        self.signalStartedAt = CACurrentMediaTime()
        self.pollInterval = 0.5

        signalLabel.stringValue = name.replacingOccurrences(of: "_", with: " ").capitalized
        summaryLabel.stringValue = summary
        sessionLabel.stringValue = "Active sessions: \(sessionCount)"
    }

    func showPanel() {
        positionPanel()
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Private

    private func setupWindow() {
        backgroundColor = NSColor(red: 0x1E/255, green: 0x1E/255, blue: 0x1E/255, alpha: 0.95)
        isOpaque = false
        hasShadow = true
        level = .floating
        isFloatingPanel = true
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        styleMask.insert(.fullSizeContentView)
        hidesOnDeactivate = false
        isMovableByWindowBackground = true

        // Close button just hides.
        standardWindowButton(.closeButton)?.target = self
        standardWindowButton(.closeButton)?.action = #selector(closeButtonClicked)
    }

    @objc private func closeButtonClicked() {
        orderOut(nil)
    }

    private func layoutContent() {
        guard let contentView = contentView else { return }
        contentView.wantsLayer = true

        trafficLightView.translatesAutoresizingMaskIntoConstraints = false
        signalLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        sessionLabel.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(trafficLightView)
        contentView.addSubview(signalLabel)
        contentView.addSubview(summaryLabel)
        contentView.addSubview(sessionLabel)

        NSLayoutConstraint.activate([
            trafficLightView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 30),
            trafficLightView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            trafficLightView.widthAnchor.constraint(equalToConstant: 100),
            trafficLightView.heightAnchor.constraint(equalToConstant: 170),

            signalLabel.topAnchor.constraint(equalTo: trafficLightView.bottomAnchor, constant: 8),
            signalLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            signalLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            summaryLabel.topAnchor.constraint(equalTo: signalLabel.bottomAnchor, constant: 4),
            summaryLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            summaryLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            sessionLabel.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 12),
            sessionLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            sessionLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            sessionLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -16),
        ])
    }

    private func positionPanel() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let panelWidth: CGFloat = 260
        let panelHeight: CGFloat = 340
        let x = screenFrame.maxX - panelWidth - 20
        let y = screenFrame.maxY - panelHeight - 32
        setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
    }

    // MARK: - Animation

    private func setupDisplayLink() {
        // Use a 16ms timer as a cross-platform alternative to CVDisplayLink.
        Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
            self?.tickAnimation()
        }
    }

    private func tickAnimation() {
        var active: Set<String> = []
        if isRepeating {
            let elapsed = CACurrentMediaTime() - signalStartedAt
            let flashOn = Int(elapsed / pollInterval) % 2 == 0
            if flashOn {
                active = [flashColor]
            }
        }
        // For non-repeating steady signals, leave the corresponding light on.
        // (Handled by showing the aggregate color in the traffic light.)
        trafficLightView.activeColors = active
    }
}
