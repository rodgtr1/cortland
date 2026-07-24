import XCTest
@testable import Cortland

/// Two zero-coverage pieces of session restore: the `validatedRestoredDirectory`
/// guard (which stops a tampered/stale session.json from launching a pane at an
/// arbitrary path) and the `SessionState` Codable graph that save/load persists.
@MainActor
final class SessionRestoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sk-session-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - validatedRestoredDirectory

    func testNilPathIsRejected() {
        XCTAssertNil(TabController.validatedRestoredDirectory(nil))
    }

    func testEmptyPathIsRejected() {
        XCTAssertNil(TabController.validatedRestoredDirectory(""))
    }

    func testRelativePathIsRejected() {
        XCTAssertNil(TabController.validatedRestoredDirectory("relative/dir"),
                     "restore must only trust absolute paths")
    }

    func testNonexistentAbsolutePathIsRejected() {
        let missing = tempDir.appendingPathComponent("does-not-exist-\(UUID().uuidString)").path
        XCTAssertNil(TabController.validatedRestoredDirectory(missing))
    }

    func testExistingFileIsRejected() throws {
        let file = tempDir.appendingPathComponent("a-file.txt")
        try Data("hi".utf8).write(to: file)
        XCTAssertNil(TabController.validatedRestoredDirectory(file.path),
                     "a regular file is not a valid working directory")
    }

    func testExistingDirectoryIsAccepted() {
        XCTAssertEqual(TabController.validatedRestoredDirectory(tempDir.path), tempDir.path)
    }

    // MARK: - SessionState Codable graph

    private func roundTrip(_ state: SessionState) throws -> SessionState {
        let data = try JSONEncoder().encode(state)
        return try JSONDecoder().decode(SessionState.self, from: data)
    }

    func testFullSessionRoundTrips() throws {
        let state = SessionState(
            tabs: [
                SessionTabState(
                    panes: [
                        SessionPaneState(type: "terminal", cwd: "/tmp", url: nil),
                        SessionPaneState(type: "terminal", cwd: "/var", url: nil),
                    ],
                    activePaneIndex: 1,
                    customTitle: "work"
                ),
                SessionTabState(panes: [SessionPaneState(type: "terminal", cwd: nil, url: nil)],
                                activePaneIndex: 0, customTitle: nil),
            ],
            activeTabIndex: 1
        )
        XCTAssertEqual(try roundTrip(state), state)
    }

    func testEmptyTabsRoundTrips() throws {
        // load() rejects an empty-tabs session; the graph itself must still encode.
        let state = SessionState(tabs: [], activeTabIndex: 0)
        let restored = try roundTrip(state)
        XCTAssertEqual(restored, state)
        XCTAssertTrue(restored.tabs.isEmpty)
    }

    func testMissingCustomTitleDecodesAsNil() throws {
        let json = """
        {"tabs":[{"panes":[{"type":"terminal","cwd":"/tmp"}],"activePaneIndex":0}],"activeTabIndex":0}
        """
        let state = try JSONDecoder().decode(SessionState.self, from: Data(json.utf8))
        XCTAssertNil(state.tabs[0].customTitle)
        XCTAssertNil(state.tabs[0].panes[0].url)
        XCTAssertEqual(state.tabs[0].panes[0].cwd, "/tmp")
    }

    func testMissingRequiredKeyFailsToDecode() {
        // activeTabIndex is required; a session.json missing it must not silently
        // decode to a bogus default.
        let json = """
        {"tabs":[]}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(SessionState.self, from: Data(json.utf8)))
    }

    func testEquatableDistinguishesActiveIndex() {
        // saveSession dedupes writes via `state != lastSavedSession`, so equality
        // must be sensitive to the active index.
        let tabs = [SessionTabState(panes: [SessionPaneState(type: "terminal", cwd: "/tmp", url: nil)],
                                    activePaneIndex: 0, customTitle: nil)]
        XCTAssertNotEqual(SessionState(tabs: tabs, activeTabIndex: 0),
                          SessionState(tabs: tabs, activeTabIndex: 1))
    }
}
