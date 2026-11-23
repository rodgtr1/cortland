import XCTest
@testable import Cortland

final class CommandRecorderTests: XCTestCase {
    func testCapturesCommandRecordWithCleanedOutput() {
        var recorder = CommandRecorder()
        XCTAssertFalse(recorder.isCommandInFlight)

        let start = Date(timeIntervalSince1970: 100)
        recorder.commandStarted(command: "ls -la", at: start)
        XCTAssertTrue(recorder.isCommandInFlight)

        recorder.appendOutput("\u{001B}[32mfile.txt\u{001B}[0m\n")
        let status = recorder.commandFinished(exitCode: 0, at: start.addingTimeInterval(1.5))

        XCTAssertEqual(status.exitCode, 0)
        XCTAssertEqual(status.duration ?? -1, 1.5, accuracy: 0.001)
        XCTAssertFalse(recorder.isCommandInFlight)

        let record = recorder.recentRecords().last
        XCTAssertEqual(record?.command, "ls -la")
        XCTAssertEqual(record?.exitCode, 0)
        // ANSI stripped and whitespace trimmed at finalize.
        XCTAssertEqual(record?.output, "file.txt")
    }

    func testOSCSequencesStrippedFromRecordOutput() {
        var recorder = CommandRecorder()
        recorder.commandStarted(command: "pwd")
        recorder.appendOutput("\u{001B}]7;file:///tmp\u{001B}\\/tmp\n")
        _ = recorder.commandFinished(exitCode: 0)
        XCTAssertEqual(recorder.recentRecords().last?.output, "/tmp")
    }

    func testFinishWithoutStartYieldsStatusButNoRecord() {
        var recorder = CommandRecorder()
        let status = recorder.commandFinished(exitCode: 2)
        XCTAssertEqual(status.exitCode, 2)
        XCTAssertNil(status.duration)
        XCTAssertTrue(recorder.recentRecords().isEmpty)
    }

    func testOutputOutsideCommandWindowIsIgnored() {
        var recorder = CommandRecorder()
        recorder.appendOutput("prompt noise before the command")
        recorder.commandStarted(command: "true")
        _ = recorder.commandFinished(exitCode: 0)
        XCTAssertEqual(recorder.recentRecords().last?.output, "")
    }

    func testAlternateScreenOutputIsNotCaptured() {
        // A full-screen TUI between the C and D marks (claude, vim): everything
        // it writes is redraw for a screen that keeps no history, so none of it
        // belongs in the record.
        var recorder = CommandRecorder()
        recorder.commandStarted(command: "claude")
        for tick in 0..<200 {
            recorder.appendOutput("\u{001B}[2K✻ Thinking… (\(tick)s)\r", onAlternateScreen: true)
        }
        _ = recorder.commandFinished(exitCode: 0)
        XCTAssertEqual(recorder.recentRecords().last?.output, "")
    }

    func testOutputEitherSideOfTheAlternateScreenIsStillCaptured() {
        // A command that prints, goes full-screen, then prints a summary on the
        // way out keeps both halves — only the TUI's redraw window is dropped.
        var recorder = CommandRecorder()
        recorder.commandStarted(command: "vim notes.md")
        recorder.appendOutput("opening notes.md\n", onAlternateScreen: false)
        recorder.appendOutput("\u{001B}[2K~\u{001B}[3;1H~\r", onAlternateScreen: true)
        recorder.appendOutput("\"notes.md\" 12L written\n", onAlternateScreen: false)
        _ = recorder.commandFinished(exitCode: 0)
        XCTAssertEqual(recorder.recentRecords().last?.output,
                       "opening notes.md\n\"notes.md\" 12L written")
    }

    func testRecordsCappedAndLimitApplied() {
        var recorder = CommandRecorder()
        for i in 0..<105 {
            recorder.commandStarted(command: "cmd\(i)")
            _ = recorder.commandFinished(exitCode: 0)
        }
        XCTAssertEqual(recorder.recentRecords().count, 100)
        XCTAssertEqual(recorder.recentRecords().first?.command, "cmd5")
        XCTAssertEqual(recorder.recentRecords(limit: 2).map(\.command), ["cmd103", "cmd104"])
        // A nil/zero limit means everything.
        XCTAssertEqual(recorder.recentRecords(limit: 0).count, 100)
    }

