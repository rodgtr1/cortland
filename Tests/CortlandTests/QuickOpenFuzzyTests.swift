import XCTest
import CortlandProInterface
@testable import Cortland

final class QuickOpenFuzzyTests: XCTestCase {
    func testFuzzyRegexBuildsSubsequencePattern() {
        XCTAssertEqual(QuickOpenPanel.fuzzyRegex(for: "abc"), "a.*b.*c")
    }

    func testFuzzyRegexEscapesMetacharacters() {
        // A "." in the query must be a literal, not "any character".
        XCTAssertEqual(QuickOpenPanel.fuzzyRegex(for: "a.b"), "a.*\\..*b")
    }

    func testRelativePathStripsRootAndLeadingSlash() {
        XCTAssertEqual(
            QuickOpenPanel.relativePath(of: "/repo/Sources/App.swift", under: "/repo"),
            "Sources/App.swift"
        )
        // Tolerates a trailing slash on the root.
        XCTAssertEqual(
            QuickOpenPanel.relativePath(of: "/repo/Sources/App.swift", under: "/repo/"),
            "Sources/App.swift"
        )
    }

    func testRelativePathReturnsOriginalWhenNotUnderRoot() {
        XCTAssertEqual(
            QuickOpenPanel.relativePath(of: "/other/file.swift", under: "/repo"),
            "/other/file.swift"
        )
    }

    // MARK: - Shared fuzzy scorer

    func testFuzzyScorerTiersRankExactAbovePrefixAboveSubstring() {
        XCTAssertEqual(FuzzyScorer.score(candidate: "main.swift", query: "main.swift"), 1000)
        XCTAssertEqual(FuzzyScorer.score(candidate: "main.swift", query: "main"), 800)
        XCTAssertEqual(FuzzyScorer.score(candidate: "main.swift", query: "n.sw"), 600)
    }

    func testFuzzyScorerSubsequenceScoresTenPerCharacter() {
        // "msw" isn't a prefix or substring of "main.swift" but its characters
        // appear in order: 3 matches × 10.
        XCTAssertEqual(FuzzyScorer.score(candidate: "main.swift", query: "msw"), 30)
    }

    func testFuzzyScorerReturnsNilWhenNotASubsequence() {
        XCTAssertNil(FuzzyScorer.score(candidate: "main.swift", query: "xyz"))
    }

    func testFuzzyScorerIsCaseInsensitive() {
        XCTAssertEqual(FuzzyScorer.score(candidate: "Main.Swift", query: "main.swift"), 1000)
    }
}
