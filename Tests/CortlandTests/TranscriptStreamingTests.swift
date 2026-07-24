import XCTest
@testable import CortlandTelemetryCore

/// Covers the streaming `aggregate(contentsOfFile:)` path (P5): it must produce
/// exactly what the in-memory `aggregate(jsonl:)` produces, including when a
/// single JSONL record straddles the reader's chunk boundary and when the file
/// has no trailing newline.
final class TranscriptStreamingTests: XCTestCase {
    private func writeTemp(_ contents: String) throws -> String {
        let path = NSTemporaryDirectory() + "transcript-\(UUID().uuidString).jsonl"
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    private let claude = """
    {"type":"mode","mode":"default"}
    {"type":"user","message":{"content":"hello"}}
    {"type":"assistant","message":{"model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":40,"cache_read_input_tokens":10,"cache_creation":{"ephemeral_5m_input_tokens":5,"ephemeral_1h_input_tokens":2}}}}
    {"type":"assistant","message":{"model":"claude-opus-4-8","usage":{"input_tokens":200,"output_tokens":80,"cache_read_input_tokens":20,"cache_creation":{"ephemeral_5m_input_tokens":6,"ephemeral_1h_input_tokens":0}}}}
    """

    private let pi = """
    {"type":"message","message":{"role":"user","content":"hi"}}
    {"type":"message","message":{"role":"assistant","model":"pi-1","usage":{"input":100,"output":40,"cacheRead":10,"cacheWrite":5,"cost":{"total":0.02}}}}
    {"type":"message","message":{"role":"assistant","model":"pi-1","usage":{"input":200,"output":80,"cacheRead":20,"cacheWrite":6,"cost":{"total":0.03}}}}
    """

    private let codex = """
    {"type":"turn_context","payload":{"model":"gpt-5.5"}}
    {"type":"event_msg","payload":{"type":"user_message","message":"hi"}}
    {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":5000,"cached_input_tokens":4000,"output_tokens":500},"last_token_usage":{"input_tokens":900}}}}
    """

    func testStreamingMatchesInMemoryForEachParser() throws {
        XCTAssertEqual(TranscriptParser.aggregate(contentsOfFile: try writeTemp(claude)),
                       TranscriptParser.aggregate(jsonl: claude))
        XCTAssertEqual(PiTranscriptParser.aggregate(contentsOfFile: try writeTemp(pi)),
                       PiTranscriptParser.aggregate(jsonl: pi))
        XCTAssertEqual(CodexTranscriptParser.aggregate(contentsOfFile: try writeTemp(codex)),
                       CodexTranscriptParser.aggregate(jsonl: codex))
    }

    func testNoTrailingNewlineStillParsesLastRecord() throws {
        // `claude` above has no trailing newline; the last assistant turn must
        // still be counted (contextTokens comes from it).
        let usage = TranscriptParser.aggregate(contentsOfFile: try writeTemp(claude))
        XCTAssertEqual(usage?.assistantResponses, 2)
        XCTAssertEqual(usage?.contextTokens, 200 + 20 + 6)   // last turn's footprint
    }

    func testRecordLargerThanChunkStraddlesBoundary() throws {
        // A record padded well past the 64 KiB read chunk must be reassembled
        // across chunk boundaries, not truncated or dropped.
        let padding = String(repeating: "x", count: 200_000)
        let jsonl = """
        {"type":"user","message":{"content":"\(padding)"}}
        {"type":"assistant","message":{"model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":40}}}
        """
        let usage = TranscriptParser.aggregate(contentsOfFile: try writeTemp(jsonl))
        XCTAssertEqual(usage, TranscriptParser.aggregate(jsonl: jsonl))
        XCTAssertEqual(usage?.userPrompts, 1)
        XCTAssertEqual(usage?.assistantResponses, 1)
        XCTAssertEqual(usage?.inputTokens, 100)
    }

    func testMissingFileReturnsNil() {
        XCTAssertNil(TranscriptParser.aggregate(contentsOfFile: "/no/such/transcript.jsonl"))
        XCTAssertNil(PiTranscriptParser.aggregate(contentsOfFile: "/no/such/transcript.jsonl"))
        XCTAssertNil(CodexTranscriptParser.aggregate(contentsOfFile: "/no/such/transcript.jsonl"))
    }
}
