import Foundation

/// Watches ~/.config/cortland/config.toml and fires `onChange` (on the main
/// queue) when its contents change. The parent directory is watched, not the
/// file itself, so atomic saves (write-temp-then-rename, used by most
/// editors) are detected too.
// `nonisolated` + `@unchecked Sendable`: the watcher lives on its own private
// serial `queue`, never the main actor. Its mutable state (`debounceWork`,
// `lastModificationDate`) is touched only from that queue — both the
// DispatchSource event handler and the debounce work run on it, so the accesses
// are genuinely serialized — plus start()/stop() at setup/teardown. The only
// hop back to the UI is `onChange`, a main-actor callback.
nonisolated final class ConfigWatcher: @unchecked Sendable {
    var onChange: (@MainActor () -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var debounceWork: DispatchWorkItem?
    private var lastModificationDate: Date?
    // Serial: the DispatchSource delivers events here and the debounce work runs
    // here, so `debounceWork`/`lastModificationDate` are never touched from two
    // threads at once (the global concurrent queue used before could overlap an
    // event handler with a still-running debounce item — a real data race).
    private let queue = DispatchQueue(label: "app.cortland.config-watcher", qos: .utility)

    private let configPath = NSString(string: "~/.config/cortland/config.toml").expandingTildeInPath
    // The path actually watched/stat'd. When config.toml is a symlink (e.g. a
    // stow/dotfiles link), this resolves to the real file so edits to the link
    // target are seen — otherwise we'd watch the wrong directory and read the
    // link's own (unchanging) modification date.
    private var watchedPath = ""

    /// Canonical path with symlinks and `..` resolved. Falls back to the input
    /// if the file does not exist yet.
    private func resolved(_ path: String) -> String {
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        // Use the pointer-returning result of realpath so we hit String's
        // (non-deprecated) UnsafePointer<CChar> overload rather than the
        // deprecated [CChar] array initializer.
        if let resolvedPtr = realpath(path, &buffer) {
            return String(cString: resolvedPtr)
        }
        return path
    }

    func start() {
        stop()

        watchedPath = resolved(configPath)
        let directory = (watchedPath as NSString).deletingLastPathComponent
        // An immutable local, not a property: the cancel handler must close the
        // exact descriptor its own source was opened with. Reading a shared
        // property would close whatever fd is current at cancel time (the wrong
        // one, if start() ever runs again), and capturing self weakly to reach it
        // leaks the fd outright when deinit cancels — self is already gone by the
        // time the handler runs.
        let fd = open(directory, O_EVTONLY)
        guard fd >= 0 else {
            Log.error("ConfigWatcher: cannot open \(directory)", category: "config")
            return
        }

        lastModificationDate = modificationDate()

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.scheduleReloadCheck()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    /// The directory also holds the IPC socket and session file, so events
    /// fire for unrelated writes — only reload when config.toml itself changed.
    private func scheduleReloadCheck() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let current = self.modificationDate()
            guard current != self.lastModificationDate else { return }
            self.lastModificationDate = current
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.onChange?()
                }
            }
        }
        debounceWork = work
        queue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: watchedPath))?[.modificationDate] as? Date
    }

    deinit {
        stop()
    }
}
