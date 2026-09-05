import AppKit

/// Flipped document stack: y=0 is the top edge, so a short form stays
/// glued to the top of the detail column and the scroll origin at rest
/// is always (0, 0).
private final class TopAlignedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

/// Providers section: the left table lists every supported provider type
/// with its configuration state (configured / not configured); the right
/// pane renders a dynamic credential form per provider kind. Saving writes
/// the 0600 explicit config and fires `onRefresh`, so new providers appear
/// in the menu within seconds. The auto-refresh interval (poll_seconds)
/// and Refresh Now also live here — they are provider-polling concerns.
final class ProviderSettingsPane: NSView, SettingsPane {
    let paneTitle = "Providers"

    /// Left-table row: one per supported kind, resolved against the
    /// explicit config and the latest usage snapshot.
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
    private var detailScroll: NSScrollView!
    private var detailStack: NSStackView?
    private var pollSecondsField: NSTextField?
    /// Bottom action row of the detail column; Remove only applies to
    /// configured providers (visibility driven by rebuildDetail).
    private var removeButton: NSButton?
    /// Live handles of the form fields of the currently displayed detail.
    private var fieldViews: [(key: String, field: NSTextField)] = []
    private var baseURLField: NSTextField?
    private var unitOverrideField: NSTextField?
    /// Optional display-name override field of the current detail form.
    private var displayNameField: NSTextField?

    init(onRefresh: @escaping () -> Void) {
        self.onRefresh = onRefresh
        super.init(frame: .zero)
        setupContent()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func paneWillAppear() {
        reload()
    }

    // MARK: - Layout

    private func setupContent() {
        let listScrollView = NSScrollView()
        listScrollView.hasVerticalScroller = true
        listScrollView.borderType = .bezelBorder

        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 24
        table.allowsEmptySelection = false
        let column = NSTableColumn(identifier: .init("provider"))
        // Must match the list viewport (170); a wider column clips the
        // trailing status marker outside the scroll view.
        column.width = 170
        table.addTableColumn(column)
        table.delegate = self
        table.dataSource = self
        listScrollView.documentView = table
        tableView = table

        let detailScroll = NSScrollView()
        self.detailScroll = detailScroll
        detailScroll.hasVerticalScroller = true
        detailScroll.borderType = .noBorder
        let stack = TopAlignedStackView()
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
            // scroll view and the whole detail pane renders blank. Flipped
            // origin keeps the form glued to the top for short content.
            stack.leadingAnchor.constraint(equalTo: detailScroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: detailScroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: detailScroll.contentView.topAnchor),
        ])
        detailStack = stack

