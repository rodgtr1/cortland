import Foundation

/// Which agent CLI produced a session log.
nonisolated enum SessionAgent: String, Codable, Sendable {
    case claude
    case codex
}

/// One past agent session, unified across Claude Code and Codex CLI logs.
///
/// This is a pure value type produced by `SessionLogScanner` off the main
/// thread, so it is explicitly `nonisolated`/`Sendable` even though the
/// `Cortland` module defaults to `@MainActor` (see `Package.swift`
/// `.defaultIsolation(MainActor.self)`).
///
/// `Codable` so `SessionRecallCache` can persist records to (and reload them
/// from) an on-disk JSON cache without re-parsing every log file.
nonisolated struct SessionRecord: Codable, Sendable, Equatable {
    /// The agent CLI that wrote the log.
    let agent: SessionAgent
    /// The session's working directory, taken ONLY from an in-record field.
    /// Nil when the log never recorded it — the encoded project dir name is a
    /// lossy source (`/`→`-`) and is never decoded back into a cwd.
    let cwd: String?
    /// Last path component of `cwd`, or nil when `cwd` is nil.
    let repo: String?
    /// The agent's own session identifier (Claude filename stem; Codex
    /// `session_id`). Falls back to `resumeID` for Codex when absent.
    let sessionID: String
    /// The id used to resume the session (`claude --resume <id>` /
    /// `codex resume <id>`). For Codex this is the rollout uuid.
    let resumeID: String
    /// Session start time, preferring the in-record/session_meta timestamp.
    let timestamp: Date?
    /// The first genuine human prompt (wrapper/injected text skipped),
    /// whitespace-collapsed and truncated to 100 chars, or "(no prompt found)".
    let title: String
    /// Claude's own generated title (`ai-title` line), when present. Always
    /// nil for Codex.
    let aiTitle: String?
    /// A ready-to-run shell command that resumes the session, prefixed with a
    /// `cd <cwd>` only when the cwd is known.
    let resumeCommand: String
    /// Absolute path to the source log file.
    let logPath: String
    /// Whether this record is the *root* thread of its logical session. True for
    /// every Claude record (each log is its own session) and for Codex rollouts
    /// whose `id == session_id` or whose `thread_source == "user"`. False for
    /// Codex subagent/child rollouts, which share a `sessionID` with their root.
    /// Used by `SessionQuery.dedupeSessions` to pick the representative row when
    /// Codex writes 2-3 rollout files for one session.
    ///
    /// `var` with a default so old on-disk caches (whose JSON predates this
    /// field) still decode — see the custom `Codable` conformance below, which
    /// decodes it as `decodeIfPresent ?? true`.
    var isRootThread: Bool = true
    /// A locally-generated one-line title (via `SessionTitler`/Ollama) for Codex
    /// sessions, which have no `aiTitle` of their own. Preferred over the raw
    /// first prompt for display, but below Claude's `aiTitle`. Nil until titled;
    /// persisted in the cache so a session is titled at most once ever.
    var generatedTitle: String? = nil

    /// The bare ARGV that resumes this session, for launching a process
    /// directly (a new tab's `command:`) rather than pasting a shell string.
    /// Unlike `resumeCommand`, it carries no `cd` prefix — the cwd is supplied
    /// out of band via the tab's working directory. The verb differs by agent:
    /// Claude uses `--resume`, Codex uses a `resume` subcommand.
    ///
    /// `nonisolated` (inherited from the type) so it is safe to read off the
    /// main thread; it is the correctness-critical bit and is unit-tested.
    var resumeArgv: [String] {
        switch agent {
        case .claude: return ["claude", "--resume", resumeID]
        case .codex: return ["codex", "resume", resumeID]
        }
    }
}

// MARK: - Codable (custom decode for backward-compatible new fields)

/// Hand-written `init(from:)` so that cache files written before `isRootThread`
/// and `generatedTitle` existed still decode: the flag defaults to `true`
/// (every pre-existing record was effectively a root), and the generated title
/// to `nil`. Declared in an extension so the synthesized memberwise initializer
/// (used all over the parser and tests) is preserved, and `encode(to:)` stays
/// synthesized from the same `CodingKeys`.
extension SessionRecord {
    enum CodingKeys: String, CodingKey {
        case agent, cwd, repo, sessionID, resumeID, timestamp, title, aiTitle
        case resumeCommand, logPath, isRootThread, generatedTitle
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agent = try container.decode(SessionAgent.self, forKey: .agent)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        repo = try container.decodeIfPresent(String.self, forKey: .repo)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        resumeID = try container.decode(String.self, forKey: .resumeID)
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp)
        title = try container.decode(String.self, forKey: .title)
        aiTitle = try container.decodeIfPresent(String.self, forKey: .aiTitle)
        resumeCommand = try container.decode(String.self, forKey: .resumeCommand)
        logPath = try container.decode(String.self, forKey: .logPath)
        isRootThread = try container.decodeIfPresent(Bool.self, forKey: .isRootThread) ?? true
        generatedTitle = try container.decodeIfPresent(String.self, forKey: .generatedTitle)
    }
}
