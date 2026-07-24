import Cocoa
import SwiftTerm
import CortlandProInterface
// UserNotifications isn't Sendable-audited for strict concurrency yet, so import
// it @preconcurrency to downgrade its cross-actor Sendable diagnostics (e.g.
// capturing UNUserNotificationCenter in the authorization completion handler).
@preconcurrency import UserNotifications
import CortlandTelemetryCore

@_silgen_name("CGSDefaultConnectionForThread")
private func CGSDefaultConnectionForThread() -> UnsafeMutableRawPointer?

@_silgen_name("CGSSetWindowBackgroundBlurRadius")
private func CGSSetWindowBackgroundBlurRadius(
    _ connection: UnsafeMutableRawPointer?,
    _ windowNumber: Int,
    _ radius: Int32
) -> Int32

private final class MainWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown,
           event.clickCount == 2,
           isInTitlebarDoubleClickRegion(event.locationInWindow) {
            performConfiguredTitlebarDoubleClickAction()
            return
        }

        super.sendEvent(event)
    }

    private func isInTitlebarDoubleClickRegion(_ location: NSPoint) -> Bool {
        guard let contentView = contentView else { return false }

        if isPointOverStandardWindowButton(location) {
            return false
        }

        let titlebarHeight = contentView.safeAreaInsets.top
        guard titlebarHeight > 0 else { return false }

        let titlebarMinY = contentView.frame.maxY - titlebarHeight
        return location.y >= titlebarMinY && location.y <= contentView.frame.maxY
    }

    private func isPointOverStandardWindowButton(_ location: NSPoint) -> Bool {
        let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

        return buttonTypes.contains { buttonType in
            guard let button = standardWindowButton(buttonType), !button.isHidden else {
                return false
            }

            let buttonFrame = button.convert(button.bounds, to: nil).insetBy(dx: -8, dy: -8)
            return buttonFrame.contains(location)
        }
    }
}

extension NSWindow {
    func performConfiguredTitlebarDoubleClickAction() {
        if let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")?.lowercased() {
            switch action {
            case "minimize":
                if styleMask.contains(.miniaturizable) {
                    performMiniaturize(nil)
                }
            case "none":
                break
            default:
                if styleMask.contains(.resizable) {
                    performZoom(nil)
                }
            }
            return
        }

        if UserDefaults.standard.object(forKey: "AppleMiniaturizeOnDoubleClick") != nil,
           UserDefaults.standard.bool(forKey: "AppleMiniaturizeOnDoubleClick"),
           styleMask.contains(.miniaturizable) {
            performMiniaturize(nil)
            return
        }

        if styleMask.contains(.resizable) {
            performZoom(nil)
        }
    }
}

private final class TitlebarBackgroundView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.performConfiguredTitlebarDoubleClickAction()
            return
        }

        window?.performDrag(with: event)
    }

    func applyTheme() {
        layer?.backgroundColor = Theme.shared.current.windowBackground.cgColor
        layer?.isOpaque = true
    }

    private func setupView() {
        wantsLayer = true
        applyTheme()
    }
}

