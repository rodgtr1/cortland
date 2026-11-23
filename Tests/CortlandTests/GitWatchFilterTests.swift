import XCTest
import CoreServices
import os
@testable import Cortland

/// The watcher filters that keep file-change bursts from spawning git: which
/// paths count, the minimum interval between firings, and the shared
/// ignored-directory cache.
@MainActor
final class GitWatchFilterTests: XCTestCase {
    private var repo: String!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("git-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // FSEvents and git report the real path (/private/var, not /var).
        repo = try XCTUnwrap(realpath(dir.path, nil).map { path in
            defer { free(path) }
            return String(cString: path)
        })
    }

    override func tearDownWithError() throws {
        if let repo { try? FileManager.default.removeItem(atPath: repo) }
    }

    // MARK: - Helpers

    @discardableResult
    private func git(_ arguments: String...) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo, "-c", "user.name=t", "-c", "user.email=t@t"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func write(_ relative: String, _ contents: String) throws {
        let url = URL(fileURLWithPath: repo).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: false, encoding: .utf8)
    }

    /// A repo with an ignored `node_modules/` and a committed `tracked.txt`.
    private func makeRepo() throws {
        XCTAssertEqual(try git("init", "-q", "-b", "main"), 0)
        try write(".gitignore", "node_modules/\n")
        try write("tracked.txt", "one\n")
        try write("node_modules/pkg/index.js", "x\n")
        XCTAssertEqual(try git("add", ".gitignore", "tracked.txt"), 0)
        XCTAssertEqual(try git("commit", "-q", "-m", "init"), 0)
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private func pump(until condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        return condition()
    }

    // MARK: - Branch filter

    func testBranchFilterPassesOnlyHeadForNormalAndLinkedLayouts() {
        for gitDir in ["/r/.git", "/main/.git/worktrees/feature"] {
            XCTAssertTrue(GitWatchFilter.isBranchEvent(gitDir + "/HEAD", gitDir: gitDir))
            XCTAssertFalse(GitWatchFilter.isBranchEvent(gitDir + "/index", gitDir: gitDir))
            XCTAssertFalse(GitWatchFilter.isBranchEvent(gitDir + "/HEAD.lock", gitDir: gitDir))
            XCTAssertFalse(GitWatchFilter.isBranchEvent(gitDir + "/ORIG_HEAD", gitDir: gitDir))
            XCTAssertFalse(GitWatchFilter.isBranchEvent(gitDir + "/refs/heads/main", gitDir: gitDir))
            XCTAssertFalse(GitWatchFilter.isBranchEvent(gitDir + "/logs/HEAD", gitDir: gitDir))
        }
        XCTAssertFalse(GitWatchFilter.isBranchEvent("/r/src/HEAD", gitDir: "/r/.git"))
        XCTAssertFalse(GitWatchFilter.isBranchEvent("/r/main.swift", gitDir: "/r/.git"))
    }

    // MARK: - Status filter

    private func decision(_ path: String, root: String = "/r", linked: String? = nil) -> GitWatchFilter.StatusDecision {
        GitWatchFilter.statusDecision(
            path: path, root: root, linkedGitDir: linked,
            isUnderIgnoredDirectory: { $0.hasPrefix(root + "/node_modules/") }
        )
    }

    func testStatusFilterNormalLayout() {
        XCTAssertEqual(decision("/r/.git/objects/ab/cdef"), .drop)
        XCTAssertEqual(decision("/r/.git/objects"), .drop)
        XCTAssertEqual(decision("/r/.git/logs/HEAD"), .drop)
        XCTAssertEqual(decision("/r/.git/logs/refs/heads/main"), .drop)
        for kept in ["index", "HEAD", "refs/heads/main", "MERGE_HEAD", "rebase-merge/done", "packed-refs"] {
            XCTAssertEqual(decision("/r/.git/" + kept), .pass, kept)
        }
        XCTAssertEqual(decision("/r/node_modules/pkg/index.js"), .drop)
        XCTAssertEqual(decision("/r/node_modules_tracked.txt"), .pass)
        XCTAssertEqual(decision("/r/src/main.swift"), .pass)
        XCTAssertEqual(decision("/r/.gitignore"), .passAndReloadIgnores)
        XCTAssertEqual(decision("/r/src/.gitignore"), .passAndReloadIgnores)
        XCTAssertEqual(decision("/r/.git/info/exclude"), .passAndReloadIgnores)
    }

    func testStatusFilterLinkedWorktreeLayout() {
        let linked = "/main/.git/worktrees/wt"
        XCTAssertEqual(decision(linked + "/logs/HEAD", root: "/wt", linked: linked), .drop)
        XCTAssertEqual(decision(linked + "/objects/ab/cd", root: "/wt", linked: linked), .drop)
        for kept in ["index", "HEAD", "refs/worktree/snap", "MERGE_HEAD"] {
            XCTAssertEqual(decision(linked + "/" + kept, root: "/wt", linked: linked), .pass, kept)
        }
        XCTAssertEqual(decision(linked + "/info/exclude", root: "/wt", linked: linked), .passAndReloadIgnores)
        XCTAssertEqual(decision("/wt/node_modules/a.js", root: "/wt", linked: linked), .drop)
        XCTAssertEqual(decision("/wt/tracked.txt", root: "/wt", linked: linked), .pass)
        XCTAssertEqual(decision("/wt/.gitignore", root: "/wt", linked: linked), .passAndReloadIgnores)
    }

    // MARK: - Watcher

    // Asserts on the gaps between firings, not on how many land inside a
    // wall-clock window: a slow runner stretches the burst past the window.
    func testMinimumIntervalYieldsOneLeadingAndOneTrailingFiring() {
        let interval = 0.6
        let watcher = RepositoryWatcher(debounce: 0.05, latency: 0.05, minimumInterval: interval)
        var fired: [Date] = []
        watcher.onChange = { fired.append(Date()) }

        watcher.scheduleDebounced()
        XCTAssertTrue(pump(until: { fired.count == 1 }, timeout: 2.0), "leading firing")
        for _ in 0..<5 {
            watcher.scheduleDebounced()
            pump(0.05)
        }
        // Long enough for the burst's trailing firing whenever the burst ended.
        pump(interval + 0.4)
        XCTAssertGreaterThanOrEqual(fired.count, 2, "the burst yields a trailing firing")
        for (earlier, later) in zip(fired, fired.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later.timeIntervalSince(earlier), interval - 0.05)
        }
        let settled = fired.count
        pump(0.3)
        XCTAssertEqual(fired.count, settled, "nothing fires once the burst is over")
    }

    func testFilteredEventsScheduleOnlyForRelevantPathsOrRescans() {
        let watcher = RepositoryWatcher(debounce: 0.02, latency: 0.05)
        var count = 0
        watcher.onChange = { count += 1 }
        watcher.start(paths: [repo], filter: { $0.hasSuffix("/keep") })

        watcher.handleEvents(paths: [repo + "/drop"], flags: [0])
        pump(0.1)
        XCTAssertEqual(count, 0)

        watcher.handleEvents(paths: [repo + "/drop", repo + "/keep"], flags: [0, 0])
        XCTAssertTrue(pump(until: { count == 1 }, timeout: 0.5))

        let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        watcher.handleEvents(paths: [repo + "/drop"], flags: [rescan])
        XCTAssertTrue(pump(until: { count == 2 }, timeout: 0.5))
        watcher.stop()
    }

    /// Real FSEvents: a write under an ignored directory does not fire the git
    /// panel's filtered watcher, and a write to a tracked file does.
    func testIgnoredWritesDoNotFireAndTrackedWritesDo() throws {
        try makeRepo()
        let cache = IgnoredDirectoryCache()
        let watcher = RepositoryWatcher(debounce: 0.05, latency: 0.05)
        var count = 0
        watcher.onChange = { count += 1 }
        let status = GitWatchFilter.statusFilter(root: repo, linkedGitDir: nil, cache: cache)
        watcher.start(paths: [repo], filter: status.filter, onFire: status.onFire)
        XCTAssertTrue(pump(until: { cache.isLoaded(root: self.repo) }))
        pump(0.3)
        count = 0

        try write("node_modules/pkg/index.js", "y\n")
        try write("node_modules/pkg/new.js", "z\n")
        pump(0.6)
        XCTAssertEqual(count, 0, "a write under node_modules/ fired")

        try write("tracked.txt", "two\n")
        XCTAssertTrue(pump(until: { count > 0 }, timeout: 3), "a tracked write never fired")
        watcher.stop()
    }

    /// Real FSEvents: the pane branch watcher ignores index writes and fires on
    /// a checkout.
    func testBranchWatcherFiresOnCheckoutOnly() throws {
        try makeRepo()
        let gitDir = try XCTUnwrap(GitStatusModel.gitDirectory(forRoot: repo))
        XCTAssertEqual(gitDir, repo + "/.git")
        let watcher = RepositoryWatcher(debounce: 0.05, latency: 0.05)
        var count = 0
        watcher.onChange = { count += 1 }
        watcher.start(paths: [gitDir], filter: { GitWatchFilter.isBranchEvent($0, gitDir: gitDir) })
        pump(0.3)
        count = 0

        try write("tracked.txt", "two\n")
        XCTAssertEqual(try git("add", "tracked.txt"), 0)
        pump(0.6)
        XCTAssertEqual(count, 0, "an index write fired the branch watcher")

        XCTAssertEqual(try git("checkout", "-q", "-b", "other"), 0)
        XCTAssertTrue(pump(until: { count > 0 }, timeout: 3), "a checkout never fired")
        watcher.stop()
    }

    // MARK: - Ignored-directory cache

    func testCacheAnswersNothingBeforeTheFirstLoad() {
        let gate = DispatchSemaphore(value: 0)
        let cache = IgnoredDirectoryCache(loader: { _ in
            gate.wait()
            return ["build/"]
        })
        let subscription = cache.subscribe(root: "/r")
        XCTAssertFalse(cache.isLoaded(root: "/r"))
        XCTAssertFalse(subscription.isUnderIgnoredDirectory("/r/build/a.o"))
        gate.signal()
        XCTAssertTrue(pump(until: { subscription.isUnderIgnoredDirectory("/r/build/a.o") }))
        XCTAssertFalse(subscription.isUnderIgnoredDirectory("/r/buildx/a.o"))
        XCTAssertFalse(subscription.isUnderIgnoredDirectory("/elsewhere/build/a.o"))
    }

    /// A directory that shows up ignored after the first load is learned
    /// when a firing finds the list stale, and only once per window.
    func testFiringReloadsAStaleListOncePerWindow() throws {
        try makeRepo()
        try write(".gitignore", "node_modules/\n.build/\n")
        let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000))
        let loads = OSAllocatedUnfairLock(initialState: 0)
        let cache = IgnoredDirectoryCache(
            loader: { root in
                loads.withLock { $0 += 1 }
                return GitIgnoreChecker.loadIgnoredFiles(rootPath: root)
            },
            now: { clock.withLock { $0 } }
        )
        let watcher = RepositoryWatcher(debounce: 0.01, latency: 0.05)
        let status = GitWatchFilter.statusFilter(root: repo, linkedGitDir: nil, cache: cache)
        // The stream watches an empty directory, so only the events this test
        // hands to `handleEvents` reach the filter.
        let quiet = FileManager.default.temporaryDirectory.appendingPathComponent("git-watch-quiet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: quiet, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: quiet) }
        watcher.start(paths: [quiet.path], filter: status.filter, onFire: status.onFire)
        var fired = 0
        watcher.onChange = { fired += 1 }
        XCTAssertTrue(pump(until: { cache.isLoaded(root: self.repo) }))
        // Let any event from creating the watched directory drain first.
        pump(0.3)
        fired = 0
        XCTAssertEqual(loads.withLock { $0 }, 1)

        // The first build creates .build/ after that load.
        try write(".build/debug/a.o", "o\n")
        let built = repo + "/.build/debug/a.o"
        XCTAssertFalse(cache.isUnderIgnoredDirectory(built, root: repo))

        // A dropped event never reloads, even with a stale list.
        clock.withLock { $0 += 11 }
        watcher.handleEvents(paths: [repo + "/node_modules/pkg/index.js"], flags: [0])
        pump(0.1)
        XCTAssertEqual(fired, 0)
        XCTAssertEqual(loads.withLock { $0 }, 1)

        // The burst from the new directory passes, fires, and the stale list reloads.
        watcher.handleEvents(paths: [built], flags: [0])
        XCTAssertTrue(pump(until: { cache.isUnderIgnoredDirectory(built, root: self.repo) }))
        XCTAssertEqual(fired, 1)
        XCTAssertEqual(loads.withLock { $0 }, 2)

        // Another firing inside the 10 s window starts no load.
        clock.withLock { $0 += 5 }
        watcher.handleEvents(paths: [repo + "/tracked.txt"], flags: [0])
        XCTAssertTrue(pump(until: { fired == 2 }))
        pump(0.2)
        XCTAssertEqual(loads.withLock { $0 }, 2)
        watcher.stop()
    }

    func testCacheLoadsReloadsAndDropsUnusedRoots() throws {
        try makeRepo()
        // A tracked file inside a directory that also holds ignored files.
        try write("build/tracked.txt", "t\n")
        XCTAssertEqual(try git("add", "build/tracked.txt"), 0)
        XCTAssertEqual(try git("commit", "-q", "-m", "build"), 0)
        try write(".gitignore", "node_modules/\nbuild/\n")
        try write("build/out.o", "o\n")

        let cache = IgnoredDirectoryCache()
        var subscription: IgnoredDirectoryCache.Subscription? = cache.subscribe(root: repo)
        XCTAssertTrue(pump(until: { cache.isLoaded(root: self.repo) }))
        XCTAssertTrue(cache.isUnderIgnoredDirectory(repo + "/node_modules/pkg/index.js", root: repo))
        XCTAssertTrue(cache.isUnderIgnoredDirectory(repo + "/node_modules", root: repo))
        XCTAssertFalse(cache.isUnderIgnoredDirectory(repo + "/tracked.txt", root: repo))
        // Git lists build/ file by file because it holds a tracked file, so
        // nothing under it is treated as an ignored directory.
        XCTAssertFalse(cache.isUnderIgnoredDirectory(repo + "/build/tracked.txt", root: repo))

        try write(".gitignore", "build/\n")
        subscription?.reload()
        XCTAssertTrue(pump(until: { !cache.isUnderIgnoredDirectory(self.repo + "/node_modules/pkg/index.js", root: self.repo) }))

        subscription = nil
        XCTAssertFalse(cache.isLoaded(root: repo), "the last release drops the entry")
    }
}
