import XCTest
@testable import Cortland

/// Covers the window-free decisions behind the changes pane's keyboard
/// review: change blocks, file and block movement, `v`'s advance, the stage
/// decision, and which key presses the pane takes.
@MainActor
final class ChangesReviewTests: XCTestCase {
    private typealias Review = ChangesReview

    private func file(_ path: String, _ top: CGFloat, _ bottom: CGFloat) -> Review.FileSpan {
        Review.FileSpan(path: path, top: top, bottom: bottom)
    }

    private func block(_ path: String, _ index: Int, _ top: CGFloat, _ bottom: CGFloat) -> Review.BlockSpan {
        Review.BlockSpan(path: path, index: index, top: top, bottom: bottom)
    }

    private func viewport(_ top: CGFloat, _ bottom: CGFloat) -> Review.Viewport {
        Review.Viewport(top: top, bottom: bottom)
    }

    /// The rendered text covered by each block.
    private func blockTexts(_ diff: String) -> [String] {
        let rendered = InlineDiffRenderer.render(diff)
        return Review.blockRanges(in: rendered).map { (rendered.string as NSString).substring(with: $0) }
    }

    // MARK: - Change blocks

    func testAdjacentRemovedAndAddedLinesFormOneBlock() {
        let diff = "@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n"
        XCTAssertEqual(blockTexts(diff), ["b\nB\n"])
    }

    func testContextLinesSplitBlocks() {
        let diff = "@@ -1,5 +1,5 @@\n-a\n+A\n b\n c\n-d\n"
        XCTAssertEqual(blockTexts(diff), ["a\nA\n", "d\n"])
    }

    func testHunkHeaderRowIsNotABlock() {
        let diff = "@@ -1,2 +1,2 @@ func first()\n-a\n+A\n@@ -10,2 +10,2 @@ func second()\n-b\n+B\n"
        let rendered = InlineDiffRenderer.render(diff).string
        XCTAssertTrue(rendered.contains("func second()"))
        let texts = blockTexts(diff)
        XCTAssertEqual(texts, ["a\nA\n", "b\nB\n"])
        XCTAssertFalse(texts.contains { $0.contains("func") })
    }

    func testAllAddedFileIsOneBlock() {
        let diff = "diff --git a/n.txt b/n.txt\nnew file mode 100644\n--- /dev/null\n+++ b/n.txt\n@@ -0,0 +1,3 @@\n+one\n+two\n+three\n"
        XCTAssertEqual(blockTexts(diff), ["one\ntwo\nthree\n"])
    }

    func testContextOnlyDiffHasNoBlocks() {
        XCTAssertEqual(blockTexts("@@ -1,2 +1,2 @@\n a\n b\n"), [])
    }

    // MARK: - Next and previous file

    private let files = [
        ChangesReview.FileSpan(path: "a", top: 0, bottom: 100),
        ChangesReview.FileSpan(path: "b", top: 110, bottom: 300),
        ChangesReview.FileSpan(path: "c", top: 310, bottom: 500)
    ]

    func testFileMovesForwardAndBack() {
        let view = viewport(0, 400)
        XCTAssertEqual(Review.movedFile("a", forward: true, files: files, viewport: view), "b")
        XCTAssertEqual(Review.movedFile("b", forward: true, files: files, viewport: view), "c")
        XCTAssertEqual(Review.movedFile("c", forward: false, files: files, viewport: view), "b")
    }

    func testFileDoesNotWrapAtEitherEnd() {
        XCTAssertNil(Review.movedFile("c", forward: true, files: files, viewport: viewport(300, 600)))
        XCTAssertNil(Review.movedFile("a", forward: false, files: files, viewport: viewport(0, 400)))
    }

    func testFirstFilePressPicksTheFileAtTheTop() {
        XCTAssertEqual(Review.movedFile(nil, forward: true, files: files, viewport: viewport(150, 400)), "b")
        XCTAssertEqual(Review.movedFile(nil, forward: false, files: files, viewport: viewport(0, 400)), "a")
    }

    func testOffScreenCurrentFileRebasesToTheTopOfTheViewport() {
        // "a" scrolled away; the viewport starts inside "b".
        let view = viewport(320, 480)
        XCTAssertEqual(Review.rebasedFile("a", files: files, viewport: view), "c")
        XCTAssertEqual(Review.movedFile("a", forward: false, files: files, viewport: viewport(150, 300)), "a")
        XCTAssertEqual(Review.movedFile("a", forward: true, files: files, viewport: viewport(150, 300)), "c")
    }

    func testVisibleCurrentFileIsKept() {
        XCTAssertEqual(Review.rebasedFile("b", files: files, viewport: viewport(0, 200)), "b")
        XCTAssertEqual(Review.rebasedFile(nil, files: files, viewport: viewport(0, 200)), "a")
    }

