import AppKit

/// The registry of Pro implementations. Every slot is optional and starts nil;
/// nil means "free build" and the caller takes its own, real free-tier path —
/// never a stub that traps. An official build fills the slots from the private
/// `CortlandPro` package at launch (see `#if CORTLAND_PRO` in AppDelegate).
///
/// Read the slots at the point of use, not once at startup: registration
/// happens during `applicationDidFinishLaunching`, before the window exists,
/// but some callers are constructed earlier.
public enum ProFeatures {
    public static var recall: RecallFullProviding?
    public static var approvalDesk: ApprovalDeskProviding?
    public static var costReporting: CostReportingProviding?
    public static var worktreeLaunch: WorktreeLaunchProviding?

    /// True when anything registered — used only for diagnostics (the About
    /// panel, log lines). Behavior always branches on the specific slot.
    public static var isProBuild: Bool {
        recall != nil || approvalDesk != nil || costReporting != nil || worktreeLaunch != nil
    }

    /// Drops every registration. Tests use this to get back to free behavior.
    public static func reset() {
        recall = nil
        approvalDesk = nil
        costReporting = nil
        worktreeLaunch = nil
    }
}

// MARK: - Session Recall

/// What the app does when a session is resumed from the Pro recall panel: open
/// a new tab in `workingDirectory` running `command`. A nil directory falls
/// back to the active pane's.
public struct RecallResumeRequest: Sendable {
    public var workingDirectory: String?
    public var command: [String]

    public init(workingDirectory: String?, command: [String]) {
        self.workingDirectory = workingDirectory
        self.command = command
    }
}

/// The full ⌃⇧S Session Recall panel: text search, deep (transcript-body)
/// search, ⌘↩ preview, agent filter, and Enter-to-resume.
///
/// Without it the app shows its own teaser panel — the ten most recent
/// sessions, read through the same public parsers.
public protocol RecallFullProviding: AnyObject {
    /// Show (or re-show) the panel centered over `window`. The provider owns
    /// the panel and reuses it across calls.
    func showRecall(relativeTo window: NSWindow, resume: @escaping (RecallResumeRequest) -> Void)
}

// MARK: - Approval desk

/// Posted whenever the pending-approval set changes, so the sidebar list, the
/// activity-bar badge, and the dock-attention logic all track one source of
/// truth. Declared here because the desk that posts it is Pro and the surfaces
/// that observe it are free.
public extension Notification.Name {
    static let pendingApprovalsChanged = Notification.Name("PendingApprovalsChanged")
}

/// The `[approval]` config slice the desk decides against, flattened to plain
/// values so config parsing stays in the public app.
public struct ApprovalSettings: Sendable {
    /// Globs that approve silently.
    public var autoAllow: [String]
    /// Globs that always force a human decision, outranking everything else.
    public var alwaysAsk: [String]
    /// Approve edits inside the pane's own registered worktree.
    public var worktreeAutoApprove: Bool
    /// The `[approval] mode` config plus the per-session menu toggle.
    public var globalAuto: Bool

    public init(
        autoAllow: [String] = [],
        alwaysAsk: [String] = [],
        worktreeAutoApprove: Bool = false,
        globalAuto: Bool = false
    ) {
        self.autoAllow = autoAllow
        self.alwaysAsk = alwaysAsk
        self.worktreeAutoApprove = worktreeAutoApprove
        self.globalAuto = globalAuto
    }
}

/// Everything the desk needs back from the app, handed over once the window is
/// up. Closures rather than a delegate protocol so the app can satisfy them
/// from whichever object already owns each piece.
public struct ApprovalDeskContext {
    /// Live settings, re-read on every decision so a config reload takes effect.
    public var settings: () -> ApprovalSettings
    /// The window approvals are reviewed in; nil when the app is closing and
    /// there is nothing left to review in.
    public var reviewWindow: () -> NSWindow?
    /// The registered-worktree root a pane sits in, or nil. Resolved by the app
    /// (it owns the git plumbing) and only consulted when the opt-in is on.
    public var worktreeRoot: (UUID?) -> String?
    /// Display label for the pane an approval came from ("main · pane 2").
    public var paneLabel: (UUID?) -> String
    /// Reports the diff lifecycle (pending/accepted/rejected/withdrawn) so the
    /// app stays the lone event-stream emit site.
    public var emitEvent: (_ path: String, _ decision: String) -> Void
    /// Flips a pane's agent status while its edit is parked at the desk.
    public var setPaneParked: (_ paneID: UUID, _ parked: Bool) -> Void

    public init(
        settings: @escaping () -> ApprovalSettings,
        reviewWindow: @escaping () -> NSWindow?,
        worktreeRoot: @escaping (UUID?) -> String?,
        paneLabel: @escaping (UUID?) -> String,
        emitEvent: @escaping (_ path: String, _ decision: String) -> Void,
        setPaneParked: @escaping (_ paneID: UUID, _ parked: Bool) -> Void
    ) {
        self.settings = settings
        self.reviewWindow = reviewWindow
        self.worktreeRoot = worktreeRoot
        self.paneLabel = paneLabel
        self.emitEvent = emitEvent
        self.setPaneParked = setPaneParked
    }
}

