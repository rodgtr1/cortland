import Cocoa

/// Agent a new worktree can be launched with from the create sheet. `argv` is
/// the command typed into the new pane, or nil for a plain terminal.
enum WorktreeAgent: String, CaseIterable {
    case none = "None"
    case claude = "Claude"
    case codex = "Codex"
    case pi = "Pi"

    var argv: [String]? {
        switch self {
        case .none: return nil
        case .claude: return ["claude"]
        case .codex: return ["codex"]
        case .pi: return ["pi"]
        }
    }
}

protocol WorktreesPanelDelegate: AnyObject {
    /// Repository root for the active tab's pane, or nil when it isn't in a git
    /// repo (drives the "No repository" empty state).
    func worktreesPanelActiveRepoRoot(_ panel: WorktreesPanelViewController) -> String?
    /// All tabs, for mapping each worktree to a pane and its agent state.
    func worktreesPanelTabs(_ panel: WorktreesPanelViewController) -> [TabModel]
    /// Open or focus a pane sitting in `path` (or open a new terminal there).
    func worktreesPanel(_ panel: WorktreesPanelViewController, didRequestOpenWorktree path: String)
    /// Open the uncommitted-changes view for the worktree at `path`.
    func worktreesPanel(_ panel: WorktreesPanelViewController, didRequestDiffForWorktree path: String)
    /// Create a worktree for `branch`, optionally launching `agent` in its pane.
    func worktreesPanel(_ panel: WorktreesPanelViewController, didRequestCreateBranch branch: String, agent: WorktreeAgent)
    /// Remove the worktree registered for `branch`; `force` overrides the
    /// dirty/locked guard. The panel has already confirmed with the user.
    func worktreesPanel(_ panel: WorktreesPanelViewController, didRequestRemoveBranch branch: String, force: Bool)
    /// Merge `branch`'s worktree into the primary checkout. The panel has already
    /// confirmed with the user; the dirty/conflict guards live in the service.
    func worktreesPanel(_ panel: WorktreesPanelViewController, didRequestMergeBranch branch: String)
    /// A worktree row was selected (single click): point the git panel at that
    /// checkout so flipping to the Git panel shows its status + vs-main changes.
    func worktreesPanel(_ panel: WorktreesPanelViewController, didSelectWorktree path: String)
}

/// Sidebar panel listing the active repo's git worktrees — the human cockpit
/// over `WorktreeService`. Shows each checkout's branch, agent state (from a
/// pane sitting in it), and dirty/conflicted summary, and offers open/focus,
/// diff, create, and guarded remove. Data is discovered live from git each
/// refresh (no store); git always runs off the main thread, and the panel
/// refreshes on demand rather than polling.
final class WorktreesPanelViewController: NSViewController {
    weak var delegate: WorktreesPanelDelegate?

    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var emptyLabel: NSTextField!
    private var themeObserver: ThemeObserver?

    /// Coalesces refresh bursts (e.g. a flurry of editor saves) into one git pass.
    private var pendingReload: DispatchWorkItem?
    /// Monotonic token so a slow background load can't overwrite a newer one.
    private var loadGeneration = 0

