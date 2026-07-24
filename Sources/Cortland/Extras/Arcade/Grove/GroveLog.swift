import Foundation

/// A quiet, plain-markdown record of the groves a person has kept: one line
/// when a tree is planted, one when an old grove is let go. It is the user's
/// file, greppable and editable like any other, so the "look back after a
/// month" is not locked inside a state blob. The living tree itself lives in
/// the arcade state; this is just the memory of what came before.
nonisolated enum GroveLog {
    static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cortland/grove.md")
    }

    private static let header = """
    # The Grove

    A record of the trees kept here, planted and let go, one line at a time.

    """

    static func recordPlanting(species: GroveSpecies, date: Date, to fileURL: URL = defaultFileURL) {
        append(line: "- \(dayStamp(for: date)) · planted a \(species.displayName)", to: fileURL)
    }

    static func recordClearing(species: GroveSpecies?, date: Date, to fileURL: URL = defaultFileURL) {
        let what = species.map { "let the \($0.displayName) go" } ?? "cleared the plot"
        append(line: "- \(dayStamp(for: date)) · \(what)", to: fileURL)
    }

    /// The most recent lines, newest last, for anyone who wants to look back.
    static func recentEntries(limit: Int, from fileURL: URL = defaultFileURL) -> [String] {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let entries = content
            .components(separatedBy: .newlines)
            .filter { $0.hasPrefix("- ") }
        return Array(entries.suffix(limit))
    }

    private static func append(line: String, to fileURL: URL) {
        do {
            let existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            let content = existing.isEmpty ? header + "\n" + line + "\n" : existing + line + "\n"
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            Log.error("failed to append grove log entry: \(error)", category: "arcade")
        }
    }

    static func dayStamp(for date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
