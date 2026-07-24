import Foundation

/// The field journal: a plain markdown file the user owns outright, the walk's
/// only keepsake. One list line per entry, in order, no metadata beyond the
/// place-marker step. Two kinds of line:
///
///     - step 460 · entered the birch wood, light rain
///     - step 482 · birch wood · a stone with a perfect white ring
nonisolated enum WalkJournal {
    static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cortland/the-walk.md")
    }

    private static let header = """
    # The Walk

    A field journal: what was found, and the first step into each new place.

    """

    /// Logs crossing into a new biome, e.g. "entered the moor, mist".
    static func recordBiomeEntry(step: Int, biome: WalkBiome, weather: WalkWeather, to fileURL: URL = defaultFileURL) {
        append(line: "- step \(step) · entered the \(biome.name), \(weather.name)", to: fileURL)
    }

    /// Logs a finding under the biome it was found in.
    static func recordFinding(step: Int, biome: WalkBiome, finding: String, to fileURL: URL = defaultFileURL) {
        append(line: "- step \(step) · \(biome.name) · \(finding)", to: fileURL)
    }

    /// The most recent entries, newest last, for the in-panel journal view.
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
            Log.error("failed to append walk journal entry: \(error)", category: "arcade")
        }
    }
}
