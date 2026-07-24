import XCTest
@testable import CortlandTelemetryCore

final class CodexTranscriptParserTests: XCTestCase {
    /// A Codex rollout slice: session_meta, a turn_context carrying the model,
    /// two user_message/token_count pairs (cumulative usage), an agent_message,
    /// a malformed line, and a task_complete — all of which the parser handles.
    private let fixture = """
    {"type":"session_meta","payload":{"model_provider":"openai","cwd":"/repo"}}
    {"type":"turn_context","payload":{"model":"gpt-5.5","cwd":"/repo"}}
    {"type":"event_msg","payload":{"type":"user_message","message":"hi"}}
    {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":600,"output_tokens":100,"reasoning_output_tokens":0,"total_tokens":1100}}}}
    {"type":"event_msg","payload":{"type":"user_message","message":"more"}}
    {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":5000,"cached_input_tokens":4000,"output_tokens":500,"reasoning_output_tokens":120,"total_tokens":5500}}}}
    {"type":"event_msg","payload":{"type":"agent_message","message":"done"}}
    this is not json
    {"type":"event_msg","payload":{"type":"task_complete"}}
    """

    func testAggregatesCumulativeUsageAndModel() {
        let u = CodexTranscriptParser.aggregate(jsonl: fixture)
        XCTAssertEqual(u.model, "gpt-5.5")
        // Last token_count is the cumulative session total (5000/4000/500).
        XCTAssertEqual(u.inputTokens, 1000)        // fresh = 5000 - 4000 cached
        XCTAssertEqual(u.cacheReadTokens, 4000)
        XCTAssertEqual(u.outputTokens, 500)
        XCTAssertEqual(u.cacheCreationTokens, 0)   // Codex doesn't bill cache writes
        XCTAssertEqual(u.assistantResponses, 2)
        XCTAssertEqual(u.userPrompts, 2)
        XCTAssertEqual(u.totalInputTokens, 1000 + 4000)
    }

    func testNoCostForUnconfiguredCodexModel() {
        // gpt-5.5 isn't in the default Claude rate card, so cost is nil until the
        // user adds it under [telemetry] — tokens still surface.
        XCTAssertNil(CodexTranscriptParser.aggregate(jsonl: fixture).estimatedCostUSD())
    }

    func testEmptyYieldsZero() {
        XCTAssertEqual(CodexTranscriptParser.aggregate(jsonl: ""), TranscriptUsage())
    }
}
