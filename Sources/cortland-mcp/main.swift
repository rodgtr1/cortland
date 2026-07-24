import Foundation
import CortlandIPCCore
import CortlandMCPCore

/// cortland-mcp — a Model Context Protocol server that exposes Cortland's
/// pane-orchestration verbs as MCP tools.
///
/// It speaks MCP over stdio (newline-delimited JSON-RPC 2.0) and translates
/// `tools/call` invocations into the same Unix-socket IPC commands that
/// `cortland-ctl` already uses. Any MCP client (Claude Desktop, Claude Code,
/// Cursor, …) can then drive Cortland natively — no `cortland-ctl` shell-outs
/// and no SKILL.md required.
///
/// Register it with an MCP client by pointing the client at this binary, e.g.
/// in a `.mcp.json`:
///   { "mcpServers": { "cortland": { "command": "/path/to/cortland-mcp" } } }

// MARK: - Logging (stderr only — stdout is the protocol channel)

func logLine(_ message: String) {
    FileHandle.standardError.write(Data("cortland-mcp: \(message)\n".utf8))
}

// MARK: - IPC client (talks to the running Cortland over its Unix socket)

// Read-only after startup and touched from the background tool-call queue as
// well as the main read loop. `CortlandIPCClient.send` opens a fresh connection
// per call and holds only immutable state, so concurrent use is safe.
private nonisolated(unsafe) let ipc = CortlandIPCClient()

// MARK: - Tool catalog
//
// The tool catalog lives in the CortlandMCPCore library so it can be unit
// tested (schemas, argument handling, emitted IPC actions). It's built once and
// never mutated, read from both the main read loop (tools/list) and the
// background tool-call queue, so the unchecked opt-out over its non-Sendable
// closures is sound.
private nonisolated(unsafe) let tools: [Tool] = makeTools(ipc: ipc)

private nonisolated(unsafe) let toolsByName: [String: Tool] = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })

// MARK: - JSON-RPC plumbing over stdio

// Tool calls run on a background queue (see the main loop), so responses can be
// emitted from several threads at once. Serialize the writes so two JSON-RPC
// messages never interleave on the stdout protocol channel.
private let stdoutLock = NSLock()

/// Writes one newline-delimited JSON-RPC message to stdout.
private func emit(_ message: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
    data.append(UInt8(ascii: "\n"))
    stdoutLock.lock()
    defer { stdoutLock.unlock() }
    FileHandle.standardOutput.write(data)
}

private func respond(id: Any, result: [String: Any]) {
    emit(["jsonrpc": "2.0", "id": id, "result": result])
}

