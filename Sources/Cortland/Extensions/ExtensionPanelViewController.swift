import Cocoa

/// A sidebar panel filled by an extension's `command panel` output: an
/// optional message, then section headers and rows. Rows and the panel may
/// carry actions: a row's in its context menu (the first also on double-click),
/// the panel's as icon buttons in the top bar, or behind the Actions button
/// when they have no icon.
final class ExtensionPanelViewController: NSViewController {
    let installed: InstalledExtension
    let refresher: ExtensionPanelRefresher
    let actionRunner: ExtensionPanelActionRunner

    /// A shell command line an action wants run in a new terminal tab.
    /// Lives on `actionRunner`, which the command palette shares.
    var onOpenTab: ((String) -> Void)? {
        get { actionRunner.onOpenTab }
        set { actionRunner.onOpenTab = newValue }
    }
    /// Asks the user to confirm an action that has `confirm`; true runs it.
    /// Lives on `actionRunner`. Injected so tests do not show an alert.
    var confirmAction: @MainActor (ExtensionPanelAction) -> Bool {
        get { actionRunner.confirmAction }
        set { actionRunner.confirmAction = newValue }
    }
    /// Shows a failed action's title and reason. Lives on `actionRunner`.
    /// Injected for tests.
    var showFailure: @MainActor (_ title: String, _ reason: String) -> Void {
        get { actionRunner.showFailure }
        set { actionRunner.showFailure = newValue }
    }

    enum Item: Equatable {
        case header(String)
        case message(String)
        case error(String)
        case row(ExtensionPanelContent.Row)
    }

    private(set) var items: [Item] = []
    /// Counts table reloads, so a test can check that equal content does not
    /// reload the view.
    private(set) var reloadCount = 0

    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var refreshButton: NSButton!
    private var actionsButton: NSButton!
    /// Holds one button per panel action with an icon, then `actionsButton`.
    private var actionStack: NSStackView!
    private var iconActionButtons: [NSButton] = []
    private var themeObserver: ThemeObserver?

    /// `actionRunner` nil uses the standard one for `installed`. Pass the
    /// extension's shared runner so palette commands and this panel run one
    /// action at a time between them. Every action the runner finishes,
    /// from here or the palette, refreshes this panel.
    init(installed: InstalledExtension, refresher: ExtensionPanelRefresher, actionRunner: ExtensionPanelActionRunner? = nil) {
        self.installed = installed
        self.refresher = refresher
        self.actionRunner = actionRunner ?? ExtensionPanelActionRunner(command: ExtensionPanelCommand(extension: installed))
        super.init(nibName: nil, bundle: nil)
        self.actionRunner.onFinish = { [weak self] in self?.refresher.refreshAfterCurrentLoad() }
    }

