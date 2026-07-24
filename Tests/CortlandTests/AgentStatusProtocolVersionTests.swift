import XCTest
@testable import Cortland
import CortlandIPCCore

/// The version handshake on the `agent_status` socket transport.
///
/// A helper left behind in `~/.local/bin` by an app upgrade fails silently by
/// design — hooks must never disrupt the agent — so the app had no way to tell a
/// current helper from one that predates the contract it is speaking. The report
/// now carries `protocol_version`, and a report that doesn't is by definition
/// from a helper older than the handshake itself.
///
/// The invariant that matters most: this is *diagnostics*, never a gate. Every
/// version — old, absent, or from the future — is still accepted and applied.
final class AgentStatusProtocolVersionTests: XCTestCase {
    private let paneID = UUID()

    // MARK: - The staleness rule

    func testMissingVersionMeansV0AndCountsAsStale() {
        // Every helper shipped before this handshake sends no version field.
        XCTAssertEqual(AgentStatusReport.legacyProtocolVersion, 0)
        XCTAssertTrue(AgentStatusReport.isStale(protocolVersion: nil))
        XCTAssertTrue(AgentStatusReport.isStale(protocolVersion: 0))
    }

    func testCurrentVersionIsNotStale() {
        XCTAssertFalse(AgentStatusReport.isStale(protocolVersion: AgentStatusReport.protocolVersion))
    }

    /// v2 added `gated` to the status vocabulary, which is exactly the kind of
    /// change the version exists to make visible: a v1 helper reports a
    /// machine-answered approval request as `ready`, and the pane it parks on
    /// "Needs input" is the bug the user would otherwise be left to explain.
    func testV1PredatesTheGatedVocabularyAndIsStale() {
        XCTAssertEqual(AgentStatusReport.protocolVersion, 2)
        XCTAssertTrue(AgentStatusReport.isStale(protocolVersion: 1))
        XCTAssertFalse(AgentStatusReport.isStale(protocolVersion: 2))
    }

    func testFutureVersionIsNotStale() {
        // A helper installed by a *newer* Cortland isn't behind — this app is.
        // Warning about it would be backwards, and rejecting it would be worse.
        XCTAssertFalse(AgentStatusReport.isStale(protocolVersion: AgentStatusReport.protocolVersion + 1))
        XCTAssertFalse(AgentStatusReport.isStale(protocolVersion: 999))
    }

    // MARK: - What the helper sends

    func testHelperDeclaresTheCurrentVersionInItsPayload() throws {
        let payload = AgentStatusReport.ipcCommand(status: .busy, paneID: paneID.uuidString)
        XCTAssertEqual(payload[AgentStatusReport.protocolVersionKey] as? Int,
                       AgentStatusReport.protocolVersion)

        // And the app reads it back as current, so a freshly built helper never
        // warns about itself.
        let command = try decodeCommand(payload)
        XCTAssertEqual(command.protocolVersion, AgentStatusReport.protocolVersion)
        XCTAssertNil(IPCCommandType.staleAgentStatusReport(command))
    }

    // MARK: - What the app does with it

    func testStaleReportIsFlaggedWithItsPaneAndVersion() throws {
        // The pre-handshake payload, exactly as an old ~/.local/bin helper sends it.
        let command = try decodeCommand([
            "action": "agent_status", "pane_id": paneID.uuidString, "status": "busy"
        ])

        let stale = try XCTUnwrap(IPCCommandType.staleAgentStatusReport(command))
        XCTAssertEqual(stale.paneID, paneID)
        XCTAssertEqual(stale.protocolVersion, 0, "A report with no version is a v0 helper")
    }

    func testAnOlderButDeclaredVersionIsAlsoFlagged() throws {
        // Once v2 exists, a v1 helper is stale the same way a v0 one is today.
        let command = try decodeCommand([
            "action": "agent_status", "pane_id": paneID.uuidString, "status": "done",
            AgentStatusReport.protocolVersionKey: AgentStatusReport.protocolVersion - 1
        ])
        XCTAssertEqual(IPCCommandType.staleAgentStatusReport(command)?.protocolVersion,
                       AgentStatusReport.protocolVersion - 1)
    }

    func testEveryVersionStillParsesIntoAnAgentStatusCommand() throws {
        // The report is honored whatever version it declares: an old helper
        // saying "busy" is still right about "busy", and a future one must never
        // be rejected by an app that simply doesn't know the number yet.
        for version in [nil, 0, AgentStatusReport.protocolVersion, 99] as [Int?] {
            var payload: [String: Any] = [
                "action": "agent_status", "pane_id": paneID.uuidString, "status": "busy"
            ]
            if let version { payload[AgentStatusReport.protocolVersionKey] = version }

            let command = try decodeCommand(payload)
            guard case let .agentStatus(parsedPaneID, parsedStatus) = IPCCommandType.from(command) else {
                return XCTFail("v\(version.map(String.init) ?? "none") must still parse as agent_status")
            }
            XCTAssertEqual(parsedPaneID, paneID)
            XCTAssertEqual(AgentStateDetector.state(fromStatus: parsedStatus), .working)
        }
    }

    func testFutureVersionParsesAndRaisesNoWarning() throws {
        let command = try decodeCommand([
            "action": "agent_status", "pane_id": paneID.uuidString, "status": "ready",
            AgentStatusReport.protocolVersionKey: AgentStatusReport.protocolVersion + 1
        ])
        XCTAssertNotNil(IPCCommandType.from(command))
        XCTAssertNil(IPCCommandType.staleAgentStatusReport(command))
    }

    func testAMalformedStaleReportRaisesNoWarning() throws {
        // No pane to warn in, and nothing to warn about on other verbs — the
        // staleness check must not fire on commands it has no business reading.
        let unaddressed = try decodeCommand(["action": "agent_status", "status": "busy"])
        XCTAssertNil(IPCCommandType.staleAgentStatusReport(unaddressed))

        let otherVerb = try decodeCommand(["action": "pane_list"])
        XCTAssertNil(IPCCommandType.staleAgentStatusReport(otherVerb))
    }

    private func decodeCommand(_ payload: [String: Any]) throws -> IPCCommand {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(IPCCommand.self, from: data)
    }
}
