import XCTest
@testable import Cortland

/// Covers the window-free decisions behind the changes pane's live refresh:
/// the reconcile plan, the scroll anchor, and the newest-request guard.
final class UncommittedChangesRefreshTests: XCTestCase {
    private func section(
        _ path: String,
        diff: String = "@@ -1 +1 @@\n-a\n+b",
        status: GitFileStatus = .modified,
        conflicted: Bool = false,
        stamp: ChangeSection.FileStamp? = nil
    ) -> ChangeSection {
        ChangeSection(relativePath: path, diff: diff, isConflicted: conflicted, status: status, fileStamp: stamp)
    }

    // MARK: - Reconcile plan

    func testIdenticalResultIsANoOp() {
        let sections = [section("a.swift"), section("b.swift")]
        let plan = ChangesReconcilePlan(displayed: sections, incoming: sections)
        XCTAssertTrue(plan.isNoOp)
        XCTAssertEqual(plan.steps, [.keep("a.swift"), .keep("b.swift")])
        XCTAssertEqual(plan.removed, [])
    }

    func testEmptyToEmptyIsANoOp() {
        XCTAssertTrue(ChangesReconcilePlan(displayed: [], incoming: []).isNoOp)
    }

    func testKeepsRebuildsInsertsAndRemoves() {
        let displayed = [section("a.swift"), section("b.swift"), section("c.swift")]
        let incoming = [
            section("a.swift"),
            section("b.swift", diff: "@@ -1 +1 @@\n-a\n+changed"),
            section("bb.swift"),
        ]
        let plan = ChangesReconcilePlan(displayed: displayed, incoming: incoming)
        XCTAssertFalse(plan.isNoOp)
        XCTAssertEqual(plan.steps, [.keep("a.swift"), .rebuild("b.swift"), .insert("bb.swift")])
        XCTAssertEqual(plan.removed, ["c.swift"])
    }

    func testStatusOrConflictChangeRebuilds() {
        let displayed = [section("a.swift", status: .modified), section("b.swift")]
        let incoming = [section("a.swift", status: .added), section("b.swift", conflicted: true)]
        let plan = ChangesReconcilePlan(displayed: displayed, incoming: incoming)
        XCTAssertEqual(plan.steps, [.rebuild("a.swift"), .rebuild("b.swift")])
    }

    func testImageWithSameDiffButNewStampRebuilds() {
        let old = ChangeSection.FileStamp(modificationDate: Date(timeIntervalSince1970: 1), size: 10)
        let new = ChangeSection.FileStamp(modificationDate: Date(timeIntervalSince1970: 2), size: 10)
        let plan = ChangesReconcilePlan(
            displayed: [section("logo.png", diff: "Binary files differ", stamp: old)],
            incoming: [section("logo.png", diff: "Binary files differ", stamp: new)]
        )
        XCTAssertEqual(plan.steps, [.rebuild("logo.png")])
    }

    func testAllRemovedIsNotANoOp() {
        let plan = ChangesReconcilePlan(displayed: [section("a.swift")], incoming: [])
        XCTAssertFalse(plan.isNoOp)
        XCTAssertEqual(plan.steps, [])
        XCTAssertEqual(plan.removed, ["a.swift"])
    }

    // MARK: - Scroll anchor

    private let geometry: [ChangesScrollAnchor.Section] = [
        .init(path: "a.swift", top: 12),
        .init(path: "c.swift", top: 300),
        .init(path: "e.swift", top: 900),
    ]

    func testAnchorIsTheSectionAtTheTopOfTheViewport() {
        let anchor = ChangesScrollAnchor.capture(visibleTop: 450, sections: geometry)
        XCTAssertEqual(anchor, ChangesScrollAnchor(path: "c.swift", offset: 150))
    }

    func testAnchorAboveEverySectionUsesTheFirst() {
        let anchor = ChangesScrollAnchor.capture(visibleTop: 0, sections: geometry)
        XCTAssertEqual(anchor, ChangesScrollAnchor(path: "a.swift", offset: -12))
    }

    func testNoSectionsMeansNoAnchor() {
        XCTAssertNil(ChangesScrollAnchor.capture(visibleTop: 0, sections: []))
    }

    func testRestoreFollowsTheAnchorWhenSectionsAboveItGrow() {
        let anchor = ChangesScrollAnchor(path: "c.swift", offset: 150)
        let grown: [ChangesScrollAnchor.Section] = [
            .init(path: "a.swift", top: 12),
            .init(path: "b.swift", top: 200),
            .init(path: "c.swift", top: 700),
        ]
        XCTAssertEqual(anchor.restoredTop(in: grown, fallback: 450), 850)
    }

    func testRestoreFallsBackToTheNextSectionWhenTheAnchorFileIsGone() {
        let anchor = ChangesScrollAnchor(path: "c.swift", offset: 150)
        let without: [ChangesScrollAnchor.Section] = [
            .init(path: "a.swift", top: 12),
            .init(path: "e.swift", top: 300),
        ]
        XCTAssertEqual(anchor.restoredTop(in: without, fallback: 450), 300)
    }

    func testRestoreUsesTheFallbackWhenNothingFollowsTheAnchor() {
        let anchor = ChangesScrollAnchor(path: "e.swift", offset: 40)
        let without: [ChangesScrollAnchor.Section] = [.init(path: "a.swift", top: 12)]
        XCTAssertEqual(anchor.restoredTop(in: without, fallback: 940), 940)
    }

    // MARK: - Newest request wins

    func testOlderRequestFinishingLateDoesNotWin() {
        var gate = LatestRequestGate()
        let older = gate.begin()
        let newer = gate.begin()
        XCTAssertTrue(gate.isCurrent(newer))
        XCTAssertFalse(gate.isCurrent(older))
    }

    func testSingleRequestIsCurrent() {
        var gate = LatestRequestGate()
        let only = gate.begin()
        XCTAssertTrue(gate.isCurrent(only))
    }
}
