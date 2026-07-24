import XCTest
@testable import CortlandTelemetryCore

final class TranscriptUsageTests: XCTestCase {
    /// A representative slice of a Claude Code transcript: noise lines, a typed
    /// prompt, two billed assistant responses (one with the nested cache split,
    /// one with only the flat legacy field), a tool-result user turn, and a
    /// malformed line — all of which the parser must handle.
    private let fixture = """
    {"type":"system","subtype":"init"}
    {"type":"user","message":{"role":"user","content":"hello, fix the bug"}}
    {"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-8","usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":2000,"cache_creation":{"ephemeral_5m_input_tokens":400,"ephemeral_1h_input_tokens":100}}}}
    {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"ok"}]}}
    {"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-8","usage":{"input_tokens":200,"output_tokens":100,"cache_creation_input_tokens":300}}}
    {"type":"attachment","foo":1}
    this is not json at all
    {"type":"mode"}
    """

    func testAggregatesUsageAndSkipsNoise() {
        let u = TranscriptParser.aggregate(jsonl: fixture)
        XCTAssertEqual(u.model, "claude-opus-4-8")
        XCTAssertEqual(u.inputTokens, 1200)
        XCTAssertEqual(u.outputTokens, 600)
        XCTAssertEqual(u.cacheReadTokens, 2000)
        XCTAssertEqual(u.cacheCreation5mTokens, 700)   // 400 nested + 300 legacy-flat
        XCTAssertEqual(u.cacheCreation1hTokens, 100)
        XCTAssertEqual(u.cacheCreationTokens, 800)
        XCTAssertEqual(u.assistantResponses, 2)
        XCTAssertEqual(u.userPrompts, 1)               // the tool-result user line doesn't count
        XCTAssertEqual(u.totalInputTokens, 1200 + 800 + 2000)
        // Context occupancy is the LAST turn's footprint, not the session sum:
        // turn 2 = input 200 + cacheRead 0 + cacheWrite 300.
        XCTAssertEqual(u.contextTokens, 500)
    }

    // MARK: - Context window

    func testContextFractionUsesLatestTurnAgainstStandardWindow() {
        // 50k occupied of the 200k standard window = 0.25.
        let u = TranscriptUsage(model: "claude-opus-4-8", contextTokens: 50_000)
        XCTAssertEqual(try XCTUnwrap(u.contextFraction()), 0.25, accuracy: 1e-9)
    }

    func testContextFractionNilWithoutBilledTurn() {
        XCTAssertNil(TranscriptUsage(model: "claude-opus-4-8", contextTokens: 0).contextFraction())
    }

    func testContextWindowPromotesToExtendedOncePastStandard() {
        // Above 200k the session must be running the 1M window, so it reads
        // against 1M rather than overflowing the standard cap.
        let u = TranscriptUsage(model: "claude-opus-4-8", contextTokens: 300_000)
        XCTAssertEqual(ContextWindow.tokens(forModel: u.model, occupancy: u.contextTokens), 1_000_000)
        XCTAssertEqual(try XCTUnwrap(u.contextFraction()), 0.3, accuracy: 1e-9)
    }

    func testContextFractionClampsToFull() {
        let u = TranscriptUsage(model: "claude-opus-4-8", contextTokens: 199_999)
        XCTAssertEqual(try XCTUnwrap(u.contextFraction()), 199_999.0 / 200_000.0, accuracy: 1e-9)
    }

    /// The transcript writes one line per content block, so a multi-block
    /// assistant message (text + tool calls) repeats the same message id with
    /// an identical usage object on every line. Each message bills once.
    func testDuplicateMessageIDLinesBillOnce() {
        let jsonl = """
        {"type":"assistant","message":{"id":"msg_a","role":"assistant","model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":1000}}}
        {"type":"assistant","message":{"id":"msg_a","role":"assistant","model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":1000}}}
        {"type":"assistant","message":{"id":"msg_a","role":"assistant","model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":1000}}}
        {"type":"assistant","message":{"id":"msg_b","role":"assistant","model":"claude-opus-4-8","usage":{"input_tokens":200,"output_tokens":25,"cache_read_input_tokens":2000}}}
        """
        let u = TranscriptParser.aggregate(jsonl: jsonl)
        XCTAssertEqual(u.assistantResponses, 2)
        XCTAssertEqual(u.inputTokens, 300)
        XCTAssertEqual(u.outputTokens, 75)
        XCTAssertEqual(u.cacheReadTokens, 3000)
        XCTAssertEqual(u.contextTokens, 2200)   // last distinct message's footprint
    }

