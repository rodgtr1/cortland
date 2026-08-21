import AppKit
import CortlandTelemetryCore

/// The slice of the window controller `TabController` needs to host tabs: the
/// content area a tab's split-controller view is pinned into, the live config
/// for building new terminals/panes, and a handful of UI-refresh callbacks for
/// chrome that stays on MainWindowController (the tab bar, sidebar, agent
/// badge). MainWindowController stays the source of truth for window chrome;
/// `TabController` owns the tab/pane tree behind this seam, so the tab
/// lifecycle and session persistence can live outside the 1,700-line controller.
protocol TabHost: AnyObject {
    /// The content area a tab's split-controller view is pinned into.
    var tabContentView: NSView { get }
    /// Current config, read fresh so a live `[config]` reload reaches new panes.
    var tabConfig: Config { get }

    /// Repaint the tab bar after the tab set or active index changes.
    func reloadTabBar()
    /// Re-point the sidebar at the active tab's directory after a switch/restore.
    func syncSidebarToActiveTab()
    /// Refresh the activity-bar "agents waiting" badge after a close.
    func refreshAgentsBadge()
    /// Point the sidebar file tree at `path` (a pane reported its directory).
    func updateSidebarDirectory(_ path: String)
    /// Confirm a mouse-driven close of `panes` (a pane's X) before they're torn
    /// down; false vetoes it. Sessions don't prompt here, unsaved editors do.
    func confirmMouseClose(target: String, panes: [PaneModel]) -> Bool
}

/// Owns the tab collection and its lifecycle — create / install / switch /
/// close / reorder, active-tab tracking, the per-tab `PaneSplitController`
/// hierarchy, and session save & restore. Also the `PaneSplitControllerDelegate`,
/// since it owns those controllers. Extracted from MainWindowController — see
/// `TabHost` for the seam back to it for window chrome.
final class TabController: NSObject {
    private weak var host: TabHost?

    /// All open tabs, in order. The active one is `tabs[activeTabIndex]`.
    private(set) var tabs: [TabModel] = []
    private(set) var activeTabIndex: Int = 0
    /// The split controller for the tab currently in the content view. Only the
    /// active tab's controller lives in the hierarchy at once.
    private(set) var currentSplitController: PaneSplitController?
    /// Maps tab IDs to their split controllers. Inactive tabs keep their
    /// controller (and its panes) alive here for re-attachment on the next switch.
    private var tabSplitControllers: [UUID: PaneSplitController] = [:]

    /// Last session state written, to skip identical autosave writes.
    private var lastSavedSession: SessionState?

    init(host: TabHost) {
        self.host = host
        super.init()
    }

    /// The active tab, or nil if there are none.
    var activeTab: TabModel? { tabs[safe: activeTabIndex] }

    /// The split controller for `id`, alive whether or not the tab is on screen.
    func splitController(forTab id: UUID) -> PaneSplitController? {
        tabSplitControllers[id]
    }

    private var config: Config { host?.tabConfig ?? Config.load() }

    // MARK: - Initial tab / new tabs

    /// At launch: restore the saved session when enabled, else open one tab.
    func restoreOrCreateInitialTab() {
        if config.behavior.restoreSession, let session = SessionStore.load() {
            restoreSession(session)
        } else {
            createNewTab()
        }
    }

    @discardableResult
    func createNewTab(workingDirectory: String? = nil, command: [String]? = nil) -> Bool {
        let startDirectory = workingDirectory ?? currentWorkingDirectoryForNewTerminal()

        let tab = TabModel()
        if let firstPane = tab.panes.first {
            firstPane.createTerminalViewController(config: config, initialDirectory: startDirectory, command: command)
        }

        return installTab(tab)
    }

    /// Shared plumbing for adding a fully-built tab: detaches the current tab,
    /// inserts the new one just after the active tab, activates it, and installs
    /// its split controller into the content view. Used by new-tab, session
    /// restore, and single-pane (diff/changes) tabs so they can't drift apart.
    /// (Restore installs tabs one at a time with each becoming active, so
    /// insert-after-active preserves the saved order there.)
    ///
    /// Returns false when the tab cap refuses the tab, so callers can surface
    /// the failure (IPC must not report ok on a tab that never opened).
    @discardableResult
    func installTab(_ tab: TabModel) -> Bool {
        // Enforce the tab cap on every live creation path, not just restore.
        // The tab's panes may already have spawned shells, so tear them down
        // rather than leak them (mirrors closeTab's shutdown).
        guard tabs.count < Limits.maxTabs else {
            Log.error("⚠️ Tab limit (\(Limits.maxTabs)) reached; not opening another tab", category: "app")
            NSSound.beep()
            for pane in tab.panes {
                pane.shutdown()
            }
            return false
        }

        if let currentController = currentSplitController {
            detachController(currentController)
        }
        if let activeTab = tabs[safe: activeTabIndex] {
            activeTab.isActive = false
        }

        tab.isActive = true
        let insertIndex = tabs.isEmpty ? 0 : min(activeTabIndex + 1, tabs.count)
        tabs.insert(tab, at: insertIndex)
        activeTabIndex = insertIndex

        let paneSplitController = PaneSplitController(config: config)
        paneSplitController.delegate = self
        currentSplitController = paneSplitController
        tabSplitControllers[tab.id] = paneSplitController

        attachController(paneSplitController)
        paneSplitController.rebuildSplitView(for: tab)

        host?.reloadTabBar()
        return true
    }

