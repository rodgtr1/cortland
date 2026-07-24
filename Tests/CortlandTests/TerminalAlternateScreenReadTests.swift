import XCTest
import SwiftTerm
@testable import Cortland

/// `recent` pane reads of a pane running a full-screen program on the alternate
/// screen — every modern agent CLI (Claude, Codex), and vim/lazygit besides.
///
/// These programs repaint by positioning the cursor and rewriting cells; they
/// emit almost no newlines. The raw rolling byte buffer therefore is not a
/// transcript of anything: strip its escapes and thousands of frames weld into
/// one line, then the carriage-return collapse keeps only the last fragment of
/// it. `testRawStreamRouteCollapsesAnAlternateScreenRepaint` pins that failure
/// directly, so the reads below are measured against a demonstrated defect
/// rather than a remembered one.
///
/// Screens here are built by feeding real escape sequences through a headless
/// SwiftTerm, the same way GhostTextTests builds visible-screen cases.
@MainActor
final class TerminalAlternateScreenReadTests: XCTestCase {
    private let gen = 4242

    /// A pane's whole byte history: shell output on the main screen, then a
    /// full-screen agent CLI that takes over the alternate screen and repaints
    /// itself twice. Every repaint is cursor positioning — not one newline.
    private func sessionBytes(secondFrame: Bool) -> String {
        var raw = "$ ls\r\nREADME.md\r\nPackage.swift\r\n$ claude\r\n"
        raw += "\u{1B}[?1049h"                       // enter the alternate screen
        raw += "\u{1B}[2J\u{1B}[H"                   // clear, home
        raw += "\u{1B}[1;1H╭─ Claude ─────────────╮"
        raw += "\u{1B}[2;1H│ Reading TerminalText │"
        raw += "\u{1B}[3;1H╰──────────────────────╯"
        raw += "\u{1B}[6;1H  esc to interrupt"
        guard secondFrame else { return raw }
        raw += "\u{1B}[2;1H│ Editing TerminalText │"
        raw += "\u{1B}[6;1H  done in 12s          "
        return raw
    }

    private func snapshot(feeding raw: String) -> TerminalText.RecentReadSnapshot {
        let headless = HeadlessTerminal(onEnd: { _ in })
        let terminal = headless.terminal!
        terminal.feed(text: raw)
        return TerminalText.recentReadSnapshot(
            terminal: terminal, buffer: raw, total: raw.utf8.count, dropped: 0, generation: gen)
    }

    // MARK: - The defect

    func testRawStreamRouteCollapsesAnAlternateScreenRepaint() {
        // What a `recent` read used to return for a pane running an agent CLI:
        // the raw buffer normalized as if it were a `\r`-overwrite spinner log.
        // Strip the positioning escapes and the whole TUI session is one line —
        // frames welded end to end, overwritten cells still in it, rows in the
        // order they were painted rather than the order they appear. On a real
        // 64KB buffer that has rolled, the CR collapse then keeps only the final
        // fragment of that line, which is the near-empty read that was reported.
        let raw = sessionBytes(secondFrame: true)
        let collapsed = TerminalText.transcript(raw, limit: 200)
        let tuiLines = collapsed.split(separator: "\n").filter { $0.contains("TerminalText") }
        XCTAssertEqual(tuiLines.count, 1,
                       "six screen rows and two frames arrive as a single line: \(collapsed)")
        XCTAssertTrue(collapsed.contains("Reading TerminalText"),
                      "a cell the TUI overwrote is still in the raw stream, so it reads as current")
        guard let interrupt = collapsed.range(of: "esc to interrupt"),
              let editing = collapsed.range(of: "Editing TerminalText") else {
            return XCTFail("expected both rows in the collapsed text: \(collapsed)")
        }
        XCTAssertTrue(interrupt.lowerBound < editing.lowerBound,
                      "row 6 lands before row 2 — paint order, not screen order")
        XCTAssertEqual(TerminalText.transcript(raw, limit: 1), tuiLines[0] + "",
                       "and the line cap cannot trim any of it, because it is all one line")
    }

    // MARK: - Full reads

    func testFullReadReturnsTheInterpretedFrame() {
        let read = TerminalText.recentRead(snapshot(feeding: sessionBytes(secondFrame: true)),
                                           since: nil, lineLimit: 200)
        XCTAssertTrue(read.text.contains("╭─ Claude ─────────────╮"), read.text)
        XCTAssertTrue(read.text.contains("│ Editing TerminalText │"),
                      "the current frame, as repainted — not the frame before it")
        XCTAssertFalse(read.text.contains("│ Reading TerminalText │"),
                       "an overwritten cell is gone from the screen, so it is gone from the read")
        XCTAssertTrue(read.text.contains("done in 12s"), read.text)
        XCTAssertFalse(read.truncated)
    }