class MainWindowController: NSWindowController {
    private static let sidebarWidthDefaultsKey = "sidebarWidth"
    // Cheap in-memory defaults just to satisfy the stored-property requirement;
    // `convenience init()` immediately overwrites this with the real Config.load()
    // result. (Initializing with Config.load() here would parse config.toml from
    // disk twice at startup and throw the first read away.)
    private var config: Config = Config()
    private var titlebarBackgroundView: TitlebarBackgroundView!
    /// Retained so ⌘K reuses one panel instead of stacking duplicates.
    private var keyboardShortcutsPanel: KeyboardShortcutsPanel?
    private var tabBarSpacerView: TitlebarBackgroundView!
    private var tabBarView: TabBarView!
    private var activityBarView: ActivityBarView!
    private var sidebarContainerView: SidebarContainerView!
    private var mainContentView: NSView!
    private var sidebarWidthConstraint: NSLayoutConstraint!
    private var sidebarResizeHandle: SidebarResizeHandle!
    private var sidebarPreferredWidth: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: MainWindowController.sidebarWidthDefaultsKey)
        return saved > 0 ? CGFloat(saved) : 240
    }()
    /// Owns the tab/pane tree, the per-tab split controllers, the tab lifecycle,
    /// and session save/restore. MWC reads it through the forwarders below and
    /// drives it for create/switch/close.
    private var tabController: TabController!
    private var tabs: [TabModel] { tabController.tabs }
    private var activeTabIndex: Int { tabController.activeTabIndex }
    private var currentPaneSplitController: PaneSplitController? { tabController.currentSplitController }
    private var quickOpenPanel: QuickOpenPanel?
    /// Retained so ⌃⇧S reuses one Session Recall panel instead of stacking
    /// duplicates, mirroring `quickOpenPanel`.
    private var sessionsPanel: SessionsPanel?
    private var preferencesWindowController: PreferencesWindowController?
    // Set on the main actor; removed in the nonisolated deinit at end-of-life.
    nonisolated(unsafe) private var keyEventMonitor: Any?
    nonisolated(unsafe) private var clickEventMonitor: Any?
    /// The last URL handed to the browser and when, so a single ⌘+click that
    /// two code paths both react to (SwiftTerm's own link handler and the shared
    /// mouse-up monitor) opens one tab, not two. Same URL inside the window is
    /// treated as the echo and dropped.
    private var lastOpenedURL: (url: URL, at: Date)?
    private let keyboardCommandRouter = KeyboardCommandRouter()
    /// Owns the ⇧⌘P palette and the keyboard-command dispatch table; drives the
    /// behaviors back through the `PaletteCommandHost` conformance below.
    private var paletteCommandRegistry: PaletteCommandRegistry!
    /// Owns the worktrees-panel create/remove/open flows; the
    /// `SidebarContainerDelegate` worktree methods forward here.
    private var worktreeFlowController: WorktreeFlowController!
    private let configWatcher = ConfigWatcher()
    private var sessionSaveTimer: Timer?
    /// Owns IPC command translation and the hook diff-approval queue.
    private var automationCoordinator: AutomationCoordinator!
    /// Mirrors pane attention events to native macOS notifications (opt-in).
    private var notificationCoordinator: NotificationCoordinator!
    /// Per-session "auto-approve agent edits" toggle (menu-driven). Layered on
    /// top of the `[approval]` config mode; resets on relaunch.
    private var sessionAutoApproveEdits = false

    convenience init() {
        Log.debug("🏗️ Creating MainWindowController...", category: "app")

        let config = Config.load()
        Theme.shared.loadFromConfig(config)
        Log.debug("✅ Config loaded", category: "app")

        let window = MainWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        Log.debug("✅ NSWindow created", category: "app")

        window.title = "Cortland"
        window.setFrameAutosaveName("MainWindow")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 1.0
        window.hasShadow = true

        // Make window movable by background
        window.isMovableByWindowBackground = true

        // Restore the frame saved under the autosave name; only center on the
        // very first launch, when there's nothing to restore. (setFrameUsingName
        // returns false when no saved frame exists.)
        if !window.setFrameUsingName("MainWindow") {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        Log.debug("✅ Window configured", category: "app")

        self.init(window: window)
        self.config = config
        self.tabController = TabController(host: self)
        self.paletteCommandRegistry = PaletteCommandRegistry(host: self)
        self.worktreeFlowController = WorktreeFlowController(host: self)
        Log.debug("✅ WindowController initialized", category: "app")

        // Must run before setupUI(): pane environments snapshot AgentApprovalState
        // at spawn, and setupUI creates the initial tab. Synced any later, the
        // first pane launches agents without the approval flags (manual mode)
        // while every subsequent pane gets them.
        syncAgentAutoApprove()

        setupUI()
        Log.debug("✅ UI setup completed", category: "app")

        setupIPC()
        Log.debug("✅ IPC server started", category: "app")

        notificationCoordinator = NotificationCoordinator(
            host: self,
            config: config.notifications ?? NotificationsConfig()
        )

        setupConfigWatcher()
        setupSessionPersistence()
    }

    /// Reflects the effective auto-approve preference into each installed agent's
    /// own permission system so agents launched in panes stop prompting. Per-agent
    /// and best-effort — only affects future launches, so failures are logged, not
    /// surfaced. Called at launch (which also reverts a stale value left by last
    /// session's menu toggle) and whenever the state changes.
    private func syncAgentAutoApprove() {
        var resolvedMode = ApprovalMode(configValue: effectiveApprovalMode)
        AgentApprovalState.mode = resolvedMode
        do {
            try AgentApprovalState.persistMode()
        } catch {
            // A stale permissive snapshot must never widen the direct-worker
            // path after a failed downgrade. persistMode fail-closes the file
            // before replacement; mirror that choice in process memory.
            resolvedMode = .ask
            AgentApprovalState.mode = .ask
            Log.error("Failed to persist agent approval mode; falling back to ask: \(error)", category: "app")
        }
        let mode = resolvedMode.rawValue
        // Scope Claude's permission mode to Cortland-launched sessions instead of
        // writing it into global settings: record the live value for new panes and
        // migrate away any managed defaultMode an older build left machine-wide.
        AgentApprovalState.claudePermissionMode =
            AgentIntegrationInstaller.claudePermissionMode(forApprovalMode: mode)
        do {
            try AgentIntegrationInstaller.clearManagedClaudeDefaultMode()
        } catch {
            Log.debug("Failed to clear legacy Claude defaultMode: \(error)", category: "app")
        }
        // Scope Codex's approval/sandbox flags to Cortland-launched sessions the
        // same way (per-session flags, not a global config.toml write), and
        // migrate away any managed keys an older build left machine-wide.
        AgentApprovalState.codexApprovalArgs =
            AgentIntegrationInstaller.codexApprovalFlags(forApprovalMode: mode)
        do {
            try AgentIntegrationInstaller.clearManagedCodexAutoApprove()
        } catch {
            Log.debug("Failed to clear legacy Codex approval keys: \(error)", category: "app")
        }
    }

    /// Effective Cortland approval level (ask/auto/review/bypass):
    /// the persistent `[approval]` mode, but the per-session ⇧⌘A toggle forces
    /// at least "auto" and never downgrades a configured "review" or
    /// "bypass" (both already auto-approve more than the toggle grants).
    private var effectiveApprovalMode: String {
        let configMode = ApprovalMode(configValue: config.approval?.mode ?? "ask")
        if configMode == .bypass || configMode == .review { return configMode.rawValue }
        if sessionAutoApproveEdits { return "auto" }
        return configMode.rawValue
    }

    private func setupConfigWatcher() {
        configWatcher.onChange = { [weak self] in
            guard let self = self else { return }
            Log.debug("🔄 Config file changed on disk, reloading", category: "app")
            let newConfig = Config.load()
            Theme.shared.loadFromConfig(newConfig)
            self.applyRuntimeConfig(newConfig)
        }
        configWatcher.start()
    }

    private func setupSessionPersistence() {
        sessionSaveTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSession() }
        }

        if let window = window {
            // Become the window delegate so windowShouldClose can veto a close
            // that would kill running agents (see the NSWindowDelegate extension).
            window.delegate = self
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowWillClose),
                name: NSWindow.willCloseNotification,
                object: window
            )
        }
    }

    /// Panes whose agent is actively running or waiting on the user — the
    /// states whose work is lost by quitting. Drives the close confirmation.
    private var busyAgentPaneCount: Int {
        tabs.reduce(0) { count, tab in
            count + tab.panes.filter { $0.agentState == .working || $0.agentState == .ready }.count
        }
    }

    /// Editor panes among `panes` holding unsaved edits. Unlike a busy session,
    /// which the user can restart, these are work that only exists in the
    /// buffer — so every close path confirms them (mouse X included) and
    /// `behavior.confirm_close` doesn't gate them.
    private func modifiedEditors(in panes: [PaneModel]) -> [EditorViewController] {
        panes.compactMap { pane in
            guard let editor = pane.editorViewController, editor.isModified else { return nil }
            return editor
        }
    }

    /// Returns true when it is safe to close/quit: nothing would be lost, or the
    /// user confirmed via the alert. Returns false to abort the close. Called
    /// from both windowShouldClose (close button) and applicationShouldTerminate
    /// (⌘Q), so it covers everything every tab holds — busy agents and editor
    /// buffers with unsaved edits alike, in one alert.
    func confirmCloseWithUnsavedWork() -> Bool {
        let editors = modifiedEditors(in: tabs.flatMap(\.panes))
        guard let confirmation = CloseConfirmation.quit(
            busyPaneCount: busyAgentPaneCount,
            modifiedFileNames: editors.map(\.fileName)
        ) else { return true }

        return runConfirmation(confirmation, dirtyEditors: editors)
    }

    /// Confirmation for keyboard-driven closes (⌘W tab, ⇧⌘W pane), so a stray
    /// keystroke can't silently kill sessions. Returns true when the close may
    /// proceed: nothing would be lost, or the user confirmed. `panes` is the set
    /// being closed, so busy agents and unsaved files there get called out.
    private func confirmKeyboardClose(target: String, panes: [PaneModel]) -> Bool {
        confirmClose(target: target, panes: panes, confirmSessionClose: config.behavior.confirmClose)
    }

    /// Confirmation for mouse-driven closes (a pane's or a tab's X). Sessions
    /// stay prompt-free here by design — a click on the X isn't a stray
    /// keystroke — but an unsaved editor buffer still prompts, on this path like
    /// every other.
    func confirmMouseClose(target: String, panes: [PaneModel]) -> Bool {
        confirmClose(target: target, panes: panes, confirmSessionClose: false)
    }

    private func confirmClose(target: String, panes: [PaneModel], confirmSessionClose: Bool) -> Bool {
        let editors = modifiedEditors(in: panes)
        guard let confirmation = CloseConfirmation.close(
            target: target,
            terminalPaneCount: panes.filter { $0.paneType == .terminal }.count,
            busyPaneCount: panes.filter { $0.agentState == .working || $0.agentState == .ready }.count,
            modifiedFileNames: editors.map(\.fileName),
            confirmSessionClose: confirmSessionClose
        ) else { return true }

        return runConfirmation(confirmation, dirtyEditors: editors)
    }

    /// Runs a `CloseConfirmation` as an alert and reports whether the close may
    /// proceed. When there are unsaved buffers the alert leads with Save, which
    /// saves each of them through the editor's own save path (so an
    /// external-change or encoding prompt still applies); a save the user
    /// cancels, or one that fails, aborts the close too.
    private func runConfirmation(_ confirmation: CloseConfirmation, dirtyEditors: [EditorViewController]) -> Bool {
        let alert = NSAlert()
        alert.messageText = confirmation.messageText
        alert.informativeText = confirmation.informativeText
        alert.alertStyle = .warning

        guard confirmation.offersSave else {
            alert.addButton(withTitle: confirmation.proceedButtonTitle)
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }

        // Buttons lay out right to left in the order they're added, so this is
        // the standard macOS document alert: [Discard] [Cancel] [Save].
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: confirmation.proceedButtonTitle)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return dirtyEditors.allSatisfy { $0.saveFile() }
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    @objc private func windowWillClose() {
        saveSession()

        // Don't strand hook processes blocked on approval: let the coordinator
        // cancel the visible sheet and resolve the queue.
        automationCoordinator?.prepareForWindowClose()

        // Tie Preferences to the main window's lifecycle. Otherwise it's a
        // separate NSWindow that keeps the app alive (and visible) after the
        // main window closes, so applicationShouldTerminateAfterLastWindowClosed
        // never fires.
        preferencesWindowController?.close()
        preferencesWindowController = nil
    }

    private func setupUI() {
        guard let window = window else { return }

        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        configureWindowBackgroundEffect()

        setupTitlebarBackground()
        setupTabBarSpacer()
        setupTabBar()
        setupActivityBar()
        setupSidebar()
        setupMainContent()

        layoutViews()

        // Create initial tab(s) after all views are set up
        tabController.restoreOrCreateInitialTab()
    }

    // MARK: - Session save/restore

    /// Forwards to the tab controller, which owns the tab/pane tree. Called from
    /// the autosave timer and windowWillClose.
    func saveSession() {
        tabController.saveSession()
    }

    /// Appends the session's cost roll-up to the JSONL history. Called once at
    /// app termination (see `applicationWillTerminate`).
    func recordSessionCosts() {
        tabController.recordSessionCosts()
    }

    private func setupTitlebarBackground() {
        titlebarBackgroundView = TitlebarBackgroundView()
        titlebarBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView?.addSubview(titlebarBackgroundView)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: .themeDidChange,
            object: nil
        )
    }

    private func setupTabBarSpacer() {
        tabBarSpacerView = TitlebarBackgroundView()
        tabBarSpacerView.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView?.addSubview(tabBarSpacerView)
    }

    private func setupTabBar() {
        tabBarView = TabBarView()
        tabBarView.delegate = self
        tabBarView.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView?.addSubview(tabBarView)
    }

    private func setupActivityBar() {
        activityBarView = ActivityBarView()
        activityBarView.delegate = self
        activityBarView.topInset = CGFloat(config.window.padding)
        activityBarView.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView?.addSubview(activityBarView)
    }

    private func setupSidebar() {
        sidebarContainerView = SidebarContainerView()
        sidebarContainerView.delegate = self
        sidebarContainerView.setVisible(false)
        sidebarContainerView.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView?.addSubview(sidebarContainerView)

        sidebarResizeHandle = SidebarResizeHandle()
        sidebarResizeHandle.isHidden = true
        sidebarResizeHandle.onDrag = { [weak self] delta in
            self?.resizeSidebar(by: delta)
        }
        sidebarResizeHandle.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView?.addSubview(sidebarResizeHandle)
    }

    private func setupMainContent() {
        mainContentView = NSView()
        mainContentView.wantsLayer = true
        // Keep main content transparent so blur shows through terminal
        mainContentView.layer?.backgroundColor = NSColor.clear.cgColor
        mainContentView.layer?.isOpaque = false
        mainContentView.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView?.addSubview(mainContentView)
        if let sidebarResizeHandle {
            window?.contentView?.addSubview(sidebarResizeHandle, positioned: .above, relativeTo: mainContentView)
        }
    }

    private func layoutViews() {
        guard let contentView = window?.contentView else { return }

        sidebarWidthConstraint = sidebarContainerView.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            // Fill the transparent native titlebar area with the app theme.
            titlebarBackgroundView.topAnchor.constraint(equalTo: contentView.topAnchor),
            titlebarBackgroundView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            titlebarBackgroundView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            titlebarBackgroundView.bottomAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.topAnchor),

            // Fill the left spacer next to the tab strip so the whole chrome band matches.
            tabBarSpacerView.topAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.topAnchor),
            tabBarSpacerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tabBarSpacerView.trailingAnchor.constraint(equalTo: tabBarView.leadingAnchor),
            tabBarSpacerView.bottomAnchor.constraint(equalTo: tabBarView.bottomAnchor),

            // Keep tabs below the native titlebar/traffic-light safe area.
            tabBarView.topAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.topAnchor),
            tabBarView.leadingAnchor.constraint(equalTo: mainContentView.leadingAnchor),
            tabBarView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tabBarView.heightAnchor.constraint(equalToConstant: 36),

            // Activity bar starts below tab bar
            activityBarView.topAnchor.constraint(equalTo: tabBarView.bottomAnchor),
            activityBarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            activityBarView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            activityBarView.widthAnchor.constraint(equalToConstant: 48),

            // Sidebar starts below tab bar, to the right of activity bar
            sidebarContainerView.topAnchor.constraint(equalTo: tabBarView.bottomAnchor),
            sidebarContainerView.leadingAnchor.constraint(equalTo: activityBarView.trailingAnchor),
            sidebarContainerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            sidebarWidthConstraint,

            sidebarResizeHandle.topAnchor.constraint(equalTo: sidebarContainerView.topAnchor),
            sidebarResizeHandle.bottomAnchor.constraint(equalTo: sidebarContainerView.bottomAnchor),
            sidebarResizeHandle.centerXAnchor.constraint(equalTo: sidebarContainerView.trailingAnchor),
            sidebarResizeHandle.widthAnchor.constraint(equalToConstant: 8),

            // Main content starts below tab bar, to the right of sidebar
            mainContentView.topAnchor.constraint(equalTo: tabBarView.bottomAnchor),
            mainContentView.leadingAnchor.constraint(equalTo: sidebarContainerView.trailingAnchor),
            mainContentView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            mainContentView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        setupKeyboardShortcuts()
        setupCWDTracking()
    }

    @objc private func themeDidChange() {
        titlebarBackgroundView?.applyTheme()
        tabBarSpacerView?.applyTheme()
        configureWindowBackgroundEffect()
        // Repaint open terminals so a theme switch (or an Auto light/dark flip)
        // applies live rather than only to newly opened panes.
        for tab in tabs {
            for pane in tab.panes {
                pane.terminalViewController?.applyConfig(config)
                pane.editorViewController?.applyConfig(config)
            }
        }
    }

    func applyRuntimeConfig(_ newConfig: Config) {
        config = newConfig
        window?.alphaValue = 1.0
        configureWindowBackgroundEffect()
        activityBarView?.topInset = CGFloat(newConfig.window.padding)
        sidebarContainerView?.setShowHiddenFiles(newConfig.editor?.showHiddenFiles ?? false)

        for tab in tabs {
            for pane in tab.panes {
                pane.terminalViewController?.applyConfig(newConfig)
                pane.editorViewController?.applyConfig(newConfig)
            }
        }

        notificationCoordinator?.updateConfig(newConfig.notifications ?? NotificationsConfig())
        syncAgentAutoApprove()
    }

    private func configureWindowBackgroundEffect() {
        guard let window else { return }

        if config.window.enableBlur {
            window.isOpaque = false
            window.backgroundColor = .white.withAlphaComponent(0.001)
            setBackgroundBlurRadius(20)
        } else {
            setBackgroundBlurRadius(0)
            window.isOpaque = true
            window.backgroundColor = AppTheme.windowBackground
        }
    }

    private func setBackgroundBlurRadius(_ radius: Int32) {
        guard let window else { return }
        _ = CGSSetWindowBackgroundBlurRadius(
            CGSDefaultConnectionForThread(),
            window.windowNumber,
            radius
        )
    }

    private func setupKeyboardShortcuts() {
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, event.window === self.window else { return event }
            return self.handleKeyDown(event) ? nil : event
        }

        // A single window-wide click monitor, routed only to the active tab's
        // split controller. Previously every tab's controller installed its own
        // monitor, so a click was hit-tested against hidden tabs too and could
        // yank focus to whichever tab's panes happened to overlap the point.
        clickEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self = self, event.window === self.window else { return event }
            self.currentPaneSplitController?.activatePane(containing: event)
            return event
        }
    }

    deinit {
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
        }
        if let clickEventMonitor {
            NSEvent.removeMonitor(clickEventMonitor)
        }
    }

    private func setupCWDTracking() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(terminalCWDChanged(_:)),
            name: .terminalCWDChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(paneDirtyStateChanged(_:)),
            name: .paneDirtyStateChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(paneTitleChanged(_:)),
            name: .paneTitleChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(paneCommandStatusChanged(_:)),
            name: .paneCommandStatusChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(paneOpenURLRequested(_:)),
            name: .paneOpenURLRequested,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(paneOpenFileRequested(_:)),
            name: .paneOpenFileRequested,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(paneAgentStateChanged(_:)),
            name: .paneAgentStateChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pendingApprovalsChanged(_:)),
            name: .pendingApprovalsChanged,
            object: nil
        )
    }

    @objc private func terminalCWDChanged(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let directory = userInfo["directory"] as? String else { return }

        if let pane = notification.object as? PaneModel,
           let activeTab = tabs[safe: activeTabIndex] {
            guard activeTab.activePane?.id == pane.id else { return }
        }

        // Update sidebar panels to show current active pane directory.
        sidebarContainerView.updateFileTree(path: directory)
    }

    @objc private func paneDirtyStateChanged(_ notification: Notification) {
        guard let pane = notification.object as? PaneModel else { return }

        // Find the tab containing this pane and aggregate dirty state across all
        // its panes — a single pane going clean must not clear the tab's dot
        // while a sibling editor is still modified. The notification only serves
        // as the trigger. (Mirrors saveCurrentFile's aggregation.)
        for tab in tabs {
            if tab.panes.contains(where: { $0.id == pane.id }) {
                let isTabDirty = tab.panes.contains { $0.editorViewController?.isModified == true }
                // textDidChange fires this on every keystroke; only rebuild the
                // tab bar when the aggregate actually flips.
                if tab.isDirty != isTabDirty {
                    tab.isDirty = isTabDirty
                    updateTabBar()
                }
                break
            }
        }
    }

    @objc private func paneTitleChanged(_ notification: Notification) {
        guard let pane = notification.object as? PaneModel else { return }

        // Find the tab containing this pane
        for tab in tabs {
            if tab.panes.contains(where: { $0.id == pane.id }) {
                // Only update if this is the active pane in the tab
                if tab.activePane?.id == pane.id {
                    tab.updateTitleFromActivePane()
                    updateTabBar()
                }
                break
            }
        }
    }

    @objc private func paneOpenFileRequested(_ notification: Notification) {
        guard let path = notification.userInfo?["path"] as? String else { return }
        let line = notification.userInfo?["line"] as? Int
        openFileInEditor(URL(fileURLWithPath: path), atLine: line ?? 1, highlighting: nil)
    }

    @objc private func paneOpenURLRequested(_ notification: Notification) {
        guard let url = notification.userInfo?["url"] as? URL else { return }
        if let last = lastOpenedURL, last.url == url, Date().timeIntervalSince(last.at) < 0.7 {
            return
        }
        lastOpenedURL = (url, Date())
        NSWorkspace.shared.open(url)
    }

    @objc private func paneCommandStatusChanged(_ notification: Notification) {
        guard let pane = notification.object as? PaneModel else { return }
        let status = notification.userInfo?["status"] as? TerminalCommandStatus

        for tab in tabs {
            if tab.panes.contains(where: { $0.id == pane.id }) {
                // A non-zero exit in a pane the user isn't looking at joins the
                // attention cycle; a zero exit clears any earlier mark. "Being
                // viewed" means the active pane of the active tab. Setting the
                // mark posts, so the agents panel refreshes on its own.
                if let status = status {
                    let viewed = tab.isActive && tab.activePane?.id == pane.id
                    pane.setFailedCommandAttention(
                        PaneModel.shouldMarkAttention(commandSucceeded: status.succeeded, paneIsBeingViewed: viewed)
                    )
                }

                // Only surface status from the pane the tab is showing as active.
                guard tab.activePane?.id == pane.id else { break }
                tab.lastCommandFailed = status.map { !$0.succeeded } ?? false
                tab.lastCommandTooltip = status.map { "Last command: \($0.summary)" }
                updateTabBar()
                break
            }
        }
    }

    private func postUserNotification(title: String, body: String, playSound: Bool) {
        // UNUserNotificationCenter requires a real bundle; skip when running
        // the bare debug binary.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = playSound ? .default : nil
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }

    @objc private func paneAgentStateChanged(_ notification: Notification) {
        guard let pane = notification.object as? PaneModel,
              notification.userInfo?["agentState"] is AgentState else { return }

        if let tab = tabs.first(where: { $0.panes.contains(where: { $0.id == pane.id }) }) {
            // PaneModel has already stored the new state. Aggregate all panes
            // so an idle sibling cannot mask one that is working or blocked.
            tab.updateAgentStateFromPanes()
            applyAgentState(tab.agentState, to: tab)
        }
    }

    /// Single path for agent state changes regardless of how they arrived
    /// (OSC termprop from the shell vs the IPC socket): updates the tab dot,
    /// the activity-bar badge, and alerts the user when input is needed.
    private func applyAgentState(_ state: AgentState, to tab: TabModel) {
        tab.agentState = state
        updateTabBar()
        refreshAgentsBadge()

        // Dock-bounce attention stays unconditional; the actual system
        // notification for ready/done is handled opt-in by NotificationCoordinator
        // (observing .paneAgentStateChanged), gated by the [notifications] config.
        if state == .ready || state == .done {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    /// Updates the activity-bar badge with everything waiting on the user:
    /// tabs whose agent needs input, plus edits queued for approval.
    func refreshAgentsBadge() {
        let waiting = tabs.filter { $0.agentState == .ready }.count
        activityBarView.updateAgentsBadge(count: waiting + ApprovalQueue.shared.pending.count)
    }

    /// The last pending-approval count, so queue-change notifications can tell
    /// growth (ask for attention) from shrinkage (just refresh the badge).
    private var lastPendingApprovalCount = 0

    /// The approvals queue changed: sync the badge, and when a new edit landed,
    /// call for attention the way a blocked agent does — dock bounce, plus a
    /// user notification when Cortland isn't frontmost.
    @objc private func pendingApprovalsChanged(_ notification: Notification) {
        let pending = ApprovalQueue.shared.pending
        defer { lastPendingApprovalCount = pending.count }
        refreshAgentsBadge()

        guard pending.count > lastPendingApprovalCount else { return }
        NSApp.requestUserAttention(.informationalRequest)
        if !NSApp.isActive, let newest = pending.last {
            postUserNotification(
                title: "Agent waiting for edit approval",
                body: (newest.path as NSString).lastPathComponent,
                playSound: true
            )
        }
    }

    /// Forwards to the tab controller. Public entry point used by the menu,
    /// command palette, keyboard router, and AppDelegate. Returns false when
    /// the tab cap refused the tab.
    @discardableResult
    func createNewTab(workingDirectory: String? = nil, command: [String]? = nil) -> Bool {
        tabController.createNewTab(workingDirectory: workingDirectory, command: command)
    }

    private func updateTabBar() {
        tabBarView.updateTabs(tabs, activeIndex: activeTabIndex)
    }

    func syncSidebarToActiveTab() {
        // Keep the agents panel's highlighted row on the active tab's agent.
        sidebarContainerView.refreshAgents()

        guard let directory = currentSidebarDirectoryForActiveTab() else { return }
        sidebarContainerView.updateFileTree(path: directory)

        // Keep the file tree pointed at whatever the active tab is editing:
        // expand to and highlight that file, or clear the selection otherwise.
        if let editorPath = activeEditorFilePath() {
            sidebarContainerView.revealFile(URL(fileURLWithPath: editorPath))
        } else {
            sidebarContainerView.clearFileSelection()
        }
    }

    private func activeEditorFilePath() -> String? {
        guard let activeTab = tabs[safe: activeTabIndex] else { return nil }
        let editorPane =
            activeTab.activePane.flatMap { $0.paneType == .editor ? $0 : nil } ??
            activeTab.panes.first(where: { $0.paneType == .editor })
        return editorPane?.editorViewController?.filePath
    }

    private func currentSidebarDirectoryForActiveTab() -> String? {
        guard let activeTab = tabs[safe: activeTabIndex] else { return nil }

        if let activePaneDirectory = directoryForSidebar(from: activeTab.activePane) {
            return activePaneDirectory
        }

        return activeTab.panes.compactMap { directoryForSidebar(from: $0) }.first
    }

    private func directoryForSidebar(from pane: PaneModel?) -> String? {
        guard let pane = pane else { return nil }

        if let directory = pane.resolvedWorkingDirectory() {
            return directory
        }

        return nil
    }

    private func switchToTab(index: Int) {
        tabController.switchToTab(index: index)
    }

    private func closeTab(index: Int) {
        tabController.closeTab(index: index)
    }
}

extension MainWindowController: TabBarDelegate {
    func tabBar(_ tabBar: TabBarView, didSelectTab index: Int) {
        switchToTab(index: index)
    }

    func tabBar(_ tabBar: TabBarView, didCloseTab index: Int) {
        // Mirror TabController.closeTab's last-tab guard so no confirmation
        // shows for a close that would be refused anyway.
        guard tabs.count > 1, let tab = tabs[safe: index] else { return }
        guard confirmMouseClose(target: "tab", panes: tab.panes) else { return }
        closeTab(index: index)
    }

    func tabBar(_ tabBar: TabBarView, didMoveTab fromIndex: Int, to toIndex: Int) {
        tabController.moveTab(from: fromIndex, to: toIndex)
    }

    func tabBar(_ tabBar: TabBarView, didRenameTab index: Int, to title: String?) {
        guard let tab = tabs[safe: index] else { return }
        tab.customTitle = title
        updateTabBar()
    }
}

extension MainWindowController: ActivityBarDelegate {
    func activityBar(_ activityBar: ActivityBarView, didSelectPanel panel: SidebarPanel) {
        showPanel(panel)
    }

    func activityBarDidToggleSidebar(_ activityBar: ActivityBarView) {
        toggleSidebar()
    }
}

extension MainWindowController: SidebarContainerDelegate {
    func sidebarContainerTabs(_ container: SidebarContainerView) -> [TabModel] {
        tabs
    }

    func sidebarContainer(_ container: SidebarContainerView, didRequestSwitchToTab index: Int) {
        switchToTab(index: index)
    }

    func sidebarContainer(_ container: SidebarContainerView, didRequestConnectCommand command: String) {
        createNewTab()
        // Send once the shell has actually drawn its prompt, rather than racing a
        // fixed 0.8s delay (which dropped the command on a slow shell and dawdled
        // on a fast one).
        let terminal = tabs[safe: activeTabIndex]?.activePane?.terminalViewController
        terminal?.sendOnShellReady(command)
    }

    // MARK: Worktrees panel

    // These forward to WorktreeFlowController, which owns the worktree flows.

    func sidebarContainerActiveRepoRoot(_ container: SidebarContainerView) -> String? {
        worktreeFlowController.activeRepoRoot()
    }

    func sidebarContainer(_ container: SidebarContainerView, didRequestOpenWorktree path: String) {
        worktreeFlowController.openWorktree(path: path)
    }

    func sidebarContainer(_ container: SidebarContainerView, didRequestCreateWorktree branch: String, agent: WorktreeAgent) {
        worktreeFlowController.createWorktree(branch: branch, agent: agent)
    }

    func sidebarContainer(_ container: SidebarContainerView, didRequestRemoveWorktree branch: String, force: Bool) {
        worktreeFlowController.removeWorktree(branch: branch, force: force)
    }

    func sidebarContainer(_ container: SidebarContainerView, didRequestMergeWorktree branch: String) {
        worktreeFlowController.mergeWorktree(branch: branch)
    }

    func sidebarContainer(_ container: SidebarContainerView, didSelectWorktreeForGitPanel path: String) {
        // Retarget the git panel only (not the file tree / search) — transient
        // until the next tab switch or cwd change, per the worktrees-panel design.
        container.retargetGitPanel(toRepositoryPath: path)
    }

    func sidebarContainer(_ container: SidebarContainerView, didOpenFile url: URL) {
        Log.debug("📂 Sidebar requested to open file: \(url.path)", category: "app")

        if config.editor?.fileOpenMode == "builtin" {
            openFileInEditor(url)
        } else {
            openFileInTerminalEditor(url)
        }
    }

    private func openFileInTerminalEditor(_ url: URL) {
        let editor = ProcessInfo.processInfo.environment["EDITOR"] ?? "nvim"
        let command = "\(editor) \"\(url.path)\""
        runCommandInActiveTerminal(command)
    }

    func sidebarContainer(_ container: SidebarContainerView, didRequestDiffFor filePath: String, kind: GitDiffKind) {
        openDiffViewer(for: filePath, kind: kind)
    }

    func sidebarContainer(_ container: SidebarContainerView, didRequestUncommittedChangesFor repositoryPath: String, focusedFilePath: String?) {
        openUncommittedChangesInNewTab(repositoryPath: repositoryPath, focusedFilePath: focusedFilePath)
    }

    func sidebarContainer(_ container: SidebarContainerView, didRequestOpenFile filePath: String, atLine line: Int, highlighting searchTerm: String?) {
        let url = URL(fileURLWithPath: filePath)
        openFileInEditor(url, atLine: line, highlighting: searchTerm)
    }

    private func openFileInEditor(_ url: URL) {
        openEditorPane(for: url)
    }

    private func openFileInEditor(_ url: URL, atLine line: Int) {
        openEditorPane(for: url, line: line)
    }

    private func openFileInEditor(_ url: URL, atLine line: Int, highlighting searchTerm: String?) {
        openEditorPane(for: url, line: line, searchTerm: searchTerm)
    }

    private func openEditorPane(for url: URL, line: Int? = nil, searchTerm: String? = nil) {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

        guard exists && !isDirectory.boolValue else {
            Log.debug("Attempted to open directory or non-existent file: \(url.path)", category: "app")
            return
        }

        guard let currentTab = tabs[safe: activeTabIndex] else { return }

        let editorPane = PaneFactory.editorPane(for: url, line: line, searchTerm: searchTerm)
        currentTab.addPane(editorPane)
        // Add into the existing split tree rather than rebuilding it flat, so a
        // nested layout (e.g. a 2×2 grid) survives opening the editor. addPane
        // activates the new pane, which syncs currentTab.activePaneIndex via the
        // didActivatePane delegate.
        currentPaneSplitController?.addPane(editorPane)

        updateTabBar()
        syncSidebarToActiveTab()
    }

    private func openDiffViewer(for filePath: String, kind: GitDiffKind = .uncommitted) {
        openDiffInNewTab(for: filePath, kind: kind)
    }

    private func openDiffInNewTab(for filePath: String, kind: GitDiffKind) {
        openSinglePaneTab(pane: PaneFactory.diffPane(for: filePath, kind: kind))
    }

    private func openUncommittedChangesInNewTab(repositoryPath: String, focusedFilePath: String?) {
        if let existingIndex = tabs.firstIndex(where: { tab in
            tab.panes.count == 1 &&
            tab.panes.first?.paneType == .uncommittedChanges &&
            tab.panes.first?.currentDirectory == repositoryPath
        }) {
            switchToTab(index: existingIndex)
            tabs[existingIndex].panes.first?.uncommittedChangesViewController?.reload(focusedFilePath: focusedFilePath)
            return
        }

        let pane = PaneFactory.uncommittedChangesPane(
            repositoryPath: repositoryPath,
            focusedFilePath: focusedFilePath,
            onOpenFile: { [weak self] filePath in
                self?.openFileInEditor(URL(fileURLWithPath: filePath))
            }
        )
        openSinglePaneTab(pane: pane)
    }

    private func openSinglePaneTab(pane: PaneModel) {
        let tab = TabModel()
        tab.panes = [pane]
        tab.activePaneIndex = 0
        tab.updateTitleFromActivePane()

        guard tabController.installTab(tab) else { return }
        syncSidebarToActiveTab()
    }

    func showQuickOpen() {
        guard let window = window else { return }

        // Get current working directory from active terminal
        let currentWorkingDirectory: String
        if let activeTab = tabs[safe: activeTabIndex],
           let terminalPane = activeTab.panes.first(where: { $0.terminalViewController != nil }),
           let terminalVC = terminalPane.terminalViewController {
            currentWorkingDirectory = terminalVC.getCurrentWorkingDirectory()
        } else {
            currentWorkingDirectory = FileManager.default.currentDirectoryPath
        }

        // Create or reuse quick open panel
        if quickOpenPanel == nil {
            quickOpenPanel = QuickOpenPanel()
            quickOpenPanel?.quickOpenDelegate = self
        }

        quickOpenPanel?.show(relativeTo: window, workingDirectory: currentWorkingDirectory)
    }

    func showSessions() {
        guard let window = window else { return }

        // Create or reuse the Session Recall panel.
        if sessionsPanel == nil {
            sessionsPanel = SessionsPanel()
            sessionsPanel?.sessionsDelegate = self
        }

        sessionsPanel?.show(relativeTo: window)
    }

    func showPreferences() {
        // Reuse only a still-open window. The controller snapshots the config it
        // was built with, so once it has closed (or config reloaded from disk),
        // rebuild it from the current `config` rather than reopening a stale one.
        if let existing = preferencesWindowController, existing.window?.isVisible == true {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let controller = PreferencesWindowController(config: config, mainWindowController: self)
        preferencesWindowController = controller
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func openConfigFile() {
        // Get EDITOR from environment or default to nvim
        let editor = ProcessInfo.processInfo.environment["EDITOR"] ?? "nvim"
        let configPath = "~/.config/cortland/config.toml"
        let command = "\(editor) \(configPath)"

        Log.debug("📝 Opening config file with command: \(command)", category: "app")

        // Make sure window is focused
        window?.makeKeyAndOrderFront(nil)

        // Send command to terminal
        runCommandInActiveTerminal(command)
    }

    func closeCurrentTab() {
        tabController.closeCurrentTab()
    }

    func saveCurrentFile() {
        guard let activeTab = tabs[safe: activeTabIndex] else { return }

        let editorPane =
            activeTab.panes.first { $0.editorViewController?.isEditorFocused == true } ??
            activeTab.activePane.flatMap { $0.paneType == .editor ? $0 : nil } ??
            currentPaneSplitController?.activePane.flatMap { $0.paneType == .editor ? $0 : nil }

        guard let pane = editorPane,
              let editor = pane.editorViewController else {
            Log.debug("💾 No active editor pane to save", category: "app")
            return
        }

        if editor.saveFile() {
            pane.updateTitleForEditor(fileName: editor.fileName)
            activeTab.isDirty = activeTab.panes.contains { $0.editorViewController?.isModified == true }
            activeTab.updateTitleFromActivePane()
            updateTabBar()
        }
    }

    /// Sends the command to the active tab's first terminal pane and returns
    /// that pane, so callers can track which pane ran the command.
    @discardableResult
    private func runCommandInActiveTerminal(_ command: String) -> PaneModel? {
        guard let activeTab = tabs[safe: activeTabIndex],
              let terminalPane = activeTab.panes.first(where: { $0.terminalViewController != nil }),
              let terminalVC = terminalPane.terminalViewController else {
            Log.error("❌ No terminal pane found in active tab!", category: "app")
            return nil
        }

        terminalVC.send(text: command + "\n")
        return terminalPane
    }

    private func setupIPC() {
        automationCoordinator = AutomationCoordinator(host: self)
        IPCServer.shared.delegate = automationCoordinator
        IPCServer.shared.start()
    }
}

// MARK: - QuickOpenPanelDelegate
extension MainWindowController: QuickOpenPanelDelegate {
    func quickOpenPanel(_ panel: QuickOpenPanel, didSelectFile filePath: String) {
        let url = URL(fileURLWithPath: filePath)
        openFileInEditor(url)
    }
}

// MARK: - SessionsPanelDelegate
extension MainWindowController: SessionsPanelDelegate {
    func sessionsPanel(_ panel: SessionsPanel, didSelect record: SessionRecord) {
        // Resume in a NEW tab: the cwd goes via workingDirectory (not a `cd`),
        // and the resume ARGV via command: so the app's existing claude/codex
        // approval-flag injection applies. A nil cwd falls back to the active
        // pane's directory.
        createNewTab(workingDirectory: record.cwd, command: record.resumeArgv)
    }
}

extension MainWindowController {
    override func keyDown(with event: NSEvent) {
        if handleKeyDown(event) {
            return
        }

        super.keyDown(with: event)
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        // When the GUI file editor has focus, let it own a few shortcuts that
        // otherwise route to panes/terminal: ⌘F (find bar), ⌘] / ⌘[ (indent /
        // outdent), ⇧⌘G (find previous, otherwise the Git panel). The terminal
        // and nvim are not CodeTextViews, so they keep the default pane behavior.
        if window?.firstResponder is CodeTextView {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command,
               event.keyCode == 3 || event.keyCode == 30 || event.keyCode == 33 {
                return false
            }
            if flags == [.command, .shift], event.keyCode == 5 {
                return false
            }
        }

        guard let command = keyboardCommandRouter.command(for: event, tabCount: tabs.count) else {
            return false
        }

        // With the arcade disabled (the default), ⌃` falls through to the
        // terminal rather than being swallowed by a no-op command.
        if command == .toggleArcade && !isArcadeEnabled {
            return false
        }

        // Cmd+V only intercepts when the pasteboard holds an image (pasted
        // as a temp PNG path); otherwise fall through to normal paste.
        if command == .pasteIntoTerminal {
            return pasteImageAsTempFileIfPossible()
        }

        paletteCommandRegistry.perform(command)
        return true
    }

    /// Keeps the keyboard toggle and the preferences setting in sync. Persists
    /// through a fresh load rather than this window's snapshot so the
    /// whole-file write can't revert external edits made since the last
    /// ConfigWatcher reload (same read-modify-write as Preferences'
    /// mutateConfig). When the on-disk file is broken, the toggle still
    /// applies to this window but save() refuses, so the user's file isn't
    /// clobbered with defaults.
    func toggleHiddenFiles() {
        var fresh = Config.load()
        if fresh.loadDidFail {
            fresh = config
            fresh.loadDidFail = true
        }
        if fresh.editor == nil {
            fresh.editor = EditorConfig()
        }
        let show = !(fresh.editor?.showHiddenFiles ?? false)
        fresh.editor?.showHiddenFiles = show
        sidebarContainerView.setShowHiddenFiles(show)
        config = fresh
        fresh.save()
    }

    /// When the clipboard holds an image (and no plain text), write it to a
    /// temp PNG and type the quoted path into the focused terminal — handy
    /// for handing screenshots to CLI agents. Returns true when handled.
    private func pasteImageAsTempFileIfPossible() -> Bool {
        // Only intercept when keyboard focus is really on the terminal;
        // otherwise Cmd+V belongs to the editor/find bar/sidebar field.
        guard let terminal = tabs[safe: activeTabIndex]?.activePane?.terminalViewController,
              terminal.isTerminalFocused,
              !terminal.isCommandRunning else {
            return false
        }

        let pasteboard = NSPasteboard.general
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return false
        }
        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return false
        }

        let url: URL
        do {
            url = try ImagePasteStore.store(png: png)
        } catch {
            Log.debug("📋 Failed to write pasted image: \(error)", category: "app")
            return false
        }

        terminal.send(text: "'\(url.path)'")
        return true
    }

    /// Cmd+Shift+J: cycles through tabs wanting attention, most urgent first —
    /// needs-input tabs, then tabs with a failed background command, then
    /// finished ones, then working ones. Repeated presses walk all tabs in that
    /// bucket. Ordering lives in `TabModel.nextAttentionIndex`.
    private func jumpToNextAttentionTab() {
        guard let next = TabModel.nextAttentionIndex(in: tabs, activeIndex: activeTabIndex),
              next != activeTabIndex else { return }
        switchToTab(index: next)
    }

    func cycleTabs(forward: Bool) {
        guard tabs.count > 1 else { return }

        if forward {
            // Next tab
            let nextIndex = (activeTabIndex + 1) % tabs.count
            switchToTab(index: nextIndex)
        } else {
            // Previous tab
            let prevIndex = (activeTabIndex - 1 + tabs.count) % tabs.count
            switchToTab(index: prevIndex)
        }
    }

    func closeCurrentPane() {
        guard let tab = tabs[safe: activeTabIndex] else { return }

        if tab.panes.count > 1 {
            guard let pane = currentPaneSplitController?.activePane,
                  confirmKeyboardClose(target: "pane", panes: [pane]) else { return }
            currentPaneSplitController?.closeActivePane()
        } else if config.behavior.confirmClose {
            // ⇧⌘W on a tab's only pane falls through to closing the whole
            // window. One alert covers everything the window holds; close()
            // skips windowShouldClose so the busy-agent veto can't ask twice.
            guard confirmKeyboardClose(target: "window", panes: tabs.flatMap(\.panes)) else { return }
            window?.close()
        } else {
            window?.performClose(nil)
        }
    }

    func toggleSidebar() {
        sidebarContainerView.toggleVisibility()
        updateSidebarLayout()
    }

    func togglePanel(_ panel: SidebarPanel) {
        if sidebarContainerView.visible && sidebarContainerView.currentPanel == panel {
            sidebarContainerView.setVisible(false)
            updateSidebarLayout()
        } else {
            showPanel(panel)
        }
    }

    func showPanel(_ panel: SidebarPanel) {
        sidebarContainerView.showPanel(panel)
        activityBarView.selectPanel(panel)

        if sidebarContainerView.isHidden {
            sidebarContainerView.setVisible(true)
            updateSidebarLayout()
        }

        // Re-push the active pane's directory so a freshly opened panel
        // reflects the current terminal, not whatever it last saw.
        syncSidebarToActiveTab()
    }

    func showKeyboardShortcuts() {
        if keyboardShortcutsPanel == nil {
            keyboardShortcutsPanel = KeyboardShortcutsPanel(
                contentRect: .zero,
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
        }
        keyboardShortcutsPanel?.makeKeyAndOrderFront(nil)
    }

    private func updateSidebarLayout() {
        sidebarWidthConstraint.constant = sidebarContainerView.visible ? sidebarPreferredWidth : 0
        sidebarResizeHandle.isHidden = !sidebarContainerView.visible
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func resizeSidebar(by delta: CGFloat) {
        guard sidebarContainerView.visible, let contentWidth = window?.contentView?.bounds.width else { return }

        let maximumWidth = max(180, min(600, contentWidth - 48 - 240))
        sidebarPreferredWidth = min(maximumWidth, max(180, sidebarPreferredWidth + delta))
        sidebarWidthConstraint.constant = sidebarPreferredWidth
        UserDefaults.standard.set(Double(sidebarPreferredWidth), forKey: Self.sidebarWidthDefaultsKey)
        window?.contentView?.layoutSubtreeIfNeeded()
    }

}

private final class SidebarResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?

    // The main window is movable by background, and a transparent view opts
    // into that by default — a drag here must only resize the sidebar, never
    // also drag the window along.
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        NSCursor.resizeLeftRight.push()
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.deltaX)
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.pop()
    }
}

