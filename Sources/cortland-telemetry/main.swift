import Foundation
import CortlandTelemetryCore
import CortlandIPCCore

// Invoked by an agent's Stop and SessionStart hooks. Reads the hook payload on
// stdin (which carries `transcript_path`), aggregates token usage from that
// transcript via CortlandTelemetryCore, and reports it to the running Cortland
// app over the IPC socket — tagged with `CORTLAND_PANE_ID`, the pane whose
// shell the hook ran in (the same correlation `cortland-ctl` uses).
//
// Stop reports the finished turn's usage. SessionStart (startup / /clear /
// resume) means the pane's previous telemetry no longer describes the session:
// if the new transcript already has billed turns (a resume), report those, and
// otherwise tell the app to blank the pane's meter instead of leaving the old
// session's context bar on screen.
//
// A hook must never disrupt the agent: every failure path exits 0 silently.

@main
struct CortlandTelemetry {
    static func main() {
        guard let paneID = ProcessInfo.processInfo.environment["CORTLAND_PANE_ID"],
              !paneID.isEmpty else { return }   // not running inside a Cortland pane

        // The hook passes the agent flavor as its first argument ("codex"); Claude
        // (no argument) is the default. It selects the transcript schema to parse.
        let agent = CommandLine.arguments.dropFirst().first ?? "claude"

        guard let payload = hookPayload() else { return }
        let isSessionStart = payload["hook_event_name"] as? String == "SessionStart"

        let parsed: TranscriptUsage?
        if let transcriptPath = transcriptPath(from: payload) {
            switch agent {
            case "codex": parsed = CodexTranscriptParser.aggregate(contentsOfFile: transcriptPath)
            case "pi":    parsed = PiTranscriptParser.aggregate(contentsOfFile: transcriptPath)
            default:      parsed = TranscriptParser.aggregate(contentsOfFile: transcriptPath)
            }
        } else {
            parsed = nil
        }

        if let usage = parsed, usage.assistantResponses > 0 {
            guard let usageData = try? JSONEncoder().encode(usage),
                  let usageString = String(data: usageData, encoding: .utf8) else { return }
            CortlandIPCClient().sendFireAndForget(
                ["action": "report_telemetry", "pane_id": paneID, "telemetry": usageString]
            )
        } else if isSessionStart {
            // A fresh or cleared session: its transcript has no billed turns yet
            // (or doesn't exist), so clear the pane's stale telemetry.
            CortlandIPCClient().sendFireAndForget(
                ["action": "reset_telemetry", "pane_id": paneID]
            )
        }
    }

    /// Reads the hook payload JSON from stdin. Both Claude and Codex deliver
    /// JSON on stdin. Only read when stdin is a pipe (never a TTY, which would
    /// block an interactive invocation).
    private static func hookPayload() -> [String: Any]? {
        guard isatty(FileHandle.standardInput.fileDescriptor) == 0 else { return nil }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// The transcript path from a hook payload: Claude uses `transcript_path`,
    /// Codex `transcript_path` or `agent_transcript_path`.
    private static func transcriptPath(from payload: [String: Any]) -> String? {
        let path = (payload["transcript_path"] as? String) ?? (payload["agent_transcript_path"] as? String)
        guard let path, !path.isEmpty else { return nil }
        return (path as NSString).expandingTildeInPath
    }
}
