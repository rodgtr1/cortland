import AppKit
import CortlandTelemetryCore

/// The surface `AutomationCoordinator` needs from the window controller to
/// resolve panes and drive the UI. MainWindowController stays the source of
/// truth for tabs/panes/window; the coordinator only reads through this seam,
/// so the IPC translation, wait logic, and diff-approval queue can live outside
/// the 1,900-line controller.
protocol AutomationHost: DiffApprovalHost {
    /// All tabs, in order. The active one is identified by `activeAutomationTabID`.
    var automationTabs: [TabModel] { get }
    /// ID of the tab the user is currently looking at (drives `focused`).
    var activeAutomationTabID: UUID? { get }
    /// Effective telemetry rate card ([telemetry] overrides merged over the
    /// built-in defaults), used to price per-pane token usage.
    var telemetryRates: [String: TelemetryRate] { get }

    func automationSplitController(forTab tabID: UUID) -> PaneSplitController?
    /// Returns false when the tab cap refused the tab.
    func automationCreateNewTab(workingDirectory: String?) -> Bool
    func automationOpenFile(_ url: URL)
    func automationSetActiveTabAgentState(_ state: AgentState)
}

/// Translates IPC commands (from `cortland-ctl`, `cortland-mcp`, and the
/// edit-approval hook) into operations on the live pane tree, and is the lone
/// event-stream emit site. Hook edit approvals are delegated to
/// `DiffApprovalCoordinator`. Extracted from MainWindowController — see
/// AutomationHost for the seam back to it.
final class AutomationCoordinator: NSObject, IPCServerDelegate {
    private weak var host: AutomationHost?

    /// Owns the hook diff-approval queue, review presentation, and per-pane
    /// "approve & remember" grants. Reports the diff lifecycle back through
    /// `emitDiffEvent` so this coordinator stays the lone event-emit site, and
    /// flips a pane's agent status while its edit waits at the desk through
    /// `setPaneParked`.
    private lazy var diffApproval = DiffApprovalCoordinator(
        host: host,
        onParkedStatusChange: { [weak self] paneID, parked in
            self?.setPaneParked(paneID, parked: parked)
        }
    ) { [weak self] path, decision in
        self?.emitDiffEvent(path: path, decision: decision)
    }

    /// How many edit-gate entries are currently parked at the desk per pane, so
    /// the pane only returns to "working" once its LAST parked edit resolves —
    /// a pane can't normally have two (its hook blocks), but the count keeps the
    /// flip balanced if it ever does.
    private var parkedApprovalCounts: [UUID: Int] = [:]

    /// Latest telemetry (model, tokens, est. cost) per pane, reported by the
    /// `cortland-telemetry` hook helper. Written on the main thread (the IPC
    /// delegate hops there); read by the agents-panel dashboard (P3).
    private(set) var paneTelemetry: [UUID: TranscriptUsage] = [:]

    /// In-flight `wait agent-status` requests, resolved by the
    /// PaneAgentStateChanged push rather than a poll. Keyed by request id so a
    /// fired deadline and a matching transition can't both resolve one twice.
    /// How an in-flight wait ended. `paneClosed` exists so a wait whose target
    /// pane disappears fails immediately with a real error, instead of leaving
    /// the client blocked until its full timeout elapses.
    enum WaitOutcome {
        case matched
        case timedOut
        case paneClosed
    }

    private struct StatusWait {
        let paneID: UUID
        let target: AgentState
        let completion: (WaitOutcome) -> Void
        let deadlineTimer: Timer
    }
    private var statusWaits: [UUID: StatusWait] = [:]

    /// In-flight `wait output` requests. The terminal does the incremental
    /// matching; this just holds the deadline + completion and the matcher
    /// handle so a fired deadline can cancel it.
    private struct OutputWait {
        let completion: (WaitOutcome) -> Void
        let deadlineTimer: Timer
        weak var terminal: TerminalViewController?
        let matcherID: UUID
    }
    private var outputWaits: [UUID: OutputWait] = [:]