// MARK: - NSWindowDelegate
extension MainWindowController: NSWindowDelegate {
    /// Veto a close-button close while agents are working or an editor holds
    /// unsaved edits, so the window (and its PTYs) aren't torn down without a
    /// heads-up. ⌘Q is guarded separately in AppDelegate.applicationShouldTerminate.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        confirmCloseWithUnsavedWork()
    }
}

// MARK: - TabHost
extension MainWindowController: TabHost {
    var tabContentView: NSView { mainContentView }
    var tabConfig: Config { config }

    func reloadTabBar() {
        updateTabBar()
    }

    func updateSidebarDirectory(_ path: String) {
        sidebarContainerView.updateFileTree(path: path)
    }
    // syncSidebarToActiveTab() and refreshAgentsBadge() are defined on the
    // class above and satisfy the rest of TabHost.
}

// MARK: - AutomationHost
extension MainWindowController: AutomationHost {
    var automationTabs: [TabModel] { tabs }
    var activeAutomationTabID: UUID? { tabs[safe: activeTabIndex]?.id }
    var automationWindow: NSWindow? { window }

    /// Effective auto-approve: the session toggle OR the config mode.
    var shouldAutoApproveEdits: Bool {
        sessionAutoApproveEdits || (config.approval?.autoApprove ?? false)
    }

