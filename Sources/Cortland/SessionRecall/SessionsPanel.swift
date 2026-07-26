import Cocoa

protocol SessionsPanelDelegate: AnyObject {
    /// The user chose a past session to resume (Return or double-click).
    func sessionsPanel(_ panel: SessionsPanel, didSelect record: SessionRecord)
}

/// ⌃⇧S Session Recall: lists past Claude/Codex sessions newest-first,
/// filters as you type (with an All/Claude/Codex agent filter, ⌘1-⌘3), and on
/// Enter resumes the selected one in a new tab.
/// The panel chrome (search field, table, key handling) lives in
/// `FilterableListPanel`; this subclass supplies the records and the async
/// cache load. Data (parse/cache/query) lives in the rest of `SessionRecall/`.
final class SessionsPanel: FilterableListPanel {
    weak var sessionsDelegate: SessionsPanelDelegate?

    /// Every record from the last cache refresh, unfiltered.
    private var all: [SessionRecord] = []
    /// The records currently shown, after applying the search query.
    private var filtered: [SessionRecord] = []
    /// The query in effect, re-applied when a background refresh lands.
    private var currentQuery: String = ""
    /// Cap the rows shown. The list is sorted newest-first, so this surfaces the
    /// most recent sessions by default; typing narrows across all of them. Keeps
    /// the panel a quick pick instead of an endless scroll.
    private let displayLimit = 50

    /// The read-only transcript preview (⌘↩). Owned/retained here and reused, so
    /// previewing many sessions never spawns a second window. Built lazily on
    /// first preview.
    private lazy var previewPanel = SessionPreviewPanel()

    // MARK: - Codex titling (background, local Ollama)

    /// Generates one-line titles for Codex sessions (which have no `aiTitle`).
    private let titler = SessionTitler()
    /// Serializes title generation to one Ollama call at a time — the model is
    /// several GB, so overlapping calls would thrash. Low priority: titling is a
    /// background nicety, never on the critical path.
    private let titlingQueue = DispatchQueue(label: "app.cortland.session-recall.titling", qos: .utility)
    /// Log paths already handed to the titler this app run, whether they
    /// succeeded or failed. Prevents re-attempting a session that produced no
    /// usable title (ollama down, garbage output) on every subsequent refresh.
    private var attemptedTitlePaths: Set<String> = []

    // MARK: - Deep search (opt-in, in-memory)

