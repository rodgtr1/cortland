import Foundation
import Cocoa

nonisolated enum GitFileStatus: String, CaseIterable, Sendable {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case unmerged = "U"
    case untracked = "?"
    case ignored = "!"
    case unmodified = " "

    var displayName: String {
        switch self {
        case .modified: return "Modified"
        case .added: return "Added"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        case .copied: return "Copied"
        case .unmerged: return "Conflict"
        case .untracked: return "Untracked"
        case .ignored: return "Ignored"
        case .unmodified: return ""
        }
    }

    // Reads the (main-actor) theme palette, so it stays main-isolated even
    // though the rest of the enum is nonisolated for background construction.
    @MainActor var color: NSColor {
        switch self {
        case .modified: return AppTheme.peach
        case .added: return AppTheme.success
        case .deleted: return AppTheme.error
        case .renamed: return AppTheme.accent
        case .copied: return AppTheme.accent
        case .unmerged: return AppTheme.warning
        case .untracked: return AppTheme.primaryText
        case .ignored: return AppTheme.mutedText
        case .unmodified: return AppTheme.primaryText
        }
    }
}

nonisolated struct GitFileItem: Sendable {
    let path: String
    let filename: String
    let stagedStatus: GitFileStatus
    let unstagedStatus: GitFileStatus
    let isStaged: Bool
    let isConflicted: Bool
    let isDirectory: Bool

    init(path: String, stagedChar: Character, unstagedChar: Character) {
        self.path = path
        self.filename = URL(fileURLWithPath: path).lastPathComponent
        self.stagedStatus = GitFileStatus(rawValue: String(stagedChar)) ?? .unmodified
        self.unstagedStatus = GitFileStatus(rawValue: String(unstagedChar)) ?? .unmodified
        self.isConflicted = GitStatusEntry(path: path, stagedStatus: stagedChar, unstagedStatus: unstagedChar).isConflicted
        // A conflicted file isn't "staged" in any useful sense; the action
        // that makes sense for it is Stage, which marks it resolved.
        self.isStaged = !isConflicted && stagedChar != " " && stagedChar != "?"
        // git porcelain reports an untracked *directory* with a trailing slash
        // (e.g. "build/"). Discarding such an entry removes the whole subtree, so
        // the UI must warn accordingly rather than treating it as a single file.
        self.isDirectory = path.hasSuffix("/")
    }

    var displayStatus: GitFileStatus {
        if isConflicted {
            return .unmerged
        }
        if stagedStatus != .unmodified {
            return stagedStatus
        }
        return unstagedStatus
    }
}

/// One committed file changed vs the default branch, for the git panel's
/// read-only "Changes vs <default>" review section. Unlike GitFileItem it
/// carries a single status (from `git diff --name-status`), no staged/unstaged
/// split — these rows are never staged from the panel.
nonisolated struct GitBranchDiffItem: Sendable {
    let path: String
    let filename: String
    let status: GitFileStatus

    init(path: String, status: Character) {
        self.path = path
        self.filename = URL(fileURLWithPath: path).lastPathComponent
        self.status = GitFileStatus(rawValue: String(status)) ?? .modified
    }
}

class GitStatusModel {
    /// Fired on the main actor after a batch of state changes settles (a status
    /// refresh, a repository switch, or a commit clearing the message). The git
    /// panel reads the properties below and repaints. A plain callback rather
    /// than Combine `@Published`, matching the app's dominant model→view idiom
    /// (`RepositoryWatcher.onChange`, `ConfigWatcher.onChange`). Set before use.
    var onChange: (() -> Void)?

    var files: [GitFileItem] = []
    /// Files committed on this branch vs the default branch (three-dot diff),
    /// shown in the panel's read-only "Changes vs <default>" section. Empty when
    /// HEAD is the default branch or detection failed.
    var branchDiffFiles: [GitBranchDiffItem] = []
    /// The default branch these committed changes are compared against (e.g.
    /// "main"), or empty when the section is hidden (HEAD is the default branch).
    var branchDiffBaseBranch: String = ""
    var currentBranch: String = ""
    var aheadCount: Int = 0
    var behindCount: Int = 0
    var isClean: Bool = true
    var commitMessage: String = ""
    var isLoading: Bool = false
    var error: String?

