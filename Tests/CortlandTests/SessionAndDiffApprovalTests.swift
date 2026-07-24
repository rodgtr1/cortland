import XCTest
@testable import Cortland

@MainActor
final class DiffApprovalUnifiedDiffTests: XCTestCase {
    func testUnifiedDiffMarksChangedLines() {
        let old = "line one\nline two\nline three\n"
        let new = "line one\nline 2\nline three\n"

        let diff = UnifiedDiff.text(old: old, new: new, path: "/tmp/example.txt")

        XCTAssertTrue(diff.contains("--- a/example.txt"))
        XCTAssertTrue(diff.contains("+++ b/example.txt"))
        XCTAssertTrue(diff.contains("-line two"))
        XCTAssertTrue(diff.contains("+line 2"))
    }

    func testUnifiedDiffForNewFileShowsAllLinesAdded() {
        let diff = UnifiedDiff.text(old: "", new: "first\nsecond\n", path: "/tmp/new.txt")

        XCTAssertTrue(diff.contains("+first"))
        XCTAssertTrue(diff.contains("+second"))
        XCTAssertFalse(diff.contains("\n-first"))
    }
}

final class SessionStateCodingTests: XCTestCase {
    func testSessionStateRoundTripsThroughJSON() throws {
        let state = SessionState(
            tabs: [
                SessionTabState(
                    panes: [
                        SessionPaneState(type: "terminal", cwd: "/Users/me/project", url: nil),
                        SessionPaneState(type: "browser", cwd: nil, url: "http://localhost:3000/")
                    ],
                    activePaneIndex: 1,
                    customTitle: "my work"
                )
            ],
            activeTabIndex: 0
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(SessionState.self, from: data)

        XCTAssertEqual(decoded.tabs.count, 1)
        XCTAssertEqual(decoded.tabs[0].panes.count, 2)
        XCTAssertEqual(decoded.tabs[0].panes[0].cwd, "/Users/me/project")
        XCTAssertEqual(decoded.tabs[0].panes[1].url, "http://localhost:3000/")
        XCTAssertEqual(decoded.tabs[0].activePaneIndex, 1)
        XCTAssertEqual(decoded.tabs[0].customTitle, "my work")
        XCTAssertEqual(decoded.activeTabIndex, 0)
    }
}
