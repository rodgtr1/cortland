import XCTest
@testable import Cortland

/// Launch-time reconciliation of hook *entries* — the half of staleness that
/// refreshing binaries can't fix.
///
/// When the hook contract gains an event (PermissionRequest did, then the
/// telemetry SessionStart), a settings file written before it existed never
/// mentions it, and the symptom is silence. From source, `install.sh` re-runs the
/// installer. An app-only user has no repo, so the app reconciles on launch —
/// but only for an integration that already exists, and only when something is
/// actually missing.
///
/// Every test builds a temp home and a temp "bundle" of fake helper binaries. The
/// real `~/.claude`, `~/.codex`, and `~/.pi` are never touched.
final class AgentHookReconcileTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var home: URL!
    private var helpers: URL!
    private var bundledSkill: URL!

    private var settingsURL: URL { home.appendingPathComponent(".claude/settings.json") }
    private var codexConfigURL: URL { home.appendingPathComponent(".codex/config.toml") }
    private var piExtensionURL: URL { home.appendingPathComponent(".pi/agent/extensions/cortland-status.ts") }

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("sk-reconcile-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        helpers = root.appendingPathComponent("Cortland.app/Contents/MacOS")
        bundledSkill = root.appendingPathComponent("Cortland.app/Contents/Resources/skills/cortland-panes")

        try fm.createDirectory(at: helpers, withIntermediateDirectories: true)
        for helper in ["cortland-agent-status", "cortland-telemetry"] {
            let url = helpers.appendingPathComponent(helper)
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try fm.createDirectory(at: bundledSkill.appendingPathComponent("agents"), withIntermediateDirectories: true)
        try Data("# SKILL\n".utf8).write(to: bundledSkill.appendingPathComponent("SKILL.md"))
        try Data("name: skill\n".utf8).write(to: bundledSkill.appendingPathComponent("agents/openai.yaml"))
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    // MARK: - Helpers

    private func reconcile(
        _ agents: [AgentIntegrationInstaller.AgentID]
    ) -> [AgentIntegrationInstaller.AgentID: AgentIntegrationInstaller.ReconcileOutcome] {
        AgentIntegrationInstaller.reconcile(
            home: home,
            helperDirectory: helpers,
            agents: agents,
            bundledSkill: bundledSkill
        )
    }

    private func write(_ contents: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    private func text(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func settingsJSON() throws -> [String: Any] {
        let data = try Data(contentsOf: settingsURL)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func hookCommands(event: String) throws -> [String] {
        let hooks = try XCTUnwrap(settingsJSON()["hooks"] as? [String: Any])
        let groups = hooks[event] as? [[String: Any]] ?? []
        return groups.flatMap { group in
            (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }

    /// A settings.json as `scripts/install-agent-status-hooks` left it before the
    /// contract grew PermissionRequest and the telemetry hooks: real hooks, real
    /// user content around them, pointing at ~/.local/bin.
    private func writeOldClaudeIntegration() throws {
        try write(
            """
            {
              "model": "opus",
              "hooks": {
                "UserPromptSubmit": [
                  {"hooks": [{"type": "command", "command": "/x/.local/bin/cortland-agent-status busy"}]}
                ],
                "Stop": [
                  {"hooks": [{"type": "command", "command": "/x/.local/bin/cortland-agent-status done"}]},
                  {"hooks": [{"type": "command", "command": "/usr/local/bin/their-own-hook"}]}
                ]
              }
            }
            """,
            to: settingsURL
        )
    }

    // MARK: - Never bootstraps

    func testAnAgentWithNoIntegrationIsNotTouched() throws {
        // Claude is installed on this machine, but its settings say nothing about
        // Cortland. Reconciliation is maintenance, not installation: only the
        // Preferences → Agents button (or the from-source script) may opt a user
        // in, and this must never write a hook they didn't ask for.
        try write(#"{"model": "opus"}"#, to: settingsURL)
        let before = try text(of: settingsURL)

        XCTAssertEqual(reconcile([.claude])[.claude], .notInstalled)
        XCTAssertEqual(try text(of: settingsURL), before)
    }

    func testAnAgentThatIsNotEvenInstalledIsNotTouched() throws {
        // No ~/.claude at all.
        XCTAssertEqual(reconcile([.claude])[.claude], .notInstalled)
        XCTAssertFalse(fm.fileExists(atPath: settingsURL.path))
    }

    func testRemovingTheIntegrationEntirelyStopsReconciliationForGood() throws {
        // The documented way out: delete our hooks, and the app stops editing the
        // file. (Deleting *one* of them is not — that comes back, by design.)
        try writeOldClaudeIntegration()
        XCTAssertEqual(reconcile([.claude])[.claude], .reconciled)

        try write(#"{"model": "opus"}"#, to: settingsURL)
        let before = try text(of: settingsURL)

        XCTAssertEqual(reconcile([.claude])[.claude], .notInstalled)
        XCTAssertEqual(try text(of: settingsURL), before)
    }

    // MARK: - Claude

    func testMissingContractEventsAreAddedToAnExistingIntegration() throws {
        try writeOldClaudeIntegration()

        XCTAssertEqual(reconcile([.claude])[.claude], .reconciled)

        // The events the old install never had.
        XCTAssertTrue(try hookCommands(event: "PermissionRequest").contains { $0.hasSuffix("cortland-agent-status ready") })
        XCTAssertTrue(try hookCommands(event: "PreToolUse").contains { $0.hasSuffix("cortland-agent-status busy") })
        XCTAssertTrue(try hookCommands(event: "PostToolUse").contains { $0.hasSuffix("cortland-agent-status busy") })
        XCTAssertTrue(try hookCommands(event: "PostToolUseFailure").contains { $0.hasSuffix("cortland-agent-status busy") })
        XCTAssertTrue(try hookCommands(event: "SessionEnd").contains { $0.hasSuffix("cortland-agent-status idle") })
        XCTAssertTrue(try hookCommands(event: "SessionStart").contains { $0.hasSuffix("cortland-telemetry") })
    }

    func testTheUsersOwnContentSurvives() throws {
        try writeOldClaudeIntegration()

        XCTAssertEqual(reconcile([.claude])[.claude], .reconciled)

        XCTAssertEqual(try settingsJSON()["model"] as? String, "opus")
        XCTAssertTrue(try hookCommands(event: "Stop").contains("/usr/local/bin/their-own-hook"))
    }

    func testAFromSourceInstallIsNotDuplicatedAtTheBundlePath() throws {
        // Their busy hook names ~/.local/bin. Ours would name the bundle. Same
        // hook — deduped by binary name + argument, so the agent doesn't end up
        // reporting every prompt twice.
        try writeOldClaudeIntegration()

        XCTAssertEqual(reconcile([.claude])[.claude], .reconciled)

        XCTAssertEqual(try hookCommands(event: "UserPromptSubmit"), ["/x/.local/bin/cortland-agent-status busy"])
        XCTAssertEqual(
            try hookCommands(event: "Stop").filter { $0.contains("cortland-agent-status") },
            ["/x/.local/bin/cortland-agent-status done"]
        )
    }

    func testACurrentIntegrationIsNotRewrittenAtAll() throws {
        // The common launch: everything already current. The file must not be
        // touched — not reformatted, not re-serialized, not restamped.
        try writeOldClaudeIntegration()
        XCTAssertEqual(reconcile([.claude])[.claude], .reconciled)

        let after = try text(of: settingsURL)
        let modified = try fm.attributesOfItem(atPath: settingsURL.path)[.modificationDate] as? Date

        XCTAssertEqual(reconcile([.claude])[.claude], .upToDate)

        XCTAssertEqual(try text(of: settingsURL), after)
        XCTAssertEqual(
            try fm.attributesOfItem(atPath: settingsURL.path)[.modificationDate] as? Date,
            modified,
            "An up-to-date settings.json must not be rewritten on launch"
        )
    }

    func testReconciliationInstallsTheSkillTheIntegrationIsMissing() throws {
        // The skill is part of the integration the user opted into; an install
        // that predates it (or predates bundling it) is incomplete, not opted-out.
        try writeOldClaudeIntegration()

        XCTAssertEqual(reconcile([.claude])[.claude], .reconciled)

        let skill = home.appendingPathComponent(".claude/skills/cortland-panes/SKILL.md")
        XCTAssertEqual(try text(of: skill), "# SKILL\n")
    }

    // MARK: - Codex

    func testCodexGainsTheMissingEventAndKeepsItsConfig() throws {
        try write(
            """
            model = "gpt-5"

            [features]
            hooks = true

            [[hooks.UserPromptSubmit]]
            [[hooks.UserPromptSubmit.hooks]]
            type = "command"
            command = "/x/.local/bin/cortland-agent-status busy"
            """,
            to: codexConfigURL
        )

        XCTAssertEqual(reconcile([.codex])[.codex], .reconciled)

        let config = try text(of: codexConfigURL)
        XCTAssertTrue(config.contains("[[hooks.PreToolUse]]"))
        XCTAssertTrue(config.contains("cortland-telemetry"))
        XCTAssertTrue(config.contains(#"model = "gpt-5""#), "the user's own config must survive")
        // Their UserPromptSubmit hook is not duplicated by a second table naming
        // the bundle copy. (PreToolUse also reports "busy", so counting the word
        // across the file would prove nothing — this counts the *event*.)
        XCTAssertEqual(occurrences(of: "[[hooks.UserPromptSubmit]]", in: config), 1)
        XCTAssertEqual(occurrences(of: "/x/.local/bin/cortland-agent-status busy", in: config), 1)

        // Idempotent: a second launch finds nothing missing and appends nothing.
        XCTAssertEqual(reconcile([.codex])[.codex], .upToDate)
        XCTAssertEqual(try text(of: codexConfigURL), config)
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    func testCodexWithNothingOfOursIsNotTouched() throws {
        try write("model = \"gpt-5\"\n", to: codexConfigURL)
        let before = try text(of: codexConfigURL)

        XCTAssertEqual(reconcile([.codex])[.codex], .notInstalled)
        XCTAssertEqual(try text(of: codexConfigURL), before)
    }

    // MARK: - Pi

    func testPiExtensionIsBroughtUpToDate() throws {
        // A pre-telemetry extension: ours (so it reconciles), but stale.
        try write("// old cortland extension\n", to: piExtensionURL)

        XCTAssertEqual(reconcile([.pi])[.pi], .reconciled)

        let ext = try text(of: piExtensionURL)
        XCTAssertTrue(ext.contains("reportTelemetry"))
        XCTAssertTrue(ext.contains(helpers.appendingPathComponent("cortland-telemetry").path))
        // The current contract also routes file edits through the approval desk.
        XCTAssertTrue(ext.contains("show_diff"))
    }

    func testPiExtensionWithoutEditGateIsReconciled() throws {
        // A telemetry-era extension that predates the edit-gate: ours, but stale
        // because it never routes edits through the desk. Reconcile must add it.
        try write(
            "// cortland extension\nfunction reportTelemetry() {}\n",
            to: piExtensionURL
        )

        XCTAssertEqual(reconcile([.pi])[.pi], .reconciled)
        XCTAssertTrue(try text(of: piExtensionURL).contains("show_diff"))
    }

    func testPiWithoutTheExtensionIsNotTouched() throws {
        try fm.createDirectory(
            at: home.appendingPathComponent(".pi/agent"),
            withIntermediateDirectories: true
        )

        XCTAssertEqual(reconcile([.pi])[.pi], .notInstalled)
        XCTAssertFalse(fm.fileExists(atPath: piExtensionURL.path))
    }

    // MARK: - Gate

    func testAnXCTestRunIsNotTreatedAsAnInstalledApp() {
        // reconcileOnLaunch() is gated on running from a real .app, so nothing in
        // this suite could reach the developer's own ~/.claude even if it called it.
        XCTAssertFalse(InstalledHelperRefresher.isRunningFromAppBundle)
    }
}