    init(host: AutomationHost) {
        self.host = host
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(paneAgentStateChanged(_:)),
            name: .paneAgentStateChanged,
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
            selector: #selector(paneDidClose(_:)),
            name: .paneDidClose,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Called from the host's windowWillClose. Don't strand hook processes
    /// blocked on approval: cancel the visible sheet and resolve the queue.
    func prepareForWindowClose() {
        diffApproval.prepareForWindowClose()
    }

    // MARK: - Pane resolution

    private func automationPane(id: UUID) -> (tab: TabModel, pane: PaneModel, controller: PaneSplitController)? {
        guard let host else { return nil }
        for tab in host.automationTabs {
            guard let pane = tab.panes.first(where: { $0.id == id }),
                  let controller = host.automationSplitController(forTab: tab.id) else { continue }
            return (tab, pane, controller)
        }
        return nil
    }

    private func activeAutomationContext() -> (tab: TabModel, pane: PaneModel, controller: PaneSplitController)? {
        guard let host,
              let tabID = host.activeAutomationTabID,
              let tab = host.automationTabs.first(where: { $0.id == tabID }),
              let pane = tab.activePane,
              let controller = host.automationSplitController(forTab: tabID) else { return nil }
        return (tab, pane, controller)
    }

    private func automationPaneInfo(tab: TabModel, pane: PaneModel, controller: PaneSplitController) -> IPCPaneInfo {
        let type: String
        switch pane.paneType {
        case .terminal: type = "terminal"
        case .editor: type = "editor"
        case .diff: type = "diff"
        case .uncommittedChanges: type = "uncommitted_changes"
        }
        let pid = pane.terminalViewController?.shellProcessID ?? 0
        return IPCPaneInfo(
            paneID: pane.id.uuidString.lowercased(),
            tabID: tab.id.uuidString.lowercased(),
            type: type,
            cwd: pane.resolvedWorkingDirectory(),
            focused: controller.activePaneID == pane.id && tab.id == host?.activeAutomationTabID,
            agentStatus: pane.agentState.rawValue,
            processID: pid > 0 ? Int32(pid) : nil
        )
    }

    /// Drops telemetry for panes no longer present in any tab so the map can't
    /// grow without bound across a long session of transient panes/worktrees.
    /// `keepID` (the pane that just reported) is always retained, since a pane
    /// can report telemetry mid-churn before it's attached to a tab.
    private func pruneStaleTelemetry(keeping keepID: UUID) {
        guard let host else { return }
        var live = Set(host.automationTabs.flatMap { $0.panes.map(\.id) })
        live.insert(keepID)
        paneTelemetry = paneTelemetry.filter { live.contains($0.key) }
    }

    private func allAutomationPaneInfo() -> [IPCPaneInfo] {
        guard let host else { return [] }
        return host.automationTabs.flatMap { tab -> [IPCPaneInfo] in
            guard let controller = host.automationSplitController(forTab: tab.id) else { return [] }
            return tab.panes.map { automationPaneInfo(tab: tab, pane: $0, controller: controller) }
        }
    }

    // MARK: - Output waits (incremental match, not poll)

    /// Resolves when `match` appears in the terminal's output stream. The
    /// terminal matches each chunk incrementally; we only own the deadline and
    /// the completion. Replaces a 100ms timer that re-scanned the whole buffer
    /// and could miss a string that scrolled past the ring between two polls.
    private func waitForOutput(
        terminal: TerminalViewController,
        match: String,
        timeoutMS: Int,
        completion: @escaping (WaitOutcome) -> Void
    ) {
        let id = UUID()
        // Added to .common modes (not the default scheduledTimer, which only
        // runs in .default mode) so the deadline still fires while the main run
        // loop is in a modal/event-tracking mode.
        let timer = Timer(timeInterval: Double(timeoutMS) / 1000, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.resolveOutputWait(id, outcome: .timedOut) }
        }
        RunLoop.main.add(timer, forMode: .common)
        guard let matcherID = terminal.registerOutputMatcher(match, onMatch: { [weak self] in
            self?.resolveOutputWait(id, outcome: .matched)
        }) else {
            // Already present — resolve now without registering.
            timer.invalidate()
            completion(.matched)
            return
        }
        outputWaits[id] = OutputWait(completion: completion, deadlineTimer: timer, terminal: terminal, matcherID: matcherID)
    }

    private func resolveOutputWait(_ id: UUID, outcome: WaitOutcome) {
        guard let wait = outputWaits.removeValue(forKey: id) else { return }
        wait.deadlineTimer.invalidate()
        wait.terminal?.cancelOutputMatcher(wait.matcherID)
        wait.completion(outcome)
    }

    // MARK: - Agent-status waits (push, not poll)

