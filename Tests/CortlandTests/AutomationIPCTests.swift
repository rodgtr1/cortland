import XCTest
@testable import Cortland
import CortlandTelemetryCore

@MainActor
final class AutomationIPCTests: XCTestCase {
    func testPaneSplitCommandDecodesStructuredArguments() throws {
        let paneID = UUID()
        let json = """
        {
          "action": "pane_split",
          "pane_id": "\(paneID.uuidString)",
          "direction": "down",
          "cwd": "/tmp",
          "focus": false,
          "command": ["claude", "-p", "review tests"]
        }
        """
        let command = try JSONDecoder().decode(IPCCommand.self, from: Data(json.utf8))

        guard case let .paneSplit(decodedID, direction, cwd, argv, focus, worktree) = IPCCommandType.from(command) else {
            return XCTFail("Expected paneSplit")
        }
        XCTAssertEqual(decodedID, paneID)
        if case .vertical = direction {} else { XCTFail("Expected vertical split") }
        XCTAssertEqual(cwd, "/tmp")
        XCTAssertEqual(argv ?? [], ["claude", "-p", "review tests"])
        XCTAssertFalse(focus)
        XCTAssertNil(worktree)
    }

    func testPaneSplitParsesWorktreeBranch() throws {
        let json = """
        {"action":"pane_split","pane_id":"\(UUID().uuidString)","direction":"right","worktree":"feature/login"}
        """
        let command = try JSONDecoder().decode(IPCCommand.self, from: Data(json.utf8))
        guard case let .paneSplit(_, _, _, _, _, worktree) = IPCCommandType.from(command) else {
            return XCTFail("Expected paneSplit")
        }
        XCTAssertEqual(worktree, "feature/login")
    }

    func testPaneSplitRejectsOptionInjectingBranch() throws {
        // A leading dash would be parsed as a git option, and whitespace is
        // never a valid ref — both must be rejected before git sees them.
        for bad in ["--force", "-b", "has space", "\(String(repeating: "x", count: 256))"] {
            let json = """
            {"action":"pane_split","pane_id":"\(UUID().uuidString)","direction":"right","worktree":"\(bad)"}
            """
            let command = try JSONDecoder().decode(IPCCommand.self, from: Data(json.utf8))
            XCTAssertNil(IPCCommandType.from(command), "Expected \(bad) to be rejected")
        }
    }

    func testPaneRunParsesAsItsOwnCommand() throws {
        let paneID = UUID()
        let json = """
        {"action":"pane_run","pane_id":"\(paneID.uuidString)","text":"swift test"}
        """
        let command = try JSONDecoder().decode(IPCCommand.self, from: Data(json.utf8))
        guard case let .paneRun(decodedID, text) = IPCCommandType.from(command) else {
            return XCTFail("Expected paneRun")
        }
        XCTAssertEqual(decodedID, paneID)
        XCTAssertEqual(text, "swift test",
                       "text must arrive without a trailing return; the server sends Enter separately")
    }

    func testWorktreeRemoveParsesBranchCwdAndForce() throws {
        let json = """
        {"action":"worktree_remove","worktree":"feature/login","cwd":"/tmp","force":true}
        """
        let command = try JSONDecoder().decode(IPCCommand.self, from: Data(json.utf8))
        guard case let .worktreeRemove(branch, cwd, force) = IPCCommandType.from(command) else {
            return XCTFail("Expected worktreeRemove")
        }
        XCTAssertEqual(branch, "feature/login")
        XCTAssertEqual(cwd, "/tmp")
        XCTAssertTrue(force)
    }

    func testWorktreeRemoveDefaultsForceFalseAndNilCwd() throws {
        let json = #"{"action":"worktree_remove","worktree":"feature/x"}"#
        let command = try JSONDecoder().decode(IPCCommand.self, from: Data(json.utf8))
        guard case let .worktreeRemove(branch, cwd, force) = IPCCommandType.from(command) else {
            return XCTFail("Expected worktreeRemove")
        }
        XCTAssertEqual(branch, "feature/x")
        XCTAssertNil(cwd)
        XCTAssertFalse(force)
    }

    func testWorktreeRemoveRejectsOptionInjectingBranch() throws {
        // Same ref-name guard as pane split --worktree.
        for bad in ["--force", "-b", "has space"] {
            let json = """
            {"action":"worktree_remove","worktree":"\(bad)"}
            """
            let command = try JSONDecoder().decode(IPCCommand.self, from: Data(json.utf8))
            XCTAssertNil(IPCCommandType.from(command), "Expected \(bad) to be rejected")
        }
    }

