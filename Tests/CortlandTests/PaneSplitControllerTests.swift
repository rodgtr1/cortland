import XCTest
import AppKit
@testable import Cortland

/// Split/close/layout invariants for `PaneSplitController` — the pane tree MCP
/// pane_split/pane_close depend on, previously zero-coverage. The private
/// `panes`/`activePaneIndex`/`paneContainers` are asserted through the public
/// surface (`paneCount`, `activePane`, `activePaneID`) and delegate callbacks.
///
/// Panes are seeded with *editor* view controllers so setup spawns no shells;
/// only `splitPane` itself creates a terminal, and every such pane is shut down
/// in tearDown so no login shell leaks past the test.
@MainActor
final class PaneSplitControllerTests: XCTestCase {
    private var tempDir: URL!
    private var controller: PaneSplitController!
    private var spawnedPanes: [PaneModel] = []

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sk-pane-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        controller = PaneSplitController(config: Config())
        _ = controller.view // force loadView so rootSplitView exists
    }

    override func tearDownWithError() throws {
        for pane in spawnedPanes { pane.shutdown() } // terminate any real shells
        spawnedPanes.removeAll()
        controller = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// A shell-free editor pane backed by a real temp file.
    private func makeEditorPane() -> PaneModel {
        let url = tempDir.appendingPathComponent("f-\(UUID().uuidString).txt")
        try? Data("hello\n".utf8).write(to: url)
        let pane = PaneModel()
        pane.createEditorViewController(for: url)
        return pane
    }

    /// A tab of `count` editor panes, installed via rebuildSplitView.
    @discardableResult
    private func installTab(paneCount count: Int, active: Int = 0) -> TabModel {
        let tab = TabModel()
        tab.panes = (0..<count).map { _ in makeEditorPane() }
        tab.activePaneIndex = active
        controller.rebuildSplitView(for: tab)
        return tab
    }

    /// Split and remember the (terminal) pane so tearDown can kill its shell.
    private func split(_ direction: SplitDirection, targetPaneID: UUID? = nil, focus: Bool = true) -> PaneModel? {
        let pane = controller.splitPane(direction: direction, targetPaneID: targetPaneID, focus: focus)
        if let pane { spawnedPanes.append(pane) }
        return pane
    }

    // MARK: - rebuild

    func testRebuildInstallsAllPanesAndFocusesActive() {
        let tab = installTab(paneCount: 3, active: 1)
        XCTAssertEqual(controller.paneCount, 3)
        XCTAssertEqual(controller.activePaneID, tab.panes[1].id)
        XCTAssertNotNil(controller.activePane)
    }

    // MARK: - split

    func testSplitGrowsCountAndActivatesNewPane() {
        installTab(paneCount: 1)
        let new = split(.horizontal)
        XCTAssertNotNil(new)
        XCTAssertEqual(controller.paneCount, 2)
        XCTAssertEqual(controller.activePaneID, new?.id, "a focused split activates the new pane")
    }

    func testSplitWithFocusFalseKeepsActivePane() {
        let tab = installTab(paneCount: 1)
        let before = tab.panes[0].id
        let new = split(.vertical, focus: false)
        XCTAssertNotNil(new)
        XCTAssertEqual(controller.paneCount, 2)
        XCTAssertEqual(controller.activePaneID, before, "focus:false must not steal activation")
    }

    func testSplitRespectsMaxPanesPerTab() {
        installTab(paneCount: Limits.maxPanesPerTab)
        let overflow = split(.horizontal)
        XCTAssertNil(overflow, "splitting past maxPanesPerTab returns nil")
        XCTAssertEqual(controller.paneCount, Limits.maxPanesPerTab, "no pane added past the cap")
    }

    func testSplitWithUnknownTargetReturnsNil() {
        installTab(paneCount: 1)
        let result = split(.horizontal, targetPaneID: UUID())
        XCTAssertNil(result)
        XCTAssertEqual(controller.paneCount, 1, "an unknown target must not spawn a pane")
    }

    // MARK: - close

    func testClosePaneRemovesAndNeverDropsToZero() {
        installTab(paneCount: 2)
        controller.closePane(index: 1)
        XCTAssertEqual(controller.paneCount, 1)
        controller.closePane(index: 0) // guarded: never drops the last pane
        XCTAssertEqual(controller.paneCount, 1)
        XCTAssertNotNil(controller.activePane)
    }

    func testCloseActivePaneReturnsFalseAtSinglePane() {
        installTab(paneCount: 1)
        XCTAssertFalse(controller.closeActivePane())
        XCTAssertEqual(controller.paneCount, 1)

        installTab(paneCount: 2)
        XCTAssertTrue(controller.closeActivePane())
        XCTAssertEqual(controller.paneCount, 1)
    }

    func testCloseKeepsActiveIndexInBounds() {
        let tab = installTab(paneCount: 3)
        let survivor = tab.panes[1].id
        controller.setActivePane(index: 2)
        controller.closePane(index: 2) // closing the last/active pane
        XCTAssertEqual(controller.paneCount, 2)
        XCTAssertNotNil(controller.activePane, "active index must stay in bounds after closing the last pane")
        XCTAssertEqual(controller.activePaneID, survivor)
    }

    func testClosePaneByUnknownIDReturnsFalse() {
        installTab(paneCount: 2)
        XCTAssertFalse(controller.closePane(id: UUID()))
        XCTAssertEqual(controller.paneCount, 2)
    }

    // MARK: - focus

    func testSetActivePaneRejectsOutOfBounds() {
        let tab = installTab(paneCount: 2, active: 0)
        controller.setActivePane(index: 99)
        XCTAssertEqual(controller.activePaneID, tab.panes[0].id, "out-of-bounds index is ignored")
    }

    func testFocusNextAndPreviousWrapAround() {
        let tab = installTab(paneCount: 3)
        controller.setActivePane(index: 2)
        controller.focusNextPane()
        XCTAssertEqual(controller.activePaneID, tab.panes[0].id, "next wraps from last to first")
        controller.focusPreviousPane()
        XCTAssertEqual(controller.activePaneID, tab.panes[2].id, "previous wraps from first to last")
    }

    func testFocusIsNoOpWithSinglePane() {
        let tab = installTab(paneCount: 1)
        controller.focusNextPane()
        controller.focusPreviousPane()
        XCTAssertEqual(controller.activePaneID, tab.panes[0].id)
    }

    // MARK: - delegate

    func testDelegateReceivesAddActivateAndCloseCallbacks() {
        let recorder = RecordingDelegate()
        controller.delegate = recorder
        installTab(paneCount: 1)

        _ = split(.horizontal)
        XCTAssertEqual(recorder.added, 1, "split fires didAddPane")
        XCTAssertGreaterThanOrEqual(recorder.activated, 1, "focused split fires didActivatePane")

        controller.closePane(index: 1)
        XCTAssertEqual(recorder.closed, 1, "close fires didClosePane")
    }
}

private final class RecordingDelegate: PaneSplitControllerDelegate {
    var added = 0
    var activated = 0
    var closed = 0
    func paneSplitController(_ controller: PaneSplitController, didAddPane pane: PaneModel, at index: Int) { added += 1 }
    func paneSplitController(_ controller: PaneSplitController, didActivatePane pane: PaneModel, at index: Int) { activated += 1 }
    func paneSplitController(_ controller: PaneSplitController, didClosePane pane: PaneModel, at index: Int) { closed += 1 }
}
