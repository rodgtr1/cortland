import Cocoa
import CortlandTelemetryCore
import CortlandProInterface

protocol AgentDashboardDelegate: AnyObject {
    func agentDashboardTabs(_ dashboard: AgentDashboardViewController) -> [TabModel]
    func agentDashboard(_ dashboard: AgentDashboardViewController, didSelectTabAt index: Int)
}

/// Sidebar panel showing every tab's agent state with elapsed time.
/// Clicking a row jumps to that tab.
final class AgentDashboardViewController: NSViewController {
    weak var delegate: AgentDashboardDelegate?

    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var emptyLabel: NSTextField!
    /// Bottom roll-up summing cost and tokens across every tab this session; a
    /// thin divider plus one line. Hidden until a tab has billed a turn.
    private var footerContainer: NSView!
    private var footerDivider: NSView!
    private var footerLabel: NSTextField!
    // Set on the main actor; invalidated in the nonisolated deinit at end-of-life.
    nonisolated(unsafe) private var refreshTimer: Timer?

    /// The approval desk's section above the agent list, supplied whole by
    /// `ProFeatures.approvalDesk`. In a free build there is no desk and this is
    /// a zero-height placeholder — the section simply does not exist.
    private var deskSection: NSView!

    private struct Row: Equatable {
        let tabIndex: Int
        let title: String
        let state: AgentState
        let since: Date
        let isActive: Bool
        /// A pane in this tab failed a command while out of view. When the tab
        /// is otherwise idle this becomes the row's headline ("Command failed");
        /// either way it joins the ⇧⌘J attention cycle.
        let hasCommandAttention: Bool
        let usage: TranscriptUsage?
        let cost: Double?
        /// Every reporting pane in the tab, each priced at its own model. Two
        /// or more billed panes render one telemetry line each, so a split
        /// running fable beside opus shows both spends instead of one.
        let paneTelemetries: [PaneTelemetry]
    }

    private var rows: [Row] = []