    func testWorktreeRemoveRejectsMissingBranchAndInvalidCwd() throws {
        let missingBranch = #"{"action":"worktree_remove"}"#
        XCTAssertNil(IPCCommandType.from(try JSONDecoder().decode(IPCCommand.self, from: Data(missingBranch.utf8))))

        let badCwd = #"{"action":"worktree_remove","worktree":"x","cwd":"/no/such/dir/zzz"}"#
        XCTAssertNil(IPCCommandType.from(try JSONDecoder().decode(IPCCommand.self, from: Data(badCwd.utf8))))
    }

    func testWorktreePruneParsesWithAndWithoutCwd() throws {
        let withCwd = #"{"action":"worktree_prune","cwd":"/tmp"}"#
        guard case let .worktreePrune(cwd) = IPCCommandType.from(try JSONDecoder().decode(IPCCommand.self, from: Data(withCwd.utf8))) else {
            return XCTFail("Expected worktreePrune")
        }
        XCTAssertEqual(cwd, "/tmp")

        let noCwd = #"{"action":"worktree_prune"}"#
        guard case let .worktreePrune(nilCwd) = IPCCommandType.from(try JSONDecoder().decode(IPCCommand.self, from: Data(noCwd.utf8))) else {
            return XCTFail("Expected worktreePrune")
        }
        XCTAssertNil(nilCwd)
    }

    func testShowDiffCarriesOptionalPaneID() throws {
        let paneID = UUID()
        let withPane = try JSONDecoder().decode(IPCCommand.self, from: JSONSerialization.data(
            withJSONObject: ["action": "show_diff", "path": "/tmp/x.swift", "old": "a", "new": "b", "pane_id": paneID.uuidString]))
        guard case let .showDiff(p, _, old, new) = IPCCommandType.from(withPane) else {
            return XCTFail("Expected showDiff")
        }
        XCTAssertEqual(p, paneID)
        XCTAssertEqual(old, "a")
        XCTAssertEqual(new, "b")

        // Absent pane_id parses to an unscoped (nil) pane.
        let noPane = try JSONDecoder().decode(IPCCommand.self, from: JSONSerialization.data(
            withJSONObject: ["action": "show_diff", "path": "/tmp/x.swift", "old": "a", "new": "b"]))
        guard case let .showDiff(nilPane, _, _, _) = IPCCommandType.from(noPane) else {
            return XCTFail("Expected showDiff")
        }
        XCTAssertNil(nilPane)
    }

    func testReportTelemetryDecodesPaneAndUsage() throws {
        let usage = TranscriptUsage(
            model: "claude-opus-4-8", inputTokens: 1000, outputTokens: 500,
            cacheReadTokens: 200, cacheCreation5mTokens: 50, assistantResponses: 3, userPrompts: 2
        )
        let blob = String(data: try JSONEncoder().encode(usage), encoding: .utf8)!
        let paneID = UUID()
        let cmd = try JSONDecoder().decode(IPCCommand.self, from: JSONSerialization.data(
            withJSONObject: ["action": "report_telemetry", "pane_id": paneID.uuidString, "telemetry": blob]))

        guard case let .reportTelemetry(decodedPane, decodedUsage) = IPCCommandType.from(cmd) else {
            return XCTFail("Expected reportTelemetry")
        }
        XCTAssertEqual(decodedPane, paneID)
        XCTAssertEqual(decodedUsage, usage)
    }

    func testReportTelemetryRejectsBadPaneOrMissingBlob() throws {
        let blob = String(data: try JSONEncoder().encode(TranscriptUsage()), encoding: .utf8)!
        let badPane = try JSONDecoder().decode(IPCCommand.self, from: JSONSerialization.data(
            withJSONObject: ["action": "report_telemetry", "pane_id": "not-a-uuid", "telemetry": blob]))
        XCTAssertNil(IPCCommandType.from(badPane))

        let noBlob = try JSONDecoder().decode(IPCCommand.self, from: JSONSerialization.data(
            withJSONObject: ["action": "report_telemetry", "pane_id": UUID().uuidString]))
        XCTAssertNil(IPCCommandType.from(noBlob))
    }

    func testResetTelemetryDecodesPane() throws {
        let paneID = UUID()
        let cmd = try JSONDecoder().decode(IPCCommand.self, from: JSONSerialization.data(
            withJSONObject: ["action": "reset_telemetry", "pane_id": paneID.uuidString]))
        guard case let .resetTelemetry(decodedPane) = IPCCommandType.from(cmd) else {
            return XCTFail("Expected resetTelemetry")
        }
        XCTAssertEqual(decodedPane, paneID)

        let badPane = try JSONDecoder().decode(IPCCommand.self, from: JSONSerialization.data(
            withJSONObject: ["action": "reset_telemetry", "pane_id": "not-a-uuid"]))
        XCTAssertNil(IPCCommandType.from(badPane))
    }

