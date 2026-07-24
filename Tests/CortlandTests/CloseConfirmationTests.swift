import XCTest
@testable import Cortland

/// Wording and gating rules for the close confirmation: which closes prompt at
/// all, and what the alert says when busy agents, unsaved editor buffers, or
/// both are on the line.
@MainActor
final class CloseConfirmationTests: XCTestCase {

    // MARK: - Quit / window close

    func testQuitDoesNotConfirmWhenNothingWouldBeLost() {
        XCTAssertNil(CloseConfirmation.quit(busyPaneCount: 0, modifiedFileNames: []))
    }

    func testQuitWithBusyAgentsKeepsItsExistingWording() {
        let one = CloseConfirmation.quit(busyPaneCount: 1, modifiedFileNames: [])
        XCTAssertEqual(one?.messageText, "An agent is still working")
        XCTAssertEqual(one?.informativeText,
                       "Quitting Cortland will end this session and any running commands. Quit anyway?")
        XCTAssertEqual(one?.proceedButtonTitle, "Quit Anyway")
        XCTAssertEqual(one?.offersSave, false)

        let many = CloseConfirmation.quit(busyPaneCount: 3, modifiedFileNames: [])
        XCTAssertEqual(many?.messageText, "3 agents are still working")
        XCTAssertEqual(many?.informativeText,
                       "Quitting Cortland will end these sessions and any running commands. Quit anyway?")
    }

    func testQuitWithUnsavedEditorNamesTheFileAndOffersSave() {
        let confirmation = CloseConfirmation.quit(busyPaneCount: 0, modifiedFileNames: ["notes.md"])
        XCTAssertEqual(confirmation?.messageText, "notes.md has unsaved changes")
        XCTAssertEqual(confirmation?.informativeText, "Unsaved edits to notes.md will be lost. Quit anyway?")
        XCTAssertEqual(confirmation?.offersSave, true)
    }

    func testQuitWithBothCoversAgentsAndFilesInOneAlert() {
        let confirmation = CloseConfirmation.quit(busyPaneCount: 2, modifiedFileNames: ["a.swift", "b.swift"])
        XCTAssertEqual(confirmation?.messageText, "2 agents are still working")
        XCTAssertEqual(confirmation?.informativeText,
                       "Unsaved edits to a.swift and b.swift will be lost. "
                       + "Quitting Cortland will end these sessions and any running commands. Quit anyway?")
        XCTAssertEqual(confirmation?.offersSave, true)
    }

    func testQuitElidesLongFileLists() {
        let confirmation = CloseConfirmation.quit(
            busyPaneCount: 0,
            modifiedFileNames: ["a.txt", "b.txt", "c.txt", "d.txt"]
        )
        XCTAssertEqual(confirmation?.messageText, "4 files have unsaved changes")
        XCTAssertEqual(confirmation?.informativeText,
                       "Unsaved edits to a.txt, b.txt, and 2 more will be lost. Quit anyway?")
    }

    // MARK: - Pane / tab close

    /// The mouse X path: `confirm_close` off, nothing unsaved — stays silent,
    /// as it has since sessions were exempted from mouse-close prompts.
    func testMouseCloseOfCleanPanesDoesNotConfirm() {
        XCTAssertNil(CloseConfirmation.close(
            target: "pane",
            terminalPaneCount: 1,
            busyPaneCount: 1,
            modifiedFileNames: [],
            confirmSessionClose: false
        ))
    }

    /// …but an unsaved buffer prompts on that same path, since nothing else
    /// stands between the click and losing the edits.
    func testMouseCloseWithUnsavedEditorConfirms() {
        let confirmation = CloseConfirmation.close(
            target: "tab",
            terminalPaneCount: 1,
            busyPaneCount: 0,
            modifiedFileNames: ["draft.md"],
            confirmSessionClose: false
        )
        XCTAssertEqual(confirmation?.messageText, "Close this tab?")
        XCTAssertEqual(confirmation?.informativeText, "Unsaved edits to draft.md will be lost.")
        XCTAssertEqual(confirmation?.proceedButtonTitle, "Close")
        XCTAssertEqual(confirmation?.offersSave, true)
    }

    func testKeyboardCloseKeepsItsExistingWording() {
        let busy = CloseConfirmation.close(
            target: "pane",
            terminalPaneCount: 1,
            busyPaneCount: 1,
            modifiedFileNames: [],
            confirmSessionClose: true
        )
        XCTAssertEqual(busy?.messageText, "Close this pane?")
        XCTAssertEqual(busy?.informativeText,
                       "An agent is still working here. Closing will end its session and any running commands.")
        XCTAssertEqual(busy?.offersSave, false)

        let idle = CloseConfirmation.close(
            target: "tab",
            terminalPaneCount: 2,
            busyPaneCount: 0,
            modifiedFileNames: [],
            confirmSessionClose: true
        )
        XCTAssertEqual(idle?.informativeText,
                       "Closing will end its 2 terminal sessions and any running commands.")
    }

    func testKeyboardCloseCombinesUnsavedEditsWithTheSessionWarning() {
        let confirmation = CloseConfirmation.close(
            target: "tab",
            terminalPaneCount: 1,
            busyPaneCount: 1,
            modifiedFileNames: ["main.swift"],
            confirmSessionClose: true
        )
        XCTAssertEqual(confirmation?.informativeText,
                       "Unsaved edits to main.swift will be lost. An agent is still working here. "
                       + "Closing will end its session and any running commands.")
        XCTAssertEqual(confirmation?.offersSave, true)
    }

    /// A saved editor pane holds no session and no unsaved work, so ⇧⌘W on it
    /// has nothing to warn about even with `confirm_close` on.
    func testKeyboardCloseOfASavedEditorPaneDoesNotConfirm() {
        XCTAssertNil(CloseConfirmation.close(
            target: "pane",
            terminalPaneCount: 0,
            busyPaneCount: 0,
            modifiedFileNames: [],
            confirmSessionClose: true
        ))
    }
}
