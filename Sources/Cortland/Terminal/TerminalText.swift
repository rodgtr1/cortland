import Foundation
import SwiftTerm

/// Shared text plumbing for the terminal output pipeline: ANSI/OSC escape
/// stripping and the amortized bounded-append used by every rolling output
/// buffer (automation output, the agent-detection window, command records).
nonisolated enum TerminalText {
    static let ansiEscapeRegex: NSRegularExpression? =
        try? NSRegularExpression(pattern: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]")

    /// OSC sequences (ESC ] … BEL/ST) — cwd reports, title sets, and Cortland's
    /// own 7/133/666 marks. Stripped from command records so the captured output
    /// is the command's actual text, not control chatter.
    static let oscEscapeRegex: NSRegularExpression? =
        try? NSRegularExpression(pattern: "\u{001B}\\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\\\)")

    static func stripANSIEscapes(_ output: String) -> String {
        guard let regex = ansiEscapeRegex else { return output }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        return regex.stringByReplacingMatches(in: output, range: range, withTemplate: "")
    }

    static func stripOSCSequences(_ output: String) -> String {
        guard let regex = oscEscapeRegex else { return output }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        return regex.stringByReplacingMatches(in: output, range: range, withTemplate: "")
    }

    /// ANSI-stripped, lowercased output for the case-insensitive heuristics.
    static func normalize(_ output: String) -> String {
        stripANSIEscapes(output).lowercased()
    }

    /// Keeps the last `lineLimit` newline-delimited lines of `text` (all of it
    /// when `lineLimit` is nil or non-positive). Shared by the pane readers so
    /// line-capping stays identical across visible/recent/delta reads.
    ///
    /// Only ever run this on text a terminal has already interpreted (a screen
    /// scrape, or `transcript`'s output). On a raw byte stream a spinner's
    /// hundreds of `\r` redraw frames are one "line", so the cap trims nothing.
    static func lastLines(of text: String, limit lineLimit: Int?) -> String {
        guard let lineLimit, lineLimit > 0 else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(lineLimit)
            .joined(separator: "\n")
    }

    /// Collapses each carriage-return overwrite run to the frame a screen would
    /// still be showing: the last non-empty segment written after a `\r`. A TUI
    /// redraws its spinner or progress bar by rewriting the same line hundreds of
    /// times, which costs a real terminal nothing but turns a raw byte log into a
    /// wall of near-identical frames.
    ///
    /// Iterates unicode scalars, not characters, because Swift graphemes cluster
    /// `\r\n` into a single Character — a line-splitter that matches on "\n"
    /// silently skips every CRLF-terminated line.
    static func collapseCarriageReturns(_ text: String) -> String {
        guard text.unicodeScalars.contains("\r") else { return text }
        var result = ""
        result.reserveCapacity(text.unicodeScalars.count)
        // `frame` is what has been written since the last `\r`; `lastDrawn` the
        // last frame that had content, so a run ending in a bare `\r` (a CRLF, or
        // an erase-line whose CSI was already stripped) keeps the frame before it
        // rather than blanking the line.
        var frame = ""
        var lastDrawn = ""
        func endLine() {
            result += frame.isEmpty ? lastDrawn : frame
            frame = ""
            lastDrawn = ""
        }
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n":
                endLine()
                result.unicodeScalars.append(scalar)
            case "\r":
                if !frame.isEmpty { lastDrawn = frame }
                frame = ""
            default:
                frame.unicodeScalars.append(scalar)
            }
        }
        endLine()
        return result
    }

    /// Normalizes a raw terminal byte stream into a readable transcript: strips
    /// CSI *and* OSC control sequences, collapses `\r` redraw runs, and only then
    /// applies the line cap — cap last, so a noisy TUI can't spend the whole
    /// budget on redraw frames and control chatter.
    static func transcript(_ raw: String, limit lineLimit: Int?) -> String {
        let stripped = stripOSCSequences(stripANSIEscapes(raw))
        return lastLines(of: collapseCarriageReturns(stripped), limit: lineLimit)
    }

    /// Caps a dump of the terminal's interpreted line buffer (scrollback +
    /// screen). The rows carry no escape sequences — the emulator consumed them —
    /// so this only drops the blank rows the screen keeps below the cursor, which
    /// would otherwise eat the line budget, and applies the cap.
    static func transcript(screen: String, limit lineLimit: Int?) -> String {
        var rows = trimmedRows(of: screen)
        if let lineLimit, lineLimit > 0 {
            rows = rows.suffix(lineLimit)
        }
        return rows.joined(separator: "\n")
    }

    /// A buffer dump split into rows with the trailing blank ones dropped — the
    /// rows a screen pads below the cursor, which carry no output and would
    /// otherwise spend the whole line budget.
    private static func trimmedRows(of screen: String) -> ArraySlice<Substring> {
        var rows = screen.split(separator: "\n", omittingEmptySubsequences: false)[...]
        while let last = rows.last, last.allSatisfy(\.isWhitespace) {
            rows = rows.dropLast()
        }
        return rows
    }

    /// A full read of a pane whose foreground program is on the alternate screen
    /// (an agent CLI, vim, lazygit): the main screen's retained scrollback —
    /// everything printed before the TUI took over — followed by the current
    /// interpreted alternate-screen frame.
    ///
    /// Both halves come from the emulator, so both are already free of the
    /// cursor-positioning repaints that make the raw byte stream unreadable here.
    /// The cap is applied last, over the joined text, so a tight `--lines` budget
    /// spends itself on the frame the user is actually looking at and drops the
    /// older scrollback above it.
    static func transcript(scrollback: String?, frame: String, limit lineLimit: Int?) -> String {
        var rows = scrollback.map { Array(trimmedRows(of: $0)) } ?? []
        rows.append(contentsOf: trimmedRows(of: frame))
        if let lineLimit, lineLimit > 0 {
            rows = Array(rows.suffix(lineLimit))
        }
        return rows.joined(separator: "\n")
    }

    /// The outcome of a cursor-scoped delta read of a rolling output buffer.
    struct RecentDelta: Equatable {
        let text: String
        let cursor: String
        let truncated: Bool
    }

    /// Computes a cursor-scoped delta of a rolling recent-output buffer. `buffer`
    /// is the current (ANSI-bearing) rolling buffer; `total` is the monotonic
    /// UTF-8 byte count ever appended and `dropped` how many leading bytes the
    /// trim has since evicted, so `dropped + buffer.utf8.count == total`.
    /// `generation` scopes the cursor to the shell's lifetime.
    ///
    /// With no `since`, returns the full (line-capped, ANSI-stripped) buffer and
    /// `truncated: false`. With a `since` cursor, returns only the output after
    /// it. When the cursor names another generation, points before the retained
    /// window, or is unparseable, returns the full buffer with `truncated: true`
    /// so the caller re-syncs — a stale cursor is never an error. Pure so the
    /// cursor math is testable off the AppKit-bound view controller.
    static func recentDelta(
        buffer: String,
        total: Int,
        dropped: Int,
        generation: Int,
        since: String?,
        lineLimit: Int?
    ) -> RecentDelta {
        let cursor = "\(generation):\(total)"
        func full(truncated: Bool) -> RecentDelta {
            RecentDelta(text: transcript(buffer, limit: lineLimit),
                        cursor: cursor, truncated: truncated)
        }
        guard let since else { return full(truncated: false) }
        guard let offset = parseRecentCursor(since, generation: generation),
              offset >= dropped, offset <= total else {
            return full(truncated: true)
        }
        // `offset` is a byte position recorded as a prior `total`, i.e. the end
        // of an appended chunk and thus a valid UTF-8 scalar boundary. Slice on
        // the UTF-8 view and re-decode so an arbitrary byte offset can't split a
        // codepoint or trap on a grapheme boundary.
        let utf8 = buffer.utf8
        let start = utf8.index(utf8.startIndex, offsetBy: offset - dropped)
        let delta = transcript(String(decoding: utf8[start...], as: UTF8.self), limit: lineLimit)
        return RecentDelta(text: delta, cursor: cursor, truncated: false)
    }

    /// Everything a `recent` pane read needs, copied off the terminal on the main
    /// thread so the normalization (two regex passes, the redraw collapse, the
    /// line cap) can run on a background queue.
    ///
    /// `screen` is the interpreted *main-screen* line buffer (scrollback +
    /// screen). The emulator keeps it intact while a program runs on the alternate
    /// screen, so it is the pre-TUI history even then.
    ///
    /// `alternateFrame` is the interpreted alternate-screen buffer, non-nil only
    /// while a full-screen program is actually on it. That buffer is one viewport
    /// with no scrollback of its own — it is the frame a human is looking at.
    struct RecentReadSnapshot: Sendable {
        let screen: String?
        let alternateFrame: String?
        let buffer: String
        let total: Int
        let dropped: Int
        let generation: Int

        init(screen: String?,
             alternateFrame: String? = nil,
             buffer: String,
             total: Int,
             dropped: Int,
             generation: Int) {
            self.screen = screen
            self.alternateFrame = alternateFrame
            self.buffer = buffer
            self.total = total
            self.dropped = dropped
            self.generation = generation
        }
    }

    /// Copies what a `recent` read needs off a terminal, cheaply, so the caller can
    /// normalize it on a background queue. This is the only main-thread work a
    /// recent read does — the strips and the line cap run against these copies.
    ///
    /// SwiftTerm exposes buffer rows only as a whole-buffer dump (`buffer.lines`
    /// itself is internal), so this walks each buffer rather than just its tail;
    /// both are bounded, the main screen by the scrollback cap and the alternate
    /// one by the viewport.
    ///
    /// Reading `.normal` rather than `.active` is what makes an alternate-screen
    /// pane readable: the emulator keeps the main-screen buffer intact while a TUI
    /// runs, so it still holds everything printed before the TUI took over.
    static func recentReadSnapshot(
        terminal: Terminal,
        buffer: String,
        total: Int,
        dropped: Int,
        generation: Int
    ) -> RecentReadSnapshot {
        let onAlternateScreen = terminal.isCurrentBufferAlternate
        return RecentReadSnapshot(
            screen: String(decoding: terminal.getBufferAsData(kind: .normal), as: UTF8.self),
            alternateFrame: onAlternateScreen
                ? String(decoding: terminal.getBufferAsData(kind: .alt), as: UTF8.self)
                : nil,
            buffer: buffer,
            total: total,
            dropped: dropped,
            generation: generation)
    }

    /// Resolves a `recent` read from a `RecentReadSnapshot`, off the main thread.
    ///
    /// A full read (no cursor, or a stale one that has to re-sync) is served from
    /// the interpreted line buffer when there is one: the emulator already applied
    /// the `\r`, backspaces, erase-lines and cursor moves that the raw stream only
    /// describes, so its text collapses TUI redraw noise for free. Delta reads keep
    /// the raw byte cursor — cursors stay `generation:total` against the rolling
    /// buffer — and get the same normalization on the way out.
    ///
    /// The screen-served case never calls `recentDelta`: that would normalize the
    /// whole raw buffer (two regex passes and a redraw collapse over up to 64KB of
    /// a spinning TUI's byte stream) only to discard the text for the screen's. The
    /// two fields it did contribute are recomputed here directly, both trivially:
    /// the cursor is `generation:total`, and `truncated` is whether `since` failed
    /// to resolve.
    ///
    /// A pane on the alternate screen takes neither route. Its raw stream is not a
    /// transcript at all: a full-screen program repaints by moving the cursor and
    /// rewriting cells, emitting almost no newlines, so stripping the escapes
    /// welds thousands of frames into one line and the redraw collapse then keeps
    /// only the last fragment of it. Both reads are served from the emulator
    /// instead — see `alternateScreenRead`.
    static func recentRead(_ snapshot: RecentReadSnapshot, since: String?, lineLimit: Int?) -> RecentDelta {
        // Same staleness rule `recentDelta` applies: a cursor is usable only when
        // it parses, names this generation, and still points inside the retained
        // window. Anything else re-syncs as a full read flagged `truncated`.
        let staleCursor = since.map { token in
            guard let offset = parseRecentCursor(token, generation: snapshot.generation) else { return true }
            return offset < snapshot.dropped || offset > snapshot.total
        } ?? false
        let isFullRead = since == nil || staleCursor

        if let frame = snapshot.alternateFrame {
            return alternateScreenRead(snapshot, frame: frame, since: since,
                                       isFullRead: isFullRead, staleCursor: staleCursor,
                                       lineLimit: lineLimit)
        }
        if isFullRead, let screen = snapshot.screen {
            return RecentDelta(text: transcript(screen: screen, limit: lineLimit),
                               cursor: "\(snapshot.generation):\(snapshot.total)",
                               truncated: staleCursor)
        }
        return recentDelta(
            buffer: snapshot.buffer,
            total: snapshot.total,
            dropped: snapshot.dropped,
            generation: snapshot.generation,
            since: since,
            lineLimit: lineLimit)
    }

    /// Resolves a `recent` read of a pane whose foreground program is on the
    /// alternate screen. Both reads come from the emulator, never the raw stream.
    ///
    /// A full read is the retained main-screen scrollback plus the current frame.
    ///
    /// A delta read is the current frame when bytes have arrived since the cursor,
    /// and empty text when none have. The alternate screen keeps no history to
    /// diff against — a repaint overwrites cells in place, so "what is new" simply
    /// does not exist there as text. Serving the whole frame is the honest answer
    /// to "show me what changed": it is bounded by the viewport, it is what a
    /// human would see, and a caller polling a worker pane gets a fresh frame
    /// exactly when the worker wrote something. The byte cursor keeps its usual
    /// job — it still advances with the raw stream, so it detects *that* output
    /// happened even though it can no longer say *which* of it is new.
    ///
    /// Cursor grammar and staleness rules are untouched: the returned cursor is
    /// `generation:total` and a stale one re-syncs as a truncated full read.
    private static func alternateScreenRead(
        _ snapshot: RecentReadSnapshot,
        frame: String,
        since: String?,
        isFullRead: Bool,
        staleCursor: Bool,
        lineLimit: Int?
    ) -> RecentDelta {
        let cursor = "\(snapshot.generation):\(snapshot.total)"
        if isFullRead {
            return RecentDelta(
                text: transcript(scrollback: snapshot.screen, frame: frame, limit: lineLimit),
                cursor: cursor,
                truncated: staleCursor)
        }
        // Live cursor (isFullRead is false only when `since` parsed and resolved).
        let caughtUp = since
            .flatMap { parseRecentCursor($0, generation: snapshot.generation) }
            .map { $0 >= snapshot.total } ?? false
        return RecentDelta(text: caughtUp ? "" : transcript(screen: frame, limit: lineLimit),
                           cursor: cursor,
                           truncated: false)
    }

    /// Parses a `"<generation>:<offset>"` cursor, returning the byte offset only
    /// when the generation half matches `generation` (a cursor from a prior
    /// shell reads as stale). Nil on any mismatch or malformed token.
    static func parseRecentCursor(_ token: String, generation: Int) -> Int? {
        let parts = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let tokenGeneration = Int(parts[0]), tokenGeneration == generation,
              let offset = Int(parts[1]), offset >= 0 else { return nil }
        return offset
    }

    /// Appends `chunk` to a rolling buffer, keeping roughly the last `cap`
    /// characters. The old `buffer = String(buffer.suffix(cap))` reallocated and
    /// copied the whole buffer on *every* output chunk once it reached `cap`.
    /// Here the grapheme-aware trim runs only after the buffer grows a quarter
    /// past `cap`, so under noisy throughput (builds, log tails) it amortizes to
    /// one trim per slack-of-growth instead of one per chunk.
    static func appendBounded(_ chunk: String, to buffer: inout String, cap: Int) {
        buffer += chunk
        // utf8.count is O(1) on Swift's native UTF-8 storage; Character `count`
        // is O(n) grapheme-breaking and ran on every chunk. The bound is
        // approximate ("roughly the last cap chars"), so bytes-vs-graphemes here
        // is fine — the occasional suffix() trim still keeps memory bounded.
        if buffer.utf8.count > cap + cap / 4 {
            buffer = String(buffer.suffix(cap))
        }
    }
}
