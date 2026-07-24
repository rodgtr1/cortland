import Foundation

/// Keeps the installed `cortland-panes` agent skill in step with the app that is
/// running, refreshing it on launch — the skills half of what
/// `InstalledHelperRefresher` does for the `~/.local/bin` binaries.
///
/// The skill is the file that teaches Claude Code / Codex / Pi how to drive
/// Cortland's panes (`cortland-ctl`, the MCP verbs, the waiting rules). It is
/// copied into each agent's skills directory once — by
/// `scripts/install-agent-status-hooks` from source, or by Preferences → Agents
/// in an installed `.app` — and nothing updated it again. So a machine could run
/// a current Cortland while its agents read a months-old skill describing verbs
/// that changed, and the failure is quiet: the agent just uses the tool wrong.
///
/// Same rules as the helper refresh: replace only what an installer of ours put
/// there, compare content rather than timestamps, write atomically, and never
/// create an install the user didn't ask for.
nonisolated enum InstalledSkillRefresher {
    /// The one skill we ship and therefore the only directory we may touch
    /// inside a skills root.
    static let skillName = "cortland-panes"

    /// What the same skill was called before the Cortland rename. Installing the
    /// current one removes it: two skills describing the same panes, one of them
    /// naming binaries that no longer exist, is worse than either alone.
    static let legacySkillName = "sidekick-panes"

    /// Every file the skill is made of, as relative paths inside
    /// `<root>/cortland-panes/`. Adding a file here is enough to have it shipped,
    /// installed, and refreshed — the same list drives all three.
    static let managedFiles = ["SKILL.md", "agents/openai.yaml"]

    /// Where each agent loads user skills from. Claude Code and Codex read
    /// `~/.claude/skills` and `~/.codex/skills`; Pi reads `~/.pi/agent/skills`.
    /// All three take the same standard `SKILL.md` layout, so one copy per root.
    static func defaultInstallRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [".claude/skills", ".codex/skills", ".pi/agent/skills"].map {
            home.appendingPathComponent($0, isDirectory: true)
        }
    }

    /// The bundled copy: `Cortland.app/Contents/Resources/skills/cortland-panes`
    /// (see build-app.sh). Nil in a `swift build` binary, whose resource
    /// directory is just the build folder — which is fine, because refreshing is
    /// an installed-`.app` behavior (see `InstalledHelperRefresher.isRunningFromAppBundle`).
    static var bundledSkillDirectory: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent(skillName, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return url
    }

    /// What happened to one skills root. Reported rather than thrown so one bad
    /// install can't stop the others from being refreshed.
    enum Outcome: Equatable {
        /// At least one file differed and was replaced.
        case refreshed
        /// Every file already matched the bundled copy.
        case upToDate
        /// No `cortland-panes/` in this root. The user never installed the skill
        /// for this agent (or removed it), and a refresh is not an install: we
        /// only maintain what an installer of ours put there.
        case notInstalled
        /// This build doesn't ship the skill (a dev bundle, or a partial build).
        case notBundled
        /// The installed skill is a symlink — the user pointing an agent at their
        /// own checkout. Replacing it would silently undo that; following it would
        /// write outside the skills root.
        case skippedSymlink
        case failed(String)
    }

    // MARK: - Launch entry point

    /// Refreshes the installed skill in every skills root against this app's
    /// bundled copy. Returns immediately: the reads, the compares, and the writes
    /// happen on a utility queue, because launch must not block on file IO.
    ///
    /// Skipped unless we are running as an installed `.app`, for the same reason
    /// the helper refresh is: a source checkout is a moving target, and a working
    /// tree on a feature branch must not overwrite the user's installed skill with
    /// whatever is half-finished on that branch. From source,
    /// `scripts/install-agent-status-hooks` (and `install.sh`, which calls it)
    /// stays the way to update.
    static func refreshOnLaunch() {
        guard InstalledHelperRefresher.isRunningFromAppBundle else {
            Log.debug("Skill refresh: skipped, not running from an app bundle", category: "app")
            return
        }
        guard let bundled = bundledSkillDirectory else {
            Log.debug("Skill refresh: \(skillName) is not bundled in this build", category: "app")
            return
        }
        let roots = defaultInstallRoots()

        DispatchQueue.global(qos: .utility).async {
            let outcomes = refresh(bundledSkillDirectory: bundled, installRoots: roots)
            for (root, outcome) in outcomes.sorted(by: { $0.key < $1.key }) {
                switch outcome {
                case .refreshed:
                    Log.info("Skill refresh: updated \(root)/\(skillName) to this build's copy", category: "app")
                case .failed(let reason):
                    Log.error("Skill refresh: could not update \(root)/\(skillName): \(reason)", category: "app")
                case .upToDate, .notInstalled, .notBundled, .skippedSymlink:
                    Log.debug("Skill refresh: \(root) — \(outcome)", category: "app")
                }
            }
        }
    }

    // MARK: - The refresh itself

    /// Brings the skill in each root into line with the bundled copy. Directories
    /// are parameters so tests never go near the real `~/.claude`, `~/.codex`, or
    /// `~/.pi`. Keyed by root path.
    @discardableResult
    static func refresh(
        bundledSkillDirectory bundled: URL,
        installRoots: [URL],
        files: [String] = managedFiles,
        fileManager: FileManager = .default
    ) -> [String: Outcome] {
        var outcomes: [String: Outcome] = [:]
        for root in installRoots {
            outcomes[root.path] = refresh(
                root: root,
                bundled: bundled,
                files: files,
                fileManager: fileManager
            )
        }
        return outcomes
    }

    private static func refresh(
        root: URL,
        bundled: URL,
        files: [String],
        fileManager: FileManager
    ) -> Outcome {
        let installed = root.appendingPathComponent(skillName, isDirectory: true)

        // Absence is the user's answer: they never installed the skill for this
        // agent. Creating it here would start managing a directory they never
        // opted into — the rule the helper refresh follows too.
        guard fileManager.fileExists(atPath: installed.path) else { return .notInstalled }
        guard !isSymbolicLink(installed, fileManager: fileManager) else { return .skippedSymlink }

        var refreshedAny = false
        for file in files {
            let source = bundled.appendingPathComponent(file)
            let destination = installed.appendingPathComponent(file)

            guard fileManager.fileExists(atPath: source.path) else { continue }
            guard !isSymbolicLink(destination, fileManager: fileManager) else { continue }

            do {
                let bundledData = try Data(contentsOf: source)
                // A file *missing* from an existing install is stale too, not
                // absent-by-choice: it's what an upgrade that adds a file to the
                // skill looks like on an older install. The install itself exists,
                // so completing it is a refresh, not a new opt-in.
                if let installedData = try? Data(contentsOf: destination), installedData == bundledData {
                    continue
                }
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                // Skills are read, not executed — 0644, matching what
                // `install -m 0644` in scripts/install-agent-status-hooks writes.
                try AtomicFile.replace(destination, with: bundledData, permissions: 0o644, fileManager: fileManager)
                refreshedAny = true
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        return refreshedAny ? .refreshed : .upToDate
    }

    // MARK: - First-time install

    /// Installs the bundled skill into `root`, creating it. This is the *opt-in*
    /// path — Preferences → Agents calling it for the agent the user just clicked
    /// Install on — as opposed to `refresh`, which never creates anything.
    ///
    /// Throws only when the skill is bundled and the copy fails; a build without
    /// the skill is a no-op, since an integration is still worth installing
    /// without it.
    static func install(
        into root: URL,
        bundledSkillDirectory bundled: URL? = bundledSkillDirectory,
        files: [String] = managedFiles,
        fileManager: FileManager = .default
    ) throws {
        guard let bundled else { return }
        let installed = root.appendingPathComponent(skillName, isDirectory: true)
        // Their own symlinked checkout stays theirs.
        guard !isSymbolicLink(installed, fileManager: fileManager) else { return }

        for file in files {
            let source = bundled.appendingPathComponent(file)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = installed.appendingPathComponent(file)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try AtomicFile.replace(
                destination,
                with: try Data(contentsOf: source),
                permissions: 0o644,
                fileManager: fileManager
            )
        }

        removeLegacySkill(from: root, fileManager: fileManager)
    }

    /// Deletes a pre-rename `sidekick-panes/` from this root. Best-effort — the
    /// skill that matters is already installed — and a symlink is left alone,
    /// same as everywhere else here: it's the user pointing an agent at their own
    /// checkout, not something an installer of ours put there.
    static func removeLegacySkill(from root: URL, fileManager: FileManager = .default) {
        let legacy = root.appendingPathComponent(legacySkillName, isDirectory: true)
        guard fileManager.fileExists(atPath: legacy.path) else { return }
        guard !isSymbolicLink(legacy, fileManager: fileManager) else { return }
        try? fileManager.removeItem(at: legacy)
    }

    private static func isSymbolicLink(_ url: URL, fileManager: FileManager) -> Bool {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink
    }
}
