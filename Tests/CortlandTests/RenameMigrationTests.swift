import XCTest
@testable import Cortland

/// The one-way carry-over from the app's former name.
///
/// Two jobs, both of which only ever run against a machine that used the old
/// build: bring `~/.config/sidekick` across to `~/.config/cortland`, and take the
/// `sidekick-*` hook entries back out of the user's agent configs so a renamed
/// install doesn't report every event twice — once to a helper that no longer
/// exists.
///
/// Every test builds a temp home. The real `~/.config`, `~/.claude`, `~/.codex`,
/// and `~/.pi` are never touched.
final class RenameMigrationTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var legacy: URL!
    private var current: URL!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("sk-rename-\(UUID().uuidString)")
        legacy = root.appendingPathComponent(".config/sidekick", isDirectory: true)
        current = root.appendingPathComponent(".config/cortland", isDirectory: true)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    // MARK: - Helpers

    private func write(_ contents: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    private func migrate() -> Bool {
        ConfigMigration.migrateIfNeeded(from: legacy, to: current)
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: current.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Binds and closes a Unix socket, leaving the socket file on disk — exactly
    /// what the IPC server leaves in the config directory of everyone who has run
    /// the app.
    ///
    /// Bound by file name from inside the directory, because `sun_path` holds
    /// only 104 bytes and a temp-directory path plus a UUID overruns it.
    private func makeSocket(named name: String, in directory: URL) throws {
        let previousDirectory = fm.currentDirectoryPath
        XCTAssertTrue(fm.changeCurrentDirectoryPath(directory.path))
        defer { _ = fm.changeCurrentDirectoryPath(previousDirectory) }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        XCTAssertLessThan(name.utf8CString.count, maxPathLength)
        name.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
                _ = strncpy(destination, source, maxPathLength - 1)
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0)
    }

    // MARK: - Config directory

    func testTheOldConfigDirectoryIsCopiedOver() throws {
        try write("[appearance]\nfont_size = 14\n", to: legacy.appendingPathComponent("config.toml"))
        try write("# July\n", to: legacy.appendingPathComponent("journal/2026-07.md"))
        try write("{}", to: legacy.appendingPathComponent("themes/mine.json"))

        XCTAssertTrue(migrate())
        XCTAssertEqual(try contents("config.toml"), "[appearance]\nfont_size = 14\n")
        XCTAssertEqual(try contents("journal/2026-07.md"), "# July\n")
        XCTAssertEqual(try contents("themes/mine.json"), "{}")
    }

    func testTheOldDirectoryIsLeftWhereItIs() throws {
        // A copy, not a move: running the previous build afterwards must still
        // find its own files.
        try write("x", to: legacy.appendingPathComponent("config.toml"))

        XCTAssertTrue(migrate())
        XCTAssertTrue(fm.fileExists(atPath: legacy.appendingPathComponent("config.toml").path))
    }

    func testALiveSocketDoesNotSinkTheWholeMigration() throws {
        // Handing the whole directory to copyItem fails on the socket and leaves
        // an empty destination behind, which would disarm this on every later
        // launch having copied nothing. Everything else must still come across.
        try write("[appearance]\n", to: legacy.appendingPathComponent("config.toml"))
        try write("# grove\n", to: legacy.appendingPathComponent("grove.md"))
        try makeSocket(named: "sidekick.sock", in: legacy)

        XCTAssertTrue(migrate())
        XCTAssertEqual(try contents("config.toml"), "[appearance]\n")
        XCTAssertEqual(try contents("grove.md"), "# grove\n")
        XCTAssertFalse(fm.fileExists(atPath: current.appendingPathComponent("sidekick.sock").path))
    }

    func testASymlinkedConfigStaysASymlink() throws {
        // config.toml pointing into a dotfiles repo is a real setup; resolving it
        // into a plain file would quietly disconnect the user's own copy.
        let target = root.appendingPathComponent("dotfiles/config.toml")
        try write("[appearance]\n", to: target)
        try fm.createSymbolicLink(
            at: legacy.appendingPathComponent("config.toml"),
            withDestinationURL: target
        )

        XCTAssertTrue(migrate())
        let copied = current.appendingPathComponent("config.toml")
        let attributes = try fm.attributesOfItem(atPath: copied.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink)
        XCTAssertEqual(try String(contentsOf: copied, encoding: .utf8), "[appearance]\n")
    }

    func testAnExistingCortlandDirectoryIsNeverOverwritten() throws {
        try write("old", to: legacy.appendingPathComponent("config.toml"))
        try write("mine", to: current.appendingPathComponent("config.toml"))

        XCTAssertFalse(migrate())
        XCTAssertEqual(try contents("config.toml"), "mine")
    }

    func testAFreshInstallHasNothingToMigrate() throws {
        try fm.removeItem(at: legacy)

        XCTAssertFalse(migrate())
        XCTAssertFalse(fm.fileExists(atPath: current.path))
    }

    // MARK: - Claude hook entries

    func testLegacyClaudeHooksAreSweptFromEveryEvent() throws {
        var hooks: [String: Any] = [
            "UserPromptSubmit": [
                ["hooks": [["type": "command", "command": "/x/.local/bin/sidekick-agent-status busy"]]]
            ],
            "Stop": [
                ["hooks": [["type": "command", "command": "/x/.local/bin/sidekick-agent-status done"]]],
                ["hooks": [["type": "command", "command": "/x/.local/bin/sidekick-telemetry"]]],
                ["hooks": [["type": "command", "command": "/usr/local/bin/their-own-hook"]]]
            ],
            "PreToolUse": [
                ["hooks": [["type": "command", "command": "/x/sidekick-hook"]]]
            ]
        ]

        AgentIntegrationInstaller.removeLegacyHooks(from: &hooks)

        XCTAssertNil(hooks["UserPromptSubmit"])
        XCTAssertNil(hooks["PreToolUse"])
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        let commands = stop.flatMap { group in
            (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
        XCTAssertEqual(commands, ["/usr/local/bin/their-own-hook"])
    }

    func testTheCurrentHooksSurviveTheSweep() throws {
        var hooks: [String: Any] = [
            "Stop": [["hooks": [["type": "command", "command": "/A/Cortland.app/cortland-agent-status done"]]]]
        ]

        AgentIntegrationInstaller.removeLegacyHooks(from: &hooks)

        XCTAssertEqual((hooks["Stop"] as? [[String: Any]])?.count, 1)
    }

    // MARK: - Codex hook blocks

    func testLegacyCodexBlocksAreRemovedAndTheRestOfTheFileSurvives() {
        let config = """
        model = "gpt-5"

        [features]
        hooks = true

        [[hooks.UserPromptSubmit]]
        [[hooks.UserPromptSubmit.hooks]]
        type = "command"
        command = "/x/.local/bin/sidekick-agent-status busy"

        [[hooks.Stop]]
        [[hooks.Stop.hooks]]
        type = "command"
        command = "/x/.local/bin/their-own-hook"

        [tui]
        theme = "dark"
        """

        let result = AgentIntegrationInstaller.removeLegacyCodexHooks(from: config)

        XCTAssertFalse(result.contains("sidekick-agent-status"))
        XCTAssertFalse(result.contains("[[hooks.UserPromptSubmit]]"))
        XCTAssertTrue(result.contains("[[hooks.Stop]]"))
        XCTAssertTrue(result.contains("their-own-hook"))
        XCTAssertTrue(result.contains("model = \"gpt-5\""))
        XCTAssertTrue(result.contains("[tui]"))
        XCTAssertTrue(result.contains("theme = \"dark\""))
    }

    func testACodexConfigWithNothingLegacyIsUnchanged() {
        let config = """
        [features]
        hooks = true

        [[hooks.Stop]]
        [[hooks.Stop.hooks]]
        type = "command"
        command = "/A/Cortland.app/cortland-agent-status done"
        """

        XCTAssertEqual(AgentIntegrationInstaller.removeLegacyCodexHooks(from: config), config)
    }

    // MARK: - Adopting a pre-rename install on launch

    /// A temp home plus a temp "bundle" of fake helpers, so the reconcile under
    /// test never goes near the real `~/.claude` or `~/.pi`.
    private func makeBundle() throws -> (home: URL, helpers: URL) {
        let home = root.appendingPathComponent("home", isDirectory: true)
        let helpers = root.appendingPathComponent("Cortland.app/Contents/MacOS", isDirectory: true)
        try fm.createDirectory(at: helpers, withIntermediateDirectories: true)
        for helper in ["cortland-agent-status", "cortland-telemetry"] {
            let url = helpers.appendingPathComponent(helper)
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return (home, helpers)
    }

    func testAPreRenameClaudeInstallIsAdoptedAndItsOldEntriesRemoved() throws {
        // Read as "never opted in", this settings file would be left alone — and
        // the user would be left with an agents panel that never updates, because
        // the binary its hooks name no longer exists.
        let (home, helpers) = try makeBundle()
        let settings = home.appendingPathComponent(".claude/settings.json")
        try write(
            """
            {
              "model": "opus",
              "hooks": {
                "UserPromptSubmit": [
                  {"hooks": [{"type": "command", "command": "/x/.local/bin/sidekick-agent-status busy"}]}
                ],
                "Stop": [
                  {"hooks": [{"type": "command", "command": "/x/.local/bin/sidekick-agent-status done"}]}
                ]
              }
            }
            """,
            to: settings
        )

        let outcomes = AgentIntegrationInstaller.reconcile(
            home: home,
            helperDirectory: helpers,
            agents: [.claude],
            bundledSkill: nil
        )

        XCTAssertEqual(outcomes[.claude], .reconciled)
        let text = try String(contentsOf: settings, encoding: .utf8)
        XCTAssertFalse(text.contains("sidekick-agent-status"))
        XCTAssertTrue(text.contains("cortland-agent-status busy"))
        XCTAssertTrue(text.contains("cortland-agent-status done"))
        XCTAssertTrue(text.contains("\"model\""), "unrelated settings must survive")
    }

    func testAPreRenamePiExtensionIsReplacedRatherThanDoubledUp() throws {
        let (home, helpers) = try makeBundle()
        let legacyExtension = home.appendingPathComponent(".pi/agent/extensions/sidekick-status.ts")
        try write("// old extension\n", to: legacyExtension)

        let outcomes = AgentIntegrationInstaller.reconcile(
            home: home,
            helperDirectory: helpers,
            agents: [.pi],
            bundledSkill: nil
        )

        XCTAssertEqual(outcomes[.pi], .reconciled)
        XCTAssertFalse(fm.fileExists(atPath: legacyExtension.path))
        XCTAssertTrue(fm.fileExists(
            atPath: home.appendingPathComponent(".pi/agent/extensions/cortland-status.ts").path
        ))
    }

    // MARK: - Shell rc file

    @MainActor
    func testInstallingShellIntegrationReplacesThePreRenameStanza() throws {
        let zshrc = root.appendingPathComponent(".zshrc")
        try write(
            """
            export EDITOR=vim

            # Sidekick shell integration
            [[ "$TERM_PROGRAM" == "Sidekick" ]] && source "$HOME/.config/sidekick/shell-integration/sidekick.zsh"

            alias ll='ls -la'
            """,
            to: zshrc
        )

        XCTAssertTrue(try ShellIntegration.installInZshrc(at: zshrc))

        let updated = try String(contentsOf: zshrc, encoding: .utf8)
        XCTAssertFalse(updated.contains("shell-integration/sidekick.zsh"))
        XCTAssertFalse(updated.contains("# Sidekick shell integration"))
        XCTAssertTrue(updated.contains("shell-integration/cortland.zsh"))
        XCTAssertTrue(updated.contains("export EDITOR=vim"), "the user's own lines must survive")
        XCTAssertTrue(updated.contains("alias ll='ls -la'"))
    }

    @MainActor
    func testAZshrcWithNoPreRenameStanzaIsOnlyAppendedTo() throws {
        let zshrc = root.appendingPathComponent(".zshrc")
        let original = "export EDITOR=vim\nalias ll='ls -la'\n"
        try write(original, to: zshrc)

        XCTAssertTrue(try ShellIntegration.installInZshrc(at: zshrc))

        XCTAssertTrue(try String(contentsOf: zshrc, encoding: .utf8).hasPrefix(original))
    }

    // MARK: - Palette frontmatter

    func testSkillsTaggedUnderTheOldKeysStillReachThePalette() throws {
        // These keys are in files the user wrote. Nothing renames them, and a
        // skill that stops appearing gives no error to go on.
        let skill = PaletteSkillScanner.parse(
            """
            ---
            name: ship-it
            sidekick-palette: true
            sidekick-palette-label: Ship It
            sidekick-palette-submit: true
            ---

            # Ship it
            """,
            fallbackName: "ship-it"
        )

        XCTAssertEqual(skill, PaletteSkill(name: "ship-it", title: "Ship It", submit: true))
    }

    func testTheCurrentKeysWinOverTheOldOnes() throws {
        let skill = PaletteSkillScanner.parse(
            """
            ---
            name: ship-it
            sidekick-palette: true
            sidekick-palette-label: Old Label
            cortland-palette: true
            cortland-palette-label: New Label
            ---
            """,
            fallbackName: "ship-it"
        )

        XCTAssertEqual(skill?.title, "New Label")
    }

    // MARK: - Installed skill

    func testTheOldSkillDirectoryIsRemoved() throws {
        let skills = root.appendingPathComponent("skills", isDirectory: true)
        try write("# old\n", to: skills.appendingPathComponent("sidekick-panes/SKILL.md"))

        InstalledSkillRefresher.removeLegacySkill(from: skills)

        XCTAssertFalse(fm.fileExists(atPath: skills.appendingPathComponent("sidekick-panes").path))
    }

    func testASymlinkedOldSkillIsTheUsersOwnCheckoutAndStays() throws {
        let skills = root.appendingPathComponent("skills", isDirectory: true)
        let checkout = root.appendingPathComponent("checkout/sidekick-panes", isDirectory: true)
        try write("# theirs\n", to: checkout.appendingPathComponent("SKILL.md"))
        try fm.createDirectory(at: skills, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: skills.appendingPathComponent("sidekick-panes"),
            withDestinationURL: checkout
        )

        InstalledSkillRefresher.removeLegacySkill(from: skills)

        XCTAssertTrue(fm.fileExists(atPath: skills.appendingPathComponent("sidekick-panes/SKILL.md").path))
    }
}
