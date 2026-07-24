import Foundation

/// Live, in-process record of the per-agent approval flags to apply to `claude`
/// and `codex` sessions started inside Cortland — the scoped replacement for the
/// old global `~/.claude/settings.json` and `~/.codex/config.toml` writes. The
/// window controller keeps these in sync with the effective approval level
/// (persistent `[approval]` mode plus the per-session ⇧⌘A toggle). Direct workers
/// read the argv values below. Interactive pane shells read `modeFileURL` every
/// time `claude` or `codex` launches, so a preference change reaches the next
/// agent even when its pane was already open.
///
/// MainActor-isolated (the module default) because both writer and reader live on
/// the main actor.
enum AgentApprovalState {
    /// Canonical provider-neutral mode used by the shell integration fallback.
    static var mode: ApprovalMode = .ask

    /// The `--permission-mode` value for Cortland-launched `claude` sessions,
    /// or `nil` for normal prompting.
    static var claudePermissionMode: String?

    /// The approval/sandbox flags (e.g. `--sandbox … --ask-for-approval …`) for
    /// Cortland-launched `codex` sessions, or `[]` for normal prompting.
    static var codexApprovalArgs: [String] = []

    /// A data-only, atomically replaced snapshot consumed by shell wrappers.
    /// Keeping only the enum spelling here avoids sourcing executable content or
    /// trying to round-trip shell-escaped argv through an environment string.
    static var modeFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cortland/approval-mode")
    }

    static func persistMode(to url: URL = modeFileURL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Fail closed before replacing a previous value. If the atomic rename of
        // the requested mode later fails (disk full, directory permissions, and
        // so on), an existing shell sees `ask`, never a stale `bypass`. Avoid
        // following a user-created symlink at this data path.
        if fileManager.fileExists(atPath: url.path) {
            let isSymlink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            if isSymlink {
                try fileManager.removeItem(at: url)
            } else {
                let askData = Data((ApprovalMode.ask.rawValue + "\n").utf8)
                do {
                    try askData.write(to: url)
                    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                } catch {
                    // Deleting also makes the shell use its fail-closed env
                    // fallback. If neither operation is possible, propagate the
                    // failure so the in-process worker policy is downgraded too.
                    try fileManager.removeItem(at: url)
                }
            }
        }

        let data = Data((mode.rawValue + "\n").utf8)
        try AtomicFile.replace(url, with: data, permissions: 0o600)
    }
}
