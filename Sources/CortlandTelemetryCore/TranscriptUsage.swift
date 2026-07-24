import Foundation

/// Token usage aggregated from a Claude Code transcript JSONL — the raw material
/// for the per-pane telemetry dashboard. Counts are summed across the session's
/// billed assistant responses; `model` is the most recent assistant model seen.
///
/// Pure value type with no AppKit dependency, so it is shared by the
/// `cortland-telemetry` helper (which parses the transcript off the agent
/// process) and the app (which prices and renders it).
public struct TranscriptUsage: Equatable, Codable, Sendable {
    /// Most recent assistant model id (e.g. `claude-opus-4-8`), or nil if the
    /// transcript had no billed assistant response.
    public var model: String?
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheCreation5mTokens: Int
    public var cacheCreation1hTokens: Int
    /// Billed model responses (distinct assistant messages carrying a `usage`
    /// block — deduplicated by message id, since the transcript repeats one
    /// message across several lines).
    public var assistantResponses: Int
    /// Typed user prompts (user lines whose content is a plain string, i.e. not
    /// a tool-result array or a harness-injected notification). The dashboard
    /// surfaces this as "turns".
    public var userPrompts: Int

    /// A cost the agent reported itself (e.g. Pi sums `usage.cost.total`). When
    /// present it's authoritative and takes precedence over the rate-card
    /// estimate — handy for agents whose model isn't in the rate card.
    public var reportedCostUSD: Double?

    /// Current context-window occupancy: the full input footprint (fresh input
    /// + cache reads + cache writes) of the *most recent* assistant turn. Unlike
    /// the cumulative `*Tokens` fields above (which sum the whole session for
    /// cost), this is the size of the prompt the model last processed — i.e. how
    /// full the context window is right now. It rises as the conversation grows
    /// and drops after a compaction, so it's the right number to drive a
    /// context-usage bar. 0 when no billed assistant turn was seen.
    public var contextTokens: Int

    public init(
        model: String? = nil,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheCreation5mTokens: Int = 0,
        cacheCreation1hTokens: Int = 0,
        assistantResponses: Int = 0,
        userPrompts: Int = 0,
        reportedCostUSD: Double? = nil,
        contextTokens: Int = 0
    ) {
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreation5mTokens = cacheCreation5mTokens
        self.cacheCreation1hTokens = cacheCreation1hTokens
        self.assistantResponses = assistantResponses
        self.userPrompts = userPrompts
        self.reportedCostUSD = reportedCostUSD
        self.contextTokens = contextTokens
    }

    /// All cache-creation (cache-write) tokens, 5-minute + 1-hour.
    public var cacheCreationTokens: Int { cacheCreation5mTokens + cacheCreation1hTokens }

    /// Total input-side tokens the user might think of as "in" (fresh input +
    /// cache writes + cache reads).
    public var totalInputTokens: Int {
        inputTokens + cacheCreationTokens + cacheReadTokens
    }

    /// Every billed token this session: the full input footprint plus output.
    /// The single number the cost roll-up sums per tab.
    public var totalTokens: Int {
        totalInputTokens + outputTokens
    }
}

public enum TranscriptParser {
    /// Aggregates usage from newline-delimited transcript JSON. Tolerant by
    /// design: non-message lines (`mode`, `system`, `attachment`, …) and any
    /// malformed line are skipped rather than failing the whole parse, since a
    /// live transcript is appended to while we read it.
    public static func aggregate<S: StringProtocol>(jsonl: S) -> TranscriptUsage {
        var usage = TranscriptUsage()
        var seenMessageIDs = Set<String>()
        for rawLine in jsonl.split(separator: "\n", omittingEmptySubsequences: true) {
            ingest(Data(rawLine.utf8), into: &usage, seenMessageIDs: &seenMessageIDs)
        }
        return usage
    }

    /// Aggregates the transcript file at `path`, or nil if it can't be read.
    /// Streams the file (see `TranscriptLineReader`) so a hundreds-of-MB
    /// transcript doesn't load whole into memory on every Stop hook (P5).
    public static func aggregate(contentsOfFile path: String) -> TranscriptUsage? {
        var usage = TranscriptUsage()
        var seenMessageIDs = Set<String>()
        guard TranscriptLineReader.forEachLine(inFileAt: path, { ingest($0, into: &usage, seenMessageIDs: &seenMessageIDs) })
        else { return nil }
        return usage
    }

    /// Folds one JSONL line's bytes into `usage`. Shared by the string and
    /// streaming entry points so they can't diverge.
    private static func ingest(
        _ lineData: Data,
        into usage: inout TranscriptUsage,
        seenMessageIDs: inout Set<String>
    ) {
        guard let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
        else { return }

        let type = object["type"] as? String
        let message = object["message"] as? [String: Any]

        // A typed prompt: a user line whose content is a plain string. Array
        // content is a tool-result turn, and harness-injected lines (task
        // notifications, command output, caveats — which arrive as string
        // content with no distinguishing flag) aren't things the user typed;
        // neither counts as a prompt.
        if type == "user", let content = message?["content"] as? String {
            if !content.hasPrefix("<") && !content.hasPrefix("Caveat:") {
                usage.userPrompts += 1
            }
            return
        }

        guard type == "assistant",
              let message,
              let usageObject = message["usage"] as? [String: Any] else { return }

        // The transcript writes one line per content block, so a multi-block
        // assistant message repeats the same id and an identical `usage` on
        // every line. Bill each message once or the session totals double.
        if let id = message["id"] as? String, !seenMessageIDs.insert(id).inserted {
            return
        }

        usage.assistantResponses += 1
        if let model = message["model"] as? String { usage.model = model }
        usage.inputTokens += int(usageObject["input_tokens"])
        usage.outputTokens += int(usageObject["output_tokens"])
        let cacheRead = int(usageObject["cache_read_input_tokens"])
        usage.cacheReadTokens += cacheRead

        let cacheWrite: Int
        if let cacheCreation = usageObject["cache_creation"] as? [String: Any] {
            let write5m = int(cacheCreation["ephemeral_5m_input_tokens"])
            let write1h = int(cacheCreation["ephemeral_1h_input_tokens"])
            usage.cacheCreation5mTokens += write5m
            usage.cacheCreation1hTokens += write1h
            cacheWrite = write5m + write1h
        } else {
            // Older transcripts only carry the flat total; bill it as 5-min.
            cacheWrite = int(usageObject["cache_creation_input_tokens"])
            usage.cacheCreation5mTokens += cacheWrite
        }

        // Context occupancy is this turn's full input footprint (it already
        // includes the whole prior conversation Claude re-sends each turn),
        // so the last assistant turn wins — not a sum across the session.
        usage.contextTokens = int(usageObject["input_tokens"]) + cacheRead + cacheWrite
    }

    /// JSON numbers decode as `NSNumber`; coerce to `Int` via doubleValue so a
    /// float-encoded integer doesn't truncate. Token counts stay under 2^53.
    private static func int(_ value: Any?) -> Int {
        guard let number = value as? NSNumber else { return 0 }
        return Int(number.doubleValue.rounded())
    }
}
