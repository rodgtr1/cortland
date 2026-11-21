import XCTest
@testable import Cortland

/// Rewinding the working tree to a turn snapshot and undoing that, against
/// real temporary git repositories, plus the changes pane's rewind decisions.
final class TurnSnapshotRewindTests: XCTestCase {
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
            .appendingPathComponent("turn-rewind-\(UUID().uuidString)", isDirectory: true)
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

    private func read(_ name: String, in directory: URL) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    private func exists(_ name: String, in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
    }

    private func remove(_ name: String, in directory: URL) throws {
        try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }

    private func modificationDate(_ name: String, in directory: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
        return try XCTUnwrap(attributes[.modificationDate] as? Date)
    }

    private func isExecutable(_ name: String, in directory: URL) throws -> Bool {
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? Int)
        return permissions & 0o100 != 0
    }

    private func allRefs(in repo: URL) throws -> [String] {
        try git(["for-each-ref", "--format=%(refname) %(objectname)"], in: repo)
            .split(separator: "\n").map(String.init)
    }

    private func undoRef(in repo: URL) throws -> String? {
        try TurnSnapshotService().rewindUndoCommit(repositoryRoot: repo.path)
    }

    /// A repo with one commit holding `a.txt`, `b.txt`, `keep.txt`, and a
    /// `.gitignore` for `*.log`.
    private func makeRepo() throws -> URL {
        let repo = try makeTempDirectory()
        try git(["init", "-q", "-b", "main"], in: repo)
        try write("a original\n", to: "a.txt", in: repo)
        try write("b\n", to: "b.txt", in: repo)
        try write("keep\n", to: "keep.txt", in: repo)
        try write("*.log\n", to: ".gitignore", in: repo)
        try git(["add", "-A"], in: repo)
        try git(["commit", "-q", "-m", "initial"], in: repo)
        return repo
    }

    /// After a snapshot of `makeRepo`: modifies `a.txt`, deletes `b.txt`,
    /// creates `new/dir/created.txt`, and writes an ignored log.
    private func makeTurnEdits(in repo: URL) throws {
        try write("a agent edit\n", to: "a.txt", in: repo)
        try remove("b.txt", in: repo)
        try write("created\n", to: "new/dir/created.txt", in: repo)
        try write("log after\n", to: "debug.log", in: repo)
    }

    // MARK: - 1. What a rewind restores

    func testRewindRestoresModifiedRecreatesDeletedDeletesCreatedAndLeavesIgnored() throws {
        let repo = try makeRepo()
        try write("log before\n", to: "debug.log", in: repo)
        let service = TurnSnapshotService()
        let snapshot = try service.takeSnapshot(paneID: UUID(), repositoryRoot: repo.path)
        try makeTurnEdits(in: repo)

        let reverted = try service.rewind(to: snapshot.commit, repositoryRoot: repo.path)

        XCTAssertEqual(reverted.map(\.path), ["a.txt", "b.txt", "new/dir/created.txt"])
        XCTAssertEqual(try read("a.txt", in: repo), "a original\n")
        XCTAssertEqual(try read("b.txt", in: repo), "b\n")
        XCTAssertFalse(exists("new/dir/created.txt", in: repo))
        XCTAssertFalse(exists("new/dir", in: repo))
        XCTAssertFalse(exists("new", in: repo))
        XCTAssertEqual(try read("debug.log", in: repo), "log after\n")
        XCTAssertEqual(try git(["status", "--porcelain"], in: repo), "")
    }

    func testRewindKeepsADirectoryThatStillHoldsOtherFiles() throws {
        let repo = try makeRepo()
        try write("ignored\n", to: "logs/keep.log", in: repo)
        let service = TurnSnapshotService()
        let snapshot = try service.takeSnapshot(paneID: UUID(), repositoryRoot: repo.path)
        try write("created\n", to: "logs/created.txt", in: repo)

        try service.rewind(to: snapshot.commit, repositoryRoot: repo.path)

        XCTAssertFalse(exists("logs/created.txt", in: repo))
        XCTAssertEqual(try read("logs/keep.log", in: repo), "ignored\n")
    }

    // MARK: - 2. Unchanged files are not rewritten

    func testRewindLeavesUnchangedFileModificationDate() throws {
        let repo = try makeRepo()
        let service = TurnSnapshotService()
        let snapshot = try service.takeSnapshot(paneID: UUID(), repositoryRoot: repo.path)
        let past = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: repo.appendingPathComponent("keep.txt").path)
        try makeTurnEdits(in: repo)

        try service.rewind(to: snapshot.commit, repositoryRoot: repo.path)

        XCTAssertEqual(try modificationDate("keep.txt", in: repo), past)
    }

    // MARK: - 3. Executable bit

    func testRewindRestoresExecutableBit() throws {
        let repo = try makeRepo()
        let script = repo.appendingPathComponent("run.sh")
        try write("#!/bin/sh\n", to: "run.sh", in: repo)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try write("#!/bin/sh\n", to: "plain.sh", in: repo)
        try git(["add", "-A"], in: repo)
        try git(["commit", "-q", "-m", "scripts"], in: repo)
        let service = TurnSnapshotService()
        let snapshot = try service.takeSnapshot(paneID: UUID(), repositoryRoot: repo.path)

        // Mode-only changes, both ways.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: script.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.appendingPathComponent("plain.sh").path)
        XCTAssertEqual(try service.changesSinceSnapshot(commit: snapshot.commit, repositoryRoot: repo.path).map(\.path), ["plain.sh", "run.sh"])

        try service.rewind(to: snapshot.commit, repositoryRoot: repo.path)

        XCTAssertTrue(try isExecutable("run.sh", in: repo))
        XCTAssertFalse(try isExecutable("plain.sh", in: repo))
    }

    // MARK: - 4. Commits since the snapshot stay

    func testRewindPastACommitLeavesHeadAndBranchAndMatchesSnapshot() throws {
        let repo = try makeRepo()
        let service = TurnSnapshotService()
        let snapshot = try service.takeSnapshot(paneID: UUID(), repositoryRoot: repo.path)
        try makeTurnEdits(in: repo)
        try git(["add", "-A"], in: repo)
        try git(["commit", "-q", "-m", "agent commit"], in: repo)
        let head = try git(["rev-parse", "HEAD"], in: repo)
        let symbolic = try git(["symbolic-ref", "HEAD"], in: repo)
        let branch = try git(["rev-parse", "refs/heads/main"], in: repo)

        try service.rewind(to: snapshot.commit, repositoryRoot: repo.path)

        XCTAssertEqual(try git(["rev-parse", "HEAD"], in: repo), head)
        XCTAssertEqual(try git(["symbolic-ref", "HEAD"], in: repo), symbolic)
        XCTAssertEqual(try git(["rev-parse", "refs/heads/main"], in: repo), branch)
        XCTAssertEqual(try git(["rev-list", "--count", "HEAD"], in: repo), "2\n")
        XCTAssertEqual(try read("a.txt", in: repo), "a original\n")
        XCTAssertEqual(try read("b.txt", in: repo), "b\n")
        XCTAssertFalse(exists("new/dir/created.txt", in: repo))
        // The reverted content shows as uncommitted against the agent's commit.
        // (b.txt is tracked-deleted in HEAD, so it shows as untracked.)
        XCTAssertEqual(
            Set(try git(["status", "--porcelain"], in: repo).split(separator: "\n").map(String.init)),
            [" M a.txt", " D new/dir/created.txt", "?? b.txt"]
        )
    }

    // MARK: - 5. Real index and refs

    func testRewindLeavesRealIndexBytesAndCreatesOnlyTheUndoRef() throws {
        let repo = try makeRepo()
        let service = TurnSnapshotService()
        let snapshot = try service.takeSnapshot(paneID: UUID(), repositoryRoot: repo.path)
        try makeTurnEdits(in: repo)
        try write("staged\n", to: "staged.txt", in: repo)
        try git(["add", "staged.txt"], in: repo)
        let indexURL = repo.appendingPathComponent(".git/index")
        let indexBefore = try Data(contentsOf: indexURL)
        let refsBefore = try allRefs(in: repo)

        try service.rewind(to: snapshot.commit, repositoryRoot: repo.path)

        XCTAssertEqual(try Data(contentsOf: indexURL), indexBefore)
        XCTAssertFalse(exists(".git/index.lock", in: repo))
        let undo = try XCTUnwrap(try undoRef(in: repo))
        XCTAssertEqual(try allRefs(in: repo), (refsBefore + ["\(TurnSnapshotService.rewindUndoRef) \(undo)"]).sorted())
    }

    // MARK: - 6. Nothing left to rewind

    func testAfterRewindChangesSinceSnapshotIsEmpty() throws {
        let repo = try makeRepo()
        let service = TurnSnapshotService()
        let snapshot = try service.takeSnapshot(paneID: UUID(), repositoryRoot: repo.path)
        try makeTurnEdits(in: repo)
        XCTAssertFalse(try service.changesSinceSnapshot(commit: snapshot.commit, repositoryRoot: repo.path).isEmpty)

        try service.rewind(to: snapshot.commit, repositoryRoot: repo.path)

        XCTAssertEqual(try service.changesSinceSnapshot(commit: snapshot.commit, repositoryRoot: repo.path), [])
    }

    // MARK: - 7. Undo

    func testUndoRewindRestoresPreRewindStateAndRemovesUndoRef() throws {
        let repo = try makeRepo()
        let service = TurnSnapshotService()
        let snapshot = try service.takeSnapshot(paneID: UUID(), repositoryRoot: repo.path)
        try makeTurnEdits(in: repo)
        let indexBefore = try Data(contentsOf: repo.appendingPathComponent(".git/index"))
        try service.rewind(to: snapshot.commit, repositoryRoot: repo.path)
        XCTAssertNotNil(try undoRef(in: repo))

        try service.undoRewind(repositoryRoot: repo.path)

        XCTAssertEqual(try read("a.txt", in: repo), "a agent edit\n")
        XCTAssertFalse(exists("b.txt", in: repo))
        XCTAssertEqual(try read("new/dir/created.txt", in: repo), "created\n")
        XCTAssertEqual(try read("debug.log", in: repo), "log after\n")
        XCTAssertNil(try undoRef(in: repo))
        XCTAssertEqual(try Data(contentsOf: repo.appendingPathComponent(".git/index")), indexBefore)
        XCTAssertEqual(
            try service.changesSinceSnapshot(commit: snapshot.commit, repositoryRoot: repo.path).map(\.path),
            ["a.txt", "b.txt", "new/dir/created.txt"]
        )
    }

    func testUndoWithoutAnUndoSnapshotThrows() throws {
        let repo = try makeRepo()
        XCTAssertThrowsError(try TurnSnapshotService().undoRewind(repositoryRoot: repo.path)) { error in
            guard case TurnSnapshotError.noRewindUndo = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    // MARK: - 8. One level of undo, outside turn snapshots

    func testSecondRewindReplacesUndoSnapshot() throws {
        let repo = try makeRepo()
        let service = TurnSnapshotService()
        let snapshot = try service.takeSnapshot(paneID: UUID(), repositoryRoot: repo.path)
        try write("first edit\n", to: "a.txt", in: repo)
        try service.rewind(to: snapshot.commit, repositoryRoot: repo.path)
        let firstUndo = try XCTUnwrap(try undoRef(in: repo))

        try write("second edit\n", to: "a.txt", in: repo)
        try service.rewind(to: snapshot.commit, repositoryRoot: repo.path)
        let secondUndo = try XCTUnwrap(try undoRef(in: repo))

        XCTAssertNotEqual(firstUndo, secondUndo)
        try service.undoRewind(repositoryRoot: repo.path)
        XCTAssertEqual(try read("a.txt", in: repo), "second edit\n")
    }

    func testUndoRefIsNotListedSurvivesPruningAndNewTurnSnapshotDeletesIt() throws {
        let repo = try makeRepo()
        let service = TurnSnapshotService()
        let pane = UUID()
        var latest = try service.takeSnapshot(paneID: pane, repositoryRoot: repo.path)
        for _ in 0..<TurnSnapshotService.retainedCount {
            latest = try service.takeSnapshot(paneID: pane, repositoryRoot: repo.path)
        }
        try write("edit\n", to: "a.txt", in: repo)
        try service.rewind(to: latest.commit, repositoryRoot: repo.path)
        let undo = try XCTUnwrap(try undoRef(in: repo))

        let listed = try service.list(repositoryRoot: repo.path)
        XCTAssertEqual(listed.count, TurnSnapshotService.retainedCount)
        XCTAssertFalse(listed.contains { $0.refName == TurnSnapshotService.rewindUndoRef || $0.commit == undo })

        // Retention at its limit, run on its own, neither counts nor deletes it.
        try service.prune(repositoryRoot: repo.path)
        XCTAssertEqual(try service.list(repositoryRoot: repo.path), listed)
        XCTAssertEqual(try undoRef(in: repo), undo)

        _ = try service.takeSnapshot(paneID: pane, repositoryRoot: repo.path)

        XCTAssertEqual(try service.list(repositoryRoot: repo.path).count, TurnSnapshotService.retainedCount)
        XCTAssertNil(try undoRef(in: repo))
    }

    func testTakingSnapshotWithoutUndoRefSucceeds() throws {
        let repo = try makeRepo()
        XCTAssertNoThrow(try TurnSnapshotService().takeSnapshot(paneID: UUID(), repositoryRoot: repo.path))
        XCTAssertNil(try undoRef(in: repo))
    }

    // MARK: - 9. Linked worktrees

    func testRewindAndUndoInLinkedWorktreeLeaveMainCheckoutAlone() throws {
        let main = try makeRepo()
        let worktree = try makeTempDirectory().appendingPathComponent("wt")
        try git(["worktree", "add", "-q", "-b", "feature", worktree.path], in: main)
        try write("main edit\n", to: "a.txt", in: main)
        try write("main new\n", to: "main-only.txt", in: main)
        let mainIndex = try Data(contentsOf: main.appendingPathComponent(".git/index"))
        let mainRefs = try allRefs(in: main)
        let mainStatus = try git(["status", "--porcelain"], in: main)

        let service = TurnSnapshotService()
        let snapshot = try service.takeSnapshot(paneID: UUID(), repositoryRoot: worktree.path)
        let mainRefsWithSnapshot = try allRefs(in: main)
        try makeTurnEdits(in: worktree)

        try service.rewind(to: snapshot.commit, repositoryRoot: worktree.path)

        XCTAssertEqual(try read("a.txt", in: worktree), "a original\n")
        XCTAssertFalse(exists("new", in: worktree))
        XCTAssertNotNil(try undoRef(in: worktree))
        XCTAssertNil(try undoRef(in: main))
        XCTAssertEqual(try read("a.txt", in: main), "main edit\n")
        XCTAssertEqual(try read("main-only.txt", in: main), "main new\n")
        XCTAssertEqual(try git(["status", "--porcelain"], in: main), mainStatus)
        XCTAssertEqual(try Data(contentsOf: main.appendingPathComponent(".git/index")), mainIndex)
        XCTAssertEqual(try allRefs(in: main), mainRefsWithSnapshot)

        try service.undoRewind(repositoryRoot: worktree.path)

        XCTAssertEqual(try read("a.txt", in: worktree), "a agent edit\n")
        XCTAssertEqual(try read("new/dir/created.txt", in: worktree), "created\n")
        XCTAssertNil(try undoRef(in: worktree))
        XCTAssertEqual(try read("a.txt", in: main), "main edit\n")
        XCTAssertEqual(try git(["status", "--porcelain"], in: main), mainStatus)
        XCTAssertEqual(try Data(contentsOf: main.appendingPathComponent(".git/index")), mainIndex)
        XCTAssertEqual(try allRefs(in: main), mainRefsWithSnapshot)
        XCTAssertEqual(mainRefs, mainRefsWithSnapshot)
    }

    // MARK: - Batching and order

    /// Runs real git, records each git subcommand, and can fail `checkout-index`.
    private nonisolated final class RecordingRunner: ProcessRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [[String]] = []
        let failsCheckoutIndex: Bool

        init(failsCheckoutIndex: Bool = false) {
            self.failsCheckoutIndex = failsCheckoutIndex
        }

        /// The arguments after `-C <root>` of each `checkout-index` call.
        var checkoutIndexCalls: [[String]] {
            lock.lock(); defer { lock.unlock() }
            return recorded.filter { $0.first == "checkout-index" }
        }

        func run(executableURL: URL, arguments: [String], currentDirectoryURL: URL?, environment: [String: String]?) throws -> ProcessResult {
            let gitArguments = Array(arguments.dropFirst(2))
            lock.lock()
            recorded.append(gitArguments)
            lock.unlock()
            if failsCheckoutIndex && gitArguments.first == "checkout-index" {
                return ProcessResult(terminationStatus: 128, stdout: "", stderr: "simulated failure")
            }
            return try ProcessRunner.shared.run(
                executableURL: executableURL,
                arguments: arguments,
                currentDirectoryURL: currentDirectoryURL,
                environment: environment
            )
        }
    }

    func testRewindOfMoreFilesThanOneBatchRestoresThemAllInBatches() throws {
        let repo = try makeRepo()
        let names = (1...7).map { "many/file\($0).txt" }
        for name in names { try write("original \(name)\n", to: name, in: repo) }
        try git(["add", "-A"], in: repo)
        try git(["commit", "-q", "-m", "many"], in: repo)
        let runner = RecordingRunner()
        let service = TurnSnapshotService(runner: runner, checkoutBatchSize: 3)
        let snapshot = try service.takeSnapshot(paneID: UUID(), repositoryRoot: repo.path)
        for name in names.prefix(5) { try write("edited\n", to: name, in: repo) }
        for name in names.suffix(2) { try remove(name, in: repo) }
        try write("created\n", to: "many/created.txt", in: repo)

        try service.rewind(to: snapshot.commit, repositoryRoot: repo.path)

        for name in names { XCTAssertEqual(try read(name, in: repo), "original \(name)\n") }
        XCTAssertFalse(exists("many/created.txt", in: repo))
        XCTAssertEqual(try service.changesSinceSnapshot(commit: snapshot.commit, repositoryRoot: repo.path), [])
        // 7 paths at 3 per call.
        XCTAssertEqual(runner.checkoutIndexCalls.map { $0.count - 3 }, [3, 3, 1])
        XCTAssertEqual(Set(runner.checkoutIndexCalls.flatMap { $0.dropFirst(3) }), Set(names))
    }

    func testFailedCheckoutLeavesCreatedFilesAndTheUndoRef() throws {
        let repo = try makeRepo()
        let service = TurnSnapshotService(runner: RecordingRunner(failsCheckoutIndex: true))
        let snapshot = try service.takeSnapshot(paneID: UUID(), repositoryRoot: repo.path)
        try makeTurnEdits(in: repo)

        XCTAssertThrowsError(try service.rewind(to: snapshot.commit, repositoryRoot: repo.path))

        XCTAssertEqual(try read("new/dir/created.txt", in: repo), "created\n")
        XCTAssertEqual(try read("a.txt", in: repo), "a agent edit\n")
        XCTAssertNotNil(try undoRef(in: repo))
    }

    func testRewindWhereADirectoryReplacedASnapshotFile() throws {
        let repo = try makeRepo()
        let service = TurnSnapshotService()
        let snapshot = try service.takeSnapshot(paneID: UUID(), repositoryRoot: repo.path)
        try remove("b.txt", in: repo)
        try write("inside\n", to: "b.txt/inner/one.txt", in: repo)
        try write("inside\n", to: "b.txt/two.txt", in: repo)
        try write("elsewhere\n", to: "other/created.txt", in: repo)

        try service.rewind(to: snapshot.commit, repositoryRoot: repo.path)

        XCTAssertEqual(try read("b.txt", in: repo), "b\n")
        XCTAssertFalse(exists("other", in: repo))
        XCTAssertEqual(try service.changesSinceSnapshot(commit: snapshot.commit, repositoryRoot: repo.path), [])

        try service.undoRewind(repositoryRoot: repo.path)
        XCTAssertEqual(try read("b.txt/inner/one.txt", in: repo), "inside\n")
        XCTAssertEqual(try read("b.txt/two.txt", in: repo), "inside\n")
        XCTAssertEqual(try read("other/created.txt", in: repo), "elsewhere\n")
    }

    func testRewindWhereAFileReplacedASnapshotDirectory() throws {
        let repo = try makeRepo()
        try write("deep\n", to: "dir/deep.txt", in: repo)
        try git(["add", "-A"], in: repo)
        try git(["commit", "-q", "-m", "dir"], in: repo)
        let service = TurnSnapshotService()
        let snapshot = try service.takeSnapshot(paneID: UUID(), repositoryRoot: repo.path)
        try remove("dir", in: repo)
        try write("now a file\n", to: "dir", in: repo)

        try service.rewind(to: snapshot.commit, repositoryRoot: repo.path)

        XCTAssertEqual(try read("dir/deep.txt", in: repo), "deep\n")
        XCTAssertEqual(try service.changesSinceSnapshot(commit: snapshot.commit, repositoryRoot: repo.path), [])
    }

    func testCreatedPathsInTheWay() {
        XCTAssertEqual(
            TurnSnapshotService.createdPathsInTheWay(
                created: ["b.txt/inner/one.txt", "b.txt/two.txt", "dir", "other/x.txt", "b.txtx/y"],
                restored: ["b.txt", "dir/deep.txt", "a.txt"]
            ),
            ["b.txt/inner/one.txt", "b.txt/two.txt", "dir"]
        )
        XCTAssertEqual(TurnSnapshotService.createdPathsInTheWay(created: ["new.txt"], restored: []), [])
    }

    // MARK: - 10. Pane decisions

    func testRewindButtonShowsOnlyInSnapshotScopesWithChanges() {
        XCTAssertFalse(ChangesRewind.showsRewind(scope: .uncommitted, hasSnapshot: true, changedFileCount: 3))
        XCTAssertTrue(ChangesRewind.showsRewind(scope: .thisTurn, hasSnapshot: true, changedFileCount: 1))
        XCTAssertTrue(ChangesRewind.showsRewind(scope: .thisSession, hasSnapshot: true, changedFileCount: 2))
        XCTAssertFalse(ChangesRewind.showsRewind(scope: .thisTurn, hasSnapshot: true, changedFileCount: 0))
        XCTAssertFalse(ChangesRewind.showsRewind(scope: .thisSession, hasSnapshot: false, changedFileCount: 0))
    }

    func testCountsSplitRestoredFromDeleted() {
        XCTAssertEqual(
            ChangesRewind.counts(for: [.modified, .deleted, .added, .added, .modified]),
            ChangesRewind.Counts(restored: 3, deleted: 2)
        )
        XCTAssertEqual(ChangesRewind.counts(for: []), ChangesRewind.Counts(restored: 0, deleted: 0))
    }

    func testConfirmationWording() {
        let turn = ChangesRewind.confirmationMessage(counts: .init(restored: 3, deleted: 1), scope: .thisTurn)
        XCTAssertTrue(turn.hasPrefix("3 files will be restored and 1 file will be deleted, putting the working tree back to how it was when this turn started."))
        XCTAssertTrue(turn.contains("Commits made since are not undone"))
        XCTAssertTrue(turn.contains("The agent is not told. Its conversation still assumes its edits exist."))

        let session = ChangesRewind.confirmationMessage(counts: .init(restored: 1, deleted: 0), scope: .thisSession)
        XCTAssertTrue(session.hasPrefix("1 file will be restored and 0 files will be deleted"))
        XCTAssertTrue(session.contains("when this session started."))

        XCTAssertEqual(ChangesRewind.confirmationTitle(scope: .thisTurn), "Rewind This Turn?")
        XCTAssertEqual(ChangesRewind.confirmationTitle(scope: .thisSession), "Rewind This Session?")
        for text in [turn, session] {
            XCTAssertFalse(text.contains("\u{2014}"))
            XCTAssertFalse(text.contains("\u{2013}"))
        }
    }
}