    func testRemovedCurrentFileFallsToNextThenPrevious() {
        XCTAssertEqual(Review.fileAfterRemoval("b", paths: ["a", "b", "c"]), "b")
        XCTAssertEqual(Review.fileAfterRemoval("b", paths: ["a", "c"]), "c")
        XCTAssertEqual(Review.fileAfterRemoval("d", paths: ["a", "c"]), "c")
        XCTAssertNil(Review.fileAfterRemoval("b", paths: []))
    }

    // MARK: - Next and previous block

    /// "a" has two blocks, "b" is collapsed or has none (so it contributes
    /// nothing), "c" has one.
    private let blocks = [
        ChangesReview.BlockSpan(path: "a", index: 0, top: 40, bottom: 60),
        ChangesReview.BlockSpan(path: "a", index: 1, top: 80, bottom: 95),
        ChangesReview.BlockSpan(path: "c", index: 0, top: 350, bottom: 380)
    ]

    func testBlockMovesAcrossFilesSkippingFilesWithoutBlocks() {
        let view = viewport(0, 1000)
        let next = Review.movedBlock(.init(path: "a", index: 1), forward: true, blocks: blocks, viewport: view)
        XCTAssertEqual(next, block("c", 0, 350, 380))
        let back = Review.movedBlock(.init(path: "c", index: 0), forward: false, blocks: blocks, viewport: view)
        XCTAssertEqual(back, block("a", 1, 80, 95))
    }

    func testBlockDoesNotWrap() {
        let view = viewport(0, 1000)
        XCTAssertNil(Review.movedBlock(.init(path: "c", index: 0), forward: true, blocks: blocks, viewport: view))
        XCTAssertNil(Review.movedBlock(.init(path: "a", index: 0), forward: false, blocks: blocks, viewport: view))
    }

    func testWithNoCurrentBlockStartsFromTheViewportTop() {
        let view = viewport(70, 400)
        XCTAssertEqual(Review.movedBlock(nil, forward: true, blocks: blocks, viewport: view), block("a", 1, 80, 95))
        XCTAssertEqual(Review.movedBlock(nil, forward: false, blocks: blocks, viewport: view), block("a", 0, 40, 60))
        XCTAssertNil(Review.movedBlock(nil, forward: true, blocks: blocks, viewport: viewport(400, 800)))
        XCTAssertNil(Review.movedBlock(nil, forward: false, blocks: blocks, viewport: viewport(0, 300)))
    }

    func testOffScreenCurrentBlockRebasesToTheViewport() {
        // Current block a#0 sits above a viewport that starts at 300.
        let view = viewport(300, 700)
        XCTAssertEqual(Review.movedBlock(.init(path: "a", index: 0), forward: true, blocks: blocks, viewport: view), block("c", 0, 350, 380))
        XCTAssertEqual(Review.movedBlock(.init(path: "a", index: 0), forward: false, blocks: blocks, viewport: view), block("a", 1, 80, 95))
    }

    func testCurrentBlockMissingFromTheListRebases() {
        // Its file was collapsed, so its blocks are no longer offered.
        let view = viewport(0, 1000)
        XCTAssertEqual(Review.movedBlock(.init(path: "b", index: 0), forward: true, blocks: blocks, viewport: view), block("a", 0, 40, 60))
    }

    // MARK: - Viewed advance

    func testViewedAdvancesToTheNextUnviewedFile() {
        let viewed: Set<String> = ["a", "b"]
        XCTAssertEqual(Review.nextUnviewed(after: "a", paths: ["a", "b", "c"], isViewed: viewed.contains), "c")
    }

    func testViewedStaysPutWhenNothingIsLeftAfter() {
        let viewed: Set<String> = ["b", "c"]
        XCTAssertNil(Review.nextUnviewed(after: "b", paths: ["a", "b", "c"], isViewed: viewed.contains))
        XCTAssertNil(Review.nextUnviewed(after: "c", paths: ["a", "b", "c"], isViewed: viewed.contains))
    }

    // MARK: - Stage or unstage

    private func entry(_ staged: Character, _ unstaged: Character) -> GitStatusEntry {
        GitStatusEntry(path: "f", stagedStatus: staged, unstagedStatus: unstaged)
    }

    func testFullyStagedOnlyWhenNothingUnstagedOrUntrackedRemains() {
        XCTAssertTrue(Review.isFullyStaged(entry("M", " ")))
        XCTAssertTrue(Review.isFullyStaged(entry("A", " ")))
        XCTAssertTrue(Review.isFullyStaged(entry("D", " ")))
        XCTAssertFalse(Review.isFullyStaged(entry("M", "M")))
        XCTAssertFalse(Review.isFullyStaged(entry(" ", "M")))
        XCTAssertFalse(Review.isFullyStaged(entry("?", "?")))
        XCTAssertFalse(Review.isFullyStaged(entry("U", "U")))
    }