    /// Resolves when the pane reaches `target` — driven by the
    /// PaneAgentStateChanged notification, with a one-shot deadline timer as the
    /// only fallback. Replaces a 100ms poll that woke thousands of times on a
    /// long timeout even though every transition already fires the push.
    private func waitForAgentStatus(
        paneID: UUID,
        target: AgentState,
        timeoutMS: Int,
        completion: @escaping (WaitOutcome) -> Void
    ) {
        if automationPane(id: paneID)?.pane.agentState == target {
            completion(.matched)
            return
        }
        let id = UUID()
        // .common modes so the deadline fires even during modal/tracking runloop
        // modes (scheduledTimer would only run in .default).
        let timer = Timer(timeInterval: Double(timeoutMS) / 1000, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.resolveStatusWait(id, outcome: .timedOut) }
        }
        RunLoop.main.add(timer, forMode: .common)
        statusWaits[id] = StatusWait(paneID: paneID, target: target, completion: completion, deadlineTimer: timer)
    }

    private func resolveStatusWait(_ id: UUID, outcome: WaitOutcome) {
        guard let wait = statusWaits.removeValue(forKey: id) else { return }
        wait.deadlineTimer.invalidate()
        wait.completion(outcome)
    }

    @objc private func paneAgentStateChanged(_ notification: Notification) {
        guard let pane = notification.object as? PaneModel else { return }
        let matched = statusWaits.filter { $0.value.paneID == pane.id && pane.agentState == $0.value.target }
        for id in matched.keys {
            resolveStatusWait(id, outcome: .matched)
        }
        emitAgentStateEvent(for: pane)
    }

    /// Fails every in-flight wait that targets a pane the moment it closes.
    /// Without this a `wait agent-status` / `wait output` whose pane goes away
    /// (worker finished and was closed, tab closed) silently blocks the client
    /// until its full timeout — minutes of a stale process waiting on nothing.
    @objc private func paneDidClose(_ notification: Notification) {
        guard let pane = notification.object as? PaneModel else { return }
        for id in statusWaits.filter({ $0.value.paneID == pane.id }).keys {
            resolveStatusWait(id, outcome: .paneClosed)
        }
        let closedTerminal = pane.terminalViewController
        for (id, wait) in outputWaits where wait.terminal == nil || wait.terminal === closedTerminal {
            resolveOutputWait(id, outcome: .paneClosed)
        }
    }

    @objc private func paneCommandStatusChanged(_ notification: Notification) {
        // Posted on both command start (status nil) and finish (status set);
        // the event stream only reports finished commands.
        guard let pane = notification.object as? PaneModel,
              let status = notification.userInfo?["status"] as? TerminalCommandStatus else { return }
        emitCommandEvent(for: pane, status: status)
    }

    // MARK: - Event stream emission

    private func emitAgentStateEvent(for pane: PaneModel) {
        // No hasSubscribers guard here (unlike command/diff): agent_state always
        // emits so EventBroadcaster's per-pane snapshot stays current for
        // backlog-on-connect, even while nobody is following yet.
        guard let context = automationPane(id: pane.id) else { return }
        var event = CortlandEvent(type: "agent_state", at: pane.agentStateChangedAt)
        event.paneID = pane.id.uuidString.lowercased()
        event.tabID = context.tab.id.uuidString.lowercased()
        event.state = pane.agentState.rawValue
        EventBroadcaster.shared.emit(event)
    }

    private func emitCommandEvent(for pane: PaneModel, status: TerminalCommandStatus) {
        guard EventBroadcaster.shared.hasSubscribers,
              let context = automationPane(id: pane.id) else { return }
        // The just-finished command line lives in the terminal's last record;
        // fall back to the status alone if integration didn't capture it.
        let lastRecord = pane.terminalViewController?.recentCommandRecords(limit: 1).last
        var event = CortlandEvent(type: "command")
        event.paneID = pane.id.uuidString.lowercased()
        event.tabID = context.tab.id.uuidString.lowercased()
        event.command = lastRecord?.command
        event.exitCode = status.exitCode
        event.duration = status.duration
        EventBroadcaster.shared.emit(event)
    }

    /// Emits a `telemetry` event so a supervisor following the stream sees token
    /// usage and est. cost per pane as it updates — the same data the dashboard
    /// shows. Guarded by `hasSubscribers` like the other non-state events.
    private func emitTelemetryEvent(paneID: UUID, tab: TabModel?, usage: TranscriptUsage) {
        guard EventBroadcaster.shared.hasSubscribers else { return }
        var event = CortlandEvent(type: "telemetry")
        event.paneID = paneID.uuidString.lowercased()
        event.tabID = tab?.id.uuidString.lowercased()
        event.model = usage.model
        event.inputTokens = usage.totalInputTokens
        event.outputTokens = usage.outputTokens
        event.costUSD = usage.estimatedCostUSD(rates: telemetryRates)
        event.turns = usage.userPrompts
        EventBroadcaster.shared.emit(event)
    }

    /// Emits a `diff` event for the hook edit-approval lifecycle so a supervisor
    /// can see edits queue and resolve without polling.
    private func emitDiffEvent(path: String, decision: String) {
        guard EventBroadcaster.shared.hasSubscribers else { return }
        var event = CortlandEvent(type: "diff")
        event.path = path
        event.decision = decision
        EventBroadcaster.shared.emit(event)
    }

    // MARK: - IPCServerDelegate

    func ipcServer(
        _ server: IPCServer,
        didReceiveCommand command: IPCCommandType,
        onClientDisconnect registerDisconnect: @escaping (@escaping @Sendable () -> Void) -> Void,
        completion: @escaping @Sendable (IPCResponse) -> Void
    ) {
        // Each verb has a focused handler below. They all run on the main thread
        // (the server hops here before invoking the delegate) and may either
        // reply synchronously or hold `completion` for a deferred answer (diff
        // approval, waits, worktree git shell-outs). `registerDisconnect` is only
        // wired for the one verb that can park indefinitely on a human: show_diff.
        switch command {
        case .ping:
            handlePing(completion: completion)
        case .newTab(let cwd):
            handleNewTab(cwd: cwd, completion: completion)
        case .showDiff(let paneID, let path, let old, let new):
            handleShowDiff(paneID: paneID, path: path, old: old, new: new,
                           registerDisconnect: registerDisconnect, completion: completion)
        case .agentReady:
            handleSetAgentState(.ready, completion: completion)
        case .agentBusy:
            handleSetAgentState(.working, completion: completion)
        case .agentDone:
            handleSetAgentState(.done, completion: completion)
        case .agentIdle:
            handleSetAgentState(.idle, completion: completion)
        case .agentStatus(let paneID, let status):
            handleAgentStatus(paneID: paneID, status: status, completion: completion)
        case .paneList:
            handlePaneList(completion: completion)
        case .agentList:
            handleAgentList(completion: completion)
        case .paneCurrent(let requestedPaneID):
            handlePaneCurrent(paneID: requestedPaneID, completion: completion)
        case .paneSplit(let paneID, let direction, let cwd, let command, let focus, let worktree):
            handlePaneSplit(paneID: paneID, direction: direction, cwd: cwd, command: command, focus: focus, worktree: worktree, completion: completion)
        case .paneFocus(let paneID):
            handlePaneFocus(paneID: paneID, completion: completion)
        case .paneClose(let paneID):
            handlePaneClose(paneID: paneID, completion: completion)
        case .paneSendText(let paneID, let text):
            handlePaneSendText(paneID: paneID, text: text, completion: completion)
        case .paneRun(let paneID, let text):
            handlePaneRun(paneID: paneID, text: text, completion: completion)
        case .paneSendKey(let paneID, let key):
            handlePaneSendKey(paneID: paneID, key: key, completion: completion)
        case .paneRead(let paneID, let source, let lines, let json, let since):
            handlePaneRead(paneID: paneID, source: source, lines: lines, json: json, since: since, completion: completion)
        case .waitAgentStatus(let paneID, let status, let timeoutMS):
            handleWaitAgentStatus(paneID: paneID, status: status, timeoutMS: timeoutMS, completion: completion)
        case .waitOutput(let paneID, let match, let timeoutMS):
            handleWaitOutput(paneID: paneID, match: match, timeoutMS: timeoutMS, completion: completion)
        case .worktreeList(let cwd):
            handleWorktreeList(cwd: cwd, completion: completion)
        case .worktreeRemove(let branch, let cwd, let force):
            handleWorktreeRemove(branch: branch, cwd: cwd, force: force, completion: completion)
        case .worktreePrune(let cwd):
            handleWorktreePrune(cwd: cwd, completion: completion)
        case .reportTelemetry(let paneID, let usage):
            handleReportTelemetry(paneID: paneID, usage: usage, completion: completion)
        case .resetTelemetry(let paneID):
            handleResetTelemetry(paneID: paneID, completion: completion)
        }
    }

    // MARK: - Per-command handlers

    private func handlePing(completion: @escaping @Sendable (IPCResponse) -> Void) {
        completion(IPCResponse(ok: true))
    }

    private func handleNewTab(cwd: String?, completion: @escaping @Sendable (IPCResponse) -> Void) {
        if host?.automationCreateNewTab(workingDirectory: cwd) == true {
            completion(IPCResponse(ok: true))
        } else {
            completion(IPCResponse(ok: false, error: "Tab limit (\(Limits.maxTabs)) reached; close a tab first"))
        }
    }

    private func handleShowDiff(
        paneID: UUID?,
        path: String,
        old: String,
        new: String,
        registerDisconnect: @escaping (@escaping @Sendable () -> Void) -> Void,
        completion: @escaping @Sendable (IPCResponse) -> Void
    ) {
        if old.isEmpty && new.isEmpty {
            // `cortland-ctl open-diff <file>`: just view the file.
            host?.automationOpenFile(URL(fileURLWithPath: path))
            completion(IPCResponse(ok: true))
        } else {
            diffApproval.requestApproval(
                paneID: paneID, path: path, old: old, new: new,
                registerDisconnect: registerDisconnect
            ) { accepted in
                completion(IPCResponse(ok: true, accepted: accepted))
            }
        }
    }

    /// Flips a pane's agent status while an edit-gate entry waits at the desk.
    /// The pane reads "needs input" (`.ready`) from its first parked edit and
    /// returns to "working" once its last one resolves. Delivered through the
    /// pane's detector like any other authoritative status report — the agent is
    /// blocked in its edit hook the whole time, so no real hook report races it.
    private func setPaneParked(_ paneID: UUID, parked: Bool) {
        guard let terminal = automationPane(id: paneID)?.pane.terminalViewController else { return }
        let count = parkedApprovalCounts[paneID] ?? 0
        if parked {
            parkedApprovalCounts[paneID] = count + 1
            if count == 0 { terminal.applyAgentStatusReport(.ready) }
        } else {
            let remaining = max(0, count - 1)
            if remaining == 0 {
                parkedApprovalCounts[paneID] = nil
                terminal.applyAgentStatusReport(.working)
            } else {
                parkedApprovalCounts[paneID] = remaining
            }
        }
    }

    private func handleSetAgentState(_ state: AgentState, completion: @escaping @Sendable (IPCResponse) -> Void) {
        host?.automationSetActiveTabAgentState(state)
        completion(IPCResponse(ok: true))
    }

    /// A status hook reporting for the pane it ran in. Routed to that pane's
    /// detector, which treats it exactly like the OSC 666 escape it would have
    /// written had it had a controlling terminal — including standing the text
    /// heuristics down for the rest of the agent's life in this pane.
    private func handleAgentStatus(
        paneID: UUID,
        status: String,
        completion: @escaping @Sendable (IPCResponse) -> Void
    ) {
        guard let terminal = automationPane(id: paneID)?.pane.terminalViewController else {
            completion(IPCResponse(ok: false, error: "Terminal pane not found"))
            return
        }
        terminal.applyAgentStatusReport(token: status)
        completion(IPCResponse())
    }

    /// The report that triggered this is being delivered regardless (see the
    /// call site in IPCServer) — an old helper reporting `busy` is still telling
    /// the truth about `busy`. What it can't do is speak any part of the contract
    /// added since it was installed, so the pane it named flags itself once.
    func ipcServer(
        _ server: IPCServer,
        didReceiveStaleAgentStatusReport paneID: UUID,
        protocolVersion: Int
    ) {
        guard let terminal = automationPane(id: paneID)?.pane.terminalViewController else { return }
        terminal.noteStaleAgentStatusHelper(reportedVersion: protocolVersion)
    }

    private func handlePaneList(completion: @escaping @Sendable (IPCResponse) -> Void) {
        completion(IPCResponse(result: IPCResult(panes: allAutomationPaneInfo())))
    }

    private func handleAgentList(completion: @escaping @Sendable (IPCResponse) -> Void) {
        completion(IPCResponse(result: IPCResult(agents: allAgentInfo())))
    }

    /// Fleet status for every pane with agent activity — the wire twin of the
    /// Agents sidebar dashboard. Idle panes are skipped (the dashboard drops
    /// idle tabs too): a listed row always names a working, ready, or done
    /// agent. Model and cost come from the same per-pane telemetry the dashboard
    /// reads, so this adds no new tracking.
    private func allAgentInfo() -> [IPCAgentInfo] {
        guard let host else { return [] }
        let now = Date()
        return host.automationTabs.flatMap { tab -> [IPCAgentInfo] in
            tab.panes.compactMap { pane -> IPCAgentInfo? in
                guard pane.agentState != .idle else { return nil }
                let usage = paneTelemetry[pane.id]
                return IPCAgentInfo(
                    paneID: pane.id.uuidString.lowercased(),
                    tabID: tab.id.uuidString.lowercased(),
                    tab: tab.title,
                    agent: usage?.model.map(TelemetryFormat.shortModel),
                    state: pane.agentState.rawValue,
                    sinceS: max(0, Int(now.timeIntervalSince(pane.agentStateChangedAt))),
                    costUSD: usage?.estimatedCostUSD(rates: telemetryRates),
                    worktree: pane.isInWorktree ? pane.gitBranch : nil
                )
            }
        }
    }

    private func handlePaneCurrent(paneID: UUID?, completion: @escaping @Sendable (IPCResponse) -> Void) {
        let context = paneID.map { automationPane(id: $0) } ?? activeAutomationContext()
        guard let context else {
            completion(IPCResponse(ok: false, error: "Pane not found"))
            return
        }
        completion(IPCResponse(result: IPCResult(
            pane: automationPaneInfo(tab: context.tab, pane: context.pane, controller: context.controller)
        )))
    }

    private func handlePaneSplit(
        paneID: UUID,
        direction: SplitDirection,
        cwd: String?,
        command: [String]?,
        focus: Bool,
        worktree: String?,
        completion: @escaping @Sendable (IPCResponse) -> Void
    ) {
        guard let context = automationPane(id: paneID) else {
            completion(IPCResponse(ok: false, error: "Pane not found"))
            return
        }
        guard let branch = worktree else {
            completeSplit(paneID: paneID, direction: direction, cwd: cwd, command: command, focus: focus, completion: completion)
            return
        }
        // Creating the worktree shells out to git (checks out files), so do
        // it off the main thread, then hop back to perform the UI split in
        // the resulting directory.
        let repoDirectory = context.pane.resolvedWorkingDirectory()
            ?? cwd ?? FileManager.default.currentDirectoryPath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try WorktreeService().ensureWorktree(forBranch: branch, directory: repoDirectory) }
            DispatchQueue.main.async {
                switch result {
                case .success(let worktreePath):
                    // If the coordinator deallocated (window closed mid-
                    // checkout), still answer the client — an optional-chained
                    // no-op here would leave it blocked forever and leak its fd.
                    guard let self else {
                        completion(IPCResponse(ok: false, error: "Window closed before split completed"))
                        return
                    }
                    self.completeSplit(paneID: paneID, direction: direction, cwd: worktreePath, command: command, focus: focus, completion: completion)
                case .failure(let error):
                    completion(IPCResponse(ok: false, error: Self.worktreeErrorMessage(error)))
                }
            }
        }
    }

    private func handlePaneFocus(paneID: UUID, completion: @escaping @Sendable (IPCResponse) -> Void) {
        guard let context = automationPane(id: paneID), context.controller.focusPane(id: paneID) else {
            completion(IPCResponse(ok: false, error: "Pane not found"))
            return
        }
        completion(IPCResponse(result: IPCResult(
            pane: automationPaneInfo(tab: context.tab, pane: context.pane, controller: context.controller)
        )))
    }

    private func handlePaneClose(paneID: UUID, completion: @escaping @Sendable (IPCResponse) -> Void) {
        guard let context = automationPane(id: paneID), context.controller.closePane(id: paneID) else {
            completion(IPCResponse(ok: false, error: "Pane not found or cannot close the last pane"))
            return
        }
        completion(IPCResponse())
    }

    private func handlePaneSendText(paneID: UUID, text: String, completion: @escaping @Sendable (IPCResponse) -> Void) {
        guard let terminal = automationPane(id: paneID)?.pane.terminalViewController else {
            completion(IPCResponse(ok: false, error: "Terminal pane not found"))
            return
        }
        terminal.send(text: text)
        completion(IPCResponse())
    }

    private func handlePaneRun(paneID: UUID, text: String, completion: @escaping @Sendable (IPCResponse) -> Void) {
        guard let terminal = automationPane(id: paneID)?.pane.terminalViewController else {
            completion(IPCResponse(ok: false, error: "Terminal pane not found"))
            return
        }
        terminal.send(text: text)
        // TUIs that treat a burst of stdin as a paste (Claude Code, Codex)
        // swallow a carriage return delivered in the same chunk, leaving
        // the text sitting in the input box unsubmitted. Deliver Enter as
        // its own write once the paste settles so it registers as a real
        // keypress; shells execute on it either way.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) {
            terminal.send(key: "enter")
            completion(IPCResponse())
        }
    }

    private func handlePaneSendKey(paneID: UUID, key: String, completion: @escaping @Sendable (IPCResponse) -> Void) {
        guard let terminal = automationPane(id: paneID)?.pane.terminalViewController else {
            completion(IPCResponse(ok: false, error: "Terminal pane not found"))
            return
        }
        guard terminal.send(key: key) else {
            completion(IPCResponse(ok: false, error: "Unsupported key: \(key)"))
            return
        }
        completion(IPCResponse())
    }

    private func handlePaneRead(
        paneID: UUID,
        source: String,
        lines: Int?,
        json: Bool,
        since: String?,
        completion: @escaping @Sendable (IPCResponse) -> Void
    ) {
        guard let terminal = automationPane(id: paneID)?.pane.terminalViewController else {
            completion(IPCResponse(ok: false, error: "Terminal pane not found"))
            return
        }
        if json {
            let records = terminal.recentCommandRecords(limit: lines).map {
                IPCCommandRecord(command: $0.command, exitCode: $0.exitCode, duration: $0.duration, output: $0.output)
            }
            completion(IPCResponse(result: IPCResult(commands: records)))
        } else if source == "recent" {
            // Only the recent-output buffer has a stable cursor; a `since` delta
            // read reports the new cursor (and `truncated` when it re-synced).
            //
            // IPC commands run on the main thread, and normalizing a recent read
            // is real work: two regex passes over a 64KB stream, a redraw collapse,
            // a line cap. So copy the pane's buffers here (cheap) and do the rest
            // on a background queue — `sendResponse` already runs off main.
            let snapshot = terminal.recentReadSnapshot()
            DispatchQueue.global(qos: .userInitiated).async {
                let read = TerminalText.recentRead(snapshot, since: since, lineLimit: lines)
                completion(IPCResponse(result: IPCResult(
                    text: read.text, cursor: read.cursor, truncated: read.truncated ? true : nil)))
            }
        } else {
            completion(IPCResponse(result: IPCResult(text: terminal.visibleScreenText(lineLimit: lines))))
        }
    }

    private func handleWaitAgentStatus(
        paneID: UUID,
        status: AgentState,
        timeoutMS: Int,
        completion: @escaping @Sendable (IPCResponse) -> Void
    ) {
        guard automationPane(id: paneID) != nil else {
            completion(IPCResponse(ok: false, error: "Pane not found"))
            return
        }
        waitForAgentStatus(paneID: paneID, target: status, timeoutMS: timeoutMS) { outcome in
            switch outcome {
            case .matched:
                completion(IPCResponse(result: IPCResult(matched: true)))
            case .timedOut:
                completion(IPCResponse(result: IPCResult(matched: false)))
            case .paneClosed:
                completion(IPCResponse(ok: false, error: "Pane closed while waiting"))
            }
        }
    }

    private func handleWaitOutput(
        paneID: UUID,
        match: String,
        timeoutMS: Int,
        completion: @escaping @Sendable (IPCResponse) -> Void
    ) {
        guard let terminal = automationPane(id: paneID)?.pane.terminalViewController else {
            completion(IPCResponse(ok: false, error: "Terminal pane not found"))
            return
        }
        waitForOutput(terminal: terminal, match: match, timeoutMS: timeoutMS) { outcome in
            switch outcome {
            case .matched:
                completion(IPCResponse(result: IPCResult(matched: true)))
            case .timedOut:
                completion(IPCResponse(result: IPCResult(matched: false)))
            case .paneClosed:
                completion(IPCResponse(ok: false, error: "Pane closed while waiting"))
            }
        }
    }

    private func handleWorktreeList(cwd: String?, completion: @escaping @Sendable (IPCResponse) -> Void) {
        let directory = worktreeDirectory(cwd: cwd)
        // Listing runs `git worktree list --porcelain`, so shell out off the
        // main thread and hop back to reply, matching the other worktree verbs.
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () throws -> [IPCWorktreeInfo] in
                guard let repoRoot = GitService().repositoryRoot(from: directory) else {
                    throw WorktreeService.WorktreeError.notAGitRepository
                }
                return try WorktreeService().listWorktrees(repoRoot: repoRoot).map {
                    IPCWorktreeInfo(path: $0.path, branch: $0.branch, head: $0.head,
                                    detached: $0.isDetached, locked: $0.isLocked, bare: $0.isBare)
                }
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let worktrees):
                    completion(IPCResponse(result: IPCResult(worktrees: worktrees)))
                case .failure(let error):
                    completion(IPCResponse(ok: false, error: Self.worktreeErrorMessage(error)))
                }
            }
        }
    }

    private func handleWorktreeRemove(
        branch: String,
        cwd: String?,
        force: Bool,
        completion: @escaping @Sendable (IPCResponse) -> Void
    ) {
        let directory = worktreeDirectory(cwd: cwd)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try WorktreeService().removeWorktree(forBranch: branch, directory: directory, force: force) }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    completion(IPCResponse(ok: true))
                case .failure(let error):
                    completion(IPCResponse(ok: false, error: Self.worktreeErrorMessage(error)))
                }
            }
        }
    }

    private func handleWorktreePrune(cwd: String?, completion: @escaping @Sendable (IPCResponse) -> Void) {
        let directory = worktreeDirectory(cwd: cwd)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try WorktreeService().pruneWorktrees(directory: directory) }
            DispatchQueue.main.async {
                switch result {
                case .success(let output):
                    completion(IPCResponse(ok: true, result: IPCResult(text: output)))
                case .failure(let error):
                    completion(IPCResponse(ok: false, error: Self.worktreeErrorMessage(error)))
                }
            }
        }
    }

    private func handleReportTelemetry(
        paneID: UUID,
        usage: TranscriptUsage,
        completion: @escaping @Sendable (IPCResponse) -> Void
    ) {
        // Store the latest per-pane usage. Keep it even for a pane we can't
        // currently resolve — it may be mid-churn.
        paneTelemetry[paneID] = usage
        pruneStaleTelemetry(keeping: paneID)
        let cost = usage.estimatedCostUSD(rates: telemetryRates).map { String(format: "$%.4f", $0) } ?? "n/a"
        Log.debug("telemetry pane=\(paneID.uuidString.prefix(8)) model=\(usage.model ?? "?") in=\(usage.totalInputTokens) out=\(usage.outputTokens) est=\(cost)", category: "telemetry")
        // Surface it on the owning tab so the agents-panel dashboard can read
        // it, and nudge the panel to refresh.
        let tab = automationPane(id: paneID)?.tab
        tab.map(updateTabTelemetry)
        NotificationCenter.default.post(name: .paneTelemetryChanged, object: tab)
        emitTelemetryEvent(paneID: paneID, tab: tab, usage: usage)
        completion(IPCResponse(ok: true))
    }

    private func handleResetTelemetry(paneID: UUID, completion: @escaping @Sendable (IPCResponse) -> Void) {
        // A new session started in this pane (SessionStart hook after
        // startup or /clear): the previous session's usage no longer
        // describes it, so blank the dashboard row instead of showing the
        // old context bar until the first turn of the new session ends.
        paneTelemetry.removeValue(forKey: paneID)
        Log.debug("telemetry reset pane=\(paneID.uuidString.prefix(8))", category: "telemetry")
        let tab = automationPane(id: paneID)?.tab
        tab.map(updateTabTelemetry)
        NotificationCenter.default.post(name: .paneTelemetryChanged, object: tab)
        emitTelemetryEvent(paneID: paneID, tab: tab, usage: TranscriptUsage())
        completion(IPCResponse(ok: true))
    }

    /// Effective rate card (config overrides over defaults), via the host.
    private var telemetryRates: [String: TelemetryRate] {
        host?.telemetryRates ?? TelemetryRates.defaults
    }

    /// Sets `tab.telemetry` to its primary agent pane's usage: the active pane's
    /// if it reported, else the pane with the most billed responses. Avoids
    /// summing across panes, which would conflate distinct agents/models. Prices
    /// it once here so the view never needs the rate card. Every reporting
    /// pane also lands in `tab.paneTelemetries` (each priced at its own model)
    /// so cost roll-ups see the whole split, not just the primary pane.
    private func updateTabTelemetry(_ tab: TabModel) {
        let usage: TranscriptUsage?
        if let active = tab.activePane, let activeUsage = paneTelemetry[active.id] {
            usage = activeUsage
        } else {
            usage = tab.panes
                .compactMap { paneTelemetry[$0.id] }
                .max(by: { $0.assistantResponses < $1.assistantResponses })
        }
        tab.telemetry = usage
        tab.telemetryCostUSD = usage?.estimatedCostUSD(rates: telemetryRates)
        tab.paneTelemetries = tab.panes.compactMap { pane in
            paneTelemetry[pane.id].map {
                PaneTelemetry(paneID: pane.id, usage: $0, costUSD: $0.estimatedCostUSD(rates: telemetryRates))
            }
        }
    }

    /// Resolves the directory a worktree command operates from: an explicit
    /// `--cwd`, else the active pane's working directory, else the process cwd.
    private func worktreeDirectory(cwd: String?) -> String {
        cwd
            ?? activeAutomationContext()?.pane.resolvedWorkingDirectory()
            ?? FileManager.default.currentDirectoryPath
    }

    // MARK: - Pane split

    /// Performs the UI split and replies with the new pane, re-resolving the
    /// target so a worktree split (which detoured through a background queue)
    /// still finds it.
    private func completeSplit(
        paneID: UUID,
        direction: SplitDirection,
        cwd: String?,
        command: [String]?,
        focus: Bool,
        completion: @escaping @Sendable (IPCResponse) -> Void
    ) {
        guard let context = automationPane(id: paneID) else {
            completion(IPCResponse(ok: false, error: "Pane not found"))
            return
        }
        guard let pane = context.controller.splitPane(
            direction: direction,
            targetPaneID: paneID,
            initialDirectory: cwd,
            command: command,
            focus: focus
        ) else {
            completion(IPCResponse(ok: false, error: "Unable to split pane (the tab may be at its pane limit)"))
            return
        }
        completion(IPCResponse(result: IPCResult(
            pane: automationPaneInfo(tab: context.tab, pane: pane, controller: context.controller)
        )))
    }

    private static func worktreeErrorMessage(_ error: Error) -> String {
        switch error {
        case WorktreeService.WorktreeError.notAGitRepository:
            return "Not a git repository — worktree commands need a directory inside one"
        case WorktreeService.WorktreeError.noWorktreeForBranch(let branch):
            return "No worktree registered for branch '\(branch)'"
        case WorktreeService.WorktreeError.gitFailed(let message):
            return "git worktree failed: \(message)"
        default:
            return "Worktree operation failed: \(error.localizedDescription)"
        }
    }
}
