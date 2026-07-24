import XCTest
@testable import Cortland

final class RepositoryWatcherTests: XCTestCase {
    func testGitdirPointerParsesLinkedWorktreeFile() {
        // A linked worktree's `.git` file is a single gitdir pointer.
        let contents = "gitdir: /Users/x/repo/.git/worktrees/feature-x\n"
        XCTAssertEqual(
            RepositoryWatcher.gitdirPointer(fromGitFileContents: contents),
            "/Users/x/repo/.git/worktrees/feature-x"
        )
    }

    func testGitdirPointerTrimsWhitespaceAndSurroundingLines() {
        let contents = "  gitdir: ../repo/.git/worktrees/wt   \n"
        XCTAssertEqual(
            RepositoryWatcher.gitdirPointer(fromGitFileContents: contents),
            "../repo/.git/worktrees/wt"
        )
    }

    func testGitdirPointerNilForNonPointerContents() {
        // A normal repo has a `.git` *directory*, never this file; unrelated
        // content must not be mistaken for a pointer.
        XCTAssertNil(RepositoryWatcher.gitdirPointer(fromGitFileContents: "ref: refs/heads/main\n"))
        XCTAssertNil(RepositoryWatcher.gitdirPointer(fromGitFileContents: ""))
        XCTAssertNil(RepositoryWatcher.gitdirPointer(fromGitFileContents: "gitdir:   \n"))
    }
}
