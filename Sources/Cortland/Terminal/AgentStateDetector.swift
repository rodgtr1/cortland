import Foundation

/// The per-pane agent-state machine, extracted from TerminalViewController so
/// its interacting pieces (explicit OSC 666 reports vs. text heuristics, the
/// done-after-quiet timer, blocked-state screen polling, prompt-marker
/// suppression) are testable on their own.
///
/// Inputs arrive from the terminal pipeline:
///  - `handleStatusToken(_:)` for explicit OSC 666 hook reports,
///  - `processHeuristics(chunk:)` for ANSI-raw output when no report arrived,
///  - `handleUserInput()` for genuine keystrokes,
///  - `reset()` / `markWorkerFinished()` for process lifecycle.
/// State changes surface through `onStateChange`; blocked-state polling reads
/// the visible screen through `readVisibleScreen`.
final class AgentStateDetector {
    /// Called (async on the main queue, deduped) whenever the detected state
    /// changes.
    var onStateChange: ((AgentState) -> Void)?
    /// Supplies the bottom-of-screen text for blocked-state polling.
    var readVisibleScreen: (() -> String)?

    private(set) var state: AgentState = .idle
    // Once the session reports state via OSC 666 (Claude/Codex hooks), those
    // reports are authoritative and the text heuristics stand down.
    private(set) var hasExplicitStatus = false

    private var recentOutput = ""
    private var suppressedPromptMarkers: Set<String> = []
    // Set by a `gated` report: an approval request that a machine reviewer is
    // answering. The pane is working, but the reviewer may escalate to the human
    // and no hook reports that, so the screen scrape runs even though the pane is
    // hook-authoritative. See `applyExplicitState`.
    private var escalationWatch = false
    // nonisolated(unsafe) only so deinit's off-main branch can hand the timers
    // to the main queue for invalidation; every other access is MainActor.
    nonisolated(unsafe) private var agentDoneTimer: Timer?
    nonisolated(unsafe) private var blockedPollingTimer: Timer?

    /// Timer intervals, injectable so tests don't wait wall-clock seconds.
    private let doneQuietPeriod: TimeInterval
    private let blockedPollInterval: TimeInterval

    init(doneQuietPeriod: TimeInterval = 2.5, blockedPollInterval: TimeInterval = 1.5) {
        self.doneQuietPeriod = doneQuietPeriod
        self.blockedPollInterval = blockedPollInterval
    }

