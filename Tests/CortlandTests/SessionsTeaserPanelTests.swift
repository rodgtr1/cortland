import XCTest
import CortlandProInterface
@testable import Cortland

/// The free tier's Session Recall behavior: ten most recent rows, a footer that
/// reports the real total, and no way to resume from it.
@MainActor
final class SessionsTeaserPanelTests: XCTestCase {
    private func record(id: String, minutesAgo: Int) -> SessionRecord {
        SessionRecord(
            agent: .claude,
            cwd: "/Users/travis/Repos/x",
            repo: "x",
            sessionID: id,
            resumeID: id,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 - Double(minutesAgo) * 60),
            title: "session \(id)",
            aiTitle: nil,
            resumeCommand: "claude --resume \(id)",
            logPath: "/tmp/\(id).jsonl"
        )
    }

    func testTeaserShowsTenRows() {
        XCTAssertEqual(SessionsTeaserPanel.displayLimit, 10)
    }

    /// The rows are the ten NEWEST, not the first ten found — the teaser sorts
    /// through the same query the Pro panel uses.
    func testTeaserKeepsTheTenMostRecent() {
        let records = (1...25).map { record(id: "S\($0)", minutesAgo: $0) }.shuffled()
        let shown = Array(SessionQuery.run(records).prefix(SessionsTeaserPanel.displayLimit))

        XCTAssertEqual(shown.count, 10)
        XCTAssertEqual(shown.map(\.sessionID), (1...10).map { "S\($0)" })
    }

    /// The point of the footer: the count is of everything found, so ten rows
    /// read as a window onto the whole history rather than the whole history.
    func testFooterReportsTheTrueTotalNotTheRowCount() {
        XCTAssertEqual(SessionsTeaserPanel.footerText(shown: 10, total: 334), "10 of 334 sessions")
    }

    func testFooterDropsTheOfClauseWhenEverythingFits() {
        XCTAssertEqual(SessionsTeaserPanel.footerText(shown: 4, total: 4), "4 sessions")
        XCTAssertEqual(SessionsTeaserPanel.footerText(shown: 1, total: 1), "1 session")
    }

    func testFooterSaysSoWhenThereAreNoSessions() {
        XCTAssertEqual(SessionsTeaserPanel.footerText(shown: 0, total: 0), "no sessions found")
    }

    /// No Enter-to-resume in free: a row can't even be selected, so there is no
    /// highlighted row that silently does nothing.
    func testRowsAreNotSelectable() {
        let panel = SessionsTeaserPanel()
        let table = NSTableView()
        XCTAssertFalse(panel.tableView(table, shouldSelectRow: 0))
    }

    /// Free builds resolve Session Recall to the teaser. A registered provider
    /// is what routes ⌃⇧S elsewhere.
    func testRecallIsUnregisteredByDefault() throws {
        #if CORTLAND_PRO
        throw XCTSkip("Pro build: recall is registered at launch")
        #else
        XCTAssertNil(ProFeatures.recall)
        #endif
    }
}
