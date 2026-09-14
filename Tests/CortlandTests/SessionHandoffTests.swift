import XCTest
import TOMLKit
@testable import Cortland

@MainActor
final class SessionHandoffTests: XCTestCase {
    private let path = "/work/repo/.cortland/handoffs/handoff-20260914-093005.md"

    // MARK: Config

    private func config(from toml: String) throws -> Config {
        try TOMLDecoder().decode(Config.self, from: try TOMLTable(string: toml))
    }

    /// A complete config with no `[handoff]` table, as a file written before
    /// the section existed would be.
    private func baseTOML() throws -> String {
        var c = Config()
        c.handoff = nil
        return try TOMLEncoder().encode(c).description
    }

    func testHandoffPromptParsesFromTOML() throws {
        let c = try config(from: try baseTOML() + "\n[handoff]\nprompt = \"Dump state to {path} and stop.\"\n")
        XCTAssertEqual(c.handoff?.prompt, "Dump state to {path} and stop.")
    }

    func testConfigWithoutHandoffSectionKeepsDefaultPrompt() throws {
        let c = try config(from: try baseTOML())
        XCTAssertNil(c.handoff?.prompt)
        XCTAssertEqual(
            SessionHandoff.handoffPrompt(path: path, configured: c.handoff?.prompt),
            SessionHandoff.defaultHandoffPrompt(path: path)
        )
        XCTAssertTrue(SessionHandoff.defaultHandoffPrompt(path: path).contains(path))
    }

    func testCustomPromptWithTokenGetsPathSubstituted() {
        let prompt = SessionHandoff.handoffPrompt(path: path, configured: "Write notes to {path}, then stop.")
        XCTAssertEqual(prompt, "Write notes to \(path), then stop.")
    }

    func testCustomPromptWithoutTokenGetsPathAppended() {
        let prompt = SessionHandoff.handoffPrompt(path: path, configured: "Summarize this session.")
        XCTAssertTrue(prompt.hasPrefix("Summarize this session."))
        XCTAssertTrue(prompt.hasSuffix("\(path)."))
    }

    func testPromptsHaveNoEmDashes() {
        XCTAssertFalse(SessionHandoff.defaultHandoffPrompt(path: path).contains("\u{2014}"))
        XCTAssertFalse(SessionHandoff.continuationPrompt(path: path).contains("\u{2014}"))
    }

    // MARK: Path and agent

    func testHandoffPathComposition() {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 14
        components.hour = 9; components.minute = 30; components.second = 5
        let date = Calendar.current.date(from: components)!
        XCTAssertEqual(SessionHandoff.handoffPath(cwd: "/work/repo", date: date), path)
    }

    func testAgentDetectionFromModel() {
        XCTAssertEqual(SessionHandoff.agent(forModel: "claude-opus-5"), .claude)
        XCTAssertEqual(SessionHandoff.agent(forModel: "gpt-5.3-codex"), .codex)
        XCTAssertEqual(SessionHandoff.agent(forModel: nil), .claude)
    }

    func testContinuationArgv() {
        XCTAssertEqual(SessionHandoff.continuationArgv(agent: .claude, path: path),
                       ["claude", SessionHandoff.continuationPrompt(path: path)])
        XCTAssertEqual(SessionHandoff.continuationArgv(agent: .codex, path: path).first, "codex")
    }

    func testStartCheckRefusesIdleNonTerminalAndWorking() {
        XCTAssertEqual(SessionHandoff.startCheck(isTerminal: true, agentState: .idle), .noAgent)
        XCTAssertEqual(SessionHandoff.startCheck(isTerminal: false, agentState: .done), .noAgent)
        XCTAssertEqual(SessionHandoff.startCheck(isTerminal: true, agentState: .working), .agentBusy)
        XCTAssertEqual(SessionHandoff.startCheck(isTerminal: true, agentState: .ready), .ok)
        XCTAssertEqual(SessionHandoff.startCheck(isTerminal: true, agentState: .done), .ok)
    }

    // MARK: Wait state machine

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testWorkingThenDoneChecksFile() {
        var m = HandoffWaitMachine(promptSentAt: t0)
        XCTAssertEqual(m.handle(.agentState(.done), at: t0.addingTimeInterval(1)), .keepWaiting,
                       "a stale done before the agent picks up the prompt is ignored")
        XCTAssertEqual(m.handle(.agentState(.working), at: t0.addingTimeInterval(2)), .keepWaiting)
        XCTAssertEqual(m.handle(.agentState(.done), at: t0.addingTimeInterval(60)), .checkHandoffFile)
        XCTAssertTrue(m.isFinished)
    }

    func testWorkingThenReadyFocusesPane() {
        var m = HandoffWaitMachine(promptSentAt: t0)
        _ = m.handle(.agentState(.working), at: t0.addingTimeInterval(1))
        XCTAssertEqual(m.handle(.agentState(.ready), at: t0.addingTimeInterval(5)), .focusPane)
        XCTAssertTrue(m.isFinished)
        XCTAssertEqual(m.handle(.agentState(.done), at: t0.addingTimeInterval(6)), .keepWaiting)
    }

    func testNoWorkingWithinStartTimeoutTimesOut() {
        var m = HandoffWaitMachine(promptSentAt: t0)
        XCTAssertEqual(m.handle(.tick, at: t0.addingTimeInterval(29)), .keepWaiting)
        XCTAssertEqual(m.handle(.tick, at: t0.addingTimeInterval(31)), .timedOutBeforeWorking)
        XCTAssertTrue(m.isFinished)
    }

    func testWorkingBeyondTenMinutesTimesOut() {
        var m = HandoffWaitMachine(promptSentAt: t0)
        _ = m.handle(.agentState(.working), at: t0.addingTimeInterval(10))
        XCTAssertEqual(m.handle(.tick, at: t0.addingTimeInterval(10 + 599)), .keepWaiting)
        XCTAssertEqual(m.handle(.tick, at: t0.addingTimeInterval(10 + 601)), .timedOutWhileWorking)
        XCTAssertTrue(m.isFinished)
    }

    func testPaneClosedCancels() {
        var m = HandoffWaitMachine(promptSentAt: t0)
        _ = m.handle(.agentState(.working), at: t0.addingTimeInterval(1))
        XCTAssertEqual(m.handle(.paneClosed, at: t0.addingTimeInterval(2)), .cancel)
        XCTAssertTrue(m.isFinished)
    }
}
