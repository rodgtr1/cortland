import Foundation
import CortlandIPCCore

/// The cortland-mcp tool catalog, extracted into a library so it can be unit
/// tested. The executable (`Sources/cortland-mcp/main.swift`) is a thin stdio
/// JSON-RPC loop over `makeTools(ipc:)`; tests import this module to assert the
/// schemas, argument handling, and emitted IPC actions stay in contract.

/// One MCP tool, plus how to turn its arguments into an IPC request and how to
/// render the IPC reply as human/agent-readable text.
public struct Tool {
    public let name: String
    public let description: String
    public let inputSchema: [String: Any]
    /// Builds the IPC request, or throws a message describing the bad arguments.
    public let buildRequest: (_ arguments: [String: Any]) throws -> [String: Any]
    /// Renders a successful IPC reply's `result` (may be nil) into tool text.
    public let render: (_ result: [String: Any]?) -> String
    /// When set, the tool runs through this instead of the one-shot
    /// buildRequest → ipc.send → render pipeline — for verbs that consume a
    /// stream (wait_event) rather than a single reply. Returns the tool text;
    /// a thrown ToolError becomes an error result.
    public var execute: ((_ arguments: [String: Any]) throws -> String)? = nil
}

public struct ToolError: Error, Equatable {
    public let message: String
    public init(message: String) { self.message = message }
}

func requireString(_ arguments: [String: Any], _ key: String) throws -> String {
    guard let value = arguments[key] as? String, !value.isEmpty else {
        throw ToolError(message: "Missing required string argument: \(key)")
    }
    return value
}

func prettyJSON(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
          let string = String(data: data, encoding: .utf8) else { return "\(value)" }
    return string
}

func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
    var schema: [String: Any] = ["type": "object", "properties": properties]
    if !required.isEmpty { schema["required"] = required }
    return schema
}

nonisolated(unsafe) let paneIDProperty: [String: Any] = ["type": "string", "description": "Opaque pane ID from pane_list / pane_current / pane_split."]

