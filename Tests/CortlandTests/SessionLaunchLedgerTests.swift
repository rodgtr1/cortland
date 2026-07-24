import XCTest
import CortlandProInterface
@testable import Cortland

/// Covers the Session Recall launch ledger: authoritative launch recording
/// (`SessionLaunchLedger.recordSync` / `entries`), the growth bound, and the
/// nil-cwd backfill (`SessionLaunchLedger.backfillCWDs`).
///
/// All pure/on-disk against a temp file — the git branch lookup is stubbed out
/// so no real `git` process is spawned.
final class SessionLaunchLedgerTests: XCTestCase {
    private let fm = FileManager.default

    private func tempURL() -> URL {
        fm.temporaryDirectory
            .appendingPathComponent("SLLedger-\(UUID().uuidString)")
            .appendingPathComponent("session-launch-ledger.jsonl")
    }

    private func record(
        agent: SessionAgent,
        cwd: String?,
        timestamp: Date?,
        resumeID: String = "r1",
        logPath: String = "/tmp/r1.jsonl"
    ) -> SessionRecord {
        SessionRecord(
            agent: agent,
            cwd: cwd,
            repo: cwd.map { ($0 as NSString).lastPathComponent },
            sessionID: resumeID,
            resumeID: resumeID,
            timestamp: timestamp,
            title: "t",
            aiTitle: nil,
            resumeCommand: cwd == nil ? "\(agent == .claude ? "claude --resume" : "codex resume") \(resumeID)" : "cmd",
            logPath: logPath
        )
    }

    // MARK: - record / recordSync

    func testRecordSyncWritesOneEntryForClaudeArgv() throws {
        let url = tempURL()
        defer { try? fm.removeItem(at: url.deletingLastPathComponent()) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let entry = SessionLaunchLedger.recordSync(
            command: ["claude", "--resume", "abc"],
            cwd: "/Users/travis/Repos/x",
            at: url,
            now: now,
            resolveBranch: { _ in nil }
        )

        XCTAssertEqual(entry?.agent, "claude")
        XCTAssertEqual(entry?.cwd, "/Users/travis/Repos/x")
        XCTAssertNil(entry?.branch)
        XCTAssertEqual(entry?.timestamp, now)

        let entries = SessionLaunchLedger.entries(at: url, fileManager: fm)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.agent, "claude")
        XCTAssertEqual(entries.first?.cwd, "/Users/travis/Repos/x")
        XCTAssertEqual(entries.first?.timestamp, now)
    }

    func testRecordSyncResolvesAgentBasenameFromAbsolutePath() throws {
        let url = tempURL()
        defer { try? fm.removeItem(at: url.deletingLastPathComponent()) }
        let entry = SessionLaunchLedger.recordSync(
            command: ["/opt/homebrew/bin/codex", "resume", "id"],
            cwd: "/tmp",
            at: url,
            resolveBranch: { _ in "main" }
        )
        XCTAssertEqual(entry?.agent, "codex")
        XCTAssertEqual(entry?.branch, "main")
    }

    func testRecordSyncIgnoresNonAgentCommand() throws {
        let url = tempURL()
        defer { try? fm.removeItem(at: url.deletingLastPathComponent()) }
        let entry = SessionLaunchLedger.recordSync(
            command: ["htop"],
            cwd: "/tmp",
            at: url,
            resolveBranch: { _ in nil }
        )
        XCTAssertNil(entry, "non-agent argv produces no entry")
        XCTAssertEqual(SessionLaunchLedger.entries(at: url, fileManager: fm), [], "and nothing is written")
    }

    func testRecordSyncIgnoresEmptyCommand() {
        let url = tempURL()
        defer { try? fm.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertNil(SessionLaunchLedger.recordSync(command: [], cwd: "/tmp", at: url, resolveBranch: { _ in nil }))
    }

    func testMultipleRecordsAppend() throws {
        let url = tempURL()
        defer { try? fm.removeItem(at: url.deletingLastPathComponent()) }
        for i in 0..<3 {
            SessionLaunchLedger.recordSync(
                command: ["claude"],
                cwd: "/repo/\(i)",
                at: url,
                now: Date(timeIntervalSince1970: TimeInterval(i)),
                resolveBranch: { _ in nil }
            )
        }
        let entries = SessionLaunchLedger.entries(at: url, fileManager: fm)
        XCTAssertEqual(entries.map(\.cwd), ["/repo/0", "/repo/1", "/repo/2"])
    }

    // MARK: - entries

    func testEntriesSkipsMalformedLines() throws {
        let url = tempURL()
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: url.deletingLastPathComponent()) }

        // A valid line, a garbage line, a blank line, another valid line.
        SessionLaunchLedger.recordSync(command: ["claude"], cwd: "/a", at: url,
                                       now: Date(timeIntervalSince1970: 1), resolveBranch: { _ in nil })
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n\n".utf8))
        try handle.close()
        SessionLaunchLedger.recordSync(command: ["codex"], cwd: "/b", at: url,
                                       now: Date(timeIntervalSince1970: 2), resolveBranch: { _ in nil })

