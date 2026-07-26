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

        let matches = SessionDeepSearch.search("bump the pnpm lockfile", in: [rec], index: index).matches
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

        let matches = SessionDeepSearch.search("npm install pnpm", in: [recA, recB], index: index).matches
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
        let extraction = SessionBodyText.extract(at: url)
        XCTAssertFalse(extraction.isTruncated, "a 2500-line log is nowhere near the byte budget")
        XCTAssertTrue(extraction.lines.joined(separator: "\n").contains("pangolin_at_line_2501"),
                      "phrase after line 2000 must still be extracted (no line cap)")

        let rec = record(agent: .claude, logPath: url.path)
        let index = SessionDeepSearch.buildIndex(for: [rec])
        let matches = SessionDeepSearch.search("pangolin_at_line_2501", in: [rec], index: index).matches
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

        XCTAssertTrue(SessionDeepSearch.search("kangaroo migration plan", in: [rec], index: index).matches.isEmpty)
    }

    // MARK: - 7. Per-file byte budget

    /// A transcript past its byte budget is truncated, not skipped: what was
    /// read is searchable, and the extraction says it is partial so the panel
    /// can stop claiming it searched the whole thing.
    func testExtractionTruncatesAtTheByteBudget() throws {
        var jsonl = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"early AARDVARK\"}]}}\n"
        for index in 0..<400 {
            jsonl += "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"filler \(index)\"}]}}\n"
        }
        jsonl += "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"late ZEBRA\"}]}}\n"

        let url = try writeLog(jsonl, name: "budgeted.jsonl")
        let extraction = SessionBodyText.extract(at: url, byteBudget: 500)

        XCTAssertTrue(extraction.isTruncated, "the budget ran out well before the end")
        XCTAssertLessThan(extraction.bytesRead, 1000, "reading stopped near the budget, not at EOF")
        let blob = extraction.lines.joined(separator: "\n")
        XCTAssertTrue(blob.contains("aardvark"), "text read before the budget ran out is kept")
        XCTAssertFalse(blob.contains("zebra"), "text past the budget is not read")
        XCTAssertEqual(extraction.characters, extraction.lines.reduce(0) { $0 + $1.count })
    }

    /// A budget that only bounds *work* still lets one giant record be
    /// assembled in memory first. A transcript written as a single enormous
    /// line (or with no newlines at all) must be cut off at the budget, not
    /// buffered whole and then measured.
    func testExtractionBoundsASingleLineLargerThanTheBudget() throws {
        let giant = String(repeating: "A", count: 400_000)
        let jsonl = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"\(giant)\"}]}}\n"
            + "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"after the giant WALLABY\"}]}}\n"

        let url = try writeLog(jsonl, name: "one-giant-line.jsonl")
        let extraction = SessionBodyText.extract(at: url, byteBudget: 4_096)

        XCTAssertTrue(extraction.isTruncated)
        XCTAssertTrue(extraction.lines.isEmpty,
                      "half a JSON record is not a record, so nothing is indexed from it")
        XCTAssertFalse(extraction.lines.joined().contains("wallaby"),
                       "reading stopped at the budget, before the next line")
        // Honest accounting: the cut line's full on-disk size is counted, even
        // though only `byteBudget` bytes of it were ever held.
        XCTAssertGreaterThan(extraction.bytesRead, 4_096)
    }

    /// The same hazard without any newline at all — the whole file is one line.
    func testExtractionBoundsAFileWithNoNewlines() throws {
        let url = try writeLog(String(repeating: "x", count: 200_000), name: "no-newlines.jsonl")
        let extraction = SessionBodyText.extract(at: url, byteBudget: 1_024)

        XCTAssertTrue(extraction.isTruncated)
        XCTAssertTrue(extraction.lines.isEmpty)
        XCTAssertEqual(extraction.bytesRead, 200_000, "every byte is counted, none are kept")
    }

    func testExtractionOfAWholeFileIsNotMarkedTruncated() throws {
        let url = try writeLog("""
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"short and complete"}]}}
        """, name: "short.jsonl")
        let extraction = SessionBodyText.extract(at: url)

        XCTAssertFalse(extraction.isTruncated)
        XCTAssertEqual(extraction.lines, ["short and complete"])
    }

    func testExtractionOfAMissingFileIsEmptyNotTruncated() {
        let extraction = SessionBodyText.extract(at: tempDir.appendingPathComponent("nope.jsonl"))
        XCTAssertEqual(extraction, SessionBodyText.Extraction())
    }

    // MARK: - 8. Index-wide budget

    /// The index holds sessions newest-first until its character budget runs
    /// out, then reports how many it left out. Skipped sessions are absent from
    /// the index, so a search over them finds nothing — which is exactly why the
    /// count has to reach the UI.
    func testIndexStopsAtItsCharacterBudgetAndReportsSkips() throws {
        var records: [SessionRecord] = []
        for i in 0..<5 {
            let url = try writeLog("""
            {"type":"user","message":{"role":"user","content":[{"type":"text","text":"session \(i) MARMOT_\(i) with a reasonable amount of prose in it"}]}}
            """, name: "budget-\(i).jsonl")
            records.append(record(agent: .claude, logPath: url.path))
        }

        // Room for roughly the first two sessions' text.
        let index = SessionDeepSearch.buildIndex(for: records, characterBudget: 100)

        XCTAssertTrue(index.isPartial)
        XCTAssertGreaterThan(index.skippedSessions, 0, "later sessions must be reported as skipped")
        XCTAssertEqual(index.linesByPath.count + index.skippedSessions, records.count,
                       "every session is either indexed or counted as skipped")
        XCTAssertFalse(SessionDeepSearch.search("marmot_0", in: records, index: index).matches.isEmpty,
                       "the first session is indexed and findable")
    }

    /// Total characters an index is holding.
    private func storedCharacters(_ index: SessionDeepSearch.Index) -> Int {
        index.linesByPath.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } }
    }

    /// Checking the budget only *before* each file lets the first transcript
    /// alone blow past it by its whole length. The budget has to bound what the
    /// index stores, whatever the first file's size.
    func testIndexNeverStoresMoreThanTheBudgetEvenForTheFirstTranscript() throws {
        let prose = String(repeating: "long winded prose about the build ", count: 200)
        let url = try writeLog("""
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"\(prose)"}]}}
        """, name: "one-big.jsonl")
        let rec = record(agent: .claude, logPath: url.path)

        let index = SessionDeepSearch.buildIndex(for: [rec], characterBudget: 500)

        XCTAssertLessThanOrEqual(storedCharacters(index), 500,
                                 "the first transcript alone must not overshoot the budget")
        XCTAssertTrue(index.truncatedPaths.contains(url.path),
                      "a transcript cut to fit is reported as truncated")
        XCTAssertTrue(index.isPartial)
    }

    /// Across many files too: whatever the mix, stored text stays under the cap
    /// and everything left out is accounted for.
    func testIndexBudgetHoldsAcrossManyTranscripts() throws {
        var records: [SessionRecord] = []
        for i in 0..<8 {
            let prose = String(repeating: "session \(i) prose ", count: 40)
            let url = try writeLog("""
            {"type":"user","message":{"role":"user","content":[{"type":"text","text":"\(prose)"}]}}
            """, name: "many-\(i).jsonl")
            records.append(record(agent: .claude, logPath: url.path))
        }

        let index = SessionDeepSearch.buildIndex(for: records, characterBudget: 1_000)

        XCTAssertLessThanOrEqual(storedCharacters(index), 1_000)
        XCTAssertEqual(index.linesByPath.count + index.skippedSessions, records.count)
        XCTAssertTrue(index.isPartial)
    }

    /// Cutting a line to fit the budget must cut Characters, not bytes — a
    /// byte-wise cut through a multi-byte scalar leaves mojibake in the index
    /// and in any snippet drawn from it.
    func testIndexTruncationDoesNotSplitMultiByteCharacters() throws {
        let url = try writeLog("""
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"日本語のテキストがここにたくさんあります"}]}}
        """, name: "unicode.jsonl")
        let rec = record(agent: .claude, logPath: url.path)

        let index = SessionDeepSearch.buildIndex(for: [rec], characterBudget: 5)
        let stored = try XCTUnwrap(index.linesByPath[url.path]).joined()

        XCTAssertEqual(stored.count, 5, "five Characters, not five bytes")
        XCTAssertFalse(stored.contains("\u{FFFD}"))
        XCTAssertEqual(stored, "日本語のテ")
    }

    func testCompleteIndexIsNotPartial() throws {
        let url = try writeLog("""
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"all of it fits"}]}}
        """, name: "whole.jsonl")
        let index = SessionDeepSearch.buildIndex(for: [record(agent: .claude, logPath: url.path)])

        XCTAssertFalse(index.isPartial)
        XCTAssertEqual(index.skippedSessions, 0)
        XCTAssertTrue(index.truncatedPaths.isEmpty)
    }

    func testIndexRecordsWhichTranscriptsWereTruncated() throws {
        var jsonl = ""
        for i in 0..<200 {
            jsonl += "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"line \(i)\"}]}}\n"
        }
        let url = try writeLog(jsonl, name: "huge.jsonl")
        let rec = record(agent: .claude, logPath: url.path)

        // The real per-file budget is 64 MiB; SessionBodyText.extract is where
        // it is enforced, so this checks the plumbing with a real (large) log
        // against a real (unbudgeted) index build.
        let index = SessionDeepSearch.buildIndex(for: [rec])
        XCTAssertTrue(index.truncatedPaths.isEmpty, "a 200-line log is far below the file budget")
        XCTAssertFalse(index.isPartial)
    }

    // MARK: - 9. Search limits and honest counts

    /// Hitting the match limit with sessions left over is a floor, not a total,
    /// and the result says so — the footer prints "50 of 51+" off this flag.
    func testSearchReportsCappedWhenTheLimitStopsItEarly() throws {
        var records: [SessionRecord] = []
        for i in 0..<6 {
            let url = try writeLog("""
            {"type":"user","message":{"role":"user","content":[{"type":"text","text":"every session mentions OTTER here"}]}}
            """, name: "otter-\(i).jsonl")
            records.append(record(agent: .claude, logPath: url.path))
        }
        let index = SessionDeepSearch.buildIndex(for: records)

        let capped = SessionDeepSearch.search("otter", in: records, index: index, limit: 3)
        XCTAssertEqual(capped.matches.count, 3)
        XCTAssertEqual(capped.scanned, 3)
        XCTAssertTrue(capped.isCapped, "three of six matches were found; the rest were never looked at")

        let complete = SessionDeepSearch.search("otter", in: records, index: index, limit: 100)
        XCTAssertEqual(complete.matches.count, 6)
        XCTAssertEqual(complete.scanned, 6)
        XCTAssertFalse(complete.isCapped, "everything was searched, so the count is a total")
    }

    /// A limit that happens to land on the last session searched everything
    /// there was; calling that capped would print a "+" that isn't true.
    func testSearchIsNotCappedWhenTheLimitLandsOnTheLastSession() throws {
        var records: [SessionRecord] = []
        for i in 0..<2 {
            let url = try writeLog("""
            {"type":"user","message":{"role":"user","content":[{"type":"text","text":"BADGER sighting \(i)"}]}}
            """, name: "badger-\(i).jsonl")
            records.append(record(agent: .claude, logPath: url.path))
        }
        let index = SessionDeepSearch.buildIndex(for: records)

        let results = SessionDeepSearch.search("badger", in: records, index: index, limit: 2)
        XCTAssertEqual(results.matches.count, 2)
        XCTAssertFalse(results.isCapped)
    }

    /// The session limit bounds the work of a single keystroke even if the
    /// index somehow holds more sessions than anyone expected.
    func testSearchStopsAtTheSessionLimit() throws {
        var records: [SessionRecord] = []
        for i in 0..<10 {
            let url = try writeLog("""
            {"type":"user","message":{"role":"user","content":[{"type":"text","text":"no hit here \(i)"}]}}
            """, name: "scan-\(i).jsonl")
            records.append(record(agent: .claude, logPath: url.path))
        }
        let index = SessionDeepSearch.buildIndex(for: records)

        let results = SessionDeepSearch.search("nothing", in: records, index: index, sessionLimit: 4)
        XCTAssertEqual(results.scanned, 4, "the scan stopped at the session limit")
        XCTAssertTrue(results.isCapped)
        XCTAssertTrue(results.matches.isEmpty)
    }

    // MARK: - 10. What the footer tells the user

    /// The footer is where a capped search or a partial index becomes visible.
    /// A count printed without them reads as "this is everything", which is the
    /// failure mode worth testing.
    func testFooterDistinguishesACompleteCountFromACappedOne() {
        let whole = SessionDeepSearch.Index(linesByPath: ["/a": ["x"]])

        XCTAssertNil(SessionsPanel.deepFooter(shown: 4, total: 4, isCapped: false, index: whole),
                     "everything shown and everything searched needs no footer")
        XCTAssertEqual(
            SessionsPanel.deepFooter(shown: 50, total: 312, isCapped: false, index: whole),
            "50 of 312 · keep typing to narrow"
        )
        XCTAssertEqual(
            SessionsPanel.deepFooter(shown: 50, total: 51, isCapped: true, index: whole),
            "50 of 51+ · keep typing to narrow",
            "a capped search knows only a floor, and has to say so"
        )
        XCTAssertEqual(
            SessionsPanel.deepFooter(shown: 0, total: 0, isCapped: false, index: whole),
            "no matches"
        )
    }

    func testFooterReportsWhatTheIndexLeftOut() {
        let skipped = SessionDeepSearch.Index(linesByPath: ["/a": ["x"]], skippedSessions: 12)
        XCTAssertEqual(
            SessionsPanel.deepFooter(shown: 0, total: 0, isCapped: false, index: skipped),
            "no matches · searched all but 12 sessions not indexed",
            "\"no matches\" means something else when 12 sessions were never read"
        )

        let truncated = SessionDeepSearch.Index(linesByPath: ["/a": ["x"]], truncatedPaths: ["/a"])
        XCTAssertEqual(
            SessionsPanel.deepFooter(shown: 3, total: 3, isCapped: false, index: truncated),
            "searched all but 1 transcript truncated"
        )

        let both = SessionDeepSearch.Index(
            linesByPath: ["/a": ["x"]],
            truncatedPaths: ["/a"],
            skippedSessions: 2
        )
        XCTAssertEqual(
            SessionsPanel.indexNote(both),
            "searched all but 2 sessions not indexed and 1 transcript truncated"
        )
        XCTAssertNil(SessionsPanel.indexNote(SessionDeepSearch.Index(linesByPath: ["/a": ["x"]])))
    }

    /// One is one, not "1 session(s)".
    func testFooterUsesSingularAndPluralCorrectly() {
        let one = SessionDeepSearch.Index(
            linesByPath: ["/a": ["x"]],
            truncatedPaths: ["/a", "/b"],
            skippedSessions: 1
        )
        XCTAssertEqual(
            SessionsPanel.indexNote(one),
            "searched all but 1 session not indexed and 2 transcripts truncated"
        )
    }

    func testEmptyPhraseSearchesNothing() throws {
        let url = try writeLog("""
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"anything at all"}]}}
        """, name: "empty-query.jsonl")
        let rec = record(agent: .claude, logPath: url.path)
        let results = SessionDeepSearch.search("   ", in: [rec], index: SessionDeepSearch.buildIndex(for: [rec]))

        XCTAssertEqual(results, SessionDeepSearch.Results())
    }
}
