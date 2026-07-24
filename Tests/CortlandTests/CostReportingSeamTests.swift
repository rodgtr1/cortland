import XCTest
import CortlandProInterface
import CortlandTelemetryCore
@testable import Cortland

/// The public half of cost reporting: turning the tab tree into billed entries
/// (free — that's telemetry), and rendering no money without a provider.
@MainActor
final class CostReportingSeamTests: XCTestCase {
    override func tearDown() {
        ProFeatures.reset()
        super.tearDown()
    }

    private func usage(model: String, input: Int, output: Int, responses: Int = 1) -> TranscriptUsage {
        TranscriptUsage(model: model, inputTokens: input, outputTokens: output, assistantResponses: responses)
    }

    /// A split tab contributes one entry per billed pane, each priced at its
    /// own model and labelled with its pane position.
    func testEntriesAreOnePerBilledPaneWithPaneLabels() {
        let tab = TabModel()
        tab.addPane(PaneModel())
        let fable = usage(model: "claude-fable-5", input: 100_000, output: 10_000)
        let opus = usage(model: "claude-opus-4-8", input: 50_000, output: 5_000)
        tab.paneTelemetries = [
            PaneTelemetry(paneID: tab.panes[0].id, usage: fable, costUSD: 1.5),
            PaneTelemetry(paneID: tab.panes[1].id, usage: opus, costUSD: 0.375),
        ]

        let entries = TabController.costEntries(for: tab)
        XCTAssertEqual(entries.map(\.model), ["claude-fable-5", "claude-opus-4-8"])
        XCTAssertEqual(entries.map(\.costUSD), [1.5, 0.375])
        XCTAssertEqual(entries[0].title, "\(tab.title) · pane 1")
        XCTAssertEqual(entries[1].title, "\(tab.title) · pane 2")
    }

    /// A tab whose per-pane list hasn't populated still contributes its primary
    /// usage, under the plain tab title.
    func testFallsBackToTheTabsPrimaryUsage() {
        let tab = TabModel()
        tab.telemetry = usage(model: "claude-opus-4-8", input: 10_000, output: 0)
        tab.telemetryCostUSD = 0.05

        let entries = TabController.costEntries(for: tab)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].title, tab.title)
        XCTAssertEqual(entries[0].tokens, 10_000)
        XCTAssertEqual(entries[0].costUSD, 0.05)
    }

    /// A pane that reported usage but never completed a turn isn't billed.
    func testUnbilledPanesContributeNothing() {
        let tab = TabModel()
        tab.paneTelemetries = [
            PaneTelemetry(paneID: tab.panes[0].id, usage: TranscriptUsage(), costUSD: nil)
        ]
        XCTAssertTrue(TabController.costEntries(for: tab).isEmpty)
    }

    // MARK: - Free rendering

    /// Free keeps the model and the turn count — telemetry — and drops the `$`.
    func testRowTelemetryLineOmitsCostWithoutAProvider() throws {
        #if CORTLAND_PRO
        throw XCTSkip("Pro build: cost reporting is registered at launch")
        #else
        var billed = usage(model: "claude-opus-4-8", input: 1_000, output: 100)
        billed.userPrompts = 7
        let line = AgentDashboardViewController.telemetryLine(billed, cost: 0.36)
        XCTAssertEqual(line, "opus-4.8 · 7t")
        XCTAssertFalse(line?.contains("$") ?? false)
        #endif
    }

    /// With a provider the same row carries the figure, from the same data.
    func testRowTelemetryLineShowsCostWithAProvider() {
        ProFeatures.costReporting = StubCostReporting()
        var billed = usage(model: "claude-opus-4-8", input: 1_000, output: 100)
        billed.userPrompts = 7
        XCTAssertEqual(AgentDashboardViewController.telemetryLine(billed, cost: 0.36), "opus-4.8 · $0.36 · 7t")
    }

    func testCostReportingIsUnregisteredByDefault() throws {
        #if CORTLAND_PRO
        throw XCTSkip("Pro build: cost reporting is registered at launch")
        #else
        XCTAssertNil(ProFeatures.costReporting)
        #endif
    }
}

private final class StubCostReporting: CostReportingProviding {
    func install(formatting: ProCostFormatting) {}
    func rowCostText(_ costUSD: Double?) -> String? { costUSD.map { String(format: "$%.2f", $0) } }
    func sessionFooter(_ entries: [ProCostEntry]) -> (line: String, tooltip: String)? { nil }
    func recordCosts(_ entries: [ProCostEntry]) {}
}
