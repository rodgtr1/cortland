import Foundation
import CortlandIPCCore

/// `cortland-agent-status edit-gate` — the PreToolUse hook that carries a
/// Claude Code file edit to Cortland's diff-review queue and carries the
/// human's answer back as a permission decision, so exactly one prompt ever
/// appears: the desk's when Cortland is reachable, Claude's own when not.
///
/// Fail-open contract, same spirit as the status reports: a hook must never
/// disrupt the agent. Any failure — not in a Cortland pane, app not running,
/// unparseable payload, unreviewable file — exits 0 with NO output, and Claude
/// Code falls back to its normal permission flow. The blocking `send` has no
/// client-side timeout by design: the hook's own timeout (600s) is the outer
/// bound, and on expiry Claude Code also falls back to its own prompt.
enum EditGateCommand {
    static func run() -> Int32 {
        // Hooks always pipe their payload; a TTY here means someone ran this
        // interactively, and blocking on terminal input would hang them.
        guard isatty(FileHandle.standardInput.fileDescriptor) == 0 else { return 0 }

        let payload = FileHandle.standardInput.readDataToEndOfFile()
        guard let proposal = EditGate.proposal(fromHookPayload: payload) else { return 0 }

        let paneID = ProcessInfo.processInfo.environment["CORTLAND_PANE_ID"]
        guard let response = CortlandIPCClient().send(
                  EditGate.ipcCommand(for: proposal, paneID: paneID)
              ),
              response["ok"] as? Bool == true,
              let accepted = response["accepted"] as? Bool
        else { return 0 }

        print(EditGate.decisionJSON(accepted: accepted, path: proposal.path))
        return 0
    }
}
