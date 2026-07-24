import Foundation

/// Parses a Pi session JSONL (`~/.pi/agent/sessions/<project>/*.jsonl`) into the
/// shared `TranscriptUsage`. Pi's schema is the richest of the three: each
/// assistant `message` carries a per-turn `usage` with separate `input`
/// (fresh), `output`, `cacheRead`, `cacheWrite`, and a nested `cost` object Pi
/// computes itself. Usage is per-message, so it sums (like Claude); the summed
/// `cost.total` is carried as `reportedCostUSD`, which the dashboard prefers
/// over the rate card — so a Pi pane shows an accurate $ even though its model
/// isn't in the built-in Claude rate card.
public enum PiTranscriptParser {
    public static func aggregate<S: StringProtocol>(jsonl: S) -> TranscriptUsage {
        var acc = Accumulator()
        for rawLine in jsonl.split(separator: "\n", omittingEmptySubsequences: true) {
            ingest(Data(rawLine.utf8), into: &acc)
        }
        return acc.finalized()
    }

    /// Aggregates the session file at `path`, or nil if it can't be read.
    /// Streams the file (see `TranscriptLineReader`) so a large Pi session
    /// doesn't load whole into memory on every Stop hook (P5).
    public static func aggregate(contentsOfFile path: String) -> TranscriptUsage? {
        var acc = Accumulator()
        guard TranscriptLineReader.forEachLine(inFileAt: path, { ingest($0, into: &acc) })
        else { return nil }
        return acc.finalized()
    }

    /// Running state: the base usage plus Pi's self-reported cost, which is only
    /// surfaced when at least one turn carried a `cost` block.
    private struct Accumulator {
        var usage = TranscriptUsage()
        var totalCost = 0.0
        var sawCost = false

        func finalized() -> TranscriptUsage {
            var result = usage
            if sawCost { result.reportedCostUSD = totalCost }
            return result
        }
    }

    /// Folds one JSONL line's bytes into `acc`. Shared by the string and
    /// streaming entry points so they can't diverge.
    private static func ingest(_ lineData: Data, into acc: inout Accumulator) {
        guard let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              object["type"] as? String == "message",
              let message = object["message"] as? [String: Any],
              let role = message["role"] as? String
        else { return }

        // Pi gives tool results their own `toolResult` role, so every
        // `user` message is a genuine prompt (content may be a string or an
        // array of blocks).
        if role == "user" {
            acc.usage.userPrompts += 1
            return
        }

        guard role == "assistant",
              let turn = message["usage"] as? [String: Any] else { return }

        acc.usage.assistantResponses += 1
        if let model = message["model"] as? String { acc.usage.model = model }
        let turnInput = int(turn["input"])               // fresh input (excludes cacheRead)
        let turnCacheRead = int(turn["cacheRead"])
        let turnCacheWrite = int(turn["cacheWrite"])
        acc.usage.inputTokens += turnInput
        acc.usage.outputTokens += int(turn["output"])
        acc.usage.cacheReadTokens += turnCacheRead
        acc.usage.cacheCreation5mTokens += turnCacheWrite

        // Context occupancy = this turn's full input footprint (last wins).
        acc.usage.contextTokens = turnInput + turnCacheRead + turnCacheWrite

        if let cost = turn["cost"] as? [String: Any], let total = double(cost["total"]) {
            acc.totalCost += total
            acc.sawCost = true
        }
    }

    // Round via doubleValue so float-encoded integers (e.g. `1.5e6`, `12345.0`,
    // which some emitters produce) don't truncate. Token counts stay well under
    // 2^53, so this is exact.
    private static func int(_ value: Any?) -> Int {
        guard let number = value as? NSNumber else { return 0 }
        return Int(number.doubleValue.rounded())
    }
    private static func double(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
}
