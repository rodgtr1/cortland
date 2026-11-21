import XCTest
@testable import Cortland

/// The Agents panel's files-changed-this-turn lines: the store's update rules,
/// the shared current-turn rule (against a real temporary repository), the
/// row model, row height, and row equality.
@MainActor
final class AgentDashboardTurnFilesTests: XCTestCase {
    private let paneA = UUID()
    private let paneB = UUID()
    private var tempDirectories: [URL] = []

    override func tearDown() {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories = []
        super.tearDown()
    }

    // MARK: - Helpers

    private func file(_ path: String, _ status: GitFileStatus = .modified, root: String = "/repo") -> TurnChangedFile {
        TurnChangedFile(repositoryRoot: root, path: path, status: status)
    }

    private func entry(_ files: [TurnChangedFile], finishedAt: TimeInterval = 100, turnStartedAt: TimeInterval? = 50) -> PaneTurnFiles {
        PaneTurnFiles(
            repositoryRoot: files.first?.repositoryRoot ?? "/repo",
            files: files,
            finishedAt: Date(timeIntervalSince1970: finishedAt),
            turnStartedAt: turnStartedAt.map { Date(timeIntervalSince1970: $0) }
        )
    }

    private func store(_ entries: [UUID: PaneTurnFiles]) -> TurnChangedFilesStore {
        var store = TurnChangedFilesStore()
        for (paneID, result) in entries {
            store.land(result, paneID: paneID, currentState: .done, currentTurnStartedAt: result.turnStartedAt)
        }
        return store
    }

    private func snapshot(_ pane: UUID, _ sequence: Int, at seconds: TimeInterval) -> TurnSnapshot {
        TurnSnapshot(
            paneID: pane,
            sequence: sequence,
            refName: TurnSnapshotService.refName(paneID: pane, sequence: sequence),
            commit: "c\(sequence)",
            head: nil,
            createdAt: Date(timeIntervalSince1970: seconds)
        )
    }

    private func makeRepo() throws -> URL {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("turn-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        tempDirectories.append(repo)
        let resolved = repo.resolvingSymlinksInPath()
        try git(["init", "-q", "-b", "main"], in: resolved)
        try "a\n".write(to: resolved.appendingPathComponent("edit.txt"), atomically: true, encoding: .utf8)
        try "b\n".write(to: resolved.appendingPathComponent("gone.txt"), atomically: true, encoding: .utf8)
        try git(["add", "-A"], in: resolved)
        try git(["commit", "-q", "-m", "initial"], in: resolved)
        return resolved
    }

    private func git(_ arguments: [String], in directory: URL) throws {
        let result = try ProcessRunner.shared.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", directory.path] + arguments,
            environment: [
                "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
                "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com"
            ]
        )
        XCTAssertTrue(result.succeeded, "git \(arguments.joined(separator: " ")) failed: \(result.stderr)")
    }

    // MARK: - 1. Store update rules

    func testTurnStartClearsTheEntry() {
        XCTAssertEqual(TurnChangedFilesStore.update(from: .done, to: .working), .remove)
        XCTAssertEqual(TurnChangedFilesStore.update(from: .idle, to: .working), .remove)
        var store = store([paneA: entry([file("a.swift")])])
        store.remove(paneID: paneA)
        XCTAssertNil(store.entries[paneA])
    }

    func testReadyAndDoneRecomputeAndStoreTheResult() {
        XCTAssertEqual(TurnChangedFilesStore.update(from: .working, to: .ready), .recompute)
        XCTAssertEqual(TurnChangedFilesStore.update(from: .working, to: .done), .recompute)
        XCTAssertEqual(TurnChangedFilesStore.update(from: .ready, to: .done), .recompute)

        var store = TurnChangedFilesStore()
        let result = entry([file("a.swift")])
        store.land(result, paneID: paneA, currentState: .ready, currentTurnStartedAt: result.turnStartedAt)
        XCTAssertEqual(store.entries[paneA], result)
        let done = entry([file("b.swift")])
        store.land(done, paneID: paneA, currentState: .done, currentTurnStartedAt: done.turnStartedAt)
        XCTAssertEqual(store.entries[paneA], done)
    }

