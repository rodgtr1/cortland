import Foundation

/// The almanac: a plain markdown file the user owns outright, and the pond's
/// only keepsake. One list line per catch, in order:
///
///     - 2026-07-16 · **largemouth bass** — a forearm's length, unhurried · line out 4 h · first
///
/// Append-only from the game's side. If the user rewrites it, prunes it, or
/// deletes it, the pond does not care and never reads it back for anything
/// that matters: the distinct-species count lives in the state blob.
nonisolated enum PondAlmanac {
    static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cortland/pond-almanac.md")
    }

    private static let header = """
    # The Pond

    An almanac: what came up, and how long the line had been out.

    """

    static func line(for catch_: PondCatch, date: Date) -> String {
        var line = "- \(day(date)) · **\(catch_.name)** — \(catch_.size)"
        line += " · line out \(PondModel.durationPhrase(catch_.elapsed))"
        if catch_.isFirst { line += " · first" }
        return line
    }

    static func record(_ catch_: PondCatch, date: Date, to fileURL: URL = defaultFileURL) {
        append(line: line(for: catch_, date: date), to: fileURL)
    }

    /// The most recent entries, newest last, for the in-panel almanac.
    static func recentEntries(limit: Int, from fileURL: URL = defaultFileURL) -> [String] {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let entries = content
            .components(separatedBy: .newlines)
            .filter { $0.hasPrefix("- ") }
        return Array(entries.suffix(limit))
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
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
            Log.error("failed to append pond almanac entry: \(error)", category: "arcade")
        }
    }
}
