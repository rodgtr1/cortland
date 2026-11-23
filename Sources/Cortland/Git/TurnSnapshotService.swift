import Foundation
import os

/// One saved working tree: the state a pane's repository was in when an agent
/// in that pane started a turn. Stored as a commit under
/// `refs/worktree/cortland/turns/<pane-uuid>/<sequence>`; the refs are the
/// only record. Refs under `refs/worktree/` are private to each worktree (the
/// main checkout included), so one checkout never sees another's snapshots.
nonisolated struct TurnSnapshot: Equatable, Sendable {
    let paneID: UUID
    let sequence: Int
    let refName: String
    let commit: String
    /// The repository's HEAD commit when the snapshot was taken; nil for a repo
    /// with no commits yet.
    let head: String?
    let createdAt: Date
    /// The turn began from idle (a session's first prompt), not from done.
    /// Snapshots written before the trailer existed read as false.
    var isSessionStart = false
}

/// One file that differs between a snapshot and the working tree now.
nonisolated struct TurnSnapshotChange: Equatable, Sendable {
    let path: String
    /// `.modified`, `.deleted`, or `.added` (created since the snapshot).
    let status: GitFileStatus
    let diff: String
}

nonisolated enum TurnSnapshotError: LocalizedError {
    case gitFailed(command: String, stderr: String)
    /// `undoRewind` found no undo snapshot.
    case noRewindUndo
    /// Something the restore cannot clear stands where a file goes back:
    /// a directory still holding files the rewind does not delete (ignored
    /// ones, for example), or such a file where a directory goes back.
    /// `path` is repository-relative.
    case restoreBlocked(path: String, isDirectory: Bool)

    var errorDescription: String? {
        switch self {
        case .gitFailed(let command, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "git \(command) failed." : "git \(command) failed: \(detail)"
        case .noRewindUndo:
            return "There is no rewind to undo."
        case .restoreBlocked(let path, true):
            return "The directory \"\(path)\" is in the way of a file that needs to be restored, and it holds files "
                + "that are not deleted (ignored files, for example). Nothing was changed. "
                + "Move or remove \"\(path)\", then try again."
        case .restoreBlocked(let path, false):
            return "The file \"\(path)\" is in the way of a directory that needs to be restored, and it is "
                + "not deleted (it is ignored, for example). Nothing was changed. "
                + "Move or remove \"\(path)\", then try again."
        }
    }
}

/// Saves and lists per-turn working tree snapshots without touching the
/// repository's real index, HEAD, branches, or working tree.
///
/// Off the main actor like GitService: every call shells out to git and is
/// meant to run on `queue`.
nonisolated final class TurnSnapshotService: Sendable {
    static let shared = TurnSnapshotService()

    /// Serial, so per-pane sequence numbers and retention never race each other.
    static let queue = DispatchQueue(label: "app.cortland.terminal.turn-snapshots", qos: .utility)

    static let refPrefix = "refs/worktree/cortland/turns/"
    static let retainedCount = 50
    /// The working tree as it was before the last rewind. Outside `refPrefix`,
    /// so `list` and retention never see it; per worktree like the snapshots.
    static let rewindUndoRef = "refs/worktree/cortland/rewind-undo"

    private let runner: ProcessRunning
    private let gitService: GitService
    /// Paths per `checkout-index` call in a rewind, so a large rewind stays
    /// under the argument length limit. Tests pass a small one.
    private let checkoutBatchSize: Int
    /// Panes whose next turn Cortland starts itself by telling the agent
    /// about a rewind, keyed by resolved repository root and pane. That one
    /// turn keeps the undo ref. Set on the main thread, consumed on `queue`.
    private let rewindUpdateTurns = OSAllocatedUnfairLock(initialState: Set<RewindUpdateTurn>())

    private struct RewindUpdateTurn: Hashable, Sendable {
        let repositoryRoot: String
        let paneID: UUID

        init(repositoryRoot: String, paneID: UUID) {
            self.repositoryRoot = URL(fileURLWithPath: repositoryRoot).resolvingSymlinksInPath().standardizedFileURL.path
            self.paneID = paneID
        }
    }

    init(runner: ProcessRunning = ProcessRunner.shared, checkoutBatchSize: Int = 300) {
        self.runner = runner
        self.gitService = GitService(runner: runner)
        self.checkoutBatchSize = checkoutBatchSize
    }

    // MARK: - Rewind update turns

    /// Marks the next turn `paneID` starts in `repositoryRoot` as the one a
    /// rewind update prompt starts, so its snapshot keeps the undo ref.
    func markRewindUpdateTurn(paneID: UUID, repositoryRoot: String) {
        let key = RewindUpdateTurn(repositoryRoot: repositoryRoot, paneID: paneID)
        _ = rewindUpdateTurns.withLock { $0.insert(key) }
    }

    /// Drops a mark that no turn will consume (the prompt was not sent).
    func clearRewindUpdateTurn(paneID: UUID, repositoryRoot: String) {
        let key = RewindUpdateTurn(repositoryRoot: repositoryRoot, paneID: paneID)
        _ = rewindUpdateTurns.withLock { $0.remove(key) }
    }

    /// Removes the mark and reports whether it was there.
    private func consumeRewindUpdateTurn(paneID: UUID, repositoryRoot: String) -> Bool {
        let key = RewindUpdateTurn(repositoryRoot: repositoryRoot, paneID: paneID)
        return rewindUpdateTurns.withLock { $0.remove(key) != nil }
    }

    // MARK: - Turn detection

    /// Whether an agent state change starts a new turn. A turn starts when the
    /// pane becomes working from done or idle (the first prompt of a session,
    /// or the next prompt after a finished turn). Working from ready is the same
    /// turn resuming after an approval. A `gated` report maps to working, so a
    /// gated pane resuming is working to working, which never starts a turn.
    ///
    /// Only a hook-authoritative pane starts turns: without hooks the text
    /// heuristics flip working to done after every quiet period and back on the
    /// next cue, so one turn (or a plain shell) would look like many.
    static func startsTurn(from previous: AgentState, to next: AgentState, hookAuthoritative: Bool) -> Bool {
        hookAuthoritative && next == .working && (previous == .done || previous == .idle)
    }

    /// Whether the turn a transition starts is also a session start: the pane
    /// came from idle (its first prompt), not from a finished turn.
    static func isSessionStart(from previous: AgentState) -> Bool {
        previous == .idle
    }

    // MARK: - Snapshots

    /// Snapshots the repository containing `workingDirectory`. Returns nil,
    /// silently, when the directory is not inside a git repo. A failed snapshot
    /// is logged and also returns nil.
    func snapshotTurn(paneID: UUID, workingDirectory: String, isSessionStart: Bool = false) -> TurnSnapshot? {
        guard let root = gitService.repositoryRoot(from: workingDirectory) else { return nil }
        do {
            let snapshot = try takeSnapshot(paneID: paneID, repositoryRoot: root, isSessionStart: isSessionStart)
            Log.debug("turn snapshot \(snapshot.refName) at \(snapshot.commit) in \(root)", category: "turn-snapshot")
            return snapshot
        } catch {
            Log.error("turn snapshot failed for pane \(paneID) in \(root): \(error)", category: "turn-snapshot")
            return nil
        }
    }

    /// Writes the working tree (tracked changes, staged and unstaged, plus
    /// untracked files that are not ignored) to a new snapshot ref, then prunes
    /// the repository's snapshots to the newest `retainedCount` and deletes
    /// the undo ref, unless this pane's turn was marked as a rewind update.
    func takeSnapshot(paneID: UUID, repositoryRoot: String, isSessionStart: Bool = false) throws -> TurnSnapshot {
        let tree = try writeWorkingTree(repositoryRoot: repositoryRoot)
        let head = try currentHead(repositoryRoot: repositoryRoot)

        let sequence = (try list(repositoryRoot: repositoryRoot, paneID: paneID).map(\.sequence).max() ?? 0) + 1
        let createdAt = Date()
        let message = Self.commitMessage(
            paneID: paneID,
            sequence: sequence,
            head: head,
            createdAt: createdAt,
            isSessionStart: isSessionStart
        )

        var commitArguments = ["commit-tree", tree, "-m", message]
        if let head { commitArguments += ["-p", head] }
        let commit = try git(commitArguments, repositoryRoot: repositoryRoot, environment: Self.identityEnvironment)

        let refName = Self.refName(paneID: paneID, sequence: sequence)
        // The empty old value makes update-ref refuse to overwrite an existing ref.
        try git(["update-ref", refName, commit, ""], repositoryRoot: repositoryRoot)

        try prune(repositoryRoot: repositoryRoot)
        // The tree has moved on, so a rewind from before this turn no longer
        // has a state worth undoing to. Deleting a missing ref succeeds. The
        // one turn a rewind update prompt starts is not the tree moving on.
        if !consumeRewindUpdateTurn(paneID: paneID, repositoryRoot: repositoryRoot) {
            try git(["update-ref", "-d", Self.rewindUndoRef], repositoryRoot: repositoryRoot)
        }

        return TurnSnapshot(
            paneID: paneID,
            sequence: sequence,
            refName: refName,
            commit: commit,
            head: head,
            createdAt: Self.parseMetadata(message)?.createdAt ?? createdAt,
            isSessionStart: isSessionStart
        )
    }

    /// This checkout's snapshots, oldest first, optionally only one pane's.
    /// Within a pane that is sequence order.
    func list(repositoryRoot: String, paneID: UUID? = nil) throws -> [TurnSnapshot] {
        let prefix = paneID.map { Self.refPrefix + $0.uuidString.lowercased() + "/" } ?? Self.refPrefix
        let output = try git(
            ["for-each-ref", "--format=%(refname)%1f%(objectname)%1f%(contents)%1e", prefix],
            repositoryRoot: repositoryRoot,
            trimmingOutput: false
        )
        return Self.parseSnapshotList(output)
    }

    /// Pins the patch format GitService.splitDiffByFile parses regardless of
    /// user git config, and keeps a repo's external diff or textconv driver from running.
    private static let patchFlags = ["--no-color", "--no-ext-diff", "--no-textconv", "--src-prefix=a/", "--dst-prefix=b/"]
    private static let nameStatusFlags = ["--no-color", "--no-ext-diff"]

    /// Every file that differs between `commit`'s tree and the working tree
    /// now, in path order: modified and deleted files, plus files created since
    /// (untracked ones included, ignored ones not). A file left as it was when
    /// the snapshot was taken is absent, however it compares with HEAD, and a
    /// change committed since the snapshot still counts.
    ///
    /// Works in a throwaway index filled by `read-tree`, so the real index,
    /// HEAD, refs, and working tree are never touched, and no objects are
    /// written.
    func changesSinceSnapshot(commit: String, repositoryRoot: String) throws -> [TurnSnapshotChange] {
        let tempIndex = FileManager.default.temporaryDirectory
            .appendingPathComponent("cortland-turn-diff-index-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempIndex)
            try? FileManager.default.removeItem(atPath: tempIndex.path + ".lock")
        }
        let indexEnvironment = ["GIT_INDEX_FILE": tempIndex.path]

        try git(["read-tree", commit], repositoryRoot: repositoryRoot, environment: indexEnvironment)
        // read-tree leaves no stat data, so record it once: the diffs below
        // then skip unchanged files without rehashing each one. Exits non-zero
        // when files differ, which is the expected case.
        _ = try runGit(["update-index", "-q", "--refresh"], repositoryRoot: repositoryRoot, environment: indexEnvironment)

        let nameStatus = try git(
            ["diff"] + Self.nameStatusFlags + ["--no-renames", "--name-status"],
            repositoryRoot: repositoryRoot,
            environment: indexEnvironment,
            trimmingOutput: false
        )
        let patches = GitService.splitDiffByFile(try git(
            ["diff"] + Self.patchFlags + ["--no-renames"],
            repositoryRoot: repositoryRoot,
            environment: indexEnvironment,
            trimmingOutput: false
        ))
        var changes = GitService.parseNameStatusOutput(nameStatus).map { entry in
            TurnSnapshotChange(
                path: entry.path,
                status: entry.status == "D" ? .deleted : .modified,
                diff: patches[entry.path] ?? "No changes"
            )
        }

        let created = try git(
            ["ls-files", "-z", "--others", "--exclude-standard"],
            repositoryRoot: repositoryRoot,
            environment: indexEnvironment,
            trimmingOutput: false
        )
        for path in created.split(separator: "\0").map(String.init) {
            let diff = (try? gitService.untrackedFileDiff(relativePath: path, repositoryRoot: repositoryRoot)) ?? "No changes"
            changes.append(TurnSnapshotChange(path: path, status: .added, diff: diff))
        }
        return changes.sorted { $0.path < $1.path }
    }

    // MARK: - Rewind

    /// Puts the working tree back to `commit`'s tree for exactly the files
    /// `changesSinceSnapshot` reports: modified and deleted files get the
    /// snapshot's content and mode back, files created since are deleted (and
    /// any directory that leaves empty). Ignored and unchanged files are not
    /// touched, and HEAD, branches, commits, and the real index stay as they
    /// are, so content reverted past a commit shows as uncommitted changes.
    ///
    /// First checks that nothing it would not delete blocks a restored path
    /// (`restoreBlocked`), then saves the current working tree at
    /// `rewindUndoRef`, replacing any earlier one; if either fails nothing
    /// changes. A failure after that throws and leaves the undo ref in place.
    /// Returns the changes it reverted.
    @discardableResult
    func rewind(to commit: String, repositoryRoot: String) throws -> [TurnSnapshotChange] {
        let changes = try changesSinceSnapshot(commit: commit, repositoryRoot: repositoryRoot)
        try checkRestoreIsUnblocked(changes, repositoryRoot: repositoryRoot)

        let tree = try writeWorkingTree(repositoryRoot: repositoryRoot)
        var commitArguments = ["commit-tree", tree, "-m", "Cortland rewind undo"]
        if let head = try currentHead(repositoryRoot: repositoryRoot) { commitArguments += ["-p", head] }
        let undo = try git(commitArguments, repositoryRoot: repositoryRoot, environment: Self.identityEnvironment)
        try git(["update-ref", Self.rewindUndoRef, undo], repositoryRoot: repositoryRoot)

        let kept = try restoreWorkingTree(changes, from: commit, repositoryRoot: repositoryRoot)
        return changes.filter { !kept.contains($0.path) }
    }

    /// Restores the working tree saved by the last `rewind`, by the same
    /// mechanism and with the same up-front check, then deletes the undo ref.
    /// Throws `noRewindUndo` when there is none; on any other failure the ref
    /// stays.
    func undoRewind(repositoryRoot: String) throws {
        guard let undo = try rewindUndoCommit(repositoryRoot: repositoryRoot) else {
            throw TurnSnapshotError.noRewindUndo
        }
        let changes = try changesSinceSnapshot(commit: undo, repositoryRoot: repositoryRoot)
        try checkRestoreIsUnblocked(changes, repositoryRoot: repositoryRoot)
        try restoreWorkingTree(changes, from: undo, repositoryRoot: repositoryRoot)
        try git(["update-ref", "-d", Self.rewindUndoRef, undo], repositoryRoot: repositoryRoot)
    }

    /// The commit at `rewindUndoRef` in this checkout, or nil when there is none.
    func rewindUndoCommit(repositoryRoot: String) throws -> String? {
        let result = try runGit(
            ["rev-parse", "--verify", "--quiet", Self.rewindUndoRef + "^{commit}"],
            repositoryRoot: repositoryRoot
        )
        let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.succeeded && !sha.isEmpty ? sha : nil
    }

    /// Makes each changed path match `commit`'s tree. Restored files come out
    /// of a throwaway index filled from `commit`, which `checkout-index` writes
    /// with the snapshot's mode, a batch of paths per call. Created files are
    /// deleted after that, so a git failure leaves them in place; only a
    /// created path in a restored file's way (a directory that replaced a
    /// snapshot file, or a file where a snapshot directory was) goes first.
    ///
    /// Returns the created paths it kept: ones the restored ignore files
    /// cover. "Created" was judged by the ignore rules as they are now, so a
    /// turn that dropped a `.gitignore` line would otherwise delete a file
    /// that predates it.
    @discardableResult
    private func restoreWorkingTree(_ changes: [TurnSnapshotChange], from commit: String, repositoryRoot: String) throws -> Set<String> {
        let root = URL(fileURLWithPath: repositoryRoot).standardizedFileURL
        let restored = changes.filter { $0.status != .added }.map(\.path)
        // `ls-files --others` names a nested repository as `dir/`. That is a
        // whole repository, not a file this rewind created, so it stays.
        let created = changes.filter { $0.status == .added && !$0.path.hasSuffix("/") }.map(\.path)
        let inTheWay = Self.createdPathsInTheWay(created: created, restored: restored)

        for path in created where inTheWay.contains(path) {
            try deleteCreatedFile(path, root: root)
        }

        // nil means delete every created path, as no ignore file changed back.
        var stillUntracked: Set<String>?
        if !restored.isEmpty {
            let tempIndex = FileManager.default.temporaryDirectory
                .appendingPathComponent("cortland-rewind-index-\(UUID().uuidString)")
            defer {
                try? FileManager.default.removeItem(at: tempIndex)
                try? FileManager.default.removeItem(atPath: tempIndex.path + ".lock")
            }
            let indexEnvironment = ["GIT_INDEX_FILE": tempIndex.path]
            try git(["read-tree", commit], repositoryRoot: repositoryRoot, environment: indexEnvironment)
            for start in stride(from: 0, to: restored.count, by: max(checkoutBatchSize, 1)) {
                let batch = Array(restored[start..<min(start + max(checkoutBatchSize, 1), restored.count)])
                try git(["checkout-index", "-f", "--"] + batch, repositoryRoot: repositoryRoot, environment: indexEnvironment)
            }
            // Ask again under the snapshot's ignore rules, now restored.
            let others = try git(
                ["ls-files", "-z", "--others", "--exclude-standard"],
                repositoryRoot: repositoryRoot,
                environment: indexEnvironment,
                trimmingOutput: false
            )
            stillUntracked = Set(others.split(separator: "\0").map(String.init))
        }

        var kept = Set<String>()
        for path in created where !inTheWay.contains(path) {
            if let stillUntracked, !stillUntracked.contains(path) {
                kept.insert(path)
                continue
            }
            try deleteCreatedFile(path, root: root)
        }
        return kept
    }

    /// Throws `restoreBlocked` when a path to restore, or a parent of it, is
    /// occupied by something deleting the created files would not clear.
    /// `checkout-index -f` would otherwise remove it, ignored files and all.
    private func checkRestoreIsUnblocked(_ changes: [TurnSnapshotChange], repositoryRoot: String) throws {
        let restored = changes.filter { $0.status != .added }.map(\.path)
        let created = changes.filter { $0.status == .added && !$0.path.hasSuffix("/") }.map(\.path)
        if let blocker = Self.restoreBlocker(restored: restored, created: created, repositoryRoot: repositoryRoot) {
            throw TurnSnapshotError.restoreBlocked(path: blocker.path, isDirectory: blocker.isDirectory)
        }
    }

    /// The first thing in the working tree that blocks restoring `restored`
    /// and is not among `created`: a non-directory where a parent directory
    /// goes back, or a directory where a file goes back that holds anything
    /// but created files. Reads the file system and changes nothing.
    static func restoreBlocker(
        restored: [String],
        created: [String],
        repositoryRoot: String
    ) -> (path: String, isDirectory: Bool)? {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: repositoryRoot).standardizedFileURL
        let createdSet = Set(created)
        var checked = Set<String>()
        for path in restored {
            let parts = path.split(separator: "/").map(String.init)
            for depth in parts.indices {
                let prefix = parts[...depth].joined(separator: "/")
                guard checked.insert(prefix).inserted else { continue }
                // attributesOfItem does not follow symlinks.
                guard let type = (try? fileManager.attributesOfItem(
                    atPath: root.appendingPathComponent(prefix).path
                ))?[.type] as? FileAttributeType else { break }
                let isDirectory = type == .typeDirectory
                if depth < parts.count - 1 {
                    guard !isDirectory else { continue }
                    if !createdSet.contains(prefix) { return (prefix, false) }
                    break
                }
                if isDirectory, !holdsOnlyCreatedFiles(prefix, created: createdSet, root: root) {
                    return (prefix, true)
                }
            }
        }
        return nil
    }

    /// Whether every non-directory inside `directory` is a created file, so
    /// deleting them leaves nothing but empty directories.
    private static func holdsOnlyCreatedFiles(_ directory: String, created: Set<String>, root: URL) -> Bool {
        // A path enumerator does not traverse symlinks to directories.
        guard let enumerator = FileManager.default.enumerator(atPath: root.appendingPathComponent(directory).path) else {
            return false
        }
        while let relative = enumerator.nextObject() as? String {
            if enumerator.fileAttributes?[.type] as? FileAttributeType == .typeDirectory { continue }
            if !created.contains(directory + "/" + relative) { return false }
        }
        return true
    }

    /// Created paths that block writing a restored one back: inside a restored
    /// path (a directory now stands where the snapshot had a file), or a
    /// parent of one (a file now stands where the snapshot had a directory).
    static func createdPathsInTheWay(created: [String], restored: [String]) -> Set<String> {
        let restoredSet = Set(restored)
        var restoredDirectories = Set<String>()
        for path in restored {
            var parts = path.split(separator: "/").dropLast()
            while !parts.isEmpty {
                restoredDirectories.insert(parts.joined(separator: "/"))
                parts = parts.dropLast()
            }
        }
        return Set(created.filter { path in
            if restoredDirectories.contains(path) { return true }
            var parts = path.split(separator: "/").dropLast()
            while !parts.isEmpty {
                if restoredSet.contains(parts.joined(separator: "/")) { return true }
                parts = parts.dropLast()
            }
            return false
        })
    }

    /// Deletes one created file, then each directory up to the root that it
    /// leaves empty.
    private func deleteCreatedFile(_ path: String, root: URL) throws {
        let fileManager = FileManager.default
        let url = root.appendingPathComponent(path)
        // attributesOfItem does not follow symlinks, so a dangling link counts.
        if (try? fileManager.attributesOfItem(atPath: url.path)) != nil {
            try fileManager.removeItem(at: url)
        }
        var directory = url.deletingLastPathComponent().standardizedFileURL
        while directory.path.count > root.path.count,
              directory.path.hasPrefix(root.path + "/"),
              let contents = try? fileManager.contentsOfDirectory(atPath: directory.path),
              contents.isEmpty {
            try fileManager.removeItem(at: directory)
            directory = directory.deletingLastPathComponent().standardizedFileURL
        }
    }

    /// Writes the working tree (tracked changes, staged and unstaged, plus
    /// untracked files that are not ignored) to a tree object through a
    /// temporary index, and returns the tree's id.
    private func writeWorkingTree(repositoryRoot: String) throws -> String {
        let indexPath = try realIndexPath(repositoryRoot: repositoryRoot)
        let tempIndex = FileManager.default.temporaryDirectory
            .appendingPathComponent("cortland-turn-index-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempIndex)
            try? FileManager.default.removeItem(atPath: tempIndex.path + ".lock")
        }
        // Seeding from the real index keeps `add -A` fast: unchanged files keep
        // their cached stat data and are not rehashed. A repo that never staged
        // anything has no index yet, and git builds the temp one from scratch.
        if FileManager.default.fileExists(atPath: indexPath) {
            try FileManager.default.copyItem(atPath: indexPath, toPath: tempIndex.path)
        }
        let indexEnvironment = ["GIT_INDEX_FILE": tempIndex.path]

        // The copy keeps skip-worktree and assume-unchanged bits, and `add -A`
        // skips those entries, so the tree would hold the index version instead
        // of the local edit. Clear them in the temp index only.
        let flagged = Self.skipOrAssumeUnchangedPaths(try git(
            ["ls-files", "-v", "-z"],
            repositoryRoot: repositoryRoot,
            environment: indexEnvironment,
            trimmingOutput: false
        ))
        // update-index applies only the first of these flags per call, so each
        // runs on its own; a path without that bit is left as it is.
        let batchSize = max(checkoutBatchSize, 1)
        for flag in ["--no-skip-worktree", "--no-assume-unchanged"] {
            for start in stride(from: 0, to: flagged.count, by: batchSize) {
                let batch = Array(flagged[start..<min(start + batchSize, flagged.count)])
                try git(["update-index", flag, "--"] + batch, repositoryRoot: repositoryRoot, environment: indexEnvironment)
            }
        }

        try git(["add", "-A"], repositoryRoot: repositoryRoot, environment: indexEnvironment)
        return try git(["write-tree"], repositoryRoot: repositoryRoot, environment: indexEnvironment)
    }

    /// HEAD's commit, or nil for a repository with no commits yet.
    private func currentHead(repositoryRoot: String) throws -> String? {
        let headResult = try runGit(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], repositoryRoot: repositoryRoot)
        let headSHA = headResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return headResult.succeeded && !headSHA.isEmpty ? headSHA : nil
    }

    /// Deletes the oldest snapshot refs beyond the newest `retainedCount`,
    /// across every pane in the repository. Internal for tests.
    func prune(repositoryRoot: String) throws {
        let snapshots = try list(repositoryRoot: repositoryRoot)
        for snapshot in Self.snapshotsToPrune(snapshots, keeping: Self.retainedCount) {
            try git(["update-ref", "-d", snapshot.refName, snapshot.commit], repositoryRoot: repositoryRoot)
        }
    }

    // MARK: - Pure helpers

    /// Paths from `git ls-files -v -z` output marked skip-worktree (`S`/`s`)
    /// or assume-unchanged (a lowercase tag).
    static func skipOrAssumeUnchangedPaths(_ lsFilesOutput: String) -> [String] {
        lsFilesOutput.split(separator: "\0").compactMap { entry in
            guard entry.count > 2, let tag = entry.first else { return nil }
            guard tag.isLowercase || tag == "S" else { return nil }
            return String(entry.dropFirst(2))
        }
    }

    static func refName(paneID: UUID, sequence: Int) -> String {
        refPrefix + paneID.uuidString.lowercased() + "/" + String(sequence)
    }

    /// Splits `refs/worktree/cortland/turns/<pane-uuid>/<sequence>` into its parts.
    static func parseRefName(_ refName: String) -> (paneID: UUID, sequence: Int)? {
        guard refName.hasPrefix(refPrefix) else { return nil }
        let parts = refName.dropFirst(refPrefix.count).split(separator: "/")
        guard parts.count == 2,
              let paneID = UUID(uuidString: String(parts[0])),
              let sequence = Int(parts[1]) else { return nil }
        return (paneID, sequence)
    }

    /// The commit message, with the metadata as git-style trailers.
    /// A session start adds `Cortland-Session-Start: true`; other snapshots
    /// carry no such line.
    static func commitMessage(paneID: UUID, sequence: Int, head: String?, createdAt: Date, isSessionStart: Bool = false) -> String {
        var message = """
        Cortland turn snapshot

        Cortland-Pane: \(paneID.uuidString.lowercased())
        Cortland-Sequence: \(sequence)
        Cortland-Head: \(head ?? "none")
        Cortland-Created: \(String(format: "%.6f", createdAt.timeIntervalSince1970))
        """
        if isSessionStart {
            message += "\nCortland-Session-Start: true"
        }
        return message
    }

    struct Metadata: Equatable {
        let paneID: UUID
        let sequence: Int
        let head: String?
        let createdAt: Date
        var isSessionStart = false
    }

    /// Reads the trailers `commitMessage` writes; nil when any required one is
    /// missing. The session start trailer is optional and defaults to false.
    static func parseMetadata(_ message: String) -> Metadata? {
        var fields: [String: String] = [:]
        for line in message.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        guard let paneID = fields["Cortland-Pane"].flatMap(UUID.init(uuidString:)),
              let sequence = fields["Cortland-Sequence"].flatMap({ Int($0) }),
              let head = fields["Cortland-Head"],
              let created = fields["Cortland-Created"].flatMap({ Double($0) }) else { return nil }
        return Metadata(
            paneID: paneID,
            sequence: sequence,
            head: head == "none" ? nil : head,
            createdAt: Date(timeIntervalSince1970: created),
            isSessionStart: fields["Cortland-Session-Start"] == "true"
        )
    }

    /// Parses `for-each-ref` output (fields split by 0x1F, records by 0x1E)
    /// into snapshots ordered oldest first. Refs outside the snapshot layout
    /// are skipped, as are snapshot refs whose commit lacks the metadata, so
    /// one malformed ref cannot stop every later snapshot in the repo.
    static func parseSnapshotList(_ output: String) -> [TurnSnapshot] {
        var snapshots: [TurnSnapshot] = []
        for record in output.split(separator: "\u{1E}") {
            let fields = record.split(separator: "\u{1F}", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            let refName = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsedRef = parseRefName(refName) else { continue }
            guard let metadata = parseMetadata(String(fields[2])) else { continue }
            snapshots.append(TurnSnapshot(
                paneID: parsedRef.paneID,
                sequence: parsedRef.sequence,
                refName: refName,
                commit: String(fields[1]),
                head: metadata.head,
                createdAt: metadata.createdAt,
                isSessionStart: metadata.isSessionStart
            ))
        }
        return snapshots.sorted {
            ($0.createdAt, $0.sequence) < ($1.createdAt, $1.sequence)
        }
    }

    /// The snapshot "This turn" compares against: the newest one `followedPane`
    /// took; when no pane is followed or it took none here, the newest taken
    /// by a pane in `tabPanes` (the changes pane's own tab); otherwise the
    /// newest in the repository, whichever pane took it. `snapshots` is oldest
    /// first, as `list` returns.
    static func turnSnapshot(in snapshots: [TurnSnapshot], followedPane: UUID? = nil, tabPanes: Set<UUID> = []) -> TurnSnapshot? {
        if let followedPane, let followed = snapshots.last(where: { $0.paneID == followedPane }) {
            return followed
        }
        if let inTab = snapshots.last(where: { tabPanes.contains($0.paneID) }) {
            return inTab
        }
        return snapshots.last
    }

    /// The snapshot "This session" compares against: the newest session start
    /// of the pane `turnSnapshot` picks, or that pane's oldest retained
    /// snapshot when its session start has been pruned.
    static func sessionSnapshot(in snapshots: [TurnSnapshot], followedPane: UUID? = nil, tabPanes: Set<UUID> = []) -> TurnSnapshot? {
        guard let turn = turnSnapshot(in: snapshots, followedPane: followedPane, tabPanes: tabPanes) else { return nil }
        let pane = snapshots.filter { $0.paneID == turn.paneID }
        return pane.last(where: \.isSessionStart) ?? pane.first
    }

    /// The snapshot a finished turn took when it started, when the changes
    /// pane should show that turn: the pane went to done from working or from
    /// ready (a turn can end straight from needs-input, such as a denied
    /// permission prompt), this turn asked for a snapshot at `turnStartedAt`,
    /// the pane's newest snapshot is that one (taken no earlier than the
    /// request, so never an earlier turn's), and the working tree differs
    /// from it. `paneSnapshots` is the
    /// pane's snapshots oldest first. `changeCount` is only asked once every
    /// other condition holds, so a caller can diff lazily.
    static func finishedTurnToShow(
        from previous: AgentState,
        to next: AgentState,
        turnStartedAt: Date?,
        paneSnapshots: [TurnSnapshot],
        changeCount: (TurnSnapshot) throws -> Int
    ) rethrows -> TurnSnapshot? {
        guard next == .done, previous == .working || previous == .ready,
              let snapshot = currentTurnSnapshot(turnStartedAt: turnStartedAt, paneSnapshots: paneSnapshots)
        else { return nil }
        return try changeCount(snapshot) > 0 ? snapshot : nil
    }

    /// The snapshot a pane's current turn took: the pane's newest snapshot,
    /// when the turn asked for one at `turnStartedAt` and that snapshot was
    /// taken no earlier, so never an earlier turn's. `paneSnapshots` is the
    /// pane's snapshots oldest first.
    static func currentTurnSnapshot(turnStartedAt: Date?, paneSnapshots: [TurnSnapshot]) -> TurnSnapshot? {
        guard let turnStartedAt,
              let snapshot = paneSnapshots.last,
              snapshot.createdAt >= turnStartedAt else { return nil }
        return snapshot
    }

    /// The oldest snapshots beyond the newest `keeping`.
    static func snapshotsToPrune(_ snapshots: [TurnSnapshot], keeping: Int) -> [TurnSnapshot] {
        let sorted = snapshots.sorted { ($0.createdAt, $0.sequence) < ($1.createdAt, $1.sequence) }
        return Array(sorted.dropLast(keeping))
    }

    // MARK: - Git

    /// Snapshot commits carry a fixed identity so they never fail on a machine
    /// without `user.name` / `user.email` configured.
    private static let identityEnvironment = [
        "GIT_AUTHOR_NAME": "Cortland",
        "GIT_AUTHOR_EMAIL": "cortland@localhost",
        "GIT_COMMITTER_NAME": "Cortland",
        "GIT_COMMITTER_EMAIL": "cortland@localhost"
    ]

    /// The real index, resolved through git so a linked worktree's per-worktree
    /// index is found.
    private func realIndexPath(repositoryRoot: String) throws -> String {
        let path = try git(["rev-parse", "--git-path", "index"], repositoryRoot: repositoryRoot)
        return path.hasPrefix("/") ? path : URL(fileURLWithPath: repositoryRoot).appendingPathComponent(path).path
    }

    /// Runs git and returns its stdout, throwing on a non-zero exit.
    @discardableResult
    private func git(
        _ arguments: [String],
        repositoryRoot: String,
        environment: [String: String] = [:],
        trimmingOutput: Bool = true
    ) throws -> String {
        let result = try runGit(arguments, repositoryRoot: repositoryRoot, environment: environment)
        guard result.succeeded else {
            throw TurnSnapshotError.gitFailed(command: arguments.first ?? "", stderr: result.stderr)
        }
        return trimmingOutput ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : result.stdout
    }

    /// GIT_OPTIONAL_LOCKS=0 so nothing here refreshes or locks the real index
    /// the agent is about to `git add` into.
    private func runGit(
        _ arguments: [String],
        repositoryRoot: String,
        environment: [String: String] = [:]
    ) throws -> ProcessResult {
        var env = environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        return try runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", repositoryRoot] + arguments,
            currentDirectoryURL: URL(fileURLWithPath: repositoryRoot),
            environment: env
        )
    }
}
