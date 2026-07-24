import XCTest
import AppKit
@testable import Cortland

/// D12: sidebar panels are instantiated lazily — each controller (and its
/// FSEvents watcher / git polling) is created only the first time its panel is
/// shown, not eagerly at startup.
@MainActor
final class SidebarLazyPanelTests: XCTestCase {
    func testNoPanelsInstantiatedAtStartup() {
        let container = SidebarContainerView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        // Nothing has been shown, so no controller — and no file-tree watcher or
        // git polling — should exist yet.
        XCTAssertTrue(container._instantiatedPanels.isEmpty)
    }

    func testShowingAPanelInstantiatesOnlyThatPanel() {
        let container = SidebarContainerView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))

        container.showPanel(.hosts)
        XCTAssertEqual(container._instantiatedPanels, [.hosts])
        // The expensive panels stayed lazy.
        XCTAssertFalse(container._instantiatedPanels.contains(.files))
        XCTAssertFalse(container._instantiatedPanels.contains(.git))

        container.showPanel(.agents)
        XCTAssertEqual(container._instantiatedPanels, [.hosts, .agents])
    }

    func testSeedingDirectoryThenShowingGitAndSearchDoesNotCrash() {
        let container = SidebarContainerView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))

        // A directory pushed before any panel exists is cached, then applied when
        // the panel is first created — the seed runs before the view loads, so
        // the git model / search field don't exist yet. A non-git temp dir keeps
        // the git model out of polling. This would crash pre-fix (nil model/field).
        container.updateFileTree(path: NSTemporaryDirectory())
        XCTAssertTrue(container._instantiatedPanels.isEmpty)

        container.showPanel(.git)
        container.showPanel(.search)
        XCTAssertEqual(container._instantiatedPanels, [.git, .search])
    }

    func testReshowingAPanelReusesTheSameController() {
        let container = SidebarContainerView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))

        container.showPanel(.hosts)
        container.showPanel(.agents)
        container.showPanel(.hosts)
        // Switching back doesn't create a second Hosts controller.
        XCTAssertEqual(container._instantiatedPanels, [.hosts, .agents])
    }

    func testBecomingVisibleMaterializesCurrentPanel() {
        let container = SidebarContainerView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))

        // Pushing a directory before any panel is shown must NOT instantiate a
        // panel — it's cached and applied when the panel is first created.
        container.updateFileTree(path: NSTemporaryDirectory())
        XCTAssertTrue(container._instantiatedPanels.isEmpty)

        // toggleSidebar bypasses showPanel: making the sidebar visible must still
        // mount the current (default .files) panel rather than leave it blank.
        container.setVisible(true)
        XCTAssertEqual(container._instantiatedPanels, [.files])
    }
}
