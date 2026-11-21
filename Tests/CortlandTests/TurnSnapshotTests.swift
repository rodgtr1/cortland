import XCTest
@testable import Cortland

/// Per-turn working tree snapshots, against real temporary git repositories.
final class TurnSnapshotTests: XCTestCase {
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
            .appendingPathComponent("turn-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempDirectories.append(url)
        // Resolve /var -> /private/var so paths match what git reports.
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

    /// A repo with one commit holding `tracked.txt` and a `.gitignore` for `*.log`.
    private func makeRepoWithCommit() throws -> URL {
        let repo = try makeTempDirectory()
        try git(["init", "-q", "-b", "main"], in: repo)
        try write("original\n", to: "tracked.txt", in: repo)
        try write("*.log\n", to: ".gitignore", in: repo)
        try git(["add", "-A"], in: repo)
        try git(["commit", "-q", "-m", "initial"], in: repo)
        return repo
    }

    private func filesInCommit(_ commit: String, repo: URL) throws -> Set<String> {
        let output = try git(["ls-tree", "-r", "--name-only", commit], in: repo)
        return Set(output.split(separator: "\n").map(String.init))
    }

    private func snapshotRefs(in repo: URL) throws -> [String] {
        try git(["for-each-ref", "--format=%(refname)", TurnSnapshotService.refPrefix], in: repo)
            .split(separator: "\n").map(String.init)
    }

    // MARK: - 1. Transition decision

    func testTurnStartsWhenWorkingFollowsDoneOrIdle() {
        XCTAssertTrue(TurnSnapshotService.startsTurn(from: .done, to: .working, hookAuthoritative: true))
        XCTAssertTrue(TurnSnapshotService.startsTurn(from: .idle, to: .working, hookAuthoritative: true))
    }

    func testResumingAfterApprovalIsNotATurnStart() {
        XCTAssertFalse(TurnSnapshotService.startsTurn(from: .ready, to: .working, hookAuthoritative: true))
        XCTAssertFalse(TurnSnapshotService.startsTurn(from: .working, to: .working, hookAuthoritative: true))
    }

    func testGatedResumeIsNotATurnStart() {
        // `gated` is not its own AgentState: the detector maps it to working, so
        // a gated pane resuming is working to working.
        let gated = AgentStateDetector.state(fromStatus: "gated")
        XCTAssertEqual(gated, .working)
        XCTAssertFalse(TurnSnapshotService.startsTurn(from: gated!, to: .working, hookAuthoritative: true))
    }

    func testLeavingWorkingIsNotATurnStart() {
        for next in [AgentState.idle, .ready, .done] {
            for previous in AgentState.allCases {
                XCTAssertFalse(TurnSnapshotService.startsTurn(from: previous, to: next, hookAuthoritative: true))
            }
        }
    }

    /// The detector's deduped stream, judged pairwise the way the pane does,
    /// snapshots once per prompt: not on the approval resume, not on a gated
    /// report, not on each tool's busy.
    @MainActor
    func testDetectorStreamStartsOneTurnPerPrompt() {
        let detector = AgentStateDetector()
        var previous = AgentState.idle
        var turnStarts = 0
        detector.onStateChange = { state in
            if TurnSnapshotService.startsTurn(from: previous, to: state, hookAuthoritative: detector.hasExplicitStatus) {
                turnStarts += 1
            }
            previous = state
        }

        for token in ["busy", "busy", "gated", "busy", "ready", "busy", "done", "busy", "busy", "done"] {
            detector.handleStatusToken(token)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(turnStarts, 2)
    }

    func testUnhookedPaneNeverStartsTurn() {
        XCTAssertFalse(TurnSnapshotService.startsTurn(from: .done, to: .working, hookAuthoritative: false))
        XCTAssertFalse(TurnSnapshotService.startsTurn(from: .idle, to: .working, hookAuthoritative: false))
    }

    /// Without hooks the heuristics flip working to done after each quiet
    /// period and back on the next cue. None of those transitions snapshots.
    @MainActor
    func testHeuristicDoneToWorkingFlipsDoNotStartTurns() {
        let detector = AgentStateDetector(doneQuietPeriod: 0.05)
        var previous = AgentState.idle
        var transitions: [AgentState] = []
        var turnStarts = 0
        detector.onStateChange = { state in
            if TurnSnapshotService.startsTurn(from: previous, to: state, hookAuthoritative: detector.hasExplicitStatus) {
                turnStarts += 1
            }
            previous = state
            transitions.append(state)
        }

        for _ in 0..<3 {
            detector.processHeuristics(chunk: "Thinking…")
            let doneCount = transitions.filter { $0 == .done }.count
            let deadline = Date().addingTimeInterval(5)
            while transitions.filter({ $0 == .done }).count == doneCount && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }

        XCTAssertFalse(detector.hasExplicitStatus)
        XCTAssertEqual(transitions, [.working, .done, .working, .done, .working, .done])
        XCTAssertEqual(turnStarts, 0)
    }

    // MARK: - 2. Snapshot contents

    func testSnapshotCapturesTrackedStagedAndUntrackedButNotIgnored() throws {
        let repo = try makeRepoWithCommit()
        try write("modified\n", to: "tracked.txt", in: repo)
        try write("staged\n", to: "staged.txt", in: repo)
        try git(["add", "staged.txt"], in: repo)
        try write("untracked\n", to: "dir/untracked.txt", in: repo)
        try write("ignored\n", to: "debug.log", in: repo)

        let snapshot = try TurnSnapshotService().takeSnapshot(paneID: UUID(), repositoryRoot: repo.path)

        let files = try filesInCommit(snapshot.commit, repo: repo)
        XCTAssertEqual(files, [".gitignore", "tracked.txt", "staged.txt", "dir/untracked.txt"])
        XCTAssertEqual(try git(["show", "\(snapshot.commit):tracked.txt"], in: repo), "modified\n")
        XCTAssertEqual(try git(["show", "\(snapshot.commit):staged.txt"], in: repo), "staged\n")
        XCTAssertEqual(try git(["show", "\(snapshot.commit):dir/untracked.txt"], in: repo), "untracked\n")
    }

    func testSnapshotCapturesDeletedTrackedFile() throws {
        let repo = try makeRepoWithCommit()
        try FileManager.default.removeItem(at: repo.appendingPathComponent("tracked.txt"))

        let snapshot = try TurnSnapshotService().takeSnapshot(paneID: UUID(), repositoryRoot: repo.path)

        XCTAssertEqual(try filesInCommit(snapshot.commit, repo: repo), [".gitignore"])
    }

    // MARK: - 3. Repository left untouched

    func testSnapshotLeavesStatusIndexAndHeadUnchanged() throws {
        let repo = try makeRepoWithCommit()
        try write("modified\n", to: "tracked.txt", in: repo)
        try write("staged\n", to: "staged.txt", in: repo)
        try git(["add", "staged.txt"], in: repo)
        try write("untracked\n", to: "untracked.txt", in: repo)
        // Settle the index's stat cache first so the comparison isolates the
        // snapshot (a plain `git status` may itself rewrite the index).
        try git(["status", "--porcelain"], in: repo)

        let indexURL = repo.appendingPathComponent(".git/index")
        let statusBefore = try git(["status", "--porcelain"], in: repo)
        let indexBefore = try Data(contentsOf: indexURL)
        let headBefore = try git(["rev-parse", "HEAD"], in: repo)
        let symbolicBefore = try git(["symbolic-ref", "HEAD"], in: repo)
        let branchesBefore = try git(["for-each-ref", "refs/heads"], in: repo)

        _ = try TurnSnapshotService().takeSnapshot(paneID: UUID(), repositoryRoot: repo.path)

        XCTAssertEqual(try Data(contentsOf: indexURL), indexBefore)
        XCTAssertEqual(try git(["rev-parse", "HEAD"], in: repo), headBefore)
        XCTAssertEqual(try git(["symbolic-ref", "HEAD"], in: repo), symbolicBefore)
        XCTAssertEqual(try git(["for-each-ref", "refs/heads"], in: repo), branchesBefore)
        XCTAssertEqual(try git(["status", "--porcelain"], in: repo), statusBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git/index.lock").path))
        XCTAssertEqual(try git(["stash", "list"], in: repo), "")
    }

    func testSnapshotInLinkedWorktreeUsesItsOwnIndex() throws {
        let repo = try makeRepoWithCommit()
        let worktree = try makeTempDirectory().appendingPathComponent("wt")
        try git(["worktree", "add", "-q", "-b", "feature", worktree.path], in: repo)
        try write("worktree change\n", to: "tracked.txt", in: worktree)
        try write("new\n", to: "wt-only.txt", in: worktree)
        try git(["add", "wt-only.txt"], in: worktree)

        let snapshot = try TurnSnapshotService().takeSnapshot(paneID: UUID(), repositoryRoot: worktree.path)

        XCTAssertEqual(try filesInCommit(snapshot.commit, repo: worktree), [".gitignore", "tracked.txt", "wt-only.txt"])
        XCTAssertEqual(try git(["show", "\(snapshot.commit):tracked.txt"], in: worktree), "worktree change\n")
        XCTAssertEqual(try git(["status", "--porcelain"], in: repo), "")
    }

    /// A main checkout and one linked worktree of the same repository.
    private func makeRepoWithLinkedWorktree() throws -> (main: URL, worktree: URL) {
        let repo = try makeRepoWithCommit()
        let worktree = try makeTempDirectory().appendingPathComponent("wt")
        try git(["worktree", "add", "-q", "-b", "feature", worktree.path], in: repo)
        return (repo, worktree)
    }

    func testSnapshotsArePrivateToEachWorktree() throws {
        let (main, worktree) = try makeRepoWithLinkedWorktree()
        let service = TurnSnapshotService()

        let inMain = try service.takeSnapshot(paneID: UUID(), repositoryRoot: main.path)
        let inWorktree = try service.takeSnapshot(paneID: UUID(), repositoryRoot: worktree.path)

        XCTAssertEqual(try service.list(repositoryRoot: main.path), [inMain])
        XCTAssertEqual(try service.list(repositoryRoot: worktree.path), [inWorktree])
        XCTAssertEqual(TurnSnapshotService.turnSnapshot(in: try service.list(repositoryRoot: main.path)), inMain)
        XCTAssertEqual(TurnSnapshotService.turnSnapshot(in: try service.list(repositoryRoot: worktree.path)), inWorktree)
        XCTAssertEqual(ChangesScope.thisTurn.snapshot(in: try service.list(repositoryRoot: worktree.path)), inWorktree)

        // for-each-ref with the prefix works from both checkouts.
        XCTAssertEqual(try snapshotRefs(in: main), [inMain.refName])
        XCTAssertEqual(try snapshotRefs(in: worktree), [inWorktree.refName])
        XCTAssertTrue(inMain.refName.hasPrefix("refs/worktree/cortland/turns/"))
    }

    func testSnapshotRefsLiveInTheGitDirectoryTheChangesPaneWatches() throws {
        let (main, worktree) = try makeRepoWithLinkedWorktree()
        let service = TurnSnapshotService()

        let inMain = try service.takeSnapshot(paneID: UUID(), repositoryRoot: main.path)
        let inWorktree = try service.takeSnapshot(paneID: UUID(), repositoryRoot: worktree.path)

        // The pane watches the checkout root (which holds `.git` in a main
        // checkout) and, for a linked worktree, its `.git/worktrees/<name>`.
        XCTAssertNil(GitStatusModel.linkedWorktreeGitDir(forRoot: main.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: main.appendingPathComponent(".git").appendingPathComponent(inMain.refName).path
        ))
        let worktreeGitDir = try XCTUnwrap(GitStatusModel.linkedWorktreeGitDir(forRoot: worktree.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: worktreeGitDir).appendingPathComponent(inWorktree.refName).path
        ))
    }

    func testPruningInOneWorktreeKeepsTheOthersSnapshots() throws {
        let (main, worktree) = try makeRepoWithLinkedWorktree()
        let service = TurnSnapshotService()
        let mainPane = UUID()
        let worktreePane = UUID()

        let mainSnapshots = [
            try service.takeSnapshot(paneID: mainPane, repositoryRoot: main.path),
            try service.takeSnapshot(paneID: mainPane, repositoryRoot: main.path)
        ]
        var worktreeSnapshots: [TurnSnapshot] = []
        for _ in 0..<(TurnSnapshotService.retainedCount + 2) {
            worktreeSnapshots.append(try service.takeSnapshot(paneID: worktreePane, repositoryRoot: worktree.path))
        }

        XCTAssertEqual(try service.list(repositoryRoot: worktree.path), Array(worktreeSnapshots.suffix(TurnSnapshotService.retainedCount)))
        XCTAssertEqual(try service.list(repositoryRoot: main.path), mainSnapshots)
        XCTAssertEqual(try snapshotRefs(in: main), mainSnapshots.map(\.refName))
    }

    // MARK: - 4. Unborn HEAD

    func testRepoWithNoCommitsSnapshotsAsParentlessCommit() throws {
        let repo = try makeTempDirectory()
        try git(["init", "-q", "-b", "main"], in: repo)
        try write("hello\n", to: "first.txt", in: repo)

        let snapshot = try TurnSnapshotService().takeSnapshot(paneID: UUID(), repositoryRoot: repo.path)

        XCTAssertNil(snapshot.head)
        XCTAssertEqual(try filesInCommit(snapshot.commit, repo: repo), ["first.txt"])
        let parents = try git(["rev-list", "--parents", "-n", "1", snapshot.commit], in: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(parents, snapshot.commit, "expected no parents")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git/index").path))
        let head = try ProcessRunner.shared.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", repo.path, "rev-parse", "--verify", "--quiet", "HEAD"]
        )
        XCTAssertFalse(head.succeeded, "HEAD should still be unborn")
    }

    // MARK: - 5. Sequences and listing

    func testSequencesIncreasePerPaneAndListReturnsMetadataInOrder() throws {
        let repo = try makeRepoWithCommit()
        let headSHA = try git(["rev-parse", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        let service = TurnSnapshotService()
        let paneA = UUID()
        let paneB = UUID()

        let a1 = try service.takeSnapshot(paneID: paneA, repositoryRoot: repo.path)
        let b1 = try service.takeSnapshot(paneID: paneB, repositoryRoot: repo.path)
        try write("next\n", to: "tracked.txt", in: repo)
        let a2 = try service.takeSnapshot(paneID: paneA, repositoryRoot: repo.path)
        let a3 = try service.takeSnapshot(paneID: paneA, repositoryRoot: repo.path)

        XCTAssertEqual([a1.sequence, a2.sequence, a3.sequence], [1, 2, 3])
        XCTAssertEqual(b1.sequence, 1)
        XCTAssertEqual(a1.refName, "refs/worktree/cortland/turns/\(paneA.uuidString.lowercased())/1")
        XCTAssertEqual(b1.refName, "refs/worktree/cortland/turns/\(paneB.uuidString.lowercased())/1")
        XCTAssertNotEqual(a1.refName, b1.refName)

        XCTAssertEqual(try service.list(repositoryRoot: repo.path, paneID: paneA), [a1, a2, a3])
        XCTAssertEqual(try service.list(repositoryRoot: repo.path, paneID: paneB), [b1])
        XCTAssertEqual(try service.list(repositoryRoot: repo.path), [a1, b1, a2, a3])

        for snapshot in [a1, a2, a3, b1] {
            XCTAssertEqual(snapshot.head, headSHA)
            let refTarget = try git(["rev-parse", snapshot.refName], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(refTarget, snapshot.commit)
            let parent = try git(["rev-parse", "\(snapshot.commit)^"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(parent, headSHA)
        }

        // The metadata is in the commit message itself, readable from the ref.
        let message = try git(["log", "-1", "--format=%B", a2.refName], in: repo)
        XCTAssertEqual(
            TurnSnapshotService.parseMetadata(message),
            TurnSnapshotService.Metadata(paneID: paneA, sequence: 2, head: headSHA, createdAt: a2.createdAt)
        )

        // A fresh service (as after an app restart) lists the same thing.
        XCTAssertEqual(try TurnSnapshotService().list(repositoryRoot: repo.path), [a1, b1, a2, a3])
    }

    func testParseRefNameRejectsForeignRefs() {
        let pane = UUID()
        let parsed = TurnSnapshotService.parseRefName(TurnSnapshotService.refName(paneID: pane, sequence: 7))
        XCTAssertEqual(parsed?.paneID, pane)
        XCTAssertEqual(parsed?.sequence, 7)
        XCTAssertNil(TurnSnapshotService.parseRefName("refs/heads/main"))
        XCTAssertNil(TurnSnapshotService.parseRefName("refs/worktree/cortland/turns/not-a-uuid/1"))
        XCTAssertNil(TurnSnapshotService.parseRefName("refs/cortland/turns/\(pane.uuidString.lowercased())/1"))
        XCTAssertNil(TurnSnapshotService.parseRefName("refs/worktree/cortland/turns/\(pane.uuidString)/x"))
    }

    func testMalformedSnapshotRefIsSkippedAndDoesNotBlockSnapshots() throws {
        let repo = try makeRepoWithCommit()
        let pane = UUID()
        let head = try git(["rev-parse", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        // A ref in the snapshot layout pointing at an ordinary commit with no
        // Cortland trailers.
        try git(["update-ref", TurnSnapshotService.refName(paneID: pane, sequence: 9), head], in: repo)
        let service = TurnSnapshotService()

        XCTAssertEqual(try service.list(repositoryRoot: repo.path), [])
        let snapshot = try service.takeSnapshot(paneID: pane, repositoryRoot: repo.path)
        XCTAssertEqual(snapshot.sequence, 1)
        XCTAssertEqual(try service.list(repositoryRoot: repo.path), [snapshot])
    }

    // MARK: - 6. Retention

    func testRetentionKeepsNewestFiftyAcrossPanes() throws {
        let repo = try makeRepoWithCommit()
        let service = TurnSnapshotService()
        let paneA = UUID()
        let paneB = UUID()

        var taken: [TurnSnapshot] = []
        for index in 0..<53 {
            taken.append(try service.takeSnapshot(paneID: index.isMultiple(of: 2) ? paneA : paneB, repositoryRoot: repo.path))
        }

        let remaining = try service.list(repositoryRoot: repo.path)
        XCTAssertEqual(remaining.count, 50)
        XCTAssertEqual(remaining, Array(taken.suffix(50)))
        XCTAssertEqual(try snapshotRefs(in: repo).count, 50)
        for pruned in taken.prefix(3) {
            XCTAssertFalse(try snapshotRefs(in: repo).contains(pruned.refName))
        }
        // Pruning a pane's oldest refs does not reuse its sequence numbers.
        let next = try service.takeSnapshot(paneID: paneA, repositoryRoot: repo.path)
        XCTAssertEqual(next.sequence, 28)
    }

    // MARK: - 7. Outside a repository

    func testPathOutsideAnyRepoIsSilentNoOp() throws {
        let directory = try makeTempDirectory()
        try write("not in git\n", to: "file.txt", in: directory)

        XCTAssertNil(TurnSnapshotService().snapshotTurn(paneID: UUID(), workingDirectory: directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path))
    }

    func testSnapshotTurnResolvesRepoFromSubdirectory() throws {
        let repo = try makeRepoWithCommit()
        try write("x\n", to: "sub/deep/file.txt", in: repo)
        let pane = UUID()

        let snapshot = TurnSnapshotService().snapshotTurn(paneID: pane, workingDirectory: repo.appendingPathComponent("sub/deep").path)

        XCTAssertEqual(snapshot?.paneID, pane)
        XCTAssertEqual(snapshot?.sequence, 1)
        XCTAssertTrue(try filesInCommit(snapshot!.commit, repo: repo).contains("sub/deep/file.txt"))
    }
}