    /// The directory a new terminal should start in: the active pane's working
    /// directory, else the first sibling pane that has one.
    func currentWorkingDirectoryForNewTerminal() -> String? {
        guard let activeTab = tabs[safe: activeTabIndex] else { return nil }

        if let activePaneDirectory = activeTab.activePane?.resolvedWorkingDirectory() {
            return activePaneDirectory
        }

        return activeTab.panes.compactMap { $0.resolvedWorkingDirectory() }.first
    }

    // MARK: - Switch / close / reorder

    func switchToTab(index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        guard index != activeTabIndex else { return } // Already on this tab

        Log.debug("🔄 Switching from tab \(activeTabIndex) to tab \(index)", category: "app")

        // Detach current tab's split controller
        if let currentController = currentSplitController {
            detachController(currentController)
        }

        // Update active state
        tabs[activeTabIndex].isActive = false
        activeTabIndex = index
        tabs[activeTabIndex].isActive = true

        // Attach the split controller for the new tab
        let newTab = tabs[index]
        // The user is now looking at this tab's active pane: drop any
        // failed-command attention mark on it.
        newTab.activePane?.setFailedCommandAttention(false)
        if let newController = tabSplitControllers[newTab.id] {
            currentSplitController = newController
            attachController(newController)
            refreshEditorsOnShow(for: newTab)
            restoreFocus(for: newTab)
        } else {
            Log.error("⚠️ No split controller found for tab \(index)", category: "app")
        }

        host?.reloadTabBar()
        host?.syncSidebarToActiveTab()
    }

    func closeCurrentTab() {
        closeTab(index: activeTabIndex)
    }

    func closeTab(index: Int) {
        guard index >= 0 && index < tabs.count && tabs.count > 1 else { return }

        let tabToClose = tabs[index]

        // Capture this tab's spend before it's dropped: the termination roll-up
        // only sees tabs still open, so a closed agent's cost would be lost.
        let costs = Self.tabCosts(for: tabToClose)
        if !costs.isEmpty {
            SessionCostStore.append(SessionCostRecord(timestamp: Date(), tabs: costs))
        }

        // Kill every pane's shell before the models are dropped; nothing else
        // terminates them and orphaned shells outlive the tab otherwise.
        for pane in tabToClose.panes {
            pane.shutdown()
        }

        // Remove and cleanup the split controller for this tab
        if let controller = tabSplitControllers[tabToClose.id] {
            controller.view.removeFromSuperview()
            tabSplitControllers.removeValue(forKey: tabToClose.id)
        }

        tabs.remove(at: index)

        // Adjust active index
        if activeTabIndex >= tabs.count {
            activeTabIndex = tabs.count - 1
        } else if activeTabIndex > index {
            activeTabIndex -= 1
        }

        // Switch to the new active tab. Closing the active tab drops the only
        // tab whose isActive was true, so mark the survivor active — otherwise
        // no tab is active and the agents dashboard loses its row highlight
        // until the user switches tabs by hand.
        tabs[activeTabIndex].isActive = true
        let newTab = tabs[activeTabIndex]
        // The survivor is now the viewed tab; clear its active pane's mark.
        newTab.activePane?.setFailedCommandAttention(false)
        if let newController = tabSplitControllers[newTab.id] {
            currentSplitController = newController
            attachController(newController)
            refreshEditorsOnShow(for: newTab)
            restoreFocus(for: newTab)
        }

        host?.reloadTabBar()
        host?.syncSidebarToActiveTab()
        host?.refreshAgentsBadge()
    }

