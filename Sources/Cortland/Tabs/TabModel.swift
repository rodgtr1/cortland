import Foundation
import Cocoa
import CortlandTelemetryCore

enum AgentState: String, Codable, CaseIterable {
    case idle       // No agent activity
    case working    // Agent is processing
    case ready      // Agent is ready for input (waiting for user)
    case done       // Agent finished the last run

    /// Higher values require more immediate attention. Used to aggregate
    /// per-pane state into the tab indicator without one idle pane masking a
    /// working or blocked sibling.
    var priority: Int {
        switch self {
        case .idle: return 0
        case .done: return 1
        case .working: return 2
        case .ready: return 3
        }
    }
}

/// One pane's reported usage plus its cost priced at that pane's own model.
struct PaneTelemetry: Equatable {
    let paneID: UUID
    let usage: TranscriptUsage
    let costUSD: Double?
}

class TabModel: Identifiable {
    let id = UUID()
    var title: String = "Terminal"
    var isActive: Bool = false
    var isDirty: Bool = false
    var agentState: AgentState = .idle {
        didSet {
            if agentState != oldValue {
                agentStateChangedAt = Date()
            }
        }
    }
    var agentStateChangedAt = Date()
    var panes: [PaneModel] = []
    var activePaneIndex: Int = 0

    /// User-assigned name from "Rename Tab"; overrides the automatic
    /// directory/branch title until cleared (set back to nil).
    var customTitle: String? {
        didSet { updateTitleFromActivePane() }
    }

    // Last finished command (from shell integration); nil while one runs
    var lastCommandFailed: Bool = false
    var lastCommandTooltip: String?

    /// Aggregated agent telemetry (model, token usage) for this tab's primary
    /// agent pane, set by AutomationCoordinator when the cortland-telemetry hook
    /// reports. Read by the agents-panel dashboard.
    var telemetry: TranscriptUsage?

    /// Estimated USD cost for `telemetry`, priced against the effective
    /// `[telemetry]` rate card by AutomationCoordinator (so the view doesn't
    /// need the rates). Nil when the model has no known rate.
    var telemetryCostUSD: Double?

    /// Telemetry for every agent pane in this tab (pane order), each priced at
    /// its own model's rate — a split tab can run different models side by
    /// side, and summing their usages under one rate would misprice them.
    /// `telemetry` above remains the primary pane's, driving the context bar.
    var paneTelemetries: [PaneTelemetry] = []

    // Backward compatibility
    var isAgentReady: Bool {
        return agentState == .ready
    }

    init() {
        // Create initial pane
        let initialPane = PaneModel()
        panes.append(initialPane)
        activePaneIndex = 0
    }

    var activePane: PaneModel? {
        guard activePaneIndex >= 0 && activePaneIndex < panes.count else { return nil }
        return panes[activePaneIndex]
    }

    func addPane(_ pane: PaneModel) {
        panes.append(pane)
        activePaneIndex = panes.count - 1
    }

    func removePane(at index: Int) {
        guard index >= 0 && index < panes.count && panes.count > 1 else { return }

        panes.remove(at: index)

        // Adjust active pane index
        if activePaneIndex >= panes.count {
            activePaneIndex = panes.count - 1
        }
    }

    func setActivePane(index: Int) {
        guard index >= 0 && index < panes.count else { return }
        activePaneIndex = index

        // Update focus for all panes
        for (i, pane) in panes.enumerated() {
            pane.isFocused = (i == index)
        }

        // Update tab title from active pane
        updateTitleFromActivePane()
    }

    func updateTitleFromActivePane() {
        if let customTitle = customTitle, !customTitle.isEmpty {
            title = customTitle
            return
        }

        guard let activePane = activePane else { return }

        // Use the active pane's title (which includes directory and git branch)
        if !activePane.title.isEmpty {
            title = activePane.title
        } else {
            title = "Terminal"
        }
    }

    func updateAgentStateFromPanes() {
        agentState = panes.map(\.agentState).max(by: { $0.priority < $1.priority }) ?? .idle
    }

    /// True when any pane in this tab carries an unacknowledged failed-command
    /// attention mark, so a background split whose hidden pane failed still
    /// lights the tab in the agents panel and the ⇧⌘J cycle.
    var hasCommandAttention: Bool {
        panes.contains { $0.failedCommandAttention }
    }

    /// The oldest still-unacknowledged failed-command mark among this tab's
    /// panes, driving the agents-panel "Command failed · 12s" elapsed line.
    var commandAttentionSince: Date? {
        panes.filter { $0.failedCommandAttention }
            .map { $0.failedCommandAttentionChangedAt }
            .min()
    }

    /// The next tab ⇧⌘J should jump to, walking attention buckets most-urgent
    /// first — needs-input, then a failed background command, then finished,
    /// then working — and wrapping past the active tab within each bucket. A
    /// failed command joins the same cycle the agent states already use rather
    /// than getting a parallel shortcut. Returns nil when nothing wants
    /// attention; returns `activeIndex` when it is the sole candidate in the
    /// most-urgent non-empty bucket (the caller treats that as a no-op). Pure so
    /// the ordering is unit-testable without a live window.
    static func nextAttentionIndex(in tabs: [TabModel], activeIndex: Int) -> Int? {
        let buckets: [(TabModel) -> Bool] = [
            { $0.agentState == .ready },
            { $0.hasCommandAttention },
            { $0.agentState == .done },
            { $0.agentState == .working }
        ]
        for matches in buckets {
            let candidates = tabs.indices.filter { matches(tabs[$0]) }
            guard !candidates.isEmpty else { continue }
            return candidates.first(where: { $0 > activeIndex }) ?? candidates[0]
        }
        return nil
    }
}

enum SplitDirection {
    case horizontal // Split left/right
    case vertical   // Split top/bottom
}
