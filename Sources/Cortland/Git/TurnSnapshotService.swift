import Foundation

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

nonisolated enum TurnSnapshotError: Error {
    case gitFailed(command: String, stderr: String)
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

    private let runner: ProcessRunning
    private let gitService: GitService

    init(runner: ProcessRunning = ProcessRunner.shared) {
        self.runner = runner
        self.gitService = GitService(runner: runner)
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
    /// the repository's snapshots to the newest `retainedCount`.
    func takeSnapshot(paneID: UUID, repositoryRoot: String, isSessionStart: Bool = false) throws -> TurnSnapshot {
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

        try git(["add", "-A"], repositoryRoot: repositoryRoot, environment: indexEnvironment)
        let tree = try git(["write-tree"], repositoryRoot: repositoryRoot, environment: indexEnvironment)

        let headResult = try runGit(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], repositoryRoot: repositoryRoot)
        let headSHA = headResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = headResult.succeeded && !headSHA.isEmpty ? headSHA : nil

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
            ["diff", "--no-renames", "--name-status"],
            repositoryRoot: repositoryRoot,
            environment: indexEnvironment,
            trimmingOutput: false
        )
        let patches = GitService.splitDiffByFile(try git(
            ["diff", "--no-renames"],
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

    /// Deletes the oldest snapshot refs beyond the newest `retainedCount`,
    /// across every pane in the repository.
    private func prune(repositoryRoot: String) throws {
        let snapshots = try list(repositoryRoot: repositoryRoot)
        for snapshot in Self.snapshotsToPrune(snapshots, keeping: Self.retainedCount) {
            try git(["update-ref", "-d", snapshot.refName, snapshot.commit], repositoryRoot: repositoryRoot)
        }
    }

    // MARK: - Pure helpers

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

    /// The snapshot "This turn" compares against: the newest in the repository,
    /// whichever pane took it. `snapshots` is oldest first, as `list` returns.
    static func turnSnapshot(in snapshots: [TurnSnapshot]) -> TurnSnapshot? {
        snapshots.last
    }

    /// The snapshot "This session" compares against: the newest session start
    /// of the pane that took the newest snapshot, or that pane's oldest
    /// retained snapshot when its session start has been pruned.
    static func sessionSnapshot(in snapshots: [TurnSnapshot]) -> TurnSnapshot? {
        guard let turn = turnSnapshot(in: snapshots) else { return nil }
        let pane = snapshots.filter { $0.paneID == turn.paneID }
        return pane.last(where: \.isSessionStart) ?? pane.first
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
