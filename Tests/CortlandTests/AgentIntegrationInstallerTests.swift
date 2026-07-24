import XCTest
@testable import Cortland

@MainActor
final class AgentIntegrationInstallerTests: XCTestCase {

    // MARK: - Claude hook merging

    private func hookCommands(_ hooks: [String: Any], event: String) -> [String] {
        (hooks[event] as? [[String: Any]] ?? []).flatMap { group in
            (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }

    func testAddClaudeHookToEmptyConfig() {
        var hooks: [String: Any] = [:]
        AgentIntegrationInstaller.addClaudeHook(to: &hooks, event: "Stop", command: "/a/cortland-agent-status done")

        XCTAssertEqual(hookCommands(hooks, event: "Stop"), ["/a/cortland-agent-status done"])
    }

    func testAddClaudeHookSkipsExactDuplicate() {
        var hooks: [String: Any] = [:]
        AgentIntegrationInstaller.addClaudeHook(to: &hooks, event: "Stop", command: "/a/cortland-agent-status done")
        AgentIntegrationInstaller.addClaudeHook(to: &hooks, event: "Stop", command: "/a/cortland-agent-status done")

        XCTAssertEqual(hookCommands(hooks, event: "Stop").count, 1)
    }

    func testAddClaudeHookSkipsSamePayloadAtDifferentPath() {
        // A from-source install at ~/.local/bin must satisfy the bundle
        // installer, not get duplicated.
        var hooks: [String: Any] = [
            "Stop": [["hooks": [["type": "command", "command": "/Users/x/.local/bin/cortland-agent-status done"]]]]
        ]
        AgentIntegrationInstaller.addClaudeHook(
            to: &hooks,
            event: "Stop",
            command: "/Applications/Cortland.app/Contents/MacOS/cortland-agent-status done"
        )

        XCTAssertEqual(hookCommands(hooks, event: "Stop").count, 1)
    }

    func testTelemetryStopHookCoexistsWithStatusStopHook() {
        // The telemetry Stop hook keys on a different binary name, so it must
        // sit alongside the agent-status Stop hook rather than dedup against it.
        var hooks: [String: Any] = [:]
        AgentIntegrationInstaller.addClaudeHook(to: &hooks, event: "Stop", command: "/a/cortland-agent-status done")
        AgentIntegrationInstaller.addClaudeHook(to: &hooks, event: "Stop", command: "/a/cortland-telemetry")
        // Re-adding telemetry must not duplicate it.
        AgentIntegrationInstaller.addClaudeHook(to: &hooks, event: "Stop", command: "/a/cortland-telemetry")

        let commands = hookCommands(hooks, event: "Stop")
        XCTAssertEqual(commands.count, 2)
        XCTAssertTrue(commands.contains("/a/cortland-agent-status done"))
        XCTAssertTrue(commands.contains("/a/cortland-telemetry"))
    }

    func testAddClaudeHookPreservesForeignHooksAndAddsMatcher() {
        var hooks: [String: Any] = [
            "PreToolUse": [["hooks": [["type": "command", "command": "/usr/local/bin/some-other-hook"]]]]
        ]
        AgentIntegrationInstaller.addClaudeHook(
            to: &hooks,
            event: "PreToolUse",
            command: "/a/cortland-hook",
            matcher: "Write|Edit|MultiEdit"
        )

        let groups = hooks["PreToolUse"] as? [[String: Any]] ?? []
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[1]["matcher"] as? String, "Write|Edit|MultiEdit")
        XCTAssertEqual(hookCommands(hooks, event: "PreToolUse").first, "/usr/local/bin/some-other-hook")
    }

    func testAddClaudeHookWritesTimeoutWhenGiven() {
        var hooks: [String: Any] = [:]
        AgentIntegrationInstaller.addClaudeHook(
            to: &hooks, event: "PreToolUse",
            command: "/a/cortland-agent-status edit-gate",
            matcher: "Edit|Write",
            timeoutSeconds: 600
        )

        let groups = hooks["PreToolUse"] as? [[String: Any]] ?? []
        XCTAssertEqual(groups.first?["matcher"] as? String, "Edit|Write")
        let hook = (groups.first?["hooks"] as? [[String: Any]])?.first
        XCTAssertEqual(hook?["timeout"] as? Int, 600)
    }

    func testEditGateHookCoexistsWithBusyStatusHook() {
        // Same binary, different argument: the edit-gate entry must sit
        // alongside the PreToolUse busy status hook, not dedup against it —
        // and re-adding either must not duplicate it.
        var hooks: [String: Any] = [:]
        AgentIntegrationInstaller.addClaudeHook(
            to: &hooks, event: "PreToolUse", command: "/a/cortland-agent-status busy")
        AgentIntegrationInstaller.addClaudeHook(
            to: &hooks, event: "PreToolUse",
            command: "/a/cortland-agent-status edit-gate",
            matcher: "Edit|Write", timeoutSeconds: 600)
        AgentIntegrationInstaller.addClaudeHook(
            to: &hooks, event: "PreToolUse",
            command: "/a/cortland-agent-status edit-gate",
            matcher: "Edit|Write", timeoutSeconds: 600)

        let commands = hookCommands(hooks, event: "PreToolUse")
        XCTAssertEqual(commands.count, 2)
        XCTAssertTrue(commands.contains("/a/cortland-agent-status busy"))
        XCTAssertTrue(commands.contains("/a/cortland-agent-status edit-gate"))
    }

    func testShellQuotedIfNeededLeavesPlainPathsAlone() {
        XCTAssertEqual(
            AgentIntegrationInstaller.shellQuotedIfNeeded("/Applications/Cortland.app/Contents/MacOS/cortland-agent-status"),
            "/Applications/Cortland.app/Contents/MacOS/cortland-agent-status"
        )
    }

    func testShellQuotedIfNeededQuotesPathWithSpace() {
        XCTAssertEqual(
            AgentIntegrationInstaller.shellQuotedIfNeeded("/Applications/My Apps/Cortland.app/Contents/MacOS/cortland-agent-status"),
            "'/Applications/My Apps/Cortland.app/Contents/MacOS/cortland-agent-status'"
        )
    }

    func testShellQuotedIfNeededEscapesEmbeddedSingleQuote() {
        XCTAssertEqual(
            AgentIntegrationInstaller.shellQuotedIfNeeded("/Users/o'brien/Apps/cortland-agent-status"),
            "'/Users/o'\\''brien/Apps/cortland-agent-status'"
        )
    }

    func testAddClaudeHookDedupsQuotedAgainstUnquotedInstall() {
        // Upgrading from an unquoted install to a quoted one (bundle moved to
        // a path with a space) must not double-register the hook.
        var hooks: [String: Any] = [
            "Stop": [["hooks": [["type": "command", "command": "/Users/x/.local/bin/cortland-agent-status done"]]]]
        ]
        AgentIntegrationInstaller.addClaudeHook(
            to: &hooks,
            event: "Stop",
            command: "'/Applications/My Apps/Cortland.app/Contents/MacOS/cortland-agent-status' done"
        )

        XCTAssertEqual(hookCommands(hooks, event: "Stop").count, 1)
    }

    func testAddClaudeHookSkipsExactQuotedDuplicate() {
        var hooks: [String: Any] = [:]
        let quoted = "'/Applications/My Apps/Cortland.app/Contents/MacOS/cortland-agent-status' done"
        AgentIntegrationInstaller.addClaudeHook(to: &hooks, event: "Stop", command: quoted)
        AgentIntegrationInstaller.addClaudeHook(to: &hooks, event: "Stop", command: quoted)

        XCTAssertEqual(hookCommands(hooks, event: "Stop").count, 1)
    }

    func testRemoveClaudeHookStripsDeadPermissionRequestHook() {
        // A previous version registered a "PermissionRequest" ready hook, an
        // event Claude Code never fires. Reinstalling must remove it.
        var hooks: [String: Any] = [
            "PermissionRequest": [["hooks": [["type": "command", "command": "/a/cortland-agent-status ready"]]]],
            "Notification": [["hooks": [["type": "command", "command": "/a/cortland-agent-status ready"]]]]
        ]
        AgentIntegrationInstaller.removeClaudeHook(from: &hooks, event: "PermissionRequest", signature: "cortland-agent-status")

        XCTAssertNil(hooks["PermissionRequest"])
        // The valid Notification hook (same binary) is untouched.
        XCTAssertEqual(hookCommands(hooks, event: "Notification"), ["/a/cortland-agent-status ready"])
    }

    // MARK: - Claude auto-approve permission mode

    func testAutoApproveSetsAcceptEditsOnEmptySettings() {
        var settings: [String: Any] = [:]
        let changed = AgentIntegrationInstaller.applyAutoApproveMode(to: &settings, desiredMode: "acceptEdits")

        XCTAssertTrue(changed)
        let permissions = settings["permissions"] as? [String: Any]
        XCTAssertEqual(permissions?["defaultMode"] as? String, "acceptEdits")
    }

    func testAutoApprovePreservesOtherPermissionKeys() {
        var settings: [String: Any] = ["permissions": ["allow": ["Edit"]]]
        _ = AgentIntegrationInstaller.applyAutoApproveMode(to: &settings, desiredMode: "acceptEdits")

        let permissions = settings["permissions"] as? [String: Any]
        XCTAssertEqual(permissions?["defaultMode"] as? String, "acceptEdits")
        XCTAssertEqual(permissions?["allow"] as? [String], ["Edit"])
    }

    func testAutoApproveNoOpWhenAlreadyAcceptEdits() {
        var settings: [String: Any] = ["permissions": ["defaultMode": "acceptEdits"]]
        XCTAssertFalse(AgentIntegrationInstaller.applyAutoApproveMode(to: &settings, desiredMode: "acceptEdits"))
    }

    func testAcceptEditsLeavesBroaderBypassMode() {
        // bypassPermissions already auto-approves edits; don't downgrade it.
        var settings: [String: Any] = ["permissions": ["defaultMode": "bypassPermissions"]]
        XCTAssertFalse(AgentIntegrationInstaller.applyAutoApproveMode(to: &settings, desiredMode: "acceptEdits"))
        let permissions = settings["permissions"] as? [String: Any]
        XCTAssertEqual(permissions?["defaultMode"] as? String, "bypassPermissions")
    }

    func testBypassSetsBypassPermissions() {
        var settings: [String: Any] = [:]
        let changed = AgentIntegrationInstaller.applyAutoApproveMode(to: &settings, desiredMode: "bypassPermissions")

        XCTAssertTrue(changed)
        let permissions = settings["permissions"] as? [String: Any]
        XCTAssertEqual(permissions?["defaultMode"] as? String, "bypassPermissions")
    }

    func testBypassUpgradesFromAcceptEdits() {
        // Asking for full bypass while on acceptEdits must upgrade, not no-op.
        var settings: [String: Any] = ["permissions": ["defaultMode": "acceptEdits"]]
        let changed = AgentIntegrationInstaller.applyAutoApproveMode(to: &settings, desiredMode: "bypassPermissions")

        XCTAssertTrue(changed)
        let permissions = settings["permissions"] as? [String: Any]
        XCTAssertEqual(permissions?["defaultMode"] as? String, "bypassPermissions")
    }

    func testClaudePermissionModeMapsApprovalLevels() {
        XCTAssertNil(AgentIntegrationInstaller.claudePermissionMode(forApprovalMode: "ask"))
        XCTAssertNil(AgentIntegrationInstaller.claudePermissionMode(forApprovalMode: "unknown"))
        XCTAssertEqual(AgentIntegrationInstaller.claudePermissionMode(forApprovalMode: "auto"), "acceptEdits")
        XCTAssertEqual(AgentIntegrationInstaller.claudePermissionMode(forApprovalMode: "review"), "auto")
        // Backwards compatibility for configs written before the shared name.
        XCTAssertEqual(AgentIntegrationInstaller.claudePermissionMode(forApprovalMode: "claude-auto"), "auto")
        // Without a managed disable policy, bypass maps straight through. (The
        // managed-disable fallback to acceptEdits depends on a system file and
        // isn't exercised here.)
        XCTAssertEqual(AgentIntegrationInstaller.claudePermissionMode(forApprovalMode: "bypass"), "bypassPermissions")
    }

    // MARK: - Codex scoped approval flags

    func testCodexApprovalFlagsMapApprovalLevels() {
        let ask = [
            "--sandbox", "read-only", "--ask-for-approval", "on-request",
            "-c", "approvals_reviewer=user"
        ]
        XCTAssertEqual(AgentIntegrationInstaller.codexApprovalFlags(forApprovalMode: "ask"), ask)
        XCTAssertEqual(AgentIntegrationInstaller.codexApprovalFlags(forApprovalMode: "unknown"), ask)
        XCTAssertEqual(
            AgentIntegrationInstaller.codexApprovalFlags(forApprovalMode: "auto"),
            [
                "--sandbox", "workspace-write", "--ask-for-approval", "on-request",
                "-c", "approvals_reviewer=user"
            ]
        )
        let reviewed = [
            "--sandbox", "workspace-write", "--ask-for-approval", "on-request",
            "-c", "approvals_reviewer=auto_review"
        ]
        XCTAssertEqual(
            AgentIntegrationInstaller.codexApprovalFlags(forApprovalMode: "review"),
            reviewed
        )
        XCTAssertEqual(
            AgentIntegrationInstaller.codexApprovalFlags(forApprovalMode: "claude-auto"),
            reviewed
        )
        XCTAssertEqual(
            AgentIntegrationInstaller.codexApprovalFlags(forApprovalMode: "bypass"),
            ["--sandbox", "danger-full-access", "--ask-for-approval", "never"]
        )
    }

    func testCodexApprovalFlagsMatchTheConfigKeyMapping() {
        // The scoped CLI flags and the (legacy) config-key form must agree so a
        // pane launched with the flags behaves like the old global write did.
        let autoConfig = AgentIntegrationInstaller.applyCodexAutoApprove(to: "", mode: "auto")
        let autoFlags = AgentIntegrationInstaller.codexApprovalFlags(forApprovalMode: "auto")
        XCTAssertEqual(codexValue(autoConfig, "sandbox_mode"), autoFlags[1])
        XCTAssertEqual(codexValue(autoConfig, "approval_policy"), autoFlags[3])
    }

    func testCodexApprovalFlagNamesCoverCallerOverrides() {
        // Every flag the shell wrapper / argv injector treats as a caller's own
        // choice must be recognized so Cortland's flags don't double up.
        for flag in ["--sandbox", "-s", "--ask-for-approval", "-a", "--full-auto", "--yolo",
                     "--dangerously-bypass-approvals-and-sandbox"] {
            XCTAssertTrue(
                AgentIntegrationInstaller.codexApprovalFlagNames.contains(flag),
                "expected \(flag) to be recognized as a caller override"
            )
        }
        for flag in ["--sandbox=read-only", "--ask-for-approval=never", "-s=workspace-write", "-a=never"] {
            XCTAssertTrue(AgentIntegrationInstaller.isCodexApprovalOverride(flag))
        }
        XCTAssertFalse(AgentIntegrationInstaller.isCodexApprovalOverride("-c"))
        // Every other `-c` value is a config Cortland has no opinion about.
        XCTAssertFalse(AgentIntegrationInstaller.isCodexApprovalOverride("model=gpt-5"))
        // `approvals_reviewer` is a config VALUE, not a flag: it only overrides
        // as part of a pair — see the command-level check.
        XCTAssertFalse(AgentIntegrationInstaller.isCodexApprovalOverride("approvals_reviewer=user"))
    }

    /// A caller's own `approvals_reviewer` takes approval control the way a
    /// sandbox flag does, but only where Codex reads it as config.
    func testCommandContainsCodexReviewerOverrideNeedsAConfigFlag() {
        for command in [
            ["codex", "-c", "approvals_reviewer=user"],
            ["codex", "--config", "approvals_reviewer=auto_review"],
            ["codex", "-c=approvals_reviewer=user"],
            ["codex", "--config=approvals_reviewer=auto_review"],
            ["codex", "exec", "-c", "approvals_reviewer=user", "do the thing"]
        ] {
            XCTAssertTrue(AgentIntegrationInstaller.commandContainsCodexReviewerOverride(command),
                          "expected \(command) to be recognized as a caller override")
        }
        for command in [
            // Prompt text that merely talks about the setting.
            ["codex", "exec", "approvals_reviewer=auto_review behaves incorrectly"],
            ["codex", "approvals_reviewer=user"],
            // The pair has to be adjacent; another config value sits between here.
            ["codex", "-c", "model=gpt-5", "approvals_reviewer=user"],
            ["codex", "-c", "approvals_reviewer_note=hi"],
            ["codex", "-c", "model=gpt-5"],
            ["codex"]
        ] {
            XCTAssertFalse(AgentIntegrationInstaller.commandContainsCodexReviewerOverride(command),
                           "expected \(command) NOT to be recognized as a caller override")
        }
    }

    func testDisableRemovesManagedAcceptEditsMode() {
        var settings: [String: Any] = ["permissions": ["defaultMode": "acceptEdits"]]
        let changed = AgentIntegrationInstaller.applyAutoApproveMode(to: &settings, desiredMode: nil)

        XCTAssertTrue(changed)
        // The permissions table is dropped once it's empty.
        XCTAssertNil(settings["permissions"])
    }

    func testDisableRemovesManagedBypassMode() {
        var settings: [String: Any] = ["permissions": ["defaultMode": "bypassPermissions"]]
        let changed = AgentIntegrationInstaller.applyAutoApproveMode(to: &settings, desiredMode: nil)

        XCTAssertTrue(changed)
        XCTAssertNil(settings["permissions"])
    }

    func testDisablePreservesUnmanagedMode() {
        // We never set "plan"; turning prompting back on must not touch it.
        var settings: [String: Any] = ["permissions": ["defaultMode": "plan"]]
        XCTAssertFalse(AgentIntegrationInstaller.applyAutoApproveMode(to: &settings, desiredMode: nil))
        let permissions = settings["permissions"] as? [String: Any]
        XCTAssertEqual(permissions?["defaultMode"] as? String, "plan")
    }

    func testDisableKeepsSiblingPermissionKeys() {
        var settings: [String: Any] = ["permissions": ["defaultMode": "acceptEdits", "allow": ["Edit"]]]
        let changed = AgentIntegrationInstaller.applyAutoApproveMode(to: &settings, desiredMode: nil)

        XCTAssertTrue(changed)
        let permissions = settings["permissions"] as? [String: Any]
        XCTAssertNil(permissions?["defaultMode"])
        XCTAssertEqual(permissions?["allow"] as? [String], ["Edit"])
    }

    // MARK: - Codex auto-approve policy/sandbox keys

    private func codexValue(_ config: String, _ key: String) -> String? {
        for line in config.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("\(key) ") || t.hasPrefix("\(key)=") {
                return t.components(separatedBy: "=").last?
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return nil
    }

    func testCodexAutoSetsWorkspaceWriteOnRequest() {
        let result = AgentIntegrationInstaller.applyCodexAutoApprove(to: "", mode: "auto")
        XCTAssertEqual(codexValue(result, "sandbox_mode"), "workspace-write")
        XCTAssertEqual(codexValue(result, "approval_policy"), "on-request")
    }

    func testCodexBypassSetsDangerFullAccessNever() {
        let result = AgentIntegrationInstaller.applyCodexAutoApprove(to: "", mode: "bypass")
        XCTAssertEqual(codexValue(result, "sandbox_mode"), "danger-full-access")
        XCTAssertEqual(codexValue(result, "approval_policy"), "never")
    }

    func testCodexKeysInsertedAheadOfTables() {
        let config = """
        [features]
        hooks = true
        """
        let result = AgentIntegrationInstaller.applyCodexAutoApprove(to: config, mode: "auto")
        // Top-level scalars must precede the first table header to stay top-level.
        XCTAssertLessThan(
            result.range(of: "sandbox_mode")!.lowerBound,
            result.range(of: "[features]")!.lowerBound
        )
        XCTAssertTrue(result.contains("hooks = true"))
    }

    func testCodexAutoReplacesExistingKeysNoDuplicates() {
        let config = """
        sandbox_mode = "read-only"
        approval_policy = "untrusted"

        [features]
        hooks = true
        """
        let result = AgentIntegrationInstaller.applyCodexAutoApprove(to: config, mode: "bypass")
        XCTAssertEqual(codexValue(result, "sandbox_mode"), "danger-full-access")
        XCTAssertEqual(codexValue(result, "approval_policy"), "never")
        // Replaced in place, not appended.
        let occurrences = result.components(separatedBy: "sandbox_mode").count - 1
        XCTAssertEqual(occurrences, 1)
    }

    func testCodexAskRemovesOnlyOurManagedCombo() {
        let config = """
        sandbox_mode = "workspace-write"
        approval_policy = "on-request"

        [features]
        hooks = true
        """
        let result = AgentIntegrationInstaller.applyCodexAutoApprove(to: config, mode: "ask")
        XCTAssertNil(codexValue(result, "sandbox_mode"))
        XCTAssertNil(codexValue(result, "approval_policy"))
        XCTAssertTrue(result.contains("hooks = true"))
    }

    func testCodexAskPreservesUserPickedPolicy() {
        // read-only/untrusted is not a combo we set, so leave it alone.
        let config = """
        sandbox_mode = "read-only"
        approval_policy = "untrusted"
        """
        let result = AgentIntegrationInstaller.applyCodexAutoApprove(to: config, mode: "ask")
        XCTAssertEqual(codexValue(result, "sandbox_mode"), "read-only")
        XCTAssertEqual(codexValue(result, "approval_policy"), "untrusted")
    }

    func testCodexDoesNotTouchKeysInsideTables() {
        // A key named like ours but inside a table is not top-level — leave it.
        let config = """
        [some_table]
        sandbox_mode = "read-only"
        """
        let result = AgentIntegrationInstaller.applyCodexAutoApprove(to: config, mode: "ask")
        XCTAssertTrue(result.contains("[some_table]"))
        XCTAssertTrue(result.contains("sandbox_mode = \"read-only\""))
    }

    // MARK: - Codex TOML features section

    func testCodexHooksEnabledAddedToEmptyConfig() {
        let result = AgentIntegrationInstaller.ensureCodexHooksEnabled(in: "")
        XCTAssertTrue(result.contains("[features]"))
        XCTAssertTrue(result.contains("hooks = true"))
    }

    func testCodexFeaturesInsertedBeforeFirstTableToKeepTopLevelKeys() {
        let config = """
        model = "gpt-5.5"

        [projects."/Users/x"]
        trust_level = "trusted"
        """
        let result = AgentIntegrationInstaller.ensureCodexHooksEnabled(in: config)

        let featuresRange = result.range(of: "[features]")
        let projectsRange = result.range(of: "[projects.")
        XCTAssertNotNil(featuresRange)
        XCTAssertNotNil(projectsRange)
        XCTAssertLessThan(featuresRange!.lowerBound, projectsRange!.lowerBound)
        // Top-level key must still come before any table header.
        XCTAssertLessThan(result.range(of: "model = ")!.lowerBound, featuresRange!.lowerBound)
    }

    func testCodexExistingFeaturesSectionGainsHooksKey() {
        let config = """
        [features]
        something = 1

        [other]
        key = 2
        """
        let result = AgentIntegrationInstaller.ensureCodexHooksEnabled(in: config)

        XCTAssertTrue(result.contains("hooks = true"))
        // Inserted inside [features], not into [other].
        let hooksRange = result.range(of: "hooks = true")!
        let otherRange = result.range(of: "[other]")!
        XCTAssertLessThan(hooksRange.lowerBound, otherRange.lowerBound)
    }

    func testCodexHooksFalseFlippedToTrue() {
        let config = """
        [features]
        hooks = false
        """
        let result = AgentIntegrationInstaller.ensureCodexHooksEnabled(in: config)

        XCTAssertTrue(result.contains("hooks = true"))
        XCTAssertFalse(result.contains("hooks = false"))
    }
}