/// The agent edit-approval desk: policy, the review queue, and the cards in the
/// agents panel.
///
/// Without it the edit gate fails OPEN — `cortland-agent-status edit-gate` gets
/// no decision back and Claude Code falls through to its own permission prompt,
/// exactly as when Cortland isn't running. The hook helpers, their wire format,
/// and hook installation are public and unchanged either way.
public protocol ApprovalDeskProviding: AnyObject {
    /// Hands the desk its window-side dependencies. Called once, when the main
    /// window comes up.
    func install(context: ApprovalDeskContext)

    /// Decides `path` and resolves `completion` with the accept/reject outcome.
    /// A parked entry holds the hook's socket open; `registerDisconnect` arms
    /// the withdrawal that runs if that socket hangs up first.
    func requestApproval(
        paneID: UUID?,
        path: String,
        old: String,
        new: String,
        registerDisconnect: (@escaping @Sendable () -> Void) -> Void,
        completion: @escaping (Bool) -> Void
    )

    /// Resolve everything still queued rather than strand blocked hooks.
    func prepareForWindowClose()

    /// Entries awaiting review, for the activity-bar badge.
    var pendingCount: Int { get }
    /// Entries awaiting review from one pane, for its per-pane badge.
    func pendingCount(forPane paneID: UUID?) -> Int

    /// The desk section for the top of the agents panel. The app installs the
    /// returned view once; a free build has no such section at all.
    func makeDeskSection() -> NSView
    /// Re-syncs the section with the queue. Called on queue changes and on the
    /// panel's per-second tick (which also advances each card's elapsed time).
    func refreshDeskSection()
}

// MARK: - Cost reporting

/// One billed pane's usage, priced at its own model.
public struct ProCostEntry: Sendable {
    public var model: String?
    public var tokens: Int
    public var costUSD: Double?
    /// False for a pane that has reported usage but never completed a turn;
    /// those don't count toward a roll-up.
    public var billed: Bool

    public init(model: String?, tokens: Int, costUSD: Double?, billed: Bool) {
        self.model = model
        self.tokens = tokens
        self.costUSD = costUSD
        self.billed = billed
    }
}

/// One tab's billed panes.
public struct ProCostTab: Sendable {
    public var title: String
    public var entries: [ProCostEntry]

    public init(title: String, entries: [ProCostEntry]) {
        self.title = title
        self.entries = entries
    }
}

/// Number formatting the app already owns (`TelemetryFormat`), handed to Pro so
/// the two render spend and tokens identically and neither has a second copy.
public struct ProCostFormatting: Sendable {
    public var cost: @Sendable (Double) -> String
    public var tokens: @Sendable (Int) -> String
    public var shortModel: @Sendable (String) -> String

    public init(
        cost: @escaping @Sendable (Double) -> String,
        tokens: @escaping @Sendable (Int) -> String,
        shortModel: @escaping @Sendable (String) -> String
    ) {
        self.cost = cost
        self.tokens = tokens
        self.shortModel = shortModel
    }
}

/// Session cost reporting: the per-row `$` figure, the agents-panel roll-up,
/// and the on-disk spend history.
///
/// Without it the free app still collects and shows telemetry — the live
/// context bar, the model, the token counts, agent state — it just renders no
/// cost figures and keeps no spend history.
public protocol CostReportingProviding: AnyObject {
    /// Number formatting from the app. Called once at registration.
    func install(formatting: ProCostFormatting)

    /// The `$0.36` fragment of a dashboard row's telemetry line, or nil when
    /// there is no figure to show.
    func rowCostText(_ costUSD: Double?) -> String?

    /// The agents panel's bottom roll-up: the footer line and its per-model
    /// tooltip. Nil when nothing has billed a turn, which hides the footer.
    func sessionFooter(_ tabs: [ProCostTab]) -> (line: String, tooltip: String)?

    /// Appends a roll-up to the on-disk cost history (a closing tab's spend, or
    /// everything still open at termination).
    func recordCosts(_ tabs: [ProCostTab])
}

// MARK: - One-step worktree launch

/// Creating a worktree and launching an agent in it as one action.
///
/// Without it the "New Worktree" sheet has no agent picker: creating a worktree
/// opens a plain terminal there, and open/remove/merge are unchanged.
public protocol WorktreeLaunchProviding: AnyObject {
    /// Agent choices for the sheet's picker, the first being "no agent".
    var agentChoices: [String] { get }
    /// The command to run in the new worktree's pane, or nil for a plain
    /// terminal (an unknown choice reads as "none").
    func launchCommand(for choice: String) -> [String]?
}
