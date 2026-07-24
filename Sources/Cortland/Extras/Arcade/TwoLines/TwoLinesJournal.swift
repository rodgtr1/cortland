import Foundation

/// The Two Lines journal is a plain markdown file the user owns outright —
/// greppable, editable, backed up like any other file. One list line per
/// entry, chronological, no metadata beyond the date:
///
///     - 2026-07-15 · **something round** — the ring stain my mug left on the desk pad
nonisolated enum TwoLinesJournal {
    static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cortland/two-lines.md")
    }

    private static let header = """
    # Two Lines

    Small observations, one or two lines at a time, collected between agent runs.

    """

    /// Appends one entry, creating the file (with its header) on first write.
    /// Internal newlines collapse to spaces so every entry stays a single
    /// markdown list line.
    static func append(prompt: String, entry: String, date: Date, to fileURL: URL = defaultFileURL) {
        let cleaned = entry
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !cleaned.isEmpty else { return }

        let line = "- \(dayStamp(for: date)) · **\(prompt)** — \(cleaned)\n"
        do {
            let existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            let content = existing.isEmpty ? header + "\n" + line : existing + line
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            Log.error("failed to append two-lines entry: \(error)", category: "arcade")
        }
    }

    /// The most recent entries, newest last — what the in-panel journal shows.
    static func recentEntries(limit: Int, from fileURL: URL = defaultFileURL) -> [String] {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let entries = content
            .components(separatedBy: .newlines)
            .filter { $0.hasPrefix("- ") }
        return Array(entries.suffix(limit))
    }

    /// A stable seed for every journal entry, used to grow the small trace in
    /// the game. The markdown remains the only source of truth: old entries
    /// appear automatically, and editing the file reshapes the trace.
    static func traceSeeds(from fileURL: URL = defaultFileURL) -> [UInt64] {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return traceSeeds(in: content)
    }

    static func traceSeeds(in content: String) -> [UInt64] {
        content.components(separatedBy: .newlines)
            .filter { $0.hasPrefix("- ") }
            .map(stableHash)
    }

    private static func stableHash(_ value: String) -> UInt64 {
        // FNV-1a is deliberately simple and stable across launches, unlike
        // Swift's randomized Hasher.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    static func dayStamp(for date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// Picks the next prompt while steering clear of recently seen ones, so a
/// dozen check-ins a day don't repeat. No other logic: prompts are never
/// "due" and nothing tracks completion.
nonisolated enum TwoLinesPromptPicker {
    static func pick(
        promptCount: Int,
        avoiding recent: [Int],
        using rng: inout some RandomNumberGenerator
    ) -> Int {
        let recentSet = Set(recent)
        let fresh = (0..<promptCount).filter { !recentSet.contains($0) }
        if let choice = fresh.randomElement(using: &rng) {
            return choice
        }
        return Int.random(in: 0..<promptCount, using: &rng)
    }

    /// How many recent prompts to remember: most of the library, but never
    /// so many that `pick` runs out of fresh choices.
    static func recentCapacity(promptCount: Int) -> Int {
        max(0, min(promptCount - 8, 80))
    }
}
