import XCTest
@testable import Cortland

/// Covers the read-only Session Recall preview extractor (`SessionTranscript`):
/// ordered, role-tagged turns with case + line breaks preserved, tool COMMANDS
/// kept but tool OUTPUTS excluded, and injected wrapper turns skipped. Fixtures
/// are inline jsonl written to temp files (matching `SessionRecallDeepSearchTests`).
final class SessionTranscriptTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-transcript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func writeLog(_ jsonl: String, name: String = "log.jsonl") throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try jsonl.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - 1. Claude: user + assistant + tool_use, order/roles/case/output

    func testClaudeUserAssistantAndToolCommandInOrder() throws {
        let jsonl = """
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"Investigate the CamelCase\\nBug please"}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"On it."}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","input":{"command":"npm install ARMADILLO"}}]}}
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":[{"type":"text","text":"stdout DROPTHIS dump"}]}]}}
        """
        let turns = SessionTranscript.turns(at: try writeLog(jsonl))

        XCTAssertEqual(turns.count, 3, "user + assistant + tool; tool_result contributes no turn")
        XCTAssertEqual(turns[0].role, .user)
        XCTAssertEqual(turns[1].role, .assistant)
        XCTAssertEqual(turns[2].role, .tool)

        // Case and internal line breaks preserved (not lowercased/flattened).
        XCTAssertEqual(turns[0].text, "Investigate the CamelCase\nBug please")
        XCTAssertEqual(turns[2].text, "npm install ARMADILLO", "tool turn shows the command")

        let blob = turns.map(\.text).joined(separator: "\n")
        XCTAssertFalse(blob.contains("DROPTHIS"), "tool_result output must be absent")
    }

    // MARK: - 2. Codex: user_message + agent_message + function_call

    func testCodexUserAgentAndFunctionCall() throws {
        let jsonl = """
        {"type":"event_msg","payload":{"type":"user_message","message":"Codex Side NARWHAL"}}
        {"type":"event_msg","payload":{"type":"agent_message","message":"Reply OKAPI"}}
        {"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\\"command\\":[\\"bash\\",\\"-lc\\",\\"grep KEEPCMD src\\"]}"}}
        {"type":"response_item","payload":{"type":"function_call_output","output":"matched DROPOUT everywhere"}}
        """
        let turns = SessionTranscript.turns(at: try writeLog(jsonl, name: "codex.jsonl"))

        XCTAssertEqual(turns.count, 3, "user + agent + function_call; output contributes no turn")
        XCTAssertEqual(turns[0].role, .user)
        XCTAssertEqual(turns[1].role, .assistant)
        XCTAssertEqual(turns[2].role, .tool)

        XCTAssertEqual(turns[0].text, "Codex Side NARWHAL", "case preserved")
        XCTAssertEqual(turns[1].text, "Reply OKAPI")
        XCTAssertTrue(turns[2].text.contains("shell"), "function-call name kept")
        XCTAssertTrue(turns[2].text.contains("KEEPCMD"), "function-call command kept")

        let blob = turns.map(\.text).joined(separator: "\n")
        XCTAssertFalse(blob.contains("DROPOUT"), "function-call output must be absent")
    }

    // MARK: - 3. Wrapper first user turn is skipped; real prompt is turn 1

    func testWrapperFirstUserTurnIsSkipped() throws {
        let jsonl = """
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"<command-message>injected wrapper</command-message>"}]}}
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"the REAL prompt"}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}
        """
        let turns = SessionTranscript.turns(at: try writeLog(jsonl, name: "wrapper.jsonl"))

        XCTAssertEqual(turns.count, 2, "the wrapper user turn is dropped")
        XCTAssertEqual(turns[0].role, .user)
        XCTAssertEqual(turns[0].text, "the REAL prompt", "transcript starts at the real conversation")
    }

    // MARK: - 4. Malformed line skipped; empty/unreadable file → empty

    func testMalformedLineSkippedAndValidKept() throws {
        let jsonl = """
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"kept one"}]}}
        {this is not valid json at all
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"kept two"}]}}
        """
        let turns = SessionTranscript.turns(at: try writeLog(jsonl, name: "malformed.jsonl"))

        XCTAssertEqual(turns.map(\.text), ["kept one", "kept two"], "only the malformed line is dropped")
    }

    func testEmptyAndUnreadableFilesYieldNoTurns() throws {
        let empty = try writeLog("", name: "empty.jsonl")
        XCTAssertTrue(SessionTranscript.turns(at: empty).isEmpty)

        let missing = tempDir.appendingPathComponent("does-not-exist.jsonl")
        XCTAssertTrue(SessionTranscript.turns(at: missing).isEmpty)
    }
}
