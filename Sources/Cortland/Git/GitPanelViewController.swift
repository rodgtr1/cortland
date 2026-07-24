import Cocoa

/// Which diff a `didRequestDiffFor` targets: the file's working-tree changes,
/// or its committed changes vs the repo's default branch (three-dot merge-base).
enum GitDiffKind: Equatable, Sendable {
    case uncommitted
    case againstDefaultBranch
}

protocol GitPanelDelegate: AnyObject {
    func gitPanel(_ panel: GitPanelViewController, didRequestDiffFor filePath: String, kind: GitDiffKind)
    func gitPanel(_ panel: GitPanelViewController, didRequestUncommittedChangesFor repositoryPath: String, focusedFilePath: String?)
}

class GitPanelViewController: NSViewController {
    // Created up front (not in viewDidLoad) so the owning sidebar can seed a
    // repository path via setRepositoryPath before the view loads — lazy panel
    // creation runs the seed first. Its init is inert (polling starts only in
    // setRepositoryPath), and setupBindings applies the model's current state
    // once on install, so the seed is reflected without being clobbered.
    private let gitStatusModel = GitStatusModel()

    weak var delegate: GitPanelDelegate?

    // UI Elements
    private var scrollView: NSScrollView!
    private var tableView: NSTableView!
    private var headerView: NSView!
    private var branchLabel: NSTextField!
    private var syncLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var commitMessageTextView: NSTextView!
    private var commitButton: NSButton!
    private var stageAllButton: NSButton!
    private var unstageAllButton: NSButton!
    private var refreshButton: NSButton!
    private var pullButton: NSButton!
    private var pushButton: NSButton!
    private var commitContainer: NSView?
    private var commitLabel: NSTextField?
    // "Changes vs <default>" review section, shown only off the default branch.
    private var branchDiffContainer: NSView!
    private var branchDiffHeaderLabel: NSTextField!
    private var branchDiffScrollView: NSScrollView!
    private var branchDiffTableView: NSTableView!
    private var branchDiffHeightConstraint: NSLayoutConstraint!
    private let branchDiffRowHeight: CGFloat = 24
    private let branchDiffHeaderHeight: CGFloat = 22
    /// Ceiling on the section's height so a long committed-diff list can't crowd
    /// out the uncommitted list above it; the inner table scrolls past this.
    private let branchDiffMaxHeight: CGFloat = 220
    private var themeObserver: ThemeObserver?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = AppTheme.sidebarBackground.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupBindings()
        themeObserver = ThemeObserver { [weak self] in self?.applyThemeColors() }
    }

    private func applyThemeColors() {
        view.layer?.backgroundColor = AppTheme.sidebarBackground.cgColor
        headerView?.layer?.backgroundColor = AppTheme.headerBackground.cgColor
        branchLabel?.textColor = AppTheme.accent
        syncLabel?.textColor = AppTheme.peach
        scrollView?.backgroundColor = AppTheme.sidebarBackground
        scrollView?.contentView.backgroundColor = AppTheme.sidebarBackground
        tableView?.backgroundColor = AppTheme.sidebarBackground
        commitContainer?.layer?.backgroundColor = AppTheme.headerBackground.cgColor
        commitLabel?.textColor = AppTheme.primaryText
        commitMessageTextView?.backgroundColor = AppTheme.windowBackground
        commitMessageTextView?.textColor = AppTheme.primaryText
        commitMessageTextView?.insertionPointColor = AppTheme.cursor
        branchDiffContainer?.layer?.backgroundColor = AppTheme.sidebarBackground.cgColor
        branchDiffHeaderLabel?.textColor = AppTheme.mutedText
        branchDiffScrollView?.backgroundColor = AppTheme.sidebarBackground
        branchDiffScrollView?.contentView.backgroundColor = AppTheme.sidebarBackground
        branchDiffTableView?.backgroundColor = AppTheme.sidebarBackground
        // statusLabel color is driven by isClean binding; reload re-colors rows.
        tableView?.reloadData()
        branchDiffTableView?.reloadData()
    }

    private func setupUI() {
        setupHeader()
        setupTableView()
        setupBranchDiffSection()
        setupCommitArea()
        layoutViews()
    }

    private func setupHeader() {
        headerView = NSView()
        headerView.wantsLayer = true
        headerView.layer?.backgroundColor = AppTheme.headerBackground.cgColor
        headerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerView)

        // Branch info
        branchLabel = NSTextField(labelWithString: "main")
        branchLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        branchLabel.textColor = AppTheme.accent
        branchLabel.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(branchLabel)

        // Ahead/behind upstream info
        syncLabel = NSTextField(labelWithString: "")
        syncLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        syncLabel.textColor = AppTheme.peach
        syncLabel.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(syncLabel)

        // Status info
        statusLabel = NSTextField(labelWithString: "Clean")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = AppTheme.success
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(statusLabel)

        // Refresh button
        refreshButton = NSButton()
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        refreshButton.bezelStyle = .shadowlessSquare
        refreshButton.isBordered = false
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(refreshButton)

        NSLayoutConstraint.activate([
            branchLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 12),
            branchLabel.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 8),

            syncLabel.leadingAnchor.constraint(equalTo: branchLabel.trailingAnchor, constant: 6),
            syncLabel.centerYAnchor.constraint(equalTo: branchLabel.centerYAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: branchLabel.leadingAnchor),
            statusLabel.topAnchor.constraint(equalTo: branchLabel.bottomAnchor, constant: 2),

            refreshButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -12),
            refreshButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            refreshButton.widthAnchor.constraint(equalToConstant: 20),
            refreshButton.heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    private func setupTableView() {
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = AppTheme.sidebarBackground
        scrollView.contentView.drawsBackground = true
        scrollView.contentView.backgroundColor = AppTheme.sidebarBackground

        tableView = NSTableView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = nil
        tableView.backgroundColor = AppTheme.sidebarBackground
        tableView.usesAlternatingRowBackgroundColors = false
        if #available(macOS 12.0, *) {
            tableView.style = .plain
        }
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = true
        // Status and Actions are pinned (min == max), so all width from a
        // sidebar resize flows to the File column instead of the default
        // last-column-only style, which would hand it to the pinned Actions.
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        // Create columns
        let statusColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Status"))
        statusColumn.title = "Status"
        statusColumn.width = 30
        statusColumn.minWidth = 30
        statusColumn.maxWidth = 30
        tableView.addTableColumn(statusColumn)

        let fileColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("File"))
        fileColumn.title = "File"
        fileColumn.isEditable = false
        fileColumn.minWidth = 60
        fileColumn.maxWidth = 10_000
        tableView.addTableColumn(fileColumn)

        let actionsColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Actions"))
        actionsColumn.title = "Actions"
        actionsColumn.width = 80
        actionsColumn.minWidth = 80
        actionsColumn.maxWidth = 80
        tableView.addTableColumn(actionsColumn)

        tableView.action = #selector(tableViewClicked(_:))
        tableView.doubleAction = #selector(tableViewDoubleClicked(_:))
        tableView.target = self

        // Add context menu
        tableView.menu = createContextMenu()

        scrollView.documentView = tableView
        view.addSubview(scrollView)

        // Add control buttons in a 2x2 grid
        let topButtonStack = NSStackView()
        topButtonStack.orientation = .horizontal
        topButtonStack.spacing = 8
        topButtonStack.distribution = .fillEqually
        topButtonStack.translatesAutoresizingMaskIntoConstraints = false

        stageAllButton = NSButton(title: "Stage All", target: self, action: #selector(stageAllClicked))
        stageAllButton.bezelStyle = .rounded
        stageAllButton.controlSize = .small
        topButtonStack.addArrangedSubview(stageAllButton)

        unstageAllButton = NSButton(title: "Unstage All", target: self, action: #selector(unstageAllClicked))
        unstageAllButton.bezelStyle = .rounded
        unstageAllButton.controlSize = .small
        topButtonStack.addArrangedSubview(unstageAllButton)

        let bottomButtonStack = NSStackView()
        bottomButtonStack.orientation = .horizontal
        bottomButtonStack.spacing = 8
        bottomButtonStack.distribution = .fillEqually
        bottomButtonStack.translatesAutoresizingMaskIntoConstraints = false

        pullButton = NSButton(title: "Pull", target: self, action: #selector(pullClicked))
        pullButton.bezelStyle = .rounded
        pullButton.controlSize = .small
        bottomButtonStack.addArrangedSubview(pullButton)

        pushButton = NSButton(title: "Push", target: self, action: #selector(pushClicked))
        pushButton.bezelStyle = .rounded
        pushButton.controlSize = .small
        bottomButtonStack.addArrangedSubview(pushButton)

        view.addSubview(topButtonStack)
        view.addSubview(bottomButtonStack)

        NSLayoutConstraint.activate([
            topButtonStack.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 8),
            topButtonStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            topButtonStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            topButtonStack.heightAnchor.constraint(equalToConstant: 24),

            bottomButtonStack.topAnchor.constraint(equalTo: topButtonStack.bottomAnchor, constant: 4),
            bottomButtonStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            bottomButtonStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            bottomButtonStack.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    /// Read-only "Changes vs <default>" section between the uncommitted list and
    /// the commit area: a header row plus a table of committed-changed files.
    /// Collapsed to zero height (and hidden) until the model reports the panel is
    /// off the default branch, so on the default branch it looks exactly as before.
    private func setupBranchDiffSection() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = AppTheme.sidebarBackground.cgColor
        container.translatesAutoresizingMaskIntoConstraints = false
        container.isHidden = true
        view.addSubview(container)
        branchDiffContainer = container

        branchDiffHeaderLabel = NSTextField(labelWithString: "CHANGES VS MAIN")
        branchDiffHeaderLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        branchDiffHeaderLabel.textColor = AppTheme.mutedText
        branchDiffHeaderLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(branchDiffHeaderLabel)

        branchDiffScrollView = NSScrollView()
        branchDiffScrollView.translatesAutoresizingMaskIntoConstraints = false
        branchDiffScrollView.hasVerticalScroller = true
        branchDiffScrollView.hasHorizontalScroller = false
        branchDiffScrollView.autohidesScrollers = true
        branchDiffScrollView.borderType = .noBorder
        branchDiffScrollView.drawsBackground = true
        branchDiffScrollView.backgroundColor = AppTheme.sidebarBackground
        branchDiffScrollView.contentView.drawsBackground = true
        branchDiffScrollView.contentView.backgroundColor = AppTheme.sidebarBackground

        branchDiffTableView = NSTableView()
        branchDiffTableView.dataSource = self
        branchDiffTableView.delegate = self
        branchDiffTableView.headerView = nil
        branchDiffTableView.backgroundColor = AppTheme.sidebarBackground
        branchDiffTableView.usesAlternatingRowBackgroundColors = false
        if #available(macOS 12.0, *) { branchDiffTableView.style = .plain }
        branchDiffTableView.selectionHighlightStyle = .regular
        branchDiffTableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let statusColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Status"))
        statusColumn.width = 30
        statusColumn.minWidth = 30
        statusColumn.maxWidth = 30
        branchDiffTableView.addTableColumn(statusColumn)
        let fileColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("File"))
        fileColumn.isEditable = false
        fileColumn.minWidth = 60
        fileColumn.maxWidth = 10_000
        branchDiffTableView.addTableColumn(fileColumn)

        branchDiffTableView.target = self
        branchDiffTableView.action = #selector(branchDiffTableClicked(_:))
        branchDiffScrollView.documentView = branchDiffTableView
        container.addSubview(branchDiffScrollView)

        branchDiffHeightConstraint = container.heightAnchor.constraint(equalToConstant: 0)

        // The internal vertical chain is sub-required so it yields silently to
        // the required height=0 when the section is collapsed (hidden), rather
        // than logging an unsatisfiable-constraints conflict.
        let headerTop = branchDiffHeaderLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 4)
        let scrollTop = branchDiffScrollView.topAnchor.constraint(equalTo: branchDiffHeaderLabel.bottomAnchor, constant: 2)
        let scrollBottom = branchDiffScrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        [headerTop, scrollTop, scrollBottom].forEach { $0.priority = .defaultHigh }

        NSLayoutConstraint.activate([
            headerTop,
            branchDiffHeaderLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),

            scrollTop,
            branchDiffScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            branchDiffScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollBottom,

            branchDiffHeightConstraint
        ])
    }

    private func setupCommitArea() {
        // Commit message area
        let commitContainer = NSView()
        commitContainer.wantsLayer = true
        commitContainer.layer?.backgroundColor = AppTheme.headerBackground.cgColor
        commitContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(commitContainer)
        self.commitContainer = commitContainer

        let commitLabel = NSTextField(labelWithString: "Commit Message")
        commitLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        commitLabel.textColor = AppTheme.primaryText
        commitLabel.translatesAutoresizingMaskIntoConstraints = false
        commitContainer.addSubview(commitLabel)
        self.commitLabel = commitLabel

        // Text view for commit message
        let commitScrollView = NSScrollView()
        commitScrollView.hasVerticalScroller = true
        commitScrollView.hasHorizontalScroller = false
        commitScrollView.borderType = .lineBorder
        commitScrollView.translatesAutoresizingMaskIntoConstraints = false

        commitMessageTextView = NSTextView()
        commitMessageTextView.isEditable = true
        commitMessageTextView.isRichText = false
        commitMessageTextView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        commitMessageTextView.backgroundColor = AppTheme.windowBackground
        commitMessageTextView.textColor = AppTheme.primaryText
        commitMessageTextView.insertionPointColor = AppTheme.cursor

        commitScrollView.documentView = commitMessageTextView
        commitContainer.addSubview(commitScrollView)

        commitButton = NSButton(title: "Commit", target: self, action: #selector(commitClicked))
        commitButton.bezelStyle = .rounded
        commitButton.keyEquivalent = "\r"
        commitButton.keyEquivalentModifierMask = [.command]
        commitButton.isEnabled = false
        commitButton.translatesAutoresizingMaskIntoConstraints = false
        commitContainer.addSubview(commitButton)

        NSLayoutConstraint.activate([
            commitLabel.topAnchor.constraint(equalTo: commitContainer.topAnchor, constant: 8),
            commitLabel.leadingAnchor.constraint(equalTo: commitContainer.leadingAnchor, constant: 12),

            commitScrollView.topAnchor.constraint(equalTo: commitLabel.bottomAnchor, constant: 4),
            commitScrollView.leadingAnchor.constraint(equalTo: commitContainer.leadingAnchor, constant: 12),
            commitScrollView.trailingAnchor.constraint(equalTo: commitContainer.trailingAnchor, constant: -12),
            commitScrollView.heightAnchor.constraint(equalToConstant: 60),

            commitButton.topAnchor.constraint(equalTo: commitScrollView.bottomAnchor, constant: 8),
            commitButton.trailingAnchor.constraint(equalTo: commitContainer.trailingAnchor, constant: -12),
            commitButton.bottomAnchor.constraint(equalTo: commitContainer.bottomAnchor, constant: -8),
            commitButton.widthAnchor.constraint(equalToConstant: 80)
        ])
    }

    private func layoutViews() {
        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: view.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 50),

            // 68 = 8 (top margin) + 24 (first row) + 4 (spacing) + 24 (second row) + 8 (bottom margin)
            scrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 68),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // The uncommitted list flexes to fill whatever the vs-main section
            // (0 height when hidden) leaves above the commit area.
            scrollView.bottomAnchor.constraint(equalTo: branchDiffContainer.topAnchor),

            branchDiffContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            branchDiffContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        // Commit area constraints; the vs-main section sits directly above it.
        if let commitContainer = commitContainer {
            NSLayoutConstraint.activate([
                branchDiffContainer.bottomAnchor.constraint(equalTo: commitContainer.topAnchor),

                commitContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                commitContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                commitContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                commitContainer.heightAnchor.constraint(equalToConstant: 120)
            ])
        }
    }

    private func setupBindings() {
        // Repaint from the model whenever its state changes, then once now to
        // reflect any value seeded before the view (and this observer) existed.
        gitStatusModel.onChange = { [weak self] in
            self?.applyModelState()
        }
        applyModelState()

        // Enable commit button when message is not empty
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(commitMessageChanged),
            name: NSText.didChangeNotification,
            object: commitMessageTextView
        )
    }

    /// Pulls the current model state into every header/table/commit control.
    /// Replaces the old per-property Combine sinks — the model batches its
    /// updates and fires `onChange` once, so a single repaint stays in sync.
    private func applyModelState() {
        tableView.reloadData()
        updateBranchDiffSection()

        branchLabel.stringValue = gitStatusModel.currentBranch.isEmpty ? "No repository" : gitStatusModel.currentBranch

        let ahead = gitStatusModel.aheadCount
        let behind = gitStatusModel.behindCount
        var parts: [String] = []
        if ahead > 0 { parts.append("\u{2191}\(ahead)") }
        if behind > 0 { parts.append("\u{2193}\(behind)") }
        syncLabel.stringValue = parts.joined(separator: " ")
        syncLabel.toolTip = parts.isEmpty ? nil : "\(ahead) commit(s) to push, \(behind) to pull"
        pushButton.title = ahead > 0 ? "Push (\(ahead))" : "Push"
        pullButton.title = behind > 0 ? "Pull (\(behind))" : "Pull"

        statusLabel.stringValue = gitStatusModel.isClean ? "Working tree clean" : "Changes detected"
        statusLabel.textColor = gitStatusModel.isClean ? AppTheme.success : AppTheme.peach

        if commitMessageTextView.string != gitStatusModel.commitMessage {
            commitMessageTextView.string = gitStatusModel.commitMessage
        }
    }

    /// Shows/hides and sizes the vs-main section from the model. The base branch
    /// is empty exactly when the section should be hidden (HEAD is the default
    /// branch, or there are no committed changes vs it), so on the default branch
    /// the panel is unchanged.
    private func updateBranchDiffSection() {
        let base = gitStatusModel.branchDiffBaseBranch
        let files = gitStatusModel.branchDiffFiles
        let show = !base.isEmpty && !files.isEmpty

        branchDiffContainer.isHidden = !show
        guard show else {
            branchDiffHeightConstraint.constant = 0
            branchDiffTableView.reloadData()
            return
        }

        branchDiffHeaderLabel.stringValue = "CHANGES VS \(base.uppercased())"
        let contentHeight = branchDiffHeaderHeight + 6 + CGFloat(files.count) * branchDiffRowHeight
        branchDiffHeightConstraint.constant = min(contentHeight, branchDiffMaxHeight)
        branchDiffTableView.reloadData()
    }

    func setRepositoryPath(_ path: String) {
        gitStatusModel.setRepositoryPath(path)
    }

    private func createContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let openItem = NSMenuItem(title: "Open in Editor", action: #selector(contextMenuOpenInEditor), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        let stageItem = NSMenuItem(title: "Stage", action: #selector(contextMenuStage), keyEquivalent: "")
        stageItem.target = self
        menu.addItem(stageItem)

        let unstageItem = NSMenuItem(title: "Unstage", action: #selector(contextMenuUnstage), keyEquivalent: "")
        unstageItem.target = self
        menu.addItem(unstageItem)

        menu.addItem(NSMenuItem.separator())

        let discardItem = NSMenuItem(title: "Discard Changes", action: #selector(contextMenuDiscard), keyEquivalent: "")
        discardItem.target = self
        menu.addItem(discardItem)

        return menu
    }

    // MARK: - Actions

    @objc private func refreshClicked() {
        gitStatusModel.refreshStatus()
    }

    @objc private func stageAllClicked() {
        gitStatusModel.stageAllFiles()
    }

    @objc private func unstageAllClicked() {
        gitStatusModel.unstageAllFiles()
    }

    @objc private func commitClicked() {
        let message = commitMessageTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        gitStatusModel.commit(message: message) { [weak self] success, error in
            DispatchQueue.main.async {
                if success {
                    self?.commitMessageTextView.string = ""
                    self?.commitButton.isEnabled = false
                } else {
                    let alert = NSAlert()
                    alert.messageText = "Commit Failed"
                    alert.informativeText = error ?? "Unknown error"
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }

    @objc private func commitMessageChanged() {
        // Mirror the untrimmed draft into the model so applyModelState's guard
        // (textView.string != model.commitMessage) sees them equal and doesn't
        // clobber the in-progress message on the next refresh batch — onChange
        // now fires on every FSEvents/poll refresh, not just message writes.
        gitStatusModel.commitMessage = commitMessageTextView.string
        let message = commitMessageTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        commitButton.isEnabled = !message.isEmpty
    }

    @objc private func pullClicked() {
        pullButton.isEnabled = false
        gitStatusModel.pull { [weak self] success, message in
            DispatchQueue.main.async {
                self?.pullButton.isEnabled = true
                self?.showGitOperationResult(title: "Pull", success: success, message: message)
            }
        }
    }

    @objc private func pushClicked() {
        pushButton.isEnabled = false
        gitStatusModel.push { [weak self] success, message in
            DispatchQueue.main.async {
                self?.pushButton.isEnabled = true
                self?.showGitOperationResult(title: "Push", success: success, message: message)
            }
        }
    }

    private func showGitOperationResult(title: String, success: Bool, message: String?) {
        let alert = NSAlert()
        alert.messageText = success ? "\(title) Successful" : "\(title) Failed"
        alert.informativeText = message ?? (success ? "Operation completed successfully" : "Unknown error occurred")
        alert.alertStyle = success ? .informational : .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func contextMenuOpenInEditor() {
        let row = tableView.clickedRow
        guard row >= 0 && row < gitStatusModel.files.count else { return }
        let file = gitStatusModel.files[row]
        guard !file.isDirectory else { return }

        let fullPath = gitStatusModel.repositoryPath + "/" + file.path
        NotificationCenter.default.post(
            name: .paneOpenFileRequested,
            object: self,
            userInfo: ["path": fullPath]
        )
    }

    @objc private func contextMenuStage() {
        let row = tableView.clickedRow
        guard row >= 0 && row < gitStatusModel.files.count else { return }
        let file = gitStatusModel.files[row]
        gitStatusModel.stageFile(file)
    }

    @objc private func contextMenuUnstage() {
        let row = tableView.clickedRow
        guard row >= 0 && row < gitStatusModel.files.count else { return }
        let file = gitStatusModel.files[row]
        gitStatusModel.unstageFile(file)
    }

    @objc private func contextMenuDiscard() {
        let row = tableView.clickedRow
        guard row >= 0 && row < gitStatusModel.files.count else { return }
        let file = gitStatusModel.files[row]

        // Show confirmation dialog. An untracked directory discards its entire
        // subtree, so spell that out rather than implying a single file.
        let alert = NSAlert()
        if file.isDirectory {
            alert.messageText = "Delete untracked directory?"
            alert.informativeText = "This permanently deletes the directory '\(file.filename)' and all of its contents. This cannot be undone."
        } else if file.unstagedStatus == .untracked {
            alert.messageText = "Delete untracked file?"
            alert.informativeText = "This permanently deletes the untracked file '\(file.filename)'. This cannot be undone."
        } else {
            alert.messageText = "Discard Changes?"
            alert.informativeText = "Are you sure you want to discard all changes to '\(file.filename)'? This cannot be undone."
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: file.unstagedStatus == .untracked ? "Delete" : "Discard")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            gitStatusModel.discardChanges(file)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - NSTableViewDataSource

extension GitPanelViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === branchDiffTableView {
            return gitStatusModel.branchDiffFiles.count
        }
        return gitStatusModel.files.count
    }
}

// MARK: - NSTableViewDelegate

extension GitPanelViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === branchDiffTableView {
            return branchDiffCell(tableColumn: tableColumn, row: row)
        }
        guard row < gitStatusModel.files.count else { return nil }
        let file = gitStatusModel.files[row]

        let identifier = tableColumn?.identifier
        var cellView: NSTableCellView?

        if identifier?.rawValue == "Status" {
            cellView = tableView.makeView(withIdentifier: identifier!, owner: self) as? NSTableCellView
            if cellView == nil {
                cellView = NSTableCellView()
                cellView?.identifier = identifier

                let statusLabel = NSTextField()
                statusLabel.isEditable = false
                statusLabel.isBordered = false
                statusLabel.backgroundColor = .clear
                statusLabel.alignment = .center
                statusLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
                statusLabel.translatesAutoresizingMaskIntoConstraints = false

                cellView?.addSubview(statusLabel)
                cellView?.textField = statusLabel

                NSLayoutConstraint.activate([
                    statusLabel.centerXAnchor.constraint(equalTo: cellView!.centerXAnchor),
                    statusLabel.centerYAnchor.constraint(equalTo: cellView!.centerYAnchor)
                ])
            }

            cellView?.textField?.stringValue = file.displayStatus.rawValue
            cellView?.textField?.textColor = file.displayStatus.color

        } else if identifier?.rawValue == "File" {
            cellView = tableView.makeView(withIdentifier: identifier!, owner: self) as? NSTableCellView
            if cellView == nil {
                cellView = NSTableCellView()
                cellView?.identifier = identifier

                let textField = NSTextField()
                textField.isEditable = false
                textField.isBordered = false
                textField.backgroundColor = .clear
                textField.font = NSFont.systemFont(ofSize: 13)
                textField.lineBreakMode = .byTruncatingMiddle
                textField.translatesAutoresizingMaskIntoConstraints = false

                cellView?.addSubview(textField)
                cellView?.textField = textField

                NSLayoutConstraint.activate([
                    textField.leadingAnchor.constraint(equalTo: cellView!.leadingAnchor, constant: 4),
                    textField.trailingAnchor.constraint(equalTo: cellView!.trailingAnchor, constant: -4),
                    textField.centerYAnchor.constraint(equalTo: cellView!.centerYAnchor)
                ])
            }

            cellView?.textField?.stringValue = file.filename
            cellView?.textField?.textColor = AppTheme.primaryText
            cellView?.textField?.toolTip = file.path

        } else if identifier?.rawValue == "Actions" {
            cellView = tableView.makeView(withIdentifier: identifier!, owner: self) as? NSTableCellView
            if cellView == nil {
                cellView = NSTableCellView()
                cellView?.identifier = identifier

                let button = NSButton()
                button.bezelStyle = .shadowlessSquare
                button.isBordered = false
                button.font = NSFont.systemFont(ofSize: 10)
                button.translatesAutoresizingMaskIntoConstraints = false

                cellView?.addSubview(button)

                NSLayoutConstraint.activate([
                    button.centerXAnchor.constraint(equalTo: cellView!.centerXAnchor),
                    button.centerYAnchor.constraint(equalTo: cellView!.centerYAnchor),
                    button.widthAnchor.constraint(equalToConstant: 60),
                    button.heightAnchor.constraint(equalToConstant: 20)
                ])
            }

            if let button = cellView?.subviews.first as? NSButton {
                if file.isStaged {
                    button.title = "Unstage"
                    button.target = self
                    button.action = #selector(unstageFile(_:))
                } else {
                    button.title = "Stage"
                    button.target = self
                    button.action = #selector(stageFile(_:))
                }
                button.tag = row
            }
        }

        return cellView
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return 24
    }

    /// Read-only status + filename cell for a "Changes vs <default>" row. No
    /// action column: these rows are reviewed, never staged from the panel.
    private func branchDiffCell(tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < gitStatusModel.branchDiffFiles.count else { return nil }
        let file = gitStatusModel.branchDiffFiles[row]
        let identifier = tableColumn?.identifier

        let cellView = branchDiffTableView.makeView(withIdentifier: identifier!, owner: self) as? NSTableCellView
            ?? {
                let created = NSTableCellView()
                created.identifier = identifier
                let field = NSTextField()
                field.isEditable = false
                field.isBordered = false
                field.backgroundColor = .clear
                field.lineBreakMode = .byTruncatingMiddle
                field.translatesAutoresizingMaskIntoConstraints = false
                created.addSubview(field)
                created.textField = field
                if identifier?.rawValue == "Status" {
                    field.alignment = .center
                    field.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
                    NSLayoutConstraint.activate([
                        field.centerXAnchor.constraint(equalTo: created.centerXAnchor),
                        field.centerYAnchor.constraint(equalTo: created.centerYAnchor)
                    ])
                } else {
                    field.font = NSFont.systemFont(ofSize: 13)
                    NSLayoutConstraint.activate([
                        field.leadingAnchor.constraint(equalTo: created.leadingAnchor, constant: 4),
                        field.trailingAnchor.constraint(equalTo: created.trailingAnchor, constant: -4),
                        field.centerYAnchor.constraint(equalTo: created.centerYAnchor)
                    ])
                }
                return created
            }()

        if identifier?.rawValue == "Status" {
            cellView.textField?.stringValue = file.status.rawValue
            cellView.textField?.textColor = file.status.color
        } else {
            cellView.textField?.stringValue = file.filename
            cellView.textField?.textColor = AppTheme.primaryText
            cellView.textField?.toolTip = file.path
        }
        return cellView
    }

    @objc private func branchDiffTableClicked(_ sender: NSTableView) {
        let row = sender.clickedRow
        guard row >= 0 && row < gitStatusModel.branchDiffFiles.count else { return }
        let file = gitStatusModel.branchDiffFiles[row]
        let fullPath = gitStatusModel.repositoryPath + "/" + file.path
        delegate?.gitPanel(self, didRequestDiffFor: fullPath, kind: .againstDefaultBranch)
    }

    @objc private func stageFile(_ sender: NSButton) {
        let row = sender.tag
        guard row < gitStatusModel.files.count else { return }
        let file = gitStatusModel.files[row]
        gitStatusModel.stageFile(file)
    }

    @objc private func unstageFile(_ sender: NSButton) {
        let row = sender.tag
        guard row < gitStatusModel.files.count else { return }
        let file = gitStatusModel.files[row]
        gitStatusModel.unstageFile(file)
    }

    @objc private func tableViewDoubleClicked(_ sender: NSTableView) {
        openUncommittedChangesForClickedRow(sender)
    }

    @objc private func tableViewClicked(_ sender: NSTableView) {
        openUncommittedChangesForClickedRow(sender)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 {
            openUncommittedChangesForSelectedRow()
            return
        }

        super.keyDown(with: event)
    }

    private func openUncommittedChangesForSelectedRow() {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        openUncommittedChanges(row: row)
    }

    private func openUncommittedChangesForClickedRow(_ sender: NSTableView) {
        let row = sender.clickedRow
        guard row >= 0 && row < gitStatusModel.files.count else { return }
        openUncommittedChanges(row: row)
    }

    private func openUncommittedChanges(row: Int) {
        guard row >= 0 && row < gitStatusModel.files.count else { return }
        let file = gitStatusModel.files[row]
        let fullPath = gitStatusModel.repositoryPath + "/" + file.path
        // Cached lookup: a row click shouldn't fork a synchronous `git
        // rev-parse` on the main thread (P1). The file lives under the panel's
        // repo, so the root is stable across a burst of clicks.
        let repositoryPath = WorkspaceResolver.cachedGitRoot(from: fullPath) ?? gitStatusModel.repositoryPath

        delegate?.gitPanel(
            self,
            didRequestUncommittedChangesFor: repositoryPath,
            focusedFilePath: fullPath
        )
    }
}

// MARK: - NSMenuDelegate

extension GitPanelViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        let row = tableView.clickedRow
        guard row >= 0 && row < gitStatusModel.files.count else {
            // Disable all items if no valid row
            for item in menu.items {
                item.isEnabled = false
            }
            return
        }

        let file = gitStatusModel.files[row]

        // Enable/disable menu items based on file state
        for item in menu.items {
            if item.action == #selector(contextMenuOpenInEditor) {
                item.isEnabled = !file.isDirectory
            } else if item.action == #selector(contextMenuStage) {
                item.isEnabled = !file.isStaged
            } else if item.action == #selector(contextMenuUnstage) {
                item.isEnabled = file.isStaged
            } else if item.action == #selector(contextMenuDiscard) {
                item.isEnabled = true
            }
        }
    }
}
