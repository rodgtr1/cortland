import XCTest
@testable import Cortland

/// Covers the window-free decisions behind the changes pane's review
/// comments: the message, which rows a selection covers, re-anchoring after
/// a refresh, the bar's send mode, which agents qualify, and the keys.
@MainActor
final class ChangesReviewCommentsTests: XCTestCase {
    private typealias Comments = ChangesComments

    private func line(_ kind: DiffGutterLine.Kind, _ text: String, _ number: Int? = nil) -> Comments.Line {
        Comments.Line(kind: kind, number: number, text: text)
    }

    private func comment(
        _ path: String,
        _ location: Comments.Location?,
        lines: [Comments.Line],
        text: String,
        anchor: Comments.Anchor = .attached(0..<1)
    ) -> Comments.Comment {
        Comments.Comment(id: UUID(), path: path, text: text, lines: lines, location: location, anchor: anchor)
    }

    private func at(_ first: Int, _ last: Int? = nil) -> Comments.Location {
        Comments.Location(first: first, last: last ?? first)
    }

    private func rows(_ diff: String) -> (text: NSAttributedString, rows: [Comments.Row]) {
        let rendered = InlineDiffRenderer.render(diff)
        return (rendered, Comments.rows(in: rendered))
    }

    /// The character range from `start` in the line containing `from` to
    /// `end` characters into the line containing `to`.
    private func range(in text: NSAttributedString, from: String, offset: Int, to: String, endOffset: Int) -> NSRange {
        let string = text.string as NSString
        let start = string.range(of: from).location + offset
        let end = string.range(of: to).location + endOffset
        return NSRange(location: start, length: end - start)
    }

    private let header = "Review comments on the uncommitted changes in this repository. Please address each one."

    // MARK: - Message

    func testMessageIntroForEachSource() {
        let comments = [comment("a.txt", at(1), lines: [line(.added, "x", 1)], text: "Ok.")]
        let uncommitted = Comments.message(for: comments, intro: ChangesSource.uncommitted.commentIntro)
        XCTAssertEqual(uncommitted.components(separatedBy: "\n").first, header)

        let branch = Comments.message(for: comments, intro: ChangesSource.branch(defaultBranch: "main").commentIntro)
        XCTAssertEqual(
            branch.components(separatedBy: "\n").first,
            "Review comments on the changes committed on this branch (compared with main). Please address each one."
        )
        // Only the first line differs.
        XCTAssertEqual(
            uncommitted.components(separatedBy: "\n").dropFirst(),
            branch.components(separatedBy: "\n").dropFirst()
        )
    }

    func testMessageMatchesTheDocumentedFormat() {
        let message = Comments.message(for: [
            comment("Sources/App/Service.swift", at(301, 303), lines: [line(.added, "    let added = 3", 301)], text: "This shadows the outer value."),
            comment(
                "Sources/App/Service.swift", at(244),
                lines: [line(.removed, "    let args = [\"diff\"]"), line(.added, "    let args = [\"diff\", \"--no-color\"]", 244)],
                text: "Use a constant for the flag."
            )
        ], intro: header)
        XCTAssertEqual(message, """
        \(header)

        1. Sources/App/Service.swift:244
           > -    let args = ["diff"]
           > +    let args = ["diff", "--no-color"]
           Use a constant for the flag.

        2. Sources/App/Service.swift:301-303
           > +    let added = 3
           This shadows the outer value.
        """)
    }

    func testSingleNumberedLineGivesOneNumber() {
        let (text, rows) = rows("@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n")
        let selection = range(in: text, from: "B", offset: 0, to: "B", endOffset: 1)
        let covered = Comments.rowRange(touching: selection, rows: rows)!
        XCTAssertEqual(Comments.location(of: covered, rows: rows), at(2))
    }

    func testSeveralNumberedLinesGiveARange() {
        let (text, rows) = rows("@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n")
        let selection = range(in: text, from: "a", offset: 0, to: "c", endOffset: 1)
        let covered = Comments.rowRange(touching: selection, rows: rows)!
        XCTAssertEqual(Comments.location(of: covered, rows: rows), at(1, 3))
    }

    func testRemovedOnlyLinesBorrowTheFollowingNumber() {
        let (text, rows) = rows("@@ -1,3 +1,2 @@\n a\n-b\n c\n")
        let covered = Comments.rowRange(touching: range(in: text, from: "b", offset: 0, to: "b", endOffset: 1), rows: rows)!
        XCTAssertEqual(Comments.location(of: covered, rows: rows), at(2))
    }

    func testRemovedOnlyLinesAtTheEndBorrowThePrecedingNumber() {
        let (text, rows) = rows("@@ -1,2 +1,1 @@\n a\n-b\n")
        let covered = Comments.rowRange(touching: range(in: text, from: "b", offset: 0, to: "b", endOffset: 1), rows: rows)!
        XCTAssertEqual(Comments.location(of: covered, rows: rows), at(1))
    }

    func testRemovedOnlyFileHasNoNumberAndShowsJustThePath() {
        let (_, rows) = rows("@@ -1,2 +0,0 @@\n-a\n-b\n")
        XCTAssertNil(Comments.location(of: 0..<2, rows: rows))
        let message = Comments.message(for: [
            comment("gone.txt", nil, lines: Comments.lines(in: 0..<2, rows: rows), text: "Why delete this?")
        ], intro: header)
        XCTAssertEqual(message, "\(header)\n\n1. gone.txt\n   > -a\n   > -b\n   Why delete this?")
    }

    func testQuoteStopsAtEightLines() {
        let lines = (1...11).map { (n: Int) in line(.added, "line \(n)", n) }
        let message = Comments.message(for: [comment("a.txt", at(1, 11), lines: lines, text: "Too long.")], intro: header)
        let quoted = message.components(separatedBy: "\n").filter { $0.hasPrefix("   >") }
        XCTAssertEqual(quoted.count, 9)
        XCTAssertEqual(quoted[7], "   > +line 8")
        XCTAssertEqual(quoted[8], "   > ... (3 more lines)")
    }

    func testEightLinesAreQuotedWithoutAMoreLine() {
        let lines = (1...8).map { (n: Int) in line(.context, "line \(n)", n) }
        let message = Comments.message(for: [comment("a.txt", at(1, 8), lines: lines, text: "Fine.")], intro: header)
        XCTAssertFalse(message.contains("more lines"))
        XCTAssertTrue(message.contains("   >  line 8"))
    }

    func testMultiLineCommentTextIsIndented() {
        let message = Comments.message(for: [
            comment("a.txt", at(4), lines: [line(.added, "x", 4)], text: "First.\nSecond.\n\nFourth.")
        ], intro: header)
        XCTAssertTrue(message.hasSuffix("   > +x\n   First.\n   Second.\n   \n   Fourth."))
    }

    func testCommentsAreOrderedByPathThenLine() {
        let message = Comments.message(for: [
            comment("b.swift", at(5), lines: [line(.added, "b5", 5)], text: "third"),
            comment("a.swift", at(20), lines: [line(.added, "a20", 20)], text: "second"),
            comment("a.swift", at(3), lines: [line(.added, "a3", 3)], text: "first")
        ], intro: header)
        let headings = message.components(separatedBy: "\n").filter { $0.first?.isNumber == true }
        XCTAssertEqual(headings, ["1. a.swift:3", "2. a.swift:20", "3. b.swift:5"])
    }

    func testDetachedCommentCarriesTheNote() {
        let message = Comments.message(for: [
            comment("a.txt", at(7), lines: [line(.added, "old", 7)], text: "Rename it.", anchor: .detached)
        ], intro: header)
        XCTAssertTrue(message.hasSuffix("1. a.txt:7\n   > +old\n   (This code has changed since the comment was written.)\n   Rename it."))
    }

    func testAttachedCommentHasNoNote() {
        let message = Comments.message(for: [comment("a.txt", at(7), lines: [line(.added, "x", 7)], text: "Ok.")], intro: header)
        XCTAssertFalse(message.contains("has changed"))
    }

    // MARK: - Selection to rows

