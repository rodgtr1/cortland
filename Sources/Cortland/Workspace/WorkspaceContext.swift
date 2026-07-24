import Foundation

nonisolated struct WorkspaceContext: Equatable, Sendable {
    let workingDirectory: String
    let repositoryRoot: String?

    var displayRoot: String {
        repositoryRoot ?? workingDirectory
    }

    init(workingDirectory: String, repositoryRoot: String? = nil) {
        self.workingDirectory = URL(fileURLWithPath: workingDirectory).standardizedFileURL.path
        self.repositoryRoot = repositoryRoot.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }

    func relativePath(for absolutePath: String) -> String {
        let absolute = URL(fileURLWithPath: absolutePath).standardizedFileURL.path
        let root = URL(fileURLWithPath: displayRoot).standardizedFileURL.path

        guard absolute == root || absolute.hasPrefix(root + "/") else {
            return absolute
        }

        if absolute == root {
            return URL(fileURLWithPath: absolute).lastPathComponent
        }

        return String(absolute.dropFirst(root.count + 1))
    }

    func absolutePath(forRepoPath path: String) -> String {
        let root = repositoryRoot ?? workingDirectory
        guard !path.hasPrefix("/") else { return URL(fileURLWithPath: path).standardizedFileURL.path }
        return URL(fileURLWithPath: root).appendingPathComponent(path).standardizedFileURL.path
    }
}

nonisolated enum WorkspaceResolver {
    static func gitRoot(from path: String, runner: ProcessRunning = ProcessRunner.shared) -> String? {
        do {
            let result = try runner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["-C", path, "rev-parse", "--show-toplevel"]
            )

            guard result.succeeded else { return nil }
            let root = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return root.isEmpty ? nil : URL(fileURLWithPath: root).standardizedFileURL.path
        } catch {
            return nil
        }
    }

    static func context(for path: String, runner: ProcessRunning = ProcessRunner.shared) -> WorkspaceContext {
        WorkspaceContext(
            workingDirectory: path,
            repositoryRoot: gitRoot(from: path, runner: runner)
        )
    }

    // MARK: - Cached lookups

    // Short-TTL memoization for the repeated, main-thread repo-root lookups (the
    // worktrees panel re-asks for the active repo root on every refresh). Guarded
    // by `cacheLock`; `gitRoot(from:runner:)` itself stays pure so the
    // injected-runner unit tests are unaffected. A repo created/removed under a
    // path is picked up after the TTL — fine for a UI hint.
    nonisolated(unsafe) private static var rootCache: [String: (root: String?, at: Date)] = [:]
    private static let cacheLock = NSLock()
    private static let cacheTTL: TimeInterval = 3

    /// `context(for:)` using the memoized repo-root lookup — for the main-thread
    /// UI sites (file tree, git panel) that rebuild a context on every tab
    /// switch or row click and would otherwise fork `git rev-parse` each time.
    static func cachedContext(for path: String) -> WorkspaceContext {
        WorkspaceContext(
            workingDirectory: path,
            repositoryRoot: cachedGitRoot(from: path)
        )
    }

    /// The root of the *linked* git worktree containing `path`, or nil when
    /// `path` is in the primary checkout, outside any repo, or unresolvable.
    ///
    /// A linked worktree (created by `git worktree add`) has a `.git` *file* at
    /// its root pointing into the primary repo's git dir; the primary checkout
    /// has a `.git` *directory*. Only linked worktrees are eligible for
    /// worktree-scoped auto-approve — the primary checkout stays protected, so
    /// enabling the feature never turns off prompting for the main repo. Uses
    /// the memoized root lookup since it runs on the per-edit approval path.
    static func linkedWorktreeRoot(from path: String) -> String? {
        guard let root = cachedGitRoot(from: path) else { return nil }
        let dotGit = URL(fileURLWithPath: root).appendingPathComponent(".git").path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) else { return nil }
        return isDirectory.boolValue ? nil : root
    }

    /// `gitRoot(from:)` against the shared runner, memoized for `cacheTTL` so a
    /// burst of identical lookups on the main thread spawns at most one `git`.
    static func cachedGitRoot(from path: String) -> String? {
        let now = Date()
        cacheLock.lock()
        if let entry = rootCache[path], now.timeIntervalSince(entry.at) < cacheTTL {
            cacheLock.unlock()
            return entry.root
        }
        cacheLock.unlock()

        let root = gitRoot(from: path)
        cacheLock.lock()
        rootCache[path] = (root, now)
        cacheLock.unlock()
        return root
    }
}