    /// The active approval config (defaults when the section is absent), used
    /// for the auto_allow / always_ask glob rules.
    var approvalConfig: ApprovalConfig {
        config.approval ?? ApprovalConfig()
    }

    /// Effective telemetry rate card: `[telemetry]` overrides merged over the
    /// built-in defaults.
    var telemetryRates: [String: TelemetryRate] {
        config.telemetry?.resolvedRates() ?? TelemetryRates.defaults
    }

    /// Working directory of the pane with `paneID`, searched across all tabs, or
    /// nil when it can't be found. Feeds worktree-scoped auto-approve.
    func workingDirectory(forPane paneID: UUID?) -> String? {
        guard let paneID else { return nil }
        for tab in tabs {
            if let pane = tab.panes.first(where: { $0.id == paneID }) {
                return pane.resolvedWorkingDirectory()
            }
        }
        return nil
    }

    /// Flips the per-session auto-approve toggle. Menu-driven. Updates the scoped
    /// Claude permission mode so the change reaches agents launched afterward in
    /// Cortland panes; the next relaunch re-syncs from the persistent `[approval]`
    /// mode.
    func toggleAutoApproveEdits() {
        sessionAutoApproveEdits.toggle()
        syncAgentAutoApprove()
    }

    func automationSplitController(forTab tabID: UUID) -> PaneSplitController? {
        tabController.splitController(forTab: tabID)
    }

