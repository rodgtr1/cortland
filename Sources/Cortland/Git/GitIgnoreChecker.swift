import Foundation

class GitIgnoreChecker {
    private let rootPath: String
    // Written on the main actor after the git load completes, read by isIgnored
    // on the file-tree background queue. Both accesses go through `stateLock`,
    // so the nonisolated(unsafe) opt-out is backed by real synchronization
    // (assigning a Set across threads without it is a data race / UB).
    private let stateLock = NSLock()
    private nonisolated(unsafe) var ignoredFiles: Set<String> = []
    private nonisolated(unsafe) var isLoaded = false
    private var isLoading = false
    private let queue = DispatchQueue(label: "app.cortland.gitignore", qos: .userInitiated)

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
        isLoading = true

        // The git invocation runs off-main and touches no instance state; the
        // result is folded back in on the main actor, so this MainActor class
        // never mutates from two threads.
        let root = rootPath
        queue.async {
            let loaded = Self.loadIgnoredFiles(rootPath: root)
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.stateLock.withLock {
                    if let loaded = loaded {
                        self.ignoredFiles = loaded
                    }
                    self.isLoaded = true
                }
                self.isLoading = false
                self.onLoadComplete?()
            }
        }
    }

    /// Runs `git ls-files` for ignored entries off the main actor. Returns the
    /// relative paths, or nil when git is unavailable / the dir isn't a repo.
    private nonisolated static func loadIgnoredFiles(rootPath: String) -> Set<String>? {
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