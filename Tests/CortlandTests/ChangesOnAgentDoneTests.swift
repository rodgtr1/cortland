import XCTest
import TOMLKit
@testable import Cortland

/// Showing the changes pane when an agent finishes a turn: the trigger, the
/// placement, the config key, following a pane's snapshots, the reuse lookup,
/// and what a saved session keeps of a split holding a changes pane.
@MainActor
final class ChangesOnAgentDoneTests: XCTestCase {
    private let agent = UUID()
    private let other = UUID()

    private func snapshot(_ pane: UUID, _ sequence: Int, at seconds: TimeInterval, sessionStart: Bool = false) -> TurnSnapshot {
        TurnSnapshot(
            paneID: pane,
            sequence: sequence,
            refName: TurnSnapshotService.refName(paneID: pane, sequence: sequence),
            commit: "c\(sequence)-\(pane.uuidString.prefix(4))",
            head: nil,
            createdAt: Date(timeIntervalSince1970: seconds),
            isSessionStart: sessionStart
        )
    }

    private func finished(
        from previous: AgentState = .working,
        to next: AgentState = .done,
        startedAt: TimeInterval? = 100,
        snapshots: [TurnSnapshot]? = nil,
        changes: Int = 2
    ) -> TurnSnapshot? {
        TurnSnapshotService.finishedTurnToShow(
            from: previous,
            to: next,
            turnStartedAt: startedAt.map { Date(timeIntervalSince1970: $0) },
            paneSnapshots: snapshots ?? [snapshot(agent, 1, at: 50), snapshot(agent, 2, at: 100.2)],
            changeCount: { _ in changes }
        )
    }

    // MARK: - 1. The trigger

    func testWorkingToDoneWithThisTurnsSnapshotAndChangesTriggers() {
        XCTAssertEqual(finished()?.sequence, 2)
    }

    func testNoSnapshotThisTurnDoesNotTrigger() {
        XCTAssertNil(finished(startedAt: nil))
        XCTAssertNil(finished(snapshots: []))
    }

    func testNoChangesDoesNotTrigger() {
        XCTAssertNil(finished(changes: 0))
    }

    func testReadyToDoneTriggers() {
        // The user denied a permission prompt and the agent stopped.
        XCTAssertEqual(finished(from: .ready, to: .done)?.sequence, 2)
        XCTAssertNil(finished(from: .ready, to: .done, changes: 0))
        XCTAssertNil(finished(from: .ready, to: .done, startedAt: nil))
    }

    func testOtherTransitionsDoNotTrigger() {
        XCTAssertNil(finished(to: .ready))
        XCTAssertNil(finished(from: .done, to: .done))
        XCTAssertNil(finished(from: .idle, to: .done))
        XCTAssertNil(finished(from: .working, to: .idle))
    }

    func testOnlyAnEarlierTurnsSnapshotDoesNotTrigger() {
        XCTAssertNil(finished(startedAt: 100, snapshots: [snapshot(agent, 1, at: 50)]))
    }

    func testChangesAreCountedOnlyWhenEverythingElseHolds() {
        var asked = 0
        let count: (TurnSnapshot) -> Int = { _ in asked += 1; return 1 }
        _ = TurnSnapshotService.finishedTurnToShow(
            from: .working, to: .ready, turnStartedAt: Date(), paneSnapshots: [], changeCount: count
        )
        XCTAssertEqual(asked, 0)
        let shown = TurnSnapshotService.finishedTurnToShow(
            from: .working,
            to: .done,
            turnStartedAt: Date(timeIntervalSince1970: 100),
            paneSnapshots: [snapshot(agent, 3, at: 101)],
            changeCount: { snapshot in asked += 1; return snapshot.sequence == 3 ? 1 : 0 }
        )
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(shown?.sequence, 3)
    }

    // MARK: - 2. Placement

