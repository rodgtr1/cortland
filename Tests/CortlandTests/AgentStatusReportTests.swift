import XCTest
@testable import Cortland
import CortlandIPCCore

/// The agent-status hook's two transports (`AgentStatusReport`), and the contract
/// between the socket transport and the app's IPC parser.
///
/// Background: Claude Code spawns hook processes detached from the pane's
/// controlling terminal, so `/dev/tty` opens with ENXIO and the OSC 666 escape —
/// the only transport this helper had — was written nowhere. Every status report
/// for a hooked Claude pane was silently dropped, which is why a pane thinking for
/// minutes still reported `idle`. The socket transport is the fix; these tests pin
/// the payload it sends to what the app actually accepts.
final class AgentStatusReportTests: XCTestCase {
    private let paneID = UUID()

    // MARK: - Status vocabulary

    func testStatusArgumentAliasesMatchTheDetectorsVocabulary() {
        // The helper's argument aliases and the detector's token aliases have to
        // agree, or a hook config written against one silently reports nothing.
        for (argument, expected) in [
            ("busy", AgentStatusReport.Status.busy), ("working", .busy), ("running", .busy),
            ("ready", .ready), ("waiting", .ready), ("needs-user", .ready),
            ("done", .done), ("finished", .done), ("complete", .done),
            ("idle", .idle), ("clear", .idle), ("reset", .idle),
            ("gated", .gated),
            (" BUSY \n", .busy)
        ] {
            XCTAssertEqual(AgentStatusReport.status(fromArgument: argument), expected,
                           "'\(argument)' must map to \(expected)")
            XCTAssertEqual(AgentStateDetector.state(fromStatus: argument),
                           AgentStateDetector.state(fromStatus: expected.rawValue),
                           "'\(argument)' must reach the detector as the same state")
        }
    }

    func testUnknownStatusArgumentIsRejected() {
        XCTAssertNil(AgentStatusReport.status(fromArgument: "compacting"))
        XCTAssertNil(AgentStatusReport.status(fromArgument: nil))
    }

    // MARK: - Transports

    func testEscapeSequenceIsTheOSC666TermpropTheParserExpects() {
        let sequence = AgentStatusReport.escapeSequence(for: .busy)
        XCTAssertEqual(sequence, "\u{001B}]666;vte.ext.cortland.agent=busy\u{001B}\\")

        // The in-band transport must survive the pane's own OSC extraction.
        var parser = ShellIntegrationParser()
        XCTAssertEqual(parser.consumeAgentStatuses(from: "output\(sequence)more"), ["busy"])
    }

    /// The regression this whole fix exists for: a hook with no controlling
    /// terminal reports over the socket instead, and the app has to understand
    /// what it sends — pane-scoped, in the hooks' own status vocabulary.
    func testSocketFallbackCommandParsesIntoAPaneScopedAgentStatusCommand() throws {
        for (status, expected) in [
            (AgentStatusReport.Status.busy, AgentState.working),
            (.ready, .ready),
            (.done, .done),
            (.idle, .idle),
            // Reported instead of `ready` when a machine reviewer is answering
            // the approval request: the pane keeps working.
            (.gated, .working)
        ] {
            let payload = AgentStatusReport.ipcCommand(status: status, paneID: paneID.uuidString)
            XCTAssertEqual(payload["action"] as? String, "agent_status")

            let command = try decodeCommand(payload)
            guard case let .agentStatus(parsedPaneID, parsedStatus) = IPCCommandType.from(command) else {
                return XCTFail("\(status) must parse as a pane-scoped agent_status command")
            }
            XCTAssertEqual(parsedPaneID, paneID)
            // The token travels unmapped so the detector can see what the state
            // alone cannot say; it has to reach the pane as the right state.
            XCTAssertEqual(parsedStatus, status.rawValue)
            XCTAssertEqual(AgentStateDetector.state(fromStatus: parsedStatus), expected)
        }
    }

    func testAgentStatusCommandRequiresAPaneAndAKnownStatus() throws {
        // No pane: the report has nowhere to land. The legacy `agent_busy` verbs
        // guess the active tab; this one must not.
        let unaddressed = try decodeCommand(["action": "agent_status", "status": "busy"])
        XCTAssertNil(IPCCommandType.from(unaddressed))

        let unknownStatus = try decodeCommand(
            ["action": "agent_status", "pane_id": paneID.uuidString, "status": "compacting"])
        XCTAssertNil(IPCCommandType.from(unknownStatus))
    }

    // MARK: - Machine-reviewed approval requests

    /// Codex fires PermissionRequest for every command needing approval, and
    /// under `approvals_reviewer=auto_review` the reviewer answers it — the human
    /// never types. Reporting `ready` there parked the pane on "Needs input" with
    /// nothing to flip it back, because the keystroke that normally does never
    /// happens.
    func testReadyUnderAMachineReviewerIsReportedAsGated() {
        XCTAssertEqual(
            AgentStatusReport.effectiveStatus(
                requested: .ready,
                environment: [AgentStatusReport.activeApprovalReviewerEnvVar: "auto_review"]),
            .gated)
    }

    func testReadyStaysReadyWheneverTheHumanMayBeAnswering() {
        // Unset is the case that must not change: an agent Cortland did not
        // launch, or a caller who chose their own approval flags.
        for environment in [
            [:],
            [AgentStatusReport.activeApprovalReviewerEnvVar: "user"],
            [AgentStatusReport.activeApprovalReviewerEnvVar: ""],
            [AgentStatusReport.activeApprovalReviewerEnvVar: "AUTO_REVIEW"],
            [AgentStatusReport.activeApprovalReviewerEnvVar: "auto_review_but_not_really"],
            ["CORTLAND_PANE_ID": "auto_review"]
        ] as [[String: String]] {
            XCTAssertEqual(
                AgentStatusReport.effectiveStatus(requested: .ready, environment: environment),
                .ready, "\(environment) must leave a ready alone")
        }
    }

    func testOnlyReadyIsEverDowngraded() {
        // Who reviews approvals says nothing about whether the agent is working,
        // finished, or gone.
        let autoReview = [AgentStatusReport.activeApprovalReviewerEnvVar: "auto_review"]
        for status in [AgentStatusReport.Status.busy, .done, .idle, .gated] {
            XCTAssertEqual(
                AgentStatusReport.effectiveStatus(requested: status, environment: autoReview),
                status, "\(status) must pass through a machine-reviewed session")
        }
    }

    // MARK: - Notification idle reminder

    func testIdleReminderIsSuppressedButRealPermissionRequestsAreNot() {
        // Claude's Notification hook fires for both; only the reminder must be
        // dropped, or a finished agent flaps back to "needs input" 60s later.
        XCTAssertTrue(AgentStatusReport.isIdleReminder(
            status: .ready, hookMessage: "Claude is waiting for your input"))
        XCTAssertFalse(AgentStatusReport.isIdleReminder(
            status: .ready, hookMessage: "Claude needs your permission to use Bash"))
        XCTAssertFalse(AgentStatusReport.isIdleReminder(status: .ready, hookMessage: nil))
        // The suppression is scoped to `ready`; nothing else consults the message.
        XCTAssertFalse(AgentStatusReport.isIdleReminder(
            status: .done, hookMessage: "Claude is waiting for your input"))
    }

    private func decodeCommand(_ payload: [String: Any]) throws -> IPCCommand {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(IPCCommand.self, from: data)
    }
}
