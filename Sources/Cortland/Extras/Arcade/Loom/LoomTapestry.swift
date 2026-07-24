import Foundation

/// How a settled panel reduces to one row of cloth: one glyph per board column,
/// shaded by how much thread that column carries. Stub counts do not change
/// when a tile turns, so the row a panel will weave is fixed the moment it is
/// dealt; settling it is what decides whether it gets woven at all.
nonisolated enum LoomWeave {
    /// Every row is this wide whatever the panel's side, so the bolts hang
    /// straight down the file. Narrow panels sit centered in their row.
    static let width = 8

    /// Shade blocks rather than box-drawing: at one glyph per column they read
    /// as cloth with a grain, where `─ ┄ ┼ ╬` reads as a diagram of a board.
    static let glyphs: [Character] = ["░", "▒", "▓", "█"]

    static func row(for panel: LoomPanel) -> String {
        let cells = (0..<panel.side).map { col in
            glyph(forAverageStubs: averageStubs(in: panel, col: col))
        }
        let padding = max(0, width - panel.side)
        let left = padding / 2
        return String(repeating: " ", count: left)
            + String(cells)
            + String(repeating: " ", count: padding - left)
    }

    static func averageStubs(in panel: LoomPanel, col: Int) -> Double {
        let total = (0..<panel.side).reduce(0) { sum, row in
            sum + panel.tile(row: row, col: col).stubs.nonzeroBitCount
        }
        return Double(total) / Double(panel.side)
    }

    /// Thresholds sit around the two-stubs-per-tile the generator tends toward,
    /// so an ordinary panel weaves a row with grain in it rather than a flat
    /// band of one glyph.
    static func glyph(forAverageStubs average: Double) -> Character {
        switch average {
        case ..<1.5: return glyphs[0]
        case ..<2.0: return glyphs[1]
        case ..<2.5: return glyphs[2]
        default: return glyphs[3]
        }
    }
}

/// The tapestry: a plain markdown file the user owns outright, and the loom's
/// only keepsake. One fenced bolt of cloth per month, one row per settled
/// panel, newest at the bottom:
///
///     ## 2026-07
///
///     ```
///      ▒▓▒░▓▒
///       ░▓█▓▒
///     ```
///
/// Append-only from the game's side. If the user rewrites it, prunes it, or
/// deletes it, nothing breaks and no count moves: panels woven lives in the
/// state blob, and the file is only ever read back to show recent rows.
nonisolated enum LoomTapestry {
    static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cortland/loom-tapestry.md")
    }

    private static let header = """
    # Loom

    One row of cloth per panel that settled. A bolt per month.

    """

    private static let fence = "```"

    static func record(_ panel: LoomPanel, date: Date, to fileURL: URL = defaultFileURL) {
        record(row: LoomWeave.row(for: panel), date: date, to: fileURL)
    }

    static func record(row: String, date: Date, to fileURL: URL = defaultFileURL) {
        let existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        let content = appending(row: row, month: monthStamp(for: date), to: existing)
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            Log.error("failed to append loom tapestry row: \(error)", category: "arcade")
        }
    }

    /// Adds one row to the running bolt, or opens a new one when the month has
    /// turned. A file whose last bolt has been closed off or reshaped by hand
    /// is not repaired: a fresh bolt simply starts below whatever is there.
    static func appending(row: String, month: String, to existing: String) -> String {
        let heading = "## \(month)"
        guard !existing.isEmpty else {
            return header + "\n" + heading + "\n\n" + fence + "\n" + row + "\n" + fence + "\n"
        }

        var content = existing
        if !content.hasSuffix("\n") { content += "\n" }
        if lastHeading(in: content) == heading, content.hasSuffix(fence + "\n") {
            content.removeLast(fence.count + 1)
            return content + row + "\n" + fence + "\n"
        }
        return content + "\n" + heading + "\n\n" + fence + "\n" + row + "\n" + fence + "\n"
    }

    /// The most recent rows, newest last, for the in-panel tapestry view.
    static func recentRows(limit: Int, from fileURL: URL = defaultFileURL) -> [String] {
        Array(rows(in: contents(of: fileURL)).map(\.row).suffix(limit))
    }

    /// How many rows are in the current month's bolt. Read off the file, so a
    /// tapestry the user has trimmed reports what it actually holds.
    static func rowCount(forMonth month: String, from fileURL: URL = defaultFileURL) -> Int {
        rows(in: contents(of: fileURL)).filter { $0.month == month }.count
    }

    /// Rows are recognised by their shape rather than by trusting the fences:
    /// a line of nothing but weave glyphs and padding is a row, and anything
    /// else in the file is the user's business.
    static func rows(in content: String) -> [(month: String, row: String)] {
        var found: [(month: String, row: String)] = []
        var month = ""
        for line in content.components(separatedBy: .newlines) {
            if line.hasPrefix("## ") {
                month = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard isRow(line) else { continue }
            found.append((month, line))
        }
        return found
    }

    static func isRow(_ line: String) -> Bool {
        let glyphs = Set(LoomWeave.glyphs)
        var sawGlyph = false
        for character in line {
            if glyphs.contains(character) {
                sawGlyph = true
            } else if character != " " {
                return false
            }
        }
        return sawGlyph
    }

    static func monthStamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }

    private static func contents(of fileURL: URL) -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    private static func lastHeading(in content: String) -> String? {
        content.components(separatedBy: .newlines)
            .last { $0.hasPrefix("## ") }?
            .trimmingCharacters(in: .whitespaces)
    }
}
