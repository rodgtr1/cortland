import XCTest
@testable import Cortland

final class AgentWorkingCueTests: XCTestCase {
    func testAnchoredSpinnerCuesMatch() {
        XCTAssertTrue(AgentStateDetector.containsAgentWorkingCue("✻ Thinking…"))
        XCTAssertTrue(AgentStateDetector.containsAgentWorkingCue("Working... please wait"))
        XCTAssertTrue(AgentStateDetector.containsAgentWorkingCue("running..."))
        XCTAssertTrue(AgentStateDetector.containsAgentWorkingCue("Generating…"))
        XCTAssertTrue(AgentStateDetector.containsAgentWorkingCue("(esc to interrupt)"))
    }

    func testBareWordsInOrdinaryOutputDoNotMatch() {
        // These would have flipped un-hooked state under the old bare-substring check.
        XCTAssertFalse(AgentStateDetector.containsAgentWorkingCue("I'm working on the report."))
        XCTAssertFalse(AgentStateDetector.containsAgentWorkingCue("nothing to commit, working tree clean"))
        XCTAssertFalse(AgentStateDetector.containsAgentWorkingCue("thinking about the design"))
        XCTAssertFalse(AgentStateDetector.containsAgentWorkingCue("the running total is 5"))
    }
}
