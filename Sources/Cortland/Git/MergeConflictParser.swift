import Foundation

/// One `<<<<<<< / ======= / >>>>>>>` conflict block found in a file.
/// Ranges are UTF-16 offsets so they map directly onto `NSTextView`/`NSString`.
nonisolated struct MergeConflict: Equatable, Sendable {
    /// The whole block, from the start of the `<<<<<<<` line through the end
    /// of the `>>>>>>>` line (including that line's trailing newline, if any).
    let fullRange: NSRange
    /// The "current"/ours content between `<<<<<<<` and `=======`
    /// (or `|||||||` in a 3-way conflict). Length 0 when that side is empty.
    let currentRange: NSRange
    /// The "incoming"/theirs content between `=======` and `>>>>>>>`.
    let incomingRange: NSRange
    /// The `<<<<<<<` marker line itself (without its newline), used to anchor
    /// the inline action buttons.
    let openingMarkerLineRange: NSRange
    /// The `=======` separator line (without its newline).
    let separatorMarkerLineRange: NSRange
    /// The `>>>>>>>` marker line (without its newline).
    let closingMarkerLineRange: NSRange
    /// Text after `<<<<<<<`, e.g. "HEAD".
    let currentLabel: String
    /// Text after `>>>>>>>`, e.g. "703c621 (main)".
    let incomingLabel: String
}

enum MergeConflictResolution {
    case current, incoming, both
}

nonisolated enum MergeConflictParser {
    /// Scans `text` for conflict blocks. Partial/unterminated blocks are
    /// ignored, so a stray `<<<<<<<` in a string literal never half-matches.
    static func conflicts(in text: String) -> [MergeConflict] {
        let ns = text as NSString
        var result: [MergeConflict] = []

        // Accumulators for the block currently being parsed.
        var openingLineRange: NSRange?
        var separatorLineRange: NSRange?
        var currentLabel = ""
        var currentLines: [NSRange] = []
        var incomingLines: [NSRange] = []
        // 0 = outside, 1 = current (ours), 2 = base (3-way, ignored), 3 = incoming
        var section = 0

        func reset() {
            openingLineRange = nil
            separatorLineRange = nil
            currentLabel = ""
            currentLines = []
            incomingLines = []
            section = 0
        }

        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length),
            options: [.byLines]
        ) { substring, substringRange, enclosingRange, _ in
            let line = substring ?? ""

            if line.hasPrefix("<<<<<<<") {
                // A new opener abandons any half-parsed previous block.
                reset()
                openingLineRange = substringRange
                currentLabel = Self.label(after: 7, in: line)
                section = 1
            } else if line.hasPrefix("|||||||"), section == 1 {
                section = 2
            } else if line.hasPrefix("======="), section == 1 || section == 2 {
                separatorLineRange = substringRange
                section = 3
            } else if line.hasPrefix(">>>>>>>"), section == 3,
                      let opening = openingLineRange, let separator = separatorLineRange {
                let fullRange = NSRange(
                    location: opening.location,
                    length: NSMaxRange(enclosingRange) - opening.location
                )
                result.append(MergeConflict(
                    fullRange: fullRange,
                    currentRange: Self.union(currentLines),
                    incomingRange: Self.union(incomingLines),
                    openingMarkerLineRange: opening,
                    separatorMarkerLineRange: separator,
                    closingMarkerLineRange: substringRange,
                    currentLabel: currentLabel,
                    incomingLabel: Self.label(after: 7, in: line)
                ))
                reset()
            } else {
                switch section {
                case 1: currentLines.append(enclosingRange)
                case 3: incomingLines.append(enclosingRange)
                default: break
                }
            }
        }

        return result
    }

    /// The text that should replace `conflict.fullRange` for the given choice.
    /// Content ranges already include their trailing newlines, so "both" keeps
    /// each side on its own lines and the surrounding file stays intact.
    static func resolvedText(
        for conflict: MergeConflict,
        in text: String,
        choice: MergeConflictResolution
    ) -> String {
        let ns = text as NSString
        let current = conflict.currentRange.length > 0 ? ns.substring(with: conflict.currentRange) : ""
        let incoming = conflict.incomingRange.length > 0 ? ns.substring(with: conflict.incomingRange) : ""

        switch choice {
        case .current: return current
        case .incoming: return incoming
        case .both: return current + incoming
        }
    }

    private static func label(after markerLength: Int, in line: String) -> String {
        guard line.count > markerLength else { return "" }
        let start = line.index(line.startIndex, offsetBy: markerLength)
        return String(line[start...]).trimmingCharacters(in: .whitespaces)
    }

    private static func union(_ ranges: [NSRange]) -> NSRange {
        guard let first = ranges.first else { return NSRange(location: 0, length: 0) }
        return ranges.dropFirst().reduce(first) { NSUnionRange($0, $1) }
    }
}
