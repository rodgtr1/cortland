import XCTest
import SwiftTerm
@testable import Cortland

/// Exercises ghost-suggestion marking on visible-screen reads: dim/gray text
/// anchored at the cursor gets wrapped in the ⟦suggested, not typed: …⟧
/// marker, while typed text, TUI frames, and dim decoration elsewhere on the
/// row stay untouched. Screens are built by feeding real escape sequences
/// through a headless SwiftTerm instance.
@MainActor
final class GhostTextTests: XCTestCase {
    private func terminal(feeding text: String) -> Terminal {
        let headless = HeadlessTerminal(onEnd: { _ in })
        let terminal = headless.terminal!
        terminal.feed(text: text)
        return terminal
    }

    private func markedCursorLine(feeding text: String) -> String? {
        let terminal = terminal(feeding: text)
        let cursor = terminal.getCursorLocation()
        guard let line = terminal.getLine(row: cursor.y) else { return nil }
        return GhostText.markedLine(line, cursorCol: cursor.x)
    }

    // MARK: - markedLine on real screens

    func testDimSuggestionAtCursorIsMarked() {
        // "> fix the " typed, dim completion after it, cursor left on the
        // first suggested character (column 11, 1-based) — the shape Claude
        // Code's autosuggest draws.
        let marked = markedCursorLine(feeding: "> fix the \u{1B}[2mbug in parser\u{1B}[0m\u{1B}[11G")
        XCTAssertEqual(marked, "> fix the ⟦suggested, not typed: bug in parser⟧")
    }

    func testGray256SuggestionIsMarked() {
        let marked = markedCursorLine(feeding: "> \u{1B}[38;5;240mrun the tests\u{1B}[0m\u{1B}[3G")
        XCTAssertEqual(marked, "> ⟦suggested, not typed: run the tests⟧")
    }

    func testTrueColorGraySuggestionIsMarked() {
        let marked = markedCursorLine(feeding: "> \u{1B}[38;2;128;128;128mtry harder\u{1B}[0m\u{1B}[3G")
        XCTAssertEqual(marked, "> ⟦suggested, not typed: try harder⟧")
    }

    func testSuggestionStartingWithSpaceIsMarked() {
        let marked = markedCursorLine(feeding: "> fix\u{1B}[2m the bug\u{1B}[0m\u{1B}[6G")
        XCTAssertEqual(marked, "> fix⟦suggested, not typed:  the bug⟧")
    }

    func testTrailingDimSpacesAreTrimmedFromMarker() {
        let marked = markedCursorLine(feeding: "> \u{1B}[2mgo   \u{1B}[0m\u{1B}[3G")
        XCTAssertNotNil(marked)
        XCTAssertTrue(marked?.contains("⟦suggested, not typed: go⟧") == true,
                      "trailing dim padding should stay outside the marker: \(marked ?? "nil")")
    }

    func testPlainTypedLineIsNotMarked() {
        // Cursor rests on an unwritten cell after typed text — nothing to mark.
        XCTAssertNil(markedCursorLine(feeding: "> fix the bug"))
    }

    func testNormalTextAtCursorIsNotMarked() {
        // Cursor moved back onto the user's own (default-styled) text.
        XCTAssertNil(markedCursorLine(feeding: "> fix the bug\u{1B}[3G"))
    }

    func testDimBoxBorderAtCursorIsNotMarked() {
        // Claude Code draws its input-box frame dim; a border at the cursor is
        // decoration, not a suggestion.
        XCTAssertNil(markedCursorLine(feeding: "> \u{1B}[2m│\u{1B}[0m\u{1B}[3G"))
    }

    func testDimPaddingBeforeBorderIsNotMarked() {
        // Dim spaces up to a dim border: no visible suggested character.
        XCTAssertNil(markedCursorLine(feeding: "> \u{1B}[2m   │\u{1B}[0m\u{1B}[3G"))
    }

    func testDimRunStopsAtBorder() {
        // Suggestion butts up against the dim frame: the border and anything
        // beyond stay outside the marker.
        let marked = markedCursorLine(feeding: "> \u{1B}[2mgo│rest\u{1B}[0m\u{1B}[3G")
        XCTAssertEqual(marked, "> ⟦suggested, not typed: go⟧│rest")
    }

    func testDimTextElsewhereOnRowIsNotMarked() {
        // Dim hint text left of the cursor (e.g. "? for shortcuts") isn't
        // anchored at the cursor, so the read stays plain.
        XCTAssertNil(markedCursorLine(feeding: "\u{1B}[2mhint\u{1B}[0m> fix\u{1B}[10G"))
    }

    // MARK: - isGhostStyled

    func testDimStyleIsGhost() {
        XCTAssertTrue(GhostText.isGhostStyled(fg: .defaultColor, bg: .defaultColor, style: [.dim]))
    }

    func testInverseAndExplicitBackgroundAreNotGhost() {
        XCTAssertFalse(GhostText.isGhostStyled(fg: .defaultColor, bg: .defaultColor, style: [.dim, .inverse]))
        XCTAssertFalse(GhostText.isGhostStyled(fg: .ansi256(code: 240), bg: .ansi256(code: 236), style: []))
    }

    func testGrayForegroundsAreGhost() {
        XCTAssertTrue(GhostText.isGhostStyled(fg: .ansi256(code: 8), bg: .defaultColor, style: []))
        XCTAssertTrue(GhostText.isGhostStyled(fg: .ansi256(code: 245), bg: .defaultColor, style: []))
        XCTAssertTrue(GhostText.isGhostStyled(fg: .trueColor(red: 128, green: 128, blue: 128), bg: .defaultColor, style: []))
    }

    func testNonGrayForegroundsAreNotGhost() {
        XCTAssertFalse(GhostText.isGhostStyled(fg: .defaultColor, bg: .defaultColor, style: []))
        XCTAssertFalse(GhostText.isGhostStyled(fg: .ansi256(code: 252), bg: .defaultColor, style: []),
                       "near-white gray is ordinary theme text")
        XCTAssertFalse(GhostText.isGhostStyled(fg: .ansi256(code: 2), bg: .defaultColor, style: []))
        XCTAssertFalse(GhostText.isGhostStyled(fg: .trueColor(red: 34, green: 34, blue: 34), bg: .defaultColor, style: []),
                       "near-black is a light theme's ordinary text")
        XCTAssertFalse(GhostText.isGhostStyled(fg: .trueColor(red: 230, green: 230, blue: 230), bg: .defaultColor, style: []),
                       "near-white is a dark theme's ordinary text")
        XCTAssertFalse(GhostText.isGhostStyled(fg: .trueColor(red: 100, green: 140, blue: 90), bg: .defaultColor, style: []),
                       "colored text is never a suggestion")
    }

    // MARK: - ghostRun edge cases

    func testGhostRunRejectsCursorOutOfRange() {
        XCTAssertNil(GhostText.ghostRun(kinds: [.ghost], cursorCol: -1))
        XCTAssertNil(GhostText.ghostRun(kinds: [.ghost], cursorCol: 1))
        XCTAssertNil(GhostText.ghostRun(kinds: [], cursorCol: 0))
    }

    func testGhostRunTrimsTrailingSpacesAndStopsAtOther() {
        XCTAssertEqual(GhostText.ghostRun(kinds: [.ghost, .ghostSpace, .ghost, .ghostSpace, .other, .ghost],
                                          cursorCol: 0), 0..<3)
        XCTAssertNil(GhostText.ghostRun(kinds: [.ghostSpace, .ghostSpace, .other], cursorCol: 0))
    }
}
