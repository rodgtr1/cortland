import Foundation
import CortlandTelemetryCore

/// Append-only JSONL history of per-session cost roll-ups, kept next to the
/// session snapshot (`~/.config/cortland/session-costs.jsonl`). One line per
/// record: written when a tab carrying telemetry closes (so its spend isn't lost
/// before quit) and once more at app termination for whatever remains. Capped at
/// `maxRecords` so a long-lived install can't grow it without bound.
enum SessionCostStore {
    private static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cortland/session-costs.jsonl")
    }

    /// Most recent records to keep; older ones are dropped on the next append.
    /// 500 short JSON objects is well under a megabyte — a sane size story for
    /// an append-only log.
    static let maxRecords = 500

    /// Appends one record, trimming the history to the newest `maxRecords`.
    /// A record with no billed tabs is skipped — there's nothing to log.
    static func append(_ record: SessionCostRecord) {
        guard !record.tabs.isEmpty, let line = record.jsonLine() else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            var lines = existingLines()
            lines.append(line)
            if lines.count > maxRecords {
                lines.removeFirst(lines.count - maxRecords)
            }
            let data = Data((lines.joined(separator: "\n") + "\n").utf8)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.error("failed to append session cost: \(error)", category: "session")
        }
    }

    /// Existing non-empty lines, or [] when the file is absent/unreadable.
    private static func existingLines() -> [String] {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// Reads the history back, skipping malformed lines. Used by tests; the app
    /// only appends.
    static func load() -> [SessionCostRecord] {
        existingLines().compactMap(SessionCostRecord.parse(jsonLine:))
    }
}
