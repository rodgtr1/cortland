import XCTest
@testable import Cortland

/// Pins the Swift Session Recall parser to the golden contract in
/// `Tests/Fixtures/SessionRecall/expected.json`. The fixtures encode the exact
/// heuristics (wrapper skipping, dual Codex prompt channels, lossy-cwd refusal)
/// that must survive the port from the Phase 0 Python prototype.
final class SessionRecallParserTests: XCTestCase {
    /// One expected record from the golden contract.
    private struct Expected: Decodable {
        let agent: String
        let cwd: String?
        let repo: String?
        let sessionID: String
        let resumeID: String
        let timestamp: String?
        let title: String
        let aiTitle: String?
        let cwdRecovery: String

        enum CodingKeys: String, CodingKey {
            case agent, cwd, repo, title
            case sessionID = "session_id"
            case resumeID = "resume_id"
            case timestamp
            case aiTitle = "ai_title"
            case cwdRecovery = "cwd_recovery"
        }
    }

    private struct Contract: Decodable {
        let records: [Expected]
    }

    /// Repo root: walk up from this test file (Tests/CortlandTests/…) two
    /// directories. The test target declares no resources, so the fixtures are
    /// located by a `#filePath`-relative path rather than `Bundle.module`.
    private var fixturesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/CortlandTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Tests/Fixtures/SessionRecall")
    }

    func testAllFixturesMatchGoldenContract() throws {
        let home = fixturesRoot.appendingPathComponent("home")
        let records = SessionLogScanner.scan(
            claudeProjectsRoot: home.appendingPathComponent(".claude/projects"),
            codexSessionsRoot: home.appendingPathComponent(".codex/sessions")
        )

        let contractData = try Data(contentsOf: fixturesRoot.appendingPathComponent("expected.json"))
        let expected = try JSONDecoder().decode(Contract.self, from: contractData).records

        // Key both sides by (agent, resumeID) so order-independence holds.
        let produced = Dictionary(uniqueKeysWithValues: records.map { ("\($0.agent.rawValue)|\($0.resumeID)", $0) })

        XCTAssertEqual(records.count, expected.count, "expected one record per fixture")

        for want in expected {
            let key = "\(want.agent)|\(want.resumeID)"
            guard let got = produced[key] else {
                XCTFail("no parsed record for \(key)")
                continue
            }

            XCTAssertEqual(got.agent.rawValue, want.agent, "agent for \(key)")
            XCTAssertEqual(got.sessionID, want.sessionID, "sessionID for \(key)")
            XCTAssertEqual(got.resumeID, want.resumeID, "resumeID for \(key)")
            XCTAssertEqual(got.title, want.title, "title for \(key)")
            XCTAssertEqual(got.aiTitle, want.aiTitle, "aiTitle for \(key)")
            XCTAssertEqual(got.timestamp, parseISO(want.timestamp), "timestamp for \(key)")

            // cwd/repo are only asserted where the log actually recorded a cwd.
            // For "ambiguous" fixtures the encoded dir name is lossy, so a
            // correct parser leaves cwd/repo nil rather than guessing.
            if want.cwdRecovery == "in-record" {
                XCTAssertEqual(got.cwd, want.cwd, "cwd for \(key)")
                XCTAssertEqual(got.repo, want.repo, "repo for \(key)")
            } else {
                XCTAssertNil(got.cwd, "cwd must be nil for ambiguous \(key)")
                XCTAssertNil(got.repo, "repo must be nil for ambiguous \(key)")
            }
        }
    }

    // MARK: - Streamed reads and the 2,000-line cap

    /// Write a jsonl file into a temp directory that the test tears down.
    private func writeTemporaryLog(_ jsonl: String, name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(name)
        try jsonl.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The scanner reads a bounded prefix of each log, and the file is streamed
    /// rather than slurped — so the 2,000-line cap bounds the read too. The
    /// observable half is that nothing past the cap reaches the record: a
    /// prompt on line 2,400 is not the session's title.
    func testScannerStopsAtTheLineCap() throws {
        var jsonl = ""
        for index in 0..<2_400 {
            jsonl += "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"filler \(index)\"}]}}\n"
        }
        jsonl += "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"PAST THE CAP\"}]}}\n"

        let url = try writeTemporaryLog(jsonl, name: "capped.jsonl")
        let record = try XCTUnwrap(SessionLogScanner.parseClaudeSession(at: url))

        XCTAssertEqual(record.title, "(no prompt found)",
                       "a prompt past line 2000 must not be read")
    }

    /// Everything inside the cap is still parsed, including a prompt near the
    /// end of the window — the streaming rewrite must not shorten the window.
    func testScannerReadsUpToTheLineCap() throws {
        var jsonl = ""
        for index in 0..<1_900 {
            jsonl += "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"filler \(index)\"}]}}\n"
        }
        jsonl += "{\"type\":\"user\",\"cwd\":\"/repo\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"INSIDE THE CAP\"}]}}\n"

        let url = try writeTemporaryLog(jsonl, name: "within-cap.jsonl")
        let record = try XCTUnwrap(SessionLogScanner.parseClaudeSession(at: url))

        XCTAssertEqual(record.title, "INSIDE THE CAP")
        XCTAssertEqual(record.cwd, "/repo")
    }

    /// Blank lines, whitespace-only lines, CRLF line endings, and malformed
    /// JSON are all skipped without throwing — the line-level parse now works on
    /// raw bytes, so the trimming has to happen there.
    func testScannerSkipsBlankAndMalformedLines() throws {
        let jsonl = "\r\n"
            + "   \n"
            + "not json at all\n"
            + "  {\"type\":\"user\",\"cwd\":\"/repo\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"still parsed\"}]}}  \r\n"

        let url = try writeTemporaryLog(jsonl, name: "messy.jsonl")
        let record = try XCTUnwrap(SessionLogScanner.parseClaudeSession(at: url))

        XCTAssertEqual(record.title, "still parsed")
        XCTAssertEqual(record.cwd, "/repo")
    }

    /// Agent logs inline whole file reads and command output, so a record can
    /// be tens of MB. One past the ceiling is skipped — not buffered, not
    /// parsed, and not fatal: the scan carries on and still finds the prompt
    /// that follows it.
    func testScannerSkipsAGiantRecordAndKeepsScanning() throws {
        let giant = String(repeating: "x", count: SessionLogScanner.maxBytesPerLine + 1_024)
        let jsonl = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"text\":\"\(giant)\"}]}}\n"
            + "{\"type\":\"user\",\"cwd\":\"/repo\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"THE REAL PROMPT\"}]}}\n"

        let url = try writeTemporaryLog(jsonl, name: "giant-record.jsonl")
        let record = try XCTUnwrap(SessionLogScanner.parseClaudeSession(at: url))

        XCTAssertEqual(record.title, "THE REAL PROMPT",
                       "a record too large to read must not cost the prompt after it")
        XCTAssertEqual(record.cwd, "/repo")
    }

    /// A log written as one record with no newline is the same hazard: it must
    /// be bounded, and it simply yields no prompt rather than a partial parse.
    func testScannerBoundsALogWithNoNewlines() throws {
        let url = try writeTemporaryLog(
            String(repeating: "y", count: SessionLogScanner.maxBytesPerLine + 512),
            name: "no-newline.jsonl"
        )
        let record = try XCTUnwrap(SessionLogScanner.parseClaudeSession(at: url))

        XCTAssertEqual(record.title, "(no prompt found)")
        XCTAssertNil(record.cwd)
    }

    /// Claude's `ai-title` can arrive after the first user turn, so the Claude
    /// pass reads its whole window rather than stopping at the prompt — the
    /// streaming fold must preserve that.
    func testScannerStillPicksUpAnAITitleAfterThePrompt() throws {
        let jsonl = """
        {"type":"user","cwd":"/repo","message":{"role":"user","content":[{"type":"text","text":"first prompt"}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"working"}]}}
        {"type":"ai-title","aiTitle":"Fixing the flaky test"}
        """
        let url = try writeTemporaryLog(jsonl, name: "late-ai-title.jsonl")
        let record = try XCTUnwrap(SessionLogScanner.parseClaudeSession(at: url))

        XCTAssertEqual(record.title, "first prompt")
        XCTAssertEqual(record.aiTitle, "Fixing the flaky test")
    }

    /// Codex has no ai-title, so it stops as soon as cwd, timestamp, and title
    /// are all in hand — the early exit the streaming rewrite has to keep.
    func testCodexScanStopsOnceEverythingIsFound() throws {
        let jsonl = """
        {"type":"session_meta","payload":{"cwd":"/repo","session_id":"abc","id":"abc","thread_source":"user","timestamp":"2026-07-24T10:00:00Z"}}
        {"type":"event_msg","payload":{"type":"user_message","message":"the codex prompt"}}
        {"type":"event_msg","payload":{"type":"user_message","message":"a later prompt that must not win"}}
        """
        let url = try writeTemporaryLog(jsonl, name: "rollout-2026-abc.jsonl")
        let record = try XCTUnwrap(SessionLogScanner.parseCodexRollout(at: url))

        XCTAssertEqual(record.title, "the codex prompt")
        XCTAssertEqual(record.cwd, "/repo")
        XCTAssertTrue(record.isRootThread)
    }

    func testTrimmingASCIIWhitespaceStripsBothEnds() {
        XCTAssertEqual(
            SessionLogScanner.trimmingASCIIWhitespace(Data(" \t{\"a\":1}\r\n".utf8)),
            Data("{\"a\":1}".utf8)
        )
        XCTAssertEqual(SessionLogScanner.trimmingASCIIWhitespace(Data("  \t\r\n".utf8)), Data())
        XCTAssertEqual(SessionLogScanner.trimmingASCIIWhitespace(Data()), Data())
    }

    func testUnreadableLogParsesToNil() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("definitely-not-here-\(UUID().uuidString).jsonl")
        XCTAssertNil(SessionLogScanner.parseClaudeSession(at: missing))
        XCTAssertNil(SessionLogScanner.parseCodexRollout(at: missing))
    }

    private func parseISO(_ value: String?) -> Date? {
        guard let value else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}
