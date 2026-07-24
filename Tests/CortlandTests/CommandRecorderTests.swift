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
}
