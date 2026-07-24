import XCTest
@testable import Cortland

/// Self-healing the installed `cortland-panes` skill on app launch.
///
/// The skill teaches agents how to drive Cortland's panes. An installer copies it
/// into `~/.claude/skills` (and Codex's, and Pi's) once; nothing updated it after
/// that, so an upgraded app could be read by agents following months-old
/// instructions — quietly, because a wrong instruction just produces a wrong tool
/// call, not an error.
///
/// Every test here works in a temp directory. The real `~/.claude`, `~/.codex`,
/// and `~/.pi` are never touched.
final class InstalledSkillRefreshTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var bundled: URL!
    private var skillsRoot: URL!

    /// `<skillsRoot>/cortland-panes`, the directory an installer of ours owns.
    private var installed: URL { skillsRoot.appendingPathComponent("cortland-panes") }

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("sk-skills-\(UUID().uuidString)")
        bundled = root.appendingPathComponent("Cortland.app/Contents/Resources/skills/cortland-panes")
        skillsRoot = root.appendingPathComponent("home/.claude/skills")
        try fm.createDirectory(at: bundled.appendingPathComponent("agents"), withIntermediateDirectories: true)
        try fm.createDirectory(at: skillsRoot, withIntermediateDirectories: true)
        try write("# SKILL v2\n", to: bundled.appendingPathComponent("SKILL.md"))
        try write("name: v2\n", to: bundled.appendingPathComponent("agents/openai.yaml"))
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    // MARK: - Helpers

    private func write(_ contents: String, to url: URL, permissions: Int = 0o644) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private func contents(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func refresh() -> InstalledSkillRefresher.Outcome? {
        InstalledSkillRefresher.refresh(
            bundledSkillDirectory: bundled,
            installRoots: [skillsRoot]
        )[skillsRoot.path]
    }

    /// An install as `scripts/install-agent-status-hooks` leaves it, one version behind.
    private func installStaleSkill() throws {
        try write("# SKILL v1\n", to: installed.appendingPathComponent("SKILL.md"))
        try write("name: v1\n", to: installed.appendingPathComponent("agents/openai.yaml"))
    }

    // MARK: - Differs → replaced

    func testStaleSkillFilesAreReplacedWithTheBundledCopies() throws {
        try installStaleSkill()

        XCTAssertEqual(refresh(), .refreshed)
        XCTAssertEqual(try contents(of: installed.appendingPathComponent("SKILL.md")), "# SKILL v2\n")
        XCTAssertEqual(try contents(of: installed.appendingPathComponent("agents/openai.yaml")), "name: v2\n")
    }

    func testRefreshedFilesStayReadable() throws {
        try installStaleSkill()

        XCTAssertEqual(refresh(), .refreshed)
        let attributes = try fm.attributesOfItem(atPath: installed.appendingPathComponent("SKILL.md").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o644)
    }

    func testReplacementLeavesNoTempFilesBehind() throws {
        // The swap is a rename(2) over the destination — an agent reading the
        // skill mid-refresh sees the whole old file or the whole new one.
        try installStaleSkill()

        XCTAssertEqual(refresh(), .refreshed)
        XCTAssertEqual(
            try fm.contentsOfDirectory(atPath: installed.path).sorted(),
            ["SKILL.md", "agents"]
        )
    }

    func testFileAddedByAnUpgradeIsCreatedInsideAnExistingInstall() throws {
        // An older install predates agents/openai.yaml. The skill *directory*
        // exists, so completing it is a refresh, not a new opt-in — this is
        // exactly what "the shipped skill gained a file" looks like on disk.
        try write("# SKILL v1\n", to: installed.appendingPathComponent("SKILL.md"))

        XCTAssertEqual(refresh(), .refreshed)
        XCTAssertEqual(try contents(of: installed.appendingPathComponent("agents/openai.yaml")), "name: v2\n")
    }

    // MARK: - Same → untouched

    func testIdenticalSkillIsLeftAlone() throws {
        try write("# SKILL v2\n", to: installed.appendingPathComponent("SKILL.md"))
        try write("name: v2\n", to: installed.appendingPathComponent("agents/openai.yaml"))
        let file = installed.appendingPathComponent("SKILL.md")
        let before = try fm.attributesOfItem(atPath: file.path)[.modificationDate] as? Date

        XCTAssertEqual(refresh(), .upToDate)

        let after = try fm.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after, "An up-to-date skill must not be rewritten")
    }

    func testFilesWeDoNotShipAreLeftAlone() throws {
        // Only the files the skill is made of are managed; anything else the user
        // keeps in that directory is theirs.
        try installStaleSkill()
        let theirs = installed.appendingPathComponent("NOTES.md")
        try write("my notes\n", to: theirs)

        XCTAssertEqual(refresh(), .refreshed)
        XCTAssertEqual(try contents(of: theirs), "my notes\n")
    }

    // MARK: - Absent → not created

    func testAbsentSkillIsNotInstalled() throws {
        // No cortland-panes in this root: the user never installed the skill for
        // this agent. A refresh maintains; it does not opt anyone in.
        XCTAssertEqual(refresh(), .notInstalled)
        XCTAssertFalse(fm.fileExists(atPath: installed.path))
    }

    func testMissingSkillsRootIsNotCreated() throws {
        try fm.removeItem(at: skillsRoot)

        XCTAssertEqual(refresh(), .notInstalled)
        XCTAssertFalse(fm.fileExists(atPath: skillsRoot.path))
    }

    func testSymlinkedSkillIsLeftAlone() throws {
        // A symlink is the user pointing an agent at their own checkout.
        let theirs = root.appendingPathComponent("their-skill")
        try write("# theirs\n", to: theirs.appendingPathComponent("SKILL.md"))
        try fm.createSymbolicLink(at: installed, withDestinationURL: theirs)

        XCTAssertEqual(refresh(), .skippedSymlink)
        XCTAssertEqual(try contents(of: theirs.appendingPathComponent("SKILL.md")), "# theirs\n")
    }

    // MARK: - Scope

    func testEachRootIsRefreshedIndependently() throws {
        let codexRoot = root.appendingPathComponent("home/.codex/skills")
        try fm.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try installStaleSkill()
        // Codex never had the skill installed; that must not stop Claude's copy
        // from being refreshed.

        let outcomes = InstalledSkillRefresher.refresh(
            bundledSkillDirectory: bundled,
            installRoots: [skillsRoot, codexRoot]
        )
        XCTAssertEqual(outcomes[skillsRoot.path], .refreshed)
        XCTAssertEqual(outcomes[codexRoot.path], .notInstalled)
        XCTAssertEqual(try contents(of: installed.appendingPathComponent("SKILL.md")), "# SKILL v2\n")
    }

    func testDefaultInstallRootsCoverEveryAgentThatLoadsSkills() {
        let home = URL(fileURLWithPath: "/home/x")
        XCTAssertEqual(
            InstalledSkillRefresher.defaultInstallRoots(home: home).map(\.path),
            ["/home/x/.claude/skills", "/home/x/.codex/skills", "/home/x/.pi/agent/skills"]
        )
    }

    // MARK: - First-time install (the opt-in path)

    func testInstallCreatesTheSkill() throws {
        try InstalledSkillRefresher.install(into: skillsRoot, bundledSkillDirectory: bundled)

        XCTAssertEqual(try contents(of: installed.appendingPathComponent("SKILL.md")), "# SKILL v2\n")
        XCTAssertEqual(try contents(of: installed.appendingPathComponent("agents/openai.yaml")), "name: v2\n")
    }

    func testInstallWithoutABundledSkillIsANoOp() throws {
        // A build that doesn't ship the skill must still be able to install the
        // hooks, and must not leave an empty skill directory behind.
        try InstalledSkillRefresher.install(into: skillsRoot, bundledSkillDirectory: nil)

        XCTAssertFalse(fm.fileExists(atPath: installed.path))
    }
}
