import XCTest
@testable import Cortland

/// Covers the window-free decisions behind Send Selection to Agent: which
/// lines a selection covers, the reference, the message, the popover's
/// primary button, and when the command applies.
@MainActor
final class EditorSelectionPromptTests: XCTestCase {
    private typealias Prompt = EditorSelectionPrompt

    private func range(_ text: String, _ location: Int, _ length: Int) -> Prompt.LineRange {
        Prompt.lineRange(in: text, selection: NSRange(location: location, length: length))
    }

    private func lines(_ first: Int, _ last: Int? = nil) -> Prompt.LineRange {
        Prompt.LineRange(first: first, last: last ?? first)
    }

    // MARK: - Line range

    func testSelectionWithinOneLine() {
        // "two" sits at 4..<7.
        XCTAssertEqual(range("one\ntwo\nthree\n", 5, 2), lines(2))
    }

    func testSelectionAcrossLines() {
        XCTAssertEqual(range("one\ntwo\nthree\n", 1, 8), lines(1, 3))
    }

    func testSelectionEndingAtColumnZeroLeavesThatLineOut() {
        // Lines 1 and 2 with their line breaks, ending at the start of line 3.
        XCTAssertEqual(range("one\ntwo\nthree\n", 0, 8), lines(1, 2))
    }

    func testEmptySelectionIsTheCaretLine() {
        XCTAssertEqual(range("one\ntwo\nthree\n", 6, 0), lines(2))
        XCTAssertEqual(range("one\ntwo\nthree\n", 4, 0), lines(2))
    }

    func testCaretOnLastLineWithoutTrailingNewline() {
        let text = "one\ntwo"
        XCTAssertEqual(range(text, 7, 0), lines(2))
        XCTAssertEqual(range(text, 5, 0), lines(2))
    }

    func testCaretOnLastLineWithTrailingNewline() {
        let text = "one\ntwo\n"
        XCTAssertEqual(range(text, 6, 0), lines(2))
        // After the final line break the caret is on the empty line 3.
        XCTAssertEqual(range(text, 8, 0), lines(3))
    }

    func testSelectionCoveringTheWholeDocument() {
        XCTAssertEqual(range("one\ntwo\nthree\n", 0, 14), lines(1, 3))
        XCTAssertEqual(range("one\ntwo\nthree", 0, 13), lines(1, 3))
    }

    func testEmptyDocument() {
        XCTAssertEqual(range("", 0, 0), lines(1))
    }

    func testCRLFLineEndings() {
        let text = "one\r\ntwo\r\nthree\r\n"
        // "two" at 5..<8.
        XCTAssertEqual(range(text, 5, 3), lines(2))
        // Lines 1 and 2 with their CRLFs, ending at column 0 of line 3.
        XCTAssertEqual(range(text, 0, 10), lines(1, 2))
        XCTAssertEqual(range(text, 0, 11), lines(1, 3))
        XCTAssertEqual(range(text, 10, 0), lines(3))
        XCTAssertEqual(Prompt.lines(in: text, range: lines(1, 3)), ["one", "two", "three"])
    }

    func testLinesInRange() {
        XCTAssertEqual(Prompt.lines(in: "one\ntwo\nthree\n", range: lines(2, 3)), ["two", "three"])
        XCTAssertEqual(Prompt.lines(in: "one\ntwo\n", range: lines(3)), [""])
    }

    // MARK: - Reference

    func testReferenceIsRepositoryRelativeInsideARepository() {
        XCTAssertEqual(
            Prompt.reference(filePath: "/repo/Sources/App/Foo.swift", repositoryRoot: "/repo", lines: lines(12, 18)),
            "Sources/App/Foo.swift:12-18"
        )
        XCTAssertEqual(
            Prompt.reference(filePath: "/repo/Foo.swift", repositoryRoot: "/repo/", lines: lines(3)),
            "Foo.swift:3"
        )
    }

    func testReferenceIsAbsoluteOutsideARepository() {
        XCTAssertEqual(
            Prompt.reference(filePath: "/notes/todo.txt", repositoryRoot: nil, lines: lines(4)),
            "/notes/todo.txt:4"
        )
        // A sibling whose name starts with the root's is not inside it.
        XCTAssertEqual(
            Prompt.reference(filePath: "/repo-other/a.swift", repositoryRoot: "/repo", lines: lines(1, 2)),
            "/repo-other/a.swift:1-2"
        )
    }

    // MARK: - Message

    func testMessageOrder() {
        let message = Prompt.message(
            instruction: "  Rename this.  ",
            reference: "Foo.swift:2-3",
            lines: ["let a = 1", "let b = 2"],
            isDirty: false
        )
        XCTAssertEqual(message, "Rename this.\n\nFoo.swift:2-3\n\n```\nlet a = 1\nlet b = 2\n```")
    }

