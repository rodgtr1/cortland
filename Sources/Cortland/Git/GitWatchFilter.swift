import Foundation
import os

/// Path decisions for the `RepositoryWatcher` filters: which file events can
/// change what a consumer reads from git. Pure, so the stream callback can ask
/// on the main actor, and tests can ask without a stream.
nonisolated enum GitWatchFilter {
    enum StatusDecision: Equatable, Sendable {
        case drop
        case pass
        /// Relevant, and the ignored-directory list may now be stale.
        case passAndReloadIgnores
    }

    /// Whether an event under `gitDir` can change a pane's branch label.
    /// Checkout, `switch -c`, a detached commit, and every rebase step rewrite
    /// `HEAD`; a commit on a branch writes only its ref, which leaves the label
    /// alone. A reftable repository keeps refs (HEAD included) in `reftable/`
    /// and never rewrites the `HEAD` stub, so that directory counts too.
    static func isBranchEvent(_ path: String, gitDir: String) -> Bool {
        path == gitDir + "/HEAD" || path.hasPrefix(gitDir + "/reftable/")
    }

    /// Whether an event under `root` (or a linked worktree's `linkedGitDir`)
    /// can change what `git status` and the diffs report.
    static func statusDecision(
        path: String,
        root: String,
        linkedGitDir: String?,
        isUnderIgnoredDirectory: (String) -> Bool
    ) -> StatusDecision {
        // Git reads these to decide what is ignored, so a change can reveal
        // or hide files and makes the cached directory list stale.
        if path.hasPrefix(root + "/"), (path as NSString).lastPathComponent == ".gitignore" {
            return .passAndReloadIgnores
        }
        var gitDirs = [root + "/.git"]
        if let linkedGitDir { gitDirs.append(linkedGitDir) }
        for gitDir in gitDirs {
            if path == gitDir + "/info/exclude" { return .passAndReloadIgnores }
            // Object writes and reflogs follow some other write (a ref, the
            // index) that already reports the change.
            for name in ["objects", "logs"] {
                let directory = gitDir + "/" + name
                if path == directory || path.hasPrefix(directory + "/") { return .drop }
            }
        }
        return isUnderIgnoredDirectory(path) ? .drop : .pass
    }

    /// The filter the git panel and the changes pane give their watchers, and
    /// the hook for each firing. Both hold a subscription to `root`'s ignored
    /// directories for as long as the watcher keeps them. A firing reloads a
    /// list older than `IgnoredDirectoryCache.staleAfter`, so a directory that
    /// appears ignored after the first load (a first build's `.build/`) is
    /// learned from its first burst rather than never.
    static func statusFilter(
        root: String,
        linkedGitDir: String?,
        cache: IgnoredDirectoryCache = .shared
    ) -> (filter: (String) -> Bool, onFire: () -> Void) {
        let ignores = cache.subscribe(root: root)
        let filter: (String) -> Bool = { path in
            switch statusDecision(
                path: path, root: root, linkedGitDir: linkedGitDir,
                isUnderIgnoredDirectory: ignores.isUnderIgnoredDirectory
            ) {
            case .drop:
                return false
            case .pass:
                return true
            case .passAndReloadIgnores:
                ignores.reload()
                return true
            }
        }
        return (filter, { ignores.reloadIfStale() })
    }
}

