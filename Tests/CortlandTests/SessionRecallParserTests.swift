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
