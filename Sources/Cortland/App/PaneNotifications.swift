import Foundation

/// Typed names for the cross-cutting events that flow between panes, the window
/// controller, the agents dashboard, and the automation coordinator. These were
/// previously raw `NSNotification.Name("PaneAgentStateChanged")` string literals
/// scattered across the poster and every observer — no compile-time safety, easy
/// to typo, hard to trace. Posting and observing through these constants makes
/// the set discoverable in one place and typo-proof; the event stream
/// (`cortland-ctl events --follow`) leans on the same signals.
///
/// Raw values are unchanged from the old literals so anything that still posts a
/// string by hand keeps interoperating during the migration.
// These names are immutable Sendable constants observed and posted from both
// main-actor and background contexts (the IPC event stream, file watchers), so
// the extension opts out of the module's default main-actor isolation.
nonisolated extension Notification.Name {
    /// A pane's agent state changed (idle/working/ready/done). `object` is the
    /// `PaneModel`; `userInfo["agentState"]` carries the new `AgentState`.
    static let paneAgentStateChanged = Notification.Name("PaneAgentStateChanged")

    /// A pane reported new agent telemetry (token usage) via the
    /// cortland-telemetry hook. `object` is the affected `TabModel`, if known.
    static let paneTelemetryChanged = Notification.Name("PaneTelemetryChanged")

    /// A shell command finished (OSC 133 D mark). `object` is the `PaneModel`;
    /// `userInfo["status"]` carries a `TerminalCommandStatus` when one is known.
    static let paneCommandStatusChanged = Notification.Name("PaneCommandStatusChanged")

    /// A pane's failed-command attention mark was set or cleared. `object` is
    /// the `PaneModel`. The agents dashboard reloads so the row highlight
    /// tracks it, the same way it does for agent-state changes.
    static let paneCommandAttentionChanged = Notification.Name("PaneCommandAttentionChanged")

    /// A pane's title (cwd/branch) changed. `object` is the `PaneModel`.
    static let paneTitleChanged = Notification.Name("PaneTitleChanged")

    /// A pane's dirty/modified state changed. `object` is the `PaneModel`.
    static let paneDirtyStateChanged = Notification.Name("PaneDirtyStateChanged")

    /// A pane asked the app to open a file. `object` is the `PaneModel`;
    /// `userInfo["path"]` is the path and `userInfo["line"]` an optional line.
    static let paneOpenFileRequested = Notification.Name("PaneOpenFileRequested")

    /// A pane asked the app to open a URL. `object` is the `PaneModel`;
    /// `userInfo["url"]` is the `URL`.
    static let paneOpenURLRequested = Notification.Name("PaneOpenURLRequested")

    /// A terminal reported a new working directory (OSC 7). `object` is the
    /// `PaneModel`; `userInfo["directory"]` and `userInfo["branch"]`.
    static let terminalCWDChanged = Notification.Name("TerminalCWDChanged")

    /// An editor pane's modified state changed. `object` is the editor.
    static let editorModifiedStateChanged = Notification.Name("EditorModifiedStateChanged")

    /// The pending diff-approval queue gained or lost entries. `object` is the
    /// `ApprovalQueue`; read its `pending` list for the current state.
    static let pendingApprovalsChanged = Notification.Name("PendingApprovalsChanged")

    /// A pane was shut down (pane closed, tab closed). `object` is the
    /// `PaneModel`. The automation coordinator uses this to fail in-flight
    /// waits on that pane immediately instead of letting them run to timeout.
    static let paneDidClose = Notification.Name("PaneDidClose")
}