    private var _repositoryPath: String = ""
    // Fallback poll for changes FSEvents can't see (e.g. edits over NFS).
    private let fallbackRefreshInterval: TimeInterval = 30.0
    // How long to keep ignoring watcher events after an app-owned git mutation
    // finishes, so the mutation's own FSEvents (delivered up to the stream's
    // latency late) don't trigger a redundant refresh on top of the explicit one.
    private let watcherSettleDelay: TimeInterval = 0.6
    // Set on the main actor; torn down in the nonisolated deinit at end-of-life.
    nonisolated(unsafe) private var refreshTimer: Timer?
    // The app's shared FSEvents change detector — see RepositoryWatcher.
    private let watcher = RepositoryWatcher()
    private let gitService: GitService
    private var refreshGeneration: Int = 0
    // Coalesce overlapping refreshes: while a background git query is running, a
    // new request just sets `refreshAgainWhenDone` instead of spawning another
    // set of `git status`/`rev-list` processes whose results the generation guard
    // would only throw away. The trailing request runs once the current finishes.
    private var refreshInFlight = false
    private var refreshAgainWhenDone = false
    // Number of in-flight git mutations the app itself started. While > 0 (and
    // for a short settle window after), watcher-driven refreshes are suppressed:
    // those operations refresh explicitly when they finish, so reacting to their
    // `.git` writes is redundant work that lands on the main thread mid-typing.
    private var pendingMutationCount: Int = 0
    private var watcherSuppressed: Bool = false
    private var unsuppressWork: DispatchWorkItem?

    init(gitService: GitService = GitService()) {
        self.gitService = gitService
        // App-owned mutations (stage/commit/checkout/…) refresh themselves when
        // they complete; ignore the `.git` churn they generate in the meantime.
        watcher.onChange = { [weak self] in
            guard let self, !self.watcherSuppressed else { return }
            self.refreshStatus()
        }
    }

    var repositoryPath: String {
        return _repositoryPath
    }

    /// Notify the observing panel that the published state above changed. Called
    /// on the main actor at the end of each batch update.
    private func notifyChanged() {
        onChange?()
    }

    // Tear down the fallback timer directly: it's nonisolated(unsafe) so this
    // nonisolated deinit can reach it without hopping to the main actor (which a
    // deinit can't await). The FSEvents stream is owned by `watcher`, whose own
    // deinit stops it when this model releases its last reference.
    deinit {
        refreshTimer?.invalidate()
    }

    func setRepositoryPath(_ path: String) {
        // Every OSC7 cwd report re-asserts the path — i.e. once per command any
        // agent runs — so this runs on the main thread constantly. The memoized
        // lookup keeps a burst of reports from forking a `git rev-parse` each.
        guard let repositoryRoot = WorkspaceResolver.cachedGitRoot(from: path) else {
            stopAutoRefresh()
            refreshGeneration += 1
            _repositoryPath = ""
            currentBranch = ""
            aheadCount = 0
            behindCount = 0
            files = []
            branchDiffFiles = []
            branchDiffBaseBranch = ""
            isClean = true
            isLoading = false
            error = nil
            notifyChanged()
            return
        }

        // Same repository as before: the cwd only moved within it (the common
        // case, since a cd inside the repo re-reports the path). Forcing a
        // refresh and restarting the watcher here would rerun the whole status
        // chain on every command; the watcher and fallback poll already cover it.
        guard repositoryRoot != _repositoryPath else { return }

        _repositoryPath = repositoryRoot
        refreshStatus(force: true)
        startAutoRefresh()
        // In a linked worktree, HEAD/index live in the main repo's
        // .git/worktrees/<name> dir, not under the checkout root — watch both so
        // an agent's stages/commits fire the watcher, not just the fallback poll.
        var watchPaths = [repositoryRoot]
        if let gitDir = Self.linkedWorktreeGitDir(forRoot: repositoryRoot) {
            watchPaths.append(gitDir)
        }
        watcher.start(paths: watchPaths)
    }

