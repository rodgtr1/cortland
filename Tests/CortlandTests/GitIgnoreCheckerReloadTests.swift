import XCTest
@testable import Cortland

/// A forced file-tree refresh reloads the existing checker instead of building
/// a new one, so the old ignored set must keep answering until the new one
/// lands, and the tree rebuilds again only when the set changed.
@MainActor
final class GitIgnoreCheckerReloadTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitignore-reload-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path, "init", "-q"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        try "*.log\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "x".write(to: repo.appendingPathComponent("a.log"), atomically: true, encoding: .utf8)
        try "x".write(to: repo.appendingPathComponent("kept.txt"), atomically: true, encoding: .utf8)
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

    private func path(_ name: String) -> String {
        repo.appendingPathComponent(name).path
    }

    private func loadedChecker() -> GitIgnoreChecker {
        let checker = GitIgnoreChecker(rootPath: repo.path)
        var loaded = false
        checker.onLoadComplete = { loaded = true }
        pump(until: { loaded })
        XCTAssertTrue(loaded)
        return checker
    }

    func testReloadKeepsOldAnswersUntilTheNewSetLands() throws {
        let checker = loadedChecker()
        XCTAssertTrue(checker.isIgnored(path: path("a.log")))
        XCTAssertFalse(checker.isIgnored(path: path("kept.txt")))

        try "x".write(to: repo.appendingPathComponent("b.log"), atomically: true, encoding: .utf8)
        var changed: Bool?
        var loadCompleteFired = false
        checker.onLoadComplete = { loadCompleteFired = true }
        checker.reload { changed = $0 }

        // Nothing has landed yet (it lands on the main actor, which this holds):
        // the old set still answers.
        XCTAssertTrue(checker.isIgnored(path: path("a.log")))
        XCTAssertFalse(checker.isIgnored(path: path("b.log")))

        pump(until: { changed != nil })
        XCTAssertEqual(changed, true)
        XCTAssertTrue(loadCompleteFired)
        XCTAssertTrue(checker.isIgnored(path: path("b.log")))
        XCTAssertTrue(checker.isIgnored(path: path("a.log")))
    }

    func testReloadWithNothingNewReportsNoChange() {
        let checker = loadedChecker()
        var changed: Bool?
        var loadCompleteFired = false
        checker.onLoadComplete = { loadCompleteFired = true }
        checker.reload { changed = $0 }
        pump(until: { changed != nil })
        XCTAssertEqual(changed, false)
        XCTAssertFalse(loadCompleteFired)
        XCTAssertTrue(checker.isIgnored(path: path("a.log")))
    }

    func testReloadDuringALoadRunsOnceMoreAfterIt() throws {
        let checker = GitIgnoreChecker(rootPath: repo.path)
        // The first load is in flight; this one must not be lost.
        try "x".write(to: repo.appendingPathComponent("c.log"), atomically: true, encoding: .utf8)
        var changed: Bool?
        checker.reload { changed = $0 }
        pump(until: { changed != nil })
        XCTAssertNotNil(changed)
        XCTAssertTrue(checker.isIgnored(path: path("c.log")))
    }
}
