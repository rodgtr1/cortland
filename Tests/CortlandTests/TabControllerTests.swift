import XCTest
import AppKit
@testable import Cortland

/// Tab lifecycle invariants for `TabController` — create/switch/close/move,
/// active-tab tracking, and per-tab split-controller wiring — previously
/// zero-coverage. `createNewTab`/`closeTab` spawn and reap real login shells;
/// tearDown closes every tab and shuts down the survivor's panes so none leak.
@MainActor
final class TabControllerTests: XCTestCase {
    private var host: StubTabHost!
    private var tc: TabController!

    override func setUp() {
        super.setUp()
        host = StubTabHost()
        tc = TabController(host: host)
    }

    override func tearDown() {
        while tc.tabs.count > 1 { tc.closeTab(index: tc.tabs.count - 1) } // reaps their shells
        tc.activeTab?.panes.forEach { $0.shutdown() }
        tc = nil
        host = nil
        super.tearDown()
    }

    private func createTabs(_ n: Int) {
        for _ in 0..<n { tc.createNewTab() }
    }

    // MARK: - create

    func testCreateNewTabInstallsAndActivates() {
        tc.createNewTab()
        XCTAssertEqual(tc.tabs.count, 1)
        XCTAssertEqual(tc.activeTabIndex, 0)
        XCTAssertEqual(tc.activeTab?.isActive, true)
        XCTAssertNotNil(tc.currentSplitController)
        XCTAssertNotNil(tc.splitController(forTab: tc.tabs[0].id))
    }

    func testExactlyOneTabActiveAfterMultipleCreates() {
        createTabs(3)
        XCTAssertEqual(tc.tabs.count, 3)
        XCTAssertEqual(tc.tabs.filter { $0.isActive }.count, 1, "only one tab may be active at a time")
        XCTAssertEqual(tc.activeTab?.id, tc.tabs[tc.activeTabIndex].id)
        XCTAssertEqual(tc.activeTab?.isActive, true)
    }

    // MARK: - switch

    func testSwitchToTabMovesActiveFlagAndController() {
        createTabs(2)
        tc.switchToTab(index: 0)
        XCTAssertEqual(tc.activeTabIndex, 0)
        XCTAssertEqual(tc.tabs[0].isActive, true)
        XCTAssertEqual(tc.tabs[1].isActive, false)
        XCTAssertTrue(tc.currentSplitController === tc.splitController(forTab: tc.tabs[0].id))
    }

    func testSwitchToSameOrOutOfRangeIsNoOp() {
        createTabs(2)
        let active = tc.activeTabIndex
        tc.switchToTab(index: active)
        XCTAssertEqual(tc.activeTabIndex, active)
        tc.switchToTab(index: 99)
        XCTAssertEqual(tc.activeTabIndex, active, "out-of-range switch is ignored")
    }

    // MARK: - close

    func testCloseCurrentTabNeverDropsBelowOne() {
        tc.createNewTab()
        tc.closeCurrentTab()
        XCTAssertEqual(tc.tabs.count, 1, "the last tab can't be closed")
    }

    func testCloseTabPromotesSurvivorToActive() {
        createTabs(2)
        tc.closeTab(index: 0)
        XCTAssertEqual(tc.tabs.count, 1)
        XCTAssertEqual(tc.activeTab?.isActive, true, "a survivor must be marked active")
    }

    func testCloseActiveTabKeepsIndexInBoundsAndAttachesController() {
        createTabs(3)
        tc.switchToTab(index: 2)
        tc.closeTab(index: 2)
        XCTAssertEqual(tc.tabs.count, 2)
        XCTAssertEqual(tc.activeTabIndex, 1, "closing the last/active tab clamps the index")
        XCTAssertEqual(tc.activeTab?.isActive, true)
        XCTAssertTrue(tc.currentSplitController === tc.splitController(forTab: tc.activeTab!.id))
    }

    func testCloseTabRemovesItsSplitController() {
        createTabs(2)
        let closedID = tc.tabs[1].id
        tc.closeTab(index: 1)
        XCTAssertNil(tc.splitController(forTab: closedID), "closing a tab drops its split controller")
    }

    // MARK: - move

    func testMoveTabPreservesActiveTabIdentity() {
        createTabs(3)
        tc.switchToTab(index: 0)
        let activeID = tc.activeTab?.id
        tc.moveTab(from: 0, to: 2)
        XCTAssertEqual(tc.activeTab?.id, activeID, "the moved active tab stays active")
        XCTAssertEqual(tc.activeTabIndex, 2, "active index follows the moved tab")
        XCTAssertEqual(tc.tabs.count, 3)
    }

    func testMoveTabToSameIndexIsNoOp() {
        createTabs(2)
        let order = tc.tabs.map(\.id)
        tc.moveTab(from: 0, to: 0)
        XCTAssertEqual(tc.tabs.map(\.id), order)
    }
}

@MainActor
private final class StubTabHost: TabHost {
    let contentView = NSView()
    let config = Config()
    var tabContentView: NSView { contentView }
    var tabConfig: Config { config }
    func reloadTabBar() {}
    func syncSidebarToActiveTab() {}
    func refreshAgentsBadge() {}
    func updateSidebarDirectory(_ path: String) {}
    func confirmMouseClose(target: String, panes: [PaneModel]) -> Bool { true }
}
