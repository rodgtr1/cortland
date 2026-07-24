import XCTest
@testable import Cortland

final class MergeConflictParserTests: XCTestCase {
    private let sample = """
    one
    <<<<<<< HEAD
    current-a
    current-b
    =======
    incoming-a
    >>>>>>> 703c621 (main)
    last

    """

    func testParsesSingleConflictRangesAndLabels() {
        let conflicts = MergeConflictParser.conflicts(in: sample)

        XCTAssertEqual(conflicts.count, 1)
        let conflict = conflicts[0]
        XCTAssertEqual(conflict.currentLabel, "HEAD")
        XCTAssertEqual(conflict.incomingLabel, "703c621 (main)")

        let ns = sample as NSString
        XCTAssertEqual(ns.substring(with: conflict.currentRange), "current-a\ncurrent-b\n")
        XCTAssertEqual(ns.substring(with: conflict.incomingRange), "incoming-a\n")
        XCTAssertEqual(ns.substring(with: conflict.openingMarkerLineRange), "<<<<<<< HEAD")
        XCTAssertEqual(ns.substring(with: conflict.separatorMarkerLineRange), "=======")
        XCTAssertEqual(ns.substring(with: conflict.closingMarkerLineRange), ">>>>>>> 703c621 (main)")
    }

    func testResolvedTextForEachChoice() {
        let conflict = MergeConflictParser.conflicts(in: sample)[0]

        XCTAssertEqual(MergeConflictParser.resolvedText(for: conflict, in: sample, choice: .current), "current-a\ncurrent-b\n")
        XCTAssertEqual(MergeConflictParser.resolvedText(for: conflict, in: sample, choice: .incoming), "incoming-a\n")
        XCTAssertEqual(MergeConflictParser.resolvedText(for: conflict, in: sample, choice: .both), "current-a\ncurrent-b\nincoming-a\n")
    }

    func testApplyingResolutionRemovesMarkers() {
        let conflict = MergeConflictParser.conflicts(in: sample)[0]
        let replacement = MergeConflictParser.resolvedText(for: conflict, in: sample, choice: .both)
        let resolved = (sample as NSString).replacingCharacters(in: conflict.fullRange, with: replacement)

        XCTAssertFalse(resolved.contains("<<<<<<<"))
        XCTAssertFalse(resolved.contains("======="))
        XCTAssertFalse(resolved.contains(">>>>>>>"))
        XCTAssertEqual(resolved, "one\ncurrent-a\ncurrent-b\nincoming-a\nlast\n")
    }

    func testIgnoresBaseSectionInThreeWayConflict() {
        let threeWay = """
        <<<<<<< HEAD
        ours
        ||||||| base
        original
        =======
        theirs
        >>>>>>> branch

        """
        let conflict = MergeConflictParser.conflicts(in: threeWay)[0]

        XCTAssertEqual((threeWay as NSString).substring(with: conflict.currentRange), "ours\n")
        XCTAssertEqual((threeWay as NSString).substring(with: conflict.incomingRange), "theirs\n")
    }

    func testParsesMultipleConflicts() {
        let text = """
        <<<<<<< HEAD
        a
        =======
        b
        >>>>>>> x
        middle
        <<<<<<< HEAD
        c
        =======
        d
        >>>>>>> y

        """
        XCTAssertEqual(MergeConflictParser.conflicts(in: text).count, 2)
    }

    func testIgnoresUnterminatedConflict() {
        let text = "<<<<<<< HEAD\nstuff\nno closing markers\n"
        XCTAssertTrue(MergeConflictParser.conflicts(in: text).isEmpty)
    }
}