        let pollLabel = makeSettingsLabel("Auto refresh (sec)", color: .secondaryLabelColor)
        let pollField = NSTextField()
        pollField.placeholderString = "300"
        pollField.widthAnchor.constraint(equalToConstant: 44).isActive = true
        pollField.heightAnchor.constraint(equalToConstant: 22).isActive = true
        pollField.target = self
        pollField.action = #selector(pollSecondsChanged)
        pollSecondsField = pollField
        let refreshButton = NSButton(
            title: "Refresh Now", target: self, action: #selector(refreshClicked)
        )
        refreshButton.bezelStyle = .rounded
        let pollGroup = NSStackView(views: [pollLabel, pollField])
        pollGroup.orientation = .horizontal
        pollGroup.spacing = 6
        let buttonRow = NSStackView(views: [pollGroup, refreshButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12

        // Detail action row: pinned to the bottom of the detail column so
        // Save/Remove stay put regardless of form length.
        let saveButton = NSButton(
            title: "Save", target: self, action: #selector(saveClicked)
        )
        saveButton.bezelStyle = .rounded
        let removeButton = NSButton(
            title: "Remove", target: self, action: #selector(removeClicked)
        )
        removeButton.bezelStyle = .rounded
        self.removeButton = removeButton
        let saveRow = NSStackView(views: [saveButton, removeButton])
        saveRow.orientation = .horizontal
        saveRow.spacing = 8

        for view in [listScrollView, detailScroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        saveRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(listScrollView)
        addSubview(detailScroll)
        addSubview(buttonRow)
        addSubview(saveRow)

        NSLayoutConstraint.activate([
            listScrollView.topAnchor.constraint(equalTo: topAnchor),
            listScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            listScrollView.bottomAnchor.constraint(
                equalTo: buttonRow.topAnchor, constant: -12
            ),
            listScrollView.widthAnchor.constraint(equalToConstant: 170),

            detailScroll.topAnchor.constraint(equalTo: topAnchor),
            detailScroll.leadingAnchor.constraint(
                equalTo: listScrollView.trailingAnchor, constant: 12
            ),
            detailScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            detailScroll.bottomAnchor.constraint(
                equalTo: saveRow.topAnchor, constant: -10
            ),

            // Align the row with the detail stack's 12pt edge inset.
            saveRow.leadingAnchor.constraint(
                equalTo: detailScroll.leadingAnchor, constant: 12
            ),
            saveRow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            saveRow.bottomAnchor.constraint(
                equalTo: buttonRow.topAnchor, constant: -12
            ),

            buttonRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            buttonRow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            buttonRow.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        pollSecondsField?.stringValue = String(
            Int(UsageMonitor.effectivePollInterval().rounded())
        )
    }

    // MARK: - Data loading

    private func reload() {
        rows = RowState.resolve(
            kinds: UsageKinds.all,
            explicit: UsageConfigStore.load(),
            snapshots: UsageStore.readUsage().providers
        )
        tableView?.reloadData()
        tableView?.selectRowIndexes(
            IndexSet(integer: selectedIndex), byExtendingSelection: false
        )
        rebuildDetail()
        // Switching providers swaps document height; a stale scroll offset
        // would visually push the shorter form down — snap back to the top
        // (the flipped document's origin is its top edge).
        detailScroll.documentView?.scroll(NSPoint(x: 0, y: 0))
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

        stack.addArrangedSubview(makeSettingsLabel(kind.displayName, size: 14, bold: true))

        switch row.state {
        case .configured:
            stack.addArrangedSubview(
                makeSettingsLabel(
                    "Configured in \(UsageConfigStore.configFile())",
                    color: .secondaryLabelColor
                )
            )
        case .notConfigured:
            stack.addArrangedSubview(
                makeSettingsLabel("Not configured yet.", color: .secondaryLabelColor)
            )
        }

        if let snapshot = row.snapshot, !snapshot.items.isEmpty {
            let usage = snapshot.items.map { UsageBadge.itemText($0) }
                .joined(separator: " · ")
            stack.addArrangedSubview(
                makeSettingsLabel("Current: \(usage)", color: .secondaryLabelColor)
            )
        } else {
            stack.addArrangedSubview(
                makeSettingsLabel("Current: no data yet", color: .tertiaryLabelColor)
            )
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

        if kind.usesBaseURL {
            let baseField = NSTextField()
            // Show the full default endpoint so the user knows what an
            // empty field means.
            baseField.placeholderString = kind.defaultBaseURL ?? "https://…"
            baseField.stringValue = active?.baseURL ?? ""
            stack.addArrangedSubview(makeFieldRow(label: "Base URL (optional)", field: baseField))
            baseURLField = baseField
        } else {
            baseURLField = nil
        }

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

        // Save/Remove live in the fixed bottom row; Remove only applies
        // to providers already in the explicit config.
        removeButton?.isHidden = row.state != .configured
    }

    /// Vertical row: caption above, field below. The detail column is
    /// ~284pt wide, so the old horizontal 170+240 row could never fit and
    /// stretched the window; stacked rows fit a fixed 240pt field cleanly.
    private func makeFieldRow(label: String, field: NSTextField) -> NSView {
        let text = makeSettingsLabel(label, color: .secondaryLabelColor)
        field.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let row = NSStackView(views: [text, field])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 2
        return row
    }

    private func makeSeparator() -> NSView {
        let separator = NSBox()
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: 240).isActive = true
        return separator
    }

    // MARK: - Actions

    @objc private func saveClicked() {
        guard let row = selectedRow() else { return }
        guard let first = fieldViews.first else { return }
        let token = first.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            presentSettingsError(
                "\(row.kind.displayName) needs a non-empty \(first.key)."
            )
            return
        }
        var extra: [String: String] = [:]
        for entry in fieldViews.dropFirst() {
            let value = entry.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                extra[entry.key] = value
            }
        }
        if let unit = unitOverrideField?.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !unit.isEmpty {
            extra["unit"] = unit
        }
        var baseURL: String?
        if let base = baseURLField?.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !base.isEmpty {
            baseURL = base
        }

        // Empty display-name field keeps the built-in name.
        var displayName = displayNameField?.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
            presentSettingsError(
                "Cannot write \(UsageConfigStore.configFile()): \(error)"
            )
            return
        }
        onRefresh()
        // The triggered poll lands within a couple of seconds; refresh the
        // Current line once it has landed.
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
            presentSettingsError(
                "Cannot update \(UsageConfigStore.configFile()): \(error)"
            )
            return
        }
        onRefresh()
        reload()
    }

    /// Persist the auto-refresh interval in seconds. Applied on the next
    /// poll cycle — the loop resolves the interval fresh each round. The
    /// 10s floor mirrors `UsageMonitor.effectivePollInterval()`, which
    /// ignores anything smaller.
    @objc private func pollSecondsChanged() {
        guard let text = pollSecondsField?.stringValue
            .trimmingCharacters(in: .whitespaces),
            let seconds = Int(text), seconds >= 10 else {
            // Invalid input: snap the field back to the effective value.
            pollSecondsField?.stringValue = String(
                Int(UsageMonitor.effectivePollInterval().rounded())
            )
            return
        }
        var file = UsageStore.readUsage()
        file.pollSeconds = seconds
        do {
            try UsageStore.writeUsage(file)
        } catch {
            presentSettingsError(
                "Cannot update \(UsageConfigStore.configFile()): \(error)"
            )
        }
    }

    @objc private func refreshClicked() {
        onRefresh()
        // The poll lands within a couple of seconds; refresh the snapshot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.reload()
        }
    }
}

// MARK: - Table view

extension ProviderSettingsPane: NSTableViewDelegate, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard row < rows.count else { return nil }
        let rowState = rows[row]
        // Configured providers use the full-strength label color; the rest
        // stay dim — no per-row status marker needed.
        let label = makeSettingsLabel(
            rowState.kind.displayName,
            color: rowState.state == .configured ? .labelColor : .tertiaryLabelColor
        )
        label.translatesAutoresizingMaskIntoConstraints = false
        // Center vertically, keep a small leading inset (the raw cell view
        // otherwise draws the text flush against the row edge).
        let container = NSView()
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
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