    func testPlacement() {
        let max = Limits.maxPanesPerTab
        XCTAssertEqual(ChangesShowOnAgentDone.placement(.split, hasOpenPane: true, panesInAgentTab: 1), .reuse)
        XCTAssertEqual(ChangesShowOnAgentDone.placement(.split, hasOpenPane: false, panesInAgentTab: 1), .split)
        XCTAssertEqual(ChangesShowOnAgentDone.placement(.split, hasOpenPane: false, panesInAgentTab: max - 1), .split)
        XCTAssertEqual(ChangesShowOnAgentDone.placement(.split, hasOpenPane: false, panesInAgentTab: max), .tab)
        XCTAssertEqual(ChangesShowOnAgentDone.placement(.split, hasOpenPane: true, panesInAgentTab: max), .reuse)
        XCTAssertEqual(ChangesShowOnAgentDone.placement(.tab, hasOpenPane: false, panesInAgentTab: 1), .tab)
        XCTAssertEqual(ChangesShowOnAgentDone.placement(.tab, hasOpenPane: true, panesInAgentTab: 1), .reuse)
        XCTAssertEqual(ChangesShowOnAgentDone.placement(.off, hasOpenPane: false, panesInAgentTab: 1), .none)
        XCTAssertEqual(ChangesShowOnAgentDone.placement(.off, hasOpenPane: true, panesInAgentTab: 1), .none)
    }

    // MARK: - 3. Config

    private func changes(from toml: String) throws -> ChangesConfig {
        try TOMLDecoder().decode(ChangesConfig.self, from: try TOMLTable(string: toml))
    }

    func testDefaultIsSplit() throws {
        XCTAssertEqual(ChangesConfig().showOnAgentDoneSetting, .split)
        XCTAssertEqual(Config().changes?.showOnAgentDoneSetting, .split)
        XCTAssertEqual(try changes(from: "").showOnAgentDoneSetting, .split)
    }

    func testEachValueParses() throws {
        XCTAssertEqual(try changes(from: "show_on_agent_done = \"split\"").showOnAgentDoneSetting, .split)
        XCTAssertEqual(try changes(from: "show_on_agent_done = \"tab\"").showOnAgentDoneSetting, .tab)
        XCTAssertEqual(try changes(from: "show_on_agent_done = \"off\"").showOnAgentDoneSetting, .off)
    }

    func testUnknownValueFallsBackToSplit() throws {
        XCTAssertEqual(try changes(from: "show_on_agent_done = \"popup\"").showOnAgentDoneSetting, .split)
        XCTAssertEqual(ChangesShowOnAgentDone(configValue: nil), .split)
    }

    func testDefaultTemplateContainsTheKeyAndParses() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("changes-config-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("config.toml").path

        _ = Config.load(from: path)
        let template = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(template.contains("[changes]\n"))
        XCTAssertTrue(template.contains("\nshow_on_agent_done = \"split\""))

        let reloaded = Config.load(from: path)
        XCTAssertFalse(reloaded.loadDidFail)
        XCTAssertEqual(reloaded.changes?.showOnAgentDoneSetting, .split)
    }

    // MARK: - 4. Following a pane

    func testFollowedPaneWinsOverANewerSnapshotFromAnotherPane() {
        let snapshots = [
            snapshot(agent, 1, at: 10, sessionStart: true),
            snapshot(agent, 2, at: 20),
            snapshot(other, 1, at: 30, sessionStart: true),
            snapshot(other, 2, at: 40)
        ]
        let turn = ChangesScope.thisTurn.snapshot(in: snapshots, followedPane: agent)
        XCTAssertEqual(turn?.paneID, agent)
        XCTAssertEqual(turn?.sequence, 2)
        let session = ChangesScope.thisSession.snapshot(in: snapshots, followedPane: agent)
        XCTAssertEqual(session?.paneID, agent)
        XCTAssertEqual(session?.sequence, 1)
    }

