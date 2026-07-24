import Foundation

/// The pure logic behind `cortland-agent-status edit-gate`: turns a Claude Code
/// PreToolUse hook payload for a file-editing tool into a `show_diff` proposal
/// for Cortland's approval desk, and renders the desk's verdict as the
/// permission-decision JSON Claude Code expects on the hook's stdout.
///
/// Lives here (not in the executable) so the parsing, diff computation, and
/// decision encoding are unit-testable; the executable adds only stdin/socket
/// plumbing. Every "can't handle this" path returns nil, which the executable
/// translates into a silent exit — Claude Code treats a hook with no decision
/// as "use the normal permission flow", so unknown shapes always fail OPEN to
/// the agent's own prompt rather than blocking the tool call.
public enum EditGate {
    public struct Proposal: Equatable, Sendable {
        public let path: String
        public let old: String
        public let new: String

        public init(path: String, old: String, new: String) {
            self.path = path
            self.old = old
            self.new = new
        }
    }

    /// Per-body ceiling for what we'll send over the socket. The app's IPC
    /// request buffer is sized for two ~4MB JSON-escaped file bodies; anything
    /// larger falls back to Claude's own prompt rather than risk a truncated
    /// diff being reviewed as if it were complete.
    public static let maxBodyBytes = 4 * 1024 * 1024

    /// Parses a PreToolUse hook payload into a review proposal, or nil when the
    /// edit can't (or shouldn't) be reviewed: an unrecognized tool, a binary or
    /// oversized file, an Edit whose old_string isn't present (Claude Code will
    /// fail that call itself), or a no-op. `readFile` is injectable for tests;
    /// nil from it means "no such file", i.e. a new-file Write.
    public static func proposal(
        fromHookPayload data: Data,
        readFile: (String) -> Data? = { FileManager.default.contents(atPath: $0) }
    ) -> Proposal? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let toolName = json["tool_name"] as? String,
              let toolInput = json["tool_input"] as? [String: Any],
              var path = toolInput["file_path"] as? String, !path.isEmpty
        else { return nil }

        path = (path as NSString).expandingTildeInPath
        // Tool paths are documented absolute, but resolve a relative one against
        // the session cwd the payload carries rather than trusting our own.
        if !path.hasPrefix("/"), let cwd = json["cwd"] as? String, cwd.hasPrefix("/") {
            path = (cwd as NSString).appendingPathComponent(path)
        }
        guard path.hasPrefix("/") else { return nil }

        let old: String
        if let oldData = readFile(path) {
            guard oldData.count <= maxBodyBytes,
                  let text = String(data: oldData, encoding: .utf8)   // non-UTF-8 = binary
            else { return nil }
            old = text
        } else {
            old = ""    // new file
        }

        let new: String
        switch toolName {
        case "Write":
            guard let content = toolInput["content"] as? String else { return nil }
            new = content
        case "Edit":
            guard let oldString = toolInput["old_string"] as? String, !oldString.isEmpty,
                  let newString = toolInput["new_string"] as? String,
                  let range = old.range(of: oldString)
            else { return nil }
            if (toolInput["replace_all"] as? Bool) == true {
                new = old.replacingOccurrences(of: oldString, with: newString)
            } else {
                new = old.replacingCharacters(in: range, with: newString)
            }
        default:
            return nil
        }

        // Nothing to review: a no-op edit, or the empty→empty shape the app's
        // show_diff handler treats as "just open a viewer".
        guard old != new, !(old.isEmpty && new.isEmpty),
              new.utf8.count <= maxBodyBytes
        else { return nil }

        return Proposal(path: path, old: old, new: new)
    }

    /// The `show_diff` socket command for a proposal. `paneID` (from
    /// `$CORTLAND_PANE_ID`) scopes the desk's "remember" grants and
    /// worktree-scoped auto-approve to the pane the agent runs in.
    public static func ipcCommand(for proposal: Proposal, paneID: String?) -> [String: Any] {
        var command: [String: Any] = [
            "action": "show_diff",
            "path": proposal.path,
            "old": proposal.old,
            "new": proposal.new
        ]
        if let paneID, !paneID.isEmpty {
            command["pane_id"] = paneID
        }
        return command
    }

    /// The PreToolUse decision Claude Code reads from the hook's stdout. Only
    /// "allow" and "deny" are ever emitted — never "ask", which would resurrect
    /// the double prompt that got the original diff hook removed. The deny
    /// reason is written for the agent: it says what was rejected and steers it
    /// toward the user instead of a blind retry.
    public static func decisionJSON(accepted: Bool, path: String) -> String {
        let reason = accepted
            ? "Approved in Cortland"
            : "The user rejected this edit to \((path as NSString).lastPathComponent) "
                + "in Cortland's review panel. Ask the user how to proceed instead of "
                + "retrying the same edit."
        let output: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": accepted ? "allow" : "deny",
                "permissionDecisionReason": reason
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: output),
              let json = String(data: data, encoding: .utf8) else {
            // Unreachable with the literal dictionary above; kept total so the
            // caller can print the result unconditionally.
            return #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"\#(accepted ? "allow" : "deny")"}}"#
        }
        return json
    }
}
