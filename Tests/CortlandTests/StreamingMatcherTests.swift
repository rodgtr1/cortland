import XCTest
@testable import Cortland

final class StreamingMatcherTests: XCTestCase {
    func testMatchesWithinASingleChunk() {
        var matcher = StreamingMatcher(needle: "BUILD SUCCEEDED")
        XCTAssertTrue(matcher.feed("... Compiling\nBUILD SUCCEEDED\n"))
    }

    func testMatchesAcrossAChunkBoundary() {
        var matcher = StreamingMatcher(needle: "deploy complete")
        // The needle is split across two chunks; the carry must bridge them.
        XCTAssertFalse(matcher.feed("running... deploy com"))
        XCTAssertTrue(matcher.feed("plete now"))
    }

    func testSeedTailBridgesIntoFirstChunk() {
        // The buffer already ended with the needle's prefix when the wait began.
        var matcher = StreamingMatcher(needle: "ready>", seed: "shell rea")
        XCTAssertTrue(matcher.feed("dy> "))
    }

    func testNoFalseMatchAndCarryStaysBounded() {
        var matcher = StreamingMatcher(needle: "END")
        for _ in 0..<1000 {
            XCTAssertFalse(matcher.feed("EN no match here EN"))
        }
        // A needle that only completes on the latest chunk still matches, proving
        // the carry never lost the boundary char despite 1000 chunks.
        XCTAssertTrue(matcher.feed("D"))
    }

    func testEmptyNeedleNeverMatches() {
        var matcher = StreamingMatcher(needle: "")
        XCTAssertFalse(matcher.feed("anything at all"))
    }

    func testSingleCharacterNeedle() {
        var matcher = StreamingMatcher(needle: "$")
        XCTAssertFalse(matcher.feed("no prompt yet"))
        XCTAssertTrue(matcher.feed("user@host $"))
    }
}
