import XCTest
import CortlandProInterface
@testable import Cortland

/// Covers the public half of the Session Recall polish pass: Codex rollout
/// dedupe (`SessionQuery.dedupeSessions` + the `isRootThread` flag) and the
/// generated-title cache round-trip. Both are shared — the free teaser reads
/// the same records the Pro panel does.
///
/// The titler that *produces* those titles is Pro; its tests live beside it in
/// CortlandProTests.
final class SessionRecallPolishTests: XCTestCase {
    private let fm = FileManager.default

    // MARK: - Record helper

    private func record(
        agent: SessionAgent,
        sessionID: String,
        resumeID: String? = nil,
        title: String = "t",
        timestamp: Date? = nil,
        isRootThread: Bool = true,
        logPath: String? = nil
    ) -> SessionRecord {
        SessionRecord(
            agent: agent,
            cwd: "/Users/travis/Repos/x",
            repo: "x",
            sessionID: sessionID,
            resumeID: resumeID ?? sessionID,
            timestamp: timestamp,
            title: title,
            aiTitle: nil,
            resumeCommand: "cmd",
            logPath: logPath ?? "/tmp/\(resumeID ?? sessionID).jsonl",
            isRootThread: isRootThread
        )
    }

    // MARK: - Part 1: dedupe

    func testCodexRootAndSubagentCollapseToRootRegardlessOfOrder() {
        let root = record(agent: .codex, sessionID: "S1", resumeID: "root", isRootThread: true,
                          logPath: "/tmp/root.jsonl")
        let sub = record(agent: .codex, sessionID: "S1", resumeID: "sub", isRootThread: false,
                         logPath: "/tmp/sub.jsonl")

        for input in [[root, sub], [sub, root]] {
            let deduped = SessionQuery.dedupeSessions(input)
            XCTAssertEqual(deduped.count, 1, "one row per logical session")
            XCTAssertEqual(deduped.first?.resumeID, "root", "the root thread wins")
        }
    }

    func testCodexWithoutRootKeepsNewest() {
        let older = record(agent: .codex, sessionID: "S1", resumeID: "old",
                           timestamp: Date(timeIntervalSince1970: 1_000), isRootThread: false,
                           logPath: "/tmp/old.jsonl")
        let newer = record(agent: .codex, sessionID: "S1", resumeID: "new",
                           timestamp: Date(timeIntervalSince1970: 2_000), isRootThread: false,
                           logPath: "/tmp/new.jsonl")

        for input in [[older, newer], [newer, older]] {
            let deduped = SessionQuery.dedupeSessions(input)
            XCTAssertEqual(deduped.count, 1)
            XCTAssertEqual(deduped.first?.resumeID, "new", "newest wins when no root is present")
        }
    }

    func testClaudeRecordsNeverCollapse() {
        // Even with an (impossible) shared sessionID, distinct Claude logs each
        // survive; in practice their sessionIDs are unique filename stems.
        let a = record(agent: .claude, sessionID: "c-a", logPath: "/tmp/a.jsonl")
        let b = record(agent: .claude, sessionID: "c-b", logPath: "/tmp/b.jsonl")
        let deduped = SessionQuery.dedupeSessions([a, b])
        XCTAssertEqual(Set(deduped.map(\.sessionID)), ["c-a", "c-b"])
    }

    func testDedupeMixedAgentsAndDistinctSessionsPassThrough() {
        let claude = record(agent: .claude, sessionID: "c1", logPath: "/tmp/c1.jsonl")
        let codexRoot = record(agent: .codex, sessionID: "S1", resumeID: "root", isRootThread: true,
                               logPath: "/tmp/root.jsonl")
        let codexSub = record(agent: .codex, sessionID: "S1", resumeID: "sub", isRootThread: false,
                              logPath: "/tmp/sub.jsonl")
        let codexOther = record(agent: .codex, sessionID: "S2", resumeID: "o", isRootThread: true,
                                logPath: "/tmp/o.jsonl")

        let deduped = SessionQuery.dedupeSessions([claude, codexSub, codexRoot, codexOther])
        XCTAssertEqual(deduped.count, 3)
        XCTAssertTrue(deduped.contains { $0.resumeID == "c1" })
        XCTAssertTrue(deduped.contains { $0.resumeID == "root" })
        XCTAssertTrue(deduped.contains { $0.resumeID == "o" })
        XCTAssertFalse(deduped.contains { $0.resumeID == "sub" })
    }

