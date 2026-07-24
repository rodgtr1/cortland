import XCTest
import TOMLKit
@testable import Cortland
import CortlandIPCCore

@MainActor
final class ApprovalConfigTests: XCTestCase {
    /// Who a directly launched worker's status hooks are told is answering its
    /// approval requests. Only `-c approvals_reviewer=auto_review` puts a machine
    /// in charge; nil means Cortland did not choose and must not name anyone.
    func testDirectWorkerReviewerStampFollowsTheInjectedFlags() {
        func reviewer(_ command: [String], mode: String) -> String? {
            TerminalViewController.codexApprovalReviewer(
                command: command,
                flags: AgentIntegrationInstaller.codexApprovalFlags(forApprovalMode: mode)
            )
        }

        XCTAssertEqual(reviewer(["codex", "exec", "prompt"], mode: "review"), "auto_review")
        XCTAssertEqual(reviewer(["codex"], mode: "ask"), "user")
        XCTAssertEqual(reviewer(["codex"], mode: "auto"), "user")
        // Bypass asks no one at all, so the human is the truthful answer: nothing
        // may be treated as machine-reviewed that isn't.
        XCTAssertEqual(reviewer(["codex"], mode: "bypass"), "user")
        // An absolute path is still codex.
        XCTAssertEqual(reviewer(["/opt/homebrew/bin/codex"], mode: "review"), "auto_review")

        // The caller's own approval flags win the injection, so the reviewer is
        // theirs to know, not Cortland's to claim.
        XCTAssertNil(reviewer(["codex", "-a=never"], mode: "review"))
        XCTAssertNil(reviewer(["codex", "--ask-for-approval", "never"], mode: "review"))
        // A caller naming their own reviewer is the same class of override: were
        // Cortland to inject a conflicting one anyway, the stamp would name
        // whichever value lost inside codex, and a pane stamped `auto_review`
        // whose reviewer is really the human hides the prompts it must show.
        XCTAssertNil(reviewer(["codex", "-c", "approvals_reviewer=user"], mode: "review"))
        XCTAssertNil(reviewer(["codex", "--config", "approvals_reviewer=user"], mode: "review"))
        XCTAssertNil(reviewer(["codex", "-c=approvals_reviewer=auto_review"], mode: "ask"))
        XCTAssertNil(reviewer(["codex", "--config=approvals_reviewer=user"], mode: "review"))
        // Another `-c` is not an approval choice, so the injection still happens.
        XCTAssertEqual(reviewer(["codex", "-c", "model=gpt-5"], mode: "review"), "auto_review")
        // Prompt text that merely mentions the setting is a prompt, not config:
        // Codex reads it as the value of no flag, so Cortland still chooses.
        XCTAssertEqual(
            reviewer(["codex", "exec", "approvals_reviewer=auto_review behaves incorrectly"], mode: "review"),
            "auto_review"
        )
        // Not a codex launch, and not a launch at all.
        XCTAssertNil(reviewer(["claude", "--model", "opus"], mode: "review"))
        XCTAssertNil(reviewer([], mode: "review"))
        // Nothing injected: nothing to report.
        XCTAssertNil(TerminalViewController.codexApprovalReviewer(command: ["codex"], flags: []))
    }

    private func approval(from toml: String) throws -> ApprovalConfig {
        try TOMLDecoder().decode(ApprovalConfig.self, from: try TOMLTable(string: toml))
    }

    func testAutoModeApproves() throws {
        XCTAssertTrue(try approval(from: "mode = \"auto\"").autoApprove)
    }

    func testAskModeDoesNotAutoApprove() throws {
        XCTAssertFalse(try approval(from: "mode = \"ask\"").autoApprove)
    }

    func testModeIsCaseInsensitive() throws {
        XCTAssertTrue(try approval(from: "mode = \"AUTO\"").autoApprove)
    }

    func testReviewAndLegacyClaudeAutoBothNormalizeToReviewedMode() throws {
        XCTAssertEqual(ApprovalMode(configValue: "review"), .review)
        XCTAssertEqual(ApprovalMode(configValue: "claude-auto"), .review)
        XCTAssertTrue(try approval(from: "mode = \"review\"").autoApprove)
        XCTAssertTrue(try approval(from: "mode = \"claude-auto\"").autoApprove)
    }

    func testUnknownModeFailsClosedToAsk() {
        XCTAssertEqual(ApprovalMode(configValue: "surprise-me"), .ask)
    }

    func testMissingModeDefaultsToAsk() throws {
        // A config written before the key existed must still parse, and must not
        // silently start auto-approving edits.
        XCTAssertFalse(try approval(from: "").autoApprove)
    }

    func testDefaultConfigDoesNotAutoApprove() {
        XCTAssertEqual(Config().approval?.autoApprove, false)
    }

    func testGlobListsParse() throws {
        let config = try approval(from: """
        mode = "ask"
        auto_allow = ["Sources/**", "docs/**"]
        always_ask = [".env"]
        """)
        XCTAssertEqual(config.autoAllow, ["Sources/**", "docs/**"])
        XCTAssertEqual(config.alwaysAsk, [".env"])
    }

    func testMissingGlobListsDefaultToEmpty() throws {
        // Configs written before these keys existed must still parse.
        let config = try approval(from: "mode = \"ask\"")
        XCTAssertTrue(config.autoAllow.isEmpty)
        XCTAssertTrue(config.alwaysAsk.isEmpty)
    }

    func testLiveApprovalModeSnapshotIsDataOnlyAndAtomic() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cortland-approval-mode-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("mode")
        defer { try? FileManager.default.removeItem(at: directory) }

        let original = AgentApprovalState.mode
        defer { AgentApprovalState.mode = original }
        AgentApprovalState.mode = .review
        try AgentApprovalState.persistMode(to: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "review\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
