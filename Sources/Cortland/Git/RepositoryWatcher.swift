import Foundation
import CoreServices

/// The app's single change-detection mechanism for git state: an FSEvents
/// stream over a repository root that fires a debounced `onChange` on the main
/// actor whenever anything under the root changes (a commit, checkout, stage,
/// or an editor writing a file). Consumers that previously polled git on a
/// timer (the pane-title branch reader) or hand-rolled their own FSEvents
/// stream (the git panel) share this one implementation instead.
@MainActor
final class RepositoryWatcher {
    /// What the FSEvents context actually retains (via its retain/release
    /// callbacks) — never the watcher itself. The weak reference means a
    /// callback racing a last-release on another thread reads nil instead of a
    /// dangling pointer.
    private final class Box {
        weak var watcher: RepositoryWatcher?
        init(_ watcher: RepositoryWatcher) { self.watcher = watcher }
    }

    /// Invoked on the main actor after the debounce interval whenever the
    /// watched root changes. Set before calling `start`.
    var onChange: (() -> Void)?

    private let debounce: TimeInterval
    private let latency: TimeInterval
    // The least time between two `onChange` firings, or nil for a plain
    // debounce. Events inside the window collapse into one trailing firing.
    private let minimumInterval: TimeInterval?
    private var lastFired: DispatchTime?
    // Decides whether one event path is worth a firing; nil means every event
    // counts. Held only while watching, so whatever it captures (an
    // ignored-directory subscription) is released by `stop()`.
    private var pathFilter: ((String) -> Bool)?
    // Runs just before each `onChange` while watching; cleared by `stop()`.
    private var onFire: (() -> Void)?
    // Set/torn down on the main actor; reached from the nonisolated deinit at
    // end-of-life, so they opt out of isolation like GitStatusModel's did.
    nonisolated(unsafe) private var eventStream: FSEventStreamRef?
    nonisolated(unsafe) private var pending: DispatchWorkItem?
    private var watchedPaths: [String] = []

    /// `debounce` collapses a burst of file writes into one `onChange`;
    /// `latency` is the FSEvents coalescing window before the callback fires.
    /// `minimumInterval`, when set, keeps a steady stream of events from firing
    /// more than once per interval.
    init(debounce: TimeInterval = 0.3, latency: TimeInterval = 0.5, minimumInterval: TimeInterval? = nil) {
        self.debounce = debounce
        self.latency = latency
        self.minimumInterval = minimumInterval
    }

    // Tear down the stream directly: the resource handles are nonisolated(unsafe)
    // so this nonisolated deinit can reach them without hopping to the main actor
    // (which a deinit can't await). Calling Stop/Invalidate/Release off-main is
    // safe even though the stream was dispatched to the main queue.
    deinit {
        pending?.cancel()
        if let eventStream {
            FSEventStreamStop(eventStream)
            FSEventStreamInvalidate(eventStream)
            FSEventStreamRelease(eventStream)
        }
    }

    /// Begins watching `root`, replacing any existing stream. Convenience for
    /// the single-directory callers; see `start(paths:)` for the multi-path form.
    func start(root: String) {
        start(paths: [root])
    }

    /// Begins watching every path in `paths` under one FSEvents stream,
    /// replacing any existing stream. A linked worktree keeps HEAD/index inside
    /// `<mainrepo>/.git/worktrees/<name>` rather than under the checkout root, so
    /// the git panel watches both that directory and the root — otherwise an
    /// agent's stages/commits fire no event and only the fallback poll notices.
    /// A no-op restart is avoided by the caller (this always rebuilds), so
    /// callers should guard on changed paths when that matters.
    ///
    /// With a `filter`, the stream reports individual files and a callback
    /// schedules a firing only if the filter passes one of its paths (or
    /// FSEvents asks for a rescan). The filter runs on the main actor for every
    /// event, so it must answer from memory. `onFire` runs before each
    /// `onChange` this stream causes.
    func start(paths: [String], filter: ((String) -> Bool)? = nil, onFire: (() -> Void)? = nil) {
        stop()
        watchedPaths = paths
        guard !paths.isEmpty else { return }
        pathFilter = filter
        self.onFire = onFire

        // The stream is dispatched to the main queue (below), so the callback
        // already runs on the main actor — assert that to reach the watcher.
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info = info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { box.watcher?.scheduleDebounced() }
        }
        // Paths are CFStrings (kFSEventStreamCreateFlagUseCFTypes below); copy
        // them and the flags out of the C buffers inside the callback.
        let filteredCallback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, _ in
            guard let info = info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            let flags = Array(UnsafeBufferPointer(start: eventFlags, count: numEvents))
            MainActor.assumeIsolated { box.watcher?.handleEvents(paths: paths, flags: flags) }
        }

        // The context retains a weak box, not the watcher: FSEventStreamCreate
        // takes its own +1 via the retain callback and drops it when the stream
        // is deallocated after Invalidate, so a callback already in flight can
        // never see freed memory even if our last release happens off-main.
        let box = Box(self)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { info in
                guard let info = info else { return nil }
                _ = Unmanaged<Box>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info = info else { return }
                Unmanaged<Box>.fromOpaque(info).release()
            },
            copyDescription: nil
        )

        let created = withExtendedLifetime(box) {
            FSEventStreamCreate(
                nil,
                filter == nil ? callback : filteredCallback,
                &context,
                paths as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                // File-level events only when a filter needs the paths.
                filter == nil
                    ? FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)
                    : FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
            )
        }
        guard let stream = created else {
            Log.error("RepositoryWatcher: Failed to create FSEvents stream for \(paths.joined(separator: ", "))", category: "git")
            return
        }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        eventStream = stream
    }

    /// Stops watching and cancels any pending debounced `onChange`.
    func stop() {
        pending?.cancel()
        pending = nil
        watchedPaths = []
        pathFilter = nil
        onFire = nil
        guard let stream = eventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventStream = nil
    }

    /// The git directory a `.git` *file* points at, parsed from its
    /// `gitdir: <path>` line. In a linked worktree `.git` is a file (not a
    /// directory) holding a single `gitdir:` pointer at
    /// `<mainrepo>/.git/worktrees/<name>`. Returns nil for a normal repo's
    /// directory `.git` or any content without the pointer. The path is returned
    /// verbatim (may be relative to the worktree root); the caller resolves it.
    nonisolated static func gitdirPointer(fromGitFileContents contents: String) -> String? {
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("gitdir:") else { continue }
            let path = trimmed.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            return path.isEmpty ? nil : path
        }
        return nil
    }

    /// One FSEvents callback's worth of events from a filtered stream. Every
    /// path goes through the filter, even after one passes, because a filter
    /// may act on what it sees (a `.gitignore` event requests a reload).
    func handleEvents(paths: [String], flags: [FSEventStreamEventFlags]) {
        // When FSEvents loses history or asks for a rescan, the paths say
        // nothing reliable, so the batch always counts.
        let mustRescan = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagRootChanged
        )
        var relevant = flags.contains { $0 & mustRescan != 0 }
        for path in paths {
            if pathFilter?(path) ?? true { relevant = true }
        }
        guard relevant else { return }
        scheduleDebounced()
    }

    func scheduleDebounced() {
        pending?.cancel()
        let now = DispatchTime.now()
        var deadline = now + debounce
        // Inside the window after the last firing, wait for its end instead:
        // the burst still yields exactly one trailing firing.
        if let minimumInterval, let lastFired {
            deadline = max(deadline, lastFired + minimumInterval)
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lastFired = .now()
                self.onFire?()
                self.onChange?()
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: deadline, execute: work)
    }
}