    func automationCreateNewTab(workingDirectory: String?) -> Bool {
        createNewTab(workingDirectory: workingDirectory)
    }

    func automationOpenFile(_ url: URL) {
        openFileInEditor(url)
    }

    func automationSetActiveTabAgentState(_ state: AgentState) {
        guard let tab = tabs[safe: activeTabIndex] else { return }
        applyAgentState(state, to: tab)
    }
}

// MARK: - NotificationCoordinatorHost
extension MainWindowController: NotificationCoordinatorHost {
    func notificationTabTitle(forPane paneID: UUID) -> String? {
        tabs.first(where: { $0.panes.contains(where: { $0.id == paneID }) })?.title
    }

    /// Click-to-focus: bring Cortland forward, select the tab, and focus the
    /// pane. This is the only place notifications activate the app — every other
    /// path deliberately avoids stealing focus.
    func focusPaneFromNotification(paneID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.panes.contains(where: { $0.id == paneID }) }) else { return }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        let tabID = tabs[index].id
        switchToTab(index: index)
        automationSplitController(forTab: tabID)?.focusPane(id: paneID)
    }

    /// Check (and if never asked, request) notification permission, reporting
    /// the effective status back so Preferences can point the user at System
    /// Settings when Cortland is blocked there. Invoked from Preferences when a
    /// notification toggle is switched on, so any prompt appears on a user
    /// action rather than at launch.
    func ensureNotificationAuthorization(completion: @escaping @MainActor (UNAuthorizationStatus) -> Void) {
        notificationCoordinator?.ensureAuthorization(completion: completion)
    }
}

