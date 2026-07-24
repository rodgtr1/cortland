import AppKit

/// The slice of the window controller `DiffApprovalCoordinator` needs to decide
/// a hook edit approval: the live `[approval]` config, the global auto-approve
/// toggle, and the window approvals are reviewed in (nil when the app is
/// closing and there's nothing left to review in). `AutomationHost` refines
/// this, so MainWindowController satisfies both through one conformance.
protocol DiffApprovalHost: AnyObject {
    /// When true, hook edits are approved without review — driven by the
    /// `[approval]` config mode and the per-session toggle.
    var shouldAutoApproveEdits: Bool { get }
    /// The active `[approval]` config, supplying the auto_allow / always_ask
    /// glob rules and the worktree auto-approve opt-in layered on top of
    /// `shouldAutoApproveEdits`.
    var approvalConfig: ApprovalConfig { get }
    /// The window approvals are reviewed in, or nil when there's none (app
    /// closing / already gone).
    var automationWindow: NSWindow? { get }
    /// Working directory of the pane an edit hook ran in, or nil when the pane
    /// can't be resolved (no id, or already closed). Used to scope worktree
    /// auto-approve to the pane's own checkout.
    func workingDirectory(forPane paneID: UUID?) -> String?
}

/// Owns hook diff-approval policy: silent allows, per-pane "approve & remember"
/// grants, and the fail-open drain when there is no window left to review in.
/// Approvals that need a human land in `ApprovalQueue` and are reviewed from
/// the agents panel's approvals list (F3) — a non-modal review queue — rather
/// than one blocking sheet at a time, so several agents' requests can be
/// decided in any order. Split out of AutomationCoordinator, which stays the
/// IPC + event-emit site and drives this through `requestApproval` /
/// `prepareForWindowClose`, reporting the diff lifecycle via `onEvent`.
final class DiffApprovalCoordinator {
    private weak var host: DiffApprovalHost?
    private let queue: ApprovalQueue

    /// Reports the approval lifecycle (pending/accepted/rejected/withdrawn) for
    /// `path` so the owner can emit a `diff` event — keeping event emission
    /// centralized there rather than spread across coordinators.
    private let onEvent: (_ path: String, _ decision: String) -> Void

    /// Flips the originating pane's agent status while its edit sits at the desk:
    /// `parked` true when an entry enqueues (→ needs input), false when it
    /// resolves or withdraws (→ working). Only entries that actually park call
    /// this; a silent policy allow never does.
    private let onParkedStatusChange: (_ paneID: UUID, _ parked: Bool) -> Void

    /// "Approve & remember" grants from the review list, scoped per pane (the
    /// pane the edit hook ran in; nil for a hook that didn't report one). Per-pane
    /// scoping keeps a grant in one agent's pane from auto-approving another's.
    /// Reset on relaunch, like the auto-approve menu toggle.
    private var sessionApprovals: [UUID?: SessionApprovals] = [:]

    init(
        host: DiffApprovalHost?,
        queue: ApprovalQueue = .shared,
        onParkedStatusChange: @escaping (_ paneID: UUID, _ parked: Bool) -> Void = { _, _ in },
        onEvent: @escaping (_ path: String, _ decision: String) -> Void
    ) {
        self.host = host
        self.queue = queue
        self.onParkedStatusChange = onParkedStatusChange
        self.onEvent = onEvent
    }

    /// Decides `path` against policy and either allows it silently or parks it
    /// in the review queue, resolving `completion` with the accept/reject
    /// outcome once the user (or a drain) decides.
    ///
    /// A parked entry holds the hook's socket open while it waits. `registerDisconnect`
    /// arms a handler the server runs if that socket hangs up first (the hook
    /// process died at its timeout, was killed, or its pane closed): the entry
    /// withdraws so the desk can't strand a ghost card no one can answer.
    func requestApproval(
        paneID: UUID?,
        path: String,
        old: String,
        new: String,
        registerDisconnect: (@escaping @Sendable () -> Void) -> Void = { _ in },
        completion: @escaping (Bool) -> Void
    ) {
        if approvalDecision(for: path, pane: paneID) == .allow {
            // Allowed silently by glob rule, "remember" grant, or auto mode.
            onEvent(path, "accepted")
            completion(true)
            return
        }

        // No window at all to review in (app closing / already gone): resolve
        // with the drain's fail-open contract rather than park an entry no one
        // can ever see. A merely miniaturized or hidden window still has a
        // queue surface — entries just wait there.
        guard host?.automationWindow != nil else {
            let accepted = !isAlwaysAsk(path, pane: paneID)
            onEvent(path, accepted ? "accepted" : "rejected")
            completion(accepted)
            return
        }

        onEvent(path, "pending")
        let entryID = queue.enqueue(
            paneID: paneID,
            path: path,
            old: old,
            new: new,
            isAlwaysAsk: isAlwaysAsk(path, pane: paneID)
        ) { [weak self] outcome in
            // Record an "approve & remember" grant into the originating pane's
            // bucket before resolving, so later edits from that pane already
            // see it. always_ask still wins.
            if outcome.accepted {
                self?.sessionApprovals[paneID, default: SessionApprovals()]
                    .record(outcome.remember, path: path)
            }
            self?.onEvent(path, outcome.accepted ? "accepted" : "rejected")
            self?.setParked(paneID, false)
            completion(outcome.accepted)
            if outcome.accepted && outcome.remember != .none {
                self?.resolveNewlyAllowed()
            }
        }
        // The edit is now genuinely waiting on a human, so the pane reads "needs
        // input" until it resolves — not the "busy" the PreToolUse status hook
        // set the moment the tool started.
        setParked(paneID, true)
        registerDisconnect { [weak self] in
            DispatchQueue.main.async {
                self?.withdraw(entryID: entryID, paneID: paneID, path: path)
            }
        }
    }

