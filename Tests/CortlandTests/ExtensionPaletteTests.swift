import XCTest
import AppKit
@testable import Cortland

/// Action effects (`open_url`, `copy`), `[[palette]]` manifest entries, the
/// palette entry list, choosing an entry, and the action runner the sidebar
/// panel and the palette share. Temp directories only, never the real
/// ~/.config/cortland; nothing opens a browser or touches the pasteboard.
@MainActor
final class ExtensionPaletteTests: XCTestCase {
    private var base: URL!
    private var extensionsDirectory: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("ExtensionPaletteTests-\(UUID().uuidString)")
        extensionsDirectory = base.appendingPathComponent("extensions")
        try fm.createDirectory(at: extensionsDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    // MARK: - Fixtures

    private let panelTable = """
    [panel]
    title = "Widgets"
    icon = "star"
    """

    /// Writes `<extensions>/<id>/` with a manifest (the given tail after the
    /// required keys) and an executable `bin/run` printing `{}`.
    @discardableResult
    private func install(id: String = "acme.widgets", name: String = "Widgets", tail: String) throws -> URL {
        let dir = extensionsDirectory.appendingPathComponent(id)
        try fm.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let manifest = """
        api_version = 1
        id = "\(id)"
        name = "\(name)"
        version = "0.1.0"
        command = "bin/run"

        \(tail)
        """
        try manifest.write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        let command = dir.appendingPathComponent("bin/run")
        try "#!/bin/sh\necho '{}'\n".write(to: command, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        return dir
    }

    private func installed(id: String = "acme.widgets", name: String = "Widgets", tail: String, enabled: Bool = true) throws -> InstalledExtension {
        let dir = try install(id: id, name: name, tail: tail)
        return InstalledExtension(manifest: try ExtensionManifest.load(from: dir), folder: dir, isEnabled: enabled)
    }

    private func manifestError(_ tail: String) throws -> ExtensionManifestError? {
        let dir = try install(tail: tail)
        do {
            _ = try ExtensionManifest.load(from: dir)
            return nil
        } catch {
            return error
        }
    }

    private func result(_ json: String) throws(ExtensionPanelError) -> ExtensionActionResult {
        try ExtensionActionResult.decode(Data(json.utf8))
    }

    private func resultError(_ json: String) -> ExtensionPanelError? {
        do {
            _ = try result(json)
            return nil
        } catch {
            return error
        }
    }

    /// Action runs that finish only when the test says so.
    @MainActor private final class HeldRuns {
        var calls: [(String, String?)] = []
        var completions: [@MainActor (Result<ExtensionActionResult, ExtensionPanelError>) -> Void] = []

        func make() -> ExtensionPanelActionRunner {
            ExtensionPanelActionRunner { [unowned self] actionID, rowID, completion in
                calls.append((actionID, rowID))
                completions.append(completion)
            }
        }
    }

    /// Records every effect and failure a runner hands on.
    @MainActor private final class Effects {
        var tabs: [String] = []
        var urls: [URL] = []
        var copies: [String] = []
        var failures: [String] = []

        func attach(to runner: ExtensionPanelActionRunner) {
            runner.onOpenTab = { [unowned self] in tabs.append($0) }
            runner.onOpenURL = { [unowned self] in urls.append($0) }
            runner.onCopy = { [unowned self] in copies.append($0) }
            runner.showFailure = { [unowned self] title, reason in failures.append("\(title): \(reason)") }
        }
    }

    // MARK: - Action results: open_url and copy

    func testOpenURLAndCopyDecode() throws {
        XCTAssertEqual(
            try result(#"{"open_url":"https://warm-orbit.example.com/"}"#),
            ExtensionActionResult(openURL: URL(string: "https://warm-orbit.example.com/")))
        XCTAssertEqual(
            try result(#"{"open_url":"http://warm-orbit.example.com:8080/a?b=c"}"#).openURL?.absoluteString,
            "http://warm-orbit.example.com:8080/a?b=c")
        XCTAssertEqual(try result(#"{"open_url":"HTTPS://Example.com"}"#).openURL?.host, "Example.com")
        XCTAssertEqual(
            try result(#"{"copy":"https://warm-orbit.example.com/"}"#),
            ExtensionActionResult(copy: "https://warm-orbit.example.com/"))
        XCTAssertEqual(try result(#"{"copy":" "}"#).copy, " ", "whitespace is not empty")
    }

    func testCombinedEffectsDecode() throws {
        XCTAssertEqual(
            try result(#"{"open_tab":{"command":["ls"]},"open_url":"https://a.example/","copy":"x","notify":"ignored"}"#),
            ExtensionActionResult(openTab: ["ls"], openURL: URL(string: "https://a.example/"), copy: "x"))
    }

    func testOpenURLRuleViolations() {
        let scheme = ExtensionPanelError.invalidOutput("\"open_url\" must be an http or https URL")
        for bad in ["file:///etc/passwd", "javascript:alert(1)", "slack://open", "ftp://a.example/", "a.example.com", "", "//a.example"] {
            XCTAssertEqual(resultError(#"{"open_url":"\#(bad)"}"#), scheme, bad)
        }
        let noHost = ExtensionPanelError.invalidOutput("\"open_url\" has no host")
        XCTAssertEqual(resultError(#"{"open_url":"https://"}"#), noHost)
        XCTAssertEqual(resultError(#"{"open_url":"http:///path"}"#), noHost)
        XCTAssertEqual(resultError(#"{"open_url":"https:/path"}"#), noHost)
        let control = ExtensionPanelError.invalidOutput("\"open_url\" contains a control character")
        XCTAssertEqual(resultError(#"{"open_url":"https://a.example/\nx"}"#), control)
        XCTAssertEqual(resultError(#"{"open_url":"https://a.example/\u0000"}"#), control)
        XCTAssertEqual(resultError(#"{"open_url":"https://a.example/\u007f"}"#), control)
        XCTAssertNotNil(resultError(#"{"open_url":3}"#))
        XCTAssertNotNil(resultError(#"{"open_url":{"url":"https://a.example/"}}"#))
    }

    func testCopyRuleViolations() {
        XCTAssertEqual(resultError(#"{"copy":""}"#), .invalidOutput("\"copy\" is empty"))
        XCTAssertNotNil(resultError(#"{"copy":3}"#))
        XCTAssertNotNil(resultError(#"{"copy":["a"]}"#))
    }

    func testAnInvalidEffectInvalidatesTheWholeResult() {
        XCTAssertNotNil(resultError(#"{"open_tab":{"command":["ls"]},"open_url":"file:///x"}"#))
        XCTAssertNotNil(resultError(#"{"open_tab":{"command":["ls"]},"copy":""}"#))
        XCTAssertNotNil(resultError(#"{"open_url":"https://a.example/","open_tab":{"command":[]}}"#))
    }

    // MARK: - Effects reach their seams

    /// A runner whose action prints `stdout`, decoded as the real command
    /// would decode it.
    private func runner(printing stdout: String) -> ExtensionPanelActionRunner {
        ExtensionPanelActionRunner { _, _, completion in
            completion(Result { () throws(ExtensionPanelError) in try ExtensionActionResult.decode(Data(stdout.utf8)) })
        }
    }

    func testEveryEffectReachesItsSeam() {
        let runner = runner(printing: #"{"open_tab":{"command":["ssh","it's"]},"open_url":"https://a.example/x","copy":"hello"}"#)
        let effects = Effects()
        effects.attach(to: runner)
        runner.perform(ExtensionPanelAction(id: "go", title: "Go"), rowID: "r")
        XCTAssertEqual(effects.tabs, ["ssh 'it'\\''s'"])
        XCTAssertEqual(effects.urls, [URL(string: "https://a.example/x")!])
        XCTAssertEqual(effects.copies, ["hello"])
        XCTAssertEqual(effects.failures, [])
    }

    func testEachEffectAlone() {
        let urlRunner = runner(printing: #"{"open_url":"https://a.example/"}"#)
        let urlEffects = Effects()
        urlEffects.attach(to: urlRunner)
        urlRunner.perform(ExtensionPanelAction(id: "open", title: "Open"), rowID: nil)
        XCTAssertEqual(urlEffects.urls.map(\.absoluteString), ["https://a.example/"])
        XCTAssertEqual(urlEffects.tabs + urlEffects.copies, [])

        let copyRunner = runner(printing: #"{"copy":"text"}"#)
        let copyEffects = Effects()
        copyEffects.attach(to: copyRunner)
        copyRunner.perform(ExtensionPanelAction(id: "copy", title: "Copy"), rowID: nil)
        XCTAssertEqual(copyEffects.copies, ["text"])
        XCTAssertEqual(copyEffects.tabs, [])
        XCTAssertEqual(copyEffects.urls, [])
    }

    func testAnInvalidResultCarriesOutNothing() {
        for stdout in [
            #"{"open_tab":{"command":["ls"]},"open_url":"javascript:alert(1)"}"#,
            #"{"open_tab":{"command":["ls"]},"copy":"x","open_url":"https://"}"#,
            #"{"open_url":"https://a.example/","copy":""}"#
        ] {
            let runner = runner(printing: stdout)
            let effects = Effects()
            effects.attach(to: runner)
            runner.perform(ExtensionPanelAction(id: "go", title: "Go"), rowID: nil)
            XCTAssertEqual(effects.tabs, [], stdout)
            XCTAssertEqual(effects.urls, [], stdout)
            XCTAssertEqual(effects.copies, [], stdout)
            XCTAssertEqual(effects.failures.count, 1, stdout)
            XCTAssertTrue(effects.failures[0].hasPrefix("Go: "), stdout)
        }
    }

    // MARK: - [[palette]] in the manifest

    func testPaletteEntriesParse() throws {
        let manifest = try installed(tail: """
        \(panelTable)

        [[palette]]
        title = "  New Widget  "
        action = "new"

        [[palette]]
        title = "Open Widget"
        action = "open"
        pick = true

        [[palette]]
        title = "Open First"
        action = "open"
        pick = false
        """).manifest
        XCTAssertEqual(manifest.palette, [
            ExtensionPaletteEntry(title: "New Widget", action: "new", pick: false),
            ExtensionPaletteEntry(title: "Open Widget", action: "open", pick: true),
            ExtensionPaletteEntry(title: "Open First", action: "open", pick: false)
        ])
    }

    func testPickDefaultsToFalse() throws {
        let manifest = try installed(tail: "\(panelTable)\n\n[[palette]]\ntitle = \"T\"\naction = \"a\"").manifest
        XCTAssertEqual(manifest.palette.first?.pick, false)
    }

    func testNoPaletteMeansNoEntries() throws {
        XCTAssertEqual(try installed(tail: panelTable).manifest.palette, [])
        XCTAssertEqual(try installed(id: "acme.bare", tail: "").manifest.palette, [])
    }

    func testPaletteEntryRuleViolations() throws {
        func entry(_ body: String) throws -> ExtensionManifestError? {
            try manifestError("\(panelTable)\n\n[[palette]]\ntitle = \"OK\"\naction = \"ok\"\n\n[[palette]]\n\(body)")
        }
        XCTAssertEqual(try entry("action = \"a\""), .missingField("palette[1].title"))
        XCTAssertEqual(try entry("title = 3\naction = \"a\""), .wrongType(field: "palette[1].title", expected: "a string"))
        XCTAssertEqual(try entry("title = \"   \"\naction = \"a\""), .emptyField("palette[1].title"))
        XCTAssertEqual(try entry("title = \"T\""), .missingField("palette[1].action"))
        XCTAssertEqual(try entry("title = \"T\"\naction = true"), .wrongType(field: "palette[1].action", expected: "a string"))
        XCTAssertEqual(try entry("title = \"T\"\naction = \"\""), .emptyField("palette[1].action"))
        XCTAssertEqual(try entry("title = \"T\"\naction = \"a\"\npick = \"yes\""), .wrongType(field: "palette[1].pick", expected: "a boolean"))
    }

    func testPaletteMustBeAnArrayOfTables() throws {
        XCTAssertEqual(
            try manifestError("palette = \"x\"\n\(panelTable)"),
            .wrongType(field: "palette", expected: "an array of tables"))
        XCTAssertEqual(
            try manifestError("palette = [1]\n\(panelTable)"),
            .wrongType(field: "palette[0]", expected: "a table"))
    }

    func testPaletteEntriesNeedAPanel() throws {
        let error = try manifestError("[[palette]]\ntitle = \"T\"\naction = \"a\"")
        XCTAssertEqual(error, .paletteWithoutPanel)
        XCTAssertEqual(error?.errorDescription, "\"palette\" entries need a [panel] table.")
    }

    func testDuplicatePaletteEntries() throws {
        let error = try manifestError("""
        \(panelTable)

        [[palette]]
        title = "One"
        action = "ssh"
        pick = true

        [[palette]]
        title = "Two"
        action = "ssh"
        pick = true
        """)
        XCTAssertEqual(error, .duplicatePaletteEntry(action: "ssh", pick: true))

        XCTAssertEqual(try manifestError("""
        \(panelTable)

        [[palette]]
        title = "One"
        action = "new"

        [[palette]]
        title = "Two"
        action = "new"
        pick = false
        """), .duplicatePaletteEntry(action: "new", pick: false), "an omitted pick is false")
    }

    // MARK: - The palette entry list

    private func entries(_ list: [(String, String, Bool)]) -> String {
        list.map { "[[palette]]\ntitle = \"\($0.0)\"\naction = \"\($0.1)\"\npick = \($0.2)" }.joined(separator: "\n\n")
    }

    func testCommandsFromASetOfExtensions() throws {
        let zebra = try installed(id: "acme.zebra", name: "Zebra", tail: """
        [panel]
        title = "Stripes"
        icon = "bolt"

        \(entries([("New", "new", false), ("SSH into", "ssh", true)]))
        """)
        let alphaDir = try install(id: "acme.alpha", name: "Alpha", tail: """
        [panel]
        title = "Alpha"
        icon = "icon.svg"

        \(entries([("Launch", "launch", true)]))
        """)
        try "<svg/>".write(to: alphaDir.appendingPathComponent("icon.svg"), atomically: true, encoding: .utf8)
        let alpha = InstalledExtension(manifest: try ExtensionManifest.load(from: alphaDir), folder: alphaDir, isEnabled: true)
        let disabled = try installed(id: "acme.off", name: "Beta", tail: "\(panelTable)\n\n\(entries([("Hidden", "x", false)]))", enabled: false)
        let noEntries = try installed(id: "acme.none", name: "Gamma", tail: panelTable)

        let commands = ExtensionPaletteCommand.commands(for: [zebra, disabled, noEntries, alpha])
        XCTAssertEqual(commands.map(\.title), ["Alpha: Launch", "Stripes: New", "Stripes: SSH into"])
        XCTAssertEqual(commands.map(\.symbolName), ["puzzlepiece.extension", "bolt", "bolt"])
        XCTAssertEqual(commands.map(\.entry.action), ["launch", "new", "ssh"])
        XCTAssertEqual(commands.map(\.installed.id), ["acme.alpha", "acme.zebra", "acme.zebra"])
        XCTAssertEqual(ExtensionPaletteCommand.commands(for: [disabled, noEntries]), [])
    }

    func testCommandsFollowTheRegistry() throws {
        try install(tail: "\(panelTable)\n\n\(entries([("New Widget", "new", false)]))")
        let registry = ExtensionRegistry(
            extensionsDirectory: extensionsDirectory,
            stateFileURL: base.appendingPathComponent("extensions.json"),
            removeFolder: { [fm] url in try fm.removeItem(at: url) }
        )
        registry.reload()
        XCTAssertEqual(ExtensionPaletteCommand.commands(for: registry.extensions), [], "disabled by default")

        try registry.setEnabled("acme.widgets", true)
        XCTAssertEqual(ExtensionPaletteCommand.commands(for: registry.extensions).map(\.title), ["Widgets: New Widget"])

        try registry.setEnabled("acme.widgets", false)
        XCTAssertEqual(ExtensionPaletteCommand.commands(for: registry.extensions), [])

        try registry.setEnabled("acme.widgets", true)
        try registry.uninstall("acme.widgets")
        XCTAssertEqual(ExtensionPaletteCommand.commands(for: registry.extensions), [])
    }

    // MARK: - Choosing an entry

    /// Seams for `ExtensionPaletteCommandRunner`: held panel loads, the
    /// picker, alerts, and performed actions, all recorded.
    @MainActor private final class Chooser {
        var loads: [String] = []
        var loadCompletions: [@MainActor (Result<ExtensionPanelContent, ExtensionPanelError>) -> Void] = []
        var picks: [(title: String, rows: [ExtensionPanelContent.Row])] = []
        var pickCompletions: [(ExtensionPanelContent.Row) -> Void] = []
        var alerts: [String] = []
        var performed: [(extensionID: String, action: ExtensionPanelAction, rowID: String?)] = []
        /// Where performed actions go next, if set (a runner's `perform`).
        var forward: ((ExtensionPanelAction, String?) -> Void)?

        func make() -> ExtensionPaletteCommandRunner {
            let runner = ExtensionPaletteCommandRunner(
                pickRow: { [unowned self] title, rows, completion in
                    picks.append((title, rows))
                    pickCompletions.append(completion)
                },
                performAction: { [unowned self] installed, action, rowID in
                    performed.append((installed.id, action, rowID))
                    forward?(action, rowID)
                }
            )
            runner.loadPanel = { [unowned self] installed, completion in
                loads.append(installed.id)
                loadCompletions.append(completion)
            }
            runner.showAlert = { [unowned self] title, body in alerts.append("\(title) | \(body)") }
            return runner
        }
    }

    private func command(action: String, pick: Bool) throws -> ExtensionPaletteCommand {
        let installed = try installed(tail: "\(panelTable)\n\n\(entries([("Do It", action, pick)]))")
        return try XCTUnwrap(ExtensionPaletteCommand.commands(for: [installed]).first)
    }

    private let newAction = ExtensionPanelAction(id: "new", title: "New Widget")
    private let openAction = ExtensionPanelAction(id: "open", title: "Open", confirm: "Open it?")

    private var pickContent: ExtensionPanelContent {
        ExtensionPanelContent(
            sections: [
                .init(title: "One", rows: [
                    .init(id: "w/a", title: "a", detail: "first", actions: [openAction]),
                    .init(id: "w/b", title: "b", actions: [ExtensionPanelAction(id: "other", title: "Other")]),
                    .init(id: "w/c", title: "c", detail: "third", actions: [ExtensionPanelAction(id: "x", title: "X"), openAction])
                ]),
                .init(title: "Two", rows: [
                    .init(id: "w/d", title: "d", actions: [openAction]),
                    .init(id: "w/e", title: "e")
                ])
            ],
            actions: [ExtensionPanelAction(id: "open", title: "Panel Open"), newAction]
        )
    }

    func testEveryChoiceRunsThePanelCommandFresh() throws {
        let chooser = Chooser()
        let runner = chooser.make()
        let command = try command(action: "new", pick: false)
        runner.run(command)
        XCTAssertEqual(chooser.loads, ["acme.widgets"])
        XCTAssertTrue(chooser.performed.isEmpty, "nothing runs before the panel output arrives")
        chooser.loadCompletions[0](.success(pickContent))
        runner.run(command)
        XCTAssertEqual(chooser.loads, ["acme.widgets", "acme.widgets"])
    }

    func testPanelActionFound() throws {
        let chooser = Chooser()
        let runner = chooser.make()
        runner.run(try command(action: "new", pick: false))
        chooser.loadCompletions[0](.success(pickContent))
        XCTAssertEqual(chooser.performed.map(\.action), [newAction])
        XCTAssertEqual(chooser.performed.map(\.rowID), [nil])
        XCTAssertEqual(chooser.performed.map(\.extensionID), ["acme.widgets"])
        XCTAssertEqual(chooser.alerts, [])
        XCTAssertTrue(chooser.picks.isEmpty)
    }

    func testPanelActionNotFound() throws {
        let chooser = Chooser()
        let runner = chooser.make()
        let command = try command(action: "missing", pick: false)

        runner.run(command)
        chooser.loadCompletions[0](.success(ExtensionPanelContent(message: "Login expired (run login)", actions: [newAction])))
        runner.run(command)
        chooser.loadCompletions[1](.success(pickContent))
        runner.run(command)
        chooser.loadCompletions[2](.success(ExtensionPanelContent(message: "")))

        XCTAssertEqual(chooser.alerts, [
            "Widgets: Do It | Login expired (run login)",
            "Widgets: Do It | This command is not available right now.",
            "Widgets: Do It | This command is not available right now."
        ])
        XCTAssertTrue(chooser.performed.isEmpty)
    }

    func testPickOffersExactlyTheMatchingRowsInOrder() throws {
        let chooser = Chooser()
        let runner = chooser.make()
        runner.run(try command(action: "open", pick: true))
        chooser.loadCompletions[0](.success(pickContent))

        XCTAssertEqual(chooser.picks.count, 1)
        XCTAssertEqual(chooser.picks[0].title, "Widgets: Do It")
        XCTAssertEqual(chooser.picks[0].rows.map(\.id), ["w/a", "w/c", "w/d"])
        XCTAssertEqual(chooser.picks[0].rows.map(\.detail), ["first", "third", nil])
        XCTAssertTrue(chooser.performed.isEmpty, "nothing runs until a row is picked")

        chooser.pickCompletions[0](chooser.picks[0].rows[1])
        XCTAssertEqual(chooser.performed.map(\.action), [openAction], "the row's action, not the panel's")
        XCTAssertEqual(chooser.performed.map(\.rowID), ["w/c"])
        XCTAssertEqual(chooser.alerts, [])
    }

    func testPickWithNoMatchingRows() throws {
        let chooser = Chooser()
        let runner = chooser.make()
        let command = try command(action: "new", pick: true)
        runner.run(command)
        chooser.loadCompletions[0](.success(pickContent))
        runner.run(command)
        chooser.loadCompletions[1](.success(ExtensionPanelContent(message: "Not logged in")))
        XCTAssertTrue(chooser.picks.isEmpty, "a panel action with the id does not count for pick")
        XCTAssertEqual(chooser.alerts, [
            "Widgets: Do It | This command is not available right now.",
            "Widgets: Do It | Not logged in"
        ])
        XCTAssertTrue(chooser.performed.isEmpty)
    }

    func testPickCancelledRunsNothing() throws {
        let chooser = Chooser()
        let runner = chooser.make()
        runner.run(try command(action: "open", pick: true))
        chooser.loadCompletions[0](.success(pickContent))
        XCTAssertEqual(chooser.picks.count, 1)
        // Escape closes the picker without calling its completion.
        XCTAssertTrue(chooser.performed.isEmpty)
        XCTAssertEqual(chooser.alerts, [])
    }

    func testFailingPanelRunShowsTheReason() throws {
        let chooser = Chooser()
        let runner = chooser.make()
        runner.run(try command(action: "new", pick: false))
        chooser.loadCompletions[0](.failure(.exited(status: 2, stderr: "boom")))
        runner.run(try command(action: "open", pick: true))
        chooser.loadCompletions[1](.failure(.invalidOutput("output is not valid JSON")))
        XCTAssertEqual(chooser.alerts, ["Widgets: Do It | boom", "Widgets: Do It | output is not valid JSON"])
        XCTAssertTrue(chooser.performed.isEmpty)
        XCTAssertTrue(chooser.picks.isEmpty)
    }

    func testRowPickerPanelFiltersAndPicks() {
        let picker = ExtensionRowPickerPanel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        var picked: [String] = []
        let rows = pickContent.sections.flatMap(\.rows)
        picker.show(relativeTo: window, title: "Widgets: Do It", rows: rows) { picked.append($0.id) }
        XCTAssertEqual(picker.itemCount, rows.count)
        picker.queryChanged("d")
        XCTAssertEqual(picker.itemCount, 1)
        picker.activateRow(0)
        XCTAssertEqual(picked, ["w/d"])
        picker.close()
    }

    // MARK: - Palette actions go through the shared runner

    func testPaletteRunActionAsksConfirmAndCancelRunsNothing() throws {
        let runs = HeldRuns()
        let actionRunner = runs.make()
        var asked: [String?] = []
        var answer = false
        actionRunner.confirmAction = { asked.append($0.confirm); return answer }

        let chooser = Chooser()
        chooser.forward = { actionRunner.perform($0, rowID: $1) }
        let runner = chooser.make()
        let command = try command(action: "open", pick: true)

        runner.run(command)
        chooser.loadCompletions[0](.success(pickContent))
        chooser.pickCompletions[0](chooser.picks[0].rows[0])
        XCTAssertEqual(asked, ["Open it?"])
        XCTAssertEqual(runs.calls.count, 0, "cancelled: nothing runs")

        answer = true
        runner.run(command)
        chooser.loadCompletions[1](.success(pickContent))
        chooser.pickCompletions[1](chooser.picks[1].rows[2])
        XCTAssertEqual(asked, ["Open it?", "Open it?"])
        XCTAssertEqual(runs.calls.map(\.0), ["open"])
        XCTAssertEqual(runs.calls.map(\.1), ["w/d"])
    }

    private func sidebar(with installed: InstalledExtension, runs: HeldRuns) -> SidebarContainerView {
        let container = SidebarContainerView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        container.setVisible(false)
        container.makeExtensionActionRunner = { _ in runs.make() }
        container.setExtensionPanels([installed])
        return container
    }

    func testOneActionAtATimeAcrossSidebarAndPalette() throws {
        let installed = try installed(tail: panelTable)
        let runs = HeldRuns()
        let container = sidebar(with: installed, runs: runs)
        container.showExtensionPanel("acme.widgets")
        let controller = try XCTUnwrap(container._extensionController("acme.widgets"))
        XCTAssertTrue(controller.actionRunner === container.extensionActionRunner("acme.widgets"), "one shared runner")
        controller.showFailure = { _, _ in }

        // Sidebar first: a palette action is ignored while it runs.
        controller.perform(ExtensionPanelAction(id: "open", title: "Open"), rowID: "a")
        container.performExtensionAction(newAction, rowID: nil, extensionID: "acme.widgets")
        XCTAssertEqual(runs.calls.map(\.0), ["open"])
        runs.completions[0](.success(ExtensionActionResult()))

        // Palette first: a sidebar click is ignored while it runs.
        var confirmations = 0
        controller.confirmAction = { _ in confirmations += 1; return true }
        container.performExtensionAction(newAction, rowID: nil, extensionID: "acme.widgets")
        controller.perform(openAction, rowID: "a")
        XCTAssertEqual(runs.calls.map(\.0), ["open", "new"])
        XCTAssertEqual(confirmations, 0, "an ignored request asks nothing")

        runs.completions[1](.success(ExtensionActionResult()))
        container.performExtensionAction(newAction, rowID: nil, extensionID: "acme.widgets")
        XCTAssertEqual(runs.calls.map(\.0), ["open", "new", "new"])
    }

    func testPaletteRunActionRefreshesTheSidebarPanelWhenItExists() throws {
        let installed = try installed(tail: panelTable)
        let runs = HeldRuns()
        let container = sidebar(with: installed, runs: runs)

        // No controller yet: the action runs and finishes without one.
        container.performExtensionAction(newAction, rowID: nil, extensionID: "acme.widgets")
        XCTAssertEqual(runs.calls.count, 1)
        runs.completions[0](.success(ExtensionActionResult()))
        XCTAssertTrue(container._instantiatedExtensionPanels.isEmpty, "the palette does not create the panel")

        container.showExtensionPanel("acme.widgets")
        let controller = try XCTUnwrap(container._extensionController("acme.widgets"))
        XCTAssertFalse(controller.refresher.isLoading)

        container.performExtensionAction(newAction, rowID: nil, extensionID: "acme.widgets")
        XCTAssertFalse(controller.refresher.isLoading)
        runs.completions[1](.success(ExtensionActionResult()))
        XCTAssertTrue(controller.refresher.isLoading, "the panel refreshes after a palette-run action")
    }

    func testSidebarRunnerOpensTabsThroughTheDelegatePath() throws {
        let installed = try installed(tail: panelTable)
        let runs = HeldRuns()
        let container = sidebar(with: installed, runs: runs)
        let runner = try XCTUnwrap(container.extensionActionRunner("acme.widgets"))
        XCTAssertNotNil(runner.onOpenTab)
        XCTAssertNotNil(runner.onOpenURL)
        XCTAssertNotNil(runner.onCopy)
        XCTAssertNil(container.extensionActionRunner("acme.unknown"))
    }

    func testRunnerIsReplacedWhenTheExtensionChanges() throws {
        let installed = try installed(tail: panelTable)
        let runs = HeldRuns()
        let container = sidebar(with: installed, runs: runs)
        let first = try XCTUnwrap(container.extensionActionRunner("acme.widgets"))
        XCTAssertTrue(first === container.extensionActionRunner("acme.widgets"))

        container.setExtensionPanels([])
        XCTAssertNil(container.extensionActionRunner("acme.widgets"))
        container.setExtensionPanels([installed])
        XCTAssertFalse(first === container.extensionActionRunner("acme.widgets"))
    }
}