// MARK: - PaletteCommandHost
extension MainWindowController: PaletteCommandHost {
    var paletteHostWindow: NSWindow? { window }

    func createNewTabFromCommand() {
        createNewTab()
    }

    func selectTab(index: Int) {
        switchToTab(index: index)
    }

    func closeActiveTab() {
        // Mirror TabController.closeTab's last-tab guard so no confirmation
        // shows for a close that would be refused anyway.
        guard tabs.count > 1, let tab = tabs[safe: activeTabIndex] else { return }
        guard confirmKeyboardClose(target: "tab", panes: tab.panes) else { return }
        closeTab(index: activeTabIndex)
    }

    func focusAgentAttentionTab() {
        jumpToNextAttentionTab()
    }

    func splitActivePane(direction: SplitDirection) {
        currentPaneSplitController?.splitPane(direction: direction)
    }

    func focusAdjacentPane(forward: Bool) {
        forward ? currentPaneSplitController?.focusNextPane() : currentPaneSplitController?.focusPreviousPane()
    }

    func jumpToPrompt(previous: Bool) {
        guard let terminal = tabs[safe: activeTabIndex]?.activePane?.terminalViewController else { return }
        if previous {
            terminal.scrollToPreviousPrompt()
        } else {
            terminal.scrollToNextPrompt()
        }
    }

