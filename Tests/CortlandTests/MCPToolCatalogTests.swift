import XCTest
@testable import Cortland
import CortlandIPCCore
import CortlandMCPCore

/// Contract tests for the cortland-mcp tool catalog. These are the guard the
/// review flagged as missing: "an MCP schema typo currently ships silently."
/// They pin the four un-typechecked string contracts — tool names, advertised
/// property names vs. what the handler reads, `required` arrays, and the
/// emitted IPC `action` — and cross-check the emitted commands against the
/// server's own `IPCCommandType.from` decoder so an action or enum drift fails
/// loudly here instead of at a live round-trip.
final class MCPToolCatalogTests: XCTestCase {
    // `ipc` is only touched by streaming tools' `execute` (wait_event), which
    // these tests never invoke, so a bare client with no live server is fine.
    private let tools = makeTools(ipc: CortlandIPCClient())

    private func tool(_ name: String) -> Tool {
        guard let t = tools.first(where: { $0.name == name }) else {
            fatalError("no tool named \(name)")
        }
        return t
    }

    /// The action each tool's buildRequest must emit. wait_event is excluded —
    /// it runs through `execute` and its action ("events") is handled by the
    /// server before `IPCCommandType.from`, not by it.
    private let expectedAction: [String: String] = [
        "cortland_ping": "ping",
        "cortland_pane_list": "pane_list",
        "cortland_agent_list": "agent_list",
        "cortland_pane_current": "pane_current",
        "cortland_new_tab": "new_tab",
        "cortland_pane_split": "pane_split",
        "cortland_pane_focus": "pane_focus",
        "cortland_pane_close": "pane_close",
        "cortland_pane_send_text": "pane_send_text",
        "cortland_pane_run": "pane_run",
        "cortland_pane_send_key": "pane_send_key",
        "cortland_pane_read": "pane_read",
        "cortland_wait_agent_status": "wait_agent_status",
        "cortland_wait_output": "wait_output",
        "cortland_worktree_list": "worktree_list",
        "cortland_worktree_remove": "worktree_remove",
        "cortland_worktree_prune": "worktree_prune",
    ]

    /// Minimal valid arguments per tool that the server's decoder will accept.
    private func validArgs(for name: String) -> [String: Any] {
        let paneID = UUID().uuidString
        switch name {
        case "cortland_ping", "cortland_pane_list", "cortland_agent_list", "cortland_new_tab":
            return [:]
        case "cortland_pane_current", "cortland_pane_focus", "cortland_pane_close":
            return ["pane_id": paneID]
        case "cortland_pane_split":
            return ["pane_id": paneID]
        case "cortland_pane_send_text":
            return ["pane_id": paneID, "text": "hello"]
        case "cortland_pane_run":
            return ["pane_id": paneID, "command": "ls -la"]
        case "cortland_pane_send_key":
            return ["pane_id": paneID, "key": "enter"]
        case "cortland_pane_read":
            return ["pane_id": paneID]
        case "cortland_wait_agent_status":
            return ["pane_id": paneID, "status": "idle"]
        case "cortland_wait_output":
            return ["pane_id": paneID, "match": "done"]
        case "cortland_worktree_list", "cortland_worktree_prune":
            return [:]
        case "cortland_worktree_remove":
            return ["branch": "feature/x"]
        default:
            return [:]
        }
    }

    private func decodeCommand(_ request: [String: Any]) throws -> IPCCommand {
        let data = try JSONSerialization.data(withJSONObject: request)
        return try JSONDecoder().decode(IPCCommand.self, from: data)
    }

    // MARK: - Catalog shape

