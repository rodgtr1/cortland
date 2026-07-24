import XCTest
@testable import Cortland

/// Normalization of `recent` pane reads (`TerminalText.transcript` and
/// `TerminalText.recentRead`): a coordinator agent watching a worker pane must get
/// a readable transcript, not the redraw noise a TUI leaves in the raw byte stream.
final class TerminalTranscriptTests: XCTestCase {
    private let gen = 99

    /// One frame of the redraw a TUI spinner emits per tick: erase the line, draw
    /// the frame, return the cursor. Same bytes a real pane feeds the buffer.
    private func spinnerFrame(_ glyph: String, _ label: String) -> String {
        "\u{001B}[2K\u{001B}[36m\(glyph)\u{001B}[0m \(label)\r"
    }

    // MARK: - transcript(_:limit:)

    func testSpinnerRedrawRunCollapsesToTheFrameOnScreen() {
        let raw = spinnerFrame("|", "Working")
            + spinnerFrame("/", "Working")
            + spinnerFrame("-", "Working")
            + "\u{001B}[2KDone\n"
        XCTAssertEqual(TerminalText.transcript(raw, limit: nil), "Done\n",
                       "only the last frame written to the line is still on screen")
    }

    func testCarriageReturnRunKeepsTheLastFrameWithContent() {
        // A run that ends by erasing the line (its CSI already stripped) leaves a
        // trailing empty frame; the frame before it is what the pane still shows.
        XCTAssertEqual(TerminalText.transcript("50%\r75%\r100%\r", limit: nil), "100%")
        XCTAssertEqual(TerminalText.transcript("loading...\rdone", limit: nil), "done")
    }

    func testCRLFLinesSplitDespiteSwiftClusteringThemAsOneCharacter() {
        // "\r\n" is a single Swift Character, so a splitter matching on "\n" walks
        // straight past it. The cap has to see three lines here, not one.
        let raw = "one\r\ntwo\r\nthree\r\n"
        XCTAssertEqual(TerminalText.transcript(raw, limit: nil), "one\ntwo\nthree\n")
        XCTAssertEqual(TerminalText.transcript(raw, limit: 2), "three\n")
    }

    func testStripsOSCSequencesNotJustCSI() {
        let raw = "\u{001B}]0;claude — repo\u{0007}\u{001B}[32mbuild ok\u{001B}[0m\n"
            + "\u{001B}]133;D;0\u{001B}\\next\n"
        XCTAssertEqual(TerminalText.transcript(raw, limit: nil), "build ok\nnext\n",
                       "title sets and shell-integration marks are control chatter, not output")
    }

    func testLineCapIsAppliedAfterNormalization() {
        // Pre-normalization the cap would count this whole redraw run as one line
        // and trim nothing. Post-normalization it sees real lines.
        let noise = (0..<200).map { spinnerFrame("|", "step \($0)") }.joined() + "\n"
        let raw = "alpha\nbeta\ngamma\n" + noise
        XCTAssertEqual(TerminalText.transcript(raw, limit: 2), "| step 199\n")
    }

    func testRecentReadOfNoisyTUIStaysNearTheSizeOfAVisibleRead() {
        // The bug this fixes: a 20-line `recent` read of a spinning TUI came back
        // an order of magnitude larger than the same read of the visible screen.
        var raw = "\u{001B}]0;worker\u{0007}"
        for tick in 0..<500 {
            raw += spinnerFrame(["|", "/", "-", "\\"][tick % 4], "Thinking \(tick)s")
        }
        raw += "\u{001B}[2KDone\n"
        let text = TerminalText.transcript(raw, limit: 20)
        XCTAssertEqual(text, "Done\n")
        XCTAssertLessThan(text.utf8.count, raw.utf8.count / 100)
    }

    // MARK: - transcript(screen:limit:)

