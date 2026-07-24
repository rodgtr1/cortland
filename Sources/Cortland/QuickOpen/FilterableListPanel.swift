import Cocoa

/// Subsequence fuzzy match shared by Quick Open (file paths) and the Command
/// Palette (action titles). An exact match scores highest, then a prefix, then
/// a substring, then an in-order subsequence (10 per matched character).
/// Returns nil when the query isn't a subsequence of the candidate.
///
/// `nonisolated` so Quick Open can score candidate paths on a background queue.
enum FuzzyScorer {
    nonisolated static func score(candidate: String, query: String) -> Int? {
        let lowerCandidate = candidate.lowercased()
        let lowerQuery = query.lowercased()

        if lowerCandidate == lowerQuery { return 1000 }
        if lowerCandidate.hasPrefix(lowerQuery) { return 800 }
        if lowerCandidate.contains(lowerQuery) { return 600 }

        var queryIndex = lowerQuery.startIndex
        var score = 0
        for character in lowerCandidate {
            if queryIndex < lowerQuery.endIndex && character == lowerQuery[queryIndex] {
                score += 10
                queryIndex = lowerQuery.index(after: queryIndex)
            }
        }
        return queryIndex >= lowerQuery.endIndex ? score : nil
    }
}

/// Shared chrome for the floating "type-to-filter, arrow-to-navigate,
/// enter-to-act" panels (Quick Open, Command Palette). This base owns the
/// search field, results table, scroll view, key handling, and selection
/// movement; subclasses supply the row data and per-row cell, and react to
/// query changes and row activation.
class FilterableListPanel: NSPanel {
    let searchField = NSSearchField()
    let scrollView = NSScrollView()
    let tableView = NSTableView()
    private var searchFieldDelegate: SearchFieldDelegate?
    /// The search field's trailing constraint, held so an optional header
    /// accessory can be inserted at the trailing edge of the search-field row
    /// (see `installHeaderAccessory`). Nil until `setupUI` runs.
    private var searchFieldTrailing: NSLayoutConstraint?
    /// The scroll view's bottom constraint, held so an optional footer can be
    /// inserted beneath the list (see `installFooter`). Nil until `setupUI` runs.
    private var scrollViewBottom: NSLayoutConstraint?
    /// Fixed row height, from `Chrome.rowHeight`. Two-line rows (title +
    /// subtitle) need more than the single-line default.
    private let rowHeight: CGFloat

    /// Per-panel appearance and behavior supplied by the subclass.
    struct Chrome {
        let title: String
        let placeholder: String
        let size: NSSize
        let columnIdentifier: String
        /// Quick Open stays up while other tasks run; the palette dismisses on
        /// deactivation.
        let hidesOnDeactivate: Bool
        /// Row height. Defaults to 32 (single-line rows); two-line rows should
        /// pass a taller value.
        var rowHeight: CGFloat = 32
    }