    func findInActiveTerminal() {
        tabs[safe: activeTabIndex]?.activePane?.terminalViewController?.showFindBar()
    }

    var isArcadeEnabled: Bool {
        config.arcade?.enabled ?? false
    }

    var paletteSkillRoots: [URL] {
        let fileManager = FileManager.default
        var roots = [
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/skills", isDirectory: true)
        ]
        // The workspace's own .claude/skills, found by walking up from the
        // terminal cwd, which may be a subdirectory of the repo. Stops at
        // $HOME so the user root can't be picked up twice.
        if let cwd = tabController.currentWorkingDirectoryForNewTerminal() {
            var directory = URL(fileURLWithPath: cwd).standardizedFileURL
            let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
            while directory.path != "/" && directory.path != home {
                let candidate = directory.appendingPathComponent(".claude/skills", isDirectory: true)
                if fileManager.fileExists(atPath: candidate.path) {
                    roots.append(candidate)
                    break
                }
                directory = directory.deletingLastPathComponent()
            }
        }
        return roots
    }

    func sendToActiveTerminal(text: String, submit: Bool) {
        guard let terminal = tabs[safe: activeTabIndex]?.activePane?.terminalViewController else { return }
        terminal.send(text: text)
        guard submit else { return }
        // Same two-step delivery as `cortland-ctl run` (handlePaneRun): agent
        // TUIs treat a burst of stdin as a paste and swallow an Enter carried
        // in the same chunk, so it goes as its own keypress once that settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) {
            _ = terminal.send(key: "enter")
        }
    }
}

// MARK: - WorktreeFlowHost
extension MainWindowController: WorktreeFlowHost {
    var worktreeWindow: NSWindow? { window }
    var worktreeTabs: [TabModel] { tabs }

    func worktreeWorkingDirectory() -> String? {
        tabController.currentWorkingDirectoryForNewTerminal()
    }

    func worktreeSwitchToTab(index: Int) {
        switchToTab(index: index)
    }

    @discardableResult
    func worktreeCreateTab(workingDirectory: String?, command: [String]?) -> Bool {
        createNewTab(workingDirectory: workingDirectory, command: command)
    }

    func worktreeRefreshPanel() {
        sidebarContainerView.refreshWorktrees()
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var hexString = hex
        if hexString.hasPrefix("#") {
            hexString = String(hexString.dropFirst())
        }

        guard hexString.count == 6,
              let hexInt = Int(hexString, radix: 16) else {
            return nil
        }

        let r = CGFloat((hexInt >> 16) & 0xFF) / 255.0
        let g = CGFloat((hexInt >> 8) & 0xFF) / 255.0
        let b = CGFloat(hexInt & 0xFF) / 255.0

        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
