import XCTest
import AppKit
import CortlandTelemetryCore
@testable import Cortland

/// `pane_close` over IPC must not drop an editor's unsaved buffer: closePane(id:)
/// skips the confirm prompt the mouse and keyboard paths show.
@MainActor
final class AutomationPaneCloseTests: XCTestCase {
    private final class FakeHost: AutomationHost {
        var tab: TabModel
        let controller: PaneSplitController
        init(tab: TabModel, controller: PaneSplitController) {
            self.tab = tab
            self.controller = controller
        }
        var automationTabs: [TabModel] { [tab] }
        var activeAutomationTabID: UUID? { tab.id }
        var telemetryRates: [String: TelemetryRate] { [:] }
        func automationSplitController(forTab tabID: UUID) -> PaneSplitController? { controller }
        func automationCreateNewTab(workingDirectory: String?) -> Bool { false }
        func automationOpenFile(_ url: URL) {}
        func automationSetActiveTabAgentState(_ state: AgentState) {}
        var shouldAutoApproveEdits: Bool { false }
        var approvalConfig: ApprovalConfig { ApprovalConfig() }
        var automationWindow: NSWindow? { nil }
        func workingDirectory(forPane paneID: UUID?) -> String? { nil }
    }

    private final class ResponseBox: @unchecked Sendable {
        var response: IPCResponse?
    }

    private var tempDir: URL!
    private var controller: PaneSplitController!
    private var tab: TabModel!
    private var host: FakeHost!
    private var coordinator: AutomationCoordinator!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sk-pane-close-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        controller = PaneSplitController(config: Config())
        _ = controller.view
        tab = TabModel()
        tab.panes = [Self.makeEditorPane(in: tempDir), Self.makeEditorPane(in: tempDir)]
        tab.activePaneIndex = 0
        controller.rebuildSplitView(for: tab)
        host = FakeHost(tab: tab, controller: controller)
        coordinator = AutomationCoordinator(host: host)
    }

    override func tearDownWithError() throws {
        coordinator = nil
        host = nil
        controller = nil
        tab = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private static func makeEditorPane(in dir: URL) -> PaneModel {
        let url = dir.appendingPathComponent("f-\(UUID().uuidString).txt")
        try? Data("hello\n".utf8).write(to: url)
        let pane = PaneModel()
        pane.createEditorViewController(for: url)
        return pane
    }

    private func close(_ paneID: UUID) -> IPCResponse? {
        let box = ResponseBox()
        coordinator.ipcServer(
            IPCServer.shared,
            didReceiveCommand: .paneClose(paneID: paneID),
            onClientDisconnect: { _ in },
            completion: { box.response = $0 }
        )
        return box.response
    }

    func testCloseRefusesEditorWithUnsavedChanges() throws {
        let dirty = tab.panes[1]
        let editor = try XCTUnwrap(dirty.editorViewController)
        editor.isModified = true

        let response = try XCTUnwrap(close(dirty.id))
        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.error?.contains("unsaved changes") == true, response.error ?? "nil")
        XCTAssertEqual(controller.paneCount, 2, "the dirty pane must stay open")
    }

    func testCloseStillClosesCleanEditor() throws {
        let clean = tab.panes[1]
        let response = try XCTUnwrap(close(clean.id))
        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(controller.paneCount, 1)
    }
}