    convenience init(installed: InstalledExtension, actionRunner: ExtensionPanelActionRunner? = nil) {
        let refreshSeconds = installed.manifest.panel?.refreshSeconds ?? ExtensionPanelSpec.defaultRefreshSeconds
        self.init(
            installed: installed,
            refresher: ExtensionPanelRefresher(
                command: ExtensionPanelCommand(extension: installed),
                refreshInterval: TimeInterval(refreshSeconds)
            ),
            actionRunner: actionRunner
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = AppTheme.sidebarBackground.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupViews()
        refresher.onStateChange = { [weak self] state in self?.apply(state) }
        apply(refresher.state)
        themeObserver = ThemeObserver { [weak self] in self?.applyThemeColors() }
    }

    /// True while this is the visible sidebar panel. Drives the refresh timer.
    func setActive(_ active: Bool) {
        refresher.setActive(active)
    }

    private func applyThemeColors() {
        view.layer?.backgroundColor = AppTheme.sidebarBackground.cgColor
        refreshButton?.contentTintColor = AppTheme.primaryText
        actionsButton?.contentTintColor = AppTheme.primaryText
        iconActionButtons.forEach { $0.contentTintColor = AppTheme.primaryText }
        scrollView?.backgroundColor = AppTheme.sidebarBackground
        tableView?.backgroundColor = AppTheme.sidebarBackground
        tableView?.reloadData()
    }

    private func setupViews() {
        refreshButton = NSButton(
            image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh") ?? NSImage(),
            target: self,
            action: #selector(refreshClicked)
        )
        refreshButton.isBordered = false
        refreshButton.contentTintColor = AppTheme.primaryText
        refreshButton.toolTip = "Refresh \(installed.manifest.panel?.title ?? installed.manifest.name)"
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        actionsButton = NSButton(
            image: NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Actions") ?? NSImage(),
            target: self,
            action: #selector(actionsClicked)
        )
        actionsButton.isBordered = false
        actionsButton.contentTintColor = AppTheme.primaryText
        actionsButton.toolTip = "Actions"
        actionsButton.isHidden = true
        actionsButton.translatesAutoresizingMaskIntoConstraints = false

        actionStack = NSStackView(views: [actionsButton])
        actionStack.orientation = .horizontal
        actionStack.spacing = 4
        actionStack.translatesAutoresizingMaskIntoConstraints = false

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
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.style = .plain
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        let rowMenu = NSMenu()
        rowMenu.delegate = self
        tableView.menu = rowMenu

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ExtensionPanelColumn"))
        column.isEditable = false
        tableView.addTableColumn(column)
        scrollView.documentView = tableView

        view.addSubview(refreshButton)
        view.addSubview(actionStack)
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            refreshButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            refreshButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            refreshButton.widthAnchor.constraint(equalToConstant: 22),
            refreshButton.heightAnchor.constraint(equalToConstant: 22),

            actionStack.centerYAnchor.constraint(equalTo: refreshButton.centerYAnchor),
            actionStack.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -4),
            actionsButton.widthAnchor.constraint(equalToConstant: 22),
            actionsButton.heightAnchor.constraint(equalToConstant: 22),

            scrollView.topAnchor.constraint(equalTo: refreshButton.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    @objc private func refreshClicked() {
        refresher.refresh()
    }

    private func apply(_ state: ExtensionPanelState) {
        let selectedID = selectedRowID
        items = Self.items(for: state)
        reloadCount += 1
        tableView?.reloadData()
        if let selectedID, let index = rowIndex(for: selectedID) {
            tableView?.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            tableView?.deselectAll(nil)
        }
        rebuildIconActionButtons()
        actionsButton?.isHidden = menuPanelActions.isEmpty
    }

    /// One top-bar button per panel action with an icon, before the Actions
    /// button, in the order the extension listed them.
    private func rebuildIconActionButtons() {
        guard let actionStack else { return }
        iconActionButtons.forEach { $0.removeFromSuperview() }
        iconActionButtons = iconPanelActions.enumerated().map { index, action in
            let image = action.icon.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: action.title) }
            let button = NSButton(image: image ?? NSImage(), target: self, action: #selector(iconActionClicked(_:)))
            button.isBordered = false
            button.contentTintColor = AppTheme.primaryText
            button.toolTip = action.title
            button.tag = index
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 22).isActive = true
            button.heightAnchor.constraint(equalToConstant: 22).isActive = true
            actionStack.insertArrangedSubview(button, at: index)
            return button
        }
    }

    @objc private func iconActionClicked(_ sender: NSButton) {
        guard let action = iconPanelActions[safe: sender.tag] else { return }
        perform(action, rowID: nil)
    }

    // MARK: - Actions

    /// The panel's own actions, from the content showing.
    var panelActions: [ExtensionPanelAction] {
        if case .content(let content) = refresher.state { return content.actions }
        return []
    }

    /// Panel actions drawn as their own top-bar button: those whose `icon` is
    /// a real SF Symbol.
    var iconPanelActions: [ExtensionPanelAction] {
        panelActions.filter(Self.hasSymbol)
    }

    /// Panel actions listed behind the Actions button: the rest.
    var menuPanelActions: [ExtensionPanelAction] {
        panelActions.filter { !Self.hasSymbol($0) }
    }

    private static func hasSymbol(_ action: ExtensionPanelAction) -> Bool {
        guard let icon = action.icon else { return false }
        return NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil
    }

    /// The id of the selected row, if a row is selected.
    var selectedRowID: String? {
        guard let tableView, let index = tableView.selectedRowIndexes.first else { return nil }
        return row(at: index)?.id
    }

    /// True when the Actions button is showing.
    var isActionsButtonVisible: Bool { actionsButton.map { !$0.isHidden } ?? false }

    private func row(at index: Int) -> ExtensionPanelContent.Row? {
        guard index >= 0, index < items.count, case .row(let entry) = items[index] else { return nil }
        return entry
    }

    private func rowIndex(for id: String) -> Int? {
        items.firstIndex { item in
            if case .row(let entry) = item { return entry.id == id }
            return false
        }
    }

    /// Selects the row with `id`, as a click would. Test hook.
    func selectRow(id: String) {
        guard let index = rowIndex(for: id) else { return }
        tableView?.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }

    /// Runs `action`, for the row with `rowID` or (nil) for the panel: asks
    /// first when it has `confirm`, and does nothing while another runs.
    func perform(_ action: ExtensionPanelAction, rowID: String?) {
        actionRunner.perform(action, rowID: rowID)
    }