    /// For a linked worktree whose root `.git` is a *file*, the resolved git
    /// directory it points at (`<mainrepo>/.git/worktrees/<name>`); nil for a
    /// normal repo whose `.git` is a directory. A relative pointer is resolved
    /// against the worktree root.
    private nonisolated static func linkedWorktreeGitDir(forRoot root: String) -> String? {
        let dotGit = URL(fileURLWithPath: root).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let contents = try? String(contentsOf: dotGit, encoding: .utf8),
              let pointer = RepositoryWatcher.gitdirPointer(fromGitFileContents: contents) else {
            return nil
        }
        if pointer.hasPrefix("/") { return pointer }
        return URL(fileURLWithPath: root).appendingPathComponent(pointer).standardizedFileURL.path
    }

    func refreshStatus(force: Bool = false) {
        guard !_repositoryPath.isEmpty else { return }
        guard force || !isLoading else { return }

        // A query is already running — fold this request into a single trailing
        // refresh instead of launching a second, redundant set of git processes.
        if refreshInFlight {
            refreshAgainWhenDone = true
            return
        }

        refreshInFlight = true
        isLoading = true
        error = nil
        refreshGeneration += 1
        let generation = refreshGeneration
        let repositoryPath = _repositoryPath

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let branch = self.getCurrentBranch(repositoryRoot: repositoryPath)
            let statusItems = self.getGitStatus(repositoryRoot: repositoryPath)
            let counts = self.getAheadBehindCounts(repositoryRoot: repositoryPath)
            let branchDiff = self.getBranchDiff(repositoryRoot: repositoryPath, currentBranch: branch)

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.refreshInFlight = false
                    defer {
                        // Service a request that arrived while this one was running.
                        if self.refreshAgainWhenDone {
                            self.refreshAgainWhenDone = false
                            self.refreshStatus(force: true)
                        }
                    }

                    guard self.refreshGeneration == generation,
                          self._repositoryPath == repositoryPath else { return }

                    self.currentBranch = branch
                    self.aheadCount = counts.ahead
                    self.behindCount = counts.behind
                    self.branchDiffBaseBranch = branchDiff.baseBranch
                    self.branchDiffFiles = branchDiff.files
                    // nil means the status query failed — keep the prior file
                    // list rather than clearing to a false "clean" state.
                    if let statusItems {
                        self.files = statusItems
                        self.isClean = statusItems.isEmpty
                    }
                    self.isLoading = false
                    self.notifyChanged()
                }
            }
        }
    }

    private func startAutoRefresh() {
        stopAutoRefresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: fallbackRefreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatus() }
        }
    }

    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        watcher.stop()
    }

    // These run on the background queue from refreshStatus. They touch only the
    // Sendable `gitService` (an immutable let) and their arguments, so they're
    // nonisolated; results are folded back into the observable state on the
    // main actor by the caller.
    private nonisolated func getCurrentBranch(repositoryRoot: String) -> String {
        do {
            return try gitService.currentBranch(repositoryRoot: repositoryRoot)
        } catch {
            return "unknown"
        }
    }

    private nonisolated func getAheadBehindCounts(repositoryRoot: String) -> (ahead: Int, behind: Int) {
        ((try? gitService.aheadBehindCounts(repositoryRoot: repositoryRoot)) ?? nil) ?? (ahead: 0, behind: 0)
    }

    /// Committed changes vs the default branch, for the panel's review section.
    /// Empty (and no base branch) when HEAD *is* the default branch, when the
    /// default can't be resolved, or when there are no such changes — those are
    /// all the "hide the section entirely" case.
    private nonisolated func getBranchDiff(
        repositoryRoot: String,
        currentBranch: String
    ) -> (baseBranch: String, files: [GitBranchDiffItem]) {
        // `try?` flattens the throwing Optional result to a single Optional.
        guard let baseBranch = try? gitService.defaultBranch(repositoryRoot: repositoryRoot),
              baseBranch != currentBranch else {
            return ("", [])
        }
        let entries = (try? gitService.changedFilesAgainstDefaultBranch(
            repositoryRoot: repositoryRoot, defaultBranch: baseBranch
        )) ?? []
        let items = entries
            .map { GitBranchDiffItem(path: $0.path, status: $0.status) }
            .sorted { $0.filename < $1.filename }
        return (items.isEmpty ? "" : baseBranch, items)
    }

    /// Returns nil on a git failure (distinct from an empty array, which means a
    /// genuinely clean tree) so the caller can keep the last-known file list
    /// instead of flashing the panel to "Working tree clean" on a transient error.
    private nonisolated func getGitStatus(repositoryRoot: String) -> [GitFileItem]? {
        do {
            return try gitService.status(repositoryRoot: repositoryRoot)
                .map { GitFileItem(path: $0.path, stagedChar: $0.stagedStatus, unstagedChar: $0.unstagedStatus) }
                .sorted { $0.filename < $1.filename }
        } catch {
            let message = error.localizedDescription
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.error = "Failed to get git status: \(message)" }
            }
        }

        return nil
    }

    // MARK: - Git Operations

    func stageFile(_ file: GitFileItem) {
        // `--` so a path beginning with "-" can't be parsed as a flag.
        executeGitCommand(["add", "--", file.path]) { [weak self] success in
            if success {
                self?.applyOptimisticStaging(to: file.path, staged: true)
                self?.refreshStatus(force: true)
            }
        }
    }

    func unstageFile(_ file: GitFileItem) {
        executeGitCommand(["reset", "HEAD", "--", file.path]) { [weak self] success in
            if success {
                self?.applyOptimisticStaging(to: file.path, staged: false)
                self?.refreshStatus(force: true)
            }
        }
    }

    /// Flips one row's staged/unstaged status the moment its `git add`/`git reset`
    /// returns, so the row's button reflects the new state immediately. The
    /// confirming refresh runs several git processes and may queue behind an
    /// in-flight one, which left the button stale for a second or more under load.
    /// It remains the source of truth: when it lands it overwrites this guess,
    /// including whatever subtlety (renames, partial adds) the guess got wrong.
    private func applyOptimisticStaging(to path: String, staged: Bool) {
        guard let index = files.firstIndex(where: { $0.path == path }) else { return }
        guard let chars = Self.optimisticStatusChars(for: files[index], staged: staged) else { return }

        files[index] = GitFileItem(path: path, stagedChar: chars.staged, unstagedChar: chars.unstaged)
        notifyChanged()
    }

    /// The porcelain status chars `file` takes on after a successful stage
    /// (`staged: true`) or unstage. Nil when the transition isn't worth guessing —
    /// a conflicted entry, whose two-char states staging resolves in ways only
    /// `git status` can report.
    nonisolated static func optimisticStatusChars(
        for file: GitFileItem,
        staged: Bool
    ) -> (staged: Character, unstaged: Character)? {
        guard !file.isConflicted else { return nil }

        if staged {
            // `git add` folds the worktree change into the index: untracked ("??")
            // becomes an add, a modify or delete keeps its letter in the staged
            // slot, and an already-clean worktree leaves the index as it was.
            let stagedChar: Character
            switch file.unstagedStatus {
            case .untracked: stagedChar = "A"
            case .unmodified: stagedChar = statusChar(file.stagedStatus)
            default: stagedChar = statusChar(file.unstagedStatus)
            }
            return (stagedChar, " ")
        }

        // `git reset HEAD` moves the index change back to the worktree. A staged
        // add returns to untracked, which porcelain reports in *both* slots
        // ("??"); anything else drops to its unstaged equivalent.
        if file.stagedStatus == .added {
            return ("?", "?")
        }
        let unstagedChar: Character
        switch file.stagedStatus {
        case .unmodified: unstagedChar = statusChar(file.unstagedStatus)
        default: unstagedChar = statusChar(file.stagedStatus)
        }
        return (" ", unstagedChar)
    }

    private nonisolated static func statusChar(_ status: GitFileStatus) -> Character {
        status.rawValue.first ?? " "
    }

    func stageAllFiles() {
        executeGitCommand(["add", "."]) { [weak self] success in
            if success {
                self?.refreshStatus(force: true)
            }
        }
    }

    func unstageAllFiles() {
        executeGitCommand(["reset", "HEAD"]) { [weak self] success in
            if success {
                self?.refreshStatus(force: true)
            }
        }
    }

    func commit(message: String, completion: @escaping @MainActor (Bool, String?) -> Void) {
        guard !message.isEmpty else {
            completion(false, "Commit message cannot be empty")
            return
        }

        executeGitCommand(["commit", "-m", message]) { [weak self] success in
            if success {
                self?.commitMessage = ""
                self?.notifyChanged()
                self?.refreshStatus(force: true)
                completion(true, nil)
            } else {
                completion(false, "Failed to commit changes")
            }
        }
    }

    func discardChanges(_ file: GitFileItem) {
        var command: [String]

        // Handle different file states
        if file.unstagedStatus == .untracked {
            // For untracked entries let git remove them. `git clean -fd` deletes
            // untracked files and directories but deliberately leaves nested git
            // repositories intact (removing those needs -ff) — unlike a blind
            // FileManager.removeItem, which would wipe a nested repo's contents
            // too. The trailing-slash path from porcelain works as a clean arg.
            executeGitCommand(["clean", "-fd", "--", file.path]) { [weak self] success in
                if success {
                    self?.refreshStatus(force: true)
                }
            }
            return
        } else if file.isStaged {
            // For staged files, restore from HEAD (discards both staged and unstaged changes)
            command = ["checkout", "HEAD", "--", file.path]
        } else {
            // For unstaged files, restore from index (discards unstaged changes only)
            command = ["checkout", "--", file.path]
        }

        executeGitCommand(command) { [weak self] success in
            if success {
                self?.refreshStatus(force: true)
            }
        }
    }

    func pull(completion: @escaping @MainActor (Bool, String?) -> Void) {
        executeGitCommandWithOutput(["pull"]) { [weak self] success, output, errorOutput in
            if success {
                self?.refreshStatus(force: true)
                completion(true, output)
            } else {
                completion(false, errorOutput ?? "Failed to pull changes")
            }
        }
    }

    func push(completion: @escaping @MainActor (Bool, String?) -> Void) {
        executeGitCommandWithOutput(["push"]) { [weak self] success, output, errorOutput in
            if success {
                self?.refreshStatus(force: true)
                completion(true, output)
            } else {
                completion(false, errorOutput ?? "Failed to push changes")
            }
        }
    }

    func fetch(completion: @escaping @MainActor (Bool, String?) -> Void) {
        executeGitCommandWithOutput(["fetch"]) { [weak self] success, output, errorOutput in
            if success {
                self?.refreshStatus(force: true)
                completion(true, output)
            } else {
                completion(false, errorOutput ?? "Failed to fetch changes")
            }
        }
    }

    private func executeGitCommand(_ arguments: [String], completion: @escaping @MainActor (Bool) -> Void) {
        let service = gitService
        let repoPath = _repositoryPath
        beginAppMutation()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let result = try service.run(repositoryRoot: repoPath, arguments: arguments)
                let success = result.succeeded
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.endAppMutation()
                        completion(success)
                    }
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.endAppMutation()
                        self?.error = "Failed to execute git command: \(message)"
                        completion(false)
                    }
                }
            }
        }
    }

    private func executeGitCommandWithOutput(_ arguments: [String], completion: @escaping @MainActor (Bool, String?, String?) -> Void) {
        let service = gitService
        let repoPath = _repositoryPath
        beginAppMutation()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let result = try service.run(repositoryRoot: repoPath, arguments: arguments)
                let success = result.succeeded

                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.endAppMutation()
                        completion(success, result.stdout, result.stderr)
                    }
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.endAppMutation()
                        self?.error = "Failed to execute git command: \(message)"
                        completion(false, nil, message)
                    }
                }
            }
        }
    }

    // MARK: - App-owned mutation suppression

    private func beginAppMutation() {
        pendingMutationCount += 1
        watcherSuppressed = true
        unsuppressWork?.cancel()
        unsuppressWork = nil
    }

    private func endAppMutation() {
        pendingMutationCount = max(0, pendingMutationCount - 1)
        guard pendingMutationCount == 0 else { return }
        // Keep suppressing briefly so trailing FSEvents from the finished
        // mutation are swallowed; the caller's explicit refresh covers the update.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.watcherSuppressed = false }
        }
        unsuppressWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + watcherSettleDelay, execute: work)
    }
}
