import Foundation

/// Reads local Claude Code and Codex CLI session logs into unified
/// `SessionRecord` values. Pure `Foundation`, no persistence — this is the
/// parsing foundation of the Session Recall feature (find & resume a past
/// agent session).
///
/// Ported faithfully from the Phase 0 Python prototype
/// (`scripts/session-recall-scan.py`) and pinned by the golden fixtures under
/// `Tests/Fixtures/SessionRecall/`. It is a `nonisolated enum` of static
/// methods (matching `CodexTranscriptParser`) so scanning can run off the main
/// thread despite the module's `@MainActor` default isolation.
nonisolated enum SessionLogScanner {
    /// Read at most this many lines per file while hunting for cwd + timestamp
    /// + the first genuine human prompt. Mirrors the prototype's cap; the data
    /// we need is almost always in the first handful of lines.
    private static let maxLinesPerFile = 2000

    /// Prefixes that mark an injected wrapper / system / tooling payload rather
    /// than a real human prompt. Compared case-sensitively against the
    /// collapsed candidate text.
    private static let wrapperPrefixes = [
        "The following is the Codex agent history",
        "Caveat:",
        "[Request interrupted",
        "This session is being continued from a previous",
    ]

    // MARK: - Public API

    /// Parse a single Claude session file into a record, or nil if unreadable.
    static func parseClaudeSession(at url: URL, fileManager: FileManager = .default) -> SessionRecord? {
        guard let lines = jsonLines(at: url) else { return nil }

        let sessionID = url.deletingPathExtension().lastPathComponent
        var cwd: String?
        var timestamp: Date?
        var title: String?
        var aiTitle: String?

        for record in lines {
            let type = record["type"] as? String
            if cwd == nil, let value = record["cwd"] as? String {
                cwd = value
            }
            if timestamp == nil {
                timestamp = parseTimestamp(record["timestamp"])
            }
            // Claude writes its own AI-generated title into an `ai-title` line;
            // capture it separately. It may appear after the first user turn,
            // so we can't early-break once cwd/timestamp/title are all found.
            if aiTitle == nil, type == "ai-title", let raw = record["aiTitle"] as? String {
                let collapsed = collapse(raw)
                aiTitle = collapsed.isEmpty ? nil : collapsed
            }
            if title == nil, type == "user", let message = record["message"] as? [String: Any],
               message["role"] as? String == "user" {
                let candidate = collapse(textFromContent(message["content"]))
                if !candidate.isEmpty, !isWrapper(candidate) {
                    title = candidate
                }
            }
        }

        // cwd is authoritative ONLY from the in-record field. The encoded
        // project dir name is lossy (a literal '-' in a segment is
        // indistinguishable from an encoded '/'), so it is never decoded.
        if timestamp == nil {
            timestamp = fileModificationDate(of: url, fileManager: fileManager)
        }

        return makeRecord(
            agent: .claude,
            cwd: cwd,
            sessionID: sessionID,
            resumeID: sessionID,
            timestamp: timestamp,
            title: title,
            aiTitle: aiTitle,
            logPath: url.path
        )
    }

    /// Parse a single Codex rollout file into a record, or nil if unreadable.
    static func parseCodexRollout(at url: URL, fileManager: FileManager = .default) -> SessionRecord? {
        guard let lines = jsonLines(at: url) else { return nil }

        var cwd: String?
        var timestamp: Date?
        var title: String?
        var sessionID: String?
        var rolloutID: String?
        var threadSource: String?

        for record in lines {
            let type = record["type"] as? String
            let payload = record["payload"] as? [String: Any]

            if type == "session_meta", let payload {
                if let value = payload["cwd"] as? String { cwd = value }
                if let value = payload["session_id"] as? String { sessionID = value }
                if let value = payload["id"] as? String { rolloutID = value }
                if let value = payload["thread_source"] as? String { threadSource = value }
                if timestamp == nil {
                    timestamp = parseTimestamp(payload["timestamp"]) ?? parseTimestamp(record["timestamp"])
                }
            }

            if timestamp == nil {
                timestamp = parseTimestamp(record["timestamp"])
            }

            // Codex carries the human prompt on TWO channels: response_item/
            // message (content parts) and event_msg/user_message (a plain
            // `message` string). Read both, or real sessions get mislabeled.
            if title == nil, type == "response_item" || type == "event_msg", let payload {
                let payloadType = payload["type"] as? String
                var candidate = ""
                if payloadType == "message", payload["role"] as? String == "user" {
                    candidate = collapse(textFromContent(payload["content"]))
                } else if payloadType == "user_message", let message = payload["message"] as? String {
                    candidate = collapse(message)
                }
                if !candidate.isEmpty, !isWrapper(candidate) {
                    title = candidate
                }
            }

            if cwd != nil, timestamp != nil, title != nil {
                break
            }
        }

        // Root vs subagent: Codex writes one rollout per thread. The root thread
        // has `thread_source == "user"` (or, equivalently, its rollout `id`
        // equals the `session_id`); child/subagent threads set `thread_source ==
        // "subagent"` and a distinct id. Computed from the RAW session_meta
        // values before the id fallbacks below, so a subagent is never mistaken
        // for a root. Absent a session_meta the values are nil and this is false;
        // such orphan rollouts keep a unique sessionID and survive dedupe anyway.
        let isRootThread = threadSource == "user"
            || (rolloutID != nil && sessionID != nil && rolloutID == sessionID)

        // Resume id: prefer the rollout uuid from session_meta; fall back to
        // the uuid embedded in the filename (rollout-<ts>-<uuid>.jsonl).
        if rolloutID == nil {
            let stem = url.deletingPathExtension().lastPathComponent
            let parts = stem.split(separator: "-")
            rolloutID = parts.count >= 5 ? parts.suffix(5).joined(separator: "-") : stem
        }
        let resumeID = rolloutID ?? url.deletingPathExtension().lastPathComponent
        if sessionID == nil {
            sessionID = resumeID
        }
        if timestamp == nil {
            timestamp = fileModificationDate(of: url, fileManager: fileManager)
        }

        return makeRecord(
            agent: .codex,
            cwd: cwd,
            sessionID: sessionID ?? resumeID,
            resumeID: resumeID,
            timestamp: timestamp,
            title: title,
            aiTitle: nil,
            logPath: url.path,
            isRootThread: isRootThread
        )
    }

    /// One discovered log file paired with the agent that wrote it, so callers
    /// can decide *whether* to parse it (e.g. the incremental cache compares
    /// mtimes) before dispatching to the right parser.
    nonisolated struct DiscoveredLog: Sendable, Equatable {
        let url: URL
        let agent: SessionAgent
    }

    /// Scan a Claude projects root and a Codex sessions root into a combined
    /// list of records. Roots are explicit `URL`s so tests can point at a
    /// fixture tree; missing roots contribute nothing.
    static func scan(
        claudeProjectsRoot: URL,
        codexSessionsRoot: URL,
        fileManager: FileManager = .default
    ) -> [SessionRecord] {
        discoverLogs(
            claudeProjectsRoot: claudeProjectsRoot,
            codexSessionsRoot: codexSessionsRoot,
            fileManager: fileManager
        ).compactMap { parse($0, fileManager: fileManager) }
    }

    /// Enumerate every Claude + Codex log file under the two roots without
    /// parsing them. Split out from `scan` so the cache can stat each file and
    /// re-parse only the ones whose mtime changed. Order is Claude-then-Codex,
    /// matching the pre-split `scan`.
    static func discoverLogs(
        claudeProjectsRoot: URL,
        codexSessionsRoot: URL,
        fileManager: FileManager = .default
    ) -> [DiscoveredLog] {
        var logs: [DiscoveredLog] = []
        logs += discoverClaudeLogs(claudeProjectsRoot, fileManager: fileManager)
            .map { DiscoveredLog(url: $0, agent: .claude) }
        logs += discoverCodexLogs(codexSessionsRoot, fileManager: fileManager)
            .map { DiscoveredLog(url: $0, agent: .codex) }
        return logs
    }

    /// Parse a single discovered log with the parser its agent demands.
    static func parse(_ log: DiscoveredLog, fileManager: FileManager = .default) -> SessionRecord? {
        switch log.agent {
        case .claude: return parseClaudeSession(at: log.url, fileManager: fileManager)
        case .codex: return parseCodexRollout(at: log.url, fileManager: fileManager)
        }
    }

    /// Convenience that scans the real `~/.claude/projects` and
    /// `~/.codex/sessions` roots.
    static func scanDefaultRoots(fileManager: FileManager = .default) -> [SessionRecord] {
        let home = fileManager.homeDirectoryForCurrentUser
        return scan(
            claudeProjectsRoot: home.appendingPathComponent(".claude/projects"),
            codexSessionsRoot: home.appendingPathComponent(".codex/sessions"),
            fileManager: fileManager
        )
    }

    // MARK: - Directory walking

    private static func discoverClaudeLogs(_ root: URL, fileManager: FileManager) -> [URL] {
        guard let projectDirs = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        var urls: [URL] = []
        for project in projectDirs {
            guard (try? project.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let files = try? fileManager.contentsOfDirectory(
                      at: project, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                  ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                urls.append(file)
            }
        }
        return urls
    }

    private static func discoverCodexLogs(_ root: URL, fileManager: FileManager) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        var urls: [URL] = []
        for case let file as URL in enumerator {
            let name = file.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { continue }
            urls.append(file)
        }
        return urls
    }

    // MARK: - Record assembly

    private static func makeRecord(
        agent: SessionAgent,
        cwd: String?,
        sessionID: String,
        resumeID: String,
        timestamp: Date?,
        title: String?,
        aiTitle: String?,
        logPath: String,
        isRootThread: Bool = true
    ) -> SessionRecord {
        let verb = agent == .claude ? "claude --resume" : "codex resume"
        let resumeCommand: String
        if let cwd, !cwd.isEmpty {
            resumeCommand = "cd \(cwd) && \(verb) \(resumeID)"
        } else {
            // cwd unknown (unrecoverable): the user must cd there themselves.
            resumeCommand = "\(verb) \(resumeID)"
        }
        return SessionRecord(
            agent: agent,
            cwd: cwd,
            repo: repo(from: cwd),
            sessionID: sessionID,
            resumeID: resumeID,
            timestamp: timestamp,
            title: String((title ?? "(no prompt found)").prefix(100)),
            aiTitle: aiTitle,
            resumeCommand: resumeCommand,
            logPath: logPath,
            isRootThread: isRootThread
        )
    }

    // MARK: - Parsing helpers

    /// Collapse all whitespace/newlines to single spaces and strip.
    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// True if the candidate title text is injected noise, not a human prompt.
    private static func isWrapper(_ text: String) -> Bool {
        if text.isEmpty { return true }
        if text.hasPrefix("<") { return true }
        return wrapperPrefixes.contains { text.hasPrefix($0) }
    }

    /// Pull human-authored text out of a message `content` field. Handles both
    /// a bare string and a list of parts; only text-bearing parts (`text` for
    /// Claude, `input_text` for Codex) contribute, so tool results, tool uses,
    /// and images never become a title.
    private static func textFromContent(_ content: Any?) -> String {
        if let string = content as? String {
            return string
        }
        if let parts = content as? [Any] {
            var pieces: [String] = []
            for part in parts {
                guard let part = part as? [String: Any] else { continue }
                let type = part["type"] as? String
                if type == "text" || type == "input_text", let text = part["text"] as? String {
                    pieces.append(text)
                }
            }
            return pieces.joined(separator: "\n")
        }
        return ""
    }

    /// Parse an ISO8601 timestamp (accepting a trailing `Z` and optional
    /// fractional seconds) into a `Date`.
    private static func parseTimestamp(_ value: Any?) -> Date? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: trimmed) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: trimmed)
    }

    /// Last path component of `cwd` (trailing slashes trimmed), or nil.
    private static func repo(from cwd: String?) -> String? {
        guard var trimmed = cwd else { return nil }
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed.split(separator: "/").last.map(String.init)
    }

    private static func fileModificationDate(of url: URL, fileManager: FileManager) -> Date? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    /// Parse a jsonl file into an array of top-level JSON objects, skipping
    /// blank and malformed lines without throwing. Returns nil only when the
    /// file itself can't be read.
    private static func jsonLines(at url: URL) -> [[String: Any]]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // Decode lossily (invalid UTF-8 becomes U+FFFD) to mirror the
        // prototype's errors="replace" read.
        let contents = String(decoding: data, as: UTF8.self)
        var objects: [[String: Any]] = []
        var seen = 0
        for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            if seen >= maxLinesPerFile { break }
            seen += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let lineData = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }
            objects.append(object)
        }
        return objects
    }
}
