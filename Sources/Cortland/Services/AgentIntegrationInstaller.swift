import Foundation

/// Detects installed agent CLIs (Claude Code, Codex, Pi) and wires their
/// hook/extension systems to report status to Cortland's agents panel.
///
/// Unlike scripts/install-agent-status-hooks (the from-source dev installer),
/// this uses the helper binaries shipped inside the app bundle, so it works
/// on machines that never had the source tree. Safe to run repeatedly — every
/// step is idempotent and existing user configuration is preserved.
///
/// `nonisolated`: this is file IO and text munging with no UI state, and
/// `reconcileOnLaunch` runs it on a utility queue so launch never blocks on it.
nonisolated enum AgentIntegrationInstaller {
    enum AgentID: CaseIterable {
        case claude
        case codex
        case pi

        var displayName: String {
            switch self {
            case .claude: return "Claude Code"
            case .codex: return "Codex"
            case .pi: return "Pi"
            }
        }
    }

    enum Status {
        case notDetected       // agent has never run on this machine
        case available         // detected, integration not installed
        case installed
        case helperMissing     // bundled helper binaries not found

        var description: String {
            switch self {
            case .notDetected: return "Not detected on this Mac."
            case .available: return "Detected — integration not installed."
            case .installed: return "Integration installed."
            case .helperMissing: return "Helper binaries missing from the app bundle."
            }
        }
    }

    enum InstallError: LocalizedError {
        case helperMissing
        case message(String)

        var errorDescription: String? {
            switch self {
            case .helperMissing:
                return "cortland-agent-status was not found next to the app executable."
            case .message(let text):
                return text
            }
        }
    }

    /// The user's home. A parameter on every entry point that reads or writes
    /// under it, defaulting to this, so tests run against a temp home and never
    /// touch the real `~/.claude`, `~/.codex`, or `~/.pi`.
    static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    /// Where the helper CLIs live: alongside the main executable, both in the app
    /// bundle (Contents/MacOS) and in SwiftPM build output (.build/<config>).
    /// Injectable for the same reason as `home`.
    static var bundledHelperDirectory: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent()
    }

    private static func helperURL(named name: String, in directory: URL?) -> URL? {
        guard let directory else { return nil }
        let url = directory.appendingPathComponent(name)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    // MARK: - Detection

    static func status(
        of agent: AgentID,
        home: URL = home,
        helperDirectory: URL? = bundledHelperDirectory
    ) -> Status {
        switch agent {
        case .claude:
            guard directoryExists(home.appendingPathComponent(".claude")) else { return .notDetected }
            guard helperURL(named: "cortland-agent-status", in: helperDirectory) != nil else { return .helperMissing }
            let settings = claudeSettingsText(home: home)
            guard settings.contains("cortland-agent-status") else { return .available }
            // A pre-PermissionRequest install lacks the needs-input hook; prompt
            // a reinstall so addClaudeHook idempotently adds it.
            guard settings.contains("PermissionRequest") else { return .available }
            // A pre-PostToolUse install strands an answered permission prompt on
            // "Needs input" until the next PreToolUse or Stop. (Checking the
            // Failure variant covers both — install adds the pair together.)
            guard settings.contains("PostToolUseFailure") else { return .available }
            // A pre-edit-gate install lacks the diff-review feeder, so the
            // approval desk never gets any mail; prompt a reinstall to add it.
            guard settings.contains("edit-gate") else { return .available }
            // A pre-SessionStart telemetry install keeps a stale context meter
            // after /clear; prompt a reinstall so the reset hook gets added.
            if isTelemetryHelperBundled(helperDirectory), !settings.contains("SessionStart") { return .available }
            return telemetryFullyInstalled(in: settings, helperDirectory: helperDirectory) ? .installed : .available
        case .codex:
            guard directoryExists(home.appendingPathComponent(".codex")) else { return .notDetected }
            guard helperURL(named: "cortland-agent-status", in: helperDirectory) != nil else { return .helperMissing }
            let config = codexConfigText(home: home)
            guard config.contains("cortland-agent-status") else { return .available }
            // A pre-PreToolUse install lacks the busy-refinement hook; prompt a
            // reinstall so installCodex idempotently adds it.
            guard config.contains("[[hooks.PreToolUse]]") else { return .available }
            return telemetryFullyInstalled(in: config, helperDirectory: helperDirectory) ? .installed : .available
        case .pi:
            guard directoryExists(home.appendingPathComponent(".pi/agent")) else { return .notDetected }
            guard let ext = try? String(contentsOf: piExtensionURL(home: home), encoding: .utf8) else { return .available }
            // A pre-edit-gate extension doesn't route file edits through the
            // approval desk (no `show_diff` round-trip); prompt a reinstall so
            // installPi ships the gate.
            guard ext.contains("show_diff") else { return .available }
            // The telemetry-enabled extension defines reportTelemetry.
            if isTelemetryHelperBundled(helperDirectory), !ext.contains("reportTelemetry") { return .available }
            return .installed
        }
    }

    private static func claudeSettingsURL(home: URL) -> URL {
        home.appendingPathComponent(".claude/settings.json")
    }

    private static func codexConfigURL(home: URL) -> URL {
        home.appendingPathComponent(".codex/config.toml")
    }

    private static func piExtensionURL(home: URL) -> URL {
        home.appendingPathComponent(".pi/agent/extensions/cortland-status.ts")
    }

    /// Where the Pi extension lived before the Cortland rename. Left behind, it
    /// loads alongside the new one and reports every lifecycle event twice.
    private static func legacyPiExtensionURL(home: URL) -> URL {
        home.appendingPathComponent(".pi/agent/extensions/sidekick-status.ts")
    }

    /// Helper binaries this app installed under its former name. Their hook
    /// entries survive the rename in the user's own settings file, where they
    /// are worse than useless: the binary they name is either gone or speaks the
    /// old termprop, so each event fires twice and one of the two goes nowhere.
    /// Every install strips them. `sidekick-hook` is older still — a retired
    /// PreToolUse diff popup that duplicated Claude Code's approval prompt.
    static let legacyHelperNames = [
        "sidekick-agent-status",
        "sidekick-telemetry",
        "sidekick-hook"
    ]

    /// Evidence that this config opted into the integration, under either name.
    /// A pre-rename install counts: the launch reconcile then adopts it — adding
    /// the `cortland-*` entries and dropping the stale ones — rather than reading
    /// it as "never opted in" and leaving the user with a dead agents panel.
    private static func namesStatusHelper(_ config: String) -> Bool {
        config.contains("cortland-agent-status") || config.contains("sidekick-agent-status")
    }

    private static func claudeSettingsText(home: URL) -> String {
        (try? String(contentsOf: claudeSettingsURL(home: home), encoding: .utf8)) ?? ""
    }

    private static func codexConfigText(home: URL) -> String {
        (try? String(contentsOf: codexConfigURL(home: home), encoding: .utf8)) ?? ""
    }

    /// Whether the telemetry helper is bundled and thus expected in a fully
    /// installed integration. When it isn't (a build without the helper), the
    /// status shouldn't perpetually read "available".
    private static func isTelemetryHelperBundled(_ helperDirectory: URL?) -> Bool {
        helperURL(named: "cortland-telemetry", in: helperDirectory) != nil
    }

    /// True when an integration that has the status hook is also wired for
    /// telemetry — i.e. the config already references `cortland-telemetry`, or
    /// the helper isn't bundled to install one. Drives the reinstall prompt when
    /// a pre-telemetry integration is detected.
    private static func telemetryFullyInstalled(in config: String, helperDirectory: URL?) -> Bool {
        !isTelemetryHelperBundled(helperDirectory) || config.contains("cortland-telemetry")
    }

    private static func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    // MARK: - Launch reconciliation

    /// Whether this agent's config already names our status helper (or, for Pi,
    /// has our extension) — i.e. the user opted in at some point, by clicking
    /// Install here or by running `scripts/install-agent-status-hooks`. It is the
    /// evidence `reconcile` requires before it will edit anything.
    static func integrationInstalled(_ agent: AgentID, home: URL = home) -> Bool {
        switch agent {
        case .claude: return namesStatusHelper(claudeSettingsText(home: home))
        case .codex: return namesStatusHelper(codexConfigText(home: home))
        case .pi:
            return FileManager.default.fileExists(atPath: piExtensionURL(home: home).path)
                || FileManager.default.fileExists(atPath: legacyPiExtensionURL(home: home).path)
        }
    }

    /// What a launch reconciliation did for one agent.
    enum ReconcileOutcome: Equatable {
        /// The integration was missing part of the current hook contract, and the
        /// missing part was added.
        case reconciled
        /// Already speaks the current contract. Nothing was written — the file
        /// isn't even opened for writing.
        case upToDate
        /// No integration to maintain. Reconciliation never creates one.
        case notInstalled
        case failed(String)
    }

    /// Brings already-installed integrations up to the hook contract this build
    /// speaks, on launch.
    ///
    /// The problem it solves: hook *entries* go stale the same way hook *binaries*
    /// do. When the contract gains an event (as it has twice already —
    /// PermissionRequest, then the telemetry SessionStart), a user who installed
    /// before it existed keeps a settings file that never mentions it, and the
    /// symptom is silence: the pane just never reports that state. From source,
    /// `install.sh` re-runs the installer and fixes this. A user who only ever
    /// downloads the `.app` has no repo and no script, so the app has to do it,
    /// or "launch the new app and you're done" is a lie for every future event.
    ///
    /// Why it is safe to edit a user's settings file on launch:
    ///   - It never bootstraps. Without `integrationInstalled` evidence — the
    ///     config already naming our helper — we do not open the file. Uninstall
    ///     the integration and the app stops touching it, permanently.
    ///   - It writes only when something is genuinely missing (`status` reports
    ///     `.available` for an installed integration only when part of the current
    ///     contract is absent). A current settings file is never rewritten, so the
    ///     common launch touches nothing at all.
    ///   - It is additive and idempotent: `install` merges into the parsed file,
    ///     dedups by helper name + argument (so a from-source install at
    ///     `~/.local/bin` is not duplicated by a bundle-path entry), preserves
    ///     every unrelated key, and writes atomically.
    ///
    /// The cost, stated plainly: a user who deletes *one* of our hook entries but
    /// keeps the rest gets it back on the next launch. Removing the integration —
    /// all of our entries — is the way to opt out, and it sticks. That trade buys
    /// every `.app` user a hook contract that repairs itself.
    static func reconcileOnLaunch() {
        // Same gate as the helper refresh: a dev build is a moving target, and
        // the from-source path has its own explicit installer.
        guard InstalledHelperRefresher.isRunningFromAppBundle else {
            Log.debug("Hook reconcile: skipped, not running from an app bundle", category: "app")
            return
        }

        DispatchQueue.global(qos: .utility).async {
            for (agent, outcome) in reconcile().sorted(by: { $0.key.displayName < $1.key.displayName }) {
                switch outcome {
                case .reconciled:
                    Log.info(
                        "Hook reconcile: \(agent.displayName)'s Cortland hooks were missing part of this "
                            + "build's contract and have been updated",
                        category: "app"
                    )
                case .failed(let reason):
                    Log.error("Hook reconcile: could not update \(agent.displayName): \(reason)", category: "app")
                case .upToDate, .notInstalled:
                    Log.debug("Hook reconcile: \(agent.displayName) — \(outcome)", category: "app")
                }
            }
        }
    }

    /// The reconciliation itself. Home and helper directories are parameters so
    /// tests run in a temp home and never touch the real one.
    @discardableResult
    static func reconcile(
        home: URL = home,
        helperDirectory: URL? = bundledHelperDirectory,
        agents: [AgentID] = AgentID.allCases,
        bundledSkill: URL? = InstalledSkillRefresher.bundledSkillDirectory
    ) -> [AgentID: ReconcileOutcome] {
        var outcomes: [AgentID: ReconcileOutcome] = [:]
        for agent in agents {
            guard integrationInstalled(agent, home: home) else {
                outcomes[agent] = .notInstalled
                continue
            }
            switch status(of: agent, home: home, helperDirectory: helperDirectory) {
            case .installed:
                outcomes[agent] = .upToDate
            case .notDetected:
                // The agent's config directory is gone but its integration text
                // isn't — nothing coherent to maintain.
                outcomes[agent] = .notInstalled
            case .helperMissing:
                outcomes[agent] = .failed("cortland-agent-status is missing from the app bundle")
            case .available:
                do {
                    try install(agent, home: home, helperDirectory: helperDirectory, bundledSkill: bundledSkill)
                    outcomes[agent] = .reconciled
                } catch {
                    outcomes[agent] = .failed(error.localizedDescription)
                }
            }
        }
        return outcomes
    }

    // MARK: - Install

    static func install(
        _ agent: AgentID,
        home: URL = home,
        helperDirectory: URL? = bundledHelperDirectory,
        bundledSkill: URL? = InstalledSkillRefresher.bundledSkillDirectory
    ) throws {
        switch agent {
        case .claude: try installClaude(home: home, helperDirectory: helperDirectory)
        case .codex: try installCodex(home: home, helperDirectory: helperDirectory)
        case .pi: try installPi(home: home, helperDirectory: helperDirectory)
        }

        // The pane-orchestration skill (what teaches the agent to drive
        // cortland-ctl and the MCP verbs) is part of the integration, and this is
        // the only installer an app-only user ever runs — from source,
        // scripts/install-agent-status-hooks writes the same files. Best-effort:
        // the hooks are what the button promises, and a skill that failed to copy
        // must not fail the wiring that did land.
        do {
            try InstalledSkillRefresher.install(
                into: skillRoot(for: agent, home: home),
                bundledSkillDirectory: bundledSkill
            )
        } catch {
            Log.error(
                "Agent integration: installed \(agent.displayName) hooks but could not install the "
                    + "\(InstalledSkillRefresher.skillName) skill: \(error.localizedDescription)",
                category: "app"
            )
        }
    }

    /// Where this agent loads user skills from.
    static func skillRoot(for agent: AgentID, home: URL = home) -> URL {
        switch agent {
        case .claude: return home.appendingPathComponent(".claude/skills", isDirectory: true)
        case .codex: return home.appendingPathComponent(".codex/skills", isDirectory: true)
        case .pi: return home.appendingPathComponent(".pi/agent/skills", isDirectory: true)
        }
    }

    /// Hook events shared by the Claude and Codex integrations.
    private static let statusHooks: [(event: String, state: String)] = [
        ("UserPromptSubmit", "busy"),
        ("Stop", "done")
    ]

    /// Refinements exposed by BOTH Claude Code and Codex (0.142+). PreToolUse
    /// marks the pane busy the instant a tool starts; PermissionRequest fires the
    /// instant an interactive approval prompt waits on the user — the correct
    /// "needs input" signal, and the only hook that fires for an inline prompt.
    /// (An earlier version of this file wrongly believed Codex exposed neither
    /// and gave it only a PermissionRequest hook; its hook schema mirrors Claude
    /// Code's, PreToolUse included.)
    private static let sharedRefinementHooks: [(event: String, state: String)] = [
        ("PreToolUse", "busy"),         // tool about to run (overridden by ready if it prompts)
        ("PermissionRequest", "ready")
    ]

    /// Refinements only Claude Code exposes. Codex has no Notification or
    /// SessionEnd event: a Codex pane instead clears from the agents panel when
    /// its root process exits (TerminalViewController.handleProcessTerminated ->
    /// AgentStateDetector.reset -> .idle), so the session-end signal isn't lost.
    private static let claudeOnlyStatusHooks: [(event: String, state: String)] = [
        // Notification is kept as a secondary trigger for the idle/gated case;
        // the helper suppresses its "waiting for your input" idle reminder.
        ("Notification", "ready"),
        // No hook fires when the user ANSWERS a permission prompt, so a pane
        // sat on "Needs input" from PermissionRequest until the next
        // PreToolUse or Stop. Tool completion is the earliest authoritative
        // busy signal after an approval (and the only one at all for
        // AskUserQuestion, whose tool call completes the moment the user
        // answers). Kept Claude-only until Codex's PostToolUse support is
        // verified.
        ("PostToolUse", "busy"),
        ("PostToolUseFailure", "busy"), // a failed tool still means Claude resumes
        ("SessionEnd", "idle")          // clears the tab from the agents panel
    ]

    /// Claude Code's auto-approve-edits permission mode: silences the prompt for
    /// file Edit/Write/MultiEdit while still asking for risky Bash, and — unlike
    /// `bypassPermissions` — is not blocked by a corporate
    /// `disableBypassPermissionsMode` policy, so it keeps working on locked-down
    /// machines. Also the fallback when bypass is requested but disabled.
    static let autoApproveMode = "acceptEdits"

    /// Claude Code's "no prompts at all" permission mode.
    static let bypassMode = "bypassPermissions"

    /// Claude Code's Auto mode: auto-approves everything, but a background
    /// safety classifier checks each action against the user's request and
    /// blocks destructive commands or actions driven by hostile content;
    /// explicit `ask` permission rules still prompt. Sits between `acceptEdits`
    /// (edits only, no oversight of Bash) and `bypassPermissions` (everything,
    /// no oversight at all). Requires Claude Code 2.1.207+ and an Opus 4.6+ /
    /// Sonnet 4.6+ model; an older CLI rejects the flag at launch, which is why
    /// this maps only from the explicit safety-reviewed level, never silently.
    static let claudeAutoPermissionMode = "auto"

    /// The defaultMode values Cortland manages. On returning to "ask" we clear
    /// only these, leaving a user's own pick (e.g. "plan") intact.
    static let managedModes: Set<String> = [autoApproveMode, bypassMode]

    /// The `--permission-mode` value to apply to `claude` sessions launched from
    /// within Cortland, or `nil` for normal prompting. This is the *scoped*
    /// replacement for writing `permissions.defaultMode` globally: Cortland passes
    /// it per-session (env var + shell wrapper for interactive panes, argv flag for
    /// Cortland-launched workers) so it never affects `claude` run outside Cortland.
    ///
    /// When `bypassPermissions` is requested but a managed/enterprise policy
    /// disables it, falls back to `acceptEdits` so a locked-down machine still gets
    /// the strongest available silencing instead of a rejected launch.
    static func claudePermissionMode(forApprovalMode mode: String) -> String? {
        guard let target = claudeMode(forApprovalMode: mode) else { return nil }
        if target == bypassMode, managedBypassDisabled() {
            return autoApproveMode
        }
        return target
    }

    /// Removes any Cortland-managed `permissions.defaultMode` (acceptEdits /
    /// bypassPermissions) left in the global `~/.claude/settings.json` by older
    /// versions, which disabled prompts for *every* `claude` session machine-wide.
    /// Permission mode is now scoped to Cortland sessions via `claudePermissionMode`,
    /// so this just migrates old global state back to clean. A user's own,
    /// unmanaged pick (e.g. "plan") is left intact. No-ops when Claude isn't present.
    static func clearManagedClaudeDefaultMode() throws {
        guard directoryExists(home.appendingPathComponent(".claude")) else { return }

        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL), !data.isEmpty {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw InstallError.message("~/.claude/settings.json is not a JSON object.")
            }
            settings = parsed
        }

        // Nothing managed to clear.
        guard applyAutoApproveMode(to: &settings, desiredMode: nil) else { return }

        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: settingsURL, options: .atomic)
    }

    /// Pure core of `syncClaudeAutoApprove`: mutates a parsed settings dict to
    /// the `desired` defaultMode (`nil` clears it) and returns whether anything
    /// changed, so callers can skip a needless rewrite. Internal for tests.
    static func applyAutoApproveMode(to settings: inout [String: Any], desiredMode desired: String?) -> Bool {
        var permissions = settings["permissions"] as? [String: Any] ?? [:]
        let current = permissions["defaultMode"] as? String

        if let desired {
            // acceptEdits is satisfied by the broader bypass too — don't downgrade.
            if desired == autoApproveMode, current == autoApproveMode || current == bypassMode {
                return false
            }
            if current == desired { return false }
            permissions["defaultMode"] = desired
        } else {
            // Restoring prompting: clear only a mode we manage.
            guard let current, managedModes.contains(current) else { return false }
            permissions.removeValue(forKey: "defaultMode")
        }

        if permissions.isEmpty {
            settings.removeValue(forKey: "permissions")
        } else {
            settings["permissions"] = permissions
        }
        return true
    }

    /// Whether a managed (enterprise) settings file disables `bypassPermissions`.
    /// macOS reads `/Library/Application Support/ClaudeCode/managed-settings.json`;
    /// when its `permissions.disableBypassPermissionsMode` is `"disable"`, writing
    /// bypass to the user file would be rejected, so we fall back to acceptEdits.
    private static func managedBypassDisabled() -> Bool {
        let url = URL(fileURLWithPath: "/Library/Application Support/ClaudeCode/managed-settings.json")
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let permissions = parsed["permissions"] as? [String: Any] else {
            return false
        }
        return (permissions["disableBypassPermissionsMode"] as? String) == "disable"
    }

    /// Maps a Cortland approval level (ask/auto/review/bypass) to
    /// the Claude Code permission mode, or `nil` for normal prompting.
    /// Centralizes the agent-specific mapping so callers only deal in the
    /// abstract level.
    static func claudeMode(forApprovalMode mode: String) -> String? {
        switch ApprovalMode(configValue: mode) {
        case .ask: return nil
        case .auto: return autoApproveMode
        case .review: return claudeAutoPermissionMode
        case .bypass: return bypassMode
        }
    }

    // MARK: - Codex auto-approve

    /// The `codex` CLI flags to apply to Codex sessions launched from within
    /// Cortland for a Cortland approval level, or `[]` for normal prompting. This
    /// is the *scoped* replacement for writing `approval_policy` + `sandbox_mode`
    /// globally into `~/.codex/config.toml`: Cortland passes these per-session
    /// (env var + shell wrapper for interactive panes, argv flags for
    /// Cortland-launched workers) so they never affect `codex` run outside
    /// Cortland — the exact model as `claudePermissionMode`.
    ///
    /// Codex has no per-command `acceptEdits` analog, so the same four intents are
    /// expressed through its sandbox, approval policy, and approval reviewer:
    ///   - ask:    read-only + on-request + human reviewer
    ///   - auto:   workspace-write + on-request + human reviewer
    ///   - review: workspace-write + on-request + automatic safety reviewer
    ///   - bypass: danger-full-access + never
    ///
    /// Fallback spirit of `claudePermissionMode`: a managed `requirements.toml`
    /// policy that disallows a requested value makes Codex silently downgrade to a
    /// permitted one and notify the user, so a locked-down machine degrades
    /// gracefully on its own without Cortland pre-checking the policy.
    static func codexApprovalFlags(forApprovalMode mode: String) -> [String] {
        switch ApprovalMode(configValue: mode) {
        case .ask:
            return codexArgs(sandbox: "read-only", approval: "on-request", reviewer: "user")
        case .auto:
            return codexArgs(
                sandbox: codexAutoSettings.sandbox,
                approval: codexAutoSettings.approval,
                reviewer: "user"
            )
        case .review:
            return codexArgs(
                sandbox: codexAutoSettings.sandbox,
                approval: codexAutoSettings.approval,
                reviewer: "auto_review"
            )
        case .bypass:
            return ["--sandbox", codexBypassSettings.sandbox, "--ask-for-approval", codexBypassSettings.approval]
        }
    }

    private static func codexArgs(sandbox: String, approval: String, reviewer: String) -> [String] {
        [
            "--sandbox", sandbox,
            "--ask-for-approval", approval,
            "-c", "approvals_reviewer=\(reviewer)"
        ]
    }

    /// Codex approval/sandbox flags recognized as a caller's own choice; when one
    /// is already present Cortland leaves the command untouched (its scoped flags
    /// would otherwise be redundant or conflict). Mirrors the `--permission-mode`
    /// guard on the Claude path.
    static let codexApprovalFlagNames: Set<String> = [
        "--sandbox", "-s", "--ask-for-approval", "-a",
        "--full-auto", "--yolo", "--dangerously-bypass-approvals-and-sandbox"
    ]

    static func isCodexApprovalOverride(_ argument: String) -> Bool {
        codexApprovalFlagNames.contains(argument)
            || argument.hasPrefix("--sandbox=")
            || argument.hasPrefix("--ask-for-approval=")
            || argument.hasPrefix("-s=")
            || argument.hasPrefix("-a=")
    }

    /// Whether `command` hands a caller's own `approvals_reviewer` to Codex,
    /// which takes approval control the same way a sandbox flag does: injecting a
    /// second, conflicting `approvals_reviewer` alongside it would leave
    /// Cortland's reviewer stamp naming whoever lost — and a pane stamped
    /// `auto_review` whose reviewer is really the human hides genuine prompts.
    ///
    /// Needs the whole argv because the bare `approvals_reviewer=…` form only
    /// means anything as the VALUE of a preceding `-c`/`--config`. On its own it
    /// is prose the caller is passing through, as in
    /// `codex exec "approvals_reviewer=auto_review behaves incorrectly"`.
    static func commandContainsCodexReviewerOverride(_ command: [String]) -> Bool {
        var previous: String?
        for argument in command {
            if argument.hasPrefix("-c=approvals_reviewer=")
                || argument.hasPrefix("--config=approvals_reviewer=") {
                return true
            }
            if (previous == "-c" || previous == "--config")
                && argument.hasPrefix("approvals_reviewer=") {
                return true
            }
            previous = argument
        }
        return false
    }

    /// Removes any Cortland-managed `approval_policy` + `sandbox_mode` combo an
    /// older version wrote into the global `~/.codex/config.toml`, which changed
    /// prompting for *every* `codex` session machine-wide. Approval is now scoped
    /// to Cortland sessions via `codexApprovalFlags`, so this migrates old global
    /// state back to clean, leaving a user's own hand-picked policy intact.
    /// No-ops when Codex isn't present.
    static func clearManagedCodexAutoApprove() throws {
        guard directoryExists(home.appendingPathComponent(".codex")) else { return }

        let configURL = home.appendingPathComponent(".codex/config.toml")
        let original = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        // mode "ask" clears only a combo we'd have written; a user's own pick stays.
        let updated = applyCodexAutoApprove(to: original, mode: "ask")
        guard updated != original else { return }

        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try updated.write(to: configURL, atomically: true, encoding: .utf8)
    }

    /// Codex (sandbox_mode, approval_policy) pairs per level — the config-key form
    /// of `codexApprovalFlags`, shared with the legacy-state cleaner.
    private static let codexAutoSettings = (sandbox: "workspace-write", approval: "on-request")
    private static let codexBypassSettings = (sandbox: "danger-full-access", approval: "never")

    /// Pure config-text form of the Codex approval mapping: returns the config
    /// with our two keys set (auto/bypass) or removed (ask). The "ask" branch
    /// backs `clearManagedCodexAutoApprove`'s legacy-state migration; auto/bypass
    /// document the (now scoped) key mapping and are covered by tests. Internal
    /// for tests.
    static func applyCodexAutoApprove(to config: String, mode: String) -> String {
        switch mode.lowercased() {
        case "auto":
            return setCodexKeys(in: config, codexAutoSettings)
        case "bypass":
            return setCodexKeys(in: config, codexBypassSettings)
        default:
            // Restore Codex's own behavior — but only undo a combo we'd have set,
            // leaving a user's hand-picked policy intact.
            guard codexHasManagedAutoApprove(config) else { return config }
            var c = removeCodexTopLevelKey(in: config, key: "sandbox_mode")
            c = removeCodexTopLevelKey(in: c, key: "approval_policy")
            return c
        }
    }

    private static func setCodexKeys(in config: String, _ settings: (sandbox: String, approval: String)) -> String {
        var c = setCodexTopLevelKey(in: config, key: "sandbox_mode", value: "\"\(settings.sandbox)\"")
        c = setCodexTopLevelKey(in: c, key: "approval_policy", value: "\"\(settings.approval)\"")
        return c
    }

    /// True when the current top-level keys match one of the combos we set, so
    /// "ask" knows it's safe to clear them.
    static func codexHasManagedAutoApprove(_ config: String) -> Bool {
        let sandbox = codexTopLevelValue(in: config, key: "sandbox_mode")
        let approval = codexTopLevelValue(in: config, key: "approval_policy")
        return (sandbox == codexAutoSettings.sandbox && approval == codexAutoSettings.approval)
            || (sandbox == codexBypassSettings.sandbox && approval == codexBypassSettings.approval)
    }

    /// Index of the first TOML table header (`[...]`), before which top-level
    /// keys must live. Returns the line count when there's no table.
    private static func firstCodexTableIndex(_ lines: [String]) -> Int {
        lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
    }

    private static func lineDefinesKey(_ line: String, _ key: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("\(key) ") || trimmed.hasPrefix("\(key)=")
    }

    /// Sets a top-level scalar `key = value` (value written verbatim, already
    /// quoted), replacing an existing top-level occurrence or inserting at the
    /// top so it stays ahead of every table header. Internal for tests.
    static func setCodexTopLevelKey(in config: String, key: String, value: String) -> String {
        var lines = config.components(separatedBy: "\n")
        let firstTable = firstCodexTableIndex(lines)
        for index in 0..<firstTable where lineDefinesKey(lines[index], key) {
            lines[index] = "\(key) = \(value)"
            return lines.joined(separator: "\n")
        }
        lines.insert("\(key) = \(value)", at: 0)
        return lines.joined(separator: "\n")
    }

    /// Removes a top-level scalar `key` (occurrences before the first table).
    /// Internal for tests.
    static func removeCodexTopLevelKey(in config: String, key: String) -> String {
        let lines = config.components(separatedBy: "\n")
        let firstTable = firstCodexTableIndex(lines)
        let kept = lines.enumerated().filter { index, line in
            !(index < firstTable && lineDefinesKey(line, key))
        }.map(\.element)
        return kept.joined(separator: "\n")
    }

    /// The unquoted value of a top-level scalar `key`, or nil when absent.
    private static func codexTopLevelValue(in config: String, key: String) -> String? {
        let lines = config.components(separatedBy: "\n")
        let firstTable = firstCodexTableIndex(lines)
        for index in 0..<firstTable where lineDefinesKey(lines[index], key) {
            guard let eq = lines[index].firstIndex(of: "=") else { continue }
            return lines[index][lines[index].index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    private static func installClaude(home: URL, helperDirectory: URL?) throws {
        guard let statusBinary = helperURL(named: "cortland-agent-status", in: helperDirectory) else {
            throw InstallError.helperMissing
        }

        let settingsURL = claudeSettingsURL(home: home)
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL), !data.isEmpty {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw InstallError.message("~/.claude/settings.json is not a JSON object.")
            }
            settings = parsed
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, state) in statusHooks + sharedRefinementHooks + claudeOnlyStatusHooks {
            addClaudeHook(
                to: &hooks, event: event,
                command: "\(shellQuotedIfNeeded(statusBinary.path)) \(state)"
            )
        }
        // Telemetry (Claude-first): a second Stop hook reports per-pane token
        // usage to the dashboard. Best-effort — registered only when the helper
        // is bundled; it dedups against the status Stop hook by binary name.
        if let telemetryBinary = helperURL(named: "cortland-telemetry", in: helperDirectory) {
            addClaudeHook(to: &hooks, event: "Stop", command: shellQuotedIfNeeded(telemetryBinary.path))
            // SessionStart (startup, /clear, resume) re-reports or resets the
            // pane's telemetry so the context meter doesn't keep showing the
            // previous session until the new one finishes a turn.
            addClaudeHook(to: &hooks, event: "SessionStart", command: shellQuotedIfNeeded(telemetryBinary.path))
        }
        // Strip the entries earlier versions left: the pre-rename `sidekick-*`
        // helpers, and the older sidekick-hook PreToolUse diff popup that
        // duplicated Claude Code's own approval prompt (it never emitted a
        // permission decision, so the harness still asked).
        removeLegacyHooks(from: &hooks)
        // Edit-gate: the successor that CAN answer. It routes Edit/Write through
        // Cortland's diff-review queue and returns the reviewer's verdict as a
        // permissionDecision (allow/deny), so the desk's prompt replaces
        // Claude's rather than duplicating it; on any failure the hook stays
        // silent and Claude's own prompt takes over. The explicit timeout is
        // the human-review budget (600s, matching Claude Code's default,
        // written out so the contract is visible in the settings file).
        addClaudeHook(
            to: &hooks, event: "PreToolUse",
            command: "\(shellQuotedIfNeeded(statusBinary.path)) edit-gate",
            matcher: "Edit|Write",
            timeoutSeconds: 600
        )
        settings["hooks"] = hooks

        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: settingsURL, options: .atomic)
    }

    /// Appends a command hook group for `event` unless an equivalent hook is
    /// already registered (matched by binary name + argument, so an existing
    /// from-source install at another path counts). Internal for tests.
    static func addClaudeHook(
        to hooks: inout [String: Any],
        event: String,
        command: String,
        matcher: String? = nil,
        timeoutSeconds: Int? = nil
    ) {
        var groups = hooks[event] as? [[String: Any]] ?? []
        // Compare with shell quotes stripped so a quoted command (bundle path
        // with a space) still dedups against an unquoted install and vice versa.
        let unquoted = command.replacingOccurrences(of: "'", with: "")
        let signature = unquoted.components(separatedBy: "/").last ?? unquoted

        for group in groups {
            for hook in group["hooks"] as? [[String: Any]] ?? [] {
                guard let existing = hook["command"] as? String else { continue }
                if existing == command
                    || existing.replacingOccurrences(of: "'", with: "").hasSuffix(signature) {
                    return
                }
            }
        }

        var hook: [String: Any] = ["type": "command", "command": command]
        if let timeoutSeconds = timeoutSeconds {
            hook["timeout"] = timeoutSeconds
        }
        var group: [String: Any] = ["hooks": [hook]]
        if let matcher = matcher {
            group["matcher"] = matcher
        }
        groups.append(group)
        hooks[event] = groups
    }

    /// Removes every hook entry that runs a helper we no longer ship, across all
    /// events — a rename leaves them scattered wherever a past install put them,
    /// so this sweeps the whole table rather than an event list that would go
    /// stale on its own. Internal for tests.
    static func removeLegacyHooks(from hooks: inout [String: Any]) {
        for event in Array(hooks.keys) {
            for name in legacyHelperNames {
                removeClaudeHook(from: &hooks, event: event, signature: name)
            }
        }
    }

    /// Removes any hook group under `event` that invokes a command whose path
    /// ends in `signature` (the binary name), dropping groups left empty. Used
    /// to retire integrations a previous install added. Internal for tests.
    static func removeClaudeHook(
        from hooks: inout [String: Any],
        event: String,
        signature: String
    ) {
        guard var groups = hooks[event] as? [[String: Any]] else { return }

        groups = groups.compactMap { group in
            let kept = (group["hooks"] as? [[String: Any]] ?? []).filter { hook in
                guard let command = hook["command"] as? String else { return true }
                let name = command.split(separator: " ").first.map(String.init) ?? command
                return !(name == signature || name.hasSuffix("/\(signature)"))
            }
            if kept.isEmpty { return nil }
            var updated = group
            updated["hooks"] = kept
            return updated
        }

        if groups.isEmpty {
            hooks.removeValue(forKey: event)
        } else {
            hooks[event] = groups
        }
    }

    private static func installCodex(home: URL, helperDirectory: URL?) throws {
        guard let statusBinary = helperURL(named: "cortland-agent-status", in: helperDirectory) else {
            throw InstallError.helperMissing
        }

        let configURL = codexConfigURL(home: home)
        var config = codexConfigText(home: home)

        // Before adding anything: a pre-rename block still names an event this
        // install is about to write, and the dedup below keys on the helper
        // name, so leaving it would give the event two hooks.
        config = removeLegacyCodexHooks(from: config)
        config = ensureCodexHooksEnabled(in: config)

        // Codex gets no edit-gate hook, deliberately. Verified against the
        // openai/codex source (hooks/src/engine/output_parser.rs), the official
        // hooks docs, and codex-cli 0.144.3's embedded schemas: a Codex
        // PreToolUse hook can only veto — a bare permissionDecision "allow" is
        // rejected as unsupported — so an approve can't suppress Codex's own
        // prompt, and a desk round-trip would double-prompt (the bug that got
        // the original cortland-hook removed). PermissionRequest CAN allow, but
        // it only fires when Codex would already prompt, so it can't gate edits
        // under the workspace-write/bypass flags Cortland launches with. Codex
        // keeps its flag-based approvals; the PermissionRequest -> "ready" hook
        // still surfaces the wait in the agents panel either way.
        for (event, state) in statusHooks + sharedRefinementHooks {
            let command = "\(shellQuotedIfNeeded(statusBinary.path)) \(state)"
            let signature = "cortland-agent-status \(state)"
            if (config.contains(signature) || config.contains(command))
                && config.contains("[[hooks.\(event)]]") {
                continue
            }
            config = config.trimmingTrailingNewlines() + """


            [[hooks.\(event)]]
            [[hooks.\(event).hooks]]
            type = "command"
            command = \(tomlString(command))

            """
        }

        // Telemetry: a Stop hook reporting per-pane token usage, parsing Codex's
        // rollout schema (hence the "codex" argument). Best-effort, dedup by the
        // helper name + flavor.
        if let telemetryBinary = helperURL(named: "cortland-telemetry", in: helperDirectory),
           !config.contains("cortland-telemetry codex"),
           !config.contains("cortland-telemetry' codex") {
            let command = "\(shellQuotedIfNeeded(telemetryBinary.path)) codex"
            config = config.trimmingTrailingNewlines() + """


            [[hooks.Stop]]
            [[hooks.Stop.hooks]]
            type = "command"
            command = \(tomlString(command))

            """
        }

        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try config.write(to: configURL, atomically: true, encoding: .utf8)
    }

    /// Drops every `[[hooks.<event>]]` block that runs a pre-rename helper.
    ///
    /// Works on line ranges rather than a TOML round-trip, like the rest of the
    /// Codex editing here, so the user's own formatting and comments survive. A
    /// block runs from its `[[hooks.<event>]]` header to the next table header
    /// that isn't its own `.hooks` sub-table. Internal for tests.
    static func removeLegacyCodexHooks(from config: String) -> String {
        let lines = config.components(separatedBy: "\n")
        var kept: [String] = []
        var index = 0

        while index < lines.count {
            guard isCodexHookEventHeader(lines[index]) else {
                kept.append(lines[index])
                index += 1
                continue
            }
            var end = index + 1
            while end < lines.count, !startsCodexTable(lines[end]) {
                end += 1
            }
            let block = lines[index..<end]
            let isLegacy = block.contains { line in
                legacyHelperNames.contains { line.contains($0) }
            }
            if !isLegacy {
                kept.append(contentsOf: block)
            }
            index = end
        }

        return kept.joined(separator: "\n")
    }

    /// `[[hooks.Stop]]` yes; `[[hooks.Stop.hooks]]` no (that's the sub-table
    /// belonging to the block above it).
    private static func isCodexHookEventHeader(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[[hooks."), trimmed.hasSuffix("]]") else { return false }
        return !trimmed.dropFirst("[[hooks.".count).dropLast(2).contains(".")
    }

    /// Any table header that opens something other than the current block's
    /// `.hooks` sub-table, and therefore ends the block.
    private static func startsCodexTable(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[") else { return false }
        return !(trimmed.hasPrefix("[[hooks.") && trimmed.hasSuffix(".hooks]]"))
    }

    /// Makes sure config.toml has `hooks = true` under `[features]`, adding
    /// either or both without disturbing the rest of the file. Internal for
    /// tests.
    static func ensureCodexHooksEnabled(in config: String) -> String {
        var lines = config.components(separatedBy: "\n")

        guard let featuresIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "[features]"
        }) else {
            // No [features] table: add one ahead of the first table so any
            // top-level keys above it stay top-level.
            let block = ["[features]", "hooks = true", ""]
            if let firstTable = lines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("[")
            }) {
                lines.insert(contentsOf: block, at: firstTable)
            } else {
                lines.append(contentsOf: block)
            }
            return lines.joined(separator: "\n")
        }

        // Section runs until the next table header.
        var sectionEnd = lines.count
        for index in (featuresIndex + 1)..<lines.count
        where lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("[") {
            sectionEnd = index
            break
        }

        for index in (featuresIndex + 1)..<sectionEnd {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("hooks") {
                lines[index] = "hooks = true"
                return lines.joined(separator: "\n")
            }
        }

        lines.insert("hooks = true", at: featuresIndex + 1)
        return lines.joined(separator: "\n")
    }

    private static func tomlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Hook commands run through a shell, so a helper path containing a space
    /// (or other metacharacter) must be single-quoted to survive word
    /// splitting. Plain paths pass through unchanged so existing installs
    /// still dedup by exact command match. Internal for tests.
    static func shellQuotedIfNeeded(_ path: String) -> String {
        let plain = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
                + "0123456789/._+-@%:,="
        )
        guard path.unicodeScalars.contains(where: { !plain.contains($0) }) else { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func installPi(home: URL, helperDirectory: URL?) throws {
        let extensionURL = piExtensionURL(home: home)
        try FileManager.default.createDirectory(
            at: extensionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Embed the absolute telemetry-helper path (best-effort: empty when the
        // helper isn't bundled, in which case the extension skips telemetry).
        let telemetryPath = helperURL(named: "cortland-telemetry", in: helperDirectory)?.path ?? ""
        let escaped = telemetryPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = piExtensionSource.replacingOccurrences(
            of: "__CORTLAND_TELEMETRY_BIN__", with: escaped
        )
        try source.write(to: extensionURL, atomically: true, encoding: .utf8)
        // Pi loads every file in extensions/, so a leftover sidekick-status.ts
        // would report each lifecycle event a second time — to a termprop this
        // build no longer reads.
        try? FileManager.default.removeItem(at: legacyPiExtensionURL(home: home))
    }

    /// Pi status + telemetry extension. Mirror of scripts/pi-cortland-status.ts —
    /// embedded like ShellIntegration's scripts so the app needs no source
    /// checkout. `__CORTLAND_TELEMETRY_BIN__` is replaced at install time with the
    /// absolute cortland-telemetry path (or "" to disable telemetry).
    private static let piExtensionSource = #"""
    // Cortland agent-status + telemetry extension for the Pi coding agent.
    //
    // Reports Pi's lifecycle to Cortland's agents panel using the same OSC 666
    // termprop sequence that cortland-agent-status emits for Claude Code/Codex
    // hooks, routes Pi's file-edit tools through Cortland's diff-approval desk,
    // and on each turn end hands Pi's session transcript to cortland-telemetry
    // for the token/cost dashboard. Installed by Cortland (Preferences -> Agents).
    //
    // Mapping:
    //   agent_start            -> busy  (working on a prompt)
    //   tool_call (edit/write) -> Cortland diff-approval desk (allow / deny)
    //   agent_end              -> done  (back at the input prompt) + telemetry
    //   session_shutdown(quit) -> idle  (removed from the agents panel)
    import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
    import { closeSync, openSync, readFileSync, writeSync } from "node:fs";
    import { spawn } from "node:child_process";
    import { connect } from "node:net";
    import { homedir } from "node:os";
    import { basename, join } from "node:path";

    const TERMPROP = "vte.ext.cortland.agent";
    const TELEMETRY_BIN = "__CORTLAND_TELEMETRY_BIN__";

    function report(status: "busy" | "ready" | "done" | "idle"): void {
      try {
        const fd = openSync("/dev/tty", "w");
        try {
          writeSync(fd, `\x1b]666;${TERMPROP}=${status}\x1b\\`);
        } finally {
          closeSync(fd);
        }
      } catch {
        // No controlling terminal (print/RPC mode) — nothing to report to.
      }
    }

    // Best-effort: hand the session transcript to cortland-telemetry, tagged via
    // the CORTLAND_PANE_ID the helper reads from the inherited environment. Never
    // throws into Pi.
    function reportTelemetry(sessionFile: string | undefined): void {
      if (!TELEMETRY_BIN || !sessionFile || !process.env.CORTLAND_PANE_ID) return;
      try {
        const child = spawn(TELEMETRY_BIN, ["pi"], {
          stdio: ["pipe", "ignore", "ignore"],
          env: process.env,
        });
        child.on("error", () => {});
        child.stdin.write(JSON.stringify({ transcript_path: sessionFile }));
        child.stdin.end();
      } catch {
        // ignore
      }
    }

    // --- Cortland edit-gate ---------------------------------------------------
    // Route Pi's file-edit tools through Cortland's diff-approval desk:
    // reconstruct the old/new file bodies, send a blocking `show_diff` over the
    // same Unix socket the cortland-agent-status hook uses, and allow or deny the
    // tool call on the reviewer's verdict — so the desk's prompt replaces Pi's
    // rather than adding a second one. Fail-open by contract: no socket, an
    // oversized or binary body, or any error lets the tool proceed to Pi's own
    // flow. Never throws into Pi.
    const CORTLAND_MAX_DIFF_BYTES = 4 * 1024 * 1024;

    function cortlandSocketPath(): string {
      const override = process.env.CORTLAND_SOCKET_PATH;
      if (override && override.length > 0) return override;
      return join(homedir(), ".config", "cortland", "cortland.sock");
    }

    // Current file body for review: a string to diff, undefined for a missing
    // file (a new-file write), or null for a body we must not diff — binary or
    // over the IPC ceiling — which the caller treats as fail-open.
    function cortlandReviewableBody(filePath: string): string | null | undefined {
      let buf: Buffer;
      try {
        buf = readFileSync(filePath);
      } catch {
        return undefined;
      }
      if (buf.length > CORTLAND_MAX_DIFF_BYTES || buf.includes(0)) return null;
      const text = buf.toString("utf8");
      // Reject invalid UTF-8 (re-encoding wouldn't round-trip) as binary.
      if (!Buffer.from(text, "utf8").equals(buf)) return null;
      return text;
    }

    interface CortlandEdit {
      oldText: string;
      newText: string;
    }

    function cortlandNormalizeEdits(input: unknown): CortlandEdit[] | undefined {
      const obj = input as { edits?: unknown; oldText?: unknown; newText?: unknown };
      if (obj && Array.isArray(obj.edits)) return obj.edits as CortlandEdit[];
      if (obj && typeof obj.oldText === "string" && typeof obj.newText === "string") {
        return [{ oldText: obj.oldText, newText: obj.newText }];
      }
      return undefined;
    }

    // Apply edits Pi-style: every oldText matched against the ORIGINAL body,
    // non-overlapping. Returns undefined when an edit can't be resolved so the
    // gate falls open rather than reviewing a diff Pi wouldn't produce.
    function cortlandApplyEdits(original: string, edits: CortlandEdit[]): string | undefined {
      const spans: { start: number; end: number; newText: string }[] = [];
      for (const edit of edits) {
        if (
          !edit || typeof edit.oldText !== "string" || typeof edit.newText !== "string"
          || edit.oldText.length === 0
        ) {
          return undefined;
        }
        const start = original.indexOf(edit.oldText);
        if (start < 0) return undefined;
        spans.push({ start, end: start + edit.oldText.length, newText: edit.newText });
      }
      spans.sort((a, b) => a.start - b.start);
      for (let i = 1; i < spans.length; i++) {
        if (spans[i].start < spans[i - 1].end) return undefined; // overlapping: fall open
      }
      let result = "";
      let cursor = 0;
      for (const span of spans) {
        result += original.slice(cursor, span.start) + span.newText;
        cursor = span.end;
      }
      return result + original.slice(cursor);
    }

    // Blocking round-trip to the desk. Resolves true (approved), false
    // (rejected), or undefined (unreachable / malformed / timed out) =>
    // fail-open. The 600s ceiling mirrors the Claude edit-gate hook's own timeout.
    function cortlandRequestDiff(
      filePath: string,
      oldBody: string,
      newBody: string,
    ): Promise<boolean | undefined> {
      return new Promise((resolve) => {
        let settled = false;
        const finish = (verdict: boolean | undefined): void => {
          if (settled) return;
          settled = true;
          resolve(verdict);
        };

        const command: Record<string, unknown> = {
          action: "show_diff",
          path: filePath,
          old: oldBody,
          new: newBody,
        };
        const paneID = process.env.CORTLAND_PANE_ID;
        if (paneID) command.pane_id = paneID;

        let buffer = "";
        const resolveLine = (line: string): void => {
          try {
            const response = JSON.parse(line);
            if (response && response.ok === true && typeof response.accepted === "boolean") {
              finish(response.accepted);
              return;
            }
          } catch {
            // fall through to fail-open
          }
          finish(undefined);
        };

        const socket = connect(cortlandSocketPath());
        socket.setEncoding("utf8");
        socket.setTimeout(600_000);
        socket.on("connect", () => {
          // One newline-framed JSON line, then half-close so the server replies.
          socket.end(`${JSON.stringify(command)}\n`);
        });
        socket.on("data", (chunk: string) => {
          buffer += chunk;
          const newline = buffer.indexOf("\n");
          if (newline >= 0) {
            resolveLine(buffer.slice(0, newline));
            socket.destroy();
          }
        });
        socket.on("end", () => resolveLine(buffer)); // EOF before newline: parse what arrived
        socket.on("timeout", () => {
          finish(undefined);
          socket.destroy();
        });
        socket.on("error", () => finish(undefined));
        socket.on("close", () => finish(undefined));
      });
    }

    // Gate `edit` and `write` on the desk's verdict; every other tool passes through.
    async function cortlandGateEdit(
      event: { toolName: string; input: unknown },
    ): Promise<{ block: boolean; reason: string } | undefined> {
      try {
        if (event.toolName !== "edit" && event.toolName !== "write") return undefined;
        const input = event.input as { path?: unknown; content?: unknown };
        const filePath = input?.path;
        if (typeof filePath !== "string" || filePath.length === 0) return undefined;

        const current = cortlandReviewableBody(filePath);
        if (current === null) return undefined; // binary / oversized: fall open

        let oldBody: string;
        let newBody: string;
        if (event.toolName === "write") {
          if (typeof input.content !== "string") return undefined;
          oldBody = current ?? "";
          newBody = input.content;
        } else {
          if (current === undefined) return undefined; // editing a missing file: let Pi report it
          const edits = cortlandNormalizeEdits(event.input);
          if (!edits) return undefined;
          const applied = cortlandApplyEdits(current, edits);
          if (applied === undefined) return undefined;
          oldBody = current;
          newBody = applied;
        }

        if (oldBody === newBody) return undefined; // no-op
        if (Buffer.byteLength(newBody, "utf8") > CORTLAND_MAX_DIFF_BYTES) return undefined;

        const verdict = await cortlandRequestDiff(filePath, oldBody, newBody);
        if (verdict === false) {
          return {
            block: true,
            reason: `The user rejected this edit to ${basename(filePath)} in Cortland's review `
              + "panel. Ask the user how to proceed instead of retrying the same edit.",
          };
        }
        return undefined; // approved, or desk unreachable: let the tool run, no second prompt
      } catch {
        return undefined; // never break the agent
      }
    }
    // --------------------------------------------------------------------------

    export default function (pi: ExtensionAPI) {
      pi.on("agent_start", async () => report("busy"));
      // Carry file edits to Cortland's approval desk and block on the verdict.
      pi.on("tool_call", async (event) => cortlandGateEdit(event));
      pi.on("agent_end", async (_event, ctx) => {
        report("done");
        try {
          reportTelemetry(ctx.sessionManager.getSessionFile());
        } catch {
          // ignore
        }
      });
      pi.on("session_shutdown", async (event) => {
        if (event.reason === "quit") {
          report("idle");
        }
      });
    }
    """#
}

private nonisolated extension String {
    func trimmingTrailingNewlines() -> String {
        var result = self
        while result.hasSuffix("\n") {
            result.removeLast()
        }
        return result
    }
}
