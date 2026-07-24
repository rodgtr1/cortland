import Foundation

/// The accretion: one plain markdown file per month, in the user's own
/// directory, that reads like a journal when scrolled. The game only ever
/// appends. It never re-parses these files for state, so editing an entry,
/// rewriting a month, or deleting the lot is entirely the user's business and
/// costs nothing.
///
///     ## 2026-07-16 2:32 PM · create
///     > Describe an imaginary shop you would visit but never work in.
///     > (350 characters, used 287)
///
///     The text of the entry, as written, paragraphs preserved.
///
/// The header is structured (date, pool, prompt, counts) and every block
/// starts with `## `, so a future rediscovery feature could split a month into
/// entries without a parser. That is the only reason for the shape; none of it
/// ships, and the format must not grow metadata beyond what is shown here.
nonisolated enum JournalFile {
    static var directoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cortland/journal")
    }

    /// `2026-07.md`: the month the entry was written in, in the local
    /// calendar, so a year boundary just rolls over to `2027-01.md`.
    static func fileName(for date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d.md", parts.year ?? 0, parts.month ?? 0)
    }

    static func fileURL(for date: Date, in directory: URL = directoryURL) -> URL {
        directory.appendingPathComponent(fileName(for: date))
    }

    /// `2026-07-16 2:32 PM`, built by hand rather than through a DateFormatter
    /// so it neither drifts with the user's locale nor varies between runs.
    static func stamp(for date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let hour = parts.hour ?? 0
        let hour12 = hour % 12 == 0 ? 12 : hour % 12
        return String(
            format: "%04d-%02d-%02d %d:%02d %@",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            hour12, parts.minute ?? 0, hour < 12 ? "AM" : "PM"
        )
    }

    static func dayStamp(for date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// One entry, formatted. Overage reads "(350 characters, used 402)" and
    /// gets no further comment: the count is a fact about the entry, not a
    /// verdict on it.
    static func block(prompt: JournalPrompt, entry: String, date: Date) -> String {
        let text = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        let used = JournalModel.count(text, unit: prompt.unit)
        return """
        ## \(stamp(for: date)) · \(prompt.pool.rawValue)
        > \(prompt.text)
        > (\(prompt.limit) \(prompt.unit.label), used \(used))

        \(text)

        """
    }

    private static func header(for date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month], from: date)
        return """
        # Journal · \(String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0))

        Bounded writing, one small finished thing at a time, between agent runs.

        """
    }

    /// Appends one entry to its month, creating the file and directory on
    /// first write. A user-edited file that has lost its trailing newline is
    /// not a problem worth mentioning to anyone: the separator is normalized
    /// and the entry lands underneath whatever is already there.
    @discardableResult
    static func append(prompt: JournalPrompt, entry: String, date: Date, to fileURL: URL? = nil) -> URL? {
        let url = fileURL ?? Self.fileURL(for: date)
        let text = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let content: String
        if existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content = header(for: date) + "\n" + block(prompt: prompt, entry: text, date: date)
        } else {
            let base = existing.hasSuffix("\n") ? existing : existing + "\n"
            content = base + "\n" + block(prompt: prompt, entry: text, date: date)
        }
        return write(content, to: url) ? url : nil
    }

    /// Adds the optional feel line under the entry just written. It is for the
    /// author to grep one day if they ever want to test their own hypothesis
    /// about what these breaks do; the game never reads it back.
    static func appendFeeling(_ feeling: String, to fileURL: URL) {
        guard var content = try? String(contentsOf: fileURL, encoding: .utf8), !content.isEmpty else { return }
        while content.hasSuffix("\n\n") {
            content.removeLast()
        }
        if !content.hasSuffix("\n") {
            content += "\n"
        }
        _ = write(content + "felt: \(feeling)\n", to: fileURL)
    }

    /// The month's entries, newest first, for the browse view. This is a
    /// window onto the markdown, not a source of truth: whatever the file
    /// says, including the user's own edits, is what shows.
    static func recentBlocks(limit: Int, from fileURL: URL) -> [String] {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return Array(blocks(in: content).reversed().prefix(limit))
    }

    /// Splits a month into entries on the `## ` header, oldest first. Anything
    /// above the first header (the file's own title, or whatever the user has
    /// put there) is not an entry and is left out.
    static func blocks(in content: String) -> [String] {
        var blocks: [String] = []
        var current: [String]?

        func close() {
            if let lines = current {
                blocks.append(lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        for line in content.components(separatedBy: .newlines) {
            if line.hasPrefix("## ") {
                close()
                current = [line]
            } else {
                current?.append(line)
            }
        }
        close()
        return blocks
    }

    private static func write(_ content: String, to fileURL: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            Log.error("failed to append journal entry: \(error)", category: "arcade")
            return false
        }
    }
}