    /// Double-click runs the row's first action.
    func performDefaultAction(rowAt index: Int) {
        guard let entry = row(at: index), let first = entry.actions.first else { return }
        perform(first, rowID: entry.id)
    }

    @objc private func rowDoubleClicked() {
        performDefaultAction(rowAt: tableView.clickedRow)
    }

    @objc private func actionsClicked() {
        let menu = NSMenu()
        for action in menuPanelActions {
            menu.addItem(menuItem(for: action, rowID: nil))
        }
        guard menu.numberOfItems > 0 else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: actionsButton.bounds.height + 4), in: actionsButton)
    }

    private struct MenuTarget {
        let action: ExtensionPanelAction
        let rowID: String?
    }

    private func menuItem(for action: ExtensionPanelAction, rowID: String?) -> NSMenuItem {
        let item = NSMenuItem(title: action.title, action: #selector(menuActionChosen(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = MenuTarget(action: action, rowID: rowID)
        return item
    }

    @objc private func menuActionChosen(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? MenuTarget else { return }
        perform(target.action, rowID: target.rowID)
    }

    /// The context menu items for the row at `index`, in order; empty for a
    /// row without actions.
    func contextMenuItems(rowAt index: Int) -> [NSMenuItem] {
        guard let entry = row(at: index) else { return [] }
        return entry.actions.map { menuItem(for: $0, rowID: entry.id) }
    }

    static func items(for state: ExtensionPanelState) -> [Item] {
        switch state {
        case .loading:
            return [.message("Loading…")]
        case .failed(let reason):
            return [.error("Extension error"), .message(reason)]
        case .content(let content):
            var items: [Item] = []
            if let message = content.message, !message.isEmpty {
                items.append(.message(message))
            }
            for section in content.sections {
                items.append(.header(section.title.uppercased()))
                if section.rows.isEmpty {
                    if let empty = section.empty, !empty.isEmpty {
                        items.append(.message(empty))
                    }
                } else {
                    items.append(contentsOf: section.rows.map(Item.row))
                }
            }
            return items
        }
    }
}

extension ExtensionPanelViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in contextMenuItems(rowAt: tableView.clickedRow) {
            menu.addItem(item)
        }
    }
}

extension ExtensionPanelViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }
}

extension ExtensionPanelViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count else { return nil }
        let cell = NSTableCellView()

        switch items[row] {
        case .header(let title):
            let label = NSTextField(labelWithString: title)
            label.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
            label.textColor = AppTheme.mutedText
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
                label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -3)
            ])
        case .message(let text), .error(let text):
            let isError: Bool
            if case .error = items[row] { isError = true } else { isError = false }
            let label = NSTextField(labelWithString: text)
            label.font = NSFont.systemFont(ofSize: 12, weight: isError ? .semibold : .regular)
            label.textColor = isError ? AppTheme.error : AppTheme.mutedText
            label.lineBreakMode = .byTruncatingTail
            label.toolTip = text
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        case .row(let entry):
            let titleLabel = NSTextField(labelWithString: entry.title)
            titleLabel.font = NSFont.systemFont(ofSize: 13)
            titleLabel.textColor = AppTheme.primaryText
            titleLabel.lineBreakMode = .byTruncatingTail
            titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            titleLabel.toolTip = entry.detail.map { "\(entry.title)\n\($0)" } ?? entry.title
            cell.addSubview(titleLabel)

            var leading = cell.leadingAnchor
            var leadingInset: CGFloat = 12
            if let iconName = entry.icon,
               let image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) {
                let icon = NSImageView(image: image)
                icon.contentTintColor = AppTheme.accent
                icon.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(icon)
                NSLayoutConstraint.activate([
                    icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                    icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    icon.widthAnchor.constraint(equalToConstant: 14),
                    icon.heightAnchor.constraint(equalToConstant: 14)
                ])
                leading = icon.trailingAnchor
                leadingInset = 7
            }

            NSLayoutConstraint.activate([
                titleLabel.leadingAnchor.constraint(equalTo: leading, constant: leadingInset),
                titleLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])

            if let detail = entry.detail, !detail.isEmpty {
                let detailLabel = NSTextField(labelWithString: detail)
                detailLabel.font = NSFont.systemFont(ofSize: 11)
                detailLabel.textColor = AppTheme.secondaryText
                detailLabel.lineBreakMode = .byTruncatingTail
                detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                detailLabel.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(detailLabel)
                NSLayoutConstraint.activate([
                    detailLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
                    detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
                    detailLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor)
                ])
            } else {
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8).isActive = true
            }
        }

        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = items[row] { return 26 }
        return 24
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .row = items[row] { return true }
        return false
    }
}
