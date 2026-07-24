import Foundation

/// An mtime-keyed, on-disk cache over the Session Recall log scan, so
/// re-opening the session list is near-instant instead of re-parsing every
/// Claude/Codex log file each time.
///
/// Stateless by design: every method takes the roots and a cache-file `URL`
/// and returns values, reading/writing the JSON on each call. There is no
/// shared mutable state, so the type is safe to call off the main thread even
/// though the `Cortland` module defaults to `@MainActor` (see `Package.swift`
/// `.defaultIsolation(MainActor.self)`). It builds ON `SessionLogScanner` and
/// never duplicates the JSONL parsing.
nonisolated enum SessionRecallCache {
    /// One cached session: the parsed `SessionRecord` plus the source log
    /// file's path and last-seen modification time, which is the freshness key.
    nonisolated struct Entry: Codable, Sendable, Equatable {
        var path: String
        var mtime: Date
        var record: SessionRecord
        /// A locally-generated title for this session (Codex only), persisted
        /// separately from the parsed `record` so it survives re-parses and can
        /// be set without re-scanning. Overlaid onto `record.generatedTitle`
        /// when the cache hands records back. Optional, so caches written before
        /// this field still decode (missing key → nil).
        var generatedTitle: String? = nil
    }

    /// The whole persisted cache. A wrapper struct (rather than a bare array)
    /// leaves room to bump a schema version later without breaking decoding.
    nonisolated struct Snapshot: Codable, Sendable, Equatable {
        var entries: [Entry]

        init(entries: [Entry] = []) {
            self.entries = entries
        }
    }

    // MARK: - Public API

    /// Refresh the unified session list against the two roots, re-parsing only
    /// what changed:
    /// - unchanged files (same mtime as the cache) reuse their cached record,
    /// - new or modified files are re-parsed,
    /// - files that no longer exist are dropped (they aren't rediscovered).
    ///
    /// The updated cache is written back to `cacheURL` and the fresh unified
    /// list is returned.
    static func refresh(
        claudeProjectsRoot: URL,
        codexSessionsRoot: URL,
        cacheURL: URL,
        fileManager: FileManager = .default
    ) -> [SessionRecord] {
        let previous = load(from: cacheURL, fileManager: fileManager)
        var byPath: [String: Entry] = [:]
        for entry in previous.entries { byPath[entry.path] = entry }

        let logs = SessionLogScanner.discoverLogs(
            claudeProjectsRoot: claudeProjectsRoot,
            codexSessionsRoot: codexSessionsRoot,
            fileManager: fileManager
        )

        var entries: [Entry] = []
        for log in logs {
            let path = log.url.path
            let mtime = fileModificationDate(of: log.url, fileManager: fileManager)

            if let mtime,
               let cached = byPath[path],
               sameMTime(cached.mtime, mtime) {
                // Unchanged since last scan: reuse the cached record, no parse.
                entries.append(cached)
                continue
            }

            // New, modified, or un-stattable: re-parse.
            guard let record = SessionLogScanner.parse(log, fileManager: fileManager) else { continue }
            entries.append(Entry(path: path, mtime: mtime ?? Date(timeIntervalSince1970: 0), record: record))
        }

        save(Snapshot(entries: entries), to: cacheURL, fileManager: fileManager)
        return entries.map(recordWithGeneratedTitle)
    }

    /// Set (or overwrite) the locally-generated title for the entry at
    /// `logPath`, then persist. A no-op when no entry matches the path (e.g. the
    /// log was deleted between scan and title generation). Cheap read-modify-
    /// write of the whole snapshot: the file is small and titling is a rare,
    /// background trickle, so there's no need for anything finer-grained.
    static func storeGeneratedTitle(
        _ title: String,
        forLogPath logPath: String,
        cacheURL: URL,
        fileManager: FileManager = .default
    ) {
        var snapshot = load(from: cacheURL, fileManager: fileManager)
        guard let idx = snapshot.entries.firstIndex(where: { $0.path == logPath }) else { return }
        snapshot.entries[idx].generatedTitle = title
        save(snapshot, to: cacheURL, fileManager: fileManager)
    }

    /// Overlay an entry's persisted `generatedTitle` onto its record, so callers
    /// read a single `record.generatedTitle`. The entry is the source of truth;
    /// the record's own copy is only what happened to be parsed (nil on a fresh
    /// scan).
    private static func recordWithGeneratedTitle(_ entry: Entry) -> SessionRecord {
        var record = entry.record
        record.generatedTitle = entry.generatedTitle
        return record
    }

    /// Decode the persisted cache, or an empty snapshot when the file is absent
    /// or unreadable/corrupt (a bad cache should degrade to a full re-parse,
    /// never crash).
    static func load(from cacheURL: URL, fileManager: FileManager = .default) -> Snapshot {
        guard let data = try? Data(contentsOf: cacheURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return Snapshot() }
        return snapshot
    }

    /// A default cache location under the user's Application Support directory,
    /// for real (non-test) use. Tests pass their own temp `URL`.
    static func defaultCacheURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("Cortland", isDirectory: true)
            .appendingPathComponent("session-recall-cache.json")
    }

    // MARK: - Persistence helpers

    private static func save(_ snapshot: Snapshot, to cacheURL: URL, fileManager: FileManager) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? fileManager.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: cacheURL, options: .atomic)
    }

    private static func fileModificationDate(of url: URL, fileManager: FileManager) -> Date? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    /// Compare mtimes with a sub-microsecond tolerance so a JSON float
    /// round-trip of the stored `Date` can never spuriously invalidate an
    /// otherwise-unchanged file. Real edits move the mtime by whole seconds.
    private static func sameMTime(_ a: Date, _ b: Date) -> Bool {
        abs(a.timeIntervalSince1970 - b.timeIntervalSince1970) < 0.000_001
    }
}
