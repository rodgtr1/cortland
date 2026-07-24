import Foundation

/// One entry from `git worktree list --porcelain`. A pure value type so the
/// Worktrees panel and tests can reason over it without shelling out.
nonisolated struct GitWorktree: Equatable, Sendable {
    /// Absolute checkout path.
    let path: String
    /// Short branch name (`feature/x`), or nil when detached or bare.
    let branch: String?
    /// HEAD commit sha, when reported.
    let head: String?
    let isDetached: Bool
    let isLocked: Bool
    let isBare: Bool
}

/// Creates (or reuses) git worktrees so `cortland-ctl pane split --worktree
/// <branch>` can open a pane on an isolated checkout. Parallel coding agents
/// can then fan out without clobbering each other's working tree — the workflow
/// the bundled SKILL.md already asks agents to do by hand.
nonisolated struct WorktreeService: Sendable {
    enum WorktreeError: Error, Equatable {
        case notAGitRepository
        case noWorktreeForBranch(String)
        case gitFailed(String)
        /// The primary checkout has uncommitted changes, so a merge into it is
        /// refused up front — merging into a dirty tree is how work gets lost.
        case primaryHasUncommittedChanges
    }

    private let git: GitService

    init(git: GitService = GitService()) {
        self.git = git
    }

    /// Ensures a worktree for `branch` exists for the repository containing
    /// `directory`, and returns its absolute path. Idempotent: a branch that
    /// already has a worktree returns that worktree rather than failing, so a
    /// supervisor can re-issue the same split safely.
    func ensureWorktree(forBranch branch: String, directory: String) throws -> String {
        guard Self.isValidBranchName(branch) else {
            throw WorktreeError.gitFailed("invalid branch name: \(branch)")
        }
        guard let repoRoot = git.repositoryRoot(from: directory) else {
            throw WorktreeError.notAGitRepository
        }

        // Reuse an existing worktree for this branch if there is one.
        let listing = try git.run(repositoryRoot: repoRoot, arguments: ["worktree", "list", "--porcelain"])
        if listing.succeeded,
           let existing = Self.worktreePath(forBranch: branch, inPorcelain: listing.stdout) {
            return existing
        }

        let path = Self.worktreePath(forBranch: branch, repoRoot: repoRoot)
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // `-b` creates the branch; if it already exists (just without a
        // worktree), check it out into the new worktree instead.
        let exists = try git.run(
            repositoryRoot: repoRoot,
            arguments: ["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"]
        ).succeeded
        let arguments = exists
            ? ["worktree", "add", path, branch]
            : ["worktree", "add", "-b", branch, path]

        let result = try git.run(repositoryRoot: repoRoot, arguments: arguments)
        guard result.succeeded else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WorktreeError.gitFailed(message.isEmpty ? "git worktree add failed" : message)
        }

        // A fresh checkout omits gitignored files (`.env`, local caches), so
        // honour a `.worktreeinclude` at the repo root the same way `claude
        // --worktree` does — otherwise the same file works or doesn't depending
        // on whether Cortland or Claude Code created the worktree. Best-effort:
        // a copy failure must not fail the split.
        copyIncludedFiles(repoRoot: repoRoot, into: path)
        return path
    }

    /// Copies files named by a `.worktreeinclude` at the repo root into a freshly
    /// created worktree, matching Claude Code's behaviour. The file uses
    /// `.gitignore` syntax; a path is copied only when it matches an include
    /// pattern *and* is gitignored, so tracked files (already in the checkout)
    /// are never duplicated. Files are copied, not symlinked, so each worktree
    /// gets its own isolated copy.
    private func copyIncludedFiles(repoRoot: String, into worktreePath: String) {
        let includeFile = URL(fileURLWithPath: repoRoot).appendingPathComponent(".worktreeinclude").path
        guard FileManager.default.fileExists(atPath: includeFile) else { return }

        // Untracked files matching the include patterns. `--others` already drops
        // tracked files, so they can never be duplicated.
        let matched = untrackedFiles(repoRoot: repoRoot, excludeArgs: ["--exclude-from=\(includeFile)"])
        guard !matched.isEmpty else { return }

        // Intersect with everything git ignores so an included path is copied only
        // when it's also gitignored — CC's rule. Computing the intersection from
        // two `ls-files` runs keeps NUL-clean paths and avoids `check-ignore`,
        // whose `-z` output needs a stdin we can't feed through GitService.
        let gitignored = Set(untrackedFiles(repoRoot: repoRoot, excludeArgs: ["--exclude-standard"]))

        let sourceRoot = URL(fileURLWithPath: repoRoot)
        let destRoot = URL(fileURLWithPath: worktreePath)
        for relativePath in matched where gitignored.contains(relativePath) {
            let source = sourceRoot.appendingPathComponent(relativePath)
            let destination = destRoot.appendingPathComponent(relativePath)
            // Don't clobber anything `git worktree add` already wrote.
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            try? FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.copyItem(at: source, to: destination)
        }
    }

    /// Untracked files in `repoRoot` that the given exclude arguments mark as
    /// ignored, as repo-relative paths. `-z` keeps paths unquoted and
    /// NUL-separated so exotic names survive intact.
    private func untrackedFiles(repoRoot: String, excludeArgs: [String]) -> [String] {
        guard let result = try? git.run(
            repositoryRoot: repoRoot,
            arguments: ["ls-files", "-z", "--others", "--ignored"] + excludeArgs
        ), result.succeeded else { return [] }
        return result.stdout.components(separatedBy: "\0").filter { !$0.isEmpty }
    }

    /// Removes the worktree registered for `branch` in the repo containing
    /// `directory`, and returns the path it removed. Refuses a dirty or locked
    /// worktree unless `force` is set, so a teardown can't silently discard an
    /// agent's uncommitted work. A branch with no worktree throws
    /// `noWorktreeForBranch` rather than failing opaquely.
    func removeWorktree(forBranch branch: String, directory: String, force: Bool = false) throws -> String {
        guard Self.isValidBranchName(branch) else {
            throw WorktreeError.gitFailed("invalid branch name: \(branch)")
        }
        guard let repoRoot = git.repositoryRoot(from: directory) else {
            throw WorktreeError.notAGitRepository
        }

        let listing = try git.run(repositoryRoot: repoRoot, arguments: ["worktree", "list", "--porcelain"])
        guard listing.succeeded,
              let path = Self.worktreePath(forBranch: branch, inPorcelain: listing.stdout) else {
            throw WorktreeError.noWorktreeForBranch(branch)
        }

        var arguments = ["worktree", "remove"]
        if force { arguments.append("--force") }
        arguments.append(path)

        let result = try git.run(repositoryRoot: repoRoot, arguments: arguments)
        guard result.succeeded else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WorktreeError.gitFailed(message.isEmpty ? "git worktree remove failed" : message)
        }
        return path
    }

    /// Merges `branch` into the repository's primary checkout, run entirely in
    /// the primary root (never a linked worktree). Resolving the primary from
    /// `directory` means the caller can pass any path inside the repo family —
    /// including the worktree being merged. Guards:
    ///
    /// - Refuses when the primary tree is dirty (`git status --porcelain`
    ///   non-empty) with `.primaryHasUncommittedChanges`, before touching HEAD.
    /// - On a failed merge (conflicts), runs `git merge --abort` in the primary
    ///   root so it's left clean, then throws `.gitFailed` carrying git's output
    ///   so the user can resolve manually.
    func mergeBranch(_ branch: String, intoPrimaryFrom directory: String) throws {
        guard Self.isValidBranchName(branch) else {
            throw WorktreeError.gitFailed("invalid branch name: \(branch)")
        }
        guard let repoRoot = git.repositoryRoot(from: directory) else {
            throw WorktreeError.notAGitRepository
        }

        // The primary checkout is the first (non-bare) entry git lists; the
        // merge must land there even when `directory` is a linked worktree.
        let listing = try git.run(repositoryRoot: repoRoot, arguments: ["worktree", "list", "--porcelain"])
        guard listing.succeeded,
              let primaryRoot = Self.parseWorktrees(porcelain: listing.stdout).first(where: { !$0.isBare })?.path else {
            throw WorktreeError.notAGitRepository
        }

        let status = try git.run(repositoryRoot: primaryRoot, arguments: ["status", "--porcelain"])
        guard status.succeeded else {
            throw WorktreeError.gitFailed("unable to read status of the primary checkout")
        }
        guard status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorktreeError.primaryHasUncommittedChanges
        }

        let result = try git.run(repositoryRoot: primaryRoot, arguments: ["merge", branch])
        guard result.succeeded else {
            // Leave the primary tree clean: undo the half-applied merge so the
            // user isn't dropped into a conflicted main they didn't ask for.
            _ = try? git.run(repositoryRoot: primaryRoot, arguments: ["merge", "--abort"])
            let combined = (result.stdout + "\n" + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            throw WorktreeError.gitFailed(combined.isEmpty ? "git merge failed" : combined)
        }
    }

    /// Prunes stale worktree admin entries — bookkeeping for worktrees whose
    /// directories were deleted by hand — and returns git's summary (empty when
    /// there was nothing to prune).
    func pruneWorktrees(directory: String) throws -> String {
        guard let repoRoot = git.repositoryRoot(from: directory) else {
            throw WorktreeError.notAGitRepository
        }

        let result = try git.run(repositoryRoot: repoRoot, arguments: ["worktree", "prune", "-v"])
        guard result.succeeded else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WorktreeError.gitFailed(message.isEmpty ? "git worktree prune failed" : message)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every worktree registered for the repository containing `directory`, in
    /// git's own order (the primary checkout first). Returns an empty list when
    /// the directory isn't in a git repo or git fails, so the panel can render an
    /// empty state rather than throwing for the common "not a repo" case.
    func listWorktrees(repoRoot: String) throws -> [GitWorktree] {
        let result = try git.run(repositoryRoot: repoRoot, arguments: ["worktree", "list", "--porcelain"])
        guard result.succeeded else { return [] }
        return Self.parseWorktrees(porcelain: result.stdout)
    }

    /// Parses `git worktree list --porcelain` into records. Each record is a run
    /// of `key value` lines (`worktree`, `HEAD`, `branch`, `detached`, `bare`,
    /// `locked`) terminated by a blank line.
    static func parseWorktrees(porcelain output: String) -> [GitWorktree] {
        var worktrees: [GitWorktree] = []
        var path: String?
        var branch: String?
        var head: String?
        var isDetached = false
        var isLocked = false
        var isBare = false

        func flush() {
            if let path {
                worktrees.append(GitWorktree(
                    path: path, branch: branch, head: head,
                    isDetached: isDetached, isLocked: isLocked, isBare: isBare
                ))
            }
            path = nil; branch = nil; head = nil
            isDetached = false; isLocked = false; isBare = false
        }

        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("worktree ") {
                flush()   // start of a new record; emit the previous one
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("HEAD ") {
                head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
            } else if line == "detached" {
                isDetached = true
            } else if line == "bare" {
                isBare = true
            } else if line == "locked" || line.hasPrefix("locked ") {
                isLocked = true
            } else if line.isEmpty {
                flush()
            }
        }
        flush()   // last record may not be followed by a blank line
        return worktrees
    }

    /// Path for a new worktree: a sibling `<repo>.worktrees/<branch>` directory,
    /// keeping checkouts out of the main tree while staying easy to find. Branch
    /// separators become dashes so `feature/x` is one directory, not nested.
    static func worktreePath(forBranch branch: String, repoRoot: String) -> String {
        let repoURL = URL(fileURLWithPath: repoRoot)
        let container = repoURL.deletingLastPathComponent()
            .appendingPathComponent("\(repoURL.lastPathComponent).worktrees")
        return container.appendingPathComponent(sanitize(branch)).path
    }

    /// Finds the worktree registered for `branch` in `git worktree list
    /// --porcelain` output, or nil if the branch has no worktree.
    static func worktreePath(forBranch branch: String, inPorcelain output: String) -> String? {
        parseWorktrees(porcelain: output).first { $0.branch == branch }?.path
    }

    private static func sanitize(_ branch: String) -> String {
        branch.map { $0 == "/" ? "-" : $0 }.reduce(into: "") { $0.append($1) }
    }

    /// Rejects branch names unsafe to pass positionally to git or that would let
    /// `worktreePath` escape its container. The IPC layer validates branches it
    /// receives, but the Worktrees UI path doesn't go through it — so the
    /// service guards itself. Additionally bars `..` (the path-traversal vector)
    /// and the characters git itself forbids in a ref.
    static func isValidBranchName(_ branch: String) -> Bool {
        guard !branch.isEmpty, branch.count <= 255, !branch.hasPrefix("-") else { return false }
        if branch.hasPrefix("/") || branch.hasSuffix("/") || branch.contains("//") { return false }
        if branch.contains("..") { return false }
        let forbidden = branch.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar == " " || scalar == "\u{7F}" ||
            "~^:?*[\\".unicodeScalars.contains(scalar)
        }
        return !forbidden
    }
}
