import XCTest
@testable import Cortland

/// The status label is the only thing that tells the user whether they are
/// looking at every match or a slice of one. It used to report a precise count
/// for runs the 1000-result cap or the 8s timeout had cut short, so a truncated
/// search read exactly like a complete one.
final class SearchSummaryTests: XCTestCase {
    private func summary(_ files: Int, _ matches: Int, _ outcome: SearchOutcome) -> String {
        SearchPanelViewController.resultSummary(fileCount: files, matchCount: matches, outcome: outcome)
    }

    func testCompleteSearchReportsItsCounts() {
        XCTAssertEqual(summary(3, 12, .complete), "3 files, 12 matches")
        XCTAssertEqual(summary(1, 1, .complete), "1 file, 1 match")
        XCTAssertEqual(summary(0, 0, .complete), "No results")
    }

    func testCappedSearchSaysTheLimitWasHit() {
        let capped = summary(40, SearchPanelViewController.maxResults, .cappedAtLimit)
        XCTAssertEqual(capped, "40 files, first 1000 matches (limit reached)")
        // The whole point: it cannot read like a complete run with the same counts.
        XCTAssertNotEqual(capped, summary(40, SearchPanelViewController.maxResults, .complete))
    }

    func testTimedOutSearchIsLabelledPartial() {
        XCTAssertEqual(summary(5, 20, .stoppedByTimeout), "Stopped after 8s: 5 files, 20 matches so far")
        // A timeout before the backend wrote anything is not "No results".
        XCTAssertEqual(summary(0, 0, .stoppedByTimeout), "Stopped after 8s: no matches yet")
        XCTAssertNotEqual(summary(0, 0, .stoppedByTimeout), summary(0, 0, .complete))
    }

    func testFailedSearchReportsFailure() {
        XCTAssertEqual(summary(0, 0, .failed), "Search failed")
    }
}
