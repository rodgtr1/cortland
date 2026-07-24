import XCTest
@testable import Cortland

/// Covers the opt-in Session Recall deep search: the body-text extractor
/// (`SessionBodyText`) and the in-memory index + phrase search with snippets
/// (`SessionDeepSearch`). Fixtures are inline jsonl written to temp files, so no
/// golden contract or on-disk cache is involved.
final class SessionRecallDeepSearchTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-deep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    /// Write inline jsonl to a temp file and return its URL.
    private func writeLog(_ jsonl: String, name: String = "log.jsonl") throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try jsonl.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A minimal record pointing at a log path — deep search only needs
    /// `logPath` to key the index and return the record.
    private func record(agent: SessionAgent, logPath: String) -> SessionRecord {
        SessionRecord(
            agent: agent,
            cwd: "/repo",
            repo: "repo",
            sessionID: "sid",
            resumeID: "rid",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            title: "title",
            aiTitle: nil,
            resumeCommand: "cmd",
            logPath: logPath
        )
    }

    // MARK: - 1. Extractor includes prose + commands

    func testExtractorIncludesProseAndCommands() throws {
        // A Claude-shaped log: a user prompt, an assistant reply, and a tool call
        // running a shell command — all three should land in the body text.
        let jsonl = """
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"Please investigate the FLYINGSQUIRREL bug"}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Sure, running the PORCUPINE diagnostics now"}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","input":{"command":"npm install ARMADILLO --save"}}]}}
        """
        let url = try writeLog(jsonl)
        let blob = SessionBodyText.extractLines(at: url).joined(separator: "\n")

        XCTAssertTrue(blob.contains("flyingsquirrel"), "user prose missing")
        XCTAssertTrue(blob.contains("porcupine"), "assistant prose missing")
        XCTAssertTrue(blob.contains("armadillo"), "tool-call command missing")
    }

    // MARK: - 2. Extractor excludes bulk output

    func testExtractorExcludesBulkToolOutput() throws {
        // A large tool RESULT carries a unique token that must NOT be indexed;
        // the sibling user prose must still be present.
        let jsonl = """
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"run the tests KEEPTHIS"}]}}
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":[{"type":"text","text":"lots of stdout DROPTHIS lines and dumps"}]}]}}
        """
        let url = try writeLog(jsonl)
        let blob = SessionBodyText.extractLines(at: url).joined(separator: "\n")

        XCTAssertTrue(blob.contains("keepthis"), "prose should be indexed")
        XCTAssertFalse(blob.contains("dropthis"), "bulk tool output must be excluded")
    }

    func testExtractorExcludesCodexFunctionCallOutput() throws {
        // Codex: the function_call arguments are kept, its output is dropped.
        let jsonl = """
        {"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\\"command\\":[\\"bash\\",\\"-lc\\",\\"grep KEEPCMD src\\"]}"}}
        {"type":"response_item","payload":{"type":"function_call_output","output":"matched DROPOUT in many files"}}
        """
        let url = try writeLog(jsonl)
        let blob = SessionBodyText.extractLines(at: url).joined(separator: "\n")

        XCTAssertTrue(blob.contains("keepcmd"), "function-call command must be indexed")
        XCTAssertFalse(blob.contains("dropout"), "function-call output must be excluded")
    }

    // MARK: - 3. Both agents extract

    func testBothAgentsExtract() throws {
        let claude = try writeLog("""
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"claude side WOMBAT"}]}}
        """, name: "claude.jsonl")
        let codex = try writeLog("""
        {"type":"event_msg","payload":{"type":"user_message","message":"codex side NARWHAL"}}
        {"type":"event_msg","payload":{"type":"agent_message","message":"reply OKAPI"}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"more QUOKKA"}]}}
        """, name: "codex.jsonl")

        let claudeBlob = SessionBodyText.extractLines(at: claude).joined(separator: "\n")
        let codexBlob = SessionBodyText.extractLines(at: codex).joined(separator: "\n")

        XCTAssertTrue(claudeBlob.contains("wombat"))
        XCTAssertTrue(codexBlob.contains("narwhal"), "codex user_message missing")
        XCTAssertTrue(codexBlob.contains("okapi"), "codex agent_message missing")
        XCTAssertTrue(codexBlob.contains("quokka"), "codex response_item/message missing")
    }

    // MARK: - 4. Search + snippet

    func testSearchReturnsSessionWithSnippet() throws {
        let url = try writeLog("""
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"the fix was to bump the pnpm lockfile version manually"}]}}
        """)
        let rec = record(agent: .claude, logPath: url.path)
        let index = SessionDeepSearch.buildIndex(for: [rec])

        let matches = SessionDeepSearch.search("bump the pnpm lockfile", in: [rec], index: index)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.record, rec)
        XCTAssertTrue(matches.first?.snippet.contains("bump the pnpm lockfile") == true,
                      "snippet should contain the matched phrase")
    }

    // MARK: - 5. Multi-word phrase match (contiguous only)

    func testPhraseMatchesContiguousButNotScattered() throws {
        let contiguous = try writeLog("""
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"I ran npm install pnpm to switch package managers"}]}}
        """, name: "contiguous.jsonl")
        let scattered = try writeLog("""
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"npm was slow so I install things with pnpm sometimes"}]}}
        """, name: "scattered.jsonl")

        let recA = record(agent: .claude, logPath: contiguous.path)
        let recB = record(agent: .claude, logPath: scattered.path)
        let index = SessionDeepSearch.buildIndex(for: [recA, recB])

        let matches = SessionDeepSearch.search("npm install pnpm", in: [recA, recB], index: index)
        XCTAssertEqual(matches.map(\.record), [recA],
                       "only the contiguous phrase should match, not scattered words")
    }

    // MARK: - 5b. Long transcripts are extracted in full (no line cap)

    func testExtractionIsNotCappedForLongTranscripts() throws {
        // Deep search exists to find "that phrase from a long session", so the
        // extractor must not silently truncate. Build a transcript with well
        // over 2000 lines where a unique phrase appears only near the END, and
        // assert both the extractor and a deep search still find it.
        var jsonl = ""
        for index in 0..<2500 {
            jsonl += "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"filler line \(index)\"}]}}\n"
        }
        jsonl += "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"the buried needle is PANGOLIN_AT_LINE_2501\"}]}}"

        let url = try writeLog(jsonl, name: "long.jsonl")
        let blob = SessionBodyText.extractLines(at: url).joined(separator: "\n")
        XCTAssertTrue(blob.contains("pangolin_at_line_2501"),
                      "phrase after line 2000 must still be extracted (no cap)")

        let rec = record(agent: .claude, logPath: url.path)
        let index = SessionDeepSearch.buildIndex(for: [rec])
        let matches = SessionDeepSearch.search("pangolin_at_line_2501", in: [rec], index: index)
        XCTAssertEqual(matches.map(\.record), [rec],
                       "deep search must find a phrase buried past line 2000")
    }

    // MARK: - 6. Negative

    func testAbsentPhraseReturnsNoMatches() throws {
        let url = try writeLog("""
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"nothing relevant here at all"}]}}
        """)
        let rec = record(agent: .claude, logPath: url.path)
        let index = SessionDeepSearch.buildIndex(for: [rec])

        XCTAssertTrue(SessionDeepSearch.search("kangaroo migration plan", in: [rec], index: index).isEmpty)
    }
}