    // MARK: - Part 1: backward-compatible decoding

    func testRecordDecodesWithoutIsRootThreadField() throws {
        // JSON predating isRootThread/generatedTitle must still decode, with the
        // flag defaulting to true and the generated title to nil.
        let json = """
        {
          "agent": "codex",
          "sessionID": "S1",
          "resumeID": "S1",
          "title": "old record",
          "resumeCommand": "codex resume S1",
          "logPath": "/tmp/S1.jsonl"
        }
        """
        let decoded = try JSONDecoder().decode(SessionRecord.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.isRootThread)
        XCTAssertNil(decoded.generatedTitle)
        XCTAssertEqual(decoded.title, "old record")
    }

    // MARK: - Generated-title cache round-trip

    func testStoreGeneratedTitleRoundTrips() throws {
        let base = fm.temporaryDirectory.appendingPathComponent("SRPolish-\(UUID().uuidString)")
        let claudeRoot = base.appendingPathComponent(".claude/projects")
        let codexRoot = base.appendingPathComponent(".codex/sessions/2026/07")
        let cacheURL = base.appendingPathComponent("cache/session-recall-cache.json")
        try fm.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let meta: [String: Any] = [
            "type": "session_meta",
            "payload": [
                "cwd": "/Users/travis/Repos/beta",
                "session_id": "sess-1",
                "id": "sess-1",
                "thread_source": "user",
                "timestamp": "2026-07-05T12:00:00.000Z",
            ],
        ]
        let msg: [String: Any] = ["type": "event_msg", "payload": ["type": "user_message", "message": "Fix the beta bug"]]
        let lines = try [meta, msg].map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            .joined(separator: "\n") + "\n"
        let logURL = codexRoot.appendingPathComponent("rollout-2026-07-05-sess-1.jsonl")
        try lines.write(to: logURL, atomically: true, encoding: .utf8)

        func refresh() -> [SessionRecord] {
            SessionRecallCache.refresh(
                claudeProjectsRoot: claudeRoot,
                codexSessionsRoot: base.appendingPathComponent(".codex/sessions"),
                cacheURL: cacheURL,
                fileManager: fm
            )
        }

        let first = refresh()
        XCTAssertEqual(first.count, 1)
        XCTAssertNil(first.first?.generatedTitle)

        let path = try XCTUnwrap(SessionRecallCache.load(from: cacheURL, fileManager: fm).entries.first?.path)
        SessionRecallCache.storeGeneratedTitle("Beta Bug Fix", forLogPath: path, cacheURL: cacheURL, fileManager: fm)

        let after = refresh()
        XCTAssertEqual(after.first?.generatedTitle, "Beta Bug Fix", "the title survives the cache round-trip")
    }

    func testCacheEntryDecodesWithoutGeneratedTitleField() throws {
        // An Entry serialized before generatedTitle existed must still decode.
        let json = """
        {
          "entries": [
            {
              "path": "/tmp/S1.jsonl",
              "mtime": 0,
              "record": {
                "agent": "codex", "sessionID": "S1", "resumeID": "S1",
                "title": "old", "resumeCommand": "codex resume S1",
                "logPath": "/tmp/S1.jsonl"
              }
            }
          ]
        }
        """
        let snapshot = try JSONDecoder().decode(SessionRecallCache.Snapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.entries.count, 1)
        XCTAssertNil(snapshot.entries.first?.generatedTitle)
        XCTAssertTrue(snapshot.entries.first?.record.isRootThread ?? false)
    }
}
