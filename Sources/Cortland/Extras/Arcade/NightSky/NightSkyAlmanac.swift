import Foundation

/// The almanac: a plain markdown file the user owns outright, and the only
/// thing Night Sky keeps. One section per named constellation, in order:
///
///     ## the kettle · 2026-07-16
///
///     ```
///     ·        *
///         *────*
///        ╱
///       *          ·
///     ```
///
///     seven stars, low in the west
///
/// Append-only from the game's side, and never read back for anything that
/// matters. If the user renames a shape, rewrites a sketch, or throws the file
/// out, nothing breaks and nothing is recounted: there is no count.
nonisolated enum NightSkyAlmanac {
    static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cortland/star-almanac.md")
    }

    private static let header = """
    # Night Sky

    Shapes noticed in an invented sky, and the names they were given.

    """

    private static let fence = "```"

    /// One constellation's section: the name and the night it was named, its
    /// sketch, and a line saying what is there.
    static func section(for constellation: NightSkyConstellation, sky: [NightSkyStar], dateStamp: String) -> String {
        let sketch = NightSkySketch.rows(path: constellation.path, sky: sky)
        var section = "## \(constellation.name) · \(dateStamp)\n\n"
        section += fence + "\n" + sketch.joined(separator: "\n") + "\n" + fence + "\n"
        section += "\n" + NightSkyProse.line(path: constellation.path, sky: sky) + "\n"
        return section
    }

    static func record(
        _ constellation: NightSkyConstellation,
        sky: [NightSkyStar],
        dateStamp: String,
        to fileURL: URL = defaultFileURL
    ) {
        let existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        let content = appending(
            section: section(for: constellation, sky: sky, dateStamp: dateStamp),
            to: existing
        )
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            Log.error("failed to append night sky almanac section: \(error)", category: "arcade")
        }
    }

    /// Adds one section below whatever is already there. Whatever that is: the
    /// file is the user's, and the almanac only ever writes at the end of it.
    static func appending(section: String, to existing: String) -> String {
        guard !existing.isEmpty else { return header + "\n" + section }
        var content = existing
        if !content.hasSuffix("\n") { content += "\n" }
        return content + "\n" + section
    }

    /// The local calendar day, which is what an evening means to the person
    /// looking at it.
    static func dayStamp(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