    nonisolated private struct Row: Equatable, Sendable {
        let branch: String?
        let path: String
        let agentState: AgentState?
        let summary: WorktreeStatusSummary
        let hasPane: Bool
        let isPrimary: Bool

        var displayName: String { branch ?? URL(fileURLWithPath: path).lastPathComponent }
    }
    private var rows: [Row] = []

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = AppTheme.sidebarBackground.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupViews()
        themeObserver = ThemeObserver { [weak self] in self?.applyThemeColors() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(scheduleReload), name: .paneAgentStateChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(scheduleReload), name: .editorModifiedStateChanged, object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    // MARK: - Layout

    private func setupViews() {
        let toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let createButton = makeToolbarButton(symbol: "plus", tooltip: "New worktree…", action: #selector(createClicked))
        let refreshButton = makeToolbarButton(symbol: "arrow.clockwise", tooltip: "Refresh", action: #selector(refreshClicked))
        toolbar.addSubview(createButton)
        toolbar.addSubview(refreshButton)

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
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.menu = makeContextMenu()
        if #available(macOS 12.0, *) { tableView.style = .plain }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("WorktreeColumn"))
        column.isEditable = false
        tableView.addTableColumn(column)
        scrollView.documentView = tableView

        emptyLabel = NSTextField(labelWithString: "No repository.\nOpen a pane inside a git repo\nto see its worktrees.")
        emptyLabel.font = NSFont.systemFont(ofSize: 12)
        emptyLabel.textColor = AppTheme.mutedText
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(toolbar)
        view.addSubview(scrollView)
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 30),
            refreshButton.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -8),
            refreshButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            createButton.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -6),
            createButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 50),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 12),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12)
        ])
    }

    private func makeToolbarButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.contentTintColor = AppTheme.mutedText
        button.toolTip = tooltip
        button.target = self
        button.action = action
        return button
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    private func applyThemeColors() {
        view.layer?.backgroundColor = AppTheme.sidebarBackground.cgColor
        scrollView?.backgroundColor = AppTheme.sidebarBackground
        tableView?.backgroundColor = AppTheme.sidebarBackground
        emptyLabel?.textColor = AppTheme.mutedText
        tableView?.reloadData()
    }

    // MARK: - Refresh

    /// Debounced refresh for notification storms (editor-save bursts, rapid
    /// agent-state flips). Panel-show and explicit actions call `reload()`.
    @objc private func scheduleReload() {
        // Skip notification-driven refreshes while the panel isn't on screen —
        // otherwise an agent-state/editor-save storm forks `git status` per
        // worktree for a panel nobody is looking at. The container calls reload()
        // when this panel is (re)selected (and viewWillAppear does too), so it
        // never shows stale on return. Non-selected panels are removed from the
        // view hierarchy, so window == nil; a collapsed sidebar is a hidden ancestor.
        guard view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return }
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Loads worktrees + status off the main thread, then applies on main —
    /// reloading the table only when the rows actually changed, so a refresh
    /// that finds nothing new doesn't churn the view.
    func reload() {
        guard isViewLoaded else { return }
        pendingReload?.cancel()

        guard let repoRoot = delegate?.worktreesPanelActiveRepoRoot(self) else {
            rows = []
            emptyLabel.isHidden = false
            tableView.reloadData()
            return
        }

        // Snapshot pane cwds + agent states on the main thread; git runs off it.
        let paneInfo = paneCwdStates()
        loadGeneration += 1
        let generation = loadGeneration

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let service = WorktreeService()
            let git = GitService()
            let worktrees = (try? service.listWorktrees(repoRoot: repoRoot)) ?? []
            let newRows: [Row] = worktrees.map { wt in
                let summary = (try? git.statusSummary(repositoryRoot: wt.path)) ?? .empty
                let paneState = Self.paneState(for: wt.path, in: paneInfo)
                return Row(
                    branch: wt.branch,
                    path: wt.path,
                    agentState: paneState,
                    summary: summary,
                    hasPane: paneState != nil,
                    isPrimary: Self.samePath(wt.path, repoRoot)
                )
            }.sorted(by: Self.order)

            DispatchQueue.main.async {
                guard let self, self.loadGeneration == generation else { return }
                self.emptyLabel.isHidden = true
                guard newRows != self.rows else { return }   // no-op refresh: don't churn
                self.rows = newRows
                self.tableView.reloadData()
            }
        }
    }

    /// (cwd, agentState) for every terminal pane across all tabs, snapshotted on
    /// the main thread for the background mapping pass.
    private func paneCwdStates() -> [(cwd: String, state: AgentState)] {
        let tabs = delegate?.worktreesPanelTabs(self) ?? []
        return tabs.flatMap { tab in
            tab.panes.compactMap { pane -> (String, AgentState)? in
                guard let cwd = pane.resolvedWorkingDirectory() else { return nil }
                return (cwd, pane.agentState)
            }
        }
    }

    /// The agent state of a pane sitting in `worktreePath` (exact match or
    /// inside it), or nil when no pane is there. Prefers a higher-priority
    /// (more actionable) state so a working agent wins over an idle shell in the
    /// same tree.
    // Pure ordering/path helpers below run inside the background worktree-listing
    // pass, so they opt out of the view controller's main-actor isolation.
    nonisolated private static func paneState(
        for worktreePath: String,
        in panes: [(cwd: String, state: AgentState)]
    ) -> AgentState? {
        panes
            .filter { samePath($0.cwd, worktreePath) || isInside($0.cwd, worktreePath) }
            .map(\.state)
            .min { sortPriority($0) < sortPriority($1) }
    }

    // MARK: - Ordering

    /// Actionable first: needs-input, working, done; then dirty over clean;
    /// the primary checkout always sinks to the bottom.
    nonisolated private static func order(_ lhs: Row, _ rhs: Row) -> Bool {
        if lhs.isPrimary != rhs.isPrimary { return !lhs.isPrimary }
        let lp = rowPriority(lhs), rp = rowPriority(rhs)
        if lp != rp { return lp < rp }
        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }

    nonisolated private static func rowPriority(_ row: Row) -> Int {
        if let state = row.agentState, state != .idle { return sortPriority(state) }
        return row.summary.clean ? 5 : 4   // dirty above clean, both below active agents
    }

    nonisolated private static func sortPriority(_ state: AgentState) -> Int {
        switch state {
        case .ready: return 0
        case .working: return 1
        case .done: return 2
        case .idle: return 3
        }
    }

    // MARK: - Path helpers

    nonisolated private static func samePath(_ a: String, _ b: String) -> Bool {
        standardized(a) == standardized(b)
    }

    nonisolated private static func isInside(_ child: String, _ parent: String) -> Bool {
        let p = standardized(parent)
        return standardized(child).hasPrefix(p.hasSuffix("/") ? p : p + "/")
    }

    nonisolated private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    // MARK: - Actions

    @objc private func refreshClicked() { reload() }

    @objc private func createClicked() { presentCreateSheet() }

    @objc private func rowDoubleClicked() {
        guard let row = rows[safe: tableView.clickedRow] else { return }
        delegate?.worktreesPanel(self, didRequestOpenWorktree: row.path)
    }

    private func openSelected() {
        guard let row = rows[safe: tableView.clickedRow] else { return }
        delegate?.worktreesPanel(self, didRequestOpenWorktree: row.path)
    }

    private func diffSelected() {
        guard let row = rows[safe: tableView.clickedRow] else { return }
        delegate?.worktreesPanel(self, didRequestDiffForWorktree: row.path)
    }

    private func removeSelected() {
        guard let row = rows[safe: tableView.clickedRow] else { return }
        presentRemoveDialog(for: row)
    }

    private func mergeSelected() {
        guard let row = rows[safe: tableView.clickedRow], let branch = row.branch,
              let primaryBranch = primaryBranchName else { return }
        presentMergeDialog(branch: branch, into: primaryBranch)
    }

    /// The primary checkout's branch — the merge target — from the current rows.
    private var primaryBranchName: String? {
        rows.first(where: { $0.isPrimary })?.branch
    }

    // MARK: - Create / remove dialogs

    private func presentCreateSheet() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "New Worktree"
        alert.informativeText = "Create a git worktree on a new or existing branch, optionally launching an agent in it."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        field.placeholderString = "branch name (e.g. feature/x)"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        popup.addItems(withTitles: WorktreeAgent.allCases.map(\.rawValue))

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 62))
        accessory.addSubview(field)
        accessory.addSubview(popup)
        alert.accessoryView = accessory

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let branch = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !branch.isEmpty else { return }
            let agent = WorktreeAgent(rawValue: popup.titleOfSelectedItem ?? "None") ?? .none
            self.delegate?.worktreesPanel(self, didRequestCreateBranch: branch, agent: agent)
        }
    }

    private func presentRemoveDialog(for row: Row) {
        guard let window = view.window, let branch = row.branch else { return }
        let alert = NSAlert()
        alert.messageText = "Remove Worktree?"
        alert.informativeText = Self.removeMessage(for: row)
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open Diff")
        let removeButton = alert.addButton(withTitle: "Remove Anyway")
        removeButton.hasDestructiveAction = true

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertSecondButtonReturn:   // Open Diff
                self.delegate?.worktreesPanel(self, didRequestDiffForWorktree: row.path)
            case .alertThirdButtonReturn:    // Remove Anyway
                self.delegate?.worktreesPanel(self, didRequestRemoveBranch: branch, force: true)
            default:
                break
            }
        }
    }

    private func presentMergeDialog(branch: String, into primaryBranch: String) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Merge '\(branch)' into '\(primaryBranch)'?"
        alert.informativeText = "This runs `git merge \(branch)` in the primary checkout. It's refused if '\(primaryBranch)' has uncommitted changes, and aborted (leaving '\(primaryBranch)' clean) if the merge conflicts."
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.delegate?.worktreesPanel(self, didRequestMergeBranch: branch)
        }
    }

    private static func removeMessage(for row: Row) -> String {
        var clauses: [String] = []
        if row.summary.changed > 0 { clauses.append("\(row.summary.changed) changed file\(row.summary.changed == 1 ? "" : "s")") }
        if row.summary.conflicted > 0 { clauses.append("\(row.summary.conflicted) conflicted") }
        if row.hasPane { clauses.append("an active agent pane") }
        let name = row.branch ?? URL(fileURLWithPath: row.path).lastPathComponent
        if clauses.isEmpty {
            return "\(name) is clean. Remove its worktree?"
        }
        return "\(name) has \(Self.joinClauses(clauses)). Removing it may delete local work."
    }

    private static func joinClauses(_ parts: [String]) -> String {
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        case 2: return "\(parts[0]) and \(parts[1])"
        default: return parts.dropLast().joined(separator: ", ") + ", and " + parts.last!
        }
    }
}

