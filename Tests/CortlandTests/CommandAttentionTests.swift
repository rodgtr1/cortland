import XCTest
@testable import Cortland

/// Feature C2: a command that exits non-zero in a pane the user isn't looking
/// at joins the same passive attention surfaces (agents-panel row highlight,
/// ⇧⌘J cycle) the agent `ready` state uses. These pin the pure decision, the
/// tab-level aggregation, and the ⇧⌘J bucket ordering.
@MainActor
final class CommandAttentionTests: XCTestCase {

    /// Builds a tab with a chosen agent state and, optionally, one pane already
    /// carrying a failed-command mark.
    private func tab(state: AgentState, attention: Bool = false) -> TabModel {
        let t = TabModel()
        t.agentState = state
        t.panes[0].failedCommandAttention = attention
        return t
    }

    // MARK: - The mark/clear decision

    func testFailureOutOfViewMarksAttention() {
        XCTAssertTrue(PaneModel.shouldMarkAttention(commandSucceeded: false, paneIsBeingViewed: false))
    }

    func testFailureInViewDoesNotMark() {
        // The user is looking at the pane, so they already see the failure.
        XCTAssertFalse(PaneModel.shouldMarkAttention(commandSucceeded: false, paneIsBeingViewed: true))
    }

    func testCleanExitNeverMarks() {
        XCTAssertFalse(PaneModel.shouldMarkAttention(commandSucceeded: true, paneIsBeingViewed: false))
        XCTAssertFalse(PaneModel.shouldMarkAttention(commandSucceeded: true, paneIsBeingViewed: true))
    }

    /// A later clean exit clears an earlier failure's mark (the "next command
    /// exits zero" clause).
    func testCleanExitClearsAnEarlierFailure() {
        let pane = PaneModel()
        pane.setFailedCommandAttention(PaneModel.shouldMarkAttention(commandSucceeded: false, paneIsBeingViewed: false))
        XCTAssertTrue(pane.failedCommandAttention)
        pane.setFailedCommandAttention(PaneModel.shouldMarkAttention(commandSucceeded: true, paneIsBeingViewed: false))
        XCTAssertFalse(pane.failedCommandAttention)
    }

    // MARK: - setFailedCommandAttention change signalling

    func testSetReportsChangeAndPosts() {
        let pane = PaneModel()
        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: .paneCommandAttentionChanged, object: pane, queue: nil
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        XCTAssertTrue(pane.setFailedCommandAttention(true))   // idle -> marked
        XCTAssertFalse(pane.setFailedCommandAttention(true))  // no change
        XCTAssertTrue(pane.setFailedCommandAttention(false))  // cleared
        XCTAssertEqual(posts, 2)                              // only real changes post
    }

    // MARK: - Tab aggregation

    func testHasCommandAttentionAggregatesAnyPane() {
        let t = TabModel()
        t.addPane(PaneModel())
        XCTAssertFalse(t.hasCommandAttention)
        t.panes[1].failedCommandAttention = true
        XCTAssertTrue(t.hasCommandAttention)  // a hidden split pane still lights the tab
    }

    func testCommandAttentionSinceIsEarliestMark() {
        let t = TabModel()
        t.addPane(PaneModel())
        XCTAssertNil(t.commandAttentionSince)

        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        t.panes[0].failedCommandAttention = true
        t.panes[0].failedCommandAttentionChangedAt = newer
        t.panes[1].failedCommandAttention = true
        t.panes[1].failedCommandAttentionChangedAt = older
        XCTAssertEqual(t.commandAttentionSince, older)
    }

    // MARK: - ⇧⌘J cycle ordering

    func testNilWhenNothingWantsAttention() {
        let tabs = [tab(state: .idle), tab(state: .idle)]
        XCTAssertNil(TabModel.nextAttentionIndex(in: tabs, activeIndex: 0))
    }

    /// A failed command in an otherwise-idle tab is a valid cycle target.
    func testFailedCommandJoinsTheCycle() {
        let tabs = [tab(state: .idle), tab(state: .idle, attention: true)]
        XCTAssertEqual(TabModel.nextAttentionIndex(in: tabs, activeIndex: 0), 1)
    }

    /// Needs-input outranks a failed command, which outranks working.
    func testUrgencyOrdering() {
        let tabs = [
            tab(state: .working),
            tab(state: .idle, attention: true),
            tab(state: .ready)
        ]
        // From tab 0, the most-urgent non-empty bucket is needs-input (tab 2).
        XCTAssertEqual(TabModel.nextAttentionIndex(in: tabs, activeIndex: 0), 2)
        // With no needs-input tab, the failed command wins over working.
        let tabs2 = [tab(state: .working), tab(state: .idle, attention: true)]
        XCTAssertEqual(TabModel.nextAttentionIndex(in: tabs2, activeIndex: 0), 1)
    }

    /// Within a bucket the search wraps around past the active tab.
    func testWrapAroundWithinBucket() {
        let tabs = [
            tab(state: .idle, attention: true),
            tab(state: .idle),                // active, nothing pending
            tab(state: .idle, attention: true)
        ]
        // Command-attention bucket: candidates {0, 2}; from active 1 the next
        // above is 2.
        XCTAssertEqual(TabModel.nextAttentionIndex(in: tabs, activeIndex: 1), 2)
        // From active 2 (last candidate) it wraps back to 0.
        XCTAssertEqual(TabModel.nextAttentionIndex(in: tabs, activeIndex: 2), 0)
    }

    /// The sole candidate being the active tab yields the active index, which
    /// the caller treats as a no-op.
    func testSoleCandidateIsActiveTab() {
        let tabs = [tab(state: .idle), tab(state: .ready), tab(state: .idle)]
        XCTAssertEqual(TabModel.nextAttentionIndex(in: tabs, activeIndex: 1), 1)
    }
}