/// Each watched repository's untracked ignored directories (the collapsed
/// `git ls-files --directory` entries, such as `node_modules/`), loaded in the
/// background and answered from memory. Entries live while some subscription
/// for their root does: the last one released drops the entry.
///
/// Sendable through `OSAllocatedUnfairLock`, which guards all mutable state.
nonisolated final class IgnoredDirectoryCache: Sendable {
    static let shared = IgnoredDirectoryCache()
    /// How old a completed load may be before a firing reloads it.
    static let staleAfter: TimeInterval = 10

    private struct Entry: Sendable {
        let id = UUID()
        var users = 0
        /// Relative paths with a trailing slash; nil until the first load lands.
        var directories: Set<String>?
        var isLoading = false
        var reloadPending = false
        /// When the last load completed; nil until the first does.
        var loadedAt: Date?
    }

    private let entries = OSAllocatedUnfairLock(initialState: [String: Entry]())
    private let loader: @Sendable (String) -> Set<String>?
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "app.cortland.ignored-directories", qos: .utility)

    /// `loader` lists a root's ignored entries and `now` is the clock; tests
    /// swap them to control timing.
    init(
        loader: @escaping @Sendable (String) -> Set<String>? = { GitIgnoreChecker.loadIgnoredFiles(rootPath: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.loader = loader
        self.now = now
    }

    /// Keeps `root`'s entry alive until the returned subscription is released,
    /// loading it the first time.
    func subscribe(root: String) -> Subscription {
        let loadID: UUID? = entries.withLock { entries in
            if entries[root] != nil {
                entries[root]?.users += 1
                return nil
            }
            var entry = Entry()
            entry.users = 1
            entry.isLoading = true
            entries[root] = entry
            return entry.id
        }
        if let loadID { load(root: root, id: loadID) }
        return Subscription(root: root, cache: self)
    }

    /// Whether `path` lies under an ignored directory of `root`. False until
    /// the first load lands.
    func isUnderIgnoredDirectory(_ path: String, root: String) -> Bool {
        guard path.hasPrefix(root + "/"),
              let directories = entries.withLock({ $0[root]?.directories }),
              !directories.isEmpty else { return false }
        var prefix = ""
        for component in path.dropFirst(root.count + 1).split(separator: "/") {
            prefix += component + "/"
            if directories.contains(prefix) { return true }
        }
        return false
    }

    /// Re-reads `root`'s list. The current list answers until the new one
    /// lands; a reload asked for mid-load runs once more after it.
    func reload(root: String) {
        let loadID: UUID? = entries.withLock { entries in
            guard var entry = entries[root] else { return nil }
            defer { entries[root] = entry }
            if entry.isLoading {
                entry.reloadPending = true
                return nil
            }
            entry.isLoading = true
            return entry.id
        }
        if let loadID { load(root: root, id: loadID) }
    }

    /// Reloads `root`'s list if no load is running and the last one completed
    /// at least `staleAfter` ago. Called when a filtered watcher fires.
    func reloadIfStale(root: String) {
        let time = now()
        let loadID: UUID? = entries.withLock { entries in
            guard var entry = entries[root], !entry.isLoading,
                  let loadedAt = entry.loadedAt,
                  time.timeIntervalSince(loadedAt) >= Self.staleAfter else { return nil }
            entry.isLoading = true
            entries[root] = entry
            return entry.id
        }
        if let loadID { load(root: root, id: loadID) }
    }

    /// Whether `root` has an entry whose first load has landed.
    func isLoaded(root: String) -> Bool {
        entries.withLock { $0[root]?.directories != nil }
    }

    private func release(root: String) {
        entries.withLock { entries in
            guard var entry = entries[root] else { return }
            entry.users -= 1
            entries[root] = entry.users > 0 ? entry : nil
        }
    }

    private func load(root: String, id: UUID) {
        queue.async { [self] in
            let loaded = loader(root)
            let again = entries.withLock { entries -> Bool in
                // Released (or released and resubscribed) while loading.
                guard var entry = entries[root], entry.id == id else { return false }
                defer { entries[root] = entry }
                // A failed load forgets the old list rather than keep hiding
                // directories that may no longer be ignored.
                entry.directories = Set((loaded ?? []).filter { $0.hasSuffix("/") })
                entry.loadedAt = now()
                if entry.reloadPending {
                    entry.reloadPending = false
                    return true
                }
                entry.isLoading = false
                return false
            }
            if again { load(root: root, id: id) }
        }
    }

    /// One user's hold on a root's entry, released when this is deallocated.
    nonisolated final class Subscription: Sendable {
        let root: String
        private let cache: IgnoredDirectoryCache

        fileprivate init(root: String, cache: IgnoredDirectoryCache) {
            self.root = root
            self.cache = cache
        }

        deinit { cache.release(root: root) }

        func isUnderIgnoredDirectory(_ path: String) -> Bool {
            cache.isUnderIgnoredDirectory(path, root: root)
        }

        func reload() { cache.reload(root: root) }

        func reloadIfStale() { cache.reloadIfStale(root: root) }
    }
}
