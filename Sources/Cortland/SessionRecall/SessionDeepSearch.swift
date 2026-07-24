import Foundation

/// One deep-search hit: the matched session plus a short snippet of the line
/// where the phrase occurs, so the panel can show the *context* that matched
/// instead of the usual "agent · repo · age" subtitle.
nonisolated struct SessionDeepMatch: Sendable, Equatable {
    let record: SessionRecord
    /// ~80-char window centered on the match, trimmed with ellipses.
    let snippet: String
}

/// The opt-in, in-memory deep search for Session Recall: build an index of
/// every session's body text (via `SessionBodyText`), hold it for the panel's
/// lifetime, and answer phrase queries with a matching snippet.
///
/// `nonisolated` and stateless so the (expensive) index build runs off the main
/// thread; the resulting `Index` is an immutable `Sendable` value handed back to
/// the main actor. Nothing is persisted — the index is dropped when the panel
/// releases it (i.e. when it closes). Phrase matching is a plain
/// case-insensitive substring test, so "npm install pnpm" matches literally.
nonisolated enum SessionDeepSearch {
    /// An immutable in-memory body-text index keyed by log path. Built off-main
    /// once, searched many times, never written to disk.
    nonisolated struct Index: Sendable, Equatable {
        var linesByPath: [String: [String]]

        init(linesByPath: [String: [String]] = [:]) {
            self.linesByPath = linesByPath
        }
    }

    /// Load and extract every session's body text into an in-memory index.
    /// Intended to run on a background queue.
    static func buildIndex(for records: [SessionRecord]) -> Index {
        var linesByPath: [String: [String]] = [:]
        for record in records where linesByPath[record.logPath] == nil {
            linesByPath[record.logPath] = SessionBodyText.extractLines(
                at: URL(fileURLWithPath: record.logPath)
            )
        }
        return Index(linesByPath: linesByPath)
    }

    /// Return the records whose body contains `phrase`, in the input order
    /// (callers pass a newest-first list), each with a snippet around the first
    /// hit. `phrase` is whitespace-collapsed and lowercased, then matched as a
    /// contiguous substring — so multi-word phrases only match contiguous text.
    static func search(
        _ phrase: String,
        in records: [SessionRecord],
        index: Index,
        limit: Int? = nil
    ) -> [SessionDeepMatch] {
        let needle = phrase
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
        guard !needle.isEmpty else { return [] }

        var matches: [SessionDeepMatch] = []
        for record in records {
            guard let lines = index.linesByPath[record.logPath] else { continue }
            for line in lines {
                guard let range = line.range(of: needle) else { continue }
                matches.append(SessionDeepMatch(record: record, snippet: snippet(from: line, around: range)))
                break   // first hit is enough for a row snippet.
            }
            if let limit, matches.count >= limit { break }
        }
        return matches
    }

    /// A ~80-char window centered on the match, with leading/trailing ellipses
    /// when the line extends past the window.
    private static func snippet(from line: String, around match: Range<String.Index>, window: Int = 80) -> String {
        let total = line.count
        if total <= window { return line }

        let matchStart = line.distance(from: line.startIndex, to: match.lowerBound)
        let matchLength = line.distance(from: match.lowerBound, to: match.upperBound)

        // Center the window on the match, then clamp into range.
        var start = max(0, matchStart - (window - min(matchLength, window)) / 2)
        var end = min(total, start + window)
        start = max(0, end - window)
        end = min(total, start + window)

        let startIndex = line.index(line.startIndex, offsetBy: start)
        let endIndex = line.index(line.startIndex, offsetBy: end)
        var snippet = String(line[startIndex..<endIndex])
        if start > 0 { snippet = "…" + snippet }
        if end < total { snippet += "…" }
        return snippet
    }
}
