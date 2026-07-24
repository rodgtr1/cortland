import XCTest
import CortlandProInterface
@testable import Cortland

/// Free worktrees: create, open, remove and merge all work; what's missing is
/// the create sheet's agent picker, so a new worktree opens a plain terminal.
@MainActor
final class WorktreeLaunchSeamTests: XCTestCase {
    override func tearDown() {
        ProFeatures.reset()
        super.tearDown()
    }

    func testWorktreeLaunchIsUnregisteredByDefault() throws {
        #if CORTLAND_PRO
        throw XCTSkip("Pro build: worktree launch is registered at launch")
        #else
        XCTAssertNil(ProFeatures.worktreeLaunch)
        #endif
    }

    /// The sheet asks the provider what to offer, so with none there is nothing
    /// to offer and no command can be produced.
    func testNoProviderMeansNoChoicesAndNoCommand() throws {
        #if CORTLAND_PRO
        throw XCTSkip("Pro build: worktree launch is registered at launch")
        #else
        XCTAssertNil(ProFeatures.worktreeLaunch?.agentChoices)
        XCTAssertNil(ProFeatures.worktreeLaunch?.launchCommand(for: "Claude") ?? nil)
        #endif
    }

    func testAProviderSuppliesTheChoicesTheSheetShows() {
        ProFeatures.worktreeLaunch = StubWorktreeLaunch()
        XCTAssertEqual(ProFeatures.worktreeLaunch?.agentChoices, ["None", "Claude"])
        XCTAssertEqual(ProFeatures.worktreeLaunch?.launchCommand(for: "Claude"), ["claude"])
        XCTAssertNil(ProFeatures.worktreeLaunch?.launchCommand(for: "None") ?? nil)
    }
}

private final class StubWorktreeLaunch: WorktreeLaunchProviding {
    var agentChoices: [String] { ["None", "Claude"] }
    func launchCommand(for choice: String) -> [String]? {
        choice == "Claude" ? ["claude"] : nil
    }
}
