import XCTest
@testable import Cortland

@MainActor
final class WorktreeRemoveDecisionTests: XCTestCase {
    func testCleanWorktreeSaysCleanAndDoesNotForce() {
        let decision = WorktreesPanelViewController.removeDecision(
            name: "feat", summary: WorktreeStatusSummary(changed: 0, conflicted: 0), hasPane: false
        )
        XCTAssertEqual(decision.message, "feat is clean. Remove its worktree?")
        XCTAssertFalse(decision.force)
    }

    func testDirtyWorktreeWarnsAndForces() {
        let decision = WorktreesPanelViewController.removeDecision(
            name: "feat", summary: WorktreeStatusSummary(changed: 2, conflicted: 1), hasPane: false
        )
        XCTAssertEqual(decision.message, "feat has 2 changed files and 1 conflicted. Removing it may delete local work.")
        XCTAssertTrue(decision.force)
    }

    func testUnreadableStatusWarnsAndForces() {
        let decision = WorktreesPanelViewController.removeDecision(name: "feat", summary: nil, hasPane: false)
        XCTAssertEqual(decision.message, "feat's status could not be read. Removing it may delete local work.")
        XCTAssertTrue(decision.force)
    }
}
