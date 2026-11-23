import XCTest
@testable import Cortland

/// The changes pane's "This turn" and "This session" scopes: the diff since a
/// snapshot (against real temporary git repositories), the session start
/// trailer, snapshot selection, and the pane's scope decisions.
final class TurnSnapshotChangesTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDown() {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories = []
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("turn-changes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempDirectories.append(url)
        return url.resolvingSymlinksInPath()
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let result = try ProcessRunner.shared.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", directory.path] + arguments,
            environment: [
                "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
                "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com"
            ]
        )
        XCTAssertTrue(result.succeeded, "git \(arguments.joined(separator: " ")) failed: \(result.stderr)", file: file, line: line)
        return result.stdout
    }

    private func write(_ content: String, to name: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func remove(_ name: String, in directory: URL) throws {
        try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }

    /// A repo with one commit holding `a.txt`, `b.txt`, `c.txt`, and a
    /// `.gitignore` for `*.log`.
    private func makeRepo() throws -> URL {
        let repo = try makeTempDirectory()
        try git(["init", "-q", "-b", "main"], in: repo)
        try write("a1\na2\na3\n", to: "a.txt", in: repo)
        try write("b\n", to: "b.txt", in: repo)
        try write("c\n", to: "c.txt", in: repo)
        try write("*.log\n", to: ".gitignore", in: repo)
        try git(["add", "-A"], in: repo)
        try git(["commit", "-q", "-m", "initial"], in: repo)
        return repo
    }

    private func changes(since snapshot: TurnSnapshot, in repo: URL) throws -> [TurnSnapshotChange] {
        try TurnSnapshotService().changesSinceSnapshot(commit: snapshot.commit, repositoryRoot: repo.path)
    }

    private func snapshot(
        pane: UUID,
        sequence: Int,
        at time: TimeInterval,
        sessionStart: Bool = false
    ) -> TurnSnapshot {
        TurnSnapshot(
            paneID: pane,
            sequence: sequence,
            refName: TurnSnapshotService.refName(paneID: pane, sequence: sequence),
            commit: String(repeating: "\(sequence % 10)", count: 40),
            head: nil,
            createdAt: Date(timeIntervalSince1970: time),
            isSessionStart: sessionStart
        )
    }

    // MARK: - 1. Changes since the snapshot

    func testListsFilesModifiedCreatedAndDeletedAfterSnapshot() throws {
        let repo = try makeRepo()
        // a.txt is already dirty at the snapshot; the turn changes it again.
        try write("a1\nA2\na3\n", to: "a.txt", in: repo)
        let taken = try TurnSnapshotService().takeSnapshot(paneID: UUID(), repositoryRoot: repo.path)

        try write("a1\nA2\na3\nturn\n", to: "a.txt", in: repo)
        try write("new\n", to: "dir/created.txt", in: repo)
        try remove("b.txt", in: repo)

        let result = try changes(since: taken, in: repo)
        XCTAssertEqual(result.map(\.path), ["a.txt", "b.txt", "dir/created.txt"])
        XCTAssertEqual(result.map(\.status), [.modified, .deleted, .added])

        // The modified file's diff is only the turn's edit, measured from the
        // snapshot's content, so line numbers match the file at the snapshot.
        let aDiff = try XCTUnwrap(result.first { $0.path == "a.txt" }?.diff)
        XCTAssertTrue(aDiff.contains("@@ -1,3 +1,4 @@"), aDiff)
        XCTAssertTrue(aDiff.contains("+turn"), aDiff)
        XCTAssertFalse(aDiff.contains("-a2"), aDiff)
        XCTAssertTrue(result.first { $0.path == "b.txt" }?.diff.contains("-b") == true)
        XCTAssertTrue(result.first { $0.path == "dir/created.txt" }?.diff.contains("+new") == true)
    }

    // MARK: - 2. Unchanged since the snapshot

    func testOmitsFilesUntouchedSinceSnapshotAndIgnoredFiles() throws {
        let repo = try makeRepo()
        try write("dirty before\n", to: "b.txt", in: repo)
        try write("untracked before\n", to: "old-untracked.txt", in: repo)
        let taken = try TurnSnapshotService().takeSnapshot(paneID: UUID(), repositoryRoot: repo.path)

        try write("noise\n", to: "build.log", in: repo)
        try write("turn\n", to: "c.txt", in: repo)

        let result = try changes(since: taken, in: repo)
        XCTAssertEqual(result.map(\.path), ["c.txt"])
    }

    func testNoChangesSinceSnapshotIsEmpty() throws {
        let repo = try makeRepo()
        try write("dirty\n", to: "a.txt", in: repo)
        try write("untracked\n", to: "u.txt", in: repo)
        let taken = try TurnSnapshotService().takeSnapshot(paneID: UUID(), repositoryRoot: repo.path)

        XCTAssertEqual(try changes(since: taken, in: repo), [])
    }

    // MARK: - 3. Committed during the turn

    func testFileEditedThenCommittedAfterSnapshotStillAppears() throws {
        let repo = try makeRepo()
        let taken = try TurnSnapshotService().takeSnapshot(paneID: UUID(), repositoryRoot: repo.path)

        try write("committed in turn\n", to: "c.txt", in: repo)
        try write("new and committed\n", to: "added.txt", in: repo)
        try git(["add", "-A"], in: repo)
        try git(["commit", "-q", "-m", "agent commit"], in: repo)
        XCTAssertEqual(try git(["status", "--porcelain"], in: repo), "")

        let result = try changes(since: taken, in: repo)
        XCTAssertEqual(result.map(\.path), ["added.txt", "c.txt"])
        XCTAssertEqual(result.map(\.status), [.added, .modified])
    }

    // MARK: - 4. Leaves the repository alone

    func testComputingChangesLeavesStatusIndexHeadRefsAndObjectsUnchanged() throws {
        let repo = try makeRepo()
        try write("before\n", to: "a.txt", in: repo)
        let taken = try TurnSnapshotService().takeSnapshot(paneID: UUID(), repositoryRoot: repo.path)
        try write("staged\n", to: "staged.txt", in: repo)
        try git(["add", "staged.txt"], in: repo)
        try write("after\n", to: "a.txt", in: repo)
        try write("untracked\n", to: "u.txt", in: repo)
        try remove("b.txt", in: repo)
        // Settle the index's stat cache so the comparison isolates the diff.
        try git(["status", "--porcelain"], in: repo)

        let indexURL = repo.appendingPathComponent(".git/index")
        let statusBefore = try git(["status", "--porcelain"], in: repo)
        let indexBefore = try Data(contentsOf: indexURL)
        let headBefore = try git(["rev-parse", "HEAD"], in: repo)
        let symbolicBefore = try git(["symbolic-ref", "HEAD"], in: repo)
        let refsBefore = try git(["for-each-ref"], in: repo)
        let objectsBefore = try git(["count-objects", "-v"], in: repo)

        let result = try changes(since: taken, in: repo)
        XCTAssertEqual(result.map(\.path), ["a.txt", "b.txt", "staged.txt", "u.txt"])

        XCTAssertEqual(try Data(contentsOf: indexURL), indexBefore)
        XCTAssertEqual(try git(["rev-parse", "HEAD"], in: repo), headBefore)
        XCTAssertEqual(try git(["symbolic-ref", "HEAD"], in: repo), symbolicBefore)
        XCTAssertEqual(try git(["for-each-ref"], in: repo), refsBefore)
        XCTAssertEqual(try git(["count-objects", "-v"], in: repo), objectsBefore)
        XCTAssertEqual(try git(["status", "--porcelain"], in: repo), statusBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git/index.lock").path))
    }

    // MARK: - 5. Session start trailer

    func testTransitionFromIdleIsSessionStartAndFromDoneIsNot() {
        XCTAssertTrue(TurnSnapshotService.isSessionStart(from: .idle))
        XCTAssertFalse(TurnSnapshotService.isSessionStart(from: .done))
    }

    func testSessionStartTrailerIsWrittenOnlyForSessionStarts() throws {
        let repo = try makeRepo()
        let service = TurnSnapshotService()
        let pane = UUID()

        let start = try service.takeSnapshot(paneID: pane, repositoryRoot: repo.path, isSessionStart: true)
        let next = try service.takeSnapshot(paneID: pane, repositoryRoot: repo.path)
        XCTAssertTrue(start.isSessionStart)
        XCTAssertFalse(next.isSessionStart)

        let startMessage = try git(["log", "-1", "--format=%B", start.refName], in: repo)
        let nextMessage = try git(["log", "-1", "--format=%B", next.refName], in: repo)
        XCTAssertTrue(startMessage.contains("Cortland-Session-Start: true"), startMessage)
        XCTAssertFalse(nextMessage.contains("Cortland-Session-Start"), nextMessage)

        XCTAssertEqual(try service.list(repositoryRoot: repo.path).map(\.isSessionStart), [true, false])
    }

    func testSnapshotWithoutSessionStartTrailerStillParsesAsNotSessionStart() throws {
        let repo = try makeRepo()
        let pane = UUID()
        // A message exactly as item 1 wrote it, before the trailer existed.
        let message = """
        Cortland turn snapshot

        Cortland-Pane: \(pane.uuidString.lowercased())
        Cortland-Sequence: 1
        Cortland-Head: none
        Cortland-Created: 1700000000.000000
        """
        let tree = try git(["write-tree"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        let commit = try git(["commit-tree", tree, "-m", message], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        try git(["update-ref", TurnSnapshotService.refName(paneID: pane, sequence: 1), commit], in: repo)

        let listed = try TurnSnapshotService().list(repositoryRoot: repo.path)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.paneID, pane)
        XCTAssertEqual(listed.first?.isSessionStart, false)
        XCTAssertEqual(TurnSnapshotService.parseMetadata(message)?.isSessionStart, false)
    }

    // MARK: - 6. Snapshot selection

    func testTurnSnapshotIsNewestInRepositoryAcrossPanes() {
        let paneA = UUID()
        let paneB = UUID()
        let snapshots = [
            snapshot(pane: paneA, sequence: 1, at: 1, sessionStart: true),
            snapshot(pane: paneB, sequence: 1, at: 2, sessionStart: true),
            snapshot(pane: paneA, sequence: 2, at: 3)
        ]
        XCTAssertEqual(TurnSnapshotService.turnSnapshot(in: snapshots), snapshots[2])
        XCTAssertEqual(ChangesScope.thisTurn.snapshot(in: snapshots), snapshots[2])
    }

    func testSessionSnapshotIsTurnPanesNewestSessionStart() {
        let pane = UUID()
        let snapshots = [
            snapshot(pane: pane, sequence: 1, at: 1, sessionStart: true),
            snapshot(pane: pane, sequence: 2, at: 2),
            snapshot(pane: pane, sequence: 3, at: 3, sessionStart: true),
            snapshot(pane: pane, sequence: 4, at: 4)
        ]
        XCTAssertEqual(TurnSnapshotService.sessionSnapshot(in: snapshots), snapshots[2])
        XCTAssertEqual(ChangesScope.thisSession.snapshot(in: snapshots), snapshots[2])
    }

    func testSessionSnapshotFallsBackToPanesOldestWhenNoneIsMarked() {
        let pane = UUID()
        let other = UUID()
        let snapshots = [
            snapshot(pane: other, sequence: 1, at: 1),
            snapshot(pane: pane, sequence: 7, at: 2),
            snapshot(pane: pane, sequence: 8, at: 3)
        ]
        XCTAssertEqual(TurnSnapshotService.sessionSnapshot(in: snapshots), snapshots[1])
    }

    func testSelectionOfEmptyListIsNil() {
        XCTAssertNil(TurnSnapshotService.turnSnapshot(in: []))
        XCTAssertNil(TurnSnapshotService.sessionSnapshot(in: []))
        XCTAssertNil(ChangesScope.thisTurn.snapshot(in: []))
        XCTAssertNil(ChangesScope.thisSession.snapshot(in: []))
    }

    func testOtherPanesSnapshotsDoNotLeakIntoSession() {
        let paneA = UUID()
        let paneB = UUID()
        let snapshots = [
            snapshot(pane: paneA, sequence: 1, at: 1),
            snapshot(pane: paneB, sequence: 1, at: 2, sessionStart: true),
            snapshot(pane: paneA, sequence: 2, at: 3),
            snapshot(pane: paneB, sequence: 2, at: 4, sessionStart: true),
            snapshot(pane: paneA, sequence: 3, at: 5)
        ]
        // Pane A took the newest snapshot and has no session start left, so
        // its oldest retained snapshot is used, never pane B's session start.
        XCTAssertEqual(TurnSnapshotService.sessionSnapshot(in: snapshots), snapshots[0])
    }

    func testUnfollowedPanePicksItsOwnTabsNewestOverANewerOneElsewhere() {
        let inTab = UUID()
        let elsewhere = UUID()
        let snapshots = [
            snapshot(pane: inTab, sequence: 1, at: 1, sessionStart: true),
            snapshot(pane: elsewhere, sequence: 1, at: 2, sessionStart: true),
            snapshot(pane: inTab, sequence: 2, at: 3),
            snapshot(pane: elsewhere, sequence: 2, at: 4)
        ]
        let tab: Set<UUID> = [inTab, UUID()]
        XCTAssertEqual(TurnSnapshotService.turnSnapshot(in: snapshots, tabPanes: tab), snapshots[2])
        XCTAssertEqual(TurnSnapshotService.sessionSnapshot(in: snapshots, tabPanes: tab), snapshots[0])
        XCTAssertEqual(ChangesScope.thisTurn.snapshot(in: snapshots, tabPanes: tab), snapshots[2])
        XCTAssertEqual(ChangesScope.thisSession.snapshot(in: snapshots, tabPanes: tab), snapshots[0])
    }

    func testFollowedPaneWinsOverTheTabsSnapshots() {
        let inTab = UUID()
        let followed = UUID()
        let snapshots = [
            snapshot(pane: followed, sequence: 1, at: 1, sessionStart: true),
            snapshot(pane: inTab, sequence: 1, at: 2, sessionStart: true)
        ]
        XCTAssertEqual(TurnSnapshotService.turnSnapshot(in: snapshots, followedPane: followed, tabPanes: [inTab]), snapshots[0])
        // A followed pane with no snapshot here falls to the tab's.
        XCTAssertEqual(TurnSnapshotService.turnSnapshot(in: snapshots, followedPane: UUID(), tabPanes: [inTab]), snapshots[1])
    }

    func testTabWithoutSnapshotsFallsBackToNewestInRepository() {
        let paneA = UUID()
        let paneB = UUID()
        let snapshots = [
            snapshot(pane: paneA, sequence: 1, at: 1, sessionStart: true),
            snapshot(pane: paneB, sequence: 1, at: 2, sessionStart: true),
            snapshot(pane: paneB, sequence: 2, at: 3)
        ]
        let alone: Set<UUID> = [UUID()]
        XCTAssertEqual(TurnSnapshotService.turnSnapshot(in: snapshots, tabPanes: alone), snapshots[2])
        XCTAssertEqual(TurnSnapshotService.sessionSnapshot(in: snapshots, tabPanes: alone), snapshots[1])
    }

    // MARK: - 7. Pane scope decisions

    func testScopesMapToSourcesInControlOrder() {
        XCTAssertEqual(ChangesScope.allCases, [.uncommitted, .thisTurn, .thisSession])
        XCTAssertEqual(ChangesScope.allCases.map(\.title), ["Uncommitted", "This turn", "This session"])
        XCTAssertEqual(ChangesScope.allCases.map(\.source), [.uncommitted, .thisTurn, .thisSession])
        XCTAssertNil(ChangesScope.uncommitted.snapshot(in: [snapshot(pane: UUID(), sequence: 1, at: 1)]))
    }

    func testOnlyUncommittedPanesOfferScopes() {
        XCTAssertTrue(ChangesSource.uncommitted.offersScopes)
        XCTAssertFalse(ChangesSource.branch(defaultBranch: "main").offersScopes)

        let branch = ChangesSource.branch(defaultBranch: "main")
        for scope in ChangesScope.allCases {
            XCTAssertEqual(ChangesScope.shownSource(createdWith: .uncommitted, scope: scope), scope.source)
            XCTAssertEqual(ChangesScope.shownSource(createdWith: branch, scope: scope), branch)
        }
    }

    func testStagingIsAvailableOnlyInUncommittedScope() {
        let section = ChangeSection(relativePath: "a.txt", diff: "diff", isConflicted: false, status: .modified)
        XCTAssertTrue(ChangesSource.uncommitted.allowsStaging)
        XCTAssertFalse(ChangesSource.thisTurn.allowsStaging)
        XCTAssertFalse(ChangesSource.thisSession.allowsStaging)
        XCTAssertEqual(ChangesReview.stageAction(for: section, source: ChangesScope.uncommitted.source), .stage)
        XCTAssertNil(ChangesReview.stageAction(for: section, source: ChangesScope.thisTurn.source))
        XCTAssertNil(ChangesReview.stageAction(for: section, source: ChangesScope.thisSession.source))
    }

    func testScopedSourcesHaveTheirOwnCommentIntro() {
        let intros = [ChangesSource.uncommitted, .thisTurn, .thisSession].map(\.commentIntro)
        XCTAssertEqual(Set(intros).count, 3)
        XCTAssertTrue(ChangesSource.thisTurn.commentIntro.contains("turn"))
        XCTAssertTrue(ChangesSource.thisSession.commentIntro.contains("session"))
    }
}