    func testScreenTranscriptDropsTheBlankRowsBelowTheCursor() {
        // A buffer dump pads every unused row of the screen; without the trim the
        // line cap spends its whole budget on blanks.
        let screen = "first\nsecond\nthird\n" + String(repeating: "\n", count: 40)
        XCTAssertEqual(TerminalText.transcript(screen: screen, limit: 2), "second\nthird")
        XCTAssertEqual(TerminalText.transcript(screen: screen, limit: nil), "first\nsecond\nthird")
    }

    func testScreenTranscriptOfAnEmptyBufferIsEmpty() {
        XCTAssertEqual(TerminalText.transcript(screen: String(repeating: "\n", count: 24), limit: 20), "")
    }

    // MARK: - recentRead: full reads prefer the interpreted buffer

    private func snapshot(raw: String, screen: String?, total: Int? = nil) -> TerminalText.RecentReadSnapshot {
        TerminalText.RecentReadSnapshot(
            screen: screen, buffer: raw, total: total ?? raw.utf8.count, dropped: 0, generation: gen)
    }

    func testFullReadIsServedFromTheInterpretedBuffer() {
        // SwiftTerm already interpreted the redraw run, so its rows are clean even
        // though the raw stream they came from is not.
        let snap = snapshot(raw: spinnerFrame("|", "Working") + "\u{001B}[2KDone\n",
                            screen: "$ build\nDone\n\n\n")
        let read = TerminalText.recentRead(snap, since: nil, lineLimit: 20)
        XCTAssertEqual(read.text, "$ build\nDone")
        XCTAssertFalse(read.truncated)
        XCTAssertEqual(read.cursor, "\(gen):\(snap.total)")
    }

    func testFullReadFallsBackToTheRawStreamWithNoInterpretedText() {
        // A snapshot carrying neither a screen nor an alternate-screen frame: the
        // raw stream is all there is. TerminalAlternateScreenReadTests covers the
        // alternate screen itself, which is served from the emulator.
        let snap = snapshot(raw: spinnerFrame("|", "Working") + "\u{001B}[2KDone\n", screen: nil)
        let read = TerminalText.recentRead(snap, since: nil, lineLimit: 20)
        XCTAssertEqual(read.text, "Done\n", "the fallback normalizes the raw stream the same way")
        XCTAssertFalse(read.truncated)
    }

    // MARK: - recentRead: cursor deltas stay on the raw byte stream

    func testDeltaReadNormalizesTheSliceAndIgnoresTheScreen() {
        let prefix = "already seen\n"
        let raw = prefix + "\u{001B}]0;title\u{0007}" + spinnerFrame("|", "Working") + "\u{001B}[2Kfresh\n"
        let snap = snapshot(raw: raw, screen: "the whole screen\nincluding history\n")
        let read = TerminalText.recentRead(snap, since: "\(gen):\(prefix.utf8.count)", lineLimit: 20)
        XCTAssertEqual(read.text, "fresh\n", "a delta is what arrived after the cursor, normalized")
        XCTAssertFalse(read.truncated)
        XCTAssertEqual(read.cursor, "\(gen):\(raw.utf8.count)")
    }

    func testStaleCursorResyncsFromTheInterpretedBufferAndStaysTruncated() {
        let snap = snapshot(raw: spinnerFrame("|", "Working") + "\u{001B}[2KDone\n",
                            screen: "$ build\nDone\n\n\n")
        for stale in ["\(gen + 1):0", "not-a-cursor", "\(gen):999999"] {
            let read = TerminalText.recentRead(snap, since: stale, lineLimit: 20)
            XCTAssertTrue(read.truncated, "cursor '\(stale)' must re-sync, not error")
            XCTAssertEqual(read.text, "$ build\nDone", "the re-sync is a full read: same clean source")
            XCTAssertEqual(read.cursor, "\(gen):\(snap.total)")
        }
    }

    func testStaleCursorWithNoInterpretedTextResyncsFromTheRawStream() {
        let snap = snapshot(raw: "line one\nline two\n", screen: nil)
        let read = TerminalText.recentRead(snap, since: "\(gen + 1):0", lineLimit: 20)
        XCTAssertTrue(read.truncated)
        XCTAssertEqual(read.text, "line one\nline two\n")
    }
}