    func testPartialLineSelectionCoversWholeLines() {
        let (text, rows) = rows("@@ -1,3 +1,3 @@\n alpha\n-beta\n+BETA\n gamma\n")
        let selection = range(in: text, from: "alpha", offset: 3, to: "beta", endOffset: 2)
        let covered = Comments.rowRange(touching: selection, rows: rows)!
        XCTAssertEqual(Comments.lines(in: covered, rows: rows), [line(.context, "alpha", 1), line(.removed, "beta")])
    }

    func testSelectionEndingAtALineStartDoesNotTakeThatLine() {
        let (text, rows) = rows("@@ -1,2 +1,2 @@\n alpha\n gamma\n")
        let selection = range(in: text, from: "alpha", offset: 0, to: "gamma", endOffset: 0)
        let covered = Comments.rowRange(touching: selection, rows: rows)!
        XCTAssertEqual(Comments.lines(in: covered, rows: rows), [line(.context, "alpha", 1)])
    }

    func testHunkHeaderIsExcludedFromASelection() {
        let (text, rows) = rows("@@ -1,2 +1,2 @@ func first()\n a\n-b\n+B\n")
        let selection = range(in: text, from: "func first()", offset: 0, to: "\na\n", endOffset: 2)
        let covered = Comments.rowRange(touching: selection, rows: rows)!
        XCTAssertEqual(Comments.lines(in: covered, rows: rows), [line(.context, "a", 1)])
    }

    func testSeparatorIsLeftOutOfTheQuote() {
        let (text, rows) = rows("@@ -1,1 +1,1 @@\n-a\n+A\n@@ -10,1 +10,1 @@\n-b\n+B\n")
        XCTAssertTrue(text.string.contains("⋯"))
        let covered = Comments.rowRange(touching: NSRange(location: 0, length: text.length), rows: rows)!
        XCTAssertEqual(
            Comments.lines(in: covered, rows: rows),
            [line(.removed, "a"), line(.added, "A", 1), line(.removed, "b"), line(.added, "B", 10)]
        )
        XCTAssertEqual(Comments.location(of: covered, rows: rows), at(1, 10))
    }

    func testSelectionTouchingNoDiffLineYieldsNothing() {
        let (text, rows) = rows("@@ -1,1 +1,1 @@ func first()\n-a\n+A\n")
        let headerOnly = range(in: text, from: "func", offset: 0, to: "first", endOffset: 3)
        XCTAssertNil(Comments.rowRange(touching: headerOnly, rows: rows))
        XCTAssertNil(Comments.rowRange(touching: NSRange(location: 0, length: 0), rows: rows))
    }

    func testGutterRowLookupSkipsHeaders() {
        let (text, rows) = rows("@@ -1,1 +1,1 @@ func first()\n-a\n+A\n")
        XCTAssertNil(Comments.row(atCharacter: 0, rows: rows))
        let a = (text.string as NSString).range(of: "A").location
        XCTAssertEqual(Comments.row(atCharacter: a, rows: rows).map { rows[$0].line }, line(.added, "A", 1))
    }

    // MARK: - Re-anchoring

    func testUniqueMatchMovesTheComment() {
        let quoted = [line(.removed, "b"), line(.added, "B", 2)]
        let (_, rows) = rows("@@ -1,5 +1,6 @@\n new\n a\n-b\n+B\n c\n")
        let moved = Comments.reanchor(quoted, in: rows)!
        XCTAssertEqual(Comments.lines(in: moved, rows: rows).map(\.text), ["b", "B"])
        XCTAssertEqual(Comments.location(of: moved, rows: rows), at(3))
    }

    func testMissingLinesDetach() {
        let quoted = [line(.removed, "b"), line(.added, "B", 2)]
        let (_, rows) = rows("@@ -1,3 +1,3 @@\n a\n-b\n+C\n c\n")
        XCTAssertNil(Comments.reanchor(quoted, in: rows))
    }

    func testSameTextWithAnotherKindDoesNotMatch() {
        let (_, rows) = rows("@@ -1,2 +1,2 @@\n a\n b\n")
        XCTAssertNil(Comments.reanchor([line(.added, "b", 2)], in: rows))
    }

    func testTwoMatchesDetach() {
        let quoted = [line(.added, "x", 2)]
        let (_, rows) = rows("@@ -1,2 +1,4 @@\n a\n+x\n b\n+x\n")
        XCTAssertNil(Comments.reanchor(quoted, in: rows))
    }

