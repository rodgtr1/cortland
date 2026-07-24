import Foundation

/// How an agent's hook reports a status change to Cortland.
///
/// The original transport was an OSC 666 escape written to `/dev/tty`, which the
/// pane's terminal picks out of the output stream. That works from anything with
/// a controlling terminal — the shell integration, a pane's own shell, an agent
/// that runs its hooks as ordinary children.
///
/// It does not work from Claude Code, whose hook processes are spawned detached
/// from the controlling terminal: opening `/dev/tty` there fails with ENXIO
/// ("device not configured"), so every report was written nowhere and the pane
/// sat at `idle` for the entire run. Those processes *can* still reach Cortland's
/// control socket (the telemetry hook already does), and they inherit
/// `CORTLAND_PANE_ID` from the pane's environment, so the report is addressed to
/// the pane directly instead of riding its output stream.
///
/// Both transports land in the same place — the pane's `AgentStateDetector`,
/// marked hook-authoritative — so a report is delivered exactly once, by whichever
/// route is open.
public enum AgentStatusReport {
    /// The terminal property the OSC 666 sequence carries.
    public static let termprop = "vte.ext.cortland.agent"

    /// Wire-protocol version of the `agent_status` IPC payload, sent by the hook
    /// helper and checked by the app. Bump it when the hook contract changes —
    /// a new required field, a changed status vocabulary, a different addressing
    /// scheme — so a helper left behind by an app upgrade becomes *visible*
    /// instead of silently misreporting. (Every mismatch failure mode in this
    /// path is silent by design: a hook must never disrupt the agent.)
    ///
    /// v1: the socket transport itself — pane-addressed `agent_status` with a
    /// declared version. Helpers older than that send no version field at all.
    /// v2: the `gated` status — what a v1 helper reports as `ready` when a
    /// machine reviewer, not the human, is answering the approval request.
    public static let protocolVersion = 2

    /// What a report with no `protocol_version` field means: a pre-handshake
    /// helper (everything shipped up to and including commit 316e143). Absence
    /// is information, not an error — those helpers exist in the wild, they just
    /// can't say so.
    public static let legacyProtocolVersion = 0

    /// Whether a report came from a helper older than this build speaks.
    ///
    /// Deliberately one-directional: a *newer* (unknown) version is never stale
    /// and must never be rejected — an old app has no business refusing a report
    /// from a helper that a newer app installed, and the status vocabulary it
    /// carries is additive.
    public static func isStale(protocolVersion reported: Int?) -> Bool {
        (reported ?? legacyProtocolVersion) < protocolVersion
    }

    /// The payload key carrying `protocolVersion`. Shared so the helper that
    /// writes it and the app that reads it can't drift.
    public static let protocolVersionKey = "protocol_version"

    /// The statuses a hook may report. The raw values are what both transports
    /// put on the wire, and what `AgentStateDetector` parses.
    ///
    /// `gated` is the one status no hook config names: it is what `ready`
    /// becomes when a machine reviewer, not the human, is answering the
    /// approval request (see `effectiveStatus(requested:environment:)`).
    public enum Status: String, Sendable, CaseIterable {
        case busy, ready, done, idle, gated
    }

    /// Normalizes a hook's status argument. The aliases match the ones
    /// `AgentStateDetector.state(fromStatus:)` accepts, so a config written
    /// against either vocabulary keeps working.
    public static func status(fromArgument argument: String?) -> Status? {
        switch argument?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "busy", "working", "running": return .busy
        case "ready", "prompt", "waiting", "needs-user", "needs_user": return .ready
        case "done", "finished", "complete": return .done
        case "idle", "clear", "reset": return .idle
        case "gated": return .gated
        default: return nil
        }
    }

    /// The environment variable naming whoever is answering this agent's
    /// approval requests, stamped onto the agent process at launch by whichever
    /// Cortland path injected the approval flags (shell wrapper, worker shim, or
    /// worker argv). Hooks inherit it, which is the only way the helper can know:
    /// Codex's PermissionRequest payload does not carry the effective reviewer
    /// (openai/codex#23465).
    ///
    /// Unset means Cortland did not choose the reviewer for this agent — a
    /// caller's own approval flags, or an agent started outside Cortland — and
    /// the helper must assume the human is answering.
    public static let activeApprovalReviewerEnvVar = "CORTLAND_ACTIVE_APPROVAL_REVIEWER"

    /// The `approvals_reviewer` value naming Codex's automatic safety reviewer.
    public static let autoReviewReviewer = "auto_review"

    /// The `approvals_reviewer` value naming the human.
    public static let userReviewer = "user"

    /// What a requested status actually means in `environment`.
    ///
    /// Codex fires its PermissionRequest hook for every command needing approval
    /// even under `approvals_reviewer=auto_review`, where the auto-reviewer
    /// answers and the human never types. Reporting `ready` there parks the pane
    /// on "Needs input" for the rest of the tool call: nothing flips it back,
    /// because the keystroke that normally would never happens. Such a request is
    /// reported as `gated` instead — still working, but watch the screen, because
    /// the reviewer can escalate to the human and no hook says when.
    ///
    /// Only `ready` is ever downgraded; every other status means what it says
    /// regardless of who reviews approvals.
    public static func effectiveStatus(requested: Status, environment: [String: String]) -> Status {
        guard requested == .ready,
              environment[activeApprovalReviewerEnvVar] == autoReviewReviewer else { return requested }
        return .gated
    }

    /// Claude Code's Notification hook fires both for genuine permission requests
    /// ("Claude needs your permission to use Bash") and for the idle reminder
    /// ("Claude is waiting for your input") that arrives ~60s after a turn ends.
    /// The reminder must not flip a finished agent back to "Needs input", so a
    /// `ready` carrying it is dropped — leaving the pane in whatever state the
    /// Stop hook last set.
    public static func isIdleReminder(status: Status, hookMessage: String?) -> Bool {
        guard status == .ready, let hookMessage else { return false }
        return hookMessage.lowercased().contains("waiting for your input")
    }

    /// The OSC 666 sequence for `status` — the in-band transport.
    public static func escapeSequence(for status: Status) -> String {
        "\u{001B}]666;\(termprop)=\(status.rawValue)\u{001B}\\"
    }

    /// The pane-addressed IPC command for `status` — the out-of-band transport,
    /// used when the hook has no controlling terminal to write the escape to.
    ///
    /// Carries `protocol_version` so the app can tell a helper this build shipped
    /// from one an upgrade left behind in `~/.local/bin`.
    public static func ipcCommand(status: Status, paneID: String) -> [String: Any] {
        [
            "action": "agent_status",
            "pane_id": paneID,
            "status": status.rawValue,
            protocolVersionKey: protocolVersion
        ]
    }
}
