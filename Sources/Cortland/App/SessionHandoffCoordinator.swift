import Cocoa

// MARK: - Pure decisions

/// The text and paths "Continue in Fresh Session" needs. Pure so the prompt
/// wording, `{path}` substitution, and agent detection are unit-testable
/// without a window.
enum SessionHandoff {
    /// Token a configured `[handoff] prompt` uses to place the file path.
    static let pathToken = "{path}"

    /// Handoff file for a pane in `cwd`. It lives inside the working directory
    /// on purpose: agents in Cortland's Auto approval modes can write inside
    /// the project without prompting, but would prompt for a path under
    /// `~/.config`. Cortland only composes the path; the agent creates it.
    static func handoffPath(cwd: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return URL(fileURLWithPath: cwd)
            .appendingPathComponent(".cortland/handoffs/handoff-\(formatter.string(from: date)).md")
            .path
    }

    enum StartCheck: Equatable {
        case ok
        case noAgent
        case agentBusy
    }

    /// Whether a handoff may start in a pane. A working agent is refused:
    /// agent TUIs queue a prompt typed mid-turn, so the wait would see the
    /// current turn end, find no file, and alert while the queued handoff
    /// then runs anyway. Ready and done are accepted.
    static func startCheck(isTerminal: Bool, agentState: AgentState) -> StartCheck {
        guard isTerminal, agentState != .idle else { return .noAgent }
        return agentState == .working ? .agentBusy : .ok
    }

    /// Which CLI the pane is running, from its telemetry model id. Nothing in
    /// the pane records the agent directly, but Claude Code always reports a
    /// `claude-*` model. An unknown model defaults to Claude Code.
    static func agent(forModel model: String?) -> SessionAgent {
        guard let model else { return .claude }
        return model.lowercased().hasPrefix("claude") ? .claude : .codex
    }

    static func defaultHandoffPrompt(path: String) -> String {
        "Write a handoff document to \(path) (create the directory if needed) so that a fresh agent with no memory of this conversation can continue the work. Include: the goal, the decisions made and why, what is finished, what is in progress, the exact next steps, and the files and commands that matter. Be specific and concise. Do not do any other work. When the file is written, stop."
    }

    /// The prompt sent to the old agent: the configured one when set, with
    /// `{path}` substituted (or the path appended when the token is missing,
    /// so the agent always knows where to write).
    static func handoffPrompt(path: String, configured: String?) -> String {
        guard let configured = configured?.trimmingCharacters(in: .whitespacesAndNewlines),
              !configured.isEmpty else {
            return defaultHandoffPrompt(path: path)
        }
        if configured.contains(pathToken) {
            return configured.replacingOccurrences(of: pathToken, with: path)
        }
        return "\(configured) Write the handoff document to \(path)."
    }

    static func continuationPrompt(path: String) -> String {
        "This is a fresh session continuing earlier work. Read \(path) first, then continue from its next steps. Do not repeat work it says is finished. Confirm in one line what you are picking up before you start."
    }

    /// Argv for the fresh session: the CLI plus one positional initial prompt.
    static func continuationArgv(agent: SessionAgent, path: String) -> [String] {
        let program: String
        switch agent {
        case .claude: program = "claude"
        case .codex: program = "codex"
        }
        return [program, continuationPrompt(path: path)]
    }
}

/// The wait rule between sending the handoff prompt and opening the fresh
/// session. Pure (events and the clock come in, an action comes out) so every
/// branch is testable without a pane or a timer.
struct HandoffWaitMachine {
    /// How long the agent has to report busy after the prompt is sent.
    static let startTimeout: TimeInterval = 30
    /// How long the agent may stay busy writing the handoff.
    static let workingTimeout: TimeInterval = 600

    enum Event: Equatable {
        case agentState(AgentState)
        case tick
        case paneClosed
    }

    enum Action: Equatable {
        case keepWaiting
        /// The agent finished; open the fresh session if the file exists.
        case checkHandoffFile
        /// The agent is asking the user something; hand them the pane.
        case focusPane
        case timedOutBeforeWorking
        case timedOutWhileWorking
        case cancel
    }

