import Foundation
import CortlandIPCCore

// Invoked by an agent's status hooks (Claude Code, Codex, Pi) to tell Cortland
// what the agent is doing: busy on a prompt, waiting on the user, done, gone.
//
// Two transports, tried in order (see AgentStatusReport for the why):
//   1. an OSC 666 escape written to /dev/tty, which the pane's terminal picks
//      out of its own output stream, and
//   2. the Cortland control socket, addressed to $CORTLAND_PANE_ID — the only
//      route open to a hook process spawned without a controlling terminal,
//      which is how Claude Code spawns them.
//
// A hook must never disrupt the agent: every failure path exits 0 silently.

// The edit-gate subcommand is a different animal from a status report: it
// blocks on a human decision and answers Claude Code's permission question.
// Dispatched before status parsing so the two share the binary (and therefore
// the install/refresh machinery) without sharing a code path.
if CommandLine.arguments.dropFirst().first == "edit-gate" {
    exit(EditGateCommand.run())
}

let requestedStatus: AgentStatusReport.Status
if let parsed = AgentStatusReport.status(fromArgument: CommandLine.arguments.dropFirst().first) {
    requestedStatus = parsed
} else {
    FileHandle.standardError.write(Data("usage: cortland-agent-status busy|ready|done|idle|edit-gate\n".utf8))
    exit(2)
}

/// Reads the `message` from a hook payload on stdin, if present. Hooks always
/// receive JSON on stdin, so we only read when stdin is a pipe (never a TTY,
/// which would block an interactive invocation).
func hookMessage() -> String? {
    guard isatty(FileHandle.standardInput.fileDescriptor) == 0 else { return nil }
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard !data.isEmpty,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let message = json["message"] as? String else { return nil }
    return message
}

if AgentStatusReport.isIdleReminder(status: requestedStatus, hookMessage: hookMessage()) {
    exit(0)
}

// A `ready` fired under a machine reviewer is not the human's cue. The reviewer
// is named by the environment the agent was launched with, which this hook
// inherits — the hook payload itself does not carry it.
let status = AgentStatusReport.effectiveStatus(
    requested: requestedStatus,
    environment: ProcessInfo.processInfo.environment
)

/// Writes the OSC 666 sequence to the controlling terminal. False when there
/// isn't one — a hook spawned detached from the pane's tty (Claude Code) opens
/// /dev/tty with ENXIO, and the report has to go around through the socket.
func reportOverTTY(_ status: AgentStatusReport.Status) -> Bool {
    guard let data = AgentStatusReport.escapeSequence(for: status).data(using: .utf8),
          let tty = FileHandle(forWritingAtPath: "/dev/tty") else { return false }
    defer { try? tty.close() }
    do {
        try tty.write(contentsOf: data)
        return true
    } catch {
        return false
    }
}

/// Reports over Cortland's control socket, addressed to the pane whose shell the
/// hook ran in. False when not running inside a Cortland pane (no pane ID in the
/// environment) or the app isn't listening.
func reportOverSocket(_ status: AgentStatusReport.Status) -> Bool {
    guard let paneID = ProcessInfo.processInfo.environment["CORTLAND_PANE_ID"],
          !paneID.isEmpty else { return false }
    return CortlandIPCClient().sendFireAndForget(
        AgentStatusReport.ipcCommand(status: status, paneID: paneID)
    )
}

if !reportOverTTY(status) {
    _ = reportOverSocket(status)
}
