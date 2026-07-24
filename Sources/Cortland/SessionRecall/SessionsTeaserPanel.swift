import Cocoa
import CortlandProInterface

/// ⌃⇧S Session Recall, free tier: the ten most recent Claude/Codex sessions,
/// newest first, as title + "agent · repo · age" rows, with the true total
/// underneath.
///
/// Read-only on purpose. There is no search field, no ⌘↩ preview, and selecting
/// a row does nothing — searching, previewing and resuming are what the Pro
/// panel adds (`ProFeatures.recall`). It shares the scan, cache, dedupe and
/// launch-ledger backfill with that panel rather than parsing logs its own way,
/// so both show the same sessions with the same titles.
final class SessionsTeaserPanel: NSPanel {
    /// The teaser's whole shape. The full panel shows 50 and narrows by typing.
    static let displayLimit = 10

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let footerLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = AppTheme.mutedText
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private var rows: [SessionRecord] = []
    /// Every session found on the last refresh, so the footer can report the
    /// real number rather than the number of rows on screen.
    private var totalCount = 0

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 360),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        title = "Sessions"
        level = .floating
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = true
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        center()
        setupUI()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private func setupUI() {
        guard let contentView else { return }

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = AppTheme.windowBackground.cgColor
        container.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(container)

        let heading = NSTextField(labelWithString: "Recent sessions")
        heading.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        heading.textColor = AppTheme.primaryText
        heading.translatesAutoresizingMaskIntoConstraints = false

        tableView.headerView = nil
        tableView.rowSizeStyle = .medium
        tableView.backgroundColor = .clear
        if #available(macOS 12.0, *) {
            tableView.style = .sourceList
        } else {
            tableView.selectionHighlightStyle = .sourceList
        }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SessionRecord"))
        column.width = 580
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.backgroundColor = .clear
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        footerLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(heading)
        container.addSubview(scrollView)
        container.addSubview(footerLabel)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: contentView.topAnchor),
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            heading.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            heading.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),

            scrollView.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            footerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            footerLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            footerLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: footerLabel.topAnchor, constant: -8)
        ])
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            close()
            return
        }
        super.keyDown(with: event)
    }

    func show(relativeTo parentWindow: NSWindow) {
        let parentFrame = parentWindow.frame
        setFrameOrigin(NSPoint(
            x: parentFrame.midX - frame.width / 2,
            y: parentFrame.midY + 80
        ))
        makeKeyAndOrderFront(nil)
        loadSessions()
    }

    /// Refresh off the main thread (the module is `@MainActor` by default, but
    /// the cache/parse/query types are `nonisolated`/`Sendable`) and apply on
    /// main — the same shape as the Pro panel's load.
    private func loadSessions() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claudeRoot = home.appendingPathComponent(".claude/projects")
        let codexRoot = home.appendingPathComponent(".codex/sessions")
        let cacheURL = SessionRecallCache.defaultCacheURL()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let records = SessionRecallCache.refresh(
                claudeProjectsRoot: claudeRoot,
                codexSessionsRoot: codexRoot,
                cacheURL: cacheURL
            )
            let ledger = SessionLaunchLedger.entries()
            let backfilled = SessionLaunchLedger.backfillCWDs(records, using: ledger)
            let deduped = SessionQuery.dedupeSessions(backfilled)
            let ordered = SessionQuery.run(deduped)
            DispatchQueue.main.async {
                guard let self else { return }
                self.totalCount = ordered.count
                self.rows = Array(ordered.prefix(Self.displayLimit))
                self.tableView.reloadData()
                self.updateFooter()
            }
        }
    }

    /// The visible "there's more than what you see" marker. Reports the real
    /// total, not the row count, so the ten on screen read as a window onto the
    /// whole history.
    private func updateFooter() {
        footerLabel.stringValue = Self.footerText(shown: rows.count, total: totalCount)
    }

    /// Internal (not private) so the free-tier behavior is unit-testable.
    static func footerText(shown: Int, total: Int) -> String {
        if total == 0 { return "no sessions found" }
        if shown < total { return "\(shown) of \(total) sessions" }
        return total == 1 ? "1 session" : "\(total) sessions"
    }
}

extension SessionsTeaserPanel: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
}

extension SessionsTeaserPanel: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let cell = SessionRowCellView()
        cell.configure(with: rows[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 46 }

    /// Rows are informational here — resuming is the Pro panel's job — so the
    /// list never takes a selection rather than highlighting a row that does
    /// nothing when you press Return.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}