    private enum Phase {
        case awaitingWorking(since: Date)
        case working(since: Date)
        case finished
    }

    private var phase: Phase

    init(promptSentAt: Date) {
        phase = .awaitingWorking(since: promptSentAt)
    }

    var isFinished: Bool {
        if case .finished = phase { return true }
        return false
    }

    mutating func handle(_ event: Event, at now: Date) -> Action {
        switch (phase, event) {
        case (.finished, _):
            return .keepWaiting
        case (_, .paneClosed):
            phase = .finished
            return .cancel
        case (.awaitingWorking(let since), .agentState(let state)):
            // Before the agent picks up the prompt, the pane still reports the
            // state it was in (often done), so only busy moves things along.
            if state == .working {
                phase = .working(since: now)
                return .keepWaiting
            }
            return timeoutCheck(since: since, limit: Self.startTimeout, now: now, action: .timedOutBeforeWorking)
        case (.awaitingWorking(let since), .tick):
            return timeoutCheck(since: since, limit: Self.startTimeout, now: now, action: .timedOutBeforeWorking)
        case (.working(let since), .agentState(let state)):
            switch state {
            case .working:
                return timeoutCheck(since: since, limit: Self.workingTimeout, now: now, action: .timedOutWhileWorking)
            case .ready:
                phase = .finished
                return .focusPane
            case .done, .idle:
                // Idle after busy means the agent exited; the file check still
                // decides whether it did its job.
                phase = .finished
                return .checkHandoffFile
            }
        case (.working(let since), .tick):
            return timeoutCheck(since: since, limit: Self.workingTimeout, now: now, action: .timedOutWhileWorking)
        }
    }

    private mutating func timeoutCheck(since: Date, limit: TimeInterval, now: Date, action: Action) -> Action {
        guard now.timeIntervalSince(since) > limit else { return .keepWaiting }
        phase = .finished
        return action
    }
}

// MARK: - Coordinator

/// What the handoff coordinator needs from the window. MainWindowController
/// stays the owner of tabs and panes; the coordinator only drives the flow.
@MainActor
protocol SessionHandoffHost: AnyObject {
    var handoffWindow: NSWindow? { get }
    var handoffTabs: [TabModel] { get }
    var handoffConfig: HandoffConfig? { get }
    /// The pane's reported telemetry model id, if its agent has reported one.
    func handoffTelemetryModel(forPane paneID: UUID) -> String?
    /// Opens a tab running `command` in `workingDirectory`, named `customTitle`
    /// when one is given (nil keeps the automatic title).
    func handoffOpenTab(workingDirectory: String, command: [String], customTitle: String?)
    func handoffFocusPane(id: UUID)
}

/// Runs "Continue in Fresh Session": asks the pane's agent to write a handoff
/// file, waits for it without blocking the main thread, then opens a new tab
/// with a fresh session of the same CLI pointed at that file. The original tab
/// is left alone.
@MainActor
final class SessionHandoffCoordinator {
    private weak var host: SessionHandoffHost?

    private final class Handoff {
        let pane: PaneModel
        let tabID: UUID
        let path: String
        let cwd: String
        let agent: SessionAgent
        var machine: HandoffWaitMachine
        var timer: Timer?

        init(pane: PaneModel, tabID: UUID, path: String, cwd: String, agent: SessionAgent, machine: HandoffWaitMachine) {
            self.pane = pane
            self.tabID = tabID
            self.path = path
            self.cwd = cwd
            self.agent = agent
            self.machine = machine
        }
    }

