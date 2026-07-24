import Cocoa

protocol SidebarContainerDelegate: AnyObject {
    func sidebarContainer(_ container: SidebarContainerView, didOpenFile url: URL)
    func sidebarContainer(_ container: SidebarContainerView, didRequestDiffFor filePath: String, kind: GitDiffKind)
    func sidebarContainer(_ container: SidebarContainerView, didRequestUncommittedChangesFor repositoryPath: String, focusedFilePath: String?)
    func sidebarContainer(_ container: SidebarContainerView, didRequestOpenFile filePath: String, atLine line: Int, highlighting searchTerm: String?)
    func sidebarContainerTabs(_ container: SidebarContainerView) -> [TabModel]
    func sidebarContainer(_ container: SidebarContainerView, didRequestSwitchToTab index: Int)
    func sidebarContainer(_ container: SidebarContainerView, didRequestConnectCommand command: String)
    /// Repository root for the active tab's pane, or nil when not in a git repo.
    func sidebarContainerActiveRepoRoot(_ container: SidebarContainerView) -> String?
    /// Open or focus a pane sitting in the worktree at `path`.
    func sidebarContainer(_ container: SidebarContainerView, didRequestOpenWorktree path: String)
    /// Create a worktree for `branch`, optionally launching `agent` in its pane.
    func sidebarContainer(_ container: SidebarContainerView, didRequestCreateWorktree branch: String, agent: WorktreeAgent)
    /// Remove the worktree registered for `branch`; `force` overrides the guard.
    func sidebarContainer(_ container: SidebarContainerView, didRequestRemoveWorktree branch: String, force: Bool)
    /// Merge `branch`'s worktree into the repository's primary checkout.
    func sidebarContainer(_ container: SidebarContainerView, didRequestMergeWorktree branch: String)
    /// A worktree row was selected: point the git panel (only) at that checkout.
    func sidebarContainer(_ container: SidebarContainerView, didSelectWorktreeForGitPanel path: String)
}

class SidebarContainerView: NSView {
    weak var delegate: SidebarContainerDelegate?

    private(set) var currentPanel: SidebarPanel = .files
    private var isVisible: Bool = true

    /// Panels are created lazily: each controller — and its FSEvents watcher
    /// (file tree) or git polling — is instantiated only the first time its
    /// panel is actually shown. See `controller(for:)`.
    private var panelControllers: [SidebarPanel: NSViewController] = [:]

    /// State pushed at us before a panel exists is remembered here and applied
    /// when the panel is first created, so a lazily-instantiated file tree /
    /// git / search panel still opens on the right directory and hidden-files
    /// setting.
    private var currentPath: String?
    /// A transient git-panel-only repository override set by selecting a worktree
    /// row. It repoints just the git panel (not the file tree/search), and is
    /// cleared on the next `updateFileTree` (tab switch / cwd change) so the panel
    /// reverts to tracking the active tab, as before.
    private var gitPanelOverridePath: String?
    private var showHiddenFiles: Bool = false

    private let headerHeight: CGFloat = 32
    private var headerView: NSView!
    private var titleLabel: NSTextField!
    private var contentView: NSView!
    private var themeObserver: ThemeObserver?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        wantsLayer = true
        applyBackground(enableBlur: true) // Default to blur enabled

        // Seed the hidden-files setting from config up front so a lazily-created
        // file tree agrees with the user's preference even before
        // applyRuntimeConfig (the only caller of setShowHiddenFiles) runs — it
        // isn't invoked at startup.
        showHiddenFiles = Config.load().editor?.showHiddenFiles ?? false

        setupHeader()
        setupContent()
        // Panels are instantiated lazily on first show (see controller(for:)),
        // so nothing here spins up the file-tree watcher or git polling. The
        // current panel is materialized when the sidebar first becomes visible.

