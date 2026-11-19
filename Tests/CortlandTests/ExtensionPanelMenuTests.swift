import XCTest
import AppKit
@testable import Cortland

/// Action menus in extension panels: decoding `menu`, its rules, the menus
/// built for a top-bar button, the Actions menu, and a row's context menu,
/// and leaves running through the shared action runner. Temp directories
/// only, never the real ~/.config/cortland.
@MainActor
final class ExtensionPanelMenuTests: XCTestCase {
    private var base: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("ExtensionPanelMenuTests-\(UUID().uuidString)")
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

    /// A panel with one panel action `new` whose `menu` is `menu`.
    private func panelJSON(menu: String, extra: String = "") -> String {
        #"{"actions":[{"id":"new","title":"New Widget","icon":"plus"\#(extra),"menu":"# + menu + "}]}"
    }

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

    private func makeController(
        runs: HeldRuns,
        loads: HeldLoads,
        content: ExtensionPanelContent
    ) throws -> ExtensionPanelViewController {
        let controller = ExtensionPanelViewController(installed: try installed(), refresher: loads.make(), actionRunner: runs.make())
        controller.showMenu = { _, _ in XCTFail("no menu should pop up here") }
        _ = controller.view
        controller.refresher.refresh()
        loads.completions[loads.completions.count - 1](.success(content))
        return controller
    }

    private let widgetMenu: [ExtensionPanelMenuItem] = [
        .init(id: "new", title: "New Widget"),
        .init(id: "new-from", title: "New Widget from Template", menu: [
            .init(id: "launch", title: "alpha", row: "template/alpha"),
            .init(id: "launch", title: "beta", row: "template/beta")
        ])
    ]

    /// Titles of `items`, with a submenu's titles in brackets after its item.
    private func outline(_ items: [NSMenuItem]) -> [String] {
        items.flatMap { item -> [String] in
            guard let submenu = item.submenu else { return [item.title] }
            return [item.title, "[" + outline(submenu.items).joined(separator: ", ") + "]"]
        }
    }

    /// Chooses `item` as a click in its menu would.
    private func choose(_ item: NSMenuItem) throws {
        let menu = try XCTUnwrap(item.menu)
        menu.performActionForItem(at: menu.index(of: item))
    }

    // MARK: - Decoding

    func testPanelActionWithNestedMenuDecodes() throws {
        let content = try decode("""
        {
          "actions": [
            {
              "id": "new", "title": "New Widget", "icon": "plus",
              "menu": [
                { "id": "new", "title": "New Widget" },
                {
                  "id": "new-from", "title": "New Widget from Template",
                  "menu": [
                    { "id": "launch", "title": "alpha", "row": "template/alpha" },
                    { "id": "launch", "title": "beta", "row": "template/beta", "confirm": "Sure?" }
                  ]
                }
              ]
            }
          ]
        }
        """)
        let action = try XCTUnwrap(content.actions.first)
        XCTAssertEqual(action.id, "new")
        XCTAssertEqual(action.icon, "plus")
        XCTAssertEqual(action.menu, [
            .init(id: "new", title: "New Widget"),
            .init(id: "new-from", title: "New Widget from Template", menu: [
                .init(id: "launch", title: "alpha", row: "template/alpha"),
                .init(id: "launch", title: "beta", confirm: "Sure?", row: "template/beta")
            ])
        ])
        XCTAssertNil(action.menu?[0].rowID, "no row runs as a panel action")
        XCTAssertEqual(action.menu?[1].menu?[0].rowID, "template/alpha")
    }

    func testRowActionMenuAndEmptyRowDecode() throws {
        let content = try decode("""
        {"sections":[{"title":"S","rows":[{"id":"r","title":"R","actions":[
          {"id":"more","title":"More","menu":[{"id":"a","title":"A","row":""},{"id":"a","title":"A2","row":"x/1"}]}]}]}]}
        """)
        let menu = try XCTUnwrap(content.sections.first?.rows.first?.actions.first?.menu)
        XCTAssertEqual(menu.map(\.id), ["a", "a"], "menu items may share an id")
        XCTAssertNil(menu[0].rowID, "an empty row is a panel action")
        XCTAssertEqual(menu[1].rowID, "x/1")
    }