    func testEveryToolNameIsUniqueAndWellFormed() {
        let names = tools.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "duplicate tool name would trap at startup")
        for name in names {
            XCTAssertNotNil(name.range(of: "^cortland_[a-z_]+$", options: .regularExpression),
                            "\(name) doesn't match the cortland_ naming convention")
        }
    }

    func testEveryInputSchemaIsAnObjectWithRequiredSubsetOfProperties() {
        for tool in tools {
            let schema = tool.inputSchema
            XCTAssertEqual(schema["type"] as? String, "object", "\(tool.name) schema type")
            let properties = (schema["properties"] as? [String: Any]) ?? [:]
            let required = (schema["required"] as? [String]) ?? []
            for key in required {
                XCTAssertNotNil(properties[key],
                                "\(tool.name): required field '\(key)' has no matching property in the schema")
            }
        }
    }

    // MARK: - Advertised properties vs. handler reads

    func testValidArgsFromSchemaBuildTheExpectedAction() throws {
        for (name, action) in expectedAction {
            let request = try tool(name).buildRequest(validArgs(for: name))
            XCTAssertEqual(request["action"] as? String, action, "\(name) emitted the wrong action")
        }
    }

    func testRequiredFieldsAreEnforcedByBuildRequest() {
        // Omitting any advertised-required field must throw — catches a `required`
        // array that names a field the handler doesn't actually demand (and vice
        // versa, since the handler's requireString call is what throws here).
        for (name, _) in expectedAction {
            let schema = tool(name).inputSchema
            let required = (schema["required"] as? [String]) ?? []
            for missing in required {
                var args = validArgs(for: name)
                args.removeValue(forKey: missing)
                XCTAssertThrowsError(try tool(name).buildRequest(args),
                                     "\(name): omitting required '\(missing)' should throw") { error in
                    XCTAssertTrue(error is ToolError, "expected ToolError, got \(error)")
                }
            }
        }
    }

    // MARK: - Emitted action decodes to a valid server command

    func testEveryEmittedActionDecodesToAKnownCommand() throws {
        // The core "silent typo" guard: a mistyped action like "pane_slit" would
        // compile and list fine but be rejected only at a live round-trip.
        for (name, _) in expectedAction {
            let request = try tool(name).buildRequest(validArgs(for: name))
            let command = try decodeCommand(request)
            XCTAssertNotNil(IPCCommandType.from(command),
                            "\(name)'s emitted command was rejected by IPCCommandType.from")
        }
    }

    // MARK: - Enum values match the server's accepted set

    func testWaitAgentStatusEnumMatchesAgentStateCases() {
        let schema = tool("cortland_wait_agent_status").inputSchema
        let properties = schema["properties"] as? [String: Any]
        let statusProp = properties?["status"] as? [String: Any]
        let advertised = Set((statusProp?["enum"] as? [String]) ?? [])
        let serverAccepted = Set(AgentState.allCases.map(\.rawValue))
        XCTAssertEqual(advertised, serverAccepted,
                       "wait_agent_status status enum drifted from AgentState")
    }

    func testPaneSplitDirectionEnumValuesAreAllAccepted() throws {
        let schema = tool("cortland_pane_split").inputSchema
        let properties = schema["properties"] as? [String: Any]
        let directionProp = properties?["direction"] as? [String: Any]
        let directions = (directionProp?["enum"] as? [String]) ?? []
        XCTAssertFalse(directions.isEmpty)
        for direction in directions {
            let request = try tool("cortland_pane_split").buildRequest(["pane_id": UUID().uuidString, "direction": direction])
            let command = try decodeCommand(request)
            guard case .paneSplit = IPCCommandType.from(command) else {
                return XCTFail("direction '\(direction)' was not accepted as a pane_split")
            }
        }
    }

    func testPaneReadSourceEnumValuesAreAllAccepted() throws {
        let schema = tool("cortland_pane_read").inputSchema
        let properties = schema["properties"] as? [String: Any]
        let sourceProp = properties?["source"] as? [String: Any]
        let sources = (sourceProp?["enum"] as? [String]) ?? []
        XCTAssertEqual(Set(sources), ["visible", "recent"])
        for source in sources {
            let request = try tool("cortland_pane_read").buildRequest(["pane_id": UUID().uuidString, "source": source])
            let command = try decodeCommand(request)
            guard case .paneRead = IPCCommandType.from(command) else {
                return XCTFail("source '\(source)' was not accepted as a pane_read")
            }
        }
    }

    // MARK: - Intentional arg→IPC renames stay pinned

    func testPaneRunMapsCommandToTextWithoutTrailingReturn() throws {
        let request = try tool("cortland_pane_run").buildRequest(["pane_id": UUID().uuidString, "command": "make test"])
        XCTAssertEqual(request["action"] as? String, "pane_run")
        XCTAssertEqual(request["text"] as? String, "make test",
                       "pane_run must not embed a carriage return: TUIs treat one delivered in the "
                       + "same chunk as pasted text, so the server sends Enter as a separate write")
    }

    func testPaneReadJSONFlagMapsToFormatJSON() throws {
        let withJSON = try tool("cortland_pane_read").buildRequest(["pane_id": UUID().uuidString, "json": true])
        XCTAssertEqual(withJSON["format"] as? String, "json")
        let withoutJSON = try tool("cortland_pane_read").buildRequest(["pane_id": UUID().uuidString])
        XCTAssertNil(withoutJSON["format"], "format should be absent (server defaults to text) when json isn't set")
    }

    func testPaneReadThreadsSinceCursorAndParsesAsDelta() throws {
        let schema = tool("cortland_pane_read").inputSchema
        let properties = schema["properties"] as? [String: Any]
        XCTAssertNotNil(properties?["since"], "pane_read must expose a `since` cursor property")

        let withSince = try tool("cortland_pane_read").buildRequest(
            ["pane_id": UUID().uuidString, "source": "recent", "since": "4321:8192"])
        XCTAssertEqual(withSince["since"] as? String, "4321:8192")
        let command = try decodeCommand(withSince)
        guard case let .paneRead(_, _, _, _, since) = IPCCommandType.from(command) else {
            return XCTFail("Expected paneRead")
        }
        XCTAssertEqual(since, "4321:8192")

        let withoutSince = try tool("cortland_pane_read").buildRequest(["pane_id": UUID().uuidString])
        XCTAssertNil(withoutSince["since"], "since stays absent (full read) unless the caller passes a cursor")
    }

    func testPaneReadRendersCursorAndTruncationForRecentReads() {
        let read = tool("cortland_pane_read")
        XCTAssertEqual(read.render(["text": "output", "cursor": "12:34"]), "output\n\n[cursor: 12:34]")
        XCTAssertEqual(
            read.render(["text": "full re-read", "cursor": "12:34", "truncated": true]),
            "full re-read\n\n[cursor: 12:34 — truncated: prior cursor was stale, this is a full re-read]")
        XCTAssertEqual(read.render(["text": "visible only"]), "visible only",
                       "a read without a cursor (visible source) renders plain text")
    }

    // MARK: - worktree lifecycle

    func testWorktreeRemoveMapsBranchToWorktreeAndOmitsForceByDefault() throws {
        let request = try tool("cortland_worktree_remove").buildRequest(["branch": "feature/x"])
        XCTAssertEqual(request["action"] as? String, "worktree_remove")
        XCTAssertEqual(request["worktree"] as? String, "feature/x",
                       "the server reads the branch from the `worktree` key")
        XCTAssertNil(request["force"], "force stays absent (server defaults to false) unless set")
    }

    func testWorktreeRemoveForwardsForceWhenSet() throws {
        let request = try tool("cortland_worktree_remove").buildRequest(["branch": "feature/x", "force": true])
        XCTAssertEqual(request["force"] as? Bool, true)
    }

    func testWorktreeListAndPruneOmitCwdWhenAbsent() throws {
        for name in ["cortland_worktree_list", "cortland_worktree_prune"] {
            let request = try tool(name).buildRequest([:])
            XCTAssertNil(request["cwd"], "\(name) must not emit an empty cwd — the server resolves it")
        }
    }

    func testWorktreeListRendersWorktreesArray() {
        let rendered = tool("cortland_worktree_list").render([
            "worktrees": [["path": "/repo", "branch": "main", "head": "abc123"]]
        ])
        XCTAssertTrue(rendered.contains("\"branch\""))
        XCTAssertTrue(rendered.contains("main"))
    }

    // MARK: - agent_list

    func testAgentListRendersAgentsArray() {
        let rendered = tool("cortland_agent_list").render([
            "agents": [[
                "pane_id": "abc", "tab_id": "def", "tab": "cortland (main)",
                "agent": "opus-4.8", "state": "working", "since_s": 12,
                "cost_usd": 0.36, "worktree": "feature/x"
            ]]
        ])
        XCTAssertTrue(rendered.contains("\"state\""))
        XCTAssertTrue(rendered.contains("working"))
        XCTAssertTrue(rendered.contains("\"since_s\""))
        XCTAssertTrue(rendered.contains("\"worktree\""))
        // JSONSerialization escapes the branch's slash (feature\/x).
        XCTAssertTrue(rendered.contains("feature"))
    }

    func testAgentListRendersEmptyArrayWhenNoAgents() {
        // A fleet with no active agents (or a nil result) renders an empty JSON
        // array — a well-formed list the caller can iterate, never an error.
        for result in [[String: Any](), nil] {
            let rendered = tool("cortland_agent_list").render(result)
            XCTAssertEqual(rendered.filter { !$0.isWhitespace }, "[]")
        }
    }

    // MARK: - wait_event

    func testWaitEventRunsThroughExecuteNotBuildRequest() {
        let waitEvent = tool("cortland_wait_event")
        XCTAssertNotNil(waitEvent.execute, "wait_event must have an execute closure")
        XCTAssertThrowsError(try waitEvent.buildRequest([:]),
                             "wait_event's buildRequest is a guard rail and must throw")
    }
}
