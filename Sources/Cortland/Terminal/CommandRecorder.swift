import Foundation

/// Result of the last finished shell command, reported via OSC 133 marks
/// from the shell integration script.
nonisolated struct TerminalCommandStatus {
    let exitCode: Int
    let duration: TimeInterval?
    /// The command line from the OSC 133 `C` mark, when one opened this
    /// command. Nil for a bare `D` with no preceding `C`.
    let command: String?

    init(exitCode: Int, duration: TimeInterval?, command: String? = nil) {
        self.exitCode = exitCode
        self.duration = duration
        self.command = command
    }

    var succeeded: Bool { exitCode == 0 }

    var summary: String {
        let outcome = succeeded ? "✓ exit 0" : "✗ exit \(exitCode)"
        guard let duration = duration else { return outcome }
        if duration >= 60 {
            let minutes = Int(duration) / 60
            let seconds = Int(duration) % 60
            return "\(outcome) · \(minutes)m \(seconds)s"
        }
        return String(format: "%@ · %.1fs", outcome, duration)
    }
}

/// A finished shell command captured from OSC 133 marks: the command line
/// (carried base64-encoded in the `C` mark by the shell integration), its exit
/// code and duration (from the `D` mark), and the ANSI-stripped output printed
/// between the two marks. Output framing is approximate at the ~100ms
/// detection-coalescing boundary, which is fine for agent legibility.
nonisolated struct TerminalCommandRecord {
    let command: String
    let exitCode: Int
    let duration: TimeInterval?
    let output: String
    let finishedAt: Date
    /// Absolute scrollback row of the prompt that ran this command (the OSC 133
    /// `A` mark preceding its `C`), so the timeline panel can scroll the terminal
    /// back to it. Nil when no prompt mark was seen (e.g. the very first command).
    let promptRow: Int?
}

/// Captures per-command records from the OSC 133 C..D windows, surfaced by
/// `cortland-ctl pane read --json` for agent-legible command history.
nonisolated struct CommandRecorder {
    private static let maxCommandRecords = 100
    /// Raw output captured per command is bounded so a runaway log tail can't
    /// grow this pane's memory without limit; the tail is what agents read.
    private static let maxCommandOutputChars = 256_000

    private struct InFlightCommand {
        let command: String
        let startDate: Date
        let promptRow: Int?
    }
    private var inFlightCommand: InFlightCommand?
    /// Output captured for the in-flight command. Kept as a standalone property
    /// rather than inside `InFlightCommand` so appending doesn't copy the whole
    /// (up to `maxCommandOutputChars`) struct in and out of the Optional on
    /// every output chunk.
    private var inFlightOutput = ""
    private var commandRecords: [TerminalCommandRecord] = []

    /// True between a `C` mark and the matching `D` — a foreground command is
    /// running.
    var isCommandInFlight: Bool { inFlightCommand != nil }

    /// OSC 133 `C`: a command started — begin capturing a new record. `promptRow`
    /// is the row of the prompt that launched it, carried into the record for
    /// jump-to navigation.
    mutating func commandStarted(command: String, promptRow: Int? = nil, at date: Date = Date()) {
        inFlightCommand = InFlightCommand(command: command, startDate: date, promptRow: promptRow)
        inFlightOutput = ""
    }

    /// Accumulates output for the in-flight command (no-op when none is
    /// running). ANSI is stripped at finalize.
    ///
    /// `onAlternateScreen` chunks are dropped: when the foreground command is a
    /// full-screen TUI (claude, codex, vim) the whole C..D window is redraw
    /// frames for a screen that keeps no history, so capturing it fills the
    /// 256KB record with noise no one can read. The caller passes the screen it
    /// saw rather than the recorder consulting a terminal, so this stays a pure
    /// struct. The same command still gets the output it printed before going
    /// full-screen and the summary it prints after leaving.
    mutating func appendOutput(_ chunk: String, onAlternateScreen: Bool = false) {
        guard inFlightCommand != nil, !onAlternateScreen else { return }
        TerminalText.appendBounded(chunk, to: &inFlightOutput, cap: Self.maxCommandOutputChars)
    }

    /// OSC 133 `D`: the command finished. Finalizes the in-flight record (when
    /// a `C` opened one) and returns the status for the delegate — a `D` with
    /// no preceding `C` still yields a status, just with no duration or record.
    mutating func commandFinished(exitCode: Int, at date: Date = Date()) -> TerminalCommandStatus {
        let duration = inFlightCommand.map { date.timeIntervalSince($0.startDate) }
        let commandLine = inFlightCommand?.command
        if let inFlight = inFlightCommand {
            let cleanOutput = TerminalText.stripANSIEscapes(TerminalText.stripOSCSequences(inFlightOutput))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            commandRecords.append(TerminalCommandRecord(
                command: inFlight.command,
                exitCode: exitCode,
                duration: duration,
                output: cleanOutput,
                finishedAt: date,
                promptRow: inFlight.promptRow
            ))
            if commandRecords.count > Self.maxCommandRecords {
                commandRecords.removeFirst(commandRecords.count - Self.maxCommandRecords)
            }
        }
        inFlightCommand = nil
        inFlightOutput = ""
        return TerminalCommandStatus(exitCode: exitCode, duration: duration, command: commandLine)
    }

    /// The most recently finished commands (oldest first), capped to `limit`
    /// when given.
    func recentRecords(limit: Int? = nil) -> [TerminalCommandRecord] {
        guard let limit, limit > 0 else { return commandRecords }
        return Array(commandRecords.suffix(limit))
    }
}
