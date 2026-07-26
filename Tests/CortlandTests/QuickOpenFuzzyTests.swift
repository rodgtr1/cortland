import XCTest
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

    // MARK: - `find` fallback argv

    /// The stock-macOS fallback has to *prune* the heavy directories, not walk
    /// them and filter afterwards: `-not -path "*/node_modules/*"` still visits
    /// every file in there. The prune clause comes before `-type f -print`, so
    /// find never descends.
    func testFindArgumentsPruneHeavyDirectoriesBeforePrinting() {
        let arguments = QuickOpenPanel.findArguments(root: "/repo")

        XCTAssertEqual(arguments.first, "/repo")
        XCTAssertEqual(Array(arguments.suffix(6)), [")", "-prune", "-o", "-type", "f", "-print"])
        for name in [".git", "node_modules", ".build", "target"] {
            XCTAssertTrue(arguments.contains(name), "\(name) is not pruned")
        }
        // Dot-names too, which is what the old "-not -path */.*" filter hid.
        XCTAssertTrue(arguments.contains(".*"))
        XCTAssertFalse(arguments.contains("-not"), "the old walk-then-filter form is gone")
    }

    // MARK: - Stale-result gate

    /// Clearing the search field returns immediately, but the search it
    /// abandoned keeps draining `find`'s output in the background. Terminating
    /// the child doesn't stop that — it has already printed most of a large
    /// tree — so without retiring the ticket, those rows land back in an empty
    /// panel.
    func testGateRefusesResultsAfterTheSearchIsAbandoned() {
        var gate = QuickOpenPanel.SearchGate()
        let ticket = gate.start()
        XCTAssertTrue(gate.accepts(ticket))

        gate.invalidate()
        XCTAssertFalse(gate.accepts(ticket), "an abandoned search must not write rows")
    }

    /// The ordinary case: a newer query supersedes the one still running, and
    /// only the newer one may install its rows — whichever finishes first.
    func testGateAcceptsOnlyTheNewestSearch() {
        var gate = QuickOpenPanel.SearchGate()
        let first = gate.start()
        let second = gate.start()

        XCTAssertNotEqual(first, second, "each search gets its own ticket")
        XCTAssertFalse(gate.accepts(first), "the superseded search is stale")
        XCTAssertTrue(gate.accepts(second))
    }

    /// Retiring twice (a cleared field, then a close) is not a way back in, and
    /// a ticket from before an invalidation stays refused once searching
    /// resumes.
    func testGateStaysClosedForOldTicketsAcrossRestarts() {
        var gate = QuickOpenPanel.SearchGate()
        let abandoned = gate.start()
        gate.invalidate()
        gate.invalidate()
        XCTAssertFalse(gate.accepts(abandoned))

        let resumed = gate.start()
        XCTAssertTrue(gate.accepts(resumed))
        XCTAssertFalse(gate.accepts(abandoned), "the old search never becomes current again")
    }

    /// A fresh gate accepts nothing: no search has been started, so any result
    /// arriving is by definition from one that was abandoned.
    func testGateAcceptsNothingBeforeAnySearch() {
        let gate = QuickOpenPanel.SearchGate()
        XCTAssertFalse(gate.accepts(0))
        XCTAssertFalse(gate.accepts(1))
    }

    // MARK: - Bounded reader

    private func chunks(_ strings: [String]) -> [Data] {
        strings.map { Data($0.utf8) }
    }

    /// A path can land across two reads; the reader must not lose it or split
    /// it into two bogus paths.
    func testBoundedReaderJoinsLinesSplitAcrossChunks() {
        var reader = QuickOpenPanel.BoundedLineReader(cap: 100)
        for chunk in chunks(["/a/one.swift\n/a/tw", "o.swift\n/a/three.swift\n"]) {
            reader.consume(chunk)
        }
        reader.finish()
        XCTAssertEqual(reader.lines, ["/a/one.swift", "/a/two.swift", "/a/three.swift"])
    }

    /// Output that stops mid-line (a child killed at the cap or the timeout)
    /// still yields the partial path rather than dropping it silently.
    func testBoundedReaderFlushesUnterminatedTail() {
        var reader = QuickOpenPanel.BoundedLineReader(cap: 100)
        reader.consume(Data("/a/one.swift\n/a/partial".utf8))
        XCTAssertEqual(reader.lines, ["/a/one.swift"])
        reader.finish()
        XCTAssertEqual(reader.lines, ["/a/one.swift", "/a/partial"])
    }

    /// The cap is what makes the walk bounded: once it's reached the reader
    /// reports full (the caller kills `find`) and takes nothing more, however
    /// much the child already wrote.
    func testBoundedReaderStopsAtCap() {
        var reader = QuickOpenPanel.BoundedLineReader(cap: 3)
        reader.consume(Data((1...10).map { "/a/\($0).swift\n" }.joined().utf8))
        XCTAssertTrue(reader.isFull)
        XCTAssertEqual(reader.lines, ["/a/1.swift", "/a/2.swift", "/a/3.swift"])

        reader.consume(Data("/a/11.swift\n".utf8))
        reader.finish()
        XCTAssertEqual(reader.lines.count, 3, "nothing is appended past the cap")
    }

    /// A read boundary can land inside a multi-byte character. Decoding each
    /// chunk as it arrives turns the two halves into U+FFFD and yields a path
    /// that doesn't exist on disk; only whole lines may be decoded.
    func testBoundedReaderJoinsMultiByteCharactersSplitAcrossChunks() {
        let path = "/repo/Sources/Café/Résumé—notes.swift"
        var bytes = Array(Data(path.utf8))
        bytes.append(0x0A)

        // Split inside the first "é" (its two bytes straddle the boundary).
        let eAcute = Array("é".utf8)
        let cut = Array(Data("/repo/Sources/Caf".utf8)).count + 1
        XCTAssertEqual(bytes[cut - 1], eAcute[0], "the split must land mid-scalar for this test to mean anything")

        var reader = QuickOpenPanel.BoundedLineReader(cap: 10)
        reader.consume(Data(bytes[..<cut]))
        reader.consume(Data(bytes[cut...]))
        reader.finish()

        XCTAssertEqual(reader.lines, [path])
        XCTAssertFalse(reader.lines[0].contains("\u{FFFD}"), "no replacement characters")
    }

    /// The same hazard on the unterminated tail: a path with no trailing
    /// newline, split mid-character, still has to come back intact.
    func testBoundedReaderFlushesMultiByteTailIntact() {
        let path = "/repo/日本語/ファイル.swift"
        let bytes = Array(Data(path.utf8))
        var reader = QuickOpenPanel.BoundedLineReader(cap: 10)
        for byte in bytes {
            reader.consume(Data([byte]))   // one byte at a time: every split is mid-scalar
        }
        reader.finish()

        XCTAssertEqual(reader.lines, [path])
    }

    func testBoundedReaderIgnoresEmptyChunks() {
        var reader = QuickOpenPanel.BoundedLineReader(cap: 10)
        reader.consume(Data())
        reader.consume(Data("/a/one.swift\n".utf8))
        reader.consume(Data())
        reader.finish()
        XCTAssertEqual(reader.lines, ["/a/one.swift"])
    }

    /// Scoring runs on the paths the reader kept, ranks filename hits above
    /// directory-only hits, and drops non-matches.
    func testScoredResultsRankFilenameHitsAndDropNonMatches() {
        let results = QuickOpenPanel.scoredResults(
            from: [
                "/repo/Sources/Editor/Theme.swift",
                "/repo/theme/notes.md",
                "/repo/Sources/Unrelated.swift",
                "   "
            ],
            searchText: "theme",
            root: "/repo"
        )
        XCTAssertEqual(results.map(\.relativePath), ["Sources/Editor/Theme.swift", "theme/notes.md"])
        XCTAssertEqual(results.first?.fileName, "Theme.swift")
    }
}
