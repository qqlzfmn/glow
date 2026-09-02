import AppKit

/// Settings window for usage providers: the left table lists every supported
/// provider type with its configuration state (configured / auto-discovered /
/// not configured); the right pane renders a dynamic credential form per
/// provider kind. Saving writes the 0600 explicit config and fires
/// `onRefresh`, so new providers appear in the menu within seconds.
final class ProviderSettingsWindowController: NSWindowController {
    /// Left-table row: one per supported kind, resolved against the explicit
    /// config, auto-discovery, and the latest usage snapshot.
    struct RowState {
        let kind: UsageProviderKind
        let explicit: UsageProviderConfig?
        let snapshot: ProviderUsage?

        enum State { case configured, notConfigured }

        var state: State {
            explicit != nil ? .configured : .notConfigured
        }

        /// The values the form is pre-filled with.
        var activeConfig: UsageProviderConfig? { explicit }

        /// Pure resolver, fixture-testable.
        static func resolve(
            kinds: [UsageProviderKind],
            explicit: [UsageProviderConfig],
            snapshots: [String: ProviderUsage]
        ) -> [RowState] {
            kinds.map { kind in
                RowState(
                    kind: kind,
                    explicit: explicit.first { $0.providerKey == kind.type },
                    snapshot: snapshots[kind.type]
                )
            }
        }
    }

    private var rows: [RowState] = []
    private var selectedIndex: Int = 0

    /// Called after a save/delete; the host triggers UsageMonitor to
    /// re-discover and poll immediately.
    private let onRefresh: () -> Void

    private var tableView: NSTableView?
    private var detailStack: NSStackView?
    private var pollMinutesField: NSTextField?
    /// Live handles of the form fields of the currently displayed detail.
    private var fieldViews: [(key: String, field: NSTextField)] = []
    private var baseURLField: NSTextField?
    private var unitOverrideField: NSTextField?
    /// Optional display-name override field of the current detail form.
    private var displayNameField: NSTextField?

    init(onRefresh: @escaping () -> Void) {
        self.onRefresh = onRefresh
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Usage Providers"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        setupContent()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        reload()
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Layout

    private func setupContent() {
        guard let content = window?.contentView else { return }

        let listScrollView = NSScrollView()
        listScrollView.hasVerticalScroller = true
        listScrollView.borderType = .bezelBorder

        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 24
        table.allowsEmptySelection = false
        let column = NSTableColumn(identifier: .init("provider"))
        column.width = 200
        table.addTableColumn(column)
        table.delegate = self
        table.dataSource = self
        listScrollView.documentView = table
        tableView = table

        let detailScroll = NSScrollView()
        detailScroll.hasVerticalScroller = true
        detailScroll.borderType = .noBorder
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        // Attach to the hierarchy FIRST, then pin: activating cross-view
        // constraints before `documentView` assignment throws
        // "no common ancestor" and kills the action chain.
        detailScroll.documentView = stack
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            // Pin the width or the stack collapses to zero inside the
            // scroll view and the whole detail pane renders blank.
            stack.leadingAnchor.constraint(equalTo: detailScroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: detailScroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: detailScroll.contentView.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: detailScroll.contentView.bottomAnchor),
        ])
        detailStack = stack