    func testFullReadKeepsTheMainScreenScrollbackAheadOfTheFrame() {
        // The emulator retains the normal buffer while a TUI is on the alternate
        // screen, so everything printed before the TUI took over is still there.
        let read = TerminalText.recentRead(snapshot(feeding: sessionBytes(secondFrame: false)),
                                           since: nil, lineLimit: 200)
        let lines = read.text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let shellRow = lines.firstIndex(where: { $0.contains("$ claude") }),
              let frameRow = lines.firstIndex(where: { $0.contains("╭─ Claude") }) else {
            return XCTFail("expected pre-TUI scrollback and the frame: \(read.text)")
        }
        XCTAssertTrue(read.text.contains("README.md"), "pre-TUI output is scrollback, not lost")
        XCTAssertLessThan(shellRow, frameRow, "history first, then the frame the user is looking at")
    }

    func testLineCapSpendsItselfOnTheFrameNotTheScrollback() {
        // A tight budget must show what is on screen now. The frame occupies six
        // rows, so a cap of six leaves no room for the shell history above it.
        let read = TerminalText.recentRead(snapshot(feeding: sessionBytes(secondFrame: false)),
                                           since: nil, lineLimit: 6)
        XCTAssertTrue(read.text.contains("esc to interrupt"), read.text)
        XCTAssertFalse(read.text.contains("$ claude"), "the cap drops scrollback before it drops the frame")
        XCTAssertEqual(read.text.split(separator: "\n", omittingEmptySubsequences: false).count, 6)
    }

    // MARK: - Delta reads

    func testDeltaReadServesTheFrameWhenOutputHasArrived() {
        // A coordinator read the pane at the first frame, then the worker
        // repainted. The alternate screen keeps no history to diff, so the delta
        // is the frame as it now stands.
        let firstFrame = sessionBytes(secondFrame: false)
        let snap = snapshot(feeding: sessionBytes(secondFrame: true))
        let read = TerminalText.recentRead(snap, since: "\(gen):\(firstFrame.utf8.count)", lineLimit: 200)
        XCTAssertFalse(read.truncated)
        XCTAssertTrue(read.text.contains("│ Editing TerminalText │"), read.text)
        XCTAssertEqual(read.cursor, "\(gen):\(snap.total)", "the cursor grammar is unchanged")
    }

    func testDeltaReadAtTheHeadOfTheStreamReturnsNothing() {
        let snap = snapshot(feeding: sessionBytes(secondFrame: true))
        let read = TerminalText.recentRead(snap, since: "\(gen):\(snap.total)", lineLimit: 200)
        XCTAssertEqual(read.text, "", "caught up: no bytes since the cursor, so nothing to show")
        XCTAssertFalse(read.truncated)
        XCTAssertEqual(read.cursor, "\(gen):\(snap.total)")
    }

    func testStaleCursorResyncsAsATruncatedFullRead() {
        let snap = snapshot(feeding: sessionBytes(secondFrame: true))
        for stale in ["\(gen + 1):0", "not-a-cursor", "\(gen):999999"] {
            let read = TerminalText.recentRead(snap, since: stale, lineLimit: 200)
            XCTAssertTrue(read.truncated, "cursor '\(stale)' must re-sync, not error")
            XCTAssertTrue(read.text.contains("README.md"),
                          "a re-sync is a full read: scrollback and frame")
            XCTAssertTrue(read.text.contains("│ Editing TerminalText │"), read.text)
        }
    }

    // MARK: - Normal-screen panes are untouched

    func testNormalScreenSnapshotCarriesNoAlternateFrame() {
        let snap = snapshot(feeding: "$ swift build\r\nBuild complete!\r\n")
        XCTAssertNil(snap.alternateFrame, "nothing is on the alternate screen")
        let read = TerminalText.recentRead(snap, since: nil, lineLimit: 20)
        XCTAssertEqual(read.text, "$ swift build\nBuild complete!")
    }

    func testLeavingTheAlternateScreenReturnsToScrollbackReads() {
        // `?1049l` puts the shell back on the main screen. Reads must go straight
        // back to the interpreted scrollback — no stale frame left behind.
        let snap = snapshot(feeding: sessionBytes(secondFrame: true) + "\u{1B}[?1049l$ echo done\r\ndone\r\n")
        XCTAssertNil(snap.alternateFrame)
        let read = TerminalText.recentRead(snap, since: nil, lineLimit: 20)
        XCTAssertFalse(read.text.contains("Editing TerminalText"), "the TUI's frame is gone from the screen")
        XCTAssertTrue(read.text.contains("$ claude"), "the shell's scrollback is what remains")
        XCTAssertTrue(read.text.hasSuffix("done"), read.text)
    }

    func testNormalScreenDeltaStillSlicesTheRawStream() {
        // The byte cursor keeps its exact meaning off the alternate screen: a
        // delta is the output appended after it, normalized.
        let prefix = "$ swift build\r\n"
        let snap = snapshot(feeding: prefix + "Build complete!\r\n")
        let read = TerminalText.recentRead(snap, since: "\(gen):\(prefix.utf8.count)", lineLimit: 20)
        XCTAssertEqual(read.text, "Build complete!\n")
        XCTAssertFalse(read.truncated)
    }
}
