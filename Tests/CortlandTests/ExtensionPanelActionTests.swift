import XCTest
import AppKit
@testable import Cortland

/// Extension panel actions: declaring them in panel output, decoding action
/// results, shell quoting, running through a fake runner, the one-at-a-time
/// rule, refresh after an action, selection across reloads, and the step to
/// "open a tab". Temp directories only, never the real ~/.config/cortland.
@MainActor
final class ExtensionPanelActionTests: XCTestCase {
    private var base: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("ExtensionPanelActionTests-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    // MARK: - Fixtures

    private func installed() throws -> InstalledExtension {
        let dir = base.appendingPathComponent("acme.widgets")
        try fm.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let manifest = """
        api_version = 1
        id = "acme.widgets"
        name = "Widgets"
        version = "0.1.0"
        command = "bin/run"

        [panel]
        title = "Widgets"
        icon = "star"
        """
        try manifest.write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        let command = dir.appendingPathComponent("bin/run")
        try "#!/bin/sh\necho '{}'\n".write(to: command, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        return InstalledExtension(manifest: try ExtensionManifest.load(from: dir), folder: dir, isEnabled: true)
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

    /// One row in one section, wrapping a row's `actions` JSON.
    private func rowJSON(actions: String) -> String {
        #"{"sections":[{"title":"S","rows":[{"id":"r","title":"R","actions":"# + actions + "}]}]}"
    }

    // MARK: - Declaring actions

    func testPanelAndRowActionsDecode() throws {
        let content = try decode("""
        {
          "actions": [ { "id": "new", "title": "New Thing" } ],
          "sections": [
            {
              "title": "Things",
              "rows": [
                {
                  "id": "thing/a", "title": "a",
                  "actions": [
                    { "id": "open", "title": "Open" },
                    { "id": "delete", "title": "Delete", "confirm": "Delete a? This cannot be undone." }
                  ]
                }
              ]
            }
          ]
        }
        """)
        XCTAssertEqual(content.actions, [ExtensionPanelAction(id: "new", title: "New Thing")])
        XCTAssertEqual(content.sections.first?.rows.first?.actions, [
            ExtensionPanelAction(id: "open", title: "Open"),
            ExtensionPanelAction(id: "delete", title: "Delete", confirm: "Delete a? This cannot be undone.")
        ])
    }

    func testActionsDefaultToEmpty() throws {
        let content = try decode(#"{"sections":[{"title":"S","rows":[{"id":"r","title":"R"}]}]}"#)
        XCTAssertEqual(content.actions, [])
        XCTAssertEqual(content.sections.first?.rows.first?.actions, [])
        XCTAssertEqual(try decode("{}").actions, [])
    }

    func testOldOutputWithoutActionsStillDecodes() throws {
        let content = try decode("""
        {"message":"m","sections":[{"title":"S","empty":"none","rows":[{"id":"a","title":"A","detail":"d","icon":"bolt"}]}]}
        """)
        XCTAssertEqual(content, ExtensionPanelContent(message: "m", sections: [
            .init(title: "S", empty: "none", rows: [.init(id: "a", title: "A", detail: "d", icon: "bolt")])
        ]))
    }

    func testActionRuleViolations() {
        // Row actions
        XCTAssertNotNil(decodeError(rowJSON(actions: #"{}"#)))
        XCTAssertNotNil(decodeError(rowJSON(actions: #"[{"title":"T"}]"#)))
        XCTAssertNotNil(decodeError(rowJSON(actions: #"[{"id":"a"}]"#)))
        XCTAssertNotNil(decodeError(rowJSON(actions: #"[{"id":1,"title":"T"}]"#)))
        XCTAssertNotNil(decodeError(rowJSON(actions: #"[{"id":"a","title":2}]"#)))
        XCTAssertNotNil(decodeError(rowJSON(actions: #"[{"id":"a","title":"T","confirm":3}]"#)))
        XCTAssertEqual(
            decodeError(rowJSON(actions: #"[{"id":"","title":"T"}]"#)),
            .invalidOutput("an action in row \"r\" has an empty \"id\""))
        XCTAssertEqual(
            decodeError(rowJSON(actions: #"[{"id":"a","title":""}]"#)),
            .invalidOutput("action \"a\" in row \"r\" has an empty \"title\""))

        // Panel actions
        XCTAssertNotNil(decodeError(#"{"actions":"x"}"#))
        XCTAssertNotNil(decodeError(#"{"actions":[{"title":"T"}]}"#))
        XCTAssertNotNil(decodeError(#"{"actions":[{"id":"a"}]}"#))
        XCTAssertEqual(
            decodeError(#"{"actions":[{"id":"","title":"T"}]}"#),
            .invalidOutput("an action in the panel has an empty \"id\""))
        XCTAssertEqual(
            decodeError(#"{"actions":[{"id":"a","title":""}]}"#),
            .invalidOutput("action \"a\" in the panel has an empty \"title\""))
    }

    func testDuplicateActionIDsAreInvalid() throws {
        XCTAssertEqual(
            decodeError(rowJSON(actions: #"[{"id":"a","title":"One"},{"id":"a","title":"Two"}]"#)),
            .invalidOutput("duplicate action id \"a\" in row \"r\""))
        XCTAssertEqual(
            decodeError(#"{"actions":[{"id":"a","title":"One"},{"id":"a","title":"Two"}]}"#),
            .invalidOutput("duplicate action id \"a\" in the panel"))

        // Unique per list: the same id on two rows, or on a row and the panel, is fine.
        let content = try decode("""
        {"actions":[{"id":"a","title":"P"}],
         "sections":[{"title":"S","rows":[
           {"id":"r1","title":"1","actions":[{"id":"a","title":"A"}]},
           {"id":"r2","title":"2","actions":[{"id":"a","title":"A"}]}]}]}
        """)
        XCTAssertEqual(content.sections.first?.rows.map(\.actions.count), [1, 1])
    }

    func testUnknownActionKeysAreIgnored() throws {
        let content = try decode("""
        {"actions":[{"id":"n","title":"N","badge":"3","style":{"x":1}}],
         "sections":[{"title":"S","rows":[{"id":"r","title":"R","actions":[{"id":"a","title":"A","shortcut":"cmd-d"}]}]}]}
        """)
        XCTAssertEqual(content.actions, [ExtensionPanelAction(id: "n", title: "N")])
        XCTAssertEqual(content.sections.first?.rows.first?.actions, [ExtensionPanelAction(id: "a", title: "A")])
    }

    // MARK: - Action results

    func testOpenTabResultDecodes() throws {
        XCTAssertEqual(
            try result(#"{"open_tab":{"command":["ssh","-p","22","host"]}}"#),
            ExtensionActionResult(openTab: ["ssh", "-p", "22", "host"]))
    }

    func testEmptyObjectMeansNothingMore() throws {
        XCTAssertEqual(try result("{}"), ExtensionActionResult(openTab: nil))
    }

    func testUnknownResultKeysAreIgnored() throws {
        XCTAssertEqual(
            try result(#"{"notify":"done","open_tab":{"command":["ls"],"title":"x"}}"#),
            ExtensionActionResult(openTab: ["ls"]))
        XCTAssertEqual(try result(#"{"notify":"done"}"#), ExtensionActionResult())
    }

    func testResultRuleViolations() {
        XCTAssertEqual(resultError("nope"), .invalidOutput("output is not valid JSON"))
        XCTAssertNotNil(resultError("[]"))
        XCTAssertNotNil(resultError(#"{"open_tab":{}}"#), "missing command")
        XCTAssertNotNil(resultError(#"{"open_tab":"ls"}"#))
        XCTAssertNotNil(resultError(#"{"open_tab":{"command":"ls"}}"#))
        XCTAssertNotNil(resultError(#"{"open_tab":{"command":["ls",1]}}"#))
        XCTAssertEqual(resultError(#"{"open_tab":{"command":[]}}"#), .invalidOutput("\"open_tab.command\" is empty"))
        XCTAssertEqual(resultError(#"{"open_tab":{"command":["ls",""]}}"#), .invalidOutput("open_tab.command[1] is empty"))
        XCTAssertEqual(
            resultError(#"{"open_tab":{"command":["echo","a\nrm -rf x"]}}"#),
            .invalidOutput("open_tab.command[1] contains a control character"))
        XCTAssertEqual(
            resultError(#"{"open_tab":{"command":["echo\u0007"]}}"#),
            .invalidOutput("open_tab.command[0] contains a control character"))
        XCTAssertEqual(
            resultError(#"{"open_tab":{"command":["echo","x\u007f"]}}"#),
            .invalidOutput("open_tab.command[1] contains a control character"))
        XCTAssertEqual(
            resultError(#"{"open_tab":{"command":["echo","\t"]}}"#),
            .invalidOutput("open_tab.command[1] contains a control character"))
    }

    // MARK: - Shell quoting

    func testPlainWordsAreLeftBare() {
        XCTAssertEqual(ShellQuoting.commandLine(["ssh", "user@host.example", "-p", "2222"]), "ssh user@host.example -p 2222")
        XCTAssertEqual(ShellQuoting.quote("--phase=default:v1"), "--phase=default:v1")
        XCTAssertEqual(ShellQuoting.quote("a,b/c_d%e+f"), "a,b/c_d%e+f")
    }

    func testUnsafeCharactersAreQuoted() {
        XCTAssertEqual(ShellQuoting.quote("two words"), "'two words'")
        XCTAssertEqual(ShellQuoting.quote("it's"), "'it'\\''s'")
        XCTAssertEqual(ShellQuoting.quote("$HOME"), "'$HOME'")
        XCTAssertEqual(ShellQuoting.quote("`whoami`"), "'`whoami`'")
        XCTAssertEqual(ShellQuoting.quote("a;rm -rf /"), "'a;rm -rf /'")
        XCTAssertEqual(ShellQuoting.quote("*"), "'*'")
        XCTAssertEqual(ShellQuoting.quote("~"), "'~'")
    }

    func testEmptyLookingEdges() {
        XCTAssertEqual(ShellQuoting.quote(""), "''")
        XCTAssertEqual(ShellQuoting.quote(" "), "' '")
        XCTAssertEqual(ShellQuoting.quote("'"), "''\\'''")
    }

    func testUnicodeIsQuoted() {
        XCTAssertEqual(ShellQuoting.quote("café"), "'café'")
        XCTAssertEqual(ShellQuoting.commandLine(["echo", "日本"]), "echo '日本'")
    }

    func testQuotedLineRoundTripsThroughAShell() throws {
        let argv = ["printf", "%s|", "it's", "$HOME", "`id`", "a;b", "café", " ", "x\"y"]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", ShellQuoting.commandLine(argv)]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(output, "it's|$HOME|`id`|a;b|café| |x\"y|")
    }

    // MARK: - Running an action (fake runner)

    private nonisolated final class FakeRunner: ProcessRunning, @unchecked Sendable {
        let result: ProcessResult
        private let lock = NSLock()
        private var _arguments: [[String]] = []
        var arguments: [[String]] {
            lock.lock(); defer { lock.unlock() }
            return _arguments
        }

        init(status: Int32 = 0, stdout: String = "", stderr: String = "") {
            result = ProcessResult(terminationStatus: status, stdout: stdout, stderr: stderr)
        }

        func run(executableURL: URL, arguments: [String], currentDirectoryURL: URL?, environment: [String: String]?) throws -> ProcessResult {
            lock.lock(); defer { lock.unlock() }
            _arguments.append(arguments)
            XCTAssertEqual(executableURL.path, "/ext/bin/run")
            XCTAssertEqual(currentDirectoryURL?.path, "/ext")
            XCTAssertEqual(environment, ["PATH": "/opt/bin:/usr/bin"])
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

    func testRowActionArguments() {
        let runner = FakeRunner(stdout: "{}")
        let result = command(runner).runAction("ssh", rowID: "widget/alpha", searchPath: "/opt/bin:/usr/bin")
        XCTAssertEqual(result, .success(ExtensionActionResult()))
        XCTAssertEqual(runner.arguments, [["action", "ssh", "widget/alpha"]])
    }

    func testPanelActionArguments() {
        let runner = FakeRunner(stdout: #"{"open_tab":{"command":["make","new"]}}"#)
        let result = command(runner).runAction("new", rowID: nil, searchPath: "/opt/bin:/usr/bin")
        XCTAssertEqual(result, .success(ExtensionActionResult(openTab: ["make", "new"])))
        XCTAssertEqual(runner.arguments, [["action", "new"]])
    }

    func testActionNonZeroExitUsesFirstStderrLine() {
        let runner = FakeRunner(status: 1, stdout: "{}", stderr: "\n  login expired (run login)  \nmore\n")
        XCTAssertEqual(
            command(runner).runAction("delete", rowID: "r", searchPath: "/opt/bin:/usr/bin"),
            .failure(.exited(status: 1, stderr: "login expired (run login)")))
    }

    func testActionInvalidJSON() {
        let runner = FakeRunner(stdout: "done!")
        XCTAssertEqual(
            command(runner).runAction("delete", rowID: "r", searchPath: "/opt/bin:/usr/bin"),
            .failure(.invalidOutput("output is not valid JSON")))
    }

    // MARK: - Action runner

    /// Action runs that finish only when the test says so.
    @MainActor private final class HeldRuns {
        var calls: [(String, String?)] = []
        var completions: [@MainActor (Result<ExtensionActionResult, ExtensionPanelError>) -> Void] = []

        func make() -> ExtensionPanelActionRunner {
            ExtensionPanelActionRunner { [unowned self] actionID, rowID, _, completion in
                calls.append((actionID, rowID))
                completions.append(completion)
            }
        }
    }

    /// Panel loads that finish only when the test says so.
    @MainActor private final class HeldLoads {
        var completions: [@MainActor (Result<ExtensionPanelContent, ExtensionPanelError>) -> Void] = []

        func make() -> ExtensionPanelRefresher {
            ExtensionPanelRefresher(refreshInterval: 60) { [unowned self] completion in
                completions.append(completion)
            }
        }
    }

    func testOnlyOneActionRunsAtATime() {
        let runs = HeldRuns()
        let runner = runs.make()
        let open = ExtensionPanelAction(id: "open", title: "Open")

        XCTAssertTrue(runner.run(open, rowID: "a"))
        XCTAssertFalse(runner.run(open, rowID: "b"))
        XCTAssertFalse(runner.run(ExtensionPanelAction(id: "new", title: "New"), rowID: nil))
        XCTAssertEqual(runs.calls.count, 1)
        XCTAssertTrue(runner.isRunning)

        runs.completions[0](.success(ExtensionActionResult()))
        XCTAssertFalse(runner.isRunning)
        XCTAssertTrue(runner.run(open, rowID: "b"))
        XCTAssertEqual(runs.calls.map(\.1), ["a", "b"])
    }

    func testViewControllerIgnoresActionsWhileOneRuns() throws {
        let runs = HeldRuns()
        let loads = HeldLoads()
        let controller = ExtensionPanelViewController(installed: try installed(), refresher: loads.make(), actionRunner: runs.make())
        var confirmations = 0
        controller.confirmAction = { _ in confirmations += 1; return true }
        _ = controller.view

        controller.perform(ExtensionPanelAction(id: "open", title: "Open"), rowID: "a")
        controller.perform(ExtensionPanelAction(id: "delete", title: "Delete", confirm: "Sure?"), rowID: "a")
        XCTAssertEqual(runs.calls.count, 1)
        XCTAssertEqual(confirmations, 0, "a request ignored while one runs asks nothing")
    }

    func testRefreshIsRequestedAfterSuccessAndFailure() throws {
        let runs = HeldRuns()
        let loads = HeldLoads()
        let controller = ExtensionPanelViewController(installed: try installed(), refresher: loads.make(), actionRunner: runs.make())
        controller.showFailure = { _, _ in }
        _ = controller.view
        let open = ExtensionPanelAction(id: "open", title: "Open")

        controller.perform(open, rowID: "a")
        XCTAssertEqual(loads.completions.count, 0)
        runs.completions[0](.success(ExtensionActionResult()))
        XCTAssertEqual(loads.completions.count, 1)
        loads.completions[0](.success(ExtensionPanelContent()))

        controller.perform(open, rowID: "a")
        runs.completions[1](.failure(.exited(status: 1, stderr: "nope")))
        XCTAssertEqual(loads.completions.count, 2)
    }

    func testRefreshAfterActionWaitsForALoadInFlight() throws {
        let runs = HeldRuns()
        let loads = HeldLoads()
        let controller = ExtensionPanelViewController(installed: try installed(), refresher: loads.make(), actionRunner: runs.make())
        _ = controller.view

        controller.refresher.refresh()
        controller.perform(ExtensionPanelAction(id: "open", title: "Open"), rowID: "a")
        runs.completions[0](.success(ExtensionActionResult()))
        XCTAssertEqual(loads.completions.count, 1, "never two loads at once")

        loads.completions[0](.success(ExtensionPanelContent()))
        XCTAssertEqual(loads.completions.count, 2, "a fresh load starts after the one in flight")
        loads.completions[1](.success(ExtensionPanelContent()))
        XCTAssertEqual(loads.completions.count, 2)
    }

    func testFailureShowsTitleAndReasonAndOpensNothing() throws {
        let runs = HeldRuns()
        let loads = HeldLoads()
        let controller = ExtensionPanelViewController(installed: try installed(), refresher: loads.make(), actionRunner: runs.make())
        var failures: [String] = []
        var opened: [String] = []
        controller.showFailure = { title, reason in failures.append("\(title): \(reason)") }
        controller.onOpenTab = { opened.append($0) }
        _ = controller.view

        controller.perform(ExtensionPanelAction(id: "delete", title: "Delete"), rowID: "a")
        runs.completions[0](.failure(.exited(status: 1, stderr: "login expired")))
        controller.perform(ExtensionPanelAction(id: "ssh", title: "SSH"), rowID: "a")
        runs.completions[1](.failure(.invalidOutput("output is not valid JSON")))

        XCTAssertEqual(failures, ["Delete: login expired", "SSH: output is not valid JSON"])
        XCTAssertEqual(opened, [])
    }

    func testOpenTabResultReachesTheSeamAsAQuotedLine() throws {
        let runs = HeldRuns()
        let loads = HeldLoads()
        let controller = ExtensionPanelViewController(installed: try installed(), refresher: loads.make(), actionRunner: runs.make())
        var opened: [String] = []
        controller.onOpenTab = { opened.append($0) }
        _ = controller.view

        controller.perform(ExtensionPanelAction(id: "ssh", title: "SSH"), rowID: "host/a")
        runs.completions[0](.success(ExtensionActionResult(openTab: ["ssh", "it's here", "--port=22"])))
        controller.perform(ExtensionPanelAction(id: "noop", title: "Nothing"), rowID: "host/a")
        runs.completions[1](.success(ExtensionActionResult()))

        XCTAssertEqual(opened, ["ssh 'it'\\''s here' --port=22"])
    }

    func testSidebarForwardsOpenTabToItsDelegatePath() throws {
        let container = SidebarContainerView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        container.setVisible(false)
        container.setExtensionPanels([try installed()])
        container.showExtensionPanel("acme.widgets")
        let controller = try XCTUnwrap(container._extensionController("acme.widgets"))
        XCTAssertNotNil(controller.onOpenTab, "the sidebar wires actions to its connect-command path")
    }

    // MARK: - Confirmation, menus, double-click

    private func controllerWithRows(
        runs: HeldRuns,
        loads: HeldLoads,
        content: ExtensionPanelContent
    ) throws -> ExtensionPanelViewController {
        let controller = ExtensionPanelViewController(installed: try installed(), refresher: loads.make(), actionRunner: runs.make())
        _ = controller.view
        controller.refresher.refresh()
        loads.completions[loads.completions.count - 1](.success(content))
        return controller
    }

    private let deleteAction = ExtensionPanelAction(id: "delete", title: "Delete", confirm: "Delete a? This cannot be undone.")

    private var sampleContent: ExtensionPanelContent {
        ExtensionPanelContent(
            sections: [.init(title: "S", rows: [
                .init(id: "a", title: "A", actions: [ExtensionPanelAction(id: "open", title: "Open"), deleteAction]),
                .init(id: "b", title: "B")
            ])],
            actions: [ExtensionPanelAction(id: "new", title: "New")]
        )
    }

    func testConfirmCancelRunsNothing() throws {
        let runs = HeldRuns()
        let loads = HeldLoads()
        let controller = try controllerWithRows(runs: runs, loads: loads, content: sampleContent)
        var asked: [String?] = []
        controller.confirmAction = { asked.append($0.confirm); return false }

        controller.perform(deleteAction, rowID: "a")
        XCTAssertEqual(asked, ["Delete a? This cannot be undone."])
        XCTAssertEqual(runs.calls.count, 0)

        controller.confirmAction = { _ in true }
        controller.perform(deleteAction, rowID: "a")
        XCTAssertEqual(runs.calls.map(\.0), ["delete"])
    }

    func testContextMenuListsRowActionsInOrder() throws {
        let runs = HeldRuns()
        let loads = HeldLoads()
        let controller = try controllerWithRows(runs: runs, loads: loads, content: sampleContent)
        // items: header "S", row a, row b
        XCTAssertEqual(controller.contextMenuItems(rowAt: 1).map(\.title), ["Open", "Delete"])
        XCTAssertEqual(controller.contextMenuItems(rowAt: 2).map(\.title), [], "a row without actions has no menu")
        XCTAssertEqual(controller.contextMenuItems(rowAt: 0).map(\.title), [], "a header has no menu")
        XCTAssertEqual(controller.contextMenuItems(rowAt: -1).map(\.title), [])
    }

    func testDoubleClickRunsTheFirstAction() throws {
        let runs = HeldRuns()
        let loads = HeldLoads()
        let controller = try controllerWithRows(runs: runs, loads: loads, content: sampleContent)
        controller.performDefaultAction(rowAt: 2)
        controller.performDefaultAction(rowAt: 0)
        XCTAssertEqual(runs.calls.count, 0)

        controller.performDefaultAction(rowAt: 1)
        XCTAssertEqual(runs.calls.map(\.0), ["open"])
        XCTAssertEqual(runs.calls.map(\.1), ["a"])
    }

    func testDoubleClickAsksWhenTheFirstActionConfirms() throws {
        let runs = HeldRuns()
        let loads = HeldLoads()
        let content = ExtensionPanelContent(sections: [.init(title: "S", rows: [.init(id: "a", title: "A", actions: [deleteAction])])])
        let controller = try controllerWithRows(runs: runs, loads: loads, content: content)
        var asked = 0
        controller.confirmAction = { _ in asked += 1; return false }
        controller.performDefaultAction(rowAt: 1)
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(runs.calls.count, 0)
    }

    func testActionsButtonFollowsPanelActions() throws {
        let runs = HeldRuns()
        let loads = HeldLoads()
        let controller = try controllerWithRows(runs: runs, loads: loads, content: sampleContent)
        XCTAssertTrue(controller.isActionsButtonVisible)
        XCTAssertEqual(controller.panelActions.map(\.id), ["new"])

        controller.refresher.refresh()
        loads.completions[1](.success(ExtensionPanelContent(sections: sampleContent.sections)))
        XCTAssertFalse(controller.isActionsButtonVisible)

        controller.refresher.refresh()
        loads.completions[2](.success(sampleContent))
        XCTAssertTrue(controller.isActionsButtonVisible)
        controller.refresher.refresh()
        loads.completions[3](.failure(.invalidOutput("bad")))
        XCTAssertFalse(controller.isActionsButtonVisible)
    }

    func testActionIconDecodes() throws {
        let json = """
        {"actions": [{"id": "new", "title": "New", "icon": "plus"}, {"id": "more", "title": "More"}]}
        """
        let content = try ExtensionPanelContent.decode(Data(json.utf8))
        XCTAssertEqual(content.actions.map(\.icon), ["plus", nil])
    }

    func testPanelActionsWithARealIconGetTheirOwnButton() throws {
        let runs = HeldRuns()
        let loads = HeldLoads()
        let content = ExtensionPanelContent(actions: [
            ExtensionPanelAction(id: "new", title: "New", icon: "plus"),
            ExtensionPanelAction(id: "bad", title: "Bad Icon", icon: "not.a.real.symbol.name"),
            ExtensionPanelAction(id: "plain", title: "Plain")
        ])
        let controller = try controllerWithRows(runs: runs, loads: loads, content: content)
        XCTAssertEqual(controller.iconPanelActions.map(\.id), ["new"])
        // An unknown symbol falls back to the menu, like an action with no icon.
        XCTAssertEqual(controller.menuPanelActions.map(\.id), ["bad", "plain"])
        XCTAssertTrue(controller.isActionsButtonVisible)
    }

    func testActionsButtonHidesWhenEveryPanelActionHasAnIcon() throws {
        let runs = HeldRuns()
        let loads = HeldLoads()
        let content = ExtensionPanelContent(actions: [ExtensionPanelAction(id: "new", title: "New", icon: "plus")])
        let controller = try controllerWithRows(runs: runs, loads: loads, content: content)
        XCTAssertEqual(controller.iconPanelActions.map(\.id), ["new"])
        XCTAssertFalse(controller.isActionsButtonVisible)
    }

    // MARK: - Choosing a folder

    func testChooseFolderDecodes() throws {
        let content = try decode(#"{"sections":[{"title":"S","rows":[{"id":"a","title":"a","actions":[{"id":"upload","title":"Upload Folder…","icon":"arrow.up","choose":"folder"},{"id":"open","title":"Open"}]}]}]}"#)
        let actions = content.sections[0].rows[0].actions
        XCTAssertEqual(actions[0].choose, .folder)
        XCTAssertNil(actions[1].choose)
    }

    func testUnknownChooseValueIsInvalid() {
        XCTAssertEqual(
            decodeError(#"{"actions":[{"id":"up","title":"Up","choose":"file"}]}"#),
            .invalidOutput(#"action "up" has "choose": "file"; the only value is "folder""#))
    }

    func testChooseWithMenuIsInvalid() {
        XCTAssertEqual(
            decodeError(#"{"actions":[{"id":"up","title":"Up","choose":"folder","menu":[{"id":"x","title":"X"}]}]}"#),
            .invalidOutput(#"action "up" in the panel has both "menu" and "choose""#))
    }

    func testChosenPathIsTheLastArgument() {
        let rowRunner = FakeRunner(stdout: "{}")
        _ = command(rowRunner).runAction("upload", rowID: "widget/alpha", path: "/tmp/my folder", searchPath: "/opt/bin:/usr/bin")
        XCTAssertEqual(rowRunner.arguments, [["action", "upload", "widget/alpha", "/tmp/my folder"]])

        let panelRunner = FakeRunner(stdout: "{}")
        _ = command(panelRunner).runAction("import", rowID: nil, path: "/tmp/in", searchPath: "/opt/bin:/usr/bin")
        XCTAssertEqual(panelRunner.arguments, [["action", "import", "/tmp/in"]])
    }

    func testChooseActionRunsWithTheChosenPath() {
        var runs: [(String, String?, String?)] = []
        let runner = ExtensionPanelActionRunner { actionID, rowID, path, completion in
            runs.append((actionID, rowID, path))
            completion(.success(ExtensionActionResult()))
        }
        var asked: [String] = []
        runner.chooseFolder = { action, completion in
            asked.append(action.id)
            completion("/Users/me/site")
        }
        runner.perform(ExtensionPanelAction(id: "upload", title: "Upload", choose: .folder), rowID: "a")
        runner.perform(ExtensionPanelAction(id: "open", title: "Open"), rowID: "a")

        XCTAssertEqual(asked, ["upload"], "only an action with choose asks for a folder")
        XCTAssertEqual(runs.map(\.0), ["upload", "open"])
        XCTAssertEqual(runs.map(\.2), ["/Users/me/site", nil])
    }

    func testCancellingTheFolderRunsNothing() {
        var runCount = 0
        let runner = ExtensionPanelActionRunner { _, _, _, completion in
            runCount += 1
            completion(.success(ExtensionActionResult()))
        }
        var confirmations = 0
        var finishes = 0
        runner.chooseFolder = { _, completion in completion(nil) }
        runner.confirmAction = { _ in confirmations += 1; return true }
        runner.onFinish = { finishes += 1 }
        runner.perform(ExtensionPanelAction(id: "upload", title: "Upload", confirm: "Sure?", choose: .folder), rowID: "a")

        XCTAssertEqual(runCount, 0)
        XCTAssertEqual(confirmations, 0)
        XCTAssertEqual(finishes, 0)
    }

    // MARK: - Row buttons

    func testRowActionWithAnIconGetsARowButtonThatRunsIt() throws {
        let runs = HeldRuns()
        let loads = HeldLoads()
        let rows = ExtensionPanelContent(sections: [.init(title: "S", rows: [
            .init(id: "a", title: "a", actions: [
                ExtensionPanelAction(id: "open", title: "Open"),
                ExtensionPanelAction(id: "upload", title: "Upload", icon: "arrow.up"),
                ExtensionPanelAction(id: "odd", title: "Odd", icon: "not.a.real.symbol.name")
            ])
        ])])
        let controller = try controllerWithRows(runs: runs, loads: loads, content: rows)
        let index = try XCTUnwrap(controller.items.firstIndex(of: .row(rows.sections[0].rows[0])))
        let table = NSTableView()
        let cell = try XCTUnwrap(controller.tableView(table, viewFor: nil, row: index) as? ExtensionPanelRowCellView)

        XCTAssertEqual(cell.actionButtons.map(\.toolTip), ["Upload"])
        XCTAssertEqual(controller.contextMenuItems(rowAt: index).map(\.title), ["Open", "Upload", "Odd"])

        cell.actionButtons[0].performClick(nil)
        XCTAssertEqual(runs.calls.map(\.0), ["upload"])
        XCTAssertEqual(runs.calls.map(\.1), ["a"])
    }

    // MARK: - Selection across reloads

    private func content(_ rows: [(String, String)]) -> ExtensionPanelContent {
        ExtensionPanelContent(sections: [.init(title: "S", rows: rows.map { .init(id: $0.0, title: $0.0, detail: $0.1) })])
    }

    func testSelectionIsRestoredByRowIDAfterAContentChange() throws {
        let runs = HeldRuns()
        let loads = HeldLoads()
        let controller = try controllerWithRows(runs: runs, loads: loads, content: content([("a", "10h left"), ("b", "5h left")]))
        controller.selectRow(id: "b")
        XCTAssertEqual(controller.selectedRowID, "b")

        // b's detail changes and a new row moves it down one place.
        controller.refresher.refresh()
        loads.completions[1](.success(content([("new", "1h left"), ("a", "9h left"), ("b", "4h left")])))
        XCTAssertEqual(controller.selectedRowID, "b")
    }

    func testSelectionIsClearedWhenTheRowIsGone() throws {
        let runs = HeldRuns()
        let loads = HeldLoads()
        let controller = try controllerWithRows(runs: runs, loads: loads, content: content([("a", "x"), ("b", "y")]))
        controller.selectRow(id: "a")

        controller.refresher.refresh()
        loads.completions[1](.success(content([("b", "y"), ("c", "z")])))
        XCTAssertNil(controller.selectedRowID)
    }
}
