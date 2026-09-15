import XCTest
import SwiftTerm
@testable import Cortland

/// Verifies the byte-level classification that decides which mouse reports are
/// forwarded to inline apps. A misclassification here would either leak hover
/// motion to Claude Code (the bug we're fixing) or, worse, swallow real clicks.
final class MouseReportClassifierTests: XCTestCase {
    private func slice(_ s: String) -> ArraySlice<UInt8> {
        Array(s.utf8)[...]
    }

    // ESC [ < Cb ; Cx ; Cy (M|m). Motion sets bit 5 (0x20) in Cb.
    private func sgr(_ cb: Int, _ x: Int, _ y: Int, press: Bool = true) -> ArraySlice<UInt8> {
        slice("\u{1B}[<\(cb);\(x);\(y)\(press ? "M" : "m")")
    }

    func testSGRMotionIsDetected() {
        // Pure hover (no button) in anyEvent mode: button 3 + motion 32 = 35.
        XCTAssertTrue(MouseReportClassifier.isMouseMotionReport(sgr(35, 10, 5)))
        // Left-button drag: button 0 + motion 32 = 32.
        XCTAssertTrue(MouseReportClassifier.isMouseMotionReport(sgr(32, 1, 1)))
    }

    func testSGRClicksAreNotMotion() {
        // Left press (button 0), no motion bit.
        XCTAssertFalse(MouseReportClassifier.isMouseMotionReport(sgr(0, 10, 5)))
        // Left release.
        XCTAssertFalse(MouseReportClassifier.isMouseMotionReport(sgr(0, 10, 5, press: false)))
        // Right press (button 2).
        XCTAssertFalse(MouseReportClassifier.isMouseMotionReport(sgr(2, 3, 4)))
        // Wheel up (button 64) — high bit, but not the 0x20 motion bit.
        XCTAssertFalse(MouseReportClassifier.isMouseMotionReport(sgr(64, 3, 4)))
    }

    func testX10MotionIsDetected() {
        // ESC [ M Cb Cx Cy, each byte offset by 32. Cb = 32(offset) + 32(motion).
        let bytes: [UInt8] = [0x1B, 0x5B, 0x4D, UInt8(32 + 32), UInt8(32 + 1), UInt8(32 + 1)]
        XCTAssertTrue(MouseReportClassifier.isMouseMotionReport(bytes[...]))
    }

    func testX10ClickIsNotMotion() {
        // Cb = 32(offset) + 0(button, no motion).
        let bytes: [UInt8] = [0x1B, 0x5B, 0x4D, 32, 33, 33]
        XCTAssertFalse(MouseReportClassifier.isMouseMotionReport(bytes[...]))
    }

    func testNonMouseSequencesAreNotMotion() {
        XCTAssertFalse(MouseReportClassifier.isMouseMotionReport(slice("\u{1B}[I"))) // focus in
        XCTAssertFalse(MouseReportClassifier.isMouseMotionReport(slice("\u{1B}[A"))) // up arrow
        XCTAssertFalse(MouseReportClassifier.isMouseMotionReport(slice("a")))         // keystroke
        XCTAssertFalse(MouseReportClassifier.isMouseMotionReport(slice("")))          // empty
    }

    func testTerminalGeneratedReportStillClassifiesFocusAndMouse() {
        XCTAssertTrue(MouseReportClassifier.isTerminalGeneratedReport(slice("\u{1B}[I")))   // focus in
        XCTAssertTrue(MouseReportClassifier.isTerminalGeneratedReport(slice("\u{1B}[O")))   // focus out
        XCTAssertTrue(MouseReportClassifier.isTerminalGeneratedReport(sgr(35, 10, 5)))      // mouse
        XCTAssertFalse(MouseReportClassifier.isTerminalGeneratedReport(slice("\u{1B}[A")))  // arrow key
        XCTAssertFalse(MouseReportClassifier.isTerminalGeneratedReport(slice("hello")))     // typing
    }

    // The button-state tracking that separates a hover (drop) from a drag
    // (forward, so TUI selection still works). A misclassification here either
    // re-leaks hover flicker or wedges a button "down" so later hovers forward.
    func testSGRPressAndReleaseAreClassified() {
        XCTAssertEqual(MouseReportClassifier.buttonTransition(sgr(0, 12, 11)), .press)               // left press
        XCTAssertEqual(MouseReportClassifier.buttonTransition(sgr(0, 12, 11, press: false)), .release) // left release
        XCTAssertEqual(MouseReportClassifier.buttonTransition(sgr(2, 3, 4)), .press)                 // right press
    }

    func testMotionAndWheelAreNotButtonTransitions() {
        // Hover (button 0 + motion) and any-event hover (button 3 + motion):
        // motion never changes button state, regardless of the button bits.
        XCTAssertEqual(MouseReportClassifier.buttonTransition(sgr(32, 12, 11)), .none) // left-coded hover/drag motion
        XCTAssertEqual(MouseReportClassifier.buttonTransition(sgr(35, 12, 11)), .none) // no-button hover motion
        // Wheel up/down are not button holds.
        XCTAssertEqual(MouseReportClassifier.buttonTransition(sgr(64, 3, 4)), .none)   // wheel up
        XCTAssertEqual(MouseReportClassifier.buttonTransition(sgr(65, 3, 4)), .none)   // wheel down
    }

