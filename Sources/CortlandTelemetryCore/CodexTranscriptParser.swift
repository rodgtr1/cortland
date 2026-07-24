import Foundation

/// Parses a Codex rollout JSONL (`~/.codex/sessions/Y/M/D/rollout-*.jsonl`) into
/// the shared `TranscriptUsage`. Codex's schema differs from Claude's:
///
///  - the model is on `turn_context.payload.model`;
///  - token usage rides `event_msg` payloads of `type: "token_count"`, whose
///    `info.total_token_usage` is **cumulative**, so the last one is the session
///    total. There `input_tokens` already includes `cached_input_tokens`
///    (OpenAI's cache reads), and `input + output == total`, so reasoning tokens
///    are already inside `output_tokens`. Codex doesn't bill cache writes.
public enum CodexTranscriptParser {
    public static func aggregate<S: StringProtocol>(jsonl: S) -> TranscriptUsage {
        var acc = Accumulator()
        for rawLine in jsonl.split(separator: "\n", omittingEmptySubsequences: true) {
            ingest(Data(rawLine.utf8), into: &acc)
        }
        return acc.finalized()
    }

    /// Aggregates the rollout file at `path`, or nil if it can't be read.
    /// Streams the file (see `TranscriptLineReader`) so a large Codex rollout
    /// doesn't load whole into memory on every Stop hook (P5).
    public static func aggregate(contentsOfFile path: String) -> TranscriptUsage? {
        var acc = Accumulator()
        guard TranscriptLineReader.forEachLine(inFileAt: path, { ingest($0, into: &acc) })
        else { return nil }
        return acc.finalized()
    }

    /// Running state: counts and model accrue as lines are read, while the
    /// cumulative and per-turn token blocks are last-wins and resolved at the end.
    private struct Accumulator {
        var usage = TranscriptUsage()
        var latestTotal: [String: Any]?
        var latestTurn: [String: Any]?

        func finalized() -> TranscriptUsage {
            var result = usage
            if let total = latestTotal {
                let input = int(total["input_tokens"])
                let cached = int(total["cached_input_tokens"])
                result.inputTokens = max(0, input - cached)   // fresh (uncached) input
                result.cacheReadTokens = cached
                result.outputTokens = int(total["output_tokens"])
            }
            // Context occupancy = the last turn's input (Codex's `input_tokens`
            // already folds in `cached_input_tokens`), i.e. the prompt size sent
            // for the most recent turn. Falls back to the cumulative total when
            // only that's present (older rollouts had no `last_token_usage`).
            if let last = latestTurn {
                result.contextTokens = int(last["input_tokens"])
            } else if let total = latestTotal {
                result.contextTokens = int(total["input_tokens"])
            }
            return result
        }
    }

    /// Folds one JSONL line's bytes into `acc`. Shared by the string and
    /// streaming entry points so they can't diverge.
    private static func ingest(_ lineData: Data, into acc: inout Accumulator) {
        guard let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
        else { return }

        let type = object["type"] as? String
        let payload = object["payload"] as? [String: Any]

        // The model can change mid-session; keep the most recent.
        if type == "turn_context", let model = payload?["model"] as? String {
            acc.usage.model = model
        }

        guard type == "event_msg", let payload else { return }
        switch payload["type"] as? String {
        case "user_message":
            acc.usage.userPrompts += 1
        case "token_count":
            acc.usage.assistantResponses += 1
            if let info = payload["info"] as? [String: Any] {
                if let total = info["total_token_usage"] as? [String: Any] {
                    acc.latestTotal = total   // cumulative — last wins
                }
                // Per-turn usage drives context occupancy (last wins).
                if let last = info["last_token_usage"] as? [String: Any] {
                    acc.latestTurn = last
                }
            }
        default:
            break
        }
    }

    // Round via doubleValue so float-encoded integers don't truncate; token
    // counts stay well under 2^53, so this is exact.
    private static func int(_ value: Any?) -> Int {
        guard let number = value as? NSNumber else { return 0 }
        return Int(number.doubleValue.rounded())
    }
}