        let pollLabel = makeLabel("Auto refresh (min)", color: .secondaryLabelColor)
        let pollField = NSTextField()
        pollField.placeholderString = "5"
        pollField.widthAnchor.constraint(equalToConstant: 44).isActive = true
        pollField.heightAnchor.constraint(equalToConstant: 22).isActive = true
        pollField.target = self
        pollField.action = #selector(pollMinutesChanged)
        pollMinutesField = pollField
        let refreshButton = NSButton(title: "Refresh Now", target: self, action: #selector(refreshClicked))
        refreshButton.bezelStyle = .rounded
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeClicked))
        closeButton.bezelStyle = .rounded
        let pollGroup = NSStackView(views: [pollLabel, pollField])
        pollGroup.orientation = .horizontal
        pollGroup.spacing = 6
        let buttonRow = NSStackView(views: [pollGroup, refreshButton, closeButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12

        for view in [listScrollView, detailScroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(listScrollView)
        content.addSubview(detailScroll)
        content.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            listScrollView.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            listScrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            listScrollView.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -12),
            listScrollView.widthAnchor.constraint(equalToConstant: 210),

            detailScroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            detailScroll.leadingAnchor.constraint(equalTo: listScrollView.trailingAnchor, constant: 12),
            detailScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            detailScroll.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -12),

            buttonRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            buttonRow.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])

        pollMinutesField?.stringValue = String(
            Int((UsageMonitor.effectivePollInterval() / 60.0).rounded())
        )
    }

    // MARK: - Data loading

    private func reload() {
        rows = RowState.resolve(
            kinds: UsageKinds.all,
            explicit: UsageConfigStore.load(),
            snapshots: UsageStore.readUsage().providers
        )
        if selectedIndex >= rows.count { selectedIndex = 0 }
        tableView?.reloadData()
        tableView?.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        rebuildDetail()
    }

    private func selectedRow() -> RowState? {
        guard selectedIndex < rows.count else { return nil }
        return rows[selectedIndex]
    }

    // MARK: - Detail form

    private func rebuildDetail() {
        guard let stack = detailStack else { return }
        stack.views.forEach { stack.removeView($0) }
        fieldViews = []
        baseURLField = nil

        guard let row = selectedRow() else { return }
        let kind = row.kind

        stack.addArrangedSubview(makeLabel(kind.displayName, size: 14, bold: true))

        switch row.state {
        case .configured:
            stack.addArrangedSubview(
                makeLabel("Configured in \(UsageConfigStore.configFile())", color: .secondaryLabelColor)
            )
        case .notConfigured:
            stack.addArrangedSubview(makeLabel("Not configured yet.", color: .secondaryLabelColor))
        }

        if let snapshot = row.snapshot, !snapshot.items.isEmpty {
            let usage = snapshot.items.map { UsageBadge.itemText($0) }.joined(separator: " · ")
            stack.addArrangedSubview(makeLabel("Current: \(usage)", color: .secondaryLabelColor))
        } else {
            stack.addArrangedSubview(makeLabel("Current: no data yet", color: .tertiaryLabelColor))
        }

        stack.addArrangedSubview(makeSeparator())

        let active = row.activeConfig

        // Optional display-name override (e.g. call "New API" "DMXAPI").
        let nameField = NSTextField()
        nameField.placeholderString = kind.displayName
        nameField.stringValue = active?.displayName ?? kind.displayName
        stack.addArrangedSubview(makeFieldRow(label: "Display name (optional)", field: nameField))
        displayNameField = nameField

        for prompt in kind.prompts {
            let field = prompt.secret ? NSSecureTextField() : NSTextField()
            field.placeholderString = prompt.prompt
            if prompt.key == "token" {
                field.stringValue = active?.token ?? ""
            } else {
                field.stringValue = active?.extra[prompt.key] ?? ""
            }
            stack.addArrangedSubview(makeFieldRow(label: prompt.prompt, field: field))
            fieldViews.append((key: prompt.key, field: field))
        }

        let baseField = NSTextField()
        baseField.placeholderString = "https://…"
        baseField.stringValue = active?.baseURL ?? ""
        stack.addArrangedSubview(makeFieldRow(label: "Base URL (optional)", field: baseField))
        baseURLField = baseField

        // Display-unit override (extra["unit"]) only applies to balance
        // providers; plan providers show percentages. Free-form concat:
        // "$", "€", "¥", "CNY" all work.
        if kind.balanceBased {
            let unitField = NSTextField()
            unitField.placeholderString = "$ / € / ¥ / CNY"
            unitField.stringValue = active?.extra["unit"] ?? ""
            stack.addArrangedSubview(makeFieldRow(label: "Unit (optional)", field: unitField))
            unitOverrideField = unitField
        } else {
            unitOverrideField = nil
        }

        let save = NSButton(title: "Save", target: self, action: #selector(saveClicked))
        save.bezelStyle = .rounded
        stack.addArrangedSubview(save)

        if row.state == .configured {
            let delete = NSButton(title: "Remove", target: self, action: #selector(removeClicked))
            delete.bezelStyle = .rounded
            stack.addArrangedSubview(delete)
        }
    }

    private func makeFieldRow(label: String, field: NSTextField) -> NSView {
        let text = makeLabel(label, color: .secondaryLabelColor)
        text.widthAnchor.constraint(equalToConstant: 170).isActive = true
        text.alignment = .right
        field.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let row = NSStackView(views: [text, field])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func makeLabel(_ text: String, size: CGFloat = 11, bold: Bool = false, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = bold ? NSFont.systemFont(ofSize: size, weight: .semibold) : NSFont.systemFont(ofSize: size)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func makeSeparator() -> NSView {
        let separator = NSBox()
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: 280).isActive = true
        return separator
    }

    // MARK: - Actions

    @objc private func saveClicked() {
        guard let row = selectedRow() else { return }
        guard let first = fieldViews.first else { return }
        let token = first.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            presentError(message: "\(row.kind.displayName) needs a non-empty \(first.key).")
            return
        }
        var extra: [String: String] = [:]
        for entry in fieldViews.dropFirst() {
            let value = entry.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                extra[entry.key] = value
            }
        }
        if let unit = unitOverrideField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
           !unit.isEmpty {
            extra["unit"] = unit
        }
        var baseURL: String?
        if let base = baseURLField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
           !base.isEmpty {
            baseURL = base
        }

        // Empty display-name field keeps the built-in name.
        var displayName = displayNameField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if displayName.isEmpty {
            displayName = row.kind.displayName
        }

        let config = UsageProviderConfig(
            providerKey: row.kind.type,
            displayName: displayName,
            baseURL: baseURL,
            token: token,
            extra: extra
        )
        do {
            try UsageConfigStore.upsert(config)
        } catch {
            presentError(message: "Cannot write \(UsageConfigStore.configFile()): \(error)")
            return
        }
        onRefresh()
        // The triggered poll lands within a couple of seconds; refresh the
        // Current line (and badges) once it has landed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.reload()
        }
    }

    @objc private func removeClicked() {
        guard let row = selectedRow(), row.state == .configured else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(row.kind.displayName)?"
        alert.informativeText = "Its credentials are deleted from the explicit config."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            _ = try UsageConfigStore.remove(providerKey: row.kind.type)
        } catch {
            presentError(message: "Cannot update \(UsageConfigStore.configFile()): \(error)")
            return
        }
        onRefresh()
        reload()
    }

    /// Persist the auto-refresh interval (minutes → seconds). Applied on the
    /// next poll cycle — the loop resolves the interval fresh each round.
    @objc private func pollMinutesChanged() {
        guard let text = pollMinutesField?.stringValue.trimmingCharacters(in: .whitespaces),
              let minutes = Int(text), minutes >= 1 else {
            // Invalid input: snap the field back to the effective value.
            pollMinutesField?.stringValue = String(
                Int((UsageMonitor.effectivePollInterval() / 60.0).rounded())
            )
            return
        }
        var file = UsageStore.readUsage()
        file.pollSeconds = minutes * 60
        do {
            try UsageStore.writeUsage(file)
        } catch {
            presentError(message: "Cannot update \(UsageConfigStore.configFile()): \(error)")
        }
    }

    @objc private func refreshClicked() {
        onRefresh()
        // The poll lands within a couple of seconds; refresh the snapshot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.reload()
        }
    }

    @objc private func closeClicked() {
        window?.orderOut(nil)
    }

    private func presentError(message: String) {
        let alert = NSAlert()
        alert.messageText = "Usage Providers"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

extension ProviderSettingsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Keep the controller alive for reopen; nothing to release.
    }
}

// MARK: - Table view

extension ProviderSettingsWindowController: NSTableViewDelegate, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let rowState = rows[row]
        let stateText: String
        let stateColor: NSColor
        switch rowState.state {
        case .configured:
            stateText = "configured"
            stateColor = .systemGreen
        case .notConfigured:
            stateText = "—"
            stateColor = .tertiaryLabelColor
        }

        let container = NSStackView(views: [
            makeLabel(rowState.kind.displayName, color: .labelColor),
            makeLabel(stateText, color: stateColor),
        ])
        container.orientation = .horizontal
        container.distribution = .fill
        container.spacing = 6
        return container
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let selected = tableView?.selectedRow ?? 0
        if selected >= 0, selected != selectedIndex {
            selectedIndex = selected
            rebuildDetail()
        }
    }
}