    func testStageActionFromSection() {
        func section(fullyStaged: Bool, conflicted: Bool = false) -> ChangeSection {
            ChangeSection(relativePath: "f", diff: "", isConflicted: conflicted, status: .modified, isFullyStaged: fullyStaged)
        }
        XCTAssertEqual(Review.stageAction(for: section(fullyStaged: false)), .stage)
        XCTAssertEqual(Review.stageAction(for: section(fullyStaged: true)), .unstage)
        XCTAssertNil(Review.stageAction(for: section(fullyStaged: false, conflicted: true)))
    }

    // MARK: - Key events

    func testThePlainReviewKeysAreHandled() {
        let plain: [String: Review.Key] = [
            "j": .nextBlock, "k": .previousBlock,
            "v": .toggleViewed, "x": .toggleCollapsed, "s": .stage, "o": .open
        ]
        for (characters, key) in plain {
            XCTAssertEqual(Review.Key(characters: characters, modifierFlags: []), key, characters)
        }
        XCTAssertEqual(Review.Key(characters: "J", modifierFlags: .shift), .nextFile)
        XCTAssertEqual(Review.Key(characters: "K", modifierFlags: .shift), .previousFile)
        XCTAssertEqual(Review.Key(characters: "j", modifierFlags: .shift), .nextFile)
    }

    func testCapsLockDoesNotTurnBlockKeysIntoFileKeys() {
        XCTAssertEqual(Review.Key(characters: "J", modifierFlags: .capsLock), .nextBlock)
        XCTAssertEqual(Review.Key(characters: "j", modifierFlags: .capsLock), .nextBlock)
        XCTAssertEqual(Review.Key(characters: "K", modifierFlags: .capsLock), .previousBlock)
        XCTAssertEqual(Review.Key(characters: "V", modifierFlags: .capsLock), .toggleViewed)
        XCTAssertEqual(Review.Key(characters: "J", modifierFlags: [.capsLock, .shift]), .nextFile)
    }

    func testShiftWithAnActionLetterIsNotAReviewKey() {
        for characters in ["V", "X", "S", "O", "v"] {
            XCTAssertNil(Review.Key(characters: characters, modifierFlags: .shift), characters)
        }
    }

    func testCommandControlOrOptionIsNeverConsumed() {
        for characters in ["j", "k", "J", "K", "v", "x", "s", "o"] {
            for modifier: NSEvent.ModifierFlags in [.command, .control, .option, [.command, .shift]] {
                XCTAssertNil(Review.Key(characters: characters, modifierFlags: modifier), "\(characters) \(modifier)")
            }
        }
    }

    func testOtherKeysAreNotConsumed() {
        for characters in [" ", "a", "\r", key(NSDownArrowFunctionKey), key(NSPageDownFunctionKey), ""] {
            XCTAssertNil(Review.Key(characters: characters, modifierFlags: []), characters)
        }
        XCTAssertNil(Review.Key(characters: nil, modifierFlags: []))
    }

    // MARK: - Scrolling keys

    private func key(_ functionKey: Int) -> String {
        String(UnicodeScalar(UInt32(functionKey))!)
    }

    /// Viewport top 1000, height 400, document 5000, line 19.
    private func scrollTop(_ characters: String?, _ flags: NSEvent.ModifierFlags = []) -> CGFloat? {
        Review.scrollTop(
            characters: characters,
            modifierFlags: flags,
            visibleTop: 1000,
            viewportHeight: 400,
            documentHeight: 5000,
            lineHeight: 19
        )
    }

    func testEachScrollingKeyMovesTheViewport() {
        XCTAssertEqual(scrollTop(key(NSUpArrowFunctionKey), .function), 1000 - 57)
        XCTAssertEqual(scrollTop(key(NSDownArrowFunctionKey), .function), 1000 + 57)
        XCTAssertEqual(scrollTop(key(NSPageDownFunctionKey)), 1000 + 381)
        XCTAssertEqual(scrollTop(" "), 1000 + 381)
        XCTAssertEqual(scrollTop(key(NSPageUpFunctionKey)), 1000 - 381)
        XCTAssertEqual(scrollTop(" ", .shift), 1000 - 381)
        XCTAssertEqual(scrollTop(key(NSHomeFunctionKey)), 0)
        XCTAssertEqual(scrollTop(key(NSEndFunctionKey)), 4600)
    }

    func testScrollingKeysWithCommandControlOrOptionAreNotHandled() {
        let keys = [" ", key(NSUpArrowFunctionKey), key(NSDownArrowFunctionKey), key(NSPageUpFunctionKey),
                    key(NSPageDownFunctionKey), key(NSHomeFunctionKey), key(NSEndFunctionKey)]
        for characters in keys {
            for modifier: NSEvent.ModifierFlags in [.command, .control, .option] {
                XCTAssertNil(scrollTop(characters, modifier), "\(characters) \(modifier)")
            }
        }
    }

    func testOtherKeysDoNotScroll() {
        for characters in ["a", "j", "\r", "\t", key(NSLeftArrowFunctionKey), "", "  "] {
            XCTAssertNil(scrollTop(characters), characters)
        }
        XCTAssertNil(scrollTop(nil))
    }
}
