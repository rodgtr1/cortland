import Foundation

/// The four attention events Cortland can mirror to a system notification. Kept
/// as a standalone enum (not tied to `AgentState`) so the trigger/gate/withdraw
/// decisions stay pure and unit-testable, separate from the
/// `UNUserNotificationCenter` plumbing in `NotificationCoordinator`.
enum NotificationTrigger: String, CaseIterable, Sendable {
    /// An agent transitioned to `.ready` — it is waiting on the user.
    case needsInput
    /// An agent transitioned to `.done` — it finished its run.
    case finished
    /// A background command exited non-zero (the C2 failed-command mark).
    case commandFailed
    /// A foreground command exceeding the duration threshold finished.
    case longRunningCommand

    /// The trigger (if any) raised by an agent-state transition. Only genuine
    /// transitions *into* `.ready`/`.done` raise one; same-state repeats (the
    /// `.paneAgentStateChanged` notification fires on every detection, not just
    /// changes) and transitions to `.idle`/`.working` raise nothing.
    static func forAgentTransition(from old: AgentState, to new: AgentState) -> NotificationTrigger? {
        guard old != new else { return nil }
        switch new {
        case .ready: return .needsInput
        case .done: return .finished
        case .idle, .working: return nil
        }
    }

    /// Whether an agent-state transition to `new` resolves this pane's currently
    /// showing notification, so it should be withdrawn. A needs-input or finished
    /// notification is stale once the agent resumes working or goes idle; a
    /// command notification is not affected by agent state.
    func isResolvedByAgentTransition(to new: AgentState) -> Bool {
        switch self {
        case .needsInput, .finished:
            return new == .working || new == .idle
        case .commandFailed, .longRunningCommand:
            return false
        }
    }

    /// Whether clearing the failed-command attention mark (the user visited the
    /// pane, or the next command exited zero) withdraws this pane's showing
    /// notification.
    var isResolvedByCommandAttentionClear: Bool {
        self == .commandFailed
    }
}

/// What the coordinator should do with a candidate trigger. Pure result of the
/// gate so it can be asserted directly in tests.
enum NotificationDecision: Equatable, Sendable {
    case deliver
    case suppress
}

extension NotificationsConfig {
    /// Whether this trigger is switched on (master switch AND its per-trigger
    /// toggle).
    func isEnabled(_ trigger: NotificationTrigger) -> Bool {
        guard enabled else { return false }
        switch trigger {
        case .needsInput: return needsInput
        case .finished: return finished
        case .commandFailed: return commandFailed
        case .longRunningCommand: return longRunningCommand
        }
    }

    /// Whether a finished command's duration crosses the long-running threshold.
    /// `nil` duration (no matching OSC 133 `C` mark) never qualifies.
    func longRunningCommandQualifies(duration: TimeInterval?) -> Bool {
        guard let duration else { return false }
        return duration >= TimeInterval(max(0, longRunningThresholdSeconds))
    }

    /// The core gate.
    ///
    /// - `appIsActive`: whether Cortland is the frontmost app. When true nothing
    ///   is ever delivered — the user is already looking, and we never steal
    ///   focus.
    /// - `backgroundedFor`: how long Cortland has been inactive (nil when
    ///   active). `needsInput` fires the instant the app is inactive;
    ///   completions and failures additionally require the background grace
    ///   period to have elapsed, so a brief tab-away doesn't ping.
    func shouldDeliver(_ trigger: NotificationTrigger,
                       appIsActive: Bool,
                       backgroundedFor: TimeInterval?) -> NotificationDecision {
        guard isEnabled(trigger) else { return .suppress }
        guard !appIsActive else { return .suppress }
        switch trigger {
        case .needsInput:
            return .deliver
        case .finished, .commandFailed, .longRunningCommand:
            let grace = TimeInterval(max(0, backgroundGraceSeconds))
            guard let backgroundedFor, backgroundedFor >= grace else { return .suppress }
            return .deliver
        }
    }
}