    /// In-flight handoffs by pane id; a second request for the same pane is ignored.
    private var inFlight: [UUID: Handoff] = [:]
    // Set on the main actor; read once in the nonisolated deinit at end-of-life.
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init(host: SessionHandoffHost) {
        self.host = host
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .paneAgentStateChanged, object: nil, queue: .main) { [weak self] note in
            guard let pane = note.object as? PaneModel,
                  let state = note.userInfo?["agentState"] as? AgentState else { return }
            MainActor.assumeIsolated {
                self?.deliver(.agentState(state), toPane: pane.id)
            }
        })
        observers.append(center.addObserver(forName: .paneDidClose, object: nil, queue: .main) { [weak self] note in
            guard let pane = note.object as? PaneModel else { return }
            MainActor.assumeIsolated {
                self?.deliver(.paneClosed, toPane: pane.id)
            }
        })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Starts a handoff for the active pane of `tab`.
    func continueInFreshSession(tab: TabModel) {
        guard let pane = tab.activePane else { return }
        guard inFlight[pane.id] == nil else { return }

        switch SessionHandoff.startCheck(isTerminal: pane.paneType == .terminal, agentState: pane.agentState) {
        case .noAgent:
            showAlert(
                message: "No agent is running in this pane",
                info: "Continue in Fresh Session hands an agent's work to a new session. Start Claude Code or Codex in the pane first."
            )
            return
        case .agentBusy:
            showAlert(
                message: "The agent is still working",
                info: "Wait for the agent to finish its current turn, then try again. The original session is untouched."
            )
            return
        case .ok:
            break
        }
        guard let terminal = pane.terminalViewController else { return }
        guard let cwd = pane.resolvedWorkingDirectory() else {
            showAlert(
                message: "Could not find the pane's working directory",
                info: "The handoff file is written inside the working directory, so Cortland needs to know where the pane is."
            )
            return
        }

        let now = Date()
        let path = SessionHandoff.handoffPath(cwd: cwd, date: now)
        let agent = SessionHandoff.agent(forModel: host?.handoffTelemetryModel(forPane: pane.id))
        let prompt = SessionHandoff.handoffPrompt(path: path, configured: host?.handoffConfig?.prompt)

        let handoff = Handoff(
            pane: pane, tabID: tab.id, path: path, cwd: cwd, agent: agent,
            machine: HandoffWaitMachine(promptSentAt: now)
        )
        inFlight[pane.id] = handoff

        // Same two-step delivery as sendToActiveTerminal: agent TUIs treat a
        // burst of stdin as a paste and swallow an Enter in the same chunk.
        terminal.send(text: prompt)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) {
            _ = terminal.send(key: "enter")
        }

        // Timeouts only advance on events, so a quiet pane needs a clock.
        handoff.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self, paneID = pane.id] _ in
            MainActor.assumeIsolated {
                self?.deliver(.tick, toPane: paneID)
            }
        }
    }

    private func deliver(_ event: HandoffWaitMachine.Event, toPane paneID: UUID) {
        guard let handoff = inFlight[paneID] else { return }
        let action = handoff.machine.handle(event, at: Date())
        if handoff.machine.isFinished {
            handoff.timer?.invalidate()
            inFlight.removeValue(forKey: paneID)
        }

        switch action {
        case .keepWaiting, .cancel:
            break
        case .focusPane:
            host?.handoffFocusPane(id: paneID)
        case .timedOutBeforeWorking:
            showAlert(
                message: "The agent did not start the handoff",
                info: "Cortland sent the handoff prompt, but the agent did not report working within \(Int(HandoffWaitMachine.startTimeout)) seconds. The original session is untouched."
            )
        case .timedOutWhileWorking:
            showAlert(
                message: "The handoff took too long",
                info: "The agent was still working after \(Int(HandoffWaitMachine.workingTimeout / 60)) minutes, so Cortland stopped waiting. The original session is untouched."
            )
        case .checkHandoffFile:
            finish(handoff)
        }
    }

    private func finish(_ handoff: Handoff) {
        guard FileManager.default.fileExists(atPath: handoff.path) else {
            showAlert(
                message: "No handoff file was written",
                info: "The agent finished without writing \(handoff.path), so no fresh session was opened. The original session is untouched."
            )
            return
        }
        guard let host else { return }
        let originalTitle = host.handoffTabs.first(where: { $0.id == handoff.tabID })?.customTitle
        let argv = SessionHandoff.continuationArgv(agent: handoff.agent, path: handoff.path)
        let title = originalTitle.flatMap { $0.isEmpty ? nil : "Continuing: \($0)" }
        host.handoffOpenTab(workingDirectory: handoff.cwd, command: argv, customTitle: title)
    }

    private func showAlert(message: String, info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.addButton(withTitle: "OK")
        if let window = host?.handoffWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
