import Foundation

/// The atlas: a plain markdown file the user owns, where each export appends a
/// dated section for the current sheet, its character map in a fenced block,
/// and the names placed on it. The map they draw a few strokes at a time
/// becomes a real file that grows in their own hands.
nonisolated enum CartographyAtlas {
    static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cortland/atlas.md")
    }

    private static let header = """
    # Atlas

    Sheets charted by hand, exported as they grow.

    """

    /// Appends one dated section for the sheet. Creates the file with its
    /// header on the first export.
    static func export(title: String, mapRows: [String], names: [CartographyName], date: Date, to fileURL: URL = defaultFileURL) {
        var section = "## \(title) · \(dayStamp(for: date))\n\n"
        section += "```\n" + mapRows.joined(separator: "\n") + "\n```\n"
        if !names.isEmpty {
            section += "\n" + names.map { "- \($0.text)" }.joined(separator: "\n") + "\n"
        }

        do {
            let existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            let content = existing.isEmpty ? header + "\n" + section : existing + "\n" + section
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            Log.error("failed to export atlas sheet: \(error)", category: "arcade")
        }
    }

    static func dayStamp(for date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
