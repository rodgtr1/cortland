import XCTest
import CortlandProInterface
@testable import Cortland

/// Covers the correctness-critical `SessionRecord.resumeArgv`: the bare ARGV
/// used to launch a resume in a new tab. The verb differs by agent, and it must
/// carry no `cd` prefix (that lives in `resumeCommand`, for clipboard use).
final class SessionRecallResumeArgvTests: XCTestCase {
    private func record(agent: SessionAgent, resumeID: String) -> SessionRecord {
        SessionRecord(
            agent: agent,
            cwd: "/Users/dev/repo",
            repo: "repo",
            sessionID: "session-\(resumeID)",
            resumeID: resumeID,
            timestamp: nil,
            title: "a session",
            aiTitle: nil,
            resumeCommand: "cd /Users/dev/repo && placeholder",
            logPath: "/tmp/log.jsonl"
        )
    }

    func testClaudeResumeArgv() {
        let argv = record(agent: .claude, resumeID: "abc-123").resumeArgv
        XCTAssertEqual(argv, ["claude", "--resume", "abc-123"])
    }

    func testCodexResumeArgv() {
        let argv = record(agent: .codex, resumeID: "def-456").resumeArgv
        XCTAssertEqual(argv, ["codex", "resume", "def-456"])
    }

    func testResumeArgvCarriesNoCdPrefix() {
        // The argv must never contain a shell `cd`; the cwd is supplied out of
        // band via the new tab's working directory.
        let argv = record(agent: .claude, resumeID: "x").resumeArgv
        XCTAssertFalse(argv.contains(where: { $0.contains("cd ") }))
    }
}