        let entries = SessionLaunchLedger.entries(at: url, fileManager: fm)
        XCTAssertEqual(entries.map(\.cwd), ["/a", "/b"], "malformed and blank lines are skipped")
    }

    func testEntriesForMissingFileIsEmpty() {
        let url = tempURL()
        XCTAssertEqual(SessionLaunchLedger.entries(at: url, fileManager: fm), [])
    }

    // MARK: - Growth bound

    func testEntriesTrimsWhenOverMax() throws {
        let url = tempURL()
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: url.deletingLastPathComponent()) }

        // Write maxEntries + 5 lines directly (fast, no per-line append cost).
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let total = SessionLaunchLedger.maxEntries + 5
        var blob = Data()
        for i in 0..<total {
            let entry = SessionLaunchLedgerEntry(
                agent: "claude", cwd: "/repo/\(i)", branch: nil,
                timestamp: Date(timeIntervalSince1970: TimeInterval(i))
            )
            blob.append(try encoder.encode(entry))
            blob.append(0x0A)
        }
        try blob.write(to: url)

        let entries = SessionLaunchLedger.entries(at: url, fileManager: fm)
        XCTAssertEqual(entries.count, SessionLaunchLedger.trimTo, "trimmed to the newest trimTo")
        // Newest kept: the last `trimTo` cwds, in order.
        XCTAssertEqual(entries.first?.cwd, "/repo/\(total - SessionLaunchLedger.trimTo)")
        XCTAssertEqual(entries.last?.cwd, "/repo/\(total - 1)")

        // The file itself was rewritten to the trimmed set, so a second read is
        // stable at trimTo (no re-trim needed).
        let again = SessionLaunchLedger.entries(at: url, fileManager: fm)
        XCTAssertEqual(again.count, SessionLaunchLedger.trimTo)
    }

    // MARK: - Backfill

    func testBackfillFillsNilCwdFromSingleInWindowEntry() {
        let ts = Date(timeIntervalSince1970: 1_000)
        let rec = record(agent: .claude, cwd: nil, timestamp: ts, resumeID: "abc")
        let entry = SessionLaunchLedgerEntry(
            agent: "claude", cwd: "/Users/travis/Repos/proj", branch: "main",
            timestamp: ts.addingTimeInterval(30) // within ±180s
        )

        let out = SessionLaunchLedger.backfillCWDs([rec], using: [entry])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].cwd, "/Users/travis/Repos/proj")
        XCTAssertEqual(out[0].repo, "proj")
        XCTAssertEqual(out[0].resumeCommand, "cd /Users/travis/Repos/proj && claude --resume abc",
                       "the cd prefix is rebuilt")
    }

    func testBackfillLeavesNilWhenTwoCandidatesInWindow() {
        let ts = Date(timeIntervalSince1970: 1_000)
        let rec = record(agent: .claude, cwd: nil, timestamp: ts)
        let a = SessionLaunchLedgerEntry(agent: "claude", cwd: "/a", branch: nil, timestamp: ts.addingTimeInterval(10))
        let b = SessionLaunchLedgerEntry(agent: "claude", cwd: "/b", branch: nil, timestamp: ts.addingTimeInterval(-10))

        let out = SessionLaunchLedger.backfillCWDs([rec], using: [a, b])
        XCTAssertNil(out[0].cwd, "ambiguous: two candidates in window → left nil")
    }

    func testBackfillLeavesNilWhenMatchOutOfWindow() {
        let ts = Date(timeIntervalSince1970: 1_000)
        let rec = record(agent: .claude, cwd: nil, timestamp: ts)
        let entry = SessionLaunchLedgerEntry(agent: "claude", cwd: "/a", branch: nil,
                                             timestamp: ts.addingTimeInterval(200)) // > 180s
        let out = SessionLaunchLedger.backfillCWDs([rec], using: [entry])
        XCTAssertNil(out[0].cwd, "out-of-window entry does not match")
    }

    func testBackfillIgnoresDifferentAgent() {
        let ts = Date(timeIntervalSince1970: 1_000)
        let rec = record(agent: .claude, cwd: nil, timestamp: ts)
        let entry = SessionLaunchLedgerEntry(agent: "codex", cwd: "/a", branch: nil,
                                             timestamp: ts.addingTimeInterval(5))
        let out = SessionLaunchLedger.backfillCWDs([rec], using: [entry])
        XCTAssertNil(out[0].cwd, "an entry for a different agent never matches")
    }

    func testBackfillLeavesRecordsWithKnownCwdUntouched() {
        let ts = Date(timeIntervalSince1970: 1_000)
        let rec = record(agent: .claude, cwd: "/existing", timestamp: ts)
        let entry = SessionLaunchLedgerEntry(agent: "claude", cwd: "/other", branch: nil,
                                             timestamp: ts.addingTimeInterval(5))
        let out = SessionLaunchLedger.backfillCWDs([rec], using: [entry])
        XCTAssertEqual(out[0].cwd, "/existing", "a record that already has a cwd is never overwritten")
        XCTAssertEqual(out[0].resumeCommand, "cmd")
    }

    func testBackfillLeavesNilWhenRecordHasNoTimestamp() {
        let rec = record(agent: .claude, cwd: nil, timestamp: nil)
        let entry = SessionLaunchLedgerEntry(agent: "claude", cwd: "/a", branch: nil,
                                             timestamp: Date(timeIntervalSince1970: 1_000))
        let out = SessionLaunchLedger.backfillCWDs([rec], using: [entry])
        XCTAssertNil(out[0].cwd, "without a record timestamp there is no window to match in")
    }

    func testBackfillWithEmptyLedgerIsIdentity() {
        let rec = record(agent: .claude, cwd: nil, timestamp: Date(timeIntervalSince1970: 1))
        let out = SessionLaunchLedger.backfillCWDs([rec], using: [])
        XCTAssertNil(out[0].cwd)
    }
}