    func testIdleAndPaneCloseRemoveTheEntry() {
        XCTAssertEqual(TurnChangedFilesStore.update(from: .done, to: .idle), .remove)
        XCTAssertEqual(TurnChangedFilesStore.update(from: .working, to: .idle), .remove)
        var store = store([paneA: entry([file("a.swift")]), paneB: entry([file("b.swift")])])
        store.remove(paneID: paneA)
        XCTAssertNil(store.entries[paneA])
        store.keepOnly(paneIDs: [])
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testWorkingToWorkingLeavesTheEntryAlone() {
        XCTAssertEqual(TurnChangedFilesStore.update(from: .working, to: .working), .none)
        // Resuming after an approval prompt is the same turn.
        XCTAssertEqual(TurnChangedFilesStore.update(from: .ready, to: .working), .none)
    }

    func testAResultThatLandsAfterThePaneMovedOnIsDropped() {
        var store = TurnChangedFilesStore()
        let result = entry([file("a.swift")], turnStartedAt: 50)
        store.land(result, paneID: paneA, currentState: .working, currentTurnStartedAt: result.turnStartedAt)
        XCTAssertNil(store.entries[paneA])
        store.land(result, paneID: paneA, currentState: .done, currentTurnStartedAt: Date(timeIntervalSince1970: 60))
        XCTAssertNil(store.entries[paneA])
    }

    // MARK: - 2. Current-turn rule

    func testNoSnapshotForTheCurrentTurnMeansNoSnapshot() {
        XCTAssertNil(TurnSnapshotService.currentTurnSnapshot(turnStartedAt: nil, paneSnapshots: [snapshot(paneA, 1, at: 100)]))
        XCTAssertNil(TurnSnapshotService.currentTurnSnapshot(turnStartedAt: Date(timeIntervalSince1970: 100), paneSnapshots: []))
        // Only an earlier turn's snapshot.
        XCTAssertNil(TurnSnapshotService.currentTurnSnapshot(
            turnStartedAt: Date(timeIntervalSince1970: 100),
            paneSnapshots: [snapshot(paneA, 1, at: 50)]
        ))
        XCTAssertEqual(TurnSnapshotService.currentTurnSnapshot(
            turnStartedAt: Date(timeIntervalSince1970: 100),
            paneSnapshots: [snapshot(paneA, 1, at: 50), snapshot(paneA, 2, at: 100.1)]
        )?.sequence, 2)
    }

    func testComputeListsEditedAddedAndDeletedFilesSinceTheTurnsSnapshot() throws {
        let repo = try makeRepo()
        let service = TurnSnapshotService()
        let turnStartedAt = Date()
        _ = try service.takeSnapshot(paneID: paneA, repositoryRoot: repo.path)

        try "a changed\n".write(to: repo.appendingPathComponent("edit.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("gone.txt"))

        let result = TurnChangedFilesStore.compute(
            paneID: paneA,
            workingDirectory: repo.path,
            turnStartedAt: turnStartedAt,
            finishedAt: Date(),
            service: service
        )
        XCTAssertEqual(result.repositoryRoot, repo.path)
        XCTAssertEqual(result.files.map(\.path), ["edit.txt", "gone.txt", "new.txt"])
        XCTAssertEqual(result.files.map(\.status), [.modified, .deleted, .added])
        XCTAssertEqual(result.files[0].absolutePath, repo.appendingPathComponent("edit.txt").path)

        // The same pane with no snapshot for this turn: nothing.
        let noTurn = TurnChangedFilesStore.compute(
            paneID: paneA,
            workingDirectory: repo.path,
            turnStartedAt: nil,
            finishedAt: Date(),
            service: service
        )
        XCTAssertEqual(noTurn.files, [])
        // A later turn that took no snapshot of its own.
        let later = TurnChangedFilesStore.compute(
            paneID: paneA,
            workingDirectory: repo.path,
            turnStartedAt: Date().addingTimeInterval(60),
            finishedAt: Date(),
            service: service
        )
        XCTAssertEqual(later.files, [])
        // Another pane's snapshot is not this pane's turn.
        let other = TurnChangedFilesStore.compute(
            paneID: paneB,
            workingDirectory: repo.path,
            turnStartedAt: turnStartedAt,
            finishedAt: Date(),
            service: service
        )
        XCTAssertEqual(other.files, [])
    }

    // MARK: - 3. Row model

    func testUnionAcrossPanesListsEachPathOnceInPathOrder() {
        let store = store([
            paneA: entry([file("z.swift"), file("b/shared.swift")], finishedAt: 100),
            paneB: entry([file("b/shared.swift"), file("a.swift", .added)], finishedAt: 200)
        ])
        let row = AgentRowFiles.make(paneIDs: [paneA, paneB], store: store)
        XCTAssertEqual(row.shown.map(\.file.path), ["a.swift", "b/shared.swift", "z.swift"])
        XCTAssertEqual(row.moreCount, 0)
        XCTAssertEqual(row.lineCount, 3)
        // Same order whichever pane comes first in the tab.
        XCTAssertEqual(AgentRowFiles.make(paneIDs: [paneB, paneA], store: store), row)
    }

    func testSamePathInDifferentCheckoutsIsTwoFiles() {
        let store = store([
            paneA: entry([file("a.swift", root: "/one")]),
            paneB: entry([file("a.swift", root: "/two")])
        ])
        XCTAssertEqual(AgentRowFiles.make(paneIDs: [paneA, paneB], store: store).shown.count, 2)
    }

    func testADuplicatedFileFollowsThePaneThatFinishedLast() {
        let earlier = store([
            paneA: entry([file("shared.swift")], finishedAt: 300),
            paneB: entry([file("shared.swift")], finishedAt: 200)
        ])
        XCTAssertEqual(AgentRowFiles.make(paneIDs: [paneA, paneB], store: earlier).shown.first?.paneID, paneA)
        let later = store([
            paneA: entry([file("shared.swift")], finishedAt: 100),
            paneB: entry([file("shared.swift")], finishedAt: 200)
        ])
        XCTAssertEqual(AgentRowFiles.make(paneIDs: [paneA, paneB], store: later).shown.first?.paneID, paneB)
    }

    func testFiveFileCapWithAndNMore() {
        let eight = (1...8).map { file("f\($0).swift") }
        let store = store([paneA: entry(Array(eight.prefix(3)), finishedAt: 100), paneB: entry(Array(eight.dropFirst(3)), finishedAt: 200)])
        let row = AgentRowFiles.make(paneIDs: [paneA, paneB], store: store)
        XCTAssertEqual(row.shown.map(\.file.path), ["f1.swift", "f2.swift", "f3.swift", "f4.swift", "f5.swift"])
        XCTAssertEqual(row.moreCount, 3)
        XCTAssertEqual(row.lineCount, 6)
        XCTAssertEqual(row.morePaneID, paneB)
        XCTAssertEqual(row.moreRepositoryRoot, "/repo")

        let exactlyFive = AgentRowFiles.make(paneIDs: [paneA], store: self.store([paneA: entry(Array(eight.prefix(5)))]))
        XCTAssertEqual(exactlyFive.moreCount, 0)
        XCTAssertNil(exactlyFive.morePaneID)
        XCTAssertEqual(exactlyFive.lineCount, 5)
    }

    func testPanesWithNothingChangedGiveAnEmptyRow() {
        let store = store([paneA: entry([])])
        XCTAssertEqual(AgentRowFiles.make(paneIDs: [paneA, paneB], store: store), .empty)
        XCTAssertEqual(AgentRowFiles.empty.lineCount, 0)
    }

    // MARK: - 4. Row height

    private func rowFiles(_ count: Int) -> AgentRowFiles {
        AgentRowFiles.make(
            paneIDs: [paneA],
            store: store([paneA: entry((0..<count).map { file("f\($0).swift") })])
        )
    }

    func testRowHeightForZeroOneFiveAndEightFiles() {
        let base = AgentDashboardViewController.rowHeight(telemetryLines: 1, hasContextBar: true, files: .empty)
        XCTAssertEqual(base, 42 + 16 + 9)
        XCTAssertEqual(AgentDashboardViewController.rowHeight(telemetryLines: 1, hasContextBar: true, files: rowFiles(0)), base)
        XCTAssertEqual(AgentDashboardViewController.rowHeight(telemetryLines: 1, hasContextBar: true, files: rowFiles(1)), base + 16)
        XCTAssertEqual(AgentDashboardViewController.rowHeight(telemetryLines: 1, hasContextBar: true, files: rowFiles(5)), base + 5 * 16)
        // 5 files plus "and 3 more".
        XCTAssertEqual(AgentDashboardViewController.rowHeight(telemetryLines: 1, hasContextBar: true, files: rowFiles(8)), base + 6 * 16)
        XCTAssertEqual(AgentDashboardViewController.rowHeight(telemetryLines: 0, hasContextBar: false, files: .empty), 42)
    }

    // MARK: - 5. Row equality

    private func row(_ files: AgentRowFiles) -> AgentDashboardViewController.Row {
        AgentDashboardViewController.Row(
            tabIndex: 0,
            title: "agent",
            state: .done,
            since: Date(timeIntervalSince1970: 10),
            isActive: false,
            hasCommandAttention: false,
            usage: nil,
            cost: nil,
            paneTelemetries: [],
            files: files
        )
    }

    func testRowsWithTheSameFilesAreEqual() {
        XCTAssertEqual(row(rowFiles(3)), row(rowFiles(3)))
        XCTAssertEqual(row(.empty), row(.empty))
    }

    func testRowsWithADifferentFileListAreNotEqual() {
        XCTAssertNotEqual(row(rowFiles(3)), row(rowFiles(4)))
        XCTAssertNotEqual(row(.empty), row(rowFiles(1)))
        let modified = AgentRowFiles.make(paneIDs: [paneA], store: store([paneA: entry([file("a.swift", .modified)])]))
        let deleted = AgentRowFiles.make(paneIDs: [paneA], store: store([paneA: entry([file("a.swift", .deleted)])]))
        XCTAssertNotEqual(row(modified), row(deleted))
    }
}
