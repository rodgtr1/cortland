import XCTest
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
