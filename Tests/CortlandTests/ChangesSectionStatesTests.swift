import XCTest
@testable import Cortland

/// Covers the changes pane's per-file collapse and Viewed state: which
/// sections start collapsed, and how clicks and refreshes change the state.
final class ChangesSectionStatesTests: XCTestCase {
    private func section(
        _ path: String,
        diff: String = "@@ -1 +1 @@\n-a\n+b",
        status: GitFileStatus = .modified,
        stamp: ChangeSection.FileStamp? = nil
    ) -> ChangeSection {
        ChangeSection(relativePath: path, diff: diff, isConflicted: false, status: status, fileStamp: stamp)
    }

    /// Runs one refresh from `displayed` to `incoming` the way the pane does.
    private func refresh(_ states: inout ChangesSectionStates, from displayed: [ChangeSection], to incoming: [ChangeSection]) {
        let changed = ChangesSectionStates.contentChangedPaths(displayed: displayed, incoming: incoming)
        states.update(sections: incoming, contentChanged: changed) { _ in 2 }
    }

    /// Builds states for `paths` with a fixed changed-line count per path.
    private func states(
        _ paths: [String],
        changedLines: [String: Int] = [:]
    ) -> ChangesSectionStates {
        var states = ChangesSectionStates()
        states.update(sections: paths.map { section($0) }, contentChanged: []) { changedLines[$0.relativePath] ?? 2 }
        return states
    }

    private let expanded = ChangesSectionStates.State(isCollapsed: false, isViewed: false)
    private let collapsed = ChangesSectionStates.State(isCollapsed: true, isViewed: false)
    private let viewed = ChangesSectionStates.State(isCollapsed: true, isViewed: true)

    // MARK: - Start collapsed

    func testEveryLockfileStartsCollapsed() {
        let names = [
            "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lock", "bun.lockb",
            "Package.resolved", "Cargo.lock", "Gemfile.lock", "Podfile.lock", "poetry.lock",
            "uv.lock", "composer.lock", "go.sum",
        ]
        for name in names {
            XCTAssertTrue(ChangesSectionStates.startsCollapsed(relativePath: name, changedLines: 1), name)
        }
    }

    func testNestedLockfileStartsCollapsed() {
        XCTAssertTrue(ChangesSectionStates.startsCollapsed(relativePath: "web/app/package-lock.json", changedLines: 3))
        XCTAssertTrue(ChangesSectionStates.startsCollapsed(
            relativePath: "Project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
            changedLines: 3
        ))
    }

    func testFiveHundredChangedLinesStaysExpandedAndFiveHundredOneCollapses() {
        XCTAssertFalse(ChangesSectionStates.startsCollapsed(relativePath: "big.swift", changedLines: 500))
        XCTAssertTrue(ChangesSectionStates.startsCollapsed(relativePath: "big.swift", changedLines: 501))
    }

    func testOrdinaryFileStartsExpanded() {
        XCTAssertFalse(ChangesSectionStates.startsCollapsed(relativePath: "Sources/main.swift", changedLines: 12))
        XCTAssertFalse(ChangesSectionStates.startsCollapsed(relativePath: "lock.json", changedLines: 12))
    }

    func testFirstUpdateAppliesTheDefaultAndNeverMarksViewed() {
        let states = states(["a.swift", "yarn.lock", "huge.swift"], changedLines: ["huge.swift": 900])
        XCTAssertEqual(states.state(for: "a.swift"), expanded)
        XCTAssertEqual(states.state(for: "yarn.lock"), collapsed)
        XCTAssertEqual(states.state(for: "huge.swift"), collapsed)
    }

    func testFileGrowingPastTheThresholdWhileExpandedStaysExpanded() {
        var states = states(["a.swift"])
        states.update(sections: [section("a.swift")], contentChanged: ["a.swift"]) { _ in 2000 }
        XCTAssertEqual(states.state(for: "a.swift"), expanded)
    }

    // MARK: - Transitions

    func testMarkingViewedCollapses() {
        var states = states(["a.swift"])
        states.setViewed(true, for: "a.swift")
        XCTAssertEqual(states.state(for: "a.swift"), viewed)
    }

    func testUnmarkingViewedExpands() {
        var states = states(["a.swift"])
        states.setViewed(true, for: "a.swift")
        states.setViewed(false, for: "a.swift")
        XCTAssertEqual(states.state(for: "a.swift"), expanded)
    }