private func respondError(id: Any, code: Int, message: String) {
    emit(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}

/// Wraps text in the MCP tool-result content shape.
private func toolResult(_ text: String, isError: Bool = false) -> [String: Any] {
    ["content": [["type": "text", "text": text]], "isError": isError]
}

private let supportedProtocolVersions: Set<String> = ["2025-06-18", "2025-03-26", "2024-11-05"]

private func handleInitialize(id: Any, params: [String: Any]) {
    // Echo the client's protocol version when we support it; otherwise offer ours.
    let requested = params["protocolVersion"] as? String
    let agreed = (requested.map(supportedProtocolVersions.contains) ?? false) ? requested! : "2025-06-18"
    respond(id: id, result: [
        "protocolVersion": agreed,
        "capabilities": ["tools": [:]],
        "serverInfo": ["name": "cortland", "version": "1.0.0"],
        "instructions": "Control Cortland terminal panes and orchestrate visible worker agents. Call cortland_pane_list first to discover pane IDs."
    ])
}

private func handleToolsList(id: Any) {
    let listed = tools.map { tool in
        ["name": tool.name, "description": tool.description, "inputSchema": tool.inputSchema] as [String: Any]
    }
    respond(id: id, result: ["tools": listed])
}

private func handleToolsCall(id: Any, params: [String: Any]) {
    guard let name = params["name"] as? String, let tool = toolsByName[name] else {
        respondError(id: id, code: -32602, message: "Unknown tool: \(params["name"] as? String ?? "<none>")")
        return
    }
    let arguments = (params["arguments"] as? [String: Any]) ?? [:]

    if let execute = tool.execute {
        do {
            respond(id: id, result: toolResult(try execute(arguments)))
        } catch let error as ToolError {
            respond(id: id, result: toolResult(error.message, isError: true))
        } catch {
            respond(id: id, result: toolResult("Tool failed: \(error)", isError: true))
        }
        return
    }

    let request: [String: Any]
    do {
        request = try tool.buildRequest(arguments)
    } catch let error as ToolError {
        respond(id: id, result: toolResult(error.message, isError: true))
        return
    } catch {
        respond(id: id, result: toolResult("Invalid arguments: \(error)", isError: true))
        return
    }

    guard let reply = ipc.send(request) else {
        respond(id: id, result: toolResult("Cortland is not responding. Is the app running?", isError: true))
        return
    }
    guard reply["ok"] as? Bool == true else {
        let message = reply["error"] as? String ?? "Cortland rejected the request."
        respond(id: id, result: toolResult(message, isError: true))
        return
    }
    respond(id: id, result: toolResult(tool.render(reply["result"] as? [String: Any])))
}

// MARK: - Main loop

/// Carries one JSON-RPC request across the concurrency boundary to a background
/// tool-call executor. The payload is plain JSON, fully built before it's handed
/// off and read by exactly one executor thread, so the unchecked-Sendable
/// opt-out over the non-Sendable `Any` fields is sound.
private struct PendingToolCall: @unchecked Sendable {
    let id: Any
    let params: [String: Any]
}

/// Tool calls run here, off the read loop. Concurrent so independent waits
/// (e.g. wait_agent_status on two panes) proceed in parallel; a single MCP
/// client only ever has a handful in flight, so thread growth is bounded in
/// practice.
private let toolCallQueue = DispatchQueue(label: "app.cortland.mcp.tool-calls",
                                          qos: .userInitiated, attributes: .concurrent)

// Survive a broken pipe on either channel: writing to stdout after the MCP
// client disconnects, or the IPC socket closing mid-write, would otherwise
// deliver SIGPIPE and kill this long-lived server. Ignoring it turns both into
// EPIPE returns the write paths already handle. (The IPC socket also sets
// SO_NOSIGPIPE; this additionally covers the stdout protocol channel.)
signal(SIGPIPE, SIG_IGN)

logLine("ready on \(defaultCortlandSocketPath())")

while let line = readLine(strippingNewline: true) {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          let data = trimmed.data(using: .utf8),
          let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        continue
    }

    let method = message["method"] as? String
    let id = message["id"]   // absent for notifications
    let params = (message["params"] as? [String: Any]) ?? [:]

    switch method {
    case "initialize":
        if let id { handleInitialize(id: id, params: params) }
    case "notifications/initialized", "notifications/cancelled":
        break   // notifications: no response
    case "ping":
        if let id { respond(id: id, result: [:]) }
    case "tools/list":
        if let id { handleToolsList(id: id) }
    case "tools/call":
        // A verb like wait_agent_status can block for its full timeout (up to
        // an hour) inside a synchronous ipc.send. Run it off the read loop so
        // ping, tools/list, and cancellation notifications stay responsive —
        // MCP clients health-check with those and would otherwise declare the
        // server dead. Responses carry their id, so finishing out of order is
        // fine per JSON-RPC.
        if let id {
            let call = PendingToolCall(id: id, params: params)
            toolCallQueue.async { handleToolsCall(id: call.id, params: call.params) }
        }
    default:
        if let id { respondError(id: id, code: -32601, message: "Method not found: \(method ?? "<none>")") }
    }
}
