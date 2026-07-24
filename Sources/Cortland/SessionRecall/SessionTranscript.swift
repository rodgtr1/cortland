import Foundation

/// Extracts a session log into an ordered, *display-oriented* transcript for the
/// read-only Session Recall preview ("see what was said without resuming it").
///
/// Where `SessionBodyText` flattens and lowercases every message into a search
/// blob, this preserves case and internal line breaks and keeps turns separate,
/// ordered, and role-tagged so the preview can render them like a conversation.
/// It shares the scanner's jsonl-reading approach (lossy UTF-8, skip malformed
/// lines) and the same "which fields carry human/agent prose vs. tool output"
/// judgement:
/// - INCLUDE: Claude `user`/`assistant` message text; Codex
///   `event_msg/user_message` + `agent_message`, `response_item/message`; and
///   the *command* of a tool/function call.
/// - EXCLUDE: all tool *outputs/results* — a preview of the conversation, not of
///   the command output that scrolled past.
///
/// A `nonisolated enum` of static methods (matching `SessionBodyText` /
/// `SessionLogScanner`) so it can parse off the main thread despite the module's
/// `@MainActor` default isolation. Extraction is uncapped — the whole point is
/// to read the entire session.
nonisolated enum SessionTranscript {
    /// Who authored a turn. `tool` is the agent invoking a command (the command
    /// itself, never its output).
    enum Role: Sendable {
        case user
        case assistant
        case tool
    }

    /// One rendered conversation turn: a role and its display text, with case and
    /// internal line breaks intact.
    struct Turn: Sendable {
        let role: Role
        let text: String
    }

    /// Prefixes that mark an injected wrapper / continuation payload rather than a
    /// real human prompt. Kept in sync with `SessionLogScanner.wrapperPrefixes`
    /// (which is private) so the transcript starts at the real conversation, not
    /// at a resumed-session banner.
    private static let wrapperPrefixes = [
        "The following is the Codex agent history",
        "Caveat:",
        "[Request interrupted",
        "This session is being continued from a previous",
    ]

    /// Read a log file into ordered turns. Returns an empty array when the file
    /// can't be read; malformed jsonl lines are skipped without throwing. No cap.
    static func turns(at url: URL) -> [Turn] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        // Decode lossily (invalid UTF-8 -> U+FFFD), matching the scanner's read.
        let contents = String(decoding: data, as: UTF8.self)
        var turns: [Turn] = []
        for raw in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let lineData = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }
            appendTurns(from: object, into: &turns)
        }
        return turns
    }

    // MARK: - Per-line extraction

    private static func appendTurns(from object: [String: Any], into turns: inout [Turn]) {
        let type = object["type"] as? String

        // Claude: user/assistant turns carry a `message` dict with `content`.
        if type == "user" || type == "assistant",
           let message = object["message"] as? [String: Any] {
            let role: Role = type == "user" ? .user : .assistant
            collectContent(message["content"], role: role, into: &turns)
            return
        }

        // Codex: everything hangs off a `payload`, keyed by its own type.
        if let payload = object["payload"] as? [String: Any] {
            switch payload["type"] as? String {
            case "user_message":
                if let message = payload["message"] as? String { addProse(message, role: .user, into: &turns) }
            case "agent_message":
                if let message = payload["message"] as? String { addProse(message, role: .assistant, into: &turns) }
            case "message":
                let role: Role = (payload["role"] as? String == "assistant") ? .assistant : .user
                collectContent(payload["content"], role: role, into: &turns)
            case "function_call":
                addFunctionCall(payload, into: &turns)
            default:
                break   // function_call_output, token_count, etc. — output/noise.
            }
        }
    }

    /// Pull turns out of a message `content` field (bare string or a list of
    /// parts). Only prose parts (`text`/`input_text`) and tool-call *inputs*
    /// (`tool_use`) contribute; `tool_result`, images and thinking are skipped so
    /// command output and internal reasoning never reach the preview.
    private static func collectContent(_ content: Any?, role: Role, into turns: inout [Turn]) {
        if let string = content as? String {
            addProse(string, role: role, into: &turns)
            return
        }
        guard let parts = content as? [Any] else { return }
        for part in parts {
            guard let part = part as? [String: Any] else { continue }
            switch part["type"] as? String {
            case "text", "input_text":
                if let text = part["text"] as? String { addProse(text, role: role, into: &turns) }
            case "tool_use":
                if let input = part["input"] as? [String: Any] { addToolUse(input, into: &turns) }
            default:
                break   // tool_result, image, thinking, etc. — skipped.
            }
        }
    }

    /// The *command* a Claude tool call invoked (and its description), never the
    /// output. Covers the shell shape (`command` as a string or an argv array).
    private static func addToolUse(_ input: [String: Any], into turns: inout [Turn]) {
        var pieces: [String] = []
        if let command = input["command"] as? String {
            pieces.append(command)
        } else if let argv = input["command"] as? [Any] {
            pieces.append(argv.compactMap { $0 as? String }.joined(separator: " "))
        }
        if let description = input["description"] as? String { pieces.append(description) }
        addTool(pieces.joined(separator: "\n"), into: &turns)
    }

    /// The Codex function call: the tool name plus its arguments (the command),
    /// never the call output.
    private static func addFunctionCall(_ payload: [String: Any], into turns: inout [Turn]) {
        var pieces: [String] = []
        if let name = payload["name"] as? String { pieces.append(name) }
        if let arguments = payload["arguments"] as? String { pieces.append(arguments) }
        addTool(pieces.joined(separator: " "), into: &turns)
    }

    // MARK: - Turn assembly

    /// Append a prose turn, preserving case and internal line breaks but trimming
    /// surrounding whitespace. Empty turns are skipped; a user turn that is an
    /// injected wrapper (`<…>`, continuation banner) is dropped so the preview
    /// opens on the real conversation.
    private static func addProse(_ raw: String, role: Role, into turns: inout [Turn]) {
        if role == .user, isWrapper(raw) { return }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return }
        turns.append(Turn(role: role, text: text))
    }

    /// Append a tool turn (a command), trimming surrounding whitespace and
    /// skipping empties.
    private static func addTool(_ raw: String, into turns: inout [Turn]) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return }
        turns.append(Turn(role: .tool, text: text))
    }

    /// True if the candidate user text is injected noise, not a human prompt.
    /// Compared against the whitespace-collapsed text, case-sensitively, matching
    /// `SessionLogScanner.isWrapper`.
    private static func isWrapper(_ text: String) -> Bool {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if collapsed.isEmpty { return true }
        if collapsed.hasPrefix("<") { return true }
        return wrapperPrefixes.contains { collapsed.hasPrefix($0) }
    }
}