    func testOldOutputWithoutMenuDecodesAsBefore() throws {
        let content = try decode(#"{"actions":[{"id":"new","title":"New","icon":"plus"}]}"#)
        XCTAssertEqual(content.actions, [ExtensionPanelAction(id: "new", title: "New", icon: "plus")])
        XCTAssertNil(content.actions[0].menu)
    }

    func testUnknownMenuItemKeysAreIgnored() throws {
        let content = try decode(panelJSON(menu: #"[{"id":"a","title":"A","icon":"star","badge":2}]"#))
        XCTAssertEqual(content.actions[0].menu, [.init(id: "a", title: "A")])
    }

    // MARK: - Rules

    func testMenuRuleViolations() {
        XCTAssertEqual(
            decodeError(panelJSON(menu: "[]")),
            .invalidOutput("action \"new\" in the panel has an empty \"menu\""))
        XCTAssertEqual(
            decodeError(panelJSON(menu: #"[{"id":"a","title":"A","menu":[]}]"#)),
            .invalidOutput("action \"new\" in the panel has an empty \"menu\""))
        XCTAssertNotNil(decodeError(panelJSON(menu: #"[{"title":"A"}]"#)), "missing id")
        XCTAssertNotNil(decodeError(panelJSON(menu: #"[{"id":"a"}]"#)), "missing title")
        XCTAssertNotNil(decodeError(panelJSON(menu: #"{"id":"a","title":"A"}"#)), "not an array")
        XCTAssertNotNil(decodeError(panelJSON(menu: #"[{"id":"a","title":"A","row":3}]"#)), "row of the wrong type")
        XCTAssertEqual(
            decodeError(panelJSON(menu: #"[{"id":"","title":"A"}]"#)),
            .invalidOutput("a menu item in action \"new\" in the panel has an empty \"id\""))
        XCTAssertEqual(
            decodeError(panelJSON(menu: #"[{"id":"a","title":""}]"#)),
            .invalidOutput("menu item \"a\" in action \"new\" in the panel has an empty \"title\""))
        XCTAssertEqual(
            decodeError(panelJSON(menu: #"[{"id":"p","title":"P","row":"x/1","menu":[{"id":"a","title":"A"}]}]"#)),
            .invalidOutput("menu item \"P\" in action \"new\" in the panel has both \"menu\" and \"row\""))
        XCTAssertEqual(
            decodeError(panelJSON(menu: #"[{"id":"p","title":"P","confirm":"Sure?","menu":[{"id":"a","title":"A"}]}]"#)),
            .invalidOutput("menu item \"P\" in action \"new\" in the panel has both \"menu\" and \"confirm\""))
        // On a row action too.
        XCTAssertEqual(
            decodeError(#"{"sections":[{"title":"S","rows":[{"id":"r","title":"R","actions":[{"id":"m","title":"M","menu":[]}]}]}]}"#),
            .invalidOutput("action \"m\" in row \"r\" has an empty \"menu\""))
    }

    func testThreeMenusDeepIsAllowedAndFourIsNot() throws {
        let three = #"[{"id":"1","title":"1","menu":[{"id":"2","title":"2","menu":[{"id":"3","title":"3"}]}]}]"#
        XCTAssertNoThrow(try decode(panelJSON(menu: three)))

        let four = #"[{"id":"1","title":"1","menu":[{"id":"2","title":"2","menu":[{"id":"3","title":"3","menu":[{"id":"4","title":"4"}]}]}]}]"#
        XCTAssertEqual(
            decodeError(panelJSON(menu: four)),
            .invalidOutput("action \"new\" in the panel nests menus more than 3 deep"))
    }

    func testActionListRulesAreUnchanged() {
        XCTAssertEqual(
            decodeError(#"{"actions":[{"id":"a","title":"One","menu":[{"id":"x","title":"X"}]},{"id":"a","title":"Two"}]}"#),
            .invalidOutput("duplicate action id \"a\" in the panel"))
    }

    // MARK: - Menus built

    func testTopBarButtonMenu() throws {
        let runs = HeldRuns()
        let loads = HeldLoads()
        let action = ExtensionPanelAction(id: "new", title: "New Widget", icon: "plus", menu: widgetMenu)
        let controller = try makeController(runs: runs, loads: loads, content: ExtensionPanelContent(actions: [action]))
        let menu = try XCTUnwrap(controller.buttonMenu(for: action))
        XCTAssertEqual(outline(menu.items), ["New Widget", "New Widget from Template", "[alpha, beta]"])
        XCTAssertNil(menu.items[0].submenu)
        XCTAssertNil(controller.buttonMenu(for: ExtensionPanelAction(id: "plain", title: "Plain", icon: "plus")))
    }

    func testActionsMenuShowsAMenuActionAsASubmenu() throws {
        let runs = HeldRuns()
        let loads = HeldLoads()
        let content = ExtensionPanelContent(actions: [
            ExtensionPanelAction(id: "sync", title: "Sync"),
            ExtensionPanelAction(id: "new", title: "New Widget", menu: widgetMenu),
            ExtensionPanelAction(id: "help", title: "Help")
        ])
        let controller = try makeController(runs: runs, loads: loads, content: content)
        XCTAssertEqual(
            outline(controller.actionsMenuItems()),
            ["Sync", "New Widget", "[New Widget, New Widget from Template, [alpha, beta]]", "Help"])
    }

    func testRowContextMenuShowsAMenuActionAsASubmenu() throws {
        let runs = HeldRuns()
        let loads = HeldLoads()
        let content = ExtensionPanelContent(sections: [.init(title: "S", rows: [
            .init(id: "w/a", title: "a", actions: [
                ExtensionPanelAction(id: "open", title: "Open"),
                ExtensionPanelAction(id: "copy", title: "Copy As", menu: [
                    .init(id: "copy-name", title: "Name", row: "w/a"),
                    .init(id: "copy-url", title: "URL", row: "w/a")
                ])
            ])
        ])])
        let controller = try makeController(runs: runs, loads: loads, content: content)
        XCTAssertEqual(outline(controller.contextMenuItems(rowAt: 1)), ["Open", "Copy As", "[Name, URL]"])
    }

    // MARK: - Choosing a leaf

    func testChoosingLeavesRunsTheirIdsAndRows() throws {
        let runs = HeldRuns()
        let loads = HeldLoads()
        let action = ExtensionPanelAction(id: "new", title: "New Widget", icon: "plus", menu: widgetMenu)
        let controller = try makeController(runs: runs, loads: loads, content: ExtensionPanelContent(actions: [action]))
        let menu = try XCTUnwrap(controller.buttonMenu(for: action))

        try choose(menu.items[0])
        runs.completions[0](.success(ExtensionActionResult()))
        loads.completions[1](.success(ExtensionPanelContent(actions: [action])))
        let submenu = try XCTUnwrap(menu.items[1].submenu)
        try choose(submenu.items[1])
        runs.completions[1](.success(ExtensionActionResult()))

        XCTAssertEqual(runs.calls.map(\.0), ["new", "launch"])
        XCTAssertEqual(runs.calls.map(\.1), [nil, "template/beta"])
        XCTAssertEqual(loads.completions.count, 3, "each run refreshes the panel")
    }

    func testRowContextMenuLeafWithoutRowRunsAsAPanelAction() throws {
        let runs = HeldRuns()
        let loads = HeldLoads()
        let content = ExtensionPanelContent(sections: [.init(title: "S", rows: [
            .init(id: "w/a", title: "a", actions: [
                ExtensionPanelAction(id: "more", title: "More", menu: [.init(id: "refresh-all", title: "Refresh All")])
            ])
        ])])
        let controller = try makeController(runs: runs, loads: loads, content: content)
        let parent = try XCTUnwrap(controller.contextMenuItems(rowAt: 1).first)
        let submenu = try XCTUnwrap(parent.submenu)
        submenu.performActionForItem(at: 0)
        XCTAssertEqual(runs.calls.map(\.0), ["refresh-all"])
        XCTAssertEqual(runs.calls.map(\.1), [nil])
    }

    func testLeafConfirmAndCancelGoThroughTheRunner() throws {
        let runs = HeldRuns()
        let loads = HeldLoads()
        let action = ExtensionPanelAction(id: "more", title: "More", menu: [
            .init(id: "delete", title: "Delete beta", confirm: "Delete beta?", row: "w/beta")
        ])
        let controller = try makeController(runs: runs, loads: loads, content: ExtensionPanelContent(actions: [action]))
        var asked: [String?] = []
        var failures: [String] = []
        controller.showFailure = { title, reason in failures.append("\(title): \(reason)") }
        let parent = try XCTUnwrap(controller.actionsMenuItems().first)
        let submenu = try XCTUnwrap(parent.submenu)
        let choose = { submenu.performActionForItem(at: 0) }

        controller.confirmAction = { asked.append($0.confirm); return false }
        choose()
        XCTAssertEqual(asked, ["Delete beta?"])
        XCTAssertEqual(runs.calls.count, 0, "Cancel runs nothing")

        controller.confirmAction = { _ in true }
        choose()
        XCTAssertEqual(runs.calls.map(\.0), ["delete"])
        XCTAssertEqual(runs.calls.map(\.1), ["w/beta"])

        choose()
        XCTAssertEqual(runs.calls.count, 1, "one action at a time")

        runs.completions[0](.failure(.exited(status: 1, stderr: "not allowed")))
        XCTAssertEqual(failures, ["Delete beta: not allowed"], "the failure alert uses the leaf's title")
    }

    // MARK: - What does not run

    func testTopBarButtonWithAMenuShowsItAndRunsNothing() throws {
        let runs = HeldRuns()
        let loads = HeldLoads()
        let content = ExtensionPanelContent(actions: [
            ExtensionPanelAction(id: "new", title: "New Widget", icon: "plus", menu: widgetMenu),
            ExtensionPanelAction(id: "sync", title: "Sync", icon: "arrow.triangle.2.circlepath")
        ])
        let controller = try makeController(runs: runs, loads: loads, content: content)
        var shown: [[String]] = []
        controller.showMenu = { menu, _ in shown.append(menu.items.map(\.title)) }
        XCTAssertEqual(controller.iconActionButtons.count, 2)

        controller.iconActionButtons[0].performClick(nil)
        XCTAssertEqual(shown, [["New Widget", "New Widget from Template"]])
        XCTAssertEqual(runs.calls.count, 0)

        controller.iconActionButtons[1].performClick(nil)
        XCTAssertEqual(shown.count, 1, "a button without a menu runs instead")
        XCTAssertEqual(runs.calls.map(\.0), ["sync"])
        XCTAssertEqual(runs.calls.map(\.1), [nil])
    }

    func testDoubleClickOnARowWhoseFirstActionHasAMenuRunsNothing() throws {
        let runs = HeldRuns()
        let loads = HeldLoads()
        let content = ExtensionPanelContent(sections: [.init(title: "S", rows: [
            .init(id: "w/a", title: "a", actions: [
                ExtensionPanelAction(id: "copy", title: "Copy As", menu: [.init(id: "copy-name", title: "Name", row: "w/a")]),
                ExtensionPanelAction(id: "open", title: "Open")
            ])
        ])])
        let controller = try makeController(runs: runs, loads: loads, content: content)
        controller.performDefaultAction(rowAt: 1)
        XCTAssertEqual(runs.calls.count, 0)
    }
}