/// Builds the tool catalog. `ipc` is only used by streaming tools' `execute`
/// (wait_event); every other tool's `buildRequest`/`render`/`inputSchema` is
/// pure and can be exercised without a live Cortland.
public func makeTools(ipc: CortlandIPCClient) -> [Tool] {
    [
    Tool(
        name: "cortland_ping",
        description: "Check whether Cortland is running and reachable.",
        inputSchema: object([:]),
        buildRequest: { _ in ["action": "ping"] },
        render: { _ in "Cortland is running." }
    ),
    Tool(
        name: "cortland_pane_list",
        description: "List every terminal pane across all tabs, with cwd, focus, and agent status. Start here to discover pane IDs.",
        inputSchema: object([:]),
        buildRequest: { _ in ["action": "pane_list"] },
        render: { result in prettyJSON(result?["panes"] ?? []) }
    ),
    Tool(
        name: "cortland_agent_list",
        description: "Fleet status for every agent pane in one call — the data the Agents sidebar tracks. Each row: pane_id, tab_id, tab title, agent (model, when known), state (working/ready/done), since_s (seconds in that state), cost_usd (when priced), and worktree branch (when the pane is on one). Idle panes are omitted. Use this to poll many workers at once instead of walking pane_list.",
        inputSchema: object([:]),
        buildRequest: { _ in ["action": "agent_list"] },
        render: { result in prettyJSON(result?["agents"] ?? []) }
    ),
    Tool(
        name: "cortland_pane_current",
        description: "Get the focused pane, or a specific pane when pane_id is given.",
        inputSchema: object(["pane_id": paneIDProperty]),
        buildRequest: { args in
            var request: [String: Any] = ["action": "pane_current"]
            if let paneID = args["pane_id"] as? String { request["pane_id"] = paneID }
            return request
        },
        render: { result in prettyJSON(result?["pane"] ?? [:]) }
    ),
    Tool(
        name: "cortland_new_tab",
        description: "Open a new terminal tab, optionally in a given working directory.",
        inputSchema: object(["cwd": ["type": "string", "description": "Absolute directory to start in."]]),
        buildRequest: { args in
            var request: [String: Any] = ["action": "new_tab"]
            request["cwd"] = (args["cwd"] as? String) ?? FileManager.default.currentDirectoryPath
            return request
        },
        render: { _ in "Opened a new tab." }
    ),
    Tool(
        name: "cortland_pane_split",
        description: "Split a pane to create a new terminal beside it. Use --no-focus semantics by passing focus=false to avoid stealing the user's focus. Pass command to launch a worker (e.g. [\"claude\"]).",
        inputSchema: object([
            "pane_id": paneIDProperty,
            "direction": ["type": "string", "enum": ["right", "down"], "description": "Split direction. Defaults to right."],
            "cwd": ["type": "string", "description": "Absolute directory for the new pane."],
            "command": ["type": "array", "items": ["type": "string"], "description": "argv to launch in the new pane (e.g. [\"claude\", \"-p\", \"review tests\"])."],
            "focus": ["type": "boolean", "description": "Whether to focus the new pane. Defaults to true."],
            "worktree": ["type": "string", "description": "Branch name. Creates (or reuses) a git worktree for it from the source pane's repo and opens the new pane there — safe fan-out for parallel agents. Overrides cwd."]
        ], required: ["pane_id"]),
        buildRequest: { args in
            var request: [String: Any] = [
                "action": "pane_split",
                "pane_id": try requireString(args, "pane_id"),
                "direction": (args["direction"] as? String) ?? "right",
                "focus": (args["focus"] as? Bool) ?? true
            ]
            if let cwd = args["cwd"] as? String { request["cwd"] = cwd }
            if let command = args["command"] as? [String], !command.isEmpty { request["command"] = command }
            if let worktree = args["worktree"] as? String { request["worktree"] = worktree }
            return request
        },
        render: { result in prettyJSON(result?["pane"] ?? [:]) }
    ),
    Tool(
        name: "cortland_pane_focus",
        description: "Bring a pane to the foreground and focus it.",
        inputSchema: object(["pane_id": paneIDProperty], required: ["pane_id"]),
        buildRequest: { args in ["action": "pane_focus", "pane_id": try requireString(args, "pane_id")] },
        render: { result in prettyJSON(result?["pane"] ?? [:]) }
    ),
    Tool(
        name: "cortland_pane_close",
        description: "Close a pane. Do not close panes you did not create unless explicitly asked.",
        inputSchema: object(["pane_id": paneIDProperty], required: ["pane_id"]),
        buildRequest: { args in ["action": "pane_close", "pane_id": try requireString(args, "pane_id")] },
        render: { _ in "Closed the pane." }
    ),
    Tool(
        name: "cortland_pane_send_text",
        description: "Type text into a pane without pressing Enter.",
        inputSchema: object([
            "pane_id": paneIDProperty,
            "text": ["type": "string", "description": "Literal text to type."]
        ], required: ["pane_id", "text"]),
        buildRequest: { args in
            ["action": "pane_send_text", "pane_id": try requireString(args, "pane_id"), "text": try requireString(args, "text")]
        },
        render: { _ in "Sent text." }
    ),
    Tool(
        name: "cortland_pane_run",
        description: "Type a command into a pane and press Enter to run it.",
        inputSchema: object([
            "pane_id": paneIDProperty,
            "command": ["type": "string", "description": "Command line to run."]
        ], required: ["pane_id", "command"]),
        buildRequest: { args in
            ["action": "pane_run", "pane_id": try requireString(args, "pane_id"), "text": try requireString(args, "command")]
        },
        render: { _ in "Ran the command." }
    ),
    Tool(
        name: "cortland_pane_send_key",
        description: "Send a named key to a pane. Supported: enter, tab, esc, backspace, ctrl-c, ctrl-d, up, down, left, right.",
        inputSchema: object([
            "pane_id": paneIDProperty,
            "key": ["type": "string", "description": "Named key, e.g. enter, ctrl-c, esc."]
        ], required: ["pane_id", "key"]),
        buildRequest: { args in
            ["action": "pane_send_key", "pane_id": try requireString(args, "pane_id"), "key": try requireString(args, "key")]
        },
        render: { _ in "Sent key." }
    ),
    Tool(
        name: "cortland_pane_read",
        description: "Read a pane's output, once. Never poll in a loop: block on cortland_wait_agent_status (a worker finishing) or cortland_wait_output (a specific line), then take ONE bounded read. source=visible (default; the screen, bounded and cheap) is the right source for a progress check. source=recent is a transcript of the pane's scrollback — use it when you genuinely need history. A source=recent read returns a `cursor`; pass it back as `since` to get only the output appended since, so a follow-up read is a delta, not the whole buffer again. On a stale cursor (evicted or a restarted shell) the reply is `truncated: true` with a full re-read, never an error. When the pane is running a full-screen program — which every agent CLI is — source=recent returns the scrollback from before that program started plus the screen as it now stands, and a `since` read returns that screen whenever anything has been written since the cursor (empty text when nothing has): a repaint overwrites cells in place, so there is no line-by-line delta to hand back. Set json=true for structured per-command records {command, exit_code, duration, output} built from shell-integration marks — easier to reason over than raw text. In visible reads, text wrapped in ⟦suggested, not typed: …⟧ is an unaccepted autosuggest/placeholder rendered at the cursor — the user did NOT type it; it becomes real input only if accepted (typically via the right-arrow key).",
        inputSchema: object([
            "pane_id": paneIDProperty,
            "source": ["type": "string", "enum": ["visible", "recent"], "description": "visible (default; the screen — prefer it for progress checks) or recent (scrollback transcript, for history)."],
            "lines": ["type": "integer", "description": "Limit to the last N lines (text) or N command records (json)."],
            "since": ["type": "string", "description": "Cursor from a prior source=recent read; returns only output appended after it."],
            "json": ["type": "boolean", "description": "Return structured command records instead of raw text."]
        ], required: ["pane_id"]),
        buildRequest: { args in
            var request: [String: Any] = [
                "action": "pane_read",
                "pane_id": try requireString(args, "pane_id"),
                "source": (args["source"] as? String) ?? "visible"
            ]
            if let lines = args["lines"] as? Int { request["lines"] = lines }
            if let since = args["since"] as? String { request["since"] = since }
            if (args["json"] as? Bool) == true { request["format"] = "json" }
            return request
        },
        render: { result in
            if let commands = result?["commands"] { return prettyJSON(commands) }
            let text = (result?["text"] as? String) ?? ""
            // A source=recent read carries the cursor; append it as a trailing
            // line so the model can pass it back as `since` on the next poll.
            guard let cursor = result?["cursor"] as? String else { return text }
            let note = (result?["truncated"] as? Bool) == true
                ? "[cursor: \(cursor) — truncated: prior cursor was stale, this is a full re-read]"
                : "[cursor: \(cursor)]"
            return text.isEmpty ? note : text + "\n\n" + note
        }
    ),
    Tool(
        name: "cortland_wait_agent_status",
        description: "Block until a pane's agent reaches a status (idle|working|ready|done) or the timeout elapses. After it returns, read the pane rather than assuming success.",
        inputSchema: object([
            "pane_id": paneIDProperty,
            "status": ["type": "string", "enum": ["idle", "working", "ready", "done"], "description": "Target agent status."],
            "timeout_ms": ["type": "integer", "description": "Timeout in milliseconds (default 30000)."]
        ], required: ["pane_id", "status"]),
        buildRequest: { args in
            [
                "action": "wait_agent_status",
                "pane_id": try requireString(args, "pane_id"),
                "status": try requireString(args, "status"),
                "timeout_ms": (args["timeout_ms"] as? Int) ?? 30_000
            ]
        },
        render: { result in
            ((result?["matched"] as? Bool) == true) ? "Reached the requested agent status." : "Timed out before reaching the requested agent status."
        }
    ),
    Tool(
        name: "cortland_wait_output",
        description: "Block until a pane's output contains a substring or the timeout elapses. After it returns, read the pane to see context.",
        inputSchema: object([
            "pane_id": paneIDProperty,
            "match": ["type": "string", "description": "Substring to wait for."],
            "timeout_ms": ["type": "integer", "description": "Timeout in milliseconds (default 30000)."]
        ], required: ["pane_id", "match"]),
        buildRequest: { args in
            [
                "action": "wait_output",
                "pane_id": try requireString(args, "pane_id"),
                "match": try requireString(args, "match"),
                "timeout_ms": (args["timeout_ms"] as? Int) ?? 30_000
            ]
        },
        render: { result in
            ((result?["matched"] as? Bool) == true) ? "Matched the requested output." : "Timed out before the output appeared."
        }
    ),
    Tool(
        name: "cortland_wait_event",
        description: "Block until the next Cortland event arrives, or the timeout elapses — the push alternative to polling wait_agent_status per pane. Optionally narrow by pane_id and/or event type: agent_state (a pane's agent changed status), command (a shell command finished), diff (a hook edit was queued/accepted/rejected), telemetry (token usage reported). Returns the event as JSON. Only events emitted after the call starts can match; current state is never replayed.",
        inputSchema: object([
            "pane_id": paneIDProperty,
            "type": ["type": "string", "enum": ["agent_state", "command", "diff", "telemetry"], "description": "Only wait for this event type."],
            "timeout_ms": ["type": "integer", "description": "Timeout in milliseconds (default 30000)."]
        ]),
        buildRequest: { _ in throw ToolError(message: "cortland_wait_event runs through execute") },
        render: { _ in "" },
        execute: { args in
            var request: [String: Any] = ["action": "events", "backlog": false]
            if let paneID = args["pane_id"] as? String, !paneID.isEmpty { request["pane_id"] = paneID }
            if let type = args["type"] as? String, !type.isEmpty { request["type"] = type }

            var matchedEvent: [String: Any] = [:]
            let outcome = ipc.waitForLine(request, timeoutMS: (args["timeout_ms"] as? Int) ?? 30_000) { line in
                // The hello connection marker always arrives first; everything
                // after it is a live event the server already filtered.
                guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      (event["type"] as? String) != "hello" else { return false }
                matchedEvent = event
                return true
            }
            switch outcome {
            case .matched:
                return prettyJSON(matchedEvent)
            case .timedOut:
                return "Timed out before a matching event arrived."
            case .disconnected:
                throw ToolError(message: "Cortland is not responding or closed the event stream. Is the app running?")
            }
        }
    ),
    Tool(
        name: "cortland_worktree_list",
        description: "List the git worktrees for the repository containing the given (or active pane's) directory. Returns each worktree's branch, path, and head as JSON.",
        inputSchema: object(["cwd": ["type": "string", "description": "Absolute directory inside the target repo. Defaults to the active pane's directory."]]),
        buildRequest: { args in
            var request: [String: Any] = ["action": "worktree_list"]
            if let cwd = args["cwd"] as? String, !cwd.isEmpty { request["cwd"] = cwd }
            return request
        },
        render: { result in prettyJSON(result?["worktrees"] ?? []) }
    ),
    Tool(
        name: "cortland_worktree_remove",
        description: "Remove the git worktree registered for a branch. Refuses a dirty or locked worktree unless force is set, so an agent's uncommitted work isn't silently discarded.",
        inputSchema: object([
            "branch": ["type": "string", "description": "Branch whose worktree to remove."],
            "force": ["type": "boolean", "description": "Remove even when the worktree is dirty or locked. Defaults to false."],
            "cwd": ["type": "string", "description": "Absolute directory inside the target repo. Defaults to the active pane's directory."]
        ], required: ["branch"]),
        buildRequest: { args in
            var request: [String: Any] = ["action": "worktree_remove", "worktree": try requireString(args, "branch")]
            if (args["force"] as? Bool) == true { request["force"] = true }
            if let cwd = args["cwd"] as? String, !cwd.isEmpty { request["cwd"] = cwd }
            return request
        },
        render: { _ in "Removed the worktree." }
    ),
    Tool(
        name: "cortland_worktree_prune",
        description: "Prune stale git worktree admin entries (bookkeeping for worktrees whose directories were deleted by hand).",
        inputSchema: object(["cwd": ["type": "string", "description": "Absolute directory inside the target repo. Defaults to the active pane's directory."]]),
        buildRequest: { args in
            var request: [String: Any] = ["action": "worktree_prune"]
            if let cwd = args["cwd"] as? String, !cwd.isEmpty { request["cwd"] = cwd }
            return request
        },
        render: { result in
            let text = (result?["text"] as? String) ?? ""
            return text.isEmpty ? "Nothing to prune." : text
        }
    )
    ]
}