    /// Tag on each row's "state · elapsed" label, so the per-second tick can
    /// refresh it in place instead of reloading the table. A full reloadData
    /// rebuilds the cells and resets their tooltip tracking rects, which is why
    /// the telemetry tooltip never survived long enough to appear.
    private static let detailLabelTag = 0x5DE7A11   // "sidetail"

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = AppTheme.sidebarBackground.cgColor
    }

    private var themeObserver: ThemeObserver?

    override func viewDidLoad() {
        super.viewDidLoad()
        setupViews()
        themeObserver = ThemeObserver { [weak self] in self?.applyThemeColors() }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(agentStateChanged),
            name: .paneAgentStateChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(agentStateChanged),
            name: .paneTelemetryChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(agentStateChanged),
            name: .pendingApprovalsChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(agentStateChanged),
            name: .paneCommandAttentionChanged,
            object: nil
        )
    }

    private func applyThemeColors() {
        view.layer?.backgroundColor = AppTheme.sidebarBackground.cgColor
        scrollView?.backgroundColor = AppTheme.sidebarBackground
        tableView?.backgroundColor = AppTheme.sidebarBackground
        emptyLabel?.textColor = AppTheme.mutedText
        footerDivider?.layer?.backgroundColor = AppTheme.divider.cgColor
        footerLabel?.textColor = AppTheme.primaryText
        tableView?.reloadData()
        ProFeatures.approvalDesk?.rebuildDeskSection()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        refreshTimer?.invalidate()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
        // Tick to keep elapsed times fresh while the panel is visible.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func setupViews() {
        if let desk = ProFeatures.approvalDesk {
            deskSection = desk.makeDeskSection()
        } else {
            // No desk: a zero-height stand-in keeps the layout chain intact
            // (the list is pinned below it) while taking up nothing.
            deskSection = NSView()
            deskSection.heightAnchor.constraint(equalToConstant: 0).isActive = true
        }
        deskSection.translatesAutoresizingMaskIntoConstraints = false

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = AppTheme.sidebarBackground

        tableView = NSTableView()
        tableView.headerView = nil
        tableView.backgroundColor = AppTheme.sidebarBackground
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.usesAlternatingRowBackgroundColors = false
        if #available(macOS 12.0, *) {
            tableView.style = .plain
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("AgentColumn"))
        column.isEditable = false
        tableView.addTableColumn(column)
        scrollView.documentView = tableView

        emptyLabel = NSTextField(labelWithString: "No agent activity.\nAgent states from Claude/Codex\nsessions appear here.")
        emptyLabel.font = NSFont.systemFont(ofSize: 12)
        emptyLabel.textColor = AppTheme.mutedText
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        footerContainer = NSView()
        footerContainer.wantsLayer = true
        footerContainer.translatesAutoresizingMaskIntoConstraints = false
        footerContainer.isHidden = true

        footerDivider = NSView()
        footerDivider.wantsLayer = true
        footerDivider.layer?.backgroundColor = AppTheme.divider.cgColor
        footerDivider.translatesAutoresizingMaskIntoConstraints = false

        footerLabel = NSTextField(labelWithString: "")
        footerLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        footerLabel.textColor = AppTheme.primaryText
        footerLabel.lineBreakMode = .byTruncatingTail
        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        footerContainer.addSubview(footerDivider)
        footerContainer.addSubview(footerLabel)

        view.addSubview(deskSection)
        view.addSubview(scrollView)
        view.addSubview(emptyLabel)
        view.addSubview(footerContainer)

        NSLayoutConstraint.activate([
            deskSection.topAnchor.constraint(equalTo: view.topAnchor),
            deskSection.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            deskSection.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: deskSection.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footerContainer.topAnchor),

            footerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footerContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            footerDivider.topAnchor.constraint(equalTo: footerContainer.topAnchor),
            footerDivider.leadingAnchor.constraint(equalTo: footerContainer.leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: footerContainer.trailingAnchor),
            footerDivider.heightAnchor.constraint(equalToConstant: 1),

            footerLabel.leadingAnchor.constraint(equalTo: footerContainer.leadingAnchor, constant: 12),
            footerLabel.trailingAnchor.constraint(lessThanOrEqualTo: footerContainer.trailingAnchor, constant: -12),
            footerLabel.topAnchor.constraint(equalTo: footerDivider.bottomAnchor, constant: 7),
            footerLabel.bottomAnchor.constraint(equalTo: footerContainer.bottomAnchor, constant: -8),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 40),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 12),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12)
        ])
    }

    @objc private func agentStateChanged() {
        reload()
    }

    func reload() {
        guard isViewLoaded else { return }
        ProFeatures.approvalDesk?.refreshDeskSection()
        let tabs = delegate?.agentDashboardTabs(self) ?? []
        updateFooter(tabs)

        var newRows = tabs.enumerated().compactMap { index, tab -> Row? in
            let commandAttention = tab.hasCommandAttention
            // A tab earns a row for a live agent state OR an unacknowledged
            // failed command; the latter shows even when the agent is idle.
            guard tab.agentState != .idle || commandAttention else { return nil }
            // When the tab is otherwise idle, the failure drives the row's
            // headline and its elapsed clock; a live agent state keeps its own.
            let since = (tab.agentState == .idle ? tab.commandAttentionSince : nil) ?? tab.agentStateChangedAt
            return Row(
                tabIndex: index,
                title: tab.title,
                state: tab.agentState,
                since: since,
                isActive: tab.isActive,
                hasCommandAttention: commandAttention,
                usage: tab.telemetry,
                cost: tab.telemetryCostUSD,
                paneTelemetries: tab.paneTelemetries
            )
        }
        // Actionable tabs first: needs-input, then a failed background command,
        // then working, then done.
        newRows.sort { lhs, rhs in
            let l = Self.sortPriority(lhs), r = Self.sortPriority(rhs)
            return l == r ? lhs.tabIndex < rhs.tabIndex : l < r
        }

        // Nothing structural changed (the common per-second tick): just advance
        // the elapsed times in place. Avoiding reloadData keeps the cells — and
        // their telemetry tooltip tracking — alive long enough to show on hover.
        if newRows == rows {
            refreshElapsedInPlace()
            return
        }

        rows = newRows
        emptyLabel.isHidden = !rows.isEmpty || (ProFeatures.approvalDesk?.pendingCount ?? 0) > 0
        tableView.reloadData()
        selectActiveRow()
    }

    /// Refreshes the bottom roll-up from the current tab set, hiding it when
    /// nothing has billed yet. Called on every reload (cheap: a sum over tabs).
    /// The spend roll-up under the list. Cost reporting is Pro, so a free build
    /// has no footer at all rather than a footer showing tokens without money.
    private func updateFooter(_ tabs: [TabModel]) {
        guard let costs = ProFeatures.costReporting,
              let footer = costs.sessionFooter(TabController.costEntries(for: tabs)) else {
            footerContainer.isHidden = true
            return
        }
        footerContainer.isHidden = false
        footerLabel.stringValue = footer.line
        footerLabel.toolTip = footer.tooltip
    }

    /// Keeps the highlighted row in sync with the active tab, so cycling tabs
    /// (Ctrl+Tab) moves the selection here too — not just the standard arrow
    /// keys when the table itself is focused.
    private func selectActiveRow() {
        guard let activeRow = rows.firstIndex(where: { $0.isActive }) else {
            tableView.deselectAll(nil)
            return
        }
        if tableView.selectedRow != activeRow {
            tableView.selectRowIndexes(IndexSet(integer: activeRow), byExtendingSelection: false)
            tableView.scrollRowToVisible(activeRow)
        }
    }

    /// Updates each visible row's "state · elapsed" label from its current data,
    /// without rebuilding the cell.
    private func refreshElapsedInPlace() {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.location ..< (visible.location + visible.length) {
            guard row < rows.count,
                  let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false),
                  let detail = cell.viewWithTag(Self.detailLabelTag) as? NSTextField else { continue }
            let rowData = rows[row]
            let (stateLabel, _) = Self.rowPresentation(rowData)
            detail.stringValue = "\(stateLabel) · \(Self.elapsedString(since: rowData.since))"
        }
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0 && row < rows.count else { return }
        delegate?.agentDashboard(self, didSelectTabAt: rows[row].tabIndex)
    }

    private static func sortPriority(_ row: Row) -> Int {
        // An idle tab that's here only for a failed command sorts just under
        // needs-input; when the tab also has a live agent state, that state
        // keeps its own rank (the attention still counts for the ⇧⌘J cycle).
        if row.state == .idle && row.hasCommandAttention { return 1 }
        switch row.state {
        case .ready: return 0
        case .working: return 2
        case .done: return 3
        case .idle: return 4
        }
    }

    /// The row's headline label and color. A failed background command becomes
    /// the headline only when no live agent state would otherwise occupy it.
    private static func rowPresentation(_ row: Row) -> (label: String, color: NSColor) {
        if row.state == .idle && row.hasCommandAttention {
            return ("Command failed", AppTheme.error)
        }
        return describe(row.state)
    }

    fileprivate static func describe(_ state: AgentState) -> (label: String, color: NSColor) {
        switch state {
        case .working: return ("Working", AppTheme.warning)
        case .ready: return ("Needs input", AppTheme.success)
        case .done: return ("Done", AppTheme.accent)
        case .idle: return ("Idle", AppTheme.mutedText)
        }
    }

    fileprivate static func elapsedString(since date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }

    // MARK: - Telemetry formatting

    /// Compact one-line telemetry for a row: `opus-4.8 · $0.36 · 7t`. Turns are
    /// dropped when unavailable, and the `$` only appears in a Pro build — free
    /// keeps the model and the turn count, which is telemetry, not spend.
    /// Returns nil when there's nothing billed yet to show.
    static func telemetryLine(_ usage: TranscriptUsage, cost: Double?) -> String? {
        guard usage.assistantResponses > 0 else { return nil }
        var parts: [String] = []
        if let model = usage.model { parts.append(TelemetryFormat.shortModel(model)) }
        if let costText = ProFeatures.costReporting?.rowCostText(cost) { parts.append(costText) }
        if usage.userPrompts > 0 { parts.append("\(usage.userPrompts)t") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The telemetry lines a row renders. Two or more billed panes get one
    /// line each (a split tab can run different models side by side); otherwise
    /// the tab's primary usage keeps its single line.
    private static func telemetryLines(for row: Row) -> [(line: String, tooltip: String)] {
        let billed = row.paneTelemetries.filter { $0.usage.assistantResponses > 0 }
        if billed.count >= 2 {
            return billed.compactMap { pane in
                telemetryLine(pane.usage, cost: pane.costUSD).map { ($0, telemetryTooltip(pane.usage)) }
            }
        }
        guard let usage = row.usage, let line = telemetryLine(usage, cost: row.cost) else { return [] }
        return [(line, telemetryTooltip(usage))]
    }

    /// Full breakdown for the row tooltip.
    fileprivate static func telemetryTooltip(_ usage: TranscriptUsage) -> String {
        var lines = ["in \(TelemetryFormat.compactTokens(usage.totalInputTokens)) · out \(TelemetryFormat.compactTokens(usage.outputTokens))"]
        if usage.cacheReadTokens > 0 { lines.append("cache read \(TelemetryFormat.compactTokens(usage.cacheReadTokens))") }
        lines.append("\(usage.assistantResponses) responses · \(usage.userPrompts) prompts")
        return lines.joined(separator: "\n")
    }
}

extension AgentDashboardViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }
}