    /// Assistant lines without a message id (unexpected, but tolerated) can't
    /// be correlated, so each still bills.
    func testAssistantLinesWithoutIDsEachBill() {
        let jsonl = """
        {"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":10}}}
        {"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":10}}}
        """
        let u = TranscriptParser.aggregate(jsonl: jsonl)
        XCTAssertEqual(u.assistantResponses, 2)
        XCTAssertEqual(u.inputTokens, 200)
    }

    /// Harness-injected user lines arrive as plain-string content with no
    /// distinguishing flag; they aren't typed prompts and don't count as turns.
    func testHarnessInjectedUserLinesAreNotPrompts() {
        let jsonl = """
        {"type":"user","message":{"role":"user","content":"<task-notification> <task-id>abc</task-id> done"}}
        {"type":"user","message":{"role":"user","content":"<command-name>/model</command-name>"}}
        {"type":"user","message":{"role":"user","content":"Caveat: The messages below were generated by the user while running local commands."}}
        {"type":"user","message":{"role":"user","content":"fix the flaky test in CI"}}
        """
        XCTAssertEqual(TranscriptParser.aggregate(jsonl: jsonl).userPrompts, 1)
    }

    func testEmptyAndAllNoiseYieldZero() {
        XCTAssertEqual(TranscriptParser.aggregate(jsonl: ""), TranscriptUsage())
        XCTAssertEqual(
            TranscriptParser.aggregate(jsonl: "{\"type\":\"mode\"}\nnonsense\n"),
            TranscriptUsage()
        )
    }

    // MARK: - Cost

    func testEstimatedCostMatchesRateCard() {
        let u = TranscriptParser.aggregate(jsonl: fixture)
        // opus 4.8: $5/$25 per 1M. reads ×0.1, 5m writes ×1.25, 1h writes ×2.
        // 1200·5e-6 + 600·25e-6 + 2000·0.1·5e-6 + 700·1.25·5e-6 + 100·2·5e-6
        XCTAssertEqual(try XCTUnwrap(u.estimatedCostUSD()), 0.027375, accuracy: 1e-9)
    }

    func testRateResolutionToleratesDateSuffix() {
        let rate = TelemetryRates.rate(forModel: "claude-haiku-4-5-20251001")
        XCTAssertEqual(rate, TelemetryRate(inputPerMTok: 1, outputPerMTok: 5))
    }

    func testNilForUnknownOrMissingModel() {
        XCTAssertNil(TranscriptUsage(model: nil, inputTokens: 100).estimatedCostUSD())
        XCTAssertNil(TranscriptUsage(model: "gpt-4o", inputTokens: 100).estimatedCostUSD())
    }

    // MARK: - Presentation formatting

    func testShortModel() {
        XCTAssertEqual(TelemetryFormat.shortModel("claude-opus-4-8"), "opus-4.8")
        XCTAssertEqual(TelemetryFormat.shortModel("claude-sonnet-4-6"), "sonnet-4.6")
        XCTAssertEqual(TelemetryFormat.shortModel("claude-haiku-4-5-20251001"), "haiku-4.5")
        XCTAssertEqual(TelemetryFormat.shortModel("claude-fable-5"), "fable-5")
    }

    func testCompactTokens() {
        XCTAssertEqual(TelemetryFormat.compactTokens(847), "847")
        XCTAssertEqual(TelemetryFormat.compactTokens(50_483), "50k")
        XCTAssertEqual(TelemetryFormat.compactTokens(146_587_198), "146.6M")
    }

    func testCostFloor() {
        XCTAssertEqual(TelemetryFormat.cost(0.0001), "<$0.01")
        XCTAssertEqual(TelemetryFormat.cost(0.36), "$0.36")
        XCTAssertEqual(TelemetryFormat.cost(73.4), "$73.40")
    }
}
