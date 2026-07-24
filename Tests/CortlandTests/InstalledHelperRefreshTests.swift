import XCTest
@testable import Cortland

/// Self-healing the helper binaries in `~/.local/bin` on app launch.
///
/// `scripts/install-agent-status-hooks` copies `cortland-agent-status` and
/// `cortland-mcp` there once and writes hooks naming those absolute paths;
/// nothing ever updated them again, so an app upgrade left the hooks running
/// weeks-old binaries — silently, because a hook that can't reach Cortland exits
/// 0 rather than disturb the agent.
///
/// Every test here works in a temp directory. The real `~/.local/bin` and
/// `~/.claude/settings.json` are never touched.
final class InstalledHelperRefreshTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var bundleDirectory: URL!
    private var installDirectory: URL!

    private let helper = "cortland-agent-status"

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("sk-helpers-\(UUID().uuidString)")
        bundleDirectory = root.appendingPathComponent("Cortland.app/Contents/MacOS")
        installDirectory = root.appendingPathComponent("local/bin")
        try fm.createDirectory(at: bundleDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: installDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    // MARK: - Helpers

    @discardableResult
    private func writeBundled(_ contents: String, named name: String? = nil) throws -> URL {
        let url = bundleDirectory.appendingPathComponent(name ?? helper)
        try Data(contents.utf8).write(to: url)
        return url
    }

    @discardableResult
    private func writeInstalled(_ contents: String, permissions: Int = 0o755, named name: String? = nil) throws -> URL {
        let url = installDirectory.appendingPathComponent(name ?? helper)
        try Data(contents.utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        return url
    }

    private func refresh(_ helpers: [String]? = nil) -> [String: InstalledHelperRefresher.Outcome] {
        InstalledHelperRefresher.refresh(
            bundleDirectory: bundleDirectory,
            installDirectory: installDirectory,
            helpers: helpers ?? [helper]
        )
    }

    private func contents(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try fm.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }

    // MARK: - Differs → replaced

    func testStaleHelperIsReplacedWithTheBundledCopy() throws {
        try writeBundled("v2-current-build")
        let installed = try writeInstalled("v1-ten-days-stale")

        XCTAssertEqual(refresh()[helper], .refreshed)
        XCTAssertEqual(try contents(of: installed), "v2-current-build")
    }

    func testRefreshedHelperStaysExecutable() throws {
        // The hooks exec this path. A refreshed copy that lost its +x would turn
        // a stale-status bug into a no-status-at-all bug.
        try writeBundled("v2-current-build")
        let installed = try writeInstalled("v1-stale", permissions: 0o755)

        XCTAssertEqual(refresh()[helper], .refreshed)
        XCTAssertEqual(try permissions(of: installed), 0o755)
    }

    func testReplacementIsAtomicAndLeavesNoTempFilesBehind() throws {
        // The swap is a rename(2) over the destination, so a hook firing mid-
        // replace execs either the old inode or the new one — never a partial
        // binary. Observable here as: same path (not a new one), no leftovers.
        try writeBundled("v2-current-build")
        let installed = try writeInstalled("v1-stale")

        XCTAssertEqual(refresh()[helper], .refreshed)

        let entries = try fm.contentsOfDirectory(atPath: installDirectory.path)
        XCTAssertEqual(entries, [helper], "The temp file must be renamed into place, not left alongside")
        XCTAssertTrue(fm.isExecutableFile(atPath: installed.path))
    }

    // MARK: - Same → untouched

    func testIdenticalHelperIsLeftAlone() throws {
        try writeBundled("same-bytes")
        let installed = try writeInstalled("same-bytes")
        let before = try fm.attributesOfItem(atPath: installed.path)[.modificationDate] as? Date

        XCTAssertEqual(refresh()[helper], .upToDate)

        let after = try fm.attributesOfItem(atPath: installed.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after, "An up-to-date helper must not be rewritten")
    }

    func testContentNotTimestampDecides() throws {
        // The installed copy is *newer* than the bundled one and still gets
        // replaced: the app that is launching is the source of truth for its own
        // hook protocol, so a downgrade has to roll the helper back too.
        let bundled = try writeBundled("this-builds-helper")
        let installed = try writeInstalled("some-other-helper")
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: bundled.path)
        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: installed.path)

        XCTAssertEqual(refresh()[helper], .refreshed)
        XCTAssertEqual(try contents(of: installed), "this-builds-helper")
    }

    // MARK: - Absent → not created

    func testAbsentHelperIsNotCreated() throws {
        // No installed copy means the user never ran the installer. Creating one
        // would start managing a directory they never opted into.
        try writeBundled("v2-current-build")

        XCTAssertEqual(refresh()[helper], .notInstalled)
        XCTAssertFalse(fm.fileExists(atPath: installDirectory.appendingPathComponent(helper).path))
    }

    func testHelperMissingFromTheBundleIsNotTouched() throws {
        let installed = try writeInstalled("whatever-the-user-has")

        XCTAssertEqual(refresh()[helper], .notBundled)
        XCTAssertEqual(try contents(of: installed), "whatever-the-user-has")
    }

    func testSymlinkedHelperIsLeftAlone() throws {
        // `install -m 0755` writes a regular file, so a symlink here is the
        // user's own wiring — following it would write outside ~/.local/bin.
        try writeBundled("v2-current-build")
        let target = root.appendingPathComponent("their-own-build")
        try Data("their-own-build".utf8).write(to: target)
        try fm.createSymbolicLink(
            at: installDirectory.appendingPathComponent(helper),
            withDestinationURL: target
        )

        XCTAssertEqual(refresh()[helper], .skippedSymlink)
        XCTAssertEqual(try contents(of: target), "their-own-build")
    }

    // MARK: - Scope

    func testOnlyTheInstallerOwnedHelpersAreManaged() throws {
        // cortland-ctl and cortland-telemetry ship in the bundle but the
        // installer never copies them to ~/.local/bin, so a file of that name
        // there is not ours to replace.
        XCTAssertEqual(InstalledHelperRefresher.managedHelpers, ["cortland-agent-status", "cortland-mcp"])

        try writeBundled("bundled-ctl", named: "cortland-ctl")
        let foreign = try writeInstalled("the-users-own-ctl", named: "cortland-ctl")

        _ = InstalledHelperRefresher.refresh(
            bundleDirectory: bundleDirectory,
            installDirectory: installDirectory
        )
        XCTAssertEqual(try contents(of: foreign), "the-users-own-ctl")
    }

    func testEachHelperIsRefreshedIndependently() throws {
        try writeBundled("status-v2", named: "cortland-agent-status")
        try writeBundled("mcp-v2", named: "cortland-mcp")
        let status = try writeInstalled("status-v1", named: "cortland-agent-status")
        // cortland-mcp was never installed; that must not stop the status helper
        // from being refreshed.

        let outcomes = InstalledHelperRefresher.refresh(
            bundleDirectory: bundleDirectory,
            installDirectory: installDirectory
        )
        XCTAssertEqual(outcomes["cortland-agent-status"], .refreshed)
        XCTAssertEqual(outcomes["cortland-mcp"], .notInstalled)
        XCTAssertEqual(try contents(of: status), "status-v2")
        XCTAssertFalse(fm.fileExists(atPath: installDirectory.appendingPathComponent("cortland-mcp").path))
    }

    func testMissingInstallDirectoryIsNotCreated() throws {
        // Never ran the installer at all: no ~/.local/bin to manage.
        try fm.removeItem(at: installDirectory)
        try writeBundled("v2-current-build")

        XCTAssertEqual(refresh()[helper], .notInstalled)
        XCTAssertFalse(fm.fileExists(atPath: installDirectory.path))
    }

    func testXCTestRunIsNotTreatedAsAnInstalledApp() throws {
        // The launch path self-heals only from a real .app (see the type's
        // comment on dev builds) — so nothing in this suite could reach the
        // user's ~/.local/bin even if it called refreshOnLaunch().
        XCTAssertFalse(InstalledHelperRefresher.isRunningFromAppBundle)
    }
}