extension AgentDashboardViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let rowData = rows[row]
        let (stateLabel, stateColor) = Self.rowPresentation(rowData)

        let cell = NSTableCellView()
        cell.wantsLayer = true

        if rowData.isActive {
            cell.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.04).cgColor

            let accent = NSView()
            accent.wantsLayer = true
            accent.layer?.backgroundColor = stateColor.withAlphaComponent(0.7).cgColor
            accent.layer?.cornerRadius = 1
            accent.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(accent)
            NSLayoutConstraint.activate([
                accent.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                accent.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6),
                accent.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -6),
                accent.widthAnchor.constraint(equalToConstant: 2)
            ])
        }

        let dot = NSTextField(labelWithString: "●")
        dot.font = NSFont.systemFont(ofSize: 10)
        dot.textColor = stateColor
        dot.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: rowData.title)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = AppTheme.primaryText
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let detailLabel = NSTextField(
            labelWithString: "\(stateLabel) · \(Self.elapsedString(since: rowData.since))"
        )
        detailLabel.font = NSFont.systemFont(ofSize: 11)
        detailLabel.textColor = stateColor
        detailLabel.tag = Self.detailLabelTag
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(dot)
        cell.addSubview(titleLabel)
        cell.addSubview(detailLabel)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            dot.topAnchor.constraint(equalTo: cell.topAnchor, constant: 7),

            titleLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 7),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: cell.topAnchor, constant: 5),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8)
        ])

        // Telemetry lines (model · est$ · turns) — one per billed pane when the
        // tab is split across agents — each with its full breakdown on hover.
        var lastBottom: NSLayoutYAxisAnchor = detailLabel.bottomAnchor
        for entry in Self.telemetryLines(for: rowData) {
            let telemetryLabel = NSTextField(labelWithString: entry.line)
            telemetryLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
            telemetryLabel.textColor = AppTheme.mutedText
            telemetryLabel.lineBreakMode = .byTruncatingTail
            telemetryLabel.toolTip = entry.tooltip
            telemetryLabel.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(telemetryLabel)
            NSLayoutConstraint.activate([
                telemetryLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                telemetryLabel.topAnchor.constraint(equalTo: lastBottom, constant: 2),
                telemetryLabel.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8)
            ])
            lastBottom = telemetryLabel.bottomAnchor
        }

        // Context-window bar: fills left→right with the share of the model's
        // context window the latest turn occupies. Only shown once a turn has
        // been billed (fraction != nil).
        if let usage = rowData.usage, let fraction = usage.contextFraction() {
            let bar = Self.makeContextBar(fraction: fraction)
            bar.toolTip = Self.contextTooltip(usage)
            cell.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
                bar.topAnchor.constraint(equalTo: lastBottom, constant: 5)
            ])
        }

        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return 42 }
        let rowData = rows[row]
        var height: CGFloat = 42 + CGFloat(Self.telemetryLines(for: rowData).count) * 16
        if rowData.usage?.contextFraction() != nil { height += 9 }
        return height
    }

    // MARK: - Context bar

    /// A thin two-layer bar (muted track + colored fill) whose fill spans
    /// `fraction` of the width. Color shifts green→yellow→red as it fills.
    private static func makeContextBar(fraction: Double) -> NSView {
        let track = NSView()
        track.wantsLayer = true
        track.layer?.backgroundColor = AppTheme.divider.withAlphaComponent(0.6).cgColor
        track.layer?.cornerRadius = 2

        let fill = NSView()
        fill.wantsLayer = true
        fill.layer?.backgroundColor = contextBarColor(fraction).cgColor
        fill.layer?.cornerRadius = 2
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)
        track.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            track.heightAnchor.constraint(equalToConstant: 4),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            // A near-empty window still shows a sliver so the bar reads as a bar.
            fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: CGFloat(max(0.02, fraction)))
        ])
        return track
    }

    private static func contextBarColor(_ fraction: Double) -> NSColor {
        switch fraction {
        case ..<0.6: return AppTheme.success
        case ..<0.85: return AppTheme.warning
        default: return AppTheme.error
        }
    }

    /// Hover text for the context bar, e.g. `context 82k / 200k (41%)`.
    private static func contextTooltip(_ usage: TranscriptUsage) -> String {
        guard let fraction = usage.contextFraction() else { return "" }
        let window = ContextWindow.tokens(forModel: usage.model, occupancy: usage.contextTokens)
        let percent = Int((fraction * 100).rounded())
        return "context \(TelemetryFormat.compactTokens(usage.contextTokens)) / \(TelemetryFormat.compactTokens(window)) (\(percent)%)"
    }
}
