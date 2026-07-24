import XCTest
import CortlandProInterface
@testable import Cortland

/// The registry's free-tier contract: nothing is registered unless an official
/// build fills it in, and every slot is independently optional so one
/// registered feature can't imply another.
@MainActor
final class ProFeaturesTests: XCTestCase {
    override func tearDown() {
        ProFeatures.reset()
        super.tearDown()
    }

    func testAPublicBuildRegistersNothing() throws {
        #if CORTLAND_PRO
        throw XCTSkip("Pro build: the registry is filled at launch")
        #else
        XCTAssertNil(ProFeatures.recall)
        XCTAssertNil(ProFeatures.approvalDesk)
        XCTAssertNil(ProFeatures.costReporting)
        XCTAssertNil(ProFeatures.worktreeLaunch)
        XCTAssertFalse(ProFeatures.isProBuild)
        #endif
    }

    func testSlotsAreIndependent() {
        ProFeatures.worktreeLaunch = StubWorktreeLaunch()
        XCTAssertTrue(ProFeatures.isProBuild)
        XCTAssertNotNil(ProFeatures.worktreeLaunch)
        XCTAssertNil(ProFeatures.recall)
        XCTAssertNil(ProFeatures.approvalDesk)
        XCTAssertNil(ProFeatures.costReporting)
    }

    func testResetClearsEverySlot() {
        ProFeatures.worktreeLaunch = StubWorktreeLaunch()
        ProFeatures.reset()
        XCTAssertFalse(ProFeatures.isProBuild)
    }

    /// The app publishes its palette into the seam, so Pro views paint with the
    /// same colors as the rest of the chrome rather than the system fallback.
    func testBootstrapPublishesTheAppPalette() {
        ProBridge.bootstrap()
        XCTAssertEqual(ProTheme.colors.accent, AppTheme.accent)
        XCTAssertEqual(ProTheme.colors.mutedText, AppTheme.mutedText)
        XCTAssertEqual(ProTheme.colors.windowBackground, AppTheme.windowBackground)
    }
}

private final class StubWorktreeLaunch: WorktreeLaunchProviding {
    var agentChoices: [String] { ["None"] }
    func launchCommand(for choice: String) -> [String]? { nil }
}