    func testMatchAcrossASeparatorSkipsIt() {
        let quoted = [line(.added, "A", 1), line(.removed, "b")]
        let (_, rows) = rows("@@ -1,1 +1,1 @@\n-a\n+A\n@@ -10,1 +10,1 @@\n-b\n+B\n")
        let moved = Comments.reanchor(quoted, in: rows)!
        XCTAssertEqual(Comments.lines(in: moved, rows: rows), [line(.added, "A", 1), line(.removed, "b")])
    }

    // MARK: - Send mode

    func testSendModeFollowsTheNumberOfAgents() {
        let one = Comments.Agent(id: UUID(), label: "opus · repo")
        let two = Comments.Agent(id: UUID(), label: "codex · repo")
        XCTAssertEqual(Comments.SendMode(agents: []), .copy)
        XCTAssertEqual(Comments.SendMode(agents: [one]), .send(one))
        XCTAssertEqual(Comments.SendMode(agents: [one, two]), .choose([one, two]))
    }

    func testCountText() {
        XCTAssertEqual(Comments.countText(1), "1 comment")
        XCTAssertEqual(Comments.countText(3), "3 comments")
    }

    // MARK: - Candidate agents

    func testCandidatesAreAgentPanesInsideTheRepository() {
        func pane(_ label: String, _ directory: String?, agent: Bool = true) -> Comments.AgentPane {
            Comments.AgentPane(id: UUID(), label: label, directory: directory, runsAgent: agent)
        }
        let panes = [
            pane("root", "/repo"),
            pane("root slash", "/repo/"),
            pane("inside", "/repo/Sources/App"),
            pane("outside", "/elsewhere"),
            pane("sibling", "/repo-other"),
            pane("parent", "/"),
            pane("shell", "/repo", agent: false),
            pane("unknown", nil)
        ]
        XCTAssertEqual(
            Comments.candidates(panes, repositoryPath: "/repo").map(\.label),
            ["root", "root slash", "inside"]
        )
    }

    func testIsWithin() {
        XCTAssertTrue(Comments.isWithin("/repo", root: "/repo"))
        XCTAssertTrue(Comments.isWithin("/repo/a", root: "/repo/"))
        XCTAssertFalse(Comments.isWithin("/repo-other", root: "/repo"))
        XCTAssertFalse(Comments.isWithin("/rep", root: "/repo"))
    }

    // MARK: - Keys

    func testCIsTheCommentKey() {
        XCTAssertEqual(ChangesReview.Key(characters: "c", modifierFlags: []), .comment)
        XCTAssertEqual(ChangesReview.Key(characters: "C", modifierFlags: .capsLock), .comment)
        XCTAssertNil(ChangesReview.Key(characters: "c", modifierFlags: .shift))
        XCTAssertNil(ChangesReview.Key(characters: "c", modifierFlags: .command))
        XCTAssertNil(ChangesReview.Key(characters: "c", modifierFlags: .control))
        XCTAssertNil(ChangesReview.Key(characters: "c", modifierFlags: .option))
    }

    func testCommandReturnSendsOnlyWhileCommentsExist() {
        XCTAssertTrue(Comments.isSendKey(characters: "\r", modifierFlags: .command, hasComments: true))
        XCTAssertTrue(Comments.isSendKey(characters: "\u{3}", modifierFlags: [.command, .numericPad], hasComments: true))
        XCTAssertFalse(Comments.isSendKey(characters: "\r", modifierFlags: .command, hasComments: false))
    }

    func testOtherReturnsAreNotTheSendKey() {
        XCTAssertFalse(Comments.isSendKey(characters: "\r", modifierFlags: [], hasComments: true))
        XCTAssertFalse(Comments.isSendKey(characters: "\r", modifierFlags: [.command, .shift], hasComments: true))
        XCTAssertFalse(Comments.isSendKey(characters: "\r", modifierFlags: [.command, .option], hasComments: true))
        XCTAssertFalse(Comments.isSendKey(characters: "s", modifierFlags: .command, hasComments: true))
        XCTAssertNil(ChangesReview.Key(characters: "\r", modifierFlags: .command))
    }
}