    /// Maps a raw OSC 666 status token to an agent state; nil for unknown
    /// tokens.
    nonisolated static func state(fromStatus status: String) -> AgentState? {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "busy", "working", "running":
            return .working
        case "ready", "prompt", "waiting", "needs-user", "needs_user":
            return .ready
        case "done", "finished", "complete":
            return .done
        case "idle", "clear", "reset":
            return .idle
        case "gated":
            // An approval request a machine reviewer is answering: the agent is
            // still working, and the pane must not say "Needs input" for a
            // question the human was never asked.
            return .working
        default:
            return nil
        }
    }

    /// Whether a raw status token is an approval request under a machine
    /// reviewer, which is `.working` like any other but wants the escalation
    /// watch armed.
    nonisolated static func isGated(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "gated"
    }

    /// Applies an explicit OSC 666 status report. Unknown tokens are ignored
    /// (they don't flip the pane hook-authoritative).
    func handleStatusToken(_ raw: String) {
        guard let state = Self.state(fromStatus: raw) else { return }
        applyExplicitState(state, escalating: Self.isGated(raw))
    }

    /// Applies an explicit status report that arrived out of band — over the
    /// control socket rather than as an OSC 666 escape in the pane's output.
    /// It is the same report by another road (a hook with no controlling
    /// terminal can't write the escape), so it carries the same authority.
    func handleStatusReport(_ state: AgentState) {
        applyExplicitState(state)
    }

    /// - Parameter escalating: the report was `gated` — see `escalationWatch`.
    private func applyExplicitState(_ state: AgentState, escalating: Bool = false) {
        hasExplicitStatus = true
        recentOutput = ""
        agentDoneTimer?.invalidate()
        agentDoneTimer = nil

        // A report that MOVES the state resolves the gated request one way or
        // another (Stop, done, an escalation answered), so it disarms the watch.
        // A same-state repeat — the busy the next tool call fires — leaves it
        // running: the session is still under the machine reviewer.
        let isSameState = state == self.state
        escalationWatch = escalating || (escalationWatch && isSameState)
        notifyStateChange(state)
        // A gated report almost always arrives while the pane is already
        // .working, where notifyStateChange dedups and never reaches its polling
        // branch. Arm the watch here for that case; a state-changing report was
        // armed by notifyStateChange itself.
        if escalating && isSameState && state == .working && blockedPollingTimer == nil {
            startBlockedPolling(suppressingVisiblePrompt: false)
        }
    }

    /// Runs the text heuristics over an output chunk for sessions WITHOUT the
    /// status hook installed.
    ///
    /// Once any OSC 666 has arrived this pane is hook-authoritative: the
    /// agent reports busy/ready/done/idle itself, so the text heuristics
    /// stand down entirely. Running them alongside the hooks only
    /// fabricates transitions the agent never reported — the root of the
    /// "stuck on Working" / Working↔NeedsInput-flicker races. Heuristics
    /// remain for un-hooked sessions (a plain shell, or an agent whose
    /// integration isn't installed), and resume if the agent process exits
    /// (`reset()` clears hasExplicitStatus).
    func processHeuristics(chunk: String) {
        if hasExplicitStatus { return }

        TerminalText.appendBounded(chunk, to: &recentOutput, cap: 8_000)

        let normalizedRecentOutput = TerminalText.normalize(recentOutput)
        let normalizedCurrentOutput = TerminalText.normalize(chunk)
        let actionablePromptMarkers = Self.agentPromptMarkers(in: normalizedRecentOutput)
            .subtracting(suppressedPromptMarkers)

        if !actionablePromptMarkers.isEmpty {
            agentDoneTimer?.invalidate()
            agentDoneTimer = nil
            notifyStateChange(.ready)
        } else if Self.containsAgentWorkingCue(normalizedCurrentOutput),
                  state != .ready {
            notifyStateChange(.working)
            scheduleDoneAfterQuietPeriod()
        } else if state == .working {
            scheduleDoneAfterQuietPeriod()
        }
    }

    /// A genuine keystroke reached the terminal.
    ///
    /// Hook-equipped agents report every transition over OSC 666, so input
    /// almost never moves agent state: Working comes from UserPromptSubmit /
    /// PreToolUse, Ready from Notification, Done from Stop. Guessing from
    /// keystrokes is what stranded finished agents on "Working" once their
    /// pane was focused. (Focus/mouse reports are already filtered upstream,
    /// but real keystrokes are silenced here too — the next hook is
    /// authoritative and effectively instant.)
    ///
    /// The one exception is answering a prompt from `.ready`: no hook fires
    /// when the user approves a permission prompt or answers AskUserQuestion
    /// (the docs are explicit about this), so the next authoritative busy is
    /// the tool's own PostToolUse — after the approved tool has finished. The
    /// answer keystroke itself is the only signal at that instant, so an
    /// Enter or an option digit optimistically flips ready → working; every
    /// later hook report still overrides. `.done` stays untouchable.
    func handleUserInput(bytes: ArraySlice<UInt8>? = nil) {
        if hasExplicitStatus {
            if state == .ready, let bytes, Self.isPromptAnswerKey(bytes) {
                notifyStateChange(.working)
            }
            return
        }

        recentOutput = ""
        agentDoneTimer?.invalidate()
        agentDoneTimer = nil

        if state == .ready || state == .done {
            notifyStateChange(.working)
            scheduleDoneAfterQuietPeriod()
        }
    }

    /// Whether an input chunk plausibly ANSWERS an interactive agent prompt:
    /// Enter (also the last byte of a paste-then-submit), or a bare option
    /// digit (Claude's numbered prompt shortcuts select-and-submit without
    /// Enter). Arrows (CSI sequences), Escape, and letters — someone composing
    /// "tell Claude what to do differently" feedback — don't count: moving a
    /// selection or writing text answers nothing yet. A digit typed INTO such
    /// feedback text is indistinguishable from a shortcut and mis-flips
    /// briefly; the submit that follows resumes the agent and the next hook
    /// report re-asserts the truth either way.
    nonisolated static func isPromptAnswerKey(_ bytes: ArraySlice<UInt8>) -> Bool {
        guard let last = bytes.last else { return false }
        if last == 0x0D || last == 0x0A { return true }             // CR / LF
        return bytes.count == 1 && (0x31...0x39).contains(last)     // '1'-'9'
    }

    /// Returns agent tracking to a clean slate (state idle, heuristics
    /// re-armed) once the agent process is known to be gone.
    ///
    /// Runs unconditionally — never short-circuits on `state == .idle`. A
    /// hooked agent often reports `idle` (OSC 666) as its last status before
    /// exiting; guarding on idle would skip `hasExplicitStatus = false` and
    /// latch the pane in hook-authoritative mode, so the text heuristics never
    /// resume for a later un-hooked process here. Every line below is
    /// idempotent, and `notifyStateChange` self-dedups, so the redundant-idle
    /// case this guard once handled is covered without the latch.
    func reset() {
        hasExplicitStatus = false
        escalationWatch = false
        recentOutput = ""
        agentDoneTimer?.invalidate()
        agentDoneTimer = nil
        stopBlockedPolling()
        notifyStateChange(.idle)
    }

    /// A directly launched worker's process exited. It has no parent shell to
    /// return to, so keep the finished pane actionable for waiters and the
    /// dashboard instead of resetting to idle.
    func markWorkerFinished() {
        notifyStateChange(.done)
    }

    private func scheduleDoneAfterQuietPeriod() {
        agentDoneTimer?.invalidate()
        agentDoneTimer = Timer.scheduledTimer(withTimeInterval: doneQuietPeriod, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self, self.state == .working else { return }
                self.notifyStateChange(.done)
            }
        }
    }

    private func notifyStateChange(_ state: AgentState) {
        guard state != self.state else { return }
        let previousState = self.state
        self.state = state

        // Blocked-polling scrapes the visible screen for permission dialogs —
        // a heuristic only needed when no hook reports .ready. Hook-authoritative
        // panes get .ready from the Notification hook, so skip the scraping. The
        // exception is a machine-reviewed pane (`escalationWatch`): its approval
        // requests are answered without a hook ever reporting .ready, so an
        // escalation to the human is visible on screen and nowhere else.
        if state == .working && (!hasExplicitStatus || escalationWatch) {
            startBlockedPolling(suppressingVisiblePrompt: previousState == .ready)
        } else {
            stopBlockedPolling()
        }

        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(state)
        }
    }

    // MARK: - Prompt/working heuristics

    // Claude Code — specific dialog/prompt phrases only.
    // "esc to cancel" alone is intentionally excluded: it appears in the
    // normal running-spinner footer ("Running... (esc to cancel)") and
    // causes constant Working↔NeedsInput flicker when the poller reads it.
    // "tab to add additional instructions" is also excluded: it is the
    // normal input footer Claude renders after Stop, not a request that is
    // blocking an active run.
    nonisolated private static let promptMarkers = [
        "do you want to proceed?",
        "do you want to continue?",
        "don't ask again",
        // Codex
        "allow command?",
        "press enter to confirm or esc to cancel",
        "enter to submit answer",
        "enter to submit all"
    ]

    nonisolated private static let interactivePermissionPromptMarker = "interactive permission prompt"

    nonisolated static func agentPromptMarkers(in output: String) -> Set<String> {
        var matched = Set(promptMarkers.filter { output.contains($0) })
        // Modern Claude Code inline permission prompt: "Do you want to <verb>…?"
        // above a numbered menu ("1. Yes  2. …  3. No"). Require BOTH halves so
        // the broad "do you want to" stem can't trip on ordinary prose. (Hooked
        // sessions get this authoritatively via PermissionRequest; this is the
        // fallback for un-integrated ones.)
        if output.contains("do you want to") && output.contains("1. yes") {
            matched.insert(interactivePermissionPromptMarker)
        }
        return matched
    }

    /// The same markers, but each must START a line of `output` once the chrome
    /// a TUI frames its dialogs in is trimmed.
    ///
    /// An agent renders a prompt at the start of its own line; text that merely
    /// CONTAINS a marker is text ABOUT the marker — a quoted literal
    /// (`"allow command?",`), a diff line (`+    "allow command?"`), a grep hit.
    /// This very file holds the markers as literals, so a pane reading it is the
    /// worst case: the loose match would call that a question to the human.
    nonisolated static func lineAnchoredAgentPromptMarkers(in output: String) -> Set<String> {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            .map(trimmingPromptChrome)
        func anyLineStarts(with prefix: String) -> Bool {
            lines.contains { $0.hasPrefix(prefix) }
        }
        var matched = Set(promptMarkers.filter(anyLineStarts))
        if anyLineStarts(with: "do you want to") && anyLineStarts(with: "1. yes") {
            matched.insert(interactivePermissionPromptMarker)
        }
        return matched
    }

    /// Drops what a TUI puts to the LEFT of a prompt on its own line:
    /// indentation and the box-drawing verticals its dialogs are framed in.
    /// Nothing else — every other leading character is content that tells a
    /// marker being ASKED from a marker being mentioned. Quoting and diff
    /// punctuation (`"`, `+`, `-`, `>`) is the obvious case; so are the bullet
    /// Codex renders transcript items with (`• Allow command?`), the ASCII pipe
    /// a Markdown table row starts with (`| Allow command? |`), and `❯`.
    nonisolated private static func trimmingPromptChrome(_ line: Substring) -> Substring {
        let chrome: Set<Character> = [" ", "\t", "│", "┃", "║", "▌", "▏", "▎", "▍"]
        return line.drop { chrome.contains($0) }
    }

    /// Heuristic "agent is working" signal for sessions WITHOUT the status hook
    /// installed (hooked sessions never reach here — see `processHeuristics`).
    /// Anchored to the spinner ellipsis the agents render ("Thinking…",
    /// "Working…", "running...") and the "esc to interrupt" footer, so the bare
    /// words don't flip state when they appear in ordinary command output. For
    /// reliable state, install the agent hooks.
    nonisolated static func containsAgentWorkingCue(_ output: String) -> Bool {
        let lower = output.lowercased()
        if lower.contains("esc to interrupt") { return true }
        for cue in ["running", "thinking", "working", "generating"] {
            if lower.contains("\(cue)...") || lower.contains("\(cue)…") { return true }
        }
        return false
    }

    // MARK: - Blocked-state polling

    // Polls the visible screen content while the agent is working so we can
    // detect permission dialogs even when no new PTY data arrives after the UI
    // renders (the OSC hook fires before the dialog, then data stops flowing).
    /// The prompt markers on screen, matched the way this pane's polling
    /// requires. An escalation watch runs over a pane that IS working and
    /// printing as it goes, where a loose substring match reads the agent's own
    /// output back as a question to the human. An un-hooked pane keeps the loose
    /// match: the screen is all it has, and it is only ever polled when the
    /// agent is between outputs.
    private func visiblePromptMarkers(in normalized: String) -> Set<String> {
        escalationWatch
            ? Self.lineAnchoredAgentPromptMarkers(in: normalized)
            : Self.agentPromptMarkers(in: normalized)
    }

    private func startBlockedPolling(suppressingVisiblePrompt: Bool) {
        stopBlockedPolling()
        if suppressingVisiblePrompt {
            let screen = TerminalText.normalize(readVisibleScreen?() ?? "")
            suppressedPromptMarkers = visiblePromptMarkers(in: screen)
        }
        blockedPollingTimer = Timer.scheduledTimer(withTimeInterval: blockedPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollForBlockedState() }
        }
    }

    private func stopBlockedPolling() {
        blockedPollingTimer?.invalidate()
        blockedPollingTimer = nil
        suppressedPromptMarkers.removeAll()
    }

    private func pollForBlockedState() {
        guard state == .working else {
            stopBlockedPolling()
            return
        }
        let screen = readVisibleScreen?() ?? ""
        let normalized = TerminalText.normalize(screen)
        let visibleMarkers = visiblePromptMarkers(in: normalized)

        // When a user answers a permission dialog, its text can remain in the
        // terminal for another redraw. Ignore those same markers until they
        // disappear; otherwise polling changes ready -> working -> ready using
        // stale cells from the dialog that was just answered.
        suppressedPromptMarkers.formIntersection(visibleMarkers)
        if !visibleMarkers.subtracting(suppressedPromptMarkers).isEmpty {
            agentDoneTimer?.invalidate()
            agentDoneTimer = nil
            notifyStateChange(.ready)
        }
    }

    deinit {
        // The timers are main-run-loop scheduled. deinit is nonisolated:
        // assumeIsolated is only safe while the final release lands on the main
        // thread. If a future off-main strong capture ever deallocates us
        // elsewhere, hand the timers to the main queue for invalidation there —
        // repeating timers are retained by the run loop indefinitely, so each
        // leaked one would fire no-ops for the app's lifetime.
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                agentDoneTimer?.invalidate()
                blockedPollingTimer?.invalidate()
            }
        } else {
            let timers = [agentDoneTimer, blockedPollingTimer]
            DispatchQueue.main.async {
                for timer in timers {
                    timer?.invalidate()
                }
            }
        }
    }
}