// MARK: - Table data source / delegate

extension WorktreesPanelViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
}

extension WorktreesPanelViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let rowData = rows[safe: row] else { return nil }
        let (stateText, stateColor) = Self.describe(rowData)

        let cell = NSTableCellView()
        cell.wantsLayer = true

        let dot = NSTextField(labelWithString: "●")
        dot.font = NSFont.systemFont(ofSize: 9)
        dot.textColor = stateColor
        dot.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: rowData.displayName)
        title.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        title.textColor = rowData.isPrimary ? AppTheme.mutedText : AppTheme.primaryText
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false

        let detail = NSTextField(labelWithString: stateText)
        detail.font = NSFont.systemFont(ofSize: 11)
        detail.textColor = stateColor
        detail.lineBreakMode = .byTruncatingTail
        detail.translatesAutoresizingMaskIntoConstraints = false

        let pathLabel = NSTextField(labelWithString: Self.pathDisplay(rowData))
        pathLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        pathLabel.textColor = AppTheme.mutedText
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(dot)
        cell.addSubview(title)
        cell.addSubview(detail)
        cell.addSubview(pathLabel)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            dot.topAnchor.constraint(equalTo: cell.topAnchor, constant: 8),

            title.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            title.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6),

            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),

            pathLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            pathLabel.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 2),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8)
        ])
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 58 }

    /// Single-click selection points the git panel at the selected checkout.
    /// Guarded on a valid row so a `reloadData`-driven deselection (selectedRow
    /// == -1) doesn't fire. Double-click still opens the tab as before — its
    /// first click retargets here, which is harmless.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let row = rows[safe: tableView.selectedRow] else { return }
        delegate?.worktreesPanel(self, didSelectWorktree: row.path)
    }

    /// Dot + line-two text and color for a row, blending agent state with dirty.
    private static func describe(_ row: Row) -> (text: String, color: NSColor) {
        let summary = row.summary
        let dirty: String
        if summary.clean {
            dirty = "clean"
        } else {
            var parts: [String] = []
            if summary.changed > 0 { parts.append("\(summary.changed) changed") }
            if summary.conflicted > 0 { parts.append("\(summary.conflicted) conflicted") }
            dirty = parts.joined(separator: ", ")
        }

        let presence = row.hasPane ? "" : "No pane · "
        if let state = row.agentState, state != .idle {
            let (label, color) = stateAppearance(state)
            return ("\(label) · \(dirty)", color)
        }
        // No active agent: lead with pane presence, color by dirtiness.
        let color: NSColor = summary.conflicted > 0 ? AppTheme.error
            : (summary.clean ? AppTheme.mutedText : AppTheme.warning)
        return ("\(presence)\(dirty)", color)
    }

    private static func stateAppearance(_ state: AgentState) -> (String, NSColor) {
        switch state {
        case .working: return ("Working", AppTheme.warning)
        case .ready: return ("Needs input", AppTheme.success)
        case .done: return ("Done", AppTheme.accent)
        case .idle: return ("Idle", AppTheme.mutedText)
        }
    }

    private static func pathDisplay(_ row: Row) -> String {
        if row.isPrimary { return URL(fileURLWithPath: row.path).lastPathComponent + "  (primary)" }
        // Show the "<repo>.worktrees/<branch>" tail when present, else basename.
        let url = URL(fileURLWithPath: row.path)
        let parent = url.deletingLastPathComponent().lastPathComponent
        return parent.hasSuffix(".worktrees") ? "\(parent)/\(url.lastPathComponent)" : url.lastPathComponent
    }
}

// MARK: - Context menu

extension WorktreesPanelViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let row = rows[safe: tableView.clickedRow] else { return }
        menu.addItem(withTitle: row.hasPane ? "Focus Pane" : "Open Terminal", action: #selector(menuOpen), keyEquivalent: "")
        menu.addItem(withTitle: "Open Diff", action: #selector(menuDiff), keyEquivalent: "")
        // Merge a non-primary worktree's branch into the primary checkout's
        // branch. Only when both branches are known (the target comes from the
        // primary row's checked-out branch).
        if !row.isPrimary, row.branch != nil, let primaryBranch = primaryBranchName {
            menu.addItem(withTitle: "Merge into \(primaryBranch)…", action: #selector(menuMerge), keyEquivalent: "")
        }
        if !row.isPrimary {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Remove Worktree…", action: #selector(menuRemove), keyEquivalent: "")
        }
        menu.items.forEach { $0.target = self }
    }

    @objc private func menuOpen() { openSelected() }
    @objc private func menuDiff() { diffSelected() }
    @objc private func menuMerge() { mergeSelected() }
    @objc private func menuRemove() { removeSelected() }
}