    func moveTab(from fromIndex: Int, to toIndex: Int) {
        guard fromIndex != toIndex,
              fromIndex >= 0, fromIndex < tabs.count,
              toIndex >= 0, toIndex < tabs.count else {
            host?.reloadTabBar()
            return
        }

        let activeTab = tabs[safe: activeTabIndex]
        let tab = tabs.remove(at: fromIndex)
        tabs.insert(tab, at: toIndex)

        if let activeTab = activeTab, let newActiveIndex = tabs.firstIndex(where: { $0.id == activeTab.id }) {
            activeTabIndex = newActiveIndex
        }
        host?.reloadTabBar()
    }

    // MARK: - Content-view attach/detach

    /// Adds a tab's split controller view into the content area, pinned to all
    /// edges. Only the active tab's controller lives in the hierarchy at once,
    /// so hidden tabs can't receive clicks, hit-tests, or relayout work.
    private func attachController(_ controller: PaneSplitController) {
        guard let contentView = host?.tabContentView else { return }
        guard controller.view.superview !== contentView else { return }
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: contentView.topAnchor),
            controller.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            controller.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    /// Removes an inactive tab's view from the hierarchy (its constraints to the
    /// content view go with it). The controller and its panes stay alive in
    /// `tabSplitControllers` for re-attachment on the next switch.
    private func detachController(_ controller: PaneSplitController) {
        controller.view.removeFromSuperview()
    }

    /// Restores first responder to the shown tab's active pane after a switch,
    /// since detaching the previous tab's view drops the window's responder.
    private func restoreFocus(for tab: TabModel) {
        DispatchQueue.main.async {
            tab.activePane?.focus()
        }
    }

    /// After a tab's view is re-attached, its editors need to regenerate their
    /// glyph layout — NSTextView leaves them blank otherwise. Deferred to the
    /// next runloop so the view has its restored frame before we lay out.
    private func refreshEditorsOnShow(for tab: TabModel) {
        DispatchQueue.main.async {
            for pane in tab.panes {
                pane.editorViewController?.refreshLayout()
            }
        }
    }

    // MARK: - Session save / restore

    func saveSession() {
        guard !tabs.isEmpty else { return }

        let tabStates: [SessionTabState] = tabs.map { tab in
            let panes: [SessionPaneState] = tab.panes.compactMap { pane in
                switch pane.paneType {
                case .terminal:
                    return SessionPaneState(
                        type: "terminal",
                        cwd: pane.resolvedWorkingDirectory(),
                        url: nil
                    )
                case .editor, .diff, .uncommittedChanges:
                    // Transient views; don't recreate them on relaunch.
                    return nil
                }
            }
            return SessionTabState(
                panes: panes,
                activePaneIndex: min(tab.activePaneIndex, max(panes.count - 1, 0)),
                customTitle: tab.customTitle
            )
        }

        let state = SessionState(tabs: tabStates, activeTabIndex: activeTabIndex)
        guard state != lastSavedSession else { return }
        lastSavedSession = state
        SessionStore.save(state)
    }

    // MARK: - Session cost history

    /// A tab's telemetry as cost entries — one per billed pane, each priced at
    /// its own model (a split tab can run different models side by side), with
    /// pane-suffixed titles when there's more than one. Empty when the tab
    /// never billed a turn. Falls back to the tab-level primary usage for a
    /// tab whose per-pane list hasn't populated.
    private static func tabCosts(for tab: TabModel) -> [SessionTabCost] {
        let billed = tab.paneTelemetries.filter { $0.usage.assistantResponses > 0 }
        guard !billed.isEmpty else {
            guard let usage = tab.telemetry, usage.assistantResponses > 0 else { return [] }
            return [SessionTabCost(
                title: tab.title,
                model: usage.model,
                tokens: usage.totalTokens,
                costUSD: tab.telemetryCostUSD
            )]
        }
        return billed.map { pane in
            var title = tab.title
            if billed.count > 1, let index = tab.panes.firstIndex(where: { $0.id == pane.paneID }) {
                title += " · pane \(index + 1)"
            }
            return SessionTabCost(
                title: title,
                model: pane.usage.model,
                tokens: pane.usage.totalTokens,
                costUSD: pane.costUSD
            )
        }
    }

    /// Appends one cost record covering every still-open tab that billed
    /// telemetry this session. Called at app termination; a no-op when nothing
    /// billed.
    func recordSessionCosts() {
        let entries = tabs.flatMap(Self.tabCosts(for:))
        guard !entries.isEmpty else { return }
        SessionCostStore.append(SessionCostRecord(timestamp: Date(), tabs: entries))
    }

