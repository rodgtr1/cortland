import XCTest
@testable import Cortland

@MainActor
final class InlineDiffRendererTests: XCTestCase {
    private let sampleDiff = """
    diff --git a/doc.mdx b/doc.mdx
    index 3eff452..d8eabce 100644
    --- a/doc.mdx
    +++ b/doc.mdx
    @@ -71,3 +71,3 @@ spec:
     environment: production
    -# whether by directly despatching the workflow.
    +# whether by directly dispatching the workflow.
     actor: octocat
    """

    func testRenderHidesGitMetadata() {
        let rendered = InlineDiffRenderer.render(sampleDiff).string

        XCTAssertFalse(rendered.contains("diff --git"))
        XCTAssertFalse(rendered.contains("index 3eff452"))
        XCTAssertFalse(rendered.contains("@@"))
        XCTAssertFalse(rendered.contains("+++"))
    }

    func testRenderNumbersContextAndAddedLinesButNotRemoved() {
        let rendered = InlineDiffRenderer.render(sampleDiff).string
        let lines = rendered.components(separatedBy: "\n")

        // Context line carries the hunk's starting line number.
        XCTAssertTrue(lines[0].hasSuffix("environment: production"))
        XCTAssertTrue(lines[0].contains("71"))

        // Removed line: blank gutter, no number anywhere in the gutter.
        XCTAssertTrue(lines[1].hasSuffix("despatching the workflow."))
        XCTAssertTrue(lines[1].hasPrefix("       "))

        // Added line gets the new file's number (72).
        XCTAssertTrue(lines[2].hasSuffix("dispatching the workflow."))
        XCTAssertTrue(lines[2].contains("72"))

        // Following context resumes numbering (73).
        XCTAssertTrue(lines[3].hasSuffix("actor: octocat"))
        XCTAssertTrue(lines[3].contains("73"))
    }

    func testRemovedLineRendersDirectlyAboveAddedLine() {
        let rendered = InlineDiffRenderer.render(sampleDiff).string
        let lines = rendered.components(separatedBy: "\n")
        let removedIndex = lines.firstIndex { $0.contains("despatching") }
        let addedIndex = lines.firstIndex { $0.contains("dispatching") }

        XCTAssertNotNil(removedIndex)
        XCTAssertEqual(removedIndex.map { $0 + 1 }, addedIndex)
    }

    func testIntralineDifferenceFindsChangedCharacters() {
        let (old, new) = InlineDiffRenderer.intralineDifference(
            "# directly despatching the workflow.",
            "# directly dispatching the workflow."
        )

        // "despatching" vs "dispatching": common prefix ends after "d",
        // common suffix starts at "spatching…", leaving "e" vs "i".
        XCTAssertEqual(old, NSRange(location: 12, length: 1))
        XCTAssertEqual(new, NSRange(location: 12, length: 1))
    }

    func testIntralineDifferenceSkipsWhollyDifferentLines() {
        let (old, new) = InlineDiffRenderer.intralineDifference(
            "completely different content here",
            "nothing in common with that line"
        )

        XCTAssertNil(old)
        XCTAssertNil(new)
    }

    func testIntralineDifferenceHandlesInsertion() {
        let (old, new) = InlineDiffRenderer.intralineDifference(
            "programatically issues",
            "programmatically issues"
        )

        // Pure insertion: nothing to emphasize on the removed side.
        XCTAssertNil(old)
        XCTAssertEqual(new?.length, 1)
    }

    func testConflictDiffRendersMarkersAndNumbersAllLines() {
        let conflictDiff = """
        diff --git a/f.txt b/f.txt
        conflict
        --- a/f.txt
        +++ b/f.txt
        @@ -1,7 +1,7 @@
         one
         <<<<<<< HEAD
         main-change
         =======
         feature-change
         >>>>>>> b81eefa (feat)
         three
        """

        let rendered = InlineDiffRenderer.render(conflictDiff)
        let lines = rendered.string.components(separatedBy: "\n")

        // The "conflict" metadata line is hidden, the markers are not.
        XCTAssertFalse(lines[0].contains("conflict"))
        XCTAssertTrue(lines[0].hasSuffix("one"))
        XCTAssertTrue(lines[0].contains("1"))
        XCTAssertTrue(lines[1].hasSuffix("<<<<<<< HEAD"))
        XCTAssertTrue(lines[3].hasSuffix("======="))
        XCTAssertTrue(lines[5].hasSuffix(">>>>>>> b81eefa (feat)"))
        XCTAssertTrue(lines[6].hasSuffix("three"))
        XCTAssertTrue(lines[6].contains("7"))

        // Ours/theirs sections carry distinct full-width tints (the custom
        // lineFillColor attribute, painted by DiffLineBackgroundLayoutManager);
        // lines outside the conflict carry none.
        func fillColor(ofLineContaining needle: String) -> NSColor? {
            let nsString = rendered.string as NSString
            let location = nsString.range(of: needle).location
            guard location != NSNotFound else { return nil }
            return rendered.attribute(InlineDiffRenderer.lineFillColor, at: location, effectiveRange: nil) as? NSColor
        }

        let oursBG = fillColor(ofLineContaining: "main-change")
        let theirsBG = fillColor(ofLineContaining: "feature-change")
        XCTAssertNotNil(oursBG)
        XCTAssertNotNil(theirsBG)
        XCTAssertNotEqual(oursBG, theirsBG)
        XCTAssertNil(fillColor(ofLineContaining: "three"))
        XCTAssertNotNil(fillColor(ofLineContaining: "<<<<<<< HEAD"))
    }

    func testNonConflictDiffDoesNotTintMarkerLookalikes() {
        // A normal diff whose context happens to contain a marker-like line
        // must render untinted: conflict handling is opt-in via "conflict".
        let diff = """
        diff --git a/doc.md b/doc.md
        index 111..222 100644
        --- a/doc.md
        +++ b/doc.md
        @@ -1,3 +1,3 @@
         <<<<<<< HEAD
        -old
        +new
        """

        let rendered = InlineDiffRenderer.render(diff)
        let location = (rendered.string as NSString).range(of: "<<<<<<<").location
        XCTAssertNil(rendered.attribute(InlineDiffRenderer.lineFillColor, at: location, effectiveRange: nil) as? NSColor)
    }

    func testUntrackedFileDiffRendersAllAddedWithNumbers() {
        let newFileDiff = """
        diff --git a/new.txt b/new.txt
        new file
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1,2 @@
        +first line
        +second line
        """

        let rendered = InlineDiffRenderer.render(newFileDiff).string
        let lines = rendered.components(separatedBy: "\n")

        XCTAssertTrue(lines[0].contains("1"))
        XCTAssertTrue(lines[0].hasSuffix("first line"))
        XCTAssertTrue(lines[1].contains("2"))
        XCTAssertTrue(lines[1].hasSuffix("second line"))
    }
}
