import XCTest
import AppKit
@testable import Cortland

/// Extension sidebar panels: the `[panel]` manifest table, panel output
/// decoding, running the command, refresh rules, and sidebar wiring. Temp
/// directories only, never the real ~/.config/cortland.
@MainActor
final class ExtensionPanelTests: XCTestCase {
    private var base: URL!
    private var extensionsDirectory: URL!
    private var stateFile: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("ExtensionPanelTests-\(UUID().uuidString)")
        extensionsDirectory = base.appendingPathComponent("extensions")
        stateFile = base.appendingPathComponent("extensions.json")
        try fm.createDirectory(at: extensionsDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    // MARK: - Fixtures

    private func manifestText(id: String, name: String, panel: String?) -> String {
        var text = """
        api_version = 1
        id = "\(id)"
        name = "\(name)"
        version = "0.1.0"
        command = "bin/run"

        """
        if let panel { text += "\n[panel]\n\(panel)\n" }
        return text
    }

    /// Creates `<extensions>/<id>/` with a manifest and an executable
    /// `bin/run` holding `script`.
    @discardableResult
    private func install(
        id: String = "acme.widgets",
        name: String = "Widgets",
        panel: String? = "title = \"Widgets\"\nicon = \"star\"",
        script: String = "#!/bin/sh\necho '{}'\n"
    ) throws -> URL {
        let dir = extensionsDirectory.appendingPathComponent(id)
        try fm.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try manifestText(id: id, name: name, panel: panel).write(
            to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        let command = dir.appendingPathComponent("bin/run")
        try script.write(to: command, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        return dir
    }

    private func parse(panel: String?) throws -> ExtensionManifest {
        let dir = try install(panel: panel)
        return try ExtensionManifest.load(from: dir)
    }

    private func panelError(_ panel: String) throws -> ExtensionManifestError? {
        let dir = try install(panel: panel)
        do {
            _ = try ExtensionManifest.load(from: dir)
            return nil
        } catch {
            return error
        }
    }

    private func installed(id: String = "acme.widgets", name: String = "Widgets", enabled: Bool = true) throws -> InstalledExtension {
        let dir = try install(id: id, name: name, panel: "title = \"\(name)\"\nicon = \"star\"")
        return InstalledExtension(manifest: try ExtensionManifest.load(from: dir), folder: dir, isEnabled: enabled)
    }

    private func decode(_ json: String) throws(ExtensionPanelError) -> ExtensionPanelContent {
        try ExtensionPanelContent.decode(Data(json.utf8))
    }

    private func decodeError(_ json: String) -> ExtensionPanelError? {
        do {
            _ = try decode(json)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - [panel] manifest rules

    func testValidPanelTable() throws {
        let manifest = try parse(panel: "title = \"  Widgets  \"\nicon = \"star\"\nrefresh_seconds = 30")
        XCTAssertEqual(manifest.panel, ExtensionPanelSpec(title: "Widgets", icon: "star", refreshSeconds: 30))
    }

    // MARK: - [panel] icon files

    private static let squareSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 20"><path d="M0 0h10v20H0z"/></svg>
    """

    func testSymbolIconHasNoFile() throws {
        // "bolt.horizontal" has a dot but no image extension: an SF Symbol.
        let manifest = try parse(panel: "title = \"W\"\nicon = \"bolt.horizontal\"")
        XCTAssertNil(manifest.panel?.iconURL)
    }

    func testIconFileResolvesInsideTheFolder() throws {
        let dir = try install(panel: "title = \"W\"\nicon = \"art/icon.svg\"")
        try fm.createDirectory(at: dir.appendingPathComponent("art"), withIntermediateDirectories: true)
        try Self.squareSVG.write(to: dir.appendingPathComponent("art/icon.svg"), atomically: true, encoding: .utf8)
        let manifest = try ExtensionManifest.load(from: dir)
        XCTAssertEqual(manifest.panel?.icon, "art/icon.svg")
        XCTAssertEqual(manifest.panel?.iconURL?.lastPathComponent, "icon.svg")
    }

    func testIconFileMustExist() throws {
        let dir = try install(panel: "title = \"W\"\nicon = \"icon.svg\"")
        XCTAssertThrowsError(try ExtensionManifest.load(from: dir)) { error in
            XCTAssertEqual(error as? ExtensionManifestError, .iconMissing("icon.svg"))
        }
    }

    func testIconFileCannotLeaveTheFolder() throws {
        let outside = base.appendingPathComponent("outside.svg")
        try Self.squareSVG.write(to: outside, atomically: true, encoding: .utf8)

        let dotDot = try install(id: "acme.dotdot", panel: "title = \"W\"\nicon = \"../../outside.svg\"")
        XCTAssertThrowsError(try ExtensionManifest.load(from: dotDot)) { error in
            XCTAssertEqual(error as? ExtensionManifestError, .iconOutsideFolder("../../outside.svg"))
        }

        let absolute = try install(id: "acme.absolute", panel: "title = \"W\"\nicon = \"\(outside.path)\"")
        XCTAssertThrowsError(try ExtensionManifest.load(from: absolute)) { error in
            XCTAssertEqual(error as? ExtensionManifestError, .iconOutsideFolder(outside.path))
        }

        let linked = try install(id: "acme.linked", panel: "title = \"W\"\nicon = \"link.svg\"")
        try fm.createSymbolicLink(at: linked.appendingPathComponent("link.svg"), withDestinationURL: outside)
        XCTAssertThrowsError(try ExtensionManifest.load(from: linked)) { error in
            XCTAssertEqual(error as? ExtensionManifestError, .iconOutsideFolder("link.svg"))
        }
    }

    func testIconFileLoadsAsAScaledTemplateImage() throws {
        let file = base.appendingPathComponent("icon.svg")
        try Self.squareSVG.write(to: file, atomically: true, encoding: .utf8)
        let image = try XCTUnwrap(ActivityBarView.extensionIconImage(at: file, box: 24))
        XCTAssertTrue(image.isTemplate)
        // 10 x 20 scaled so the longer side fills the box.
        XCTAssertEqual(image.size.height, 24, accuracy: 0.01)
        XCTAssertEqual(image.size.width, 12, accuracy: 0.01)

        XCTAssertNil(ActivityBarView.extensionIconImage(at: nil))
        XCTAssertNil(ActivityBarView.extensionIconImage(at: base.appendingPathComponent("missing.svg")))
    }

    func testAbsentPanelTable() throws {
        XCTAssertNil(try parse(panel: nil).panel)
    }

    func testRefreshSecondsDefaultsToTen() throws {
        XCTAssertEqual(try parse(panel: "title = \"W\"\nicon = \"star\"").panel?.refreshSeconds, 10)
    }

    func testRefreshSecondsMinimumIsTwo() throws {
        XCTAssertEqual(try parse(panel: "title = \"W\"\nicon = \"star\"\nrefresh_seconds = 2").panel?.refreshSeconds, 2)
        XCTAssertEqual(try panelError("title = \"W\"\nicon = \"star\"\nrefresh_seconds = 1"), .refreshTooShort(1))
        XCTAssertEqual(try panelError("title = \"W\"\nicon = \"star\"\nrefresh_seconds = 0"), .refreshTooShort(0))
    }

    func testRefreshSecondsMustBeInteger() throws {
        XCTAssertEqual(
            try panelError("title = \"W\"\nicon = \"star\"\nrefresh_seconds = \"10\""),
            .wrongType(field: "panel.refresh_seconds", expected: "an integer"))
        XCTAssertEqual(
            try panelError("title = \"W\"\nicon = \"star\"\nrefresh_seconds = 2.5"),
            .wrongType(field: "panel.refresh_seconds", expected: "an integer"))
    }

    func testPanelTitleRules() throws {
        XCTAssertEqual(try panelError("icon = \"star\""), .missingField("panel.title"))
        XCTAssertEqual(try panelError("title = 3\nicon = \"star\""), .wrongType(field: "panel.title", expected: "a string"))
        XCTAssertEqual(try panelError("title = \"   \"\nicon = \"star\""), .emptyField("panel.title"))
    }

    func testPanelIconRules() throws {
        XCTAssertEqual(try panelError("title = \"W\""), .missingField("panel.icon"))
        XCTAssertEqual(try panelError("title = \"W\"\nicon = true"), .wrongType(field: "panel.icon", expected: "a string"))
        XCTAssertEqual(try panelError("title = \"W\"\nicon = \"\""), .emptyField("panel.icon"))
    }

    func testUnknownSymbolIsNotAManifestError() throws {
        XCTAssertEqual(try parse(panel: "title = \"W\"\nicon = \"no.such.symbol.anywhere\"").panel?.icon, "no.such.symbol.anywhere")
    }

    func testPanelMustBeATable() throws {
        let dir = extensionsDirectory.appendingPathComponent("acme.widgets")
        try install()
        let text = manifestText(id: "acme.widgets", name: "Widgets", panel: nil) + "panel = \"Widgets\"\n"
        try text.write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ExtensionManifest.load(from: dir)) { error in
            XCTAssertEqual(error as? ExtensionManifestError, .wrongType(field: "panel", expected: "a table"))
        }
    }

    // MARK: - Panel output decoding

    func testFullDocumentDecodes() throws {
        let content = try decode("""
        {
          "message": "hello",
          "sections": [
            {
              "title": "Things",
              "empty": "No things",
              "rows": [
                { "id": "thing/a", "title": "a", "detail": "first · one", "icon": "bolt" },
                { "id": "thing/b", "title": "b" }
              ]
            },
            { "title": "Others", "empty": "No others", "rows": [] }
          ]
        }
        """)
        XCTAssertEqual(content, ExtensionPanelContent(message: "hello", sections: [
            .init(title: "Things", empty: "No things", rows: [
                .init(id: "thing/a", title: "a", detail: "first · one", icon: "bolt"),
                .init(id: "thing/b", title: "b")
            ]),
            .init(title: "Others", empty: "No others", rows: [])
        ]))
    }

    func testMinimalDocumentsUseDefaults() throws {
        XCTAssertEqual(try decode("{}"), ExtensionPanelContent(message: nil, sections: []))
        XCTAssertEqual(
            try decode(#"{"sections":[{"title":"S"}]}"#),
            ExtensionPanelContent(sections: [.init(title: "S", empty: nil, rows: [])]))
    }

    func testUnknownKeysAreIgnored() throws {
        let content = try decode("""
        {
          "version": 9,
          "sections": [
            {
              "title": "S", "collapsed": true,
              "rows": [
                { "id": "r", "title": "R", "badges": [ { "id": "open", "title": "Open" } ], "extra": null }
              ]
            }
          ]
        }
        """)
        XCTAssertEqual(content.sections.first?.rows, [.init(id: "r", title: "R")])
    }

    func testRuleViolations() {
        XCTAssertNotNil(decodeError("not json"))
        XCTAssertNotNil(decodeError("[]"))
        XCTAssertNotNil(decodeError(#"{"message": 3}"#))
        XCTAssertNotNil(decodeError(#"{"sections": {}}"#))
        XCTAssertNotNil(decodeError(#"{"sections": [{"rows": []}]}"#))
        XCTAssertNotNil(decodeError(#"{"sections": [{"title": 1}]}"#))
        XCTAssertNotNil(decodeError(#"{"sections": [{"title": "S", "empty": 1}]}"#))
        XCTAssertNotNil(decodeError(#"{"sections": [{"title": "S", "rows": [{"title": "R"}]}]}"#))
        XCTAssertNotNil(decodeError(#"{"sections": [{"title": "S", "rows": [{"id": "r"}]}]}"#))
        XCTAssertNotNil(decodeError(#"{"sections": [{"title": "S", "rows": [{"id": "r", "title": "R", "detail": 1}]}]}"#))
        XCTAssertNotNil(decodeError(#"{"sections": [{"title": "S", "rows": [{"id": "r", "title": "R", "icon": 1}]}]}"#))
        XCTAssertEqual(
            decodeError(#"{"sections": [{"title": "S", "rows": [{"id": "", "title": "R"}]}]}"#),
            .invalidOutput("a row in \"S\" has an empty \"id\""))
        XCTAssertEqual(decodeError("not json"), .invalidOutput("output is not valid JSON"))
        XCTAssertEqual(
            decodeError(#"{"sections": [{"title": "S", "rows": [{"title": "R"}]}]}"#),
            .invalidOutput("missing \"id\" at sections[0].rows[0]"))
    }

    func testDuplicateIDsAcrossSectionsAreInvalid() {
        XCTAssertEqual(
            decodeError(#"{"sections": [{"title": "A", "rows": [{"id": "x", "title": "1"}]}, {"title": "B", "rows": [{"id": "x", "title": "2"}]}]}"#),
            .invalidOutput("duplicate row id \"x\""))
    }

    // MARK: - Running the command (fake runner)

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

    private func command(_ runner: FakeRunner) -> ExtensionPanelCommand {
        ExtensionPanelCommand(
            executableURL: URL(fileURLWithPath: "/ext/bin/run"),
            folder: URL(fileURLWithPath: "/ext"),
            runner: runner
        )
    }

    func testCommandSuccess() throws {
        let runner = FakeRunner(stdout: #"{"sections":[{"title":"S","rows":[{"id":"a","title":"A"}]}]}"#)
        let result = command(runner).run(searchPath: "/opt/bin:/usr/bin")
        XCTAssertEqual(try result.get(), ExtensionPanelContent(sections: [.init(title: "S", rows: [.init(id: "a", title: "A")])]))

        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(call.0.path, "/ext/bin/run")
        XCTAssertEqual(call.1, ["panel"])
        XCTAssertEqual(call.2?.path, "/ext")
        XCTAssertEqual(call.3, ["PATH": "/opt/bin:/usr/bin"])
    }

    func testCommandNonZeroExitUsesFirstStderrLine() {
        let runner = FakeRunner(status: 3, stdout: "{}", stderr: "\n  \n  token expired  \nsecond line\n")
        let result = command(runner).run(searchPath: "/usr/bin")
        XCTAssertEqual(result, .failure(.exited(status: 3, stderr: "token expired")))
        XCTAssertEqual(ExtensionPanelError.exited(status: 3, stderr: "token expired").localizedDescription, "token expired")
        XCTAssertEqual(ExtensionPanelError.exited(status: 3, stderr: "").localizedDescription, "exited with status 3")
    }

    func testCommandInvalidJSON() {
        let runner = FakeRunner(stdout: "Traceback (most recent call last):")
        XCTAssertEqual(command(runner).run(searchPath: "/usr/bin"), .failure(.invalidOutput("output is not valid JSON")))
    }

    func testRealExecutableReceivesPanelArgumentAndWorkingDirectory() throws {
        let script = """
        #!/bin/sh
        printf '{"sections":[{"title":"Args","rows":[{"id":"arg","title":"%s"},{"id":"cwd","title":"%s"}]}]}' "$*" "$(pwd -P)"
        """
        let dir = try install(script: script)
        let manifest = try ExtensionManifest.load(from: dir)
        let result = ExtensionPanelCommand(
            extension: InstalledExtension(manifest: manifest, folder: dir, isEnabled: true)
        ).run(searchPath: "/usr/bin:/bin")

        let realFolder = try XCTUnwrap(realpath(dir.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        let rows = try result.get().sections.first?.rows
        XCTAssertEqual(rows, [.init(id: "arg", title: "panel"), .init(id: "cwd", title: realFolder)])
    }

    // MARK: - Refresh rules

    /// A refresher whose loads finish only when the test says so.
    @MainActor private final class HeldLoads {
        var completions: [@MainActor (Result<ExtensionPanelContent, ExtensionPanelError>) -> Void] = []

        func make() -> ExtensionPanelRefresher {
            ExtensionPanelRefresher(refreshInterval: 60) { [unowned self] completion in
                completions.append(completion)
            }
        }
    }

    func testRefreshNeverOverlaps() {
        let loads = HeldLoads()
        let refresher = loads.make()

        refresher.refresh()
        refresher.refresh()
        refresher.refresh()
        XCTAssertEqual(loads.completions.count, 1)
        XCTAssertTrue(refresher.isLoading)

        loads.completions[0](.success(ExtensionPanelContent()))
        XCTAssertFalse(refresher.isLoading)

        refresher.refresh()
        XCTAssertEqual(loads.completions.count, 2)
    }

    func testEqualContentDoesNotReportAChange() {
        let loads = HeldLoads()
        let refresher = loads.make()
        var changes: [ExtensionPanelState] = []
        refresher.onStateChange = { changes.append($0) }
        let content = ExtensionPanelContent(sections: [.init(title: "S", rows: [.init(id: "a", title: "A")])])

        refresher.refresh()
        loads.completions[0](.success(content))
        refresher.refresh()
        loads.completions[1](.success(content))
        XCTAssertEqual(changes, [.content(content)])

        refresher.refresh()
        loads.completions[2](.failure(.invalidOutput("bad")))
        refresher.refresh()
        loads.completions[3](.success(content))
        XCTAssertEqual(changes, [.content(content), .failed("bad"), .content(content)])
    }

    func testViewReloadsOnlyWhenContentChanges() throws {
        let loads = HeldLoads()
        let controller = ExtensionPanelViewController(installed: try installed(), refresher: loads.make())
        _ = controller.view
        let initial = controller.reloadCount
        let content = ExtensionPanelContent(sections: [.init(title: "S", rows: [.init(id: "a", title: "A")])])

        controller.refresher.refresh()
        loads.completions[0](.success(content))
        XCTAssertEqual(controller.reloadCount, initial + 1)

        controller.refresher.refresh()
        loads.completions[1](.success(content))
        XCTAssertEqual(controller.reloadCount, initial + 1)
    }

    func testActivatingRefreshesAndDeactivatingStopsTheTimer() {
        let loads = HeldLoads()
        let refresher = loads.make()

        refresher.setActive(true)
        XCTAssertTrue(refresher.isActive)
        XCTAssertEqual(loads.completions.count, 1)

        refresher.setActive(true)
        XCTAssertEqual(loads.completions.count, 1)

        refresher.setActive(false)
        XCTAssertFalse(refresher.isActive)
    }

    func testItemsForStates() {
        XCTAssertEqual(
            ExtensionPanelViewController.items(for: .failed("token expired")),
            [.error("Extension error"), .message("token expired")])
        let content = ExtensionPanelContent(message: "note", sections: [
            .init(title: "Full", empty: "None", rows: [.init(id: "a", title: "A")]),
            .init(title: "Empty", empty: "Nothing here", rows: []),
            .init(title: "Bare", rows: [])
        ])
        XCTAssertEqual(ExtensionPanelViewController.items(for: .content(content)), [
            .message("note"),
            .header("FULL"), .row(.init(id: "a", title: "A")),
            .header("EMPTY"), .message("Nothing here"),
            .header("BARE")
        ])
    }

    // MARK: - Sidebar integration

    func testPanelExtensionsFilterAndOrder() throws {
        let zed = try installed(id: "acme.zed", name: "Zed")
        let alpha = try installed(id: "acme.alpha", name: "Alpha")
        let off = try installed(id: "acme.off", name: "Off", enabled: false)
        let plainDir = try install(id: "acme.plain", name: "Plain", panel: nil)
        let plain = InstalledExtension(manifest: try ExtensionManifest.load(from: plainDir), folder: plainDir, isEnabled: true)

        XCTAssertEqual(InstalledExtension.panelExtensions([zed, off, plain, alpha]).map(\.id), ["acme.alpha", "acme.zed"])
    }

    func testActivityBarFollowsEnabledExtensions() throws {
        try install(id: "acme.widgets", name: "Widgets")
        try install(id: "acme.plain", name: "Plain", panel: nil)
        let registry = ExtensionRegistry(
            extensionsDirectory: extensionsDirectory,
            stateFileURL: stateFile,
            removeFolder: { [fm] url in try fm.removeItem(at: url) }
        )
        let bar = ActivityBarView(frame: NSRect(x: 0, y: 0, width: 48, height: 600))

        registry.reload()
        bar.setExtensionPanels(InstalledExtension.panelExtensions(registry.extensions))
        XCTAssertEqual(bar.extensionPanelIDs, [])

        try registry.setEnabled("acme.plain", true)
        bar.setExtensionPanels(InstalledExtension.panelExtensions(registry.extensions))
        XCTAssertEqual(bar.extensionPanelIDs, [], "an extension without [panel] adds no icon")

        try registry.setEnabled("acme.widgets", true)
        bar.setExtensionPanels(InstalledExtension.panelExtensions(registry.extensions))
        XCTAssertEqual(bar.extensionPanelIDs, ["acme.widgets"])
        XCTAssertEqual(bar._extensionButtonToolTips, ["Widgets"])

        bar.selectExtensionPanel("acme.widgets")
        XCTAssertEqual(bar.selectedExtensionID, "acme.widgets")

        try registry.setEnabled("acme.widgets", false)
        bar.setExtensionPanels(InstalledExtension.panelExtensions(registry.extensions))
        XCTAssertEqual(bar.extensionPanelIDs, [])
        XCTAssertNil(bar.selectedExtensionID)
    }

    func testSidebarAddsExtensionPanelLazily() throws {
        let widgets = try installed()
        let container = SidebarContainerView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        container.setVisible(false)

        container.setExtensionPanels([widgets])
        XCTAssertTrue(container._instantiatedExtensionPanels.isEmpty)
        XCTAssertTrue(container._instantiatedPanels.isEmpty)

        container.showExtensionPanel("acme.widgets")
        XCTAssertEqual(container.currentExtensionPanelID, "acme.widgets")
        XCTAssertEqual(container._instantiatedExtensionPanels, ["acme.widgets"])
        XCTAssertTrue(container._instantiatedPanels.isEmpty)
        XCTAssertEqual(container._extensionController("acme.widgets")?.refresher.isActive, false,
                       "a hidden sidebar runs nothing")

        container.showExtensionPanel("acme.unknown")
        XCTAssertEqual(container.currentExtensionPanelID, "acme.widgets")
    }

    func testRemovingTheShowingPanelFallsBackToFiles() throws {
        let widgets = try installed()
        let container = SidebarContainerView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        container.setVisible(false)
        container.setExtensionPanels([widgets])
        container.showPanel(.hosts)
        container.showExtensionPanel("acme.widgets")

        container.setExtensionPanels([])
        XCTAssertNil(container.currentExtensionPanelID)
        XCTAssertEqual(container.currentPanel, .files)
        XCTAssertTrue(container._instantiatedExtensionPanels.isEmpty)
    }

    func testOnlyTheShowingExtensionPanelIsActive() throws {
        let widgets = try installed()
        let container = SidebarContainerView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        container.setVisible(false)
        container.setExtensionPanels([widgets])
        container.showExtensionPanel("acme.widgets")
        let controller = try XCTUnwrap(container._extensionController("acme.widgets"))
        XCTAssertFalse(controller.refresher.isActive)

        container.setVisible(true)
        XCTAssertTrue(controller.refresher.isActive)

        container.showPanel(.hosts)
        XCTAssertFalse(controller.refresher.isActive)

        container.showExtensionPanel("acme.widgets")
        XCTAssertTrue(controller.refresher.isActive)

        container.setVisible(false)
        XCTAssertFalse(controller.refresher.isActive)
    }
}