    private func restoreSession(_ session: SessionState) {
        let restorable = session.tabs.filter { !$0.panes.isEmpty }
        guard !restorable.isEmpty else {
            createNewTab()
            return
        }

        Log.debug("📦 Restoring session with \(restorable.count) tab(s)", category: "app")
        for tabState in restorable.prefix(Limits.maxTabs) {
            restoreTab(from: tabState)
        }

        // activeTabIndex was saved against the full tab list, but editor-only
        // tabs serialize to empty panes and are filtered out above — which
        // shifts every later index down. Map the saved index onto the restored
        // (filtered) list so we activate the tab the user actually left active.
        let restorableActiveIndex: Int
        if session.tabs.indices.contains(session.activeTabIndex),
           !session.tabs[session.activeTabIndex].panes.isEmpty {
            restorableActiveIndex = session.tabs[..<session.activeTabIndex].filter { !$0.panes.isEmpty }.count
        } else {
            restorableActiveIndex = 0
        }
        let targetIndex = min(max(0, restorableActiveIndex), tabs.count - 1)
        if targetIndex != activeTabIndex {
            switchToTab(index: targetIndex)
        }
        // Point the sidebar at the restored tab's directory right away.
        host?.syncSidebarToActiveTab()
    }

    private func restoreTab(from state: SessionTabState) {
        let tab = TabModel()
        tab.panes.removeAll()
        tab.customTitle = state.customTitle

        for paneState in state.panes.prefix(Limits.maxPanesPerTab) {
            let pane = PaneModel()
            // Only trust a restored cwd that still exists and is a directory;
            // otherwise fall back to the default start directory.
            pane.createTerminalViewController(config: config, initialDirectory: Self.validatedRestoredDirectory(paneState.cwd))
            tab.panes.append(pane)
        }
        tab.activePaneIndex = min(max(0, state.activePaneIndex), tab.panes.count - 1)
        tab.updateTitleFromActivePane()

        installTab(tab)
    }

    /// A restored cwd is only trusted when it still exists and is a directory;
    /// otherwise we return nil so the terminal falls back to the default start
    /// directory. Guards against a tampered/stale session.json launching a pane
    /// at an arbitrary path.
    static func validatedRestoredDirectory(_ path: String?) -> String? {
        guard let path, path.hasPrefix("/") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return path
    }
}

// MARK: - PaneSplitControllerDelegate

extension TabController: PaneSplitControllerDelegate {
    func paneSplitController(_ controller: PaneSplitController, didAddPane pane: PaneModel, at index: Int) {
        guard let tab = tabs.first(where: { tabSplitControllers[$0.id] === controller }) else { return }

        if !tab.panes.contains(where: { $0.id == pane.id }) {
            tab.panes.append(pane)
        }
        host?.reloadTabBar()
    }

    func paneSplitController(_ controller: PaneSplitController, didActivatePane pane: PaneModel, at index: Int) {
        guard let tabIndex = tabs.firstIndex(where: { tabSplitControllers[$0.id] === controller }) else { return }
        let tab = tabs[tabIndex]

        tab.activePaneIndex = index
        // The user just brought this pane forward: acknowledge any failed-command
        // attention on it. (switchToTab clears too, but only fires on a tab
        // change, not on selecting a sibling pane within the current tab.)
        pane.setFailedCommandAttention(false)
        if tabIndex != activeTabIndex {
            switchToTab(index: tabIndex)
        }
        if let directory = pane.resolvedWorkingDirectory() {
            host?.updateSidebarDirectory(directory)
        }
    }

    func paneSplitController(_ controller: PaneSplitController, shouldClosePane pane: PaneModel) -> Bool {
        host?.confirmMouseClose(target: "pane", panes: [pane]) ?? true
    }

    func paneSplitController(_ controller: PaneSplitController, didClosePane pane: PaneModel, at index: Int) {
        guard let tab = tabs.first(where: { tabSplitControllers[$0.id] === controller }) else { return }

        pane.shutdown()

        if index < tab.panes.count, tab.panes[index].id == pane.id {
            tab.panes.remove(at: index)
        } else if let paneIndex = tab.panes.firstIndex(of: pane) {
            tab.panes.remove(at: paneIndex)
        }

        if tab.activePaneIndex >= tab.panes.count {
            tab.activePaneIndex = max(tab.panes.count - 1, 0)
        } else if tab.activePaneIndex > index {
            tab.activePaneIndex -= 1
        }

        tab.updateTitleFromActivePane()
        tab.updateAgentStateFromPanes()
        // Re-aggregate dirty state now that the pane is gone: the
        // notification-based aggregation can't fire for a closed pane (it's
        // already out of tab.panes), so closing the only modified editor
        // would otherwise leave the dirty dot lit forever.
        tab.isDirty = tab.panes.contains { $0.editorViewController?.isModified == true }
        host?.reloadTabBar()
    }
}
