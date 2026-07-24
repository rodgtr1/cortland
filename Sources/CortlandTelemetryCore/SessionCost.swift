import Foundation

/// One tab's telemetry contribution to a session cost record: the agent's model,
/// total tokens billed, and estimated USD (nil when the model has no known rate,
/// mirroring `estimatedCostUSD`). Pure value type so the summing/serialization is
/// unit-testable away from the main-actor UI that produces it.
public struct SessionTabCost: Codable, Equatable, Sendable {
    public let title: String
    public let model: String?
    public let tokens: Int
    public let costUSD: Double?

    public init(title: String, model: String?, tokens: Int, costUSD: Double?) {
        self.title = title
        self.model = model
        self.tokens = tokens
        self.costUSD = costUSD
    }
}

/// A single session's aggregated cost, appended one-per-record to the JSONL
/// history (`session-costs.jsonl`). Totals are summed from `tabs` at
/// construction so a reader never has to re-derive them, and tabs with an
/// unknown rate (nil `costUSD`) still contribute their tokens.
public struct SessionCostRecord: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let tabs: [SessionTabCost]
    public let totalCostUSD: Double
    public let totalTokens: Int

    public init(timestamp: Date, tabs: [SessionTabCost]) {
        self.timestamp = timestamp
        self.tabs = tabs
        self.totalCostUSD = tabs.compactMap(\.costUSD).reduce(0, +)
        self.totalTokens = tabs.map(\.tokens).reduce(0, +)
    }

    /// ISO-8601 timestamps keep the JSONL human-readable (and stable across
    /// locales) rather than the reference-date doubles `JSONEncoder` defaults to.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// One newline-free JSON object for the JSONL history, or nil if encoding
    /// fails. The caller appends the record separator.
    public func jsonLine() -> String? {
        guard let data = try? Self.encoder.encode(self),
              let line = String(data: data, encoding: .utf8) else { return nil }
        return line
    }

    /// Parses one JSONL line back into a record, or nil if it's blank/malformed
    /// (a truncated last line shouldn't fail the whole read).
    public static func parse(jsonLine: String) -> SessionCostRecord? {
        let trimmed = jsonLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return try? decoder.decode(SessionCostRecord.self, from: data)
    }
}
