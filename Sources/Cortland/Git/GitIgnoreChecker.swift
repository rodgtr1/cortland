import Foundation

class GitIgnoreChecker {
    let rootPath: String
    // Written on the main actor after the git load completes, read by isIgnored
    // on the file-tree background queue. Both accesses go through `stateLock`,
    // so the nonisolated(unsafe) opt-out is backed by real synchronization
    // (assigning a Set across threads without it is a data race / UB).
    private let stateLock = NSLock()
    private nonisolated(unsafe) var ignoredFiles: Set<String> = []
    private nonisolated(unsafe) var isLoaded = false
    private var isLoading = false
    // A reload asked for while a load runs: one more load follows it, and
    // these completions are answered by that one.
    private var reloadPending = false
    private var pendingCompletions: [(Bool) -> Void] = []
    // Answered when the running load lands; kept here rather than captured
    // by the background closure, which must stay Sendable.
    private var inFlightCompletions: [(Bool) -> Void] = []
    private let queue = DispatchQueue(label: "app.cortland.gitignore", qos: .userInitiated)

    /// Fired when a load lands and changed the answers: always for the first
    /// load, and after a reload only when the ignored set differs.
    var onLoadComplete: (() -> Void)?

    init(rootPath: String) {
        self.rootPath = rootPath
        // Don't load synchronously in init - start async load
        startLoadingIgnoredFiles()
    }

    nonisolated func isIgnored(path: String) -> Bool {
        // Convert to relative path from root
        let relativePath = path.hasPrefix(rootPath)
            ? String(path.dropFirst(rootPath.count + 1))
            : path

        stateLock.lock()
        defer { stateLock.unlock() }
        // Return false if not loaded yet - we'll refresh the UI when loading completes
        guard isLoaded else { return false }
        if ignoredFiles.contains(relativePath) { return true }
        // `git ls-files --directory` collapses a wholly-ignored directory into a
        // single entry with a trailing slash (e.g. "node_modules/") rather than
        // listing every file beneath it. So a path is ignored if it *is* such a
        // directory, or lives under one — walk its ancestors to catch the latter.
        if ignoredFiles.contains(relativePath + "/") { return true }
        var prefix = ""
        for component in relativePath.split(separator: "/").dropLast() {
            prefix += component + "/"
            if ignoredFiles.contains(prefix) { return true }
        }
        return false
    }

    private func startLoadingIgnoredFiles() {
        stateLock.lock()
        let alreadyLoaded = isLoaded
        stateLock.unlock()
        guard !isLoading && !alreadyLoaded else { return }
        runLoad()
    }

    /// Re-reads the ignored set in the background. The set already loaded
    /// keeps answering `isIgnored` until the new one is swapped in.
    /// `completion` gets whether the answers changed. A reload asked for while
    /// a load runs queues exactly one more load after it.
    func reload(completion: ((Bool) -> Void)? = nil) {
        if let completion { pendingCompletions.append(completion) }
        guard !isLoading else {
            reloadPending = true
            return
        }
        runLoad()
    }

    private func runLoad() {
        isLoading = true
        inFlightCompletions = pendingCompletions
        pendingCompletions = []

        // The git invocation runs off-main and touches no instance state; the
        // result is folded back in on the main actor, so this MainActor class
        // never mutates from two threads.
        let root = rootPath
        queue.async {
            let loaded = Self.loadIgnoredFiles(rootPath: root)
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let changed = self.stateLock.withLock {
                    // The first load always counts as a change: until it, every
                    // path read as not ignored.
                    var changed = !self.isLoaded
                    if let loaded = loaded, loaded != self.ignoredFiles {
                        self.ignoredFiles = loaded
                        changed = true
                    }
                    self.isLoaded = true
                    return changed
                }
                self.isLoading = false
                let completions = self.inFlightCompletions
                self.inFlightCompletions = []
                if changed { self.onLoadComplete?() }
                completions.forEach { $0(changed) }
                if self.reloadPending {
                    self.reloadPending = false
                    self.reload()
                }
            }
        }
    }

    /// Runs `git ls-files` for ignored entries off the main actor. Returns the
    /// relative paths, or nil when git is unavailable / the dir isn't a repo.
    nonisolated static func loadIgnoredFiles(rootPath: String) -> Set<String>? {
        // Via the shared runner: it drains both stdout and stderr on separate
        // queues (so a repo whose git writes >64KB to stderr can't deadlock the
        // child, which the old hand-rolled version risked), and adds a timeout.
        guard let result = try? ProcessRunner.shared.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", rootPath, "ls-files", "--ignored", "--exclude-standard", "--others", "--directory"],
            currentDirectoryURL: URL(fileURLWithPath: rootPath)
        ), result.succeeded else {
            // Git not available or not a git repo: ignore silently.
            return nil
        }
        return Set(result.stdout.split(separator: "\n").map(String.init))
    }
}