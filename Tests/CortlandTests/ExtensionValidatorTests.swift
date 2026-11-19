import XCTest
@testable import Cortland

/// `cortland-ctl extension validate`: the check itself (with a fake process
/// runner), the `extension_validate` IPC parsing, one run of a real
/// executable, and the extension-builder skill's template. Temp directories
/// only, never the real ~/.config/cortland.
final class ExtensionValidatorTests: XCTestCase {
    private var base: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("ExtensionValidatorTests-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    // MARK: - Fixtures

    private static let panelTable = "[panel]\ntitle = \"Widgets\"\nicon = \"star\"\n"
    private static let paletteTables = """
    [[palette]]
    title = "New Widget"
    action = "new"

    [[palette]]
    title = "Open Widget"
    action = "open"
    pick = true

    """

    /// A panel output that offers both palette actions, with real symbols.
    private static let goodPanel = """
    {"message": "2 widgets",
     "actions": [{"id": "new", "title": "New Widget", "icon": "plus"}],
     "sections": [
       {"title": "Running", "rows": [
         {"id": "widget/a", "title": "a", "icon": "cube", "actions": [{"id": "open", "title": "Open"}]},
         {"id": "widget/b", "title": "b", "actions": [{"id": "open", "title": "Open"}]}]},
       {"title": "Stopped", "empty": "None", "rows": []}]}
    """

    /// Creates `<base>/<id>/` with a manifest (core fields plus `extra`) and
    /// an executable `bin/run` holding `script`.
    @discardableResult
    private func makeExtension(
        id: String = "acme.widgets",
        extra: String = panelTable + "\n" + paletteTables,
        script: String = "#!/bin/sh\necho '{}'\n"
    ) throws -> URL {
        let dir = base.appendingPathComponent(id)
        try fm.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let manifest = """
        api_version = 1
        id = "\(id)"
        name = "Widgets"
        version = "0.1.0"
        command = "bin/run"

        \(extra)
        """
        try manifest.write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        let command = dir.appendingPathComponent("bin/run")
        try script.write(to: command, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        return dir
    }

    private nonisolated final class FakeRunner: ProcessRunning, @unchecked Sendable {
        let result: ProcessResult
        private let lock = NSLock()
        private var _calls: [(URL, [String], URL?, [String: String]?)] = []
        var calls: [(URL, [String], URL?, [String: String]?)] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }

        init(status: Int32 = 0, stdout: String = "", stderr: String = "") {
            result = ProcessResult(terminationStatus: status, stdout: stdout, stderr: stderr)
        }

        func run(executableURL: URL, arguments: [String], currentDirectoryURL: URL?, environment: [String: String]?) throws -> ProcessResult {
            lock.lock(); defer { lock.unlock() }
            _calls.append((executableURL, arguments, currentDirectoryURL, environment))
            return result
        }
    }

    private func validate(_ folder: URL, _ runner: FakeRunner) -> ExtensionValidationReport {
        ExtensionValidator.validate(folder: folder, runner: runner, searchPath: "/usr/bin:/bin")
    }

    // MARK: - Valid

    func testValidExtensionWithPanel() throws {
        let dir = try makeExtension()
        let runner = FakeRunner(stdout: Self.goodPanel)
        let report = validate(dir, runner)

        XCTAssertTrue(report.valid)
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.warnings, [])
        XCTAssertEqual(report.manifest, .init(
            id: "acme.widgets", name: "Widgets", version: "0.1.0", apiVersion: 1,
            panelTitle: "Widgets", palette: ["New Widget", "Open Widget"]))
        XCTAssertEqual(report.panel, .init(sections: 2, rows: 2, actions: 1, message: "2 widgets"))

        // Run exactly as the sidebar runs it.
        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(call.0.lastPathComponent, "run")
        XCTAssertEqual(call.1, ["panel"])
        XCTAssertEqual(call.2, dir)
        XCTAssertEqual(call.3, ["PATH": "/usr/bin:/bin"])
    }

    func testValidExtensionWithoutPanelDoesNotRunTheCommand() throws {
        let dir = try makeExtension(extra: "")
        let runner = FakeRunner(stdout: "not json")
        let report = validate(dir, runner)

        XCTAssertTrue(report.valid)
        XCTAssertEqual(report.warnings, [])
        XCTAssertNil(report.panel)
        XCTAssertNil(report.manifest?.panelTitle)
        XCTAssertEqual(report.manifest?.palette, [])
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testJSONShape() throws {
        let dir = try makeExtension()
        let report = validate(dir, FakeRunner(stdout: Self.goodPanel))
        let data = try JSONEncoder().encode(report)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["valid"] as? Bool, true)
        XCTAssertEqual((object["errors"] as? [Any])?.count, 0)
        let manifest = try XCTUnwrap(object["manifest"] as? [String: Any])
        XCTAssertEqual(manifest["api_version"] as? Int, 1)
        XCTAssertEqual(manifest["panel_title"] as? String, "Widgets")
        let panel = try XCTUnwrap(object["panel"] as? [String: Any])
        XCTAssertEqual(panel["rows"] as? Int, 2)
    }

    // MARK: - Errors

    func testBadManifestIsAnErrorAndStops() throws {
        let dir = try makeExtension(id: "acme.widgets")
        let renamed = base.appendingPathComponent("acme.other")
        try fm.moveItem(at: dir, to: renamed)
        let runner = FakeRunner(stdout: Self.goodPanel)
        let report = validate(renamed, runner)

        XCTAssertFalse(report.valid)
        XCTAssertEqual(report.errors, [ExtensionManifestError.idMismatch(id: "acme.widgets", folder: "acme.other").localizedDescription])
        XCTAssertNil(report.manifest)
        XCTAssertNil(report.panel)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testPanelCommandExitingNonZeroIsAnError() throws {
        let dir = try makeExtension()
        let report = validate(dir, FakeRunner(status: 3, stderr: "boom\n"))

        XCTAssertFalse(report.valid)
        XCTAssertEqual(report.errors, ["\"bin/run panel\" failed: boom"])
        XCTAssertEqual(report.manifest?.id, "acme.widgets")
        XCTAssertNil(report.panel)
        XCTAssertEqual(report.warnings, [], "palette checks need panel output")
    }

    func testInvalidPanelOutputIsAnError() throws {
        let dir = try makeExtension()
        let report = validate(dir, FakeRunner(stdout: #"{"sections": [{"rows": []}]}"#))

        XCTAssertFalse(report.valid)
        XCTAssertEqual(report.errors, ["\"bin/run panel\" printed invalid output: missing \"title\" at sections[0]"])
        XCTAssertNil(report.panel)
    }

    // MARK: - Warnings

    func testPanelPaletteEntryWithoutMatchingPanelAction() throws {
        let dir = try makeExtension()
        let output = #"{"sections": [{"title": "S", "rows": [{"id": "widget/a", "title": "a", "actions": [{"id": "open", "title": "Open"}]}]}]}"#
        let report = validate(dir, FakeRunner(stdout: output))

        XCTAssertTrue(report.valid)
        XCTAssertEqual(report.warnings, [
            "Palette entry \"New Widget\" runs panel action \"new\", but the panel output has no panel action with that id."
        ])
    }

    func testPickPaletteEntryWithoutMatchingRowAction() throws {
        let dir = try makeExtension()
        // "open" exists only as a panel action, which does not satisfy pick = true.
        let output = #"{"actions": [{"id": "new", "title": "New"}, {"id": "open", "title": "Open"}], "sections": [{"title": "S", "rows": [{"id": "widget/a", "title": "a"}]}]}"#
        let report = validate(dir, FakeRunner(stdout: output))

        XCTAssertTrue(report.valid)
        XCTAssertEqual(report.warnings, [
            "Palette entry \"Open Widget\" (pick = true) runs row action \"open\", but no row in the panel output has it."
        ])
    }

    func testUnknownPanelSymbol() throws {
        let dir = try makeExtension(extra: "[panel]\ntitle = \"Widgets\"\nicon = \"no.such.symbol.anywhere\"\n")
        let report = validate(dir, FakeRunner(stdout: "{}"))

        XCTAssertTrue(report.valid)
        XCTAssertEqual(report.warnings, [
            "\"panel.icon\" \"no.such.symbol.anywhere\" is not an SF Symbol on this Mac; the activity bar shows a generic icon instead."
        ])
    }

    func testPanelIconFileIsNotCheckedAsASymbol() throws {
        let dir = try makeExtension(extra: "[panel]\ntitle = \"Widgets\"\nicon = \"icon.svg\"\n")
        try "<svg xmlns=\"http://www.w3.org/2000/svg\"/>".write(
            to: dir.appendingPathComponent("icon.svg"), atomically: true, encoding: .utf8)
        let report = validate(dir, FakeRunner(stdout: "{}"))
        XCTAssertTrue(report.valid)
        XCTAssertEqual(report.warnings, [])
    }

    func testUnknownRowAndActionIcons() throws {
        let dir = try makeExtension(extra: Self.panelTable)
        let output = """
        {"actions": [{"id": "new", "title": "New", "icon": "bad.panel.action"}],
         "sections": [{"title": "S", "rows": [
           {"id": "widget/a", "title": "a", "icon": "bad.row",
            "actions": [{"id": "open", "title": "Open", "icon": "bad.row.action"}]}]}]}
        """
        let report = validate(dir, FakeRunner(stdout: output))

        XCTAssertTrue(report.valid)
        XCTAssertEqual(report.warnings, [
            "Panel action \"new\" has icon \"bad.panel.action\", which is not an SF Symbol on this Mac; it goes in the Actions menu instead of the top bar.",
            "Row \"widget/a\" has icon \"bad.row\", which is not an SF Symbol on this Mac; the row shows no icon.",
            "Action \"open\" on row \"widget/a\" has icon \"bad.row.action\", which is not an SF Symbol on this Mac."
        ])
    }

    // MARK: - IPC parsing

    private func parse(_ request: [String: Any]) throws -> IPCCommandType.ParseResult {
        let data = try JSONSerialization.data(withJSONObject: request)
        return IPCCommandType.parse(try JSONDecoder().decode(IPCCommand.self, from: data))
    }

    func testIPCParsesAnExistingDirectory() throws {
        let dir = try makeExtension()
        guard case .command(.extensionValidate(let folder)) = try parse(["action": "extension_validate", "path": dir.path]) else {
            return XCTFail("Expected extensionValidate")
        }
        XCTAssertEqual(folder, dir.standardizedFileURL.path)
    }

    func testIPCKeepsASymlinkedFolderName() throws {
        let dir = try makeExtension()
        let link = base.appendingPathComponent("linked")
        try fm.createSymbolicLink(at: link, withDestinationURL: dir)
        guard case .command(.extensionValidate(let folder)) = try parse(["action": "extension_validate", "path": link.path]) else {
            return XCTFail("Expected extensionValidate")
        }
        XCTAssertEqual(URL(fileURLWithPath: folder).lastPathComponent, "linked")
    }

    func testIPCRejectsMissingPath() throws {
        guard case .invalidArguments = try parse(["action": "extension_validate"]) else {
            return XCTFail("Expected invalidArguments")
        }
    }

    func testIPCRejectsPathThatIsNotADirectory() throws {
        let dir = try makeExtension()
        let file = dir.appendingPathComponent("extension.toml")
        for path in [file.path, base.appendingPathComponent("missing").path, "relative/folder"] {
            guard case .invalidArguments = try parse(["action": "extension_validate", "path": path]) else {
                return XCTFail("Expected invalidArguments for \(path)")
            }
        }
    }

    // MARK: - Real executables

    func testEndToEndWithARealExecutable() throws {
        // The stub reports its argument and working directory in "message".
        let script = """
        #!/bin/sh
        printf '{"message": "%s %s", "actions": [{"id": "new", "title": "New"}], "sections": [{"title": "S", "rows": [{"id": "widget/a", "title": "a", "actions": [{"id": "open", "title": "Open"}]}]}]}\\n' "$1" "$(pwd -P)"
        """
        let dir = try makeExtension(script: script)
        let report = ExtensionValidator.validate(folder: dir, runner: ProcessRunner.shared, searchPath: "/usr/bin:/bin")

        XCTAssertTrue(report.valid, "\(report.errors)")
        XCTAssertEqual(report.warnings, [])
        // realpath(3), because resolvingSymlinksInPath keeps /var for /private/var.
        let resolved = try XCTUnwrap(realpath(dir.path, nil))
        defer { free(resolved) }
        let realFolder = String(cString: resolved)
        XCTAssertEqual(report.panel, .init(sections: 1, rows: 1, actions: 1, message: "panel \(realFolder)"))
    }

    /// The extension-builder skill's template, copied to a folder named for
    /// its id as the skill tells an agent to do, must validate cleanly with
    /// its real `bin/run`.
    func testSkillTemplateValidatesCleanly() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let template = repoRoot.appendingPathComponent(".claude/skills/cortland-extension-builder/template")
        let copy = base.appendingPathComponent("example.widgets")
        try fm.copyItem(at: template, to: copy)

        let report = ExtensionValidator.validate(folder: copy, runner: ProcessRunner.shared, searchPath: "/usr/bin:/bin")

        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.warnings, [])
        XCTAssertTrue(report.valid)
        XCTAssertEqual(report.manifest?.id, "example.widgets")
        XCTAssertEqual(report.panel?.rows, 2)
    }
}