    func testFollowedPaneWithoutSnapshotsFallsBackToNewestInCheckout() {
        let snapshots = [snapshot(agent, 1, at: 10, sessionStart: true), snapshot(other, 1, at: 30, sessionStart: true)]
        let missing = UUID()
        XCTAssertEqual(ChangesScope.thisTurn.snapshot(in: snapshots, followedPane: missing), snapshots[1])
        XCTAssertEqual(ChangesScope.thisSession.snapshot(in: snapshots, followedPane: missing), snapshots[1])
    }

    func testNoFollowedPaneIsTodaysBehavior() {
        let snapshots = [
            snapshot(agent, 1, at: 10, sessionStart: true),
            snapshot(other, 1, at: 20, sessionStart: true),
            snapshot(other, 2, at: 30)
        ]
        XCTAssertEqual(ChangesScope.thisTurn.snapshot(in: snapshots), snapshots[2])
        XCTAssertEqual(ChangesScope.thisSession.snapshot(in: snapshots), snapshots[1])
        XCTAssertEqual(ChangesScope.thisTurn.snapshot(in: snapshots, followedPane: nil), TurnSnapshotService.turnSnapshot(in: snapshots))
        XCTAssertNil(ChangesScope.uncommitted.snapshot(in: snapshots, followedPane: agent))
    }

    // MARK: - 5. Reuse lookup

    func testLookupFindsAChangesPaneAloneOrInsideASplit() {
        let repo = "/repo"
        let alone: [[(repository: String?, source: ChangesSource?)]] = [
            [(nil, nil)],
            [(repo, .uncommitted)]
        ]
        XCTAssertTrue(ChangesSource.paneLocation(in: alone, repositoryPath: repo, source: .uncommitted).map { $0 == (1, 0) } ?? false)

        let split: [[(repository: String?, source: ChangesSource?)]] = [
            [(nil, nil)],
            [(nil, nil), (repo, .uncommitted), (nil, nil)]
        ]
        XCTAssertTrue(ChangesSource.paneLocation(in: split, repositoryPath: repo, source: .uncommitted).map { $0 == (1, 1) } ?? false)
    }

    func testLookupIgnoresOtherCheckoutsAndBranchPanes() {
        let tabs: [[(repository: String?, source: ChangesSource?)]] = [
            [(nil, nil), ("/other", .uncommitted)],
            [("/repo", .branch(defaultBranch: "main"))]
        ]
        XCTAssertNil(ChangesSource.paneLocation(in: tabs, repositoryPath: "/repo", source: .uncommitted))
        XCTAssertTrue(ChangesSource.paneLocation(in: tabs, repositoryPath: "/repo", source: .branch(defaultBranch: "main"))
            .map { $0 == (1, 0) } ?? false)
    }

    // MARK: - 6. Session save of a split holding a changes pane

    /// Changes panes are not restored; the saved active index points at the
    /// same terminal among the panes that are kept.
    func testSavedActivePaneIndexSkipsDroppedPanes() {
        // terminal, changes, terminal, terminal
        let kept = [true, false, true, true]
        XCTAssertEqual(TabController.savedActivePaneIndex(kept: kept, activePaneIndex: 0), 0)
        XCTAssertEqual(TabController.savedActivePaneIndex(kept: kept, activePaneIndex: 2), 1)
        XCTAssertEqual(TabController.savedActivePaneIndex(kept: kept, activePaneIndex: 3), 2)
        // The changes pane itself was active: the terminal before it.
        XCTAssertEqual(TabController.savedActivePaneIndex(kept: kept, activePaneIndex: 1), 0)
        // A changes pane first and active: the first kept pane.
        XCTAssertEqual(TabController.savedActivePaneIndex(kept: [false, true], activePaneIndex: 0), 0)
        // Nothing kept (a changes pane alone): 0, and the empty tab is not restored.
        XCTAssertEqual(TabController.savedActivePaneIndex(kept: [false], activePaneIndex: 0), 0)
        // All terminals: unchanged.
        XCTAssertEqual(TabController.savedActivePaneIndex(kept: [true, true], activePaneIndex: 1), 1)
    }
}
