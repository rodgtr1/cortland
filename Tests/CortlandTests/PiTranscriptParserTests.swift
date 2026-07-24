import XCTest
@testable import CortlandTelemetryCore

final class PiTranscriptParserTests: XCTestCase {
    /// A Pi session slice: session/model_change noise, a user prompt, two
    /// assistant messages with per-turn usage (and Pi's own cost), a
    /// tool-result-style array user line, and a malformed line.
    private let fixture = """
    {"type":"session","session":{"model":"gpt-5.5"}}
    {"type":"model_change","provider":"openai-codex","modelId":"gpt-5.5"}
    {"type":"message","message":{"role":"user","content":"hi"}}
    {"type":"message","message":{"role":"assistant","model":"gpt-5.5","usage":{"input":1500,"output":60,"cacheRead":0,"cacheWrite":0,"totalTokens":1560,"cost":{"total":0.01}}}}
    {"type":"message","message":{"role":"toolResult","content":[{"type":"tool_result"}]}}
    {"type":"message","message":{"role":"assistant","model":"gpt-5.5","usage":{"input":300,"output":120,"cacheRead":6656,"cacheWrite":40,"totalTokens":7116,"cost":{"total":0.008}}}}
    not json
    """

    func testSumsPerTurnUsageAndCarriesReportedCost() throws {
        let u = PiTranscriptParser.aggregate(jsonl: fixture)
        XCTAssertEqual(u.model, "gpt-5.5")
        XCTAssertEqual(u.inputTokens, 1800)        // 1500 + 300, fresh
        XCTAssertEqual(u.outputTokens, 180)        // 60 + 120
        XCTAssertEqual(u.cacheReadTokens, 6656)
        XCTAssertEqual(u.cacheCreation5mTokens, 40)  // cacheWrite
        XCTAssertEqual(u.assistantResponses, 2)
        XCTAssertEqual(u.userPrompts, 1)           // toolResult role isn't a prompt
        XCTAssertEqual(try XCTUnwrap(u.reportedCostUSD), 0.018, accuracy: 1e-9)
    }

    func testReportedCostWinsOverRateCard() {
        // gpt-5.5 has no rate-card entry, yet cost is present because Pi reported it.
        let u = PiTranscriptParser.aggregate(jsonl: fixture)
        XCTAssertEqual(try XCTUnwrap(u.estimatedCostUSD()), 0.018, accuracy: 1e-9)
    }

    func testEmptyYieldsZero() {
        XCTAssertEqual(PiTranscriptParser.aggregate(jsonl: ""), TranscriptUsage())
    }
}
