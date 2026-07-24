import Foundation

/// Per-1M-token price for a model. Cache pricing is derived from the input rate
/// (reads ≈0.1×, 5-min writes 1.25×, 1-hour writes 2×), so only the two base
/// rates are stored.
public struct TelemetryRate: Equatable, Sendable {
    public let inputPerMTok: Double
    public let outputPerMTok: Double

    public init(inputPerMTok: Double, outputPerMTok: Double) {
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
    }
}

public enum TelemetryRates {
    /// Current Claude API rate card (USD per 1M tokens), keyed by model-id
    /// prefix. These drift between releases; `[telemetry.rates]` in `config.toml`
    /// layers over them so a price change is a config edit, not a rebuild.
    public static let defaults: [String: TelemetryRate] = [
        "claude-opus-4-8": TelemetryRate(inputPerMTok: 5, outputPerMTok: 25),
        "claude-opus-4-7": TelemetryRate(inputPerMTok: 5, outputPerMTok: 25),
        "claude-opus-4-6": TelemetryRate(inputPerMTok: 5, outputPerMTok: 25),
        "claude-sonnet-4-6": TelemetryRate(inputPerMTok: 3, outputPerMTok: 15),
        "claude-haiku-4-5": TelemetryRate(inputPerMTok: 1, outputPerMTok: 5),
        "claude-fable-5": TelemetryRate(inputPerMTok: 10, outputPerMTok: 50),
    ]

    /// Resolves a rate for `model`, tolerating date suffixes by matching the
    /// longest rate-card key that is a prefix of the model id (so
    /// `claude-haiku-4-5-20251001` resolves to the `claude-haiku-4-5` rate).
    public static func rate(
        forModel model: String?,
        rates: [String: TelemetryRate] = defaults
    ) -> TelemetryRate? {
        guard let model else { return nil }
        if let exact = rates[model] { return exact }
        return rates
            .filter { model.hasPrefix($0.key) }
            // Longest matching prefix wins; tie-break on the key so the result
            // is deterministic if two equal-length keys ever both match (e.g.
            // once rates load from config.toml).
            .max(by: { ($0.key.count, $0.key) < ($1.key.count, $1.key) })?
            .value
    }
}

public enum ContextWindow {
    /// The standard Claude context window.
    public static let standard = 200_000
    /// The opt-in 1M-token (beta) window.
    public static let extended = 1_000_000

    /// Best-effort context-window size for `model` given current `occupancy`.
    ///
    /// The transcript's model id (e.g. `claude-opus-4-8`) doesn't reliably carry
    /// the `[1m]` extended-context marker, so we can't always read the window off
    /// the name. We therefore default to the standard 200k and promote to 1M when
    /// either the id explicitly mentions `1m` or occupancy has already exceeded
    /// 200k — in which case the session must be running the extended window. This
    /// keeps the bar correct for 1M sessions once they cross 200k and clamps it
    /// otherwise; below 200k a 1M session reads against the 200k cap, which only
    /// over-reports early in a session.
    public static func tokens(forModel model: String?, occupancy: Int) -> Int {
        if let model, model.lowercased().contains("1m") { return extended }
        return occupancy > standard ? extended : standard
    }
}

public extension TranscriptUsage {
    /// Fraction (0...1) of the context window currently occupied, or nil when no
    /// billed assistant turn has been seen yet (nothing to show). Clamped so a
    /// mis-sized window can never drive a bar past full.
    func contextFraction() -> Double? {
        guard contextTokens > 0 else { return nil }
        let window = ContextWindow.tokens(forModel: model, occupancy: contextTokens)
        guard window > 0 else { return nil }
        return min(1.0, max(0.0, Double(contextTokens) / Double(window)))
    }

    /// Estimated USD cost for this usage under `rates`. Cache reads bill ≈0.1×
    /// the input rate; 5-minute cache writes 1.25×, 1-hour writes 2×. Returns
    /// nil when the model has no known rate (e.g. a non-Claude agent), so the
    /// dashboard can show tokens without a misleading "$0.00".
    func estimatedCostUSD(rates: [String: TelemetryRate] = TelemetryRates.defaults) -> Double? {
        // An agent-reported cost (Pi) is authoritative — no rate card needed.
        if let reportedCostUSD { return reportedCostUSD }
        guard let rate = TelemetryRates.rate(forModel: model, rates: rates) else { return nil }
        let inRate = rate.inputPerMTok / 1_000_000
        let outRate = rate.outputPerMTok / 1_000_000
        return Double(inputTokens) * inRate
            + Double(outputTokens) * outRate
            + Double(cacheReadTokens) * 0.1 * inRate
            + Double(cacheCreation5mTokens) * 1.25 * inRate
            + Double(cacheCreation1hTokens) * 2.0 * inRate
    }
}
