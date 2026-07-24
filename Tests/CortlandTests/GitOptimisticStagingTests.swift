import XCTest
@testable import Cortland

/// Covers `GitStatusModel.optimisticStatusChars`, the guess the git panel paints
/// the instant `git add`/`git reset` returns, before the confirming status
/// refresh lands. Pure — no git repo, no main actor.
final class GitOptimisticStagingTests: XCTestCase {
    private func staged(_ file: GitFileItem) -> GitFileItem? {
        guard let chars = GitStatusModel.optimisticStatusChars(for: file, staged: true) else { return nil }
        return GitFileItem(path: file.path, stagedChar: chars.staged, unstagedChar: chars.unstaged)
    }

    private func unstaged(_ file: GitFileItem) -> GitFileItem? {
        guard let chars = GitStatusModel.optimisticStatusChars(for: file, staged: false) else { return nil }
        return GitFileItem(path: file.path, stagedChar: chars.staged, unstagedChar: chars.unstaged)
    }

    func testStagingUntrackedBecomesAdded() {
        let item = staged(GitFileItem(path: "new.txt", stagedChar: "?", unstagedChar: "?"))
        XCTAssertEqual(item?.stagedStatus, .added)
        XCTAssertEqual(item?.unstagedStatus, .unmodified)
        XCTAssertEqual(item?.isStaged, true)
        XCTAssertEqual(item?.displayStatus, .added)
    }

    func testStagingModifiedMovesLetterIntoIndex() {
        let item = staged(GitFileItem(path: "a.txt", stagedChar: " ", unstagedChar: "M"))
        XCTAssertEqual(item?.stagedStatus, .modified)
        XCTAssertEqual(item?.unstagedStatus, .unmodified)
        XCTAssertEqual(item?.isStaged, true)
    }

    func testStagingDeletedMovesLetterIntoIndex() {
        let item = staged(GitFileItem(path: "gone.txt", stagedChar: " ", unstagedChar: "D"))
        XCTAssertEqual(item?.stagedStatus, .deleted)
        XCTAssertEqual(item?.isStaged, true)
    }

    func testStagingPartiallyStagedFileAbsorbsTheWorktreeChange() {
        // "MM": staged edit plus a further worktree edit — `git add` folds the
        // worktree half in, leaving "M ".
        let item = staged(GitFileItem(path: "a.txt", stagedChar: "M", unstagedChar: "M"))
        XCTAssertEqual(item?.stagedStatus, .modified)
        XCTAssertEqual(item?.unstagedStatus, .unmodified)
    }

    func testStagingAnAlreadyStagedFileKeepsTheIndexStatus() {
        let item = staged(GitFileItem(path: "a.txt", stagedChar: "A", unstagedChar: " "))
        XCTAssertEqual(item?.stagedStatus, .added)
        XCTAssertEqual(item?.isStaged, true)
    }

    func testUnstagingAddedReturnsToUntracked() {
        let item = unstaged(GitFileItem(path: "new.txt", stagedChar: "A", unstagedChar: " "))
        XCTAssertEqual(item?.stagedStatus, .untracked)
        XCTAssertEqual(item?.unstagedStatus, .untracked)
        XCTAssertEqual(item?.isStaged, false)
        XCTAssertEqual(item?.displayStatus, .untracked)
    }

    func testUnstagingModifiedReturnsToWorktree() {
        let item = unstaged(GitFileItem(path: "a.txt", stagedChar: "M", unstagedChar: " "))
        XCTAssertEqual(item?.stagedStatus, .unmodified)
        XCTAssertEqual(item?.unstagedStatus, .modified)
        XCTAssertEqual(item?.isStaged, false)
        XCTAssertEqual(item?.displayStatus, .modified)
    }

    func testUnstagingAddedThenModifiedReturnsToUntracked() {
        // "AM" is a new file staged and then edited again; resetting it drops the
        // whole thing back to untracked.
        let item = unstaged(GitFileItem(path: "new.txt", stagedChar: "A", unstagedChar: "M"))
        XCTAssertEqual(item?.isStaged, false)
        XCTAssertEqual(item?.displayStatus, .untracked)
    }

    func testConflictedFileIsNotGuessed() {
        let conflict = GitFileItem(path: "merge.txt", stagedChar: "U", unstagedChar: "U")
        XCTAssertNil(GitStatusModel.optimisticStatusChars(for: conflict, staged: true),
                     "staging a conflict marks it resolved — only git status can say how")
        XCTAssertNil(GitStatusModel.optimisticStatusChars(for: conflict, staged: false))
    }

    func testStageThenUnstageRoundTripsAModifiedFile() {
        let original = GitFileItem(path: "a.txt", stagedChar: " ", unstagedChar: "M")
        let roundTripped = staged(original).flatMap(unstaged)
        XCTAssertEqual(roundTripped?.stagedStatus, original.stagedStatus)
        XCTAssertEqual(roundTripped?.unstagedStatus, original.unstagedStatus)
    }

    func testStageThenUnstageRoundTripsAnUntrackedFile() {
        let original = GitFileItem(path: "new.txt", stagedChar: "?", unstagedChar: "?")
        let roundTripped = staged(original).flatMap(unstaged)
        XCTAssertEqual(roundTripped?.stagedStatus, original.stagedStatus)
        XCTAssertEqual(roundTripped?.unstagedStatus, original.unstagedStatus)
    }
}
