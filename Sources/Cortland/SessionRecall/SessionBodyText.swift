import Foundation

/// Extracts a session log's *searchable body text* — the human and assistant
/// prose plus the commands the agent invoked — for the opt-in Session Recall
/// "deep search" mode. Answers "which session had that command / phrase?" by
/// reading transcript bodies INTO MEMORY only; nothing is persisted.
///
/// A `nonisolated enum` of static methods (matching `SessionLogScanner`) so it
/// can run off the main thread despite the module's `@MainActor` default
/// isolation. It reuses the scanner's jsonl-reading *approach* (lossy UTF-8,
/// skip malformed lines) without touching its logic. Unlike the title scanner,
/// extraction is uncapped: deep search exists to find phrases anywhere in a
/// long transcript, and this parsing is in-memory and opt-in.
///
/// What it INCLUDES vs EXCLUDES is the whole point of recall usefulness:
/// - INCLUDE: Claude `user`/`assistant` message text; Codex
///   `event_msg/user_message`, `response_item/message`, `event_msg/agent_message`;
///   and the *input* of a tool/function call (e.g. the shell command string).
/// - EXCLUDE: bulk tool *outputs/results* (command stdout, file-read dumps) —
///   those are noise for recall. Only whitelisted, text-bearing fields are kept,
///   so large output payloads are skipped by construction.
nonisolated enum SessionBodyText {
    /// Read a log file into an array of lowercased, whitespace-collapsed text
    /// lines — one per message / tool-call input contributed. Lines are kept
    /// separable so a matching snippet can be produced around a hit. Returns an
    /// empty array when the file can't be read; malformed jsonl lines are
    /// skipped without throwing.
    static func extractLines(at url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        // Decode lossily (invalid UTF-8 -> U+FFFD), matching the scanner's read.
        let contents = String(decoding: data, as: UTF8.self)
        var lines: [String] = []
        for raw in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let lineData = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }
            appendText(from: object, into: &lines)
        }
        return lines
    }

    // MARK: - Per-line extraction

    private static func appendText(from object: [String: Any], into lines: inout [String]) {
        let type = object["type"] as? String

        // Claude: user/assistant turns carry a `message` dict with `content`.
        if type == "user" || type == "assistant",
           let message = object["message"] as? [String: Any] {
            collectContent(message["content"], into: &lines)
            return
        }

        // Codex: everything hangs off a `payload`, keyed by its own type.
        if let payload = object["payload"] as? [String: Any] {
            switch payload["type"] as? String {
            case "user_message", "agent_message":
                if let message = payload["message"] as? String { add(message, into: &lines) }
            case "message":
                collectContent(payload["content"], into: &lines)
            case "function_call":
                // The command the agent ran lives in the call arguments; keep
                // the tool name + arguments, never the (bulk) call output.
                if let name = payload["name"] as? String { add(name, into: &lines) }
                if let arguments = payload["arguments"] as? String { add(arguments, into: &lines) }
            default:
                break   // function_call_output, token_count, etc. — skip output/noise.
            }
        }
    }

    /// Pull text out of a message `content` field (bare string or a list of
    /// parts). Only prose parts (`text`/`input_text`/`output_text`) and
    /// tool-call *inputs* (`tool_use`) contribute; `tool_result` and images are
    /// skipped so command output never bloats the index.
    private static func collectContent(_ content: Any?, into lines: inout [String]) {
        if let string = content as? String { add(string, into: &lines); return }
        guard let parts = content as? [Any] else { return }
        for part in parts {
            guard let part = part as? [String: Any] else { continue }
            switch part["type"] as? String {
            case "text", "input_text", "output_text":
                if let text = part["text"] as? String { add(text, into: &lines) }
            case "tool_use":
                if let input = part["input"] as? [String: Any] { addToolInput(input, into: &lines) }
            default:
                break   // tool_result, image, thinking, etc. — skipped.
            }
        }
    }

    /// Include the *command* the agent invoked (and its description), not the
    /// tool's output. Covers the common shell-command shape (`command` as a
    /// string or an argv array) plus a human-readable `description`.
    private static func addToolInput(_ input: [String: Any], into lines: inout [String]) {
        if let command = input["command"] as? String {
            add(command, into: &lines)
        } else if let argv = input["command"] as? [Any] {
            add(argv.compactMap { $0 as? String }.joined(separator: " "), into: &lines)
        }
        if let description = input["description"] as? String { add(description, into: &lines) }
    }

    /// Collapse whitespace to single spaces, lowercase, and append when
    /// non-empty. Lowercasing here makes deep search case-insensitive by a plain
    /// substring test.
    private static func add(_ text: String, into lines: inout [String]) {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if !collapsed.isEmpty { lines.append(collapsed.lowercased()) }
    }
}
