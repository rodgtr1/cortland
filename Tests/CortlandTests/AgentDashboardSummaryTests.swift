import XCTest
@testable import Cortland
@testable import CortlandTelemetryCore

/// The agents-panel session roll-up: every reporting pane counts (priced at its
/// own model), not just each tab's primary pane, with a per-model breakdown.
@MainActor
final class AgentDashboardSummaryTests: XCTestCase {
    private func usage(model: String, input: Int, output: Int, responses: Int = 1) -> TranscriptUsage {
        TranscriptUsage(model: model, inputTokens: input, outputTokens: output, assistantResponses: responses)
    }

    /// A tab split between fable and opus contributes both panes' spend, and
    /// the breakdown separates the models (highest spend first).
    func testSummarySumsEveryPaneAndBreaksDownByModel() throws {
        let tab = TabModel()
        tab.addPane(PaneModel())
        let fable = usage(model: "claude-fable-5", input: 100_000, output: 10_000)
        let opus = usage(model: "claude-opus-4-8", input: 50_000, output: 5_000)
        tab.telemetry = fable                       // primary pane only
        tab.telemetryCostUSD = fable.estimatedCostUSD()
        tab.paneTelemetries = [
            PaneTelemetry(paneID: tab.panes[0].id, usage: fable, costUSD: fable.estimatedCostUSD()),
            PaneTelemetry(paneID: tab.panes[1].id, usage: opus, costUSD: opus.estimatedCostUSD()),
        ]

        let summary = try XCTUnwrap(AgentDashboardViewController.sessionSummary([tab]))
        XCTAssertEqual(summary.tokens, 165_000)
        // fable: 100k·10e-6 + 10k·50e-6 = 1.5; opus: 50k·5e-6 + 5k·25e-6 = 0.375
        XCTAssertEqual(summary.cost, 1.875, accuracy: 1e-9)
        XCTAssertEqual(summary.byModel.map(\.model), ["fable-5", "opus-4.8"])
        XCTAssertEqual(summary.byModel[0].cost, 1.5, accuracy: 1e-9)
        XCTAssertEqual(summary.byModel[1].tokens, 55_000)
    }

    /// Two panes on the same model merge into one breakdown entry.
    func testSameModelPanesMergeInBreakdown() throws {
        let tab = TabModel()
        tab.addPane(PaneModel())
        let a = usage(model: "claude-opus-4-8", input: 10_000, output: 1_000)
        let b = usage(model: "claude-opus-4-8", input: 20_000, output: 2_000)
        tab.paneTelemetries = [
            PaneTelemetry(paneID: tab.panes[0].id, usage: a, costUSD: a.estimatedCostUSD()),
            PaneTelemetry(paneID: tab.panes[1].id, usage: b, costUSD: b.estimatedCostUSD()),
        ]
        let summary = try XCTUnwrap(AgentDashboardViewController.sessionSummary([tab]))
        XCTAssertEqual(summary.byModel.count, 1)
        XCTAssertEqual(summary.byModel[0].tokens, 33_000)
    }

    /// A tab whose per-pane list hasn't populated still contributes its
    /// primary usage, and an unknown-rate pane contributes tokens but no cost.
    func testFallbackAndUnknownRate() throws {
        let legacy = TabModel()
        legacy.telemetry = usage(model: "claude-opus-4-8", input: 10_000, output: 0)
        legacy.telemetryCostUSD = 0.05

        let codex = TabModel()
        let unknown = usage(model: "gpt-x", input: 5_000, output: 500)
        codex.paneTelemetries = [PaneTelemetry(paneID: codex.panes[0].id, usage: unknown, costUSD: nil)]

        let summary = try XCTUnwrap(AgentDashboardViewController.sessionSummary([legacy, codex]))
        XCTAssertEqual(summary.tokens, 15_500)
        XCTAssertEqual(summary.cost, 0.05, accuracy: 1e-9)
        XCTAssertEqual(summary.byModel.count, 2)
    }

    /// No billed turns anywhere → nil, so the footer stays hidden.
    func testNilWhenNothingBilled() {
        let tab = TabModel()
        tab.paneTelemetries = [
            PaneTelemetry(paneID: tab.panes[0].id, usage: TranscriptUsage(), costUSD: nil)
        ]
        XCTAssertNil(AgentDashboardViewController.sessionSummary([tab]))
    }
}
