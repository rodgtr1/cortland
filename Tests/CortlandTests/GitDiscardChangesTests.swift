import XCTest
@testable import Cortland

/// `GitStatusModel.discardChanges` against a real temp repo: a staged new file
/// has nothing in HEAD to restore, and a failed discard must report git's error.
@MainActor
final class GitDiscardChangesTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("sk-discard-\(UUID().uuidString)")
        self.repo = repo
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try Self.runGit(["init", "-q", "-b", "main"], in: repo)
        try Self.runGit(["config", "user.email", "t@example.com"], in: repo)
        try Self.runGit(["config", "user.name", "Test"], in: repo)
        try "base\n".write(to: repo.appendingPathComponent("README"), atomically: true, encoding: .utf8)
        try Self.runGit(["add", "."], in: repo)
        try Self.runGit(["commit", "-qm", "init"], in: repo)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
    }

    @discardableResult
    private func git(_ args: [String]) throws -> String {
        try Self.runGit(args, in: repo)
    }

    @discardableResult
    private nonisolated static func runGit(_ args: [String], in repo: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = repo
        let out = Pipe()
        p.standardOutput = out; p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func discard(_ file: GitFileItem) -> (Bool, String?) {
        let model = GitStatusModel()
        model.setRepositoryPath(repo.path)
        let done = expectation(description: "discard")
        var outcome: (Bool, String?) = (false, nil)
        model.discardChanges(file) { success, message in
            outcome = (success, message)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return outcome
    }

    func testDiscardStagedNewFileDeletesItAndLeavesCleanStatus() throws {
        let url = repo.appendingPathComponent("new.txt")
        try "fresh\n".write(to: url, atomically: true, encoding: .utf8)
        try git(["add", "new.txt"])

        let (success, message) = discard(GitFileItem(path: "new.txt", stagedChar: "A", unstagedChar: " "))

        XCTAssertTrue(success, message ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try git(["status", "--porcelain"]), "")
    }

    /// The status row for `path`, built the way the changes pane builds it.
    private func statusItem(_ path: String) throws -> GitFileItem {
        let entry = try XCTUnwrap(try GitService().status(repositoryRoot: repo.path).first { $0.path == path })
        return GitFileItem(
            path: entry.path, stagedChar: entry.stagedStatus, unstagedChar: entry.unstagedStatus,
            originalPath: entry.originalPath
        )
    }

    func testDiscardStagedRenameRestoresSourceAndRemovesDestination() throws {
        try git(["mv", "README", "MOVED"])
        let item = try statusItem("MOVED")
        XCTAssertEqual(item.originalPath, "README")

        let (success, message) = discard(item)

        XCTAssertTrue(success, message ?? "")
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("README"), encoding: .utf8), "base\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("MOVED").path))
        XCTAssertEqual(try git(["status", "--porcelain"]), "")
    }

    func testDiscardStagedRenameWithUnstagedEditRestoresSourceAndRemovesDestination() throws {
        try git(["mv", "README", "MOVED"])
        try "edited\n".write(to: repo.appendingPathComponent("MOVED"), atomically: true, encoding: .utf8)
        let item = try statusItem("MOVED")
        XCTAssertEqual(item.unstagedStatus, .modified)

        let (success, message) = discard(item)

        XCTAssertTrue(success, message ?? "")
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("README"), encoding: .utf8), "base\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("MOVED").path))
        XCTAssertEqual(try git(["status", "--porcelain"]), "")
    }
}
