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

    /// The gutter metadata on the line starting at `lineIndex` of the
    /// rendered string.
    private func gutterLine(_ rendered: NSAttributedString, line lineIndex: Int) -> DiffGutterLine? {
        let lines = rendered.string.components(separatedBy: "\n")
        let location = lines.prefix(lineIndex).reduce(0) { $0 + ($1 as NSString).length + 1 }
        return rendered.attribute(InlineDiffRenderer.gutterLine, at: location, effectiveRange: nil) as? DiffGutterLine
    }

    func testRenderHidesGitMetadata() {
        let rendered = InlineDiffRenderer.render(sampleDiff).string

        XCTAssertFalse(rendered.contains("diff --git"))
        XCTAssertFalse(rendered.contains("index 3eff452"))
        XCTAssertFalse(rendered.contains("@@"))
        XCTAssertFalse(rendered.contains("+++"))
    }

    func testRenderedStringHoldsOnlyCode() {
        let rendered = InlineDiffRenderer.render(sampleDiff).string
        let lines = rendered.components(separatedBy: "\n")

        // Hunk header text first, then each line exactly as in the file: no
        // line numbers, gutter padding, or +/- prefixes to copy along.
        XCTAssertEqual(lines, [
            "spec:",
            "environment: production",
            "# whether by directly despatching the workflow.",
            "# whether by directly dispatching the workflow.",
            "actor: octocat",
            ""
        ])
    }

    func testEachLineCarriesNumberAndKind() {
        let rendered = InlineDiffRenderer.render(sampleDiff)

        // The hunk header row is unnumbered and has no gutter.
        XCTAssertNil(gutterLine(rendered, line: 0))

        // Context line carries the hunk's starting line number.
        XCTAssertEqual(gutterLine(rendered, line: 1)?.kind, .context)
        XCTAssertEqual(gutterLine(rendered, line: 1)?.number, 71)

        // Removed line: no number.
        XCTAssertEqual(gutterLine(rendered, line: 2)?.kind, .removed)
        XCTAssertNil(gutterLine(rendered, line: 2)?.number)

        // Added line gets the new file's number (72).
        XCTAssertEqual(gutterLine(rendered, line: 3)?.kind, .added)
        XCTAssertEqual(gutterLine(rendered, line: 3)?.number, 72)

        // Following context resumes numbering (73).
        XCTAssertEqual(gutterLine(rendered, line: 4)?.kind, .context)
        XCTAssertEqual(gutterLine(rendered, line: 4)?.number, 73)
    }

    func testCodeLinesHangInTheGutterIndent() {
        let rendered = InlineDiffRenderer.render(sampleDiff)
        let location = (rendered.string as NSString).range(of: "environment").location
        let style = rendered.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle

        XCTAssertNotNil(style)
        XCTAssertGreaterThan(style?.firstLineHeadIndent ?? 0, 0)
        XCTAssertEqual(style?.headIndent, style?.firstLineHeadIndent)
    }

    func testHunkWithoutTrailingTextSeparatesOnlyBetweenHunks() {
        let diff = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1,1 +1,1 @@
        -one
        +uno
        @@ -10,1 +10,1 @@
        -ten
        +diez
        @@ -20,1 +20,1 @@ func twenty()
        -twenty
        +veinte
        """

        let lines = InlineDiffRenderer.render(diff).string.components(separatedBy: "\n")

        XCTAssertEqual(lines, [
            "one", "uno",
            "⋯",
            "ten", "diez",
            "func twenty()",
            "twenty", "veinte",
            ""
        ])
    }

    func testChangeCountsSkipFileHeaders() {
        let diff = """
        diff --git a/a.txt b/a.txt
        index 111..222 100644
        --- a/a.txt
        +++ b/a.txt
        @@ -1,4 +1,4 @@
         keep
        -old
        +new
        +extra
        ---- removed line that starts with dashes
        diff --git a/b.txt b/b.txt
        --- a/b.txt
        +++ b/b.txt
        @@ -1 +1 @@
        +another
        """

        let counts = InlineDiffRenderer.changeCounts(diff)
        XCTAssertEqual(counts.added, 3)
        XCTAssertEqual(counts.removed, 2)
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
        XCTAssertEqual(lines[0], "one")
        XCTAssertEqual(gutterLine(rendered, line: 0)?.number, 1)
        XCTAssertEqual(lines[1], "<<<<<<< HEAD")
        XCTAssertEqual(lines[3], "=======")
        XCTAssertEqual(lines[5], ">>>>>>> b81eefa (feat)")
        XCTAssertEqual(lines[6], "three")
        XCTAssertEqual(gutterLine(rendered, line: 6)?.number, 7)
        XCTAssertEqual(gutterLine(rendered, line: 6)?.kind, .context)

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

        let rendered = InlineDiffRenderer.render(newFileDiff)
        let lines = rendered.string.components(separatedBy: "\n")

        XCTAssertEqual(lines[0], "first line")
        XCTAssertEqual(gutterLine(rendered, line: 0)?.number, 1)
        XCTAssertEqual(gutterLine(rendered, line: 0)?.kind, .added)
        XCTAssertEqual(lines[1], "second line")
        XCTAssertEqual(gutterLine(rendered, line: 1)?.number, 2)
    }
}
