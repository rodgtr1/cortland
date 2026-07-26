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
    /// Ceiling on the extracted text one index holds: 32 million characters,
    /// roughly 64 MB resident. A machine with years of sessions can hold far
    /// more prose than anyone wants an opt-in panel to keep alive, so indexing
    /// stops here and the panel says so rather than quietly searching a subset.
    /// Sessions are indexed newest-first, so the budget is spent on the ones
    /// most likely to be looked for.
    static let maxIndexCharacters = 32_000_000

    /// Ceiling on the sessions one search inspects. Well above the number of
    /// sessions any index holds in practice; it exists so a pathological index
    /// can't make a keystroke's search unbounded.
    static let maxSessionsPerSearch = 20_000

    /// An immutable in-memory body-text index keyed by log path. Built off-main
    /// once, searched many times, never written to disk.
    nonisolated struct Index: Sendable, Equatable {
        var linesByPath: [String: [String]]
        /// Log paths whose own file budget ran out, so their text is partial.
        var truncatedPaths: Set<String>
        /// Sessions the index-wide budget left out entirely. Non-zero means a
        /// search cannot claim to have covered everything.
        var skippedSessions: Int

        /// True when the index is not a complete picture of the sessions it was
        /// built for — some file was truncated, or some session never made it in.
        var isPartial: Bool { skippedSessions > 0 || !truncatedPaths.isEmpty }

        init(
            linesByPath: [String: [String]] = [:],
            truncatedPaths: Set<String> = [],
            skippedSessions: Int = 0
        ) {
            self.linesByPath = linesByPath
            self.truncatedPaths = truncatedPaths
            self.skippedSessions = skippedSessions
        }
    }

    /// What one query found, and whether it saw everything. `isCapped` means
    /// `matches` is a floor: the search stopped at a limit with sessions left
    /// unexamined, so the panel must not present the count as a total.
    nonisolated struct Results: Sendable, Equatable {
        var matches: [SessionDeepMatch] = []
        /// Sessions actually examined.
        var scanned = 0
        /// True when a limit ended the scan early.
        var isCapped = false
    }

    /// Load and extract every session's body text into an in-memory index.
    /// Intended to run on a background queue.
    ///
    /// `records` is consumed in the order given (the panel passes newest-first)
    /// and stops once `characterBudget` is spent, so the sessions that make it
    /// in are the ones most likely to be searched for.
    static func buildIndex(
        for records: [SessionRecord],
        characterBudget: Int = maxIndexCharacters
    ) -> Index {
        var index = Index()
        var spent = 0
        for record in records where index.linesByPath[record.logPath] == nil {
            guard spent < characterBudget else {
                index.skippedSessions += 1
                continue
            }
            let extraction = SessionBodyText.extract(at: URL(fileURLWithPath: record.logPath))
            // Trim to what's left of the budget before storing, so the budget
            // bounds the index itself. Trimming afterwards would let the very
            // first transcript overshoot it by its whole length.
            let (lines, keptAll) = fitting(extraction.lines, into: characterBudget - spent)
            index.linesByPath[record.logPath] = lines
            if extraction.isTruncated || !keptAll {
                index.truncatedPaths.insert(record.logPath)
            }
            spent += lines.reduce(0) { $0 + $1.count }
        }
        return index
    }

    /// The longest prefix of `lines` whose combined length fits in `budget`,
    /// plus whether that was all of them. A line that only partly fits is cut
    /// with `String.prefix`, which counts Characters — so a grapheme cluster is
    /// never split into mojibake the way a byte-wise cut would.
    private static func fitting(_ lines: [String], into budget: Int) -> (lines: [String], keptAll: Bool) {
        guard budget > 0 else { return ([], lines.isEmpty) }
        var kept: [String] = []
        var remaining = budget
        for line in lines {
            guard line.count <= remaining else {
                // This line only partly fits (possibly not at all): keep what
                // there's room for and stop.
                if remaining > 0 { kept.append(String(line.prefix(remaining))) }
                return (kept, false)
            }
            kept.append(line)
            remaining -= line.count
        }
        return (kept, true)
    }

    /// Find the records whose body contains `phrase`, in the input order
    /// (callers pass a newest-first list), each with a snippet around the first
    /// hit. `phrase` is whitespace-collapsed and lowercased, then matched as a
    /// contiguous substring — so multi-word phrases only match contiguous text.
    ///
    /// - Parameters:
    ///   - limit: stop after this many matches. The result is marked capped
    ///     only if sessions were left unexamined when it stopped.
    ///   - sessionLimit: stop after examining this many sessions.
    static func search(
        _ phrase: String,
        in records: [SessionRecord],
        index: Index,
        limit: Int? = nil,
        sessionLimit: Int = maxSessionsPerSearch
    ) -> Results {
        let needle = phrase
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
        guard !needle.isEmpty else { return Results() }

        var results = Results()
        for record in records {
            if results.scanned >= sessionLimit {
                results.isCapped = true
                break
            }
            results.scanned += 1
            guard let lines = index.linesByPath[record.logPath] else { continue }
            for line in lines {
                guard let range = line.range(of: needle) else { continue }
                results.matches.append(
                    SessionDeepMatch(record: record, snippet: snippet(from: line, around: range))
                )
                break   // first hit is enough for a row snippet.
            }
            if let limit, results.matches.count >= limit {
                // Capped only if there was more to look at — a limit reached on
                // the last record searched everything there was.
                results.isCapped = results.scanned < records.count
                break
            }
        }
        return results
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