    func testContentChangeClearsViewedAndExpands() {
        var states = states(["a.swift", "b.swift"])
        states.setViewed(true, for: "a.swift")
        states.update(sections: [section("a.swift"), section("b.swift")], contentChanged: ["a.swift"]) { _ in 2 }
        XCTAssertEqual(states.state(for: "a.swift"), expanded)
    }

    func testKeepLeavesViewedAndCollapseAlone() {
        var states = states(["a.swift", "b.swift"])
        states.setViewed(true, for: "a.swift")
        states.toggleCollapsed("b.swift")
        states.update(sections: [section("a.swift"), section("b.swift")], contentChanged: []) { _ in 2 }
        XCTAssertEqual(states.state(for: "a.swift"), viewed)
        XCTAssertEqual(states.state(for: "b.swift"), collapsed)
    }

    func testExplicitCollapseSurvivesAContentChange() {
        var states = states(["a.swift"])
        states.toggleCollapsed("a.swift")
        states.update(sections: [section("a.swift")], contentChanged: ["a.swift"]) { _ in 2 }
        XCTAssertEqual(states.state(for: "a.swift"), collapsed)
    }

    func testExplicitExpandOfALockfileSurvivesAContentChange() {
        var states = states(["yarn.lock"])
        states.toggleCollapsed("yarn.lock")
        states.update(sections: [section("yarn.lock")], contentChanged: ["yarn.lock"]) { _ in 2 }
        XCTAssertEqual(states.state(for: "yarn.lock"), expanded)
    }

    func testRemovedThenReaddedPathStartsFresh() {
        var states = states(["a.swift", "b.swift"])
        states.setViewed(true, for: "a.swift")
        states.update(sections: [section("b.swift")], contentChanged: []) { _ in 2 }
        states.update(sections: [section("a.swift"), section("b.swift")], contentChanged: []) { _ in 2 }
        XCTAssertEqual(states.state(for: "a.swift"), expanded)
    }

    func testSidebarFocusExpandsWithoutClearingViewed() {
        var states = states(["a.swift"])
        states.setViewed(true, for: "a.swift")
        states.expand("a.swift")
        XCTAssertEqual(states.state(for: "a.swift"), ChangesSectionStates.State(isCollapsed: false, isViewed: true))
    }

    func testToggleFlipsCollapse() {
        var states = states(["a.swift"])
        states.toggleCollapsed("a.swift")
        XCTAssertEqual(states.state(for: "a.swift"), collapsed)
        states.toggleCollapsed("a.swift")
        XCTAssertEqual(states.state(for: "a.swift"), expanded)
    }

    // MARK: - What counts as a content change

    func testStatusOnlyChangeKeepsViewedAndCollapsed() {
        var states = states(["a.swift"])
        states.setViewed(true, for: "a.swift")
        let displayed = [section("a.swift", status: .modified)]
        let incoming = [section("a.swift", status: .added)]
        XCTAssertEqual(ChangesReconcilePlan(displayed: displayed, incoming: incoming).steps, [.rebuild("a.swift")])
        refresh(&states, from: displayed, to: incoming)
        XCTAssertEqual(states.state(for: "a.swift"), viewed)
    }

    func testDiffChangeClearsViewedAndExpands() {
        var states = states(["a.swift"])
        states.setViewed(true, for: "a.swift")
        refresh(&states, from: [section("a.swift")], to: [section("a.swift", diff: "@@ -1 +1 @@\n-a\n+c")])
        XCTAssertEqual(states.state(for: "a.swift"), expanded)
    }

    func testFileStampChangeClearsViewedAndExpands() {
        let old = ChangeSection.FileStamp(modificationDate: Date(timeIntervalSince1970: 1), size: 10)
        let new = ChangeSection.FileStamp(modificationDate: Date(timeIntervalSince1970: 2), size: 10)
        var states = states(["logo.png"])
        states.setViewed(true, for: "logo.png")
        refresh(
            &states,
            from: [section("logo.png", diff: "Binary files differ", stamp: old)],
            to: [section("logo.png", diff: "Binary files differ", stamp: new)]
        )
        XCTAssertEqual(states.state(for: "logo.png"), expanded)
    }

    func testUnchangedAndNewPathsAreNotContentChanges() {
        let changed = ChangesSectionStates.contentChangedPaths(
            displayed: [section("a.swift")],
            incoming: [section("a.swift"), section("b.swift")]
        )
        XCTAssertEqual(changed, [])
    }
}