    /// Withdraws a parked entry whose hook client vanished: drops it from the
    /// queue (unfired), records the withdrawal, and returns the pane to working.
    /// A no-op if the entry already resolved (a human answered in the same
    /// instant the client dropped).
    private func withdraw(entryID: UUID, paneID: UUID?, path: String) {
        guard queue.withdraw(id: entryID) != nil else { return }
        onEvent(path, "withdrawn")
        setParked(paneID, false)
    }

    /// Notifies the owner to flip the pane's agent status for a parked edit.
    /// Guards on a real pane — an unscoped (nil) hook has no pane to flip.
    private func setParked(_ paneID: UUID?, _ parked: Bool) {
        guard let paneID else { return }
        onParkedStatusChange(paneID, parked)
    }

    /// Called from the host's windowWillClose. Don't strand hook processes
    /// blocked on approval: resolve everything still queued. Most fail OPEN —
    /// allowing the edit — to match the hook's contract that an unavailable
    /// Cortland lets edits through. The exception is `always_ask` paths: that
    /// list exists to force a human decision, so without a window to review in
    /// they fail CLOSED (reject) rather than slip through unreviewed.
    func prepareForWindowClose() {
        queue.drainAll { [weak self] entry in
            let alwaysAsk = self?.isAlwaysAsk(entry.path, pane: entry.paneID) ?? true
            return ApprovalOutcome(accepted: !alwaysAsk, remember: .none)
        }
    }

    // MARK: - Policy

    /// Resolves the approval policy for `path` against the config glob rules,
    /// the pane's own "remember" grants, and the global auto toggle.
    private func approvalDecision(for path: String, pane: UUID?) -> ApprovalPolicy.Decision {
        let config = host?.approvalConfig ?? ApprovalConfig()
        return ApprovalPolicy.decide(
            path: path,
            globalAuto: host?.shouldAutoApproveEdits ?? false,
            autoAllow: config.autoAllow,
            alwaysAsk: config.alwaysAsk,
            session: sessionApprovals[pane] ?? SessionApprovals(),
            workingRoot: worktreeRoot(forPane: pane, config: config),
            worktreeAutoApprove: config.worktreeAutoApprove
        )
    }

    /// The registered-worktree root the pane sits in, or nil. Resolved only when
    /// the opt-in is on so a disabled feature never forks `git`. Nil for a pane
    /// in the primary checkout keeps that checkout prompting.
    private func worktreeRoot(forPane pane: UUID?, config: ApprovalConfig) -> String? {
        guard config.worktreeAutoApprove,
              let cwd = host?.workingDirectory(forPane: pane) else { return nil }
        return WorkspaceResolver.linkedWorktreeRoot(from: cwd)
    }

    /// After an "approve & remember" grant, entries already queued from the
    /// same pane may now be allowed by policy — resolve them rather than make
    /// the user click through requests the grant they just gave already
    /// covers. (`queue.pending` is a value snapshot, so resolving while
    /// iterating is safe; the resolved entries' `remember` is `.none`, so this
    /// can't recurse.)
    private func resolveNewlyAllowed() {
        for entry in queue.pending where approvalDecision(for: entry.path, pane: entry.paneID) == .allow {
            queue.resolve(id: entry.id, outcome: ApprovalOutcome(accepted: true, remember: .none))
        }
    }

    /// Whether `path` matches an `always_ask` glob. Mirrors `decide`'s
    /// fail-closed semantics: an unparseable pattern counts as a match.
    private func isAlwaysAsk(_ path: String, pane: UUID?) -> Bool {
        let config = host?.approvalConfig ?? ApprovalConfig()
        let canonicalPath = ApprovalPolicy.canonical(path)
        return config.alwaysAsk.contains { pattern in
            ApprovalPolicy.globMatch(pattern, canonicalPath: canonicalPath) != .noMatch
        }
    }
}