    func testPaneReadRejectsUnboundedLineCount() throws {
        let json = """
        {"action":"pane_read","pane_id":"\(UUID().uuidString)","lines":10001}
        """
        let command = try JSONDecoder().decode(IPCCommand.self, from: Data(json.utf8))
        XCTAssertNil(IPCCommandType.from(command))
    }

    func testPaneReadParsesJSONFormat() throws {
        let paneID = UUID()
        let json = """
        {"action":"pane_read","pane_id":"\(paneID.uuidString)","format":"json","lines":20}
        """
        let command = try JSONDecoder().decode(IPCCommand.self, from: Data(json.utf8))
        guard case let .paneRead(decodedID, _, lines, isJSON, since) = IPCCommandType.from(command) else {
            return XCTFail("Expected paneRead")
        }
        XCTAssertEqual(decodedID, paneID)
        XCTAssertEqual(lines, 20)
        XCTAssertTrue(isJSON)
        XCTAssertNil(since)
    }

    func testPaneReadDefaultsToTextAndRejectsUnknownFormat() throws {
        let paneID = UUID().uuidString
        let textCommand = try JSONDecoder().decode(
            IPCCommand.self, from: Data("""
            {"action":"pane_read","pane_id":"\(paneID)"}
            """.utf8))
        guard case let .paneRead(_, _, _, isJSON, _) = IPCCommandType.from(textCommand) else {
            return XCTFail("Expected paneRead")
        }
        XCTAssertFalse(isJSON)

        let badCommand = try JSONDecoder().decode(
            IPCCommand.self, from: Data("""
            {"action":"pane_read","pane_id":"\(paneID)","format":"xml"}
            """.utf8))
        XCTAssertNil(IPCCommandType.from(badCommand))
    }

    func testPaneReadParsesSinceCursor() throws {
        let paneID = UUID()
        let json = """
        {"action":"pane_read","pane_id":"\(paneID.uuidString)","source":"recent","since":"4321:8192"}
        """
        let command = try JSONDecoder().decode(IPCCommand.self, from: Data(json.utf8))
        guard case let .paneRead(decodedID, source, _, _, since) = IPCCommandType.from(command) else {
            return XCTFail("Expected paneRead")
        }
        XCTAssertEqual(decodedID, paneID)
        XCTAssertEqual(source, "recent")
        XCTAssertEqual(since, "4321:8192")
    }

    func testPaneReadRejectsOverlongSinceCursor() throws {
        let json = """
        {"action":"pane_read","pane_id":"\(UUID().uuidString)","since":"\(String(repeating: "9", count: 129))"}
        """
        let command = try JSONDecoder().decode(IPCCommand.self, from: Data(json.utf8))
        XCTAssertNil(IPCCommandType.from(command))
    }

    func testCommandRecordUsesSnakeCaseJSONKeys() throws {
        let record = IPCCommandRecord(command: "swift build", exitCode: 1, duration: 12.4, output: "error: …")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any]
        )
        XCTAssertEqual(object["command"] as? String, "swift build")
        XCTAssertEqual(object["exit_code"] as? Int, 1)
        XCTAssertEqual(object["duration"] as? Double, 12.4)
        XCTAssertNil(object["exitCode"])
    }

    func testTabAgentStateAggregatesMostUrgentPane() {
        let tab = TabModel()
        let second = PaneModel()
        tab.panes.append(second)

        tab.panes[0].agentState = .done
        second.agentState = .working
        tab.updateAgentStateFromPanes()
        XCTAssertEqual(tab.agentState, .working)

        tab.panes[0].agentState = .ready
        tab.updateAgentStateFromPanes()
        XCTAssertEqual(tab.agentState, .ready)
    }

    func testPaneInfoUsesSnakeCaseJSONKeys() throws {
        let info = IPCPaneInfo(
            paneID: "pane",
            tabID: "tab",
            type: "terminal",
            cwd: "/tmp",
            focused: true,
            agentStatus: "working",
            processID: 42
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(info)) as? [String: Any]
        )
        XCTAssertEqual(object["pane_id"] as? String, "pane")
        XCTAssertEqual(object["agent_status"] as? String, "working")
        XCTAssertEqual(object["process_id"] as? Int, 42)
    }
}