        themeObserver = ThemeObserver { [weak self] in self?.applyThemeColors() }
    }

    private func applyThemeColors() {
        applyBackground(enableBlur: true)
        titleLabel?.textColor = AppTheme.primaryText
    }

    private func setupHeader() {
        headerView = NSView()
        headerView.wantsLayer = true
        headerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerView)

        titleLabel = NSTextField(labelWithString: "FILES")
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = AppTheme.primaryText
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(titleLabel)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: topAnchor),
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: headerHeight),

            titleLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 12)
        ])
    }

    private func setupContent() {
        contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)

        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    func applyBackground(enableBlur: Bool) {
        // Sidebar is always opaque (no blur)
        layer?.backgroundColor = AppTheme.sidebarBackground.cgColor
        headerView?.layer?.backgroundColor = AppTheme.headerBackground.cgColor
    }

    /// Returns the controller for `panel`, creating it (and starting its
    /// watchers / polling) the first time it's needed, then caching it.
    private func controller(for panel: SidebarPanel) -> NSViewController {
        if let existing = panelControllers[panel] { return existing }
        let created = makeController(for: panel)
        panelControllers[panel] = created
        return created
    }

    /// Builds a panel controller and seeds it with the current cross-panel
    /// state (directory, hidden-files) that was pushed before it existed.
    private func makeController(for panel: SidebarPanel) -> NSViewController {
        switch panel {
        case .files:
            let fileTreeVC = FileTreeViewController()
            fileTreeVC.delegate = self
            // Seed the hidden-files setting and (if known) the project directory
            // before the view loads. setShowHidden just records the flag here
            // (no tree yet); loadFileTree is deferred until viewDidLoad, which
            // then honors this seeded directory instead of defaulting to home.
            fileTreeVC.setShowHidden(showHiddenFiles)
            if let currentPath { fileTreeVC.loadFileTree(for: currentPath) }
            return fileTreeVC
        case .git:
            let gitPanelVC = GitPanelViewController()
            gitPanelVC.delegate = self
            // A pending worktree-selection override wins over the active tab's
            // path so a panel created after the selection opens on that checkout.
            if let path = gitPanelOverridePath ?? currentPath { gitPanelVC.setRepositoryPath(path) }
            return gitPanelVC
        case .search:
            let searchPanelVC = SearchPanelViewController()
            searchPanelVC.delegate = self
            if let currentPath { searchPanelVC.updateWorkingDirectory(currentPath) }
            return searchPanelVC
        case .worktrees:
            let worktreesVC = WorktreesPanelViewController()
            worktreesVC.delegate = self
            return worktreesVC
        case .agents:
            let agentDashboardVC = AgentDashboardViewController()
            agentDashboardVC.delegate = self
            return agentDashboardVC
        case .hosts:
            let hostsPanelVC = HostsPanelViewController()
            hostsPanelVC.delegate = self
            return hostsPanelVC
        }
    }

    func showPanel(_ panel: SidebarPanel) {
        // Hide the current panel's view (only if it was ever created).
        panelControllers[currentPanel]?.view.removeFromSuperview()

        // Show new panel, creating its controller lazily on first show.
        currentPanel = panel
        titleLabel.stringValue = panel.rawValue.uppercased()

        let newView = controller(for: panel).view
        contentView.addSubview(newView)
        newView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            newView.topAnchor.constraint(equalTo: contentView.topAnchor),
            newView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            newView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            newView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        if panel == .search {
            (panelControllers[.search] as? SearchPanelViewController)?.focusSearchField()
        }

        if panel == .agents {
            (panelControllers[.agents] as? AgentDashboardViewController)?.reload()
        }

        if panel == .worktrees {
            (panelControllers[.worktrees] as? WorktreesPanelViewController)?.reload()
        }
    }

    /// Refreshes the agents panel (if instantiated) so its highlighted row
    /// tracks the active tab. Called when the active tab changes.
    func refreshAgents() {
        (panelControllers[.agents] as? AgentDashboardViewController)?.reload()
    }

    func toggleVisibility() {
        setVisible(!isVisible)
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        isHidden = !visible
        // Unhiding the sidebar without an explicit showPanel (e.g. toggleSidebar)
        // must still mount a panel — materialize the current one on demand so it
        // isn't blank the first time it's revealed.
        if visible, panelControllers[currentPanel]?.view.superview == nil {
            showPanel(currentPanel)
        }
    }

    var visible: Bool {
        return isVisible && !isHidden
    }

    func updateFileTree(path: String) {
        // Remember the directory so a not-yet-created files/git/search panel
        // opens on it when first shown.
        currentPath = path
        // A tab switch / cwd change repoints the git panel as normal, so the
        // transient worktree-selection override no longer applies.
        gitPanelOverridePath = nil

        if let fileTreeVC = panelControllers[.files] as? FileTreeViewController {
            fileTreeVC.loadFileTree(for: path)
        }

        // Also update git panel if it exists
        if let gitPanelVC = panelControllers[.git] as? GitPanelViewController {
            gitPanelVC.setRepositoryPath(path)
        }

        // Update search panel working directory
        if let searchPanelVC = panelControllers[.search] as? SearchPanelViewController {
            searchPanelVC.updateWorkingDirectory(path)
        }
    }

    func toggleHiddenFiles() {
        setShowHiddenFiles(!showHiddenFiles)
    }

    func setShowHiddenFiles(_ show: Bool) {
        // Track it so a lazily-created file tree is built with the right
        // visibility even if this arrives before the panel exists.
        showHiddenFiles = show
        if let fileTreeVC = panelControllers[.files] as? FileTreeViewController {
            fileTreeVC.setShowHidden(show)
        }
    }

    func refreshFileTree() {
        if let fileTreeVC = panelControllers[.files] as? FileTreeViewController {
            fileTreeVC.refresh()
        }
    }

    /// Points the git panel (only — not the file tree or search) at `path`,
    /// e.g. after a worktree row is selected. If the git panel isn't
    /// instantiated yet, the override is remembered so it opens on this checkout
    /// when first shown. Transient: cleared by the next `updateFileTree`.
    func retargetGitPanel(toRepositoryPath path: String) {
        gitPanelOverridePath = path
        (panelControllers[.git] as? GitPanelViewController)?.setRepositoryPath(path)
    }

    /// Re-list worktrees after a create/remove completes, so the row appears or
    /// disappears without waiting for the next refresh trigger.
    func refreshWorktrees() {
        (panelControllers[.worktrees] as? WorktreesPanelViewController)?.reload()
    }

    func revealFile(_ url: URL) {
        (panelControllers[.files] as? FileTreeViewController)?.revealFile(url)
    }

    func clearFileSelection() {
        (panelControllers[.files] as? FileTreeViewController)?.clearSelection()
    }

    /// Test hook: the set of panels whose controllers have been instantiated so
    /// far. Lets a unit test assert lazy creation without exposing the cache.
    var _instantiatedPanels: Set<SidebarPanel> { Set(panelControllers.keys) }
}