    func testNonMouseSequencesAreNotButtonTransitions() {
        XCTAssertEqual(MouseReportClassifier.buttonTransition(slice("\u{1B}[I")), .none) // focus in
        XCTAssertEqual(MouseReportClassifier.buttonTransition(slice("\u{1B}[A")), .none) // arrow key
        XCTAssertEqual(MouseReportClassifier.buttonTransition(slice("a")), .none)        // keystroke
    }

    func testX10PressAndReleaseAreClassified() {
        // ESC [ M Cb Cx Cy, offset 32. Button 0 press vs. button 3 (release).
        let press: [UInt8] = [0x1B, 0x5B, 0x4D, 32, 33, 33]
        let release: [UInt8] = [0x1B, 0x5B, 0x4D, 32 + 3, 33, 33]
        XCTAssertEqual(MouseReportClassifier.buttonTransition(press[...]), .press)
        XCTAssertEqual(MouseReportClassifier.buttonTransition(release[...]), .release)
    }
}

/// The press-time decision that lets a drag select text over an app that has
/// mouse reporting on. Getting it wrong either makes Codex output impossible
/// to copy again or steals plain drags from vim and lazygit.
final class SelectionGestureTests: XCTestCase {
    func testPlainDragSelectsOnNormalScreen() {
        XCTAssertTrue(SelectionGesture.bypassesMouseReporting(shiftHeld: false, isAlternateScreen: false))
    }

    func testPlainDragGoesToAlternateScreenApp() {
        XCTAssertFalse(SelectionGesture.bypassesMouseReporting(shiftHeld: false, isAlternateScreen: true))
    }

    func testShiftDragSelectsEverywhere() {
        XCTAssertTrue(SelectionGesture.bypassesMouseReporting(shiftHeld: true, isAlternateScreen: true))
        XCTAssertTrue(SelectionGesture.bypassesMouseReporting(shiftHeld: true, isAlternateScreen: false))
    }
}

/// Drives a real SwiftTerm terminal to pin down when a scroll invalidates a
/// selection anchored to buffer indices: never while the scrollback still has
/// room, and on every scroll once it is full and trimming.
final class SelectionScrollInvalidationTests: XCTestCase {
    private final class Delegate: TerminalDelegate {
        var scrolls = 0
        var movedOnScroll: [Bool] = []
        var terminal: Terminal?
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
        func scrolled(source: Terminal, yDisp: Int) {
            scrolls += 1
            movedOnScroll.append(SelectionGesture.scrollMovedExistingLines(in: source))
        }
    }

    /// Three rows plus two lines of scrollback: the buffer holds five lines,
    /// so the first two scrolls append and every scroll after that trims.
    func testScrollsOnlyInvalidateOnceScrollbackIsFull() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 20, rows: 3, scrollback: 2))
        for i in 1...6 {
            terminal.feed(text: "line \(i)\r\n")
        }
        // Two line feeds move the cursor down the screen; the four after scroll.
        XCTAssertEqual(delegate.scrolls, 4)
        XCTAssertEqual(delegate.movedOnScroll, [false, false, true, true])
    }

    func testScrollInsideARegionInvalidates() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 20, rows: 5, scrollback: 100))
        // DECSTBM: rows 2 to 4 scroll, the rest stay put. Cursor moves to home.
        terminal.feed(text: "\u{1B}[2;4r")
        terminal.feed(text: "\u{1B}[4;1Hx\r\n")
        XCTAssertEqual(delegate.scrolls, 1)
        XCTAssertEqual(delegate.movedOnScroll, [true])
    }

    func testAlternateScreenScrollInvalidates() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 20, rows: 2, scrollback: 100))
        terminal.feed(text: "\u{1B}[?1049h")
        terminal.feed(text: "a\r\nb\r\nc\r\n")
        XCTAssertGreaterThan(delegate.scrolls, 0)
        XCTAssertFalse(delegate.movedOnScroll.contains(false))
    }
}

/// The configured scrollback has to reach SwiftTerm, whose own default is 500
/// lines; before this, the setting was decoded and then ignored.
final class TerminalScrollbackTests: XCTestCase {
    private final class Delegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    func testNegativeMeansTheUnlimitedCap() {
        XCTAssertEqual(TerminalScrollback.lines(forConfigured: -1), TerminalScrollback.unlimitedCap)
        XCTAssertEqual(TerminalScrollback.lines(forConfigured: 10_000), 10_000)
        XCTAssertEqual(TerminalScrollback.lines(forConfigured: 0), 0)
    }

    /// 600 lines through a 3-row terminal trims under SwiftTerm's 500-line
    /// default and keeps everything once the history is raised the way the
    /// view controller does it.
    func testChangingScrollbackKeepsMoreHistory() {
        let delegate = Delegate()
        let trimmed = Terminal(delegate: delegate, options: TerminalOptions(cols: 20, rows: 3))
        for i in 1...600 { trimmed.feed(text: "line \(i)\r\n") }
        XCTAssertNil(trimmed.getScrollInvariantLine(row: 0), "the default history should have trimmed")

        let raised = Terminal(delegate: delegate, options: TerminalOptions(cols: 20, rows: 3))
        raised.changeScrollback(TerminalScrollback.lines(forConfigured: 10_000))
        for i in 1...600 { raised.feed(text: "line \(i)\r\n") }
        XCTAssertNotNil(raised.getScrollInvariantLine(row: 0), "10,000 lines of history must hold 600 lines")
    }
}