    func testStatusSummaryFormatting() {
        XCTAssertEqual(TerminalCommandStatus(exitCode: 0, duration: nil).summary, "✓ exit 0")
        XCTAssertEqual(TerminalCommandStatus(exitCode: 1, duration: 2.34).summary, "✗ exit 1 · 2.3s")
        XCTAssertEqual(TerminalCommandStatus(exitCode: 0, duration: 90).summary, "✓ exit 0 · 1m 30s")
    }

    // MARK: Retained output budget

    /// `size` characters of output whose last 11 are a marker naming `index`,
    /// so a shrunk record's surviving tail is identifiable.
    private func output(_ index: Int, size: Int) -> String {
        String(repeating: "x", count: size - 11) + String(format: "tail-%05d", index) + "!"
    }

    private func record(_ recorder: inout CommandRecorder, _ index: Int, size: Int) {
        recorder.commandStarted(command: "cmd \(index)", promptRow: index)
        recorder.appendOutput(output(index, size: size))
        _ = recorder.commandFinished(exitCode: index % 3)
    }

    func testOutputUnderBudgetIsUntouched() {
        var recorder = CommandRecorder()
        // 8 x 250,000 is exactly the 2,000,000 budget: not over it.
        for index in 0..<8 { record(&recorder, index, size: 250_000) }
        let records = recorder.recentRecords()
        XCTAssertEqual(records.count, 8)
        for (index, rec) in records.enumerated() {
            XCTAssertEqual(rec.output, output(index, size: 250_000))
        }
        XCTAssertEqual(recorder.retainedOutputChars, 2_000_000)
    }

    func testOverBudgetShrinksOldestToTailAndKeepsNewestIntact() {
        var recorder = CommandRecorder()
        for index in 0..<9 { record(&recorder, index, size: 250_000) }
        let records = recorder.recentRecords()
        XCTAssertEqual(records.count, 9, "the budget never drops a record")

        // 2,250,000 over a 2,000,000 budget: shrinking record 0 leaves
        // 2,008,000, still over, so record 1 shrinks too. Record 2 on are whole.
        let shrunk = CommandRecorder.shrunkCommandOutputChars
        for index in 0..<2 {
            XCTAssertEqual(records[index].output.count, shrunk)
            XCTAssertEqual(records[index].output, String(output(index, size: 250_000).suffix(shrunk)))
            XCTAssertTrue(records[index].output.hasSuffix(String(format: "tail-%05d!", index)))
        }
        for index in 2..<9 {
            XCTAssertEqual(records[index].output, output(index, size: 250_000))
        }
        // Metadata is never touched.
        for (index, rec) in records.enumerated() {
            XCTAssertEqual(rec.command, "cmd \(index)")
            XCTAssertEqual(rec.exitCode, index % 3)
            XCTAssertEqual(rec.promptRow, index)
            XCTAssertNotNil(rec.duration)
        }
        XCTAssertEqual(recorder.retainedOutputChars, records.reduce(0) { $0 + $1.output.count })
        XCTAssertLessThanOrEqual(recorder.retainedOutputChars, CommandRecorder.maxRetainedOutputChars)
    }

    func testTotalStaysWithinBudgetAcrossManyRecords() {
        var recorder = CommandRecorder()
        for index in 0..<130 {
            record(&recorder, index, size: 250_000)
            XCTAssertLessThanOrEqual(recorder.retainedOutputChars, CommandRecorder.maxRetainedOutputChars)
            XCTAssertEqual(recorder.recentRecords().last?.output, output(index, size: 250_000),
                           "the newest record keeps its full output")
        }
        let records = recorder.recentRecords()
        XCTAssertEqual(records.count, 100)
        XCTAssertEqual(recorder.retainedOutputChars, records.reduce(0) { $0 + $1.output.count })
    }

    func testShrinkCutsOnCharacterBoundary() {
        var recorder = CommandRecorder()
        // Two-scalar graphemes (e + combining acute): a cut on anything but a
        // Character boundary would leave a bare combining mark at the head.
        let accented = "e\u{301}"
        recorder.commandStarted(command: "accents")
        recorder.appendOutput(String(repeating: accented, count: 100_000))
        _ = recorder.commandFinished(exitCode: 0)
        for index in 1..<9 { record(&recorder, index, size: 250_000) }
        let first = recorder.recentRecords()[0].output
        XCTAssertEqual(first, String(repeating: accented, count: CommandRecorder.shrunkCommandOutputChars))
        XCTAssertEqual(first.unicodeScalars.count, 2 * CommandRecorder.shrunkCommandOutputChars)
    }
}
