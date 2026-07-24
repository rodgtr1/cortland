import Foundation

/// One authoritative launch record, written by Cortland at the moment it spawns
/// a `claude`/`codex` process. Because Cortland *launches* the agent, it knows
/// the working directory (and git branch) first-hand, with no lossy round-trip
/// through the encoded project-dir name that the log scanner has to live with.
///
/// Pure value type, `nonisolated`/`Sendable`: it is produced and consumed off
/// the main thread even though the module defaults to `@MainActor`.
nonisolated struct SessionLaunchLedgerEntry: Codable, Sendable, Equatable {
    /// "claude" or "codex" — argv[0]'s basename at launch.
    var agent: String
    /// The directory the process was launched in.
    var cwd: String
    /// The git branch at launch, best-effort (nil when not a repo / lookup
    /// failed or timed out). Carried for future use; backfill only needs cwd.
    var branch: String?
    /// When the launch happened.
    var timestamp: Date
}

/// An append-only JSONL ledger of agent launches, alongside the Session Recall
/// cache. Written fire-and-forget on a background queue so it never sits on the
/// pane-launch path, and read (off-main) by `SessionsPanel` to backfill the one
/// blind spot the log scanner has: sessions whose log never recorded a cwd.
///
/// `nonisolated enum` of statics — no shared mutable state, safe off the main
/// thread. Single-process writer, so an atomic `seekToEnd`+`write` append is
/// sufficient; there is no cross-process locking.
nonisolated enum SessionLaunchLedger {
    /// Above this many entries, a read rewrites the file down to `trimTo` newest
    /// entries. Keeps an always-appended file from growing without bound while
    /// staying dead simple (no rotation, no index).
    static let maxEntries = 2000
    static let trimTo = 1000

    /// The default ±window (seconds) for matching a nil-cwd record to a launch.
    static let matchWindow: TimeInterval = 180

    /// Serializes the (branch-resolve + append) work off the launch path. Utility
    /// QoS: recording a launch is a background nicety, never latency-critical.
    private static let queue = DispatchQueue(label: "app.cortland.session-recall.launch-ledger", qos: .utility)

    /// ISO8601 on the wire so the file is human-legible and stable across runs.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// The ledger file, next to the Session Recall cache.
    static func defaultLedgerURL(fileManager: FileManager = .default) -> URL {
        SessionRecallCache.defaultCacheURL(fileManager: fileManager)
            .deletingLastPathComponent()
            .appendingPathComponent("session-launch-ledger.jsonl")
    }

    // MARK: - Recording

    /// Record a launch, fire-and-forget. Inspects argv[0]'s basename: only
    /// `claude`/`codex` launches are recorded; anything else is a no-op. All work
    /// (branch resolution + the file append) runs on a background queue so the
    /// caller (the pane-launch path) never blocks.
    static func record(
        command: [String],
        cwd: String,
        at url: URL = SessionLaunchLedger.defaultLedgerURL()
    ) {
        // Cheap pre-check on the calling thread so non-agent launches don't even
        // dispatch. The full check runs again in `recordSync`. The append uses
        // `FileManager.default` (constructed inside the closure so nothing
        // non-`Sendable` is captured); tests drive `recordSync` directly.
        guard agentName(for: command) != nil else { return }
        queue.async {
            recordSync(command: command, cwd: cwd, at: url, fileManager: .default)
        }
    }

    /// The synchronous core of `record`, exposed for tests (so they need not
    /// sleep on the async dispatch). Resolves the branch (best-effort) and
    /// appends one JSON line. Returns the appended entry, or nil when `command`
    /// is not an agent launch. `now`/`resolveBranch` are injectable so tests can
    /// pin the timestamp and avoid spawning git.
    @discardableResult
    static func recordSync(
        command: [String],
        cwd: String,
        at url: URL,
        now: Date = Date(),
        resolveBranch: (String) -> String? = SessionLaunchLedger.gitBranch(cwd:),
        fileManager: FileManager = .default
    ) -> SessionLaunchLedgerEntry? {
        guard let agent = agentName(for: command) else { return nil }
        let entry = SessionLaunchLedgerEntry(
            agent: agent,
            cwd: cwd,
            branch: resolveBranch(cwd),
            timestamp: now
        )
        append(entry, to: url, fileManager: fileManager)
        return entry
    }

    /// "claude"/"codex" from argv[0]'s basename, else nil.
    static func agentName(for command: [String]) -> String? {
        guard let first = command.first, !first.isEmpty else { return nil }
        let base = (first as NSString).lastPathComponent
        return (base == "claude" || base == "codex") ? base : nil
    }

    // MARK: - Reading

    /// Read every entry, skipping malformed lines. Missing/empty file → `[]`.
    /// When the file exceeds `maxEntries`, it is rewritten in place to the newest
    /// `trimTo` entries (bounding growth), and those are returned.
    static func entries(at url: URL = SessionLaunchLedger.defaultLedgerURL(), fileManager: FileManager = .default) -> [SessionLaunchLedgerEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        let decoder = makeDecoder()
        var result: [SessionLaunchLedgerEntry] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let lineData = trimmed.data(using: .utf8),
                  let entry = try? decoder.decode(SessionLaunchLedgerEntry.self, from: lineData)
            else { continue }
            result.append(entry)
        }
        if result.count > maxEntries {
            let trimmed = Array(result.suffix(trimTo))
            rewrite(trimmed, to: url, fileManager: fileManager)
            return trimmed
        }
        return result
    }

    // MARK: - Backfill

    /// Fill the cwd of records the scanner left blank, using authoritative launch
    /// entries. For each record with `cwd == nil` and a known timestamp, find the
    /// ledger entries for the same agent whose launch time is within `±window` of
    /// the record's timestamp; if EXACTLY ONE matches (unambiguous), adopt its
    /// cwd — recomputing `repo` and rebuilding `resumeCommand` with the `cd`
    /// prefix so the record stays internally consistent. Ambiguous (>1) or no
    /// match leaves the record untouched, as do records that already have a cwd.
    /// Pure; returns a new array.
    static func backfillCWDs(
        _ records: [SessionRecord],
        using entries: [SessionLaunchLedgerEntry],
        window: TimeInterval = SessionLaunchLedger.matchWindow
    ) -> [SessionRecord] {
        guard !entries.isEmpty else { return records }
        return records.map { record in
            guard record.cwd == nil, let ts = record.timestamp else { return record }
            let agent = record.agent.rawValue
            let matches = entries.filter {
                $0.agent == agent && abs($0.timestamp.timeIntervalSince(ts)) <= window
            }
            guard matches.count == 1, let match = matches.first else { return record }
            let cwd = match.cwd
            return SessionRecord(
                agent: record.agent,
                cwd: cwd,
                repo: repoName(from: cwd),
                sessionID: record.sessionID,
                resumeID: record.resumeID,
                timestamp: record.timestamp,
                title: record.title,
                aiTitle: record.aiTitle,
                resumeCommand: resumeCommand(agent: record.agent, resumeID: record.resumeID, cwd: cwd),
                logPath: record.logPath,
                isRootThread: record.isRootThread,
                generatedTitle: record.generatedTitle
            )
        }
    }

    // MARK: - Git

    /// Best-effort current branch of `cwd` via `git rev-parse --abbrev-ref HEAD`,
    /// with a ~2s timeout. Returns nil on any failure, a detached HEAD, or
    /// timeout. Uses `/usr/bin/git` to match the rest of the codebase.
    static func gitBranch(cwd: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }

        if done.wait(timeout: .now() + 2.0) == .timedOut {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let branch = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // "HEAD" means detached; treat as no branch.
        return (branch.isEmpty || branch == "HEAD") ? nil : branch
    }

    // MARK: - Private helpers

    /// Append one JSON line, creating the directory/file as needed. Single-process
    /// writer, so `seekToEnd`+`write` is a sufficient atomic append.
    private static func append(_ entry: SessionLaunchLedgerEntry, to url: URL, fileManager: FileManager) {
        guard var data = try? makeEncoder().encode(entry) else { return }
        data.append(0x0A) // '\n'
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    /// Rewrite the whole file from `entries` (used by the growth bound).
    private static func rewrite(_ entries: [SessionLaunchLedgerEntry], to url: URL, fileManager: FileManager) {
        let encoder = makeEncoder()
        var data = Data()
        for entry in entries {
            guard let line = try? encoder.encode(entry) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Last path component of `cwd` (trailing slashes trimmed). Mirrors
    /// `SessionLogScanner.repo(from:)` so a backfilled record's repo matches a
    /// natively-parsed one.
    private static func repoName(from cwd: String) -> String? {
        var trimmed = cwd
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed.split(separator: "/").last.map(String.init)
    }

    /// Rebuild the ready-to-run resume command with the `cd` prefix, matching
    /// `SessionLogScanner.makeRecord`'s format exactly.
    private static func resumeCommand(agent: SessionAgent, resumeID: String, cwd: String) -> String {
        let verb = agent == .claude ? "claude --resume" : "codex resume"
        return cwd.isEmpty ? "\(verb) \(resumeID)" : "cd \(cwd) && \(verb) \(resumeID)"
    }
}