    /// When ON, the query matches text INSIDE transcript bodies, not just the
    /// title. Toggled by `deepToggle`.
    private var deepMode = false
    /// The in-memory body-text index, built off-main on first deep use and held
    /// only while the panel lives. Nil until loaded (or after `all` changes and
    /// it must be rebuilt); nothing is ever written to disk.
    private var deepIndex: SessionDeepSearch.Index?
    /// True while a background index build is in flight, so it isn't kicked off
    /// twice.
    private var deepLoading = false
    /// Bumped whenever the index is invalidated (records refreshed, panel
    /// closed). A build captures this before dispatching and only installs its
    /// result if the value still matches on completion — otherwise the build ran
    /// against stale records and is discarded. Prevents an in-flight build from
    /// silently overwriting a fresher record set with an old index.
    private var deepGeneration = 0
    /// Bumped on every deep query. A search captures it before going off-main
    /// and its results are dropped unless it still matches, so a slow search for
    /// "np" can never land on top of the results for "npm install".
    private var deepSearchGeneration = 0
    /// The scheduled (debounced) deep search, cancelled by the next keystroke.
    private var deepSearchWorkItem: DispatchWorkItem?
    /// How long typing has to pause before a deep query runs. Deep search walks
    /// every indexed transcript's text, which is far too much to redo per
    /// keystroke; the shallow filter stays immediate.
    private static let deepSearchDebounce: TimeInterval = 0.2
    /// Match snippets for the currently shown rows, keyed by log path, shown in
    /// the subtitle position instead of "agent · repo · age".
    private var snippets: [String: String] = [:]
    /// The "Deep" toggle at the trailing edge of the search-field row.
    private lazy var deepToggle: NSButton = {
        let button = NSButton(checkboxWithTitle: "Deep", target: self, action: #selector(deepToggled(_:)))
        button.toolTip = "Search inside transcript bodies (in-memory, not saved)"
        button.font = NSFont.systemFont(ofSize: 12)
        return button
    }()

    // MARK: - Agent filter (All / Claude / Codex)

    /// When set, only this agent's sessions are shown; nil shows every agent.
    /// Applied before the text query in both shallow and deep mode.
    private var agentFilter: SessionAgent?
    /// The segment order mirrored by ⌘1/⌘2/⌘3. Index 0 is "All" (nil filter).
    private static let agentSegments: [SessionAgent?] = [nil, .claude, .codex]
    /// The "All | Claude | Codex" control beside the Deep toggle.
    private lazy var agentControl: NSSegmentedControl = {
        let control = NSSegmentedControl(
            labels: ["All", "Claude", "Codex"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(agentFilterChanged(_:))
        )
        control.controlSize = .small
        control.selectedSegment = 0
        control.toolTip = "Filter by agent (⌘1 all, ⌘2 claude, ⌘3 codex)"
        return control
    }()
    /// Footer status line ("50 of 334 · keep typing to narrow"). The window
    /// title can't carry this — the panel hides its title bar — so it lives
    /// visibly under the list instead.
    private let footerLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = AppTheme.mutedText
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    init() {
        super.init(chrome: Chrome(
            title: "Sessions",
            placeholder: "Search past sessions…    ⌘↩ to preview",
            size: NSSize(width: 620, height: 420),
            columnIdentifier: "SessionRecord",
            hidesOnDeactivate: true,
            // Two-line rows (title + "agent · repo · age") need more than the
            // single-line default, or the subtitle clips into the next row.
            rowHeight: 46
        ))
        // One accessory slot: stack the agent filter and the Deep toggle.
        let accessories = NSStackView(views: [agentControl, deepToggle])
        accessories.orientation = .horizontal
        accessories.spacing = 10
        installHeaderAccessory(accessories)
        installFooter(footerLabel)
    }

    // MARK: - FilterableListPanel hooks

    override var itemCount: Int { filtered.count }

    override func cellView(forRow row: Int) -> NSView? {
        let cell = SessionRowCellView()
        let record = filtered[row]
        cell.configure(with: record, snippet: snippets[record.logPath])
        return cell
    }

    override func queryChanged(_ query: String) {
        currentQuery = query
        applyFilter()
        reloadAndSelectFirst()
    }

    override func activateRow(_ row: Int) {
        let record = filtered[row]
        close()
        sessionsDelegate?.sessionsPanel(self, didSelect: record)
    }

    /// ⌘↩ previews the selected session read-only instead of resuming it. A
    /// command-key equivalent reaches the panel here even while the search
    /// field's field editor holds focus — plain Return does not; it goes via the
    /// `SearchFieldDelegate` and still resumes (`activateRow`), unchanged. The
    /// sessions panel stays open so the user can keep browsing/previewing.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.keyCode == 36 { // Return
            previewSelectedRow()
            return true
        }
        // ⌘1/⌘2/⌘3 pick the agent filter segment (All / Claude / Codex).
        if event.modifierFlags.contains(.command),
           let digit = event.charactersIgnoringModifiers.flatMap(Int.init),
           (1...Self.agentSegments.count).contains(digit) {
            selectAgentSegment(digit - 1)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func previewSelectedRow() {
        let row = tableView.selectedRow
        guard row >= 0, row < filtered.count else { return }
        previewPanel.show(record: filtered[row])
    }

    private func applyFilter() {
        if deepMode {
            applyDeepFilter()
        } else {
            applyShallowFilter()
        }
    }

    /// Title/metadata filter via `SessionQuery`, with one refinement over the
    /// raw query: sessions whose *title/aiTitle* contain the phrase rank above
    /// sessions that only matched via their cwd/repo path (typing "mac" matches
    /// everything under cortland-term-mac; those shouldn't bury actual title
    /// hits). Newest-first is preserved within each group.
    private func applyShallowFilter() {
        // Turning Deep off mid-search must not let that search land on top of
        // the shallow rows a moment later.
        deepSearchWorkItem?.cancel()
        deepSearchGeneration += 1
        snippets = [:]
        let matches = SessionQuery.run(all, agent: agentFilter, search: currentQuery.isEmpty ? nil : currentQuery)
        if currentQuery.isEmpty {
            filtered = Array(matches.prefix(displayLimit))
        } else {
            let needle = currentQuery.lowercased()
            let titleHits = matches.filter {
                $0.title.lowercased().contains(needle) || $0.aiTitle?.lowercased().contains(needle) == true
            }
            let pathOnly = matches.filter { record in !titleHits.contains(where: { $0.logPath == record.logPath }) }
            filtered = Array((titleHits + pathOnly).prefix(displayLimit))
        }
        updateFooter(shown: filtered.count, total: matches.count)
    }

    /// The visible "there's more than what you see" marker.
    private func updateFooter(shown: Int, total: Int, note: String? = nil) {
        if let note {
            footerLabel.stringValue = note
        } else if shown < total {
            footerLabel.stringValue = "\(shown) of \(total) · keep typing to narrow"
        } else {
            footerLabel.stringValue = total == 0 ? "no matches" : ""
        }
    }

    /// Match against transcript bodies using the in-memory deep index. Until the
    /// index has loaded, show the shallow results so the panel stays responsive
    /// and refresh once the (off-main) load lands.
    private func applyDeepFilter() {
        guard let deepIndex else {
            deepSearchWorkItem?.cancel()
            filtered = SessionQuery.run(
                all,
                agent: agentFilter,
                search: currentQuery.isEmpty ? nil : currentQuery,
                limit: displayLimit
            )
            snippets = [:]
            updateFooter(shown: 0, total: 0, note: "loading deep search…")
            loadDeepIndex()
            return
        }

        // No phrase yet: nothing to match inside bodies — just show newest.
        guard !currentQuery.isEmpty else {
            deepSearchWorkItem?.cancel()
            deepSearchGeneration += 1
            snippets = [:]
            let matches = SessionQuery.run(all, agent: agentFilter)
            filtered = Array(matches.prefix(displayLimit))
            updateFooter(
                shown: filtered.count,
                total: matches.count,
                note: Self.deepFooter(
                    shown: filtered.count,
                    total: matches.count,
                    isCapped: false,
                    index: deepIndex
                )
            )
            return
        }

        scheduleDeepSearch(using: deepIndex)
    }

    /// Run the phrase search off the main actor after a short pause in typing.
    /// It used to run inline on every keystroke, walking every indexed
    /// transcript's text on the main thread; a large index froze the panel while
    /// it typed. The rows on screen stay put until the newest search lands.
    private func scheduleDeepSearch(using index: SessionDeepSearch.Index) {
        deepSearchWorkItem?.cancel()
        deepSearchGeneration += 1
        let generation = deepSearchGeneration
        let query = currentQuery
        let records = all
        let agent = agentFilter
        // Ask for one more than fits on screen, so the footer can distinguish
        // "exactly a screenful" from "more than a screenful".
        let matchLimit = displayLimit + 1

        let work = DispatchWorkItem { [weak self] in
            let ordered = SessionQuery.run(records, agent: agent)
            let results = SessionDeepSearch.search(query, in: ordered, index: index, limit: matchLimit)
            DispatchQueue.main.async {
                guard let self, generation == self.deepSearchGeneration else { return }
                self.applyDeepResults(results, index: index)
            }
        }
        deepSearchWorkItem = work
        DispatchQueue.global(qos: .userInitiated)
            .asyncAfter(deadline: .now() + Self.deepSearchDebounce, execute: work)
    }

    /// Install a completed deep search: rows, snippets, and a footer that says
    /// what the count actually is.
    private func applyDeepResults(_ results: SessionDeepSearch.Results, index: SessionDeepSearch.Index) {
        let shown = Array(results.matches.prefix(displayLimit))
        filtered = shown.map(\.record)
        snippets = Dictionary(shown.map { ($0.record.logPath, $0.snippet) }, uniquingKeysWith: { first, _ in first })
        updateFooter(
            shown: shown.count,
            total: results.matches.count,
            note: Self.deepFooter(
                shown: shown.count,
                total: results.matches.count,
                isCapped: results.isCapped,
                index: index
            )
        )
        reloadAndSelectFirst()
    }

    /// The footer for a deep search. A capped search knows it found *at least*
    /// this many, so it says "50 of 51+" rather than passing a floor off as a
    /// total; a partial index is called out on its own, because "no matches"
    /// means something different when not every session was read. Pure and
    /// `nonisolated` so the honesty of the count is testable without a window.
    nonisolated static func deepFooter(
        shown: Int,
        total: Int,
        isCapped: Bool,
        index: SessionDeepSearch.Index
    ) -> String? {
        var parts: [String] = []
        if isCapped {
            parts.append("\(shown) of \(total)+ · keep typing to narrow")
        } else if shown < total {
            parts.append("\(shown) of \(total) · keep typing to narrow")
        } else if total == 0 {
            parts.append("no matches")
        }
        if let note = indexNote(index) { parts.append(note) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What the index left out, or nil when it holds every session in full.
    nonisolated static func indexNote(_ index: SessionDeepSearch.Index) -> String? {
        guard index.isPartial else { return nil }
        var parts: [String] = []
        if index.skippedSessions > 0 {
            parts.append(count(index.skippedSessions, "session", "sessions") + " not indexed")
        }
        if !index.truncatedPaths.isEmpty {
            parts.append(count(index.truncatedPaths.count, "transcript", "transcripts") + " truncated")
        }
        return "searched all but " + parts.joined(separator: " and ")
    }

    private nonisolated static func count(_ value: Int, _ singular: String, _ plural: String) -> String {
        "\(value) \(value == 1 ? singular : plural)"
    }

    /// Build the body-text index off the main thread (mirroring `loadSessions`),
    /// then re-apply the current query on main. In-memory only; dropped with the
    /// panel.
    private func loadDeepIndex() {
        guard !deepLoading, deepIndex == nil else { return }
        deepLoading = true
        let records = all
        let generation = deepGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let index = SessionDeepSearch.buildIndex(for: records)
            DispatchQueue.main.async {
                guard let self else { return }
                self.deepLoading = false
                // If the records changed (or the panel closed) while this build
                // ran, it was built against stale logs — discard it and rebuild
                // against the current records, but only if deep mode is still on
                // and the panel is still open (a closed panel frees the index on
                // purpose, so don't resurrect it).
                guard generation == self.deepGeneration else {
                    if self.deepMode, self.isVisible { self.loadDeepIndex() }
                    return
                }
                self.deepIndex = index
                guard self.deepMode else { return }
                self.applyFilter()
                self.reloadAndSelectFirst()
            }
        }
    }

    @objc private func deepToggled(_ sender: NSButton) {
        deepMode = sender.state == .on
        applyFilter()
        reloadAndSelectFirst()
        // Toggling steals first responder; hand it back so typing keeps filtering.
        searchField.becomeFirstResponder()
    }

    @objc private func agentFilterChanged(_ sender: NSSegmentedControl) {
        let segment = sender.selectedSegment
        guard segment >= 0, segment < Self.agentSegments.count else { return }
        agentFilter = Self.agentSegments[segment]
        applyFilter()
        reloadAndSelectFirst()
        // Clicking steals first responder; hand it back so typing keeps filtering.
        searchField.becomeFirstResponder()
    }

    /// Select the agent segment for a ⌘1/⌘2/⌘3 press, mirroring a click.
    private func selectAgentSegment(_ segment: Int) {
        guard segment < Self.agentSegments.count else { return }
        agentControl.selectedSegment = segment
        agentFilterChanged(agentControl)
    }

    /// The panel is retained by `MainWindowController`, so `close()` only orders
    /// it out — the in-memory body index (tens of MB) would otherwise live for
    /// the app's lifetime. Free it here; bumping the generation makes any
    /// in-flight build discard itself. The `deepMode` toggle is left as-is so it
    /// persists across opens; the next deep use rebuilds the index fresh.
    override func close() {
        super.close()
        deepIndex = nil
        snippets = [:]
        deepGeneration += 1
        // A search scheduled against the index we just dropped has nothing to
        // land on; cancel it and retire its generation.
        deepSearchWorkItem?.cancel()
        deepSearchWorkItem = nil
        deepSearchGeneration += 1
    }

    func show(relativeTo parentWindow: NSWindow) {
        let parentFrame = parentWindow.frame
        setFrameOrigin(NSPoint(
            x: parentFrame.midX - frame.width / 2,
            y: parentFrame.midY + 80
        ))

        searchField.stringValue = ""
        currentQuery = ""
        // Show immediately with whatever we already have; the refresh below
        // repopulates once the (off-main) cache load lands.
        applyFilter()
        reloadAndSelectFirst()

        makeKeyAndOrderFront(nil)
        searchField.becomeFirstResponder()

        loadSessions()
    }

    /// Refresh the unified session list off the main thread (the module is
    /// `@MainActor` by default, but the cache/parse/query types are
    /// `nonisolated`/`Sendable`), then apply on main — mirroring how
    /// `QuickOpenPanel` drains work off-main and applies on main.
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
            // Backfill the cwd of records whose log never recorded one, using the
            // authoritative launch ledger Cortland writes at spawn time. Done
            // off-main (ledger read + pure match) before dedupe/filter see them.
            let ledger = SessionLaunchLedger.entries()
            let backfilled = SessionLaunchLedger.backfillCWDs(records, using: ledger)
            DispatchQueue.main.async {
                guard let self else { return }
                // Collapse Codex's per-subagent rollout files down to one row per
                // logical session before anything else sees the records.
                self.all = SessionQuery.dedupeSessions(backfilled)
                // The body index was keyed to the previous record set; drop it
                // so deep mode rebuilds against the fresh logs. Bump the
                // generation so any in-flight build discards itself instead of
                // reinstalling an index built from the old records.
                self.deepIndex = nil
                self.deepGeneration += 1
                self.applyFilter()
                self.reloadAndSelectFirst()
                self.queueTitleGeneration()
            }
        }
    }

    // MARK: - Codex titling

    /// Queue local title generation for the currently-visible Codex rows that
    /// still show their raw prompt (no `aiTitle`, no `generatedTitle`) and
    /// haven't been attempted yet. Scoped to the visible set so we title what the
    /// user is actually looking at, not the whole history. Each result is
    /// persisted and folded into the live rows as it lands; a missing/stopped
    /// Ollama simply produces nothing and the rows stay as they are.
    private func queueTitleGeneration() {
        let titler = self.titler
        let cacheURL = SessionRecallCache.defaultCacheURL()
        let candidates = filtered.filter { record in
            record.agent == .codex
                && record.aiTitle == nil
                && record.generatedTitle == nil
                && !attemptedTitlePaths.contains(record.logPath)
        }
        guard !candidates.isEmpty else { return }

        for record in candidates {
            attemptedTitlePaths.insert(record.logPath)
            let logPath = record.logPath
            let rawTitle = record.title
            titlingQueue.async { [weak self] in
                guard let generated = titler.title(for: rawTitle) else { return }
                SessionRecallCache.storeGeneratedTitle(generated, forLogPath: logPath, cacheURL: cacheURL)
                DispatchQueue.main.async {
                    self?.applyGeneratedTitle(generated, forLogPath: logPath)
                }
            }
        }
    }

    /// Fold a freshly-generated title into the in-memory record sets and redraw
    /// just its row if it's visible. Records are matched by `logPath` (captured
    /// at queue time) so a refresh that reordered the arrays in between can't
    /// misapply a title.
    private func applyGeneratedTitle(_ title: String, forLogPath logPath: String) {
        if let i = all.firstIndex(where: { $0.logPath == logPath }) {
            all[i].generatedTitle = title
        }
        guard let row = filtered.firstIndex(where: { $0.logPath == logPath }) else { return }
        filtered[row].generatedTitle = title
        tableView.reloadData(
            forRowIndexes: IndexSet(integer: row),
            columnIndexes: IndexSet(integer: 0)
        )
    }
}

// MARK: - Row cell

/// One session row: an agent glyph, the (aiTitle-preferred) title, and a muted
/// subtitle of "agent · repo · relative age". Modeled on the palette's
/// `PaletteActionCellView`, using `AppTheme` colors.
private final class SessionRowCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    private static let ageFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentTintColor = AppTheme.accent

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = AppTheme.primaryText
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        subtitleLabel.textColor = AppTheme.mutedText
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            subtitleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            subtitleLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4)
        ])
    }

    /// Configure the row. When a deep-search `snippet` is supplied, it replaces
    /// the usual "agent · repo · age" subtitle with the matching context so you
    /// can see *where* the phrase hit.
    func configure(with record: SessionRecord, snippet: String? = nil) {
        let symbol = record.agent == .claude ? "sparkle" : "chevron.left.forwardslash.chevron.right"
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: record.agent.rawValue)
        titleLabel.stringValue = record.aiTitle ?? record.generatedTitle ?? record.title
        if let snippet, !snippet.isEmpty {
            subtitleLabel.stringValue = snippet
        } else {
            subtitleLabel.stringValue = Self.subtitle(for: record)
        }
    }

    private static func subtitle(for record: SessionRecord) -> String {
        var parts: [String] = [record.agent.rawValue]
        if let repo = record.repo, !repo.isEmpty {
            parts.append(repo)
        }
        if let age = relativeAge(record.timestamp) {
            parts.append(age)
        }
        return parts.joined(separator: " · ")
    }

    private static func relativeAge(_ date: Date?) -> String? {
        guard let date else { return nil }
        return ageFormatter.localizedString(for: date, relativeTo: Date())
    }
}