extension SidebarContainerView: AgentDashboardDelegate {
    func agentDashboardTabs(_ dashboard: AgentDashboardViewController) -> [TabModel] {
        delegate?.sidebarContainerTabs(self) ?? []
    }

    func agentDashboard(_ dashboard: AgentDashboardViewController, didSelectTabAt index: Int) {
        delegate?.sidebarContainer(self, didRequestSwitchToTab: index)
    }
}

extension SidebarContainerView: WorktreesPanelDelegate {
    func worktreesPanelActiveRepoRoot(_ panel: WorktreesPanelViewController) -> String? {
        delegate?.sidebarContainerActiveRepoRoot(self)
    }

    func worktreesPanelTabs(_ panel: WorktreesPanelViewController) -> [TabModel] {
        delegate?.sidebarContainerTabs(self) ?? []
    }

    func worktreesPanel(_ panel: WorktreesPanelViewController, didRequestOpenWorktree path: String) {
        delegate?.sidebarContainer(self, didRequestOpenWorktree: path)
    }

    func worktreesPanel(_ panel: WorktreesPanelViewController, didRequestDiffForWorktree path: String) {
        // A worktree's diff is just its uncommitted-changes view, keyed by the
        // checkout path — reuse the existing route.
        delegate?.sidebarContainer(self, didRequestUncommittedChangesFor: path, focusedFilePath: nil)
    }

    func worktreesPanel(_ panel: WorktreesPanelViewController, didRequestCreateBranch branch: String, agent: WorktreeAgent) {
        delegate?.sidebarContainer(self, didRequestCreateWorktree: branch, agent: agent)
    }

    func worktreesPanel(_ panel: WorktreesPanelViewController, didRequestRemoveBranch branch: String, force: Bool) {
        delegate?.sidebarContainer(self, didRequestRemoveWorktree: branch, force: force)
    }

    func worktreesPanel(_ panel: WorktreesPanelViewController, didRequestMergeBranch branch: String) {
        delegate?.sidebarContainer(self, didRequestMergeWorktree: branch)
    }

    func worktreesPanel(_ panel: WorktreesPanelViewController, didSelectWorktree path: String) {
        delegate?.sidebarContainer(self, didSelectWorktreeForGitPanel: path)
    }
}

extension SidebarContainerView: HostsPanelDelegate {
    func hostsPanel(_ panel: HostsPanelViewController, didRequestConnectCommand command: String) {
        delegate?.sidebarContainer(self, didRequestConnectCommand: command)
    }
}

extension SidebarContainerView: FileTreeDelegate {
    func fileTree(_ fileTree: FileTreeViewController, didSelectFile url: URL) {
        // File selected but not opened
    }

    func fileTree(_ fileTree: FileTreeViewController, didOpenFile url: URL) {
        delegate?.sidebarContainer(self, didOpenFile: url)
    }
}

extension SidebarContainerView: GitPanelDelegate {
    func gitPanel(_ panel: GitPanelViewController, didRequestDiffFor filePath: String, kind: GitDiffKind) {
        delegate?.sidebarContainer(self, didRequestDiffFor: filePath, kind: kind)
    }

    func gitPanel(_ panel: GitPanelViewController, didRequestUncommittedChangesFor repositoryPath: String, focusedFilePath: String?) {
        delegate?.sidebarContainer(
            self,
            didRequestUncommittedChangesFor: repositoryPath,
            focusedFilePath: focusedFilePath
        )
    }
}

extension SidebarContainerView: SearchPanelDelegate {
    func searchPanel(_ panel: SearchPanelViewController, didRequestOpenFile filePath: String, atLine line: Int, highlighting searchTerm: String) {
        delegate?.sidebarContainer(self, didRequestOpenFile: filePath, atLine: line, highlighting: searchTerm)
    }
}
