import XCTest
import CortlandProInterface
@testable import Cortland

/// Covers Session Recall Phase 1 part B: the mtime-keyed on-disk cache
/// (`SessionRecallCache`) and the in-memory query API (`SessionQuery`).
///
/// Every test builds its own throwaway temp tree of Claude/Codex logs (like
/// `PaletteSkillScannerTests`) and points the cache at a temp JSON file — the
/// committed fixtures under `Tests/Fixtures/SessionRecall/` are never touched.
final class SessionRecallCacheTests: XCTestCase {
    private var base: URL!
    private var claudeRoot: URL!
    private var codexRoot: URL!
    private var cacheURL: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory
            .appendingPathComponent("SessionRecallCacheTests-\(UUID().uuidString)")
        claudeRoot = base.appendingPathComponent(".claude/projects")
        codexRoot = base.appendingPathComponent(".codex/sessions")
        cacheURL = base.appendingPathComponent("cache/session-recall-cache.json")
        try fm.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: codexRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    // MARK: - Fixture builders

    /// Write a minimal but real Claude session log and return its file URL.
    @discardableResult
    private func writeClaudeLog(
        project: String,
        sessionID: String,
        cwd: String,
        title: String,
        timestamp: String = "2026-07-01T10:00:00.000Z"
    ) throws -> URL {
        let dir = claudeRoot.appendingPathComponent(project)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let line: [String: Any] = [
            "type": "user",
            "cwd": cwd,
            "timestamp": timestamp,
            "message": ["role": "user", "content": title],
        ]
        let url = dir.appendingPathComponent("\(sessionID).jsonl")
        try jsonl([line]).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Write a minimal but real Codex rollout log and return its file URL.
    @discardableResult
    private func writeCodexLog(
        rolloutID: String,
        cwd: String,
        title: String,
        timestamp: String = "2026-07-05T12:00:00.000Z"
    ) throws -> URL {
        let dir = codexRoot.appendingPathComponent("2026/07")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let meta: [String: Any] = [
            "type": "session_meta",
            "payload": [
                "cwd": cwd,
                "session_id": "sess-\(rolloutID)",
                "id": rolloutID,
                "timestamp": timestamp,
            ],
        ]
        let msg: [String: Any] = [
            "type": "event_msg",
            "payload": ["type": "user_message", "message": title],
        ]
        let url = dir.appendingPathComponent("rollout-2026-07-05-\(rolloutID).jsonl")
        try jsonl([meta, msg]).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func jsonl(_ objects: [[String: Any]]) throws -> String {
        try objects.map { object in
            let data = try JSONSerialization.data(withJSONObject: object)
            return String(decoding: data, as: UTF8.self)
        }.joined(separator: "\n") + "\n"
    }

    private func refresh() -> [SessionRecord] {
        SessionRecallCache.refresh(
            claudeProjectsRoot: claudeRoot,
            codexSessionsRoot: codexRoot,
            cacheURL: cacheURL,
            fileManager: fm
        )
    }

    private func mtime(of url: URL) throws -> Date {
        try XCTUnwrap((try fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date)
    }

    // MARK: - 1. Round-trip

    func testRefreshPersistsAndReloadsEqualRecords() throws {
        try writeClaudeLog(project: "alpha", sessionID: "alpha-session", cwd: "/Users/travis/Repos/alpha", title: "Build the alpha feature")
        try writeCodexLog(rolloutID: "11111111-2222-3333-4444-555555555555", cwd: "/Users/travis/Repos/beta", title: "Fix the beta bug")

        let first = refresh().sorted { $0.resumeID < $1.resumeID }
        XCTAssertEqual(first.count, 2)
        XCTAssertTrue(fm.fileExists(atPath: cacheURL.path), "cache file must be written to disk")

        // Reload straight from the persisted JSON: records survive the round-trip.
        let reloaded = SessionRecallCache.load(from: cacheURL).entries
            .map(\.record)
            .sorted { $0.resumeID < $1.resumeID }
        XCTAssertEqual(reloaded, first)

        // A second refresh with no source changes returns the same records.
        let second = refresh().sorted { $0.resumeID < $1.resumeID }
        XCTAssertEqual(second, first)
    }

    // MARK: - 2. Incremental: unchanged files are not re-parsed

    func testUnchangedFileIsNotReparsedThenIsWhenMTimeBumps() throws {
        let logURL = try writeClaudeLog(
            project: "alpha", sessionID: "alpha-session",
            cwd: "/Users/travis/Repos/alpha", title: "Build the alpha feature"
        )

        _ = refresh()

        // Hand-edit the persisted cache to a sentinel title, leaving the stored
        // mtime untouched. If the file were re-parsed, this stale value would be
        // overwritten by the real title.
        var snapshot = SessionRecallCache.load(from: cacheURL)
        // Match by agent rather than path: FileManager resolves the temp dir's
        // /var → /private/var symlink when enumerating, so the stored path won't
        // string-equal our constructed URL. (The cache is internally consistent
        // — it stores and compares the same resolved paths.)
        let idx = try XCTUnwrap(snapshot.entries.firstIndex { $0.record.agent == .claude })
        let stale = snapshot.entries[idx].record
        snapshot.entries[idx].record = withTitle(stale, "STALE CACHED TITLE")
        try JSONEncoder().encode(snapshot).write(to: cacheURL)

        // File untouched → cache reused → stale title comes back (no re-parse).
        let reused = refresh()
        XCTAssertEqual(reused.first?.title, "STALE CACHED TITLE")

        // Bump the log's mtime → cache invalidated → fresh parse restores the
        // real title.
        let bumped = try mtime(of: logURL).addingTimeInterval(120)
        try fm.setAttributes([.modificationDate: bumped], ofItemAtPath: logURL.path)

        let reparsed = refresh()
        XCTAssertEqual(reparsed.first?.title, "Build the alpha feature")
    }

    // MARK: - 3. Deleted source file → record dropped

    func testDeletedFileIsDroppedOnNextRefresh() throws {
        try writeClaudeLog(project: "alpha", sessionID: "alpha-session", cwd: "/Users/travis/Repos/alpha", title: "Build the alpha feature")
        let codexURL = try writeCodexLog(rolloutID: "11111111-2222-3333-4444-555555555555", cwd: "/Users/travis/Repos/beta", title: "Fix the beta bug")

        XCTAssertEqual(refresh().count, 2)

        try fm.removeItem(at: codexURL)

        let after = refresh()
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.agent, .claude)
        XCTAssertFalse(after.contains { $0.agent == .codex })
        // The dropped record is gone from the persisted cache too.
        XCTAssertEqual(SessionRecallCache.load(from: cacheURL).entries.count, 1)
    }

    // MARK: - 4. New source file → record added

    func testNewFileIsAddedOnNextRefresh() throws {
        try writeClaudeLog(project: "alpha", sessionID: "alpha-session", cwd: "/Users/travis/Repos/alpha", title: "Build the alpha feature")
        XCTAssertEqual(refresh().count, 1)

        try writeCodexLog(rolloutID: "11111111-2222-3333-4444-555555555555", cwd: "/Users/travis/Repos/beta", title: "Fix the beta bug")

        let after = refresh()
        XCTAssertEqual(after.count, 2)
        XCTAssertTrue(after.contains { $0.agent == .codex && $0.title == "Fix the beta bug" })
    }

    // MARK: - 5. Query API

    func testQueryFiltersSortsAndLimits() {
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let newest = Date(timeIntervalSince1970: 3_000)

        let claudeAlpha = record(agent: .claude, cwd: "/Users/travis/Repos/Alpha", title: "Ship the login screen", timestamp: newer, resumeID: "c1")
        let codexBeta = record(agent: .codex, cwd: "/Users/travis/Repos/beta", title: "Rewrite the parser", timestamp: newest, resumeID: "x1")
        let claudeGamma = record(agent: .claude, cwd: "/Users/travis/Repos/gamma", title: "Add gamma tests", aiTitle: "Login flow polish", timestamp: older, resumeID: "c2")
        let noStamp = record(agent: .codex, cwd: "/Users/travis/Repos/delta", title: "No timestamp here", timestamp: nil, resumeID: "x2")
        let all = [claudeAlpha, codexBeta, claudeGamma, noStamp]

        // agent filter
        XCTAssertEqual(
            Set(SessionQuery.run(all, agent: .claude).map(\.resumeID)),
            ["c1", "c2"]
        )

        // repo substring, case-insensitive (matches repo/cwd)
        XCTAssertEqual(
            SessionQuery.run(all, repo: "alpha").map(\.resumeID),
            ["c1"]
        )

        // search substring over title (case-insensitive)
        XCTAssertEqual(
            SessionQuery.run(all, search: "PARSER").map(\.resumeID),
            ["x1"]
        )
        // search also spans aiTitle
        XCTAssertEqual(
            SessionQuery.run(all, search: "login flow").map(\.resumeID),
            ["c2"]
        )

        // newest first; the nil-timestamp record sinks to the bottom.
        XCTAssertEqual(
            SessionQuery.run(all).map(\.resumeID),
            ["x1", "c1", "c2", "x2"]
        )

        // limit applied after sorting
        XCTAssertEqual(
            SessionQuery.run(all, limit: 2).map(\.resumeID),
            ["x1", "c1"]
        )
    }

    // MARK: - Record helpers

    private func record(
        agent: SessionAgent,
        cwd: String?,
        title: String,
        aiTitle: String? = nil,
        timestamp: Date?,
        resumeID: String
    ) -> SessionRecord {
        SessionRecord(
            agent: agent,
            cwd: cwd,
            repo: cwd.flatMap { $0.split(separator: "/").last.map(String.init) },
            sessionID: resumeID,
            resumeID: resumeID,
            timestamp: timestamp,
            title: title,
            aiTitle: aiTitle,
            resumeCommand: "cmd \(resumeID)",
            logPath: "/tmp/\(resumeID).jsonl"
        )
    }

    private func withTitle(_ r: SessionRecord, _ title: String) -> SessionRecord {
        SessionRecord(
            agent: r.agent,
            cwd: r.cwd,
            repo: r.repo,
            sessionID: r.sessionID,
            resumeID: r.resumeID,
            timestamp: r.timestamp,
            title: title,
            aiTitle: r.aiTitle,
            resumeCommand: r.resumeCommand,
            logPath: r.logPath
        )
    }
}