    init(chrome: Chrome) {
        rowHeight = chrome.rowHeight
        super.init(
            contentRect: NSRect(origin: .zero, size: chrome.size),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        setupPanel(chrome)
        setupUI(chrome)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private func setupPanel(_ chrome: Chrome) {
        title = chrome.title
        level = .floating
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = chrome.hidesOnDeactivate
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        center()
    }

    private func setupUI(_ chrome: Chrome) {
        guard let contentView = contentView else { return }

        let containerView = NSView()
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = AppTheme.windowBackground.cgColor
        containerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(containerView)

        searchField.placeholderString = chrome.placeholder
        searchField.target = self
        searchField.action = #selector(searchFieldChanged(_:))
        searchField.font = NSFont.systemFont(ofSize: 14)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        // Route escape/arrows/enter from the field editor back to the panel so
        // list navigation works while the search field holds focus.
        let delegate = SearchFieldDelegate()
        delegate.escapeHandler = { [weak self] in self?.close() }
        delegate.moveUpHandler = { [weak self] in self?.moveSelection(by: -1) }
        delegate.moveDownHandler = { [weak self] in self?.moveSelection(by: 1) }
        delegate.enterHandler = { [weak self] in self?.activateSelectedRow() }
        searchField.delegate = delegate
        searchFieldDelegate = delegate

        tableView.headerView = nil
        tableView.rowSizeStyle = .medium
        tableView.backgroundColor = .clear
        if #available(macOS 12.0, *) {
            tableView.style = .sourceList
        } else {
            tableView.selectionHighlightStyle = .sourceList
        }
        tableView.target = self
        tableView.doubleAction = #selector(tableViewDoubleClick(_:))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(chrome.columnIdentifier))
        column.width = chrome.size.width - 40
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.backgroundColor = .clear
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        containerView.addSubview(searchField)
        containerView.addSubview(scrollView)

        let searchTrailing = searchField.trailingAnchor.constraint(
            equalTo: containerView.trailingAnchor, constant: -20
        )
        searchFieldTrailing = searchTrailing
        let scrollBottom = scrollView.bottomAnchor.constraint(
            equalTo: containerView.bottomAnchor, constant: -20
        )
        scrollViewBottom = scrollBottom

        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            containerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            searchField.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 20),
            searchField.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            searchTrailing,
            searchField.heightAnchor.constraint(equalToConstant: 28),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            scrollBottom
        ])

        tableView.dataSource = self
        tableView.delegate = self
    }

    // MARK: - Key handling & selection

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            close()
        case 125: // Down arrow
            moveSelection(by: 1)
        case 126: // Up arrow
            moveSelection(by: -1)
        case 36: // Return
            activateSelectedRow()
        default:
            super.keyDown(with: event)
        }
    }

    func moveSelection(by delta: Int) {
        let next = tableView.selectedRow + delta
        guard next >= 0, next < itemCount else { return }
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    private func activateSelectedRow() {
        let row = tableView.selectedRow
        guard row >= 0, row < itemCount else { return }
        activateRow(row)
    }

    /// Reload the table and auto-select the first row, if any.
    func reloadAndSelectFirst() {
        tableView.reloadData()
        if itemCount > 0 {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        queryChanged(sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @objc private func tableViewDoubleClick(_ sender: NSTableView) {
        activateSelectedRow()
    }

    // MARK: - Header accessory

    /// Install an optional control at the trailing edge of the search-field row,
    /// shrinking the search field to make room. Subclasses call this after
    /// `init` (once `self` exists, so the control can target it). Panels that
    /// never call it — Quick Open, the command palette — keep the original
    /// full-width search field, unchanged.
    func installHeaderAccessory(_ view: NSView) {
        guard let containerView = searchField.superview,
              let searchFieldTrailing else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        containerView.addSubview(view)

        // Detach the search field from the container's trailing edge and pin it
        // to the accessory's leading edge instead.
        searchFieldTrailing.isActive = false
        NSLayoutConstraint.activate([
            view.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            view.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            searchField.trailingAnchor.constraint(equalTo: view.leadingAnchor, constant: -10)
        ])
    }

    /// Insert a footer view beneath the list, shrinking the scroll view to make
    /// room. Panels that never call this — Quick Open, the command palette —
    /// keep the original full-height list, unchanged.
    func installFooter(_ view: NSView) {
        guard let containerView = scrollView.superview,
              let scrollViewBottom else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(view)

        // Detach the scroll view from the container's bottom edge and pin it
        // to the footer's top edge instead.
        scrollViewBottom.isActive = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            view.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            view.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: view.topAnchor, constant: -8)
        ])
    }

    // MARK: - Subclass hooks

    /// Number of rows currently displayed. Override.
    var itemCount: Int { 0 }

    /// Cell view for `row`. Override.
    func cellView(forRow row: Int) -> NSView? { nil }

    /// The (trimmed) search query changed. Override to refilter / kick off a
    /// search.
    func queryChanged(_ query: String) {}

    /// A row was chosen (Return or double-click). Override to act on it.
    func activateRow(_ row: Int) {}
}

extension FilterableListPanel: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { itemCount }
}

extension FilterableListPanel: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < itemCount else { return nil }
        return cellView(forRow: row)
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rowHeight }
}

// MARK: - Search Field Delegate

/// Routes keys the field editor would otherwise swallow (escape, arrows,
/// enter) back to the owning panel so list navigation works while typing.
class SearchFieldDelegate: NSObject, NSSearchFieldDelegate {
    var escapeHandler: (() -> Void)?
    var moveUpHandler: (() -> Void)?
    var moveDownHandler: (() -> Void)?
    var enterHandler: (() -> Void)?

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            escapeHandler?()
            return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)), let moveUpHandler {
            moveUpHandler()
            return true
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)), let moveDownHandler {
            moveDownHandler()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)), let enterHandler {
            enterHandler()
            return true
        }
        return false
    }
}
