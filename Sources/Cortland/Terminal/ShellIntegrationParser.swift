import Foundation

/// Extracts shell-integration escape sequences from the raw output stream:
/// OSC 133 command marks (prompt drawn / command started / command finished)
/// and OSC 666 agent-status reports (the Claude/Codex hook termprop).
///
/// A sequence split across PTY read chunks stays buffered until it completes,
/// and the retained partial is aggressively trimmed so ESC-heavy but mark-less
/// streams (vim emits CSI constantly and marks never) can't pin memory or force
/// full regex rescans on every flush.
nonisolated struct ShellIntegrationParser {
    static let agentStatusTermprop = "vte.ext.cortland.agent"

    /// One OSC 133 mark: its kind letter (`A` prompt, `C` command start,
    /// `D` command end, …) and the optional parameter after the second `;`.
    struct CommandMark: Equatable {
        let kind: String
        let parameter: String?
    }

    private var commandMarkBuffer = ""
    private var agentStatusBuffer = ""

    private static let commandMarkRegex: NSRegularExpression? =
        try? NSRegularExpression(pattern: "\u{001B}\\]133;([A-Za-z])(?:;([^\u{001B}\u{0007}]*))?(?:\u{001B}\\\\|\u{0007})")

    private static let agentStatusRegex: NSRegularExpression? = {
        let escapedTermprop = NSRegularExpression.escapedPattern(for: agentStatusTermprop)
        let pattern = "\u{001B}\\]666;\(escapedTermprop)=([A-Za-z_-]+)(?:\u{001B}\\\\|\u{0007})"
        return try? NSRegularExpression(pattern: pattern)
    }()

    /// Consumes every complete OSC 133 mark in `output` (plus any buffered
    /// partial it completes) and returns them in stream order.
    mutating func consumeCommandMarks(from output: String) -> [CommandMark] {
        var marks: [CommandMark] = []
        Self.consumeBufferedSequences(from: output, into: &commandMarkBuffer, regex: Self.commandMarkRegex) { match, buffer in
            guard let kindRange = Range(match.range(at: 1), in: buffer) else { return }
            var parameter: String?
            if match.range(at: 2).location != NSNotFound,
               let parameterRange = Range(match.range(at: 2), in: buffer) {
                parameter = String(buffer[parameterRange])
            }
            marks.append(CommandMark(kind: String(buffer[kindRange]), parameter: parameter))
        }
        return marks
    }

    /// Consumes every complete OSC 666 agent-status sequence in `output` and
    /// returns the raw status tokens in stream order. A non-empty return means
    /// the pane received an explicit report this chunk — even when the token is
    /// unknown — so the caller's text heuristics should stand down for it.
    mutating func consumeAgentStatuses(from output: String) -> [String] {
        var statuses: [String] = []
        Self.consumeBufferedSequences(from: output, into: &agentStatusBuffer, regex: Self.agentStatusRegex) { match, buffer in
            guard let statusRange = Range(match.range(at: 1), in: buffer) else { return }
            statuses.append(String(buffer[statusRange]))
        }
        return statuses
    }

    /// Decodes the base64 command line carried in the OSC 133 `C` parameter.
    /// Returns "" when absent (a shell whose integration predates this, or a
    /// command with no captured line) so a record is still produced.
    static func decodeCommandParameter(_ parameter: String?) -> String {
        guard let parameter, !parameter.isEmpty,
              let data = Data(base64Encoded: parameter),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Buffered OSC matching

    /// ESC (0x1B), the OSC introducer (`ESC ]`), and the two OSC terminators
    /// (BEL and ST = `ESC \`). Both the command-mark (OSC 133) and agent-status
    /// (OSC 666) regexes begin with the introducer, so its presence gates every
    /// match — see `trimMarkBuffer` / `consumeBufferedSequences`.
    private static let escByte: Character = "\u{001B}"
    private static let oscIntroducer = "\u{001B}]"
    private static let belTerminator = "\u{0007}"
    private static let stTerminator = "\u{001B}\\"

    /// Final safety cap on a retained partial. Sized well above the longest
    /// plausible OSC 133/666 sequence (a base64 command line) so we never slice
    /// a sequence mid-flight — the bug the old pre-match `suffix(2_000)` caused.
    /// utf8.count is O(1).
    private static let maxMarkBufferChars = 64_000

    /// Trims an in-progress mark buffer to just the bytes that could still be
    /// the start of an OSC 133/666 sequence split across chunks. A live partial
    /// always begins with the OSC introducer `ESC ]`; anything before the last
    /// *un-terminated* introducer is already matched, a completed non-mark OSC
    /// (title/cwd report), or an aborted sequence — none can extend into a
    /// future match, so it's dropped. This is what keeps a mark-less but
    /// ESC-heavy stream (a vim session emits CSI constantly and marks never)
    /// from pinning the buffer near `maxMarkBufferChars` and forcing a full
    /// regex rescan on every 100ms flush.
    private static func trimMarkBuffer(_ buffer: inout String) {
        if let introducer = buffer.range(of: oscIntroducer, options: .backwards) {
            let tail = buffer[introducer.lowerBound...]
            // No terminator after the introducer → a live partial we must keep.
            // A lone trailing ESC is the *start* of an ST terminator, not a
            // complete one, so it correctly reads as still-live here.
            if tail.range(of: belTerminator) == nil, tail.range(of: stTerminator) == nil {
                if introducer.lowerBound != buffer.startIndex {
                    buffer = String(tail)
                }
                capMarkBuffer(&buffer)
                return
            }
        }
        // No live partial introducer. Keep only a trailing lone ESC, which may
        // be the first byte of an introducer split across the chunk boundary.
        buffer = buffer.last == escByte ? String(escByte) : ""
    }

    private static func capMarkBuffer(_ buffer: inout String) {
        if buffer.utf8.count > maxMarkBufferChars {
            buffer = String(buffer.suffix(maxMarkBufferChars))
        }
    }

    /// Shared buffered-OSC matcher behind the OSC 133 command-mark and OSC 666
    /// agent-status consumers, whose buffering/matching/slicing were identical.
    /// Appends `output` to `buffer`, runs `regex` over the accumulation, calls
    /// `handle` for each complete match (passing the match and the buffer string
    /// it indexes into), then drops everything through the last match and trims
    /// the tail to a live partial (if any). A sequence split across chunks stays
    /// buffered until it completes.
    private static func consumeBufferedSequences(
        from output: String,
        into buffer: inout String,
        regex: NSRegularExpression?,
        handle: (_ match: NSTextCheckingResult, _ buffer: String) -> Void
    ) {
        // A mark is `ESC ] 133/666 …`. With nothing buffered, if this chunk has
        // no OSC introducer — nor a trailing ESC that could begin one on the
        // next chunk — there's nothing to match, so skip the append and both
        // regex passes. This is the common case for ordinary output and, unlike
        // a bare-ESC check, also for ESC-heavy TUIs (vim) that emit CSI but no
        // OSC marks.
        if buffer.isEmpty,
           output.range(of: oscIntroducer) == nil,
           output.last != escByte {
            return
        }
        buffer += output

        // The introducer may now sit at the seam between the retained partial
        // and this chunk, so re-check the accumulation. A plain substring scan
        // is far cheaper than the regex when no mark is present.
        guard let regex, buffer.range(of: oscIntroducer) != nil else {
            trimMarkBuffer(&buffer)
            return
        }

        let searchRange = NSRange(buffer.startIndex..<buffer.endIndex, in: buffer)
        let matches = regex.matches(in: buffer, range: searchRange)
        guard !matches.isEmpty else {
            trimMarkBuffer(&buffer)
            return
        }

        var consumedUpperBound = buffer.startIndex
        for match in matches {
            if let matchRange = Range(match.range, in: buffer) {
                consumedUpperBound = matchRange.upperBound
            }
            handle(match, buffer)
        }
        buffer = String(buffer[consumedUpperBound...])
        trimMarkBuffer(&buffer)
    }
}