    func testMessageCapsQuotedLines() {
        let all = (1...55).map { "line \($0)" }
        let message = Prompt.message(instruction: "Fix", reference: "a.swift:1-55", lines: all, isDirty: false)
        XCTAssertTrue(message.contains("line 40\n```"))
        XCTAssertFalse(message.contains("line 41"))
        XCTAssertTrue(message.contains("15 more lines"))

        let one = Prompt.message(instruction: "Fix", reference: "a.swift:1-41", lines: Array(all.prefix(41)), isDirty: false)
        XCTAssertTrue(one.contains("1 more line not quoted"))

        let exact = Prompt.message(instruction: "Fix", reference: "a.swift:1-40", lines: Array(all.prefix(40)), isDirty: false)
        XCTAssertFalse(exact.contains("more line"))
    }

    func testUnsavedNoteOnlyWhenDirty() {
        let clean = Prompt.message(instruction: "Fix", reference: "a.swift:1", lines: ["x"], isDirty: false)
        let dirty = Prompt.message(instruction: "Fix", reference: "a.swift:1", lines: ["x"], isDirty: true)
        XCTAssertFalse(clean.contains(Prompt.unsavedNote))
        XCTAssertTrue(dirty.hasSuffix("\n\n" + Prompt.unsavedNote))
    }

    func testGeneratedTextHasNoEmOrEnDash() {
        let message = Prompt.message(
            instruction: "Fix",
            reference: Prompt.reference(filePath: "/r/a.swift", repositoryRoot: "/r", lines: lines(1, 60)),
            lines: (1...60).map { "l\($0)" },
            isDirty: true
        )
        let buttons = [
            Prompt.primaryButton(for: .copy, instruction: "x"),
            Prompt.primaryButton(for: .send(agent("Opus · Tab")), instruction: "x"),
            Prompt.primaryButton(for: .choose([agent("A"), agent("B")]), instruction: "x")
        ].map(\.title)
        for text in [message, Prompt.unsavedNote] + buttons {
            XCTAssertFalse(text.contains("\u{2014}"), text)
            XCTAssertFalse(text.contains("\u{2013}"), text)
        }
    }

    func testCodeContainingAFenceGetsALongerFence() {
        let code = ["let doc = \"\"\"", "```swift", "print(1)", "```", "\"\"\""]
        let message = Prompt.message(instruction: "Explain", reference: "a.swift:1-5", lines: code, isDirty: false)
        XCTAssertTrue(message.hasPrefix("Explain\n\na.swift:1-5\n\n````\n"))
        XCTAssertTrue(message.hasSuffix("\n````"))
        XCTAssertEqual(Prompt.fence(for: ["a ````` b"]), "``````")
        XCTAssertEqual(Prompt.fence(for: ["`x`"]), "```")
    }

    // MARK: - Primary button

    private func agent(_ label: String) -> ChangesComments.Agent {
        ChangesComments.Agent(id: UUID(), label: label)
    }

    func testPrimaryButtonWithNoAgentsCopies() {
        let button = Prompt.primaryButton(for: ChangesComments.SendMode(agents: []), instruction: "Fix it")
        XCTAssertEqual(button, Prompt.PrimaryButton(title: "Copy", isEnabled: true, action: .copy))
    }

    func testPrimaryButtonWithOneAgentSendsAndNamesIt() {
        let opus = agent("Opus · cortland")
        let button = Prompt.primaryButton(for: ChangesComments.SendMode(agents: [opus]), instruction: "Fix it")
        XCTAssertEqual(button, Prompt.PrimaryButton(title: "Send to Opus · cortland", isEnabled: true, action: .send(opus)))
    }

    func testPrimaryButtonWithSeveralAgentsOffersAMenu() {
        let agents = [agent("A"), agent("B")]
        let button = Prompt.primaryButton(for: ChangesComments.SendMode(agents: agents), instruction: "Fix it")
        XCTAssertEqual(button, Prompt.PrimaryButton(title: "Send to Agent", isEnabled: true, action: .chooseFromMenu(agents)))
    }

    func testPrimaryButtonDisabledWhileInstructionIsEmpty() {
        for mode in [ChangesComments.SendMode.copy, .send(agent("A")), .choose([agent("A"), agent("B")])] {
            XCTAssertFalse(Prompt.primaryButton(for: mode, instruction: "").isEnabled)
            XCTAssertFalse(Prompt.primaryButton(for: mode, instruction: "  \n ").isEnabled)
        }
    }

    // MARK: - Applies

    func testAppliesOnlyToAnEditorPaneInEditMode() {
        XCTAssertTrue(Prompt.applies(isEditorPane: true, isReadMode: false))
        XCTAssertFalse(Prompt.applies(isEditorPane: true, isReadMode: true))
        XCTAssertFalse(Prompt.applies(isEditorPane: false, isReadMode: false))
    }

    func testShortcutIsCommandL() {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0,
            context: nil, characters: "l", charactersIgnoringModifiers: "l", isARepeat: false, keyCode: 37
        )!
        XCTAssertEqual(KeyboardCommandRouter().command(for: event, tabCount: 1), .sendSelectionToAgent)
        XCTAssertEqual(KeyboardCommand.sendSelectionToAgent.displayShortcut, "⌘L")
    }
}
