import XCTest
@testable import Cortland

/// The git panel's model skips background refreshes while the panel is not
/// on screen and catches up once when it is shown again. Drives the model's
/// visibility seam directly against a temp repo; no window involved.
@MainActor
final class GitStatusModelVisibilityTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitstatus-visibility-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path, "init", "-q"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    override func tearDownWithError() throws {
        if let repo { try? FileManager.default.removeItem(at: repo) }
    }

    private func pump(until condition: () -> Bool, timeout: TimeInterval = 10) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
    }

    func testHiddenPanelMarksStaleAndRefreshesOnceWhenShown() {
        let model = GitStatusModel()
        var changes = 0
        model.onChange = { changes += 1 }
        model.setRepositoryPath(repo.path)
        pump(until: { !model.isLoading && changes > 0 })
        XCTAssertFalse(model.isLoading)

        model.setPanelVisible(false)
        model.backgroundRefresh()
        XCTAssertTrue(model.isStale)
        XCTAssertFalse(model.isLoading, "a hidden panel must not refresh on a background tick")

        // Showing the panel catches up once.
        model.setPanelVisible(true)
        XCTAssertFalse(model.isStale)
        XCTAssertTrue(model.isLoading)
        let before = changes
        pump(until: { !model.isLoading })
        XCTAssertEqual(changes, before + 1)

        // Shown again with nothing missed: no refresh.
        model.setPanelVisible(false)
        model.setPanelVisible(true)
        XCTAssertFalse(model.isLoading)
    }

    func testAppInitiatedRefreshRunsWhileHidden() {
        let model = GitStatusModel()
        model.setRepositoryPath(repo.path)
        pump(until: { !model.isLoading })

        model.setPanelVisible(false)
        model.backgroundRefresh()
        XCTAssertTrue(model.isStale)
        model.refreshStatus(force: true)
        XCTAssertTrue(model.isLoading)
        XCTAssertFalse(model.isStale)
        pump(until: { !model.isLoading })
    }
}
