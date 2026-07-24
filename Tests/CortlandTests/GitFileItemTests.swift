import XCTest
@testable import Cortland

/// Covers `GitFileItem`, the model-layer wrapper `GitStatusModel` builds from a
/// pair of porcelain status chars. It re-derives staged/conflicted/directory
/// state with its own rules (distinct from the already-tested `GitStatusEntry`),
/// and had zero coverage. These are pure — no git repo, no main actor.
final class GitFileItemTests: XCTestCase {
    func testStagedModified() {
        let item = GitFileItem(path: "src/app.swift", stagedChar: "M", unstagedChar: " ")
        XCTAssertEqual(item.filename, "app.swift")
        XCTAssertEqual(item.stagedStatus, .modified)
        XCTAssertEqual(item.unstagedStatus, .unmodified)
        XCTAssertTrue(item.isStaged)
        XCTAssertFalse(item.isConflicted)
        XCTAssertFalse(item.isDirectory)
        XCTAssertEqual(item.displayStatus, .modified)
    }

    func testUnstagedModifiedIsNotStaged() {
        let item = GitFileItem(path: "a.txt", stagedChar: " ", unstagedChar: "M")
        XCTAssertFalse(item.isStaged)
        // Staged slot is unmodified, so displayStatus falls through to unstaged.
        XCTAssertEqual(item.displayStatus, .modified)
    }

    func testUntrackedIsNotStaged() {
        let item = GitFileItem(path: "new.txt", stagedChar: "?", unstagedChar: "?")
        XCTAssertFalse(item.isStaged, "untracked files are never 'staged'")
        XCTAssertFalse(item.isConflicted)
        XCTAssertEqual(item.displayStatus, .untracked)
    }

    func testConflictUUIsConflictedAndNotStaged() {
        let item = GitFileItem(path: "merge.txt", stagedChar: "U", unstagedChar: "U")
        XCTAssertTrue(item.isConflicted)
        XCTAssertFalse(item.isStaged, "a conflicted file is not staged even with a non-space staged char")
        XCTAssertEqual(item.displayStatus, .unmerged)
    }

    func testAllConflictVariants() {
        // UU, AU, UA, DU, UD, AA, DD are all conflicts (mirrors GitStatusEntry).
        let conflicts: [(Character, Character)] = [("U","U"), ("A","U"), ("U","A"), ("D","U"), ("U","D"), ("A","A"), ("D","D")]
        for (staged, unstaged) in conflicts {
            let item = GitFileItem(path: "f", stagedChar: staged, unstagedChar: unstaged)
            XCTAssertTrue(item.isConflicted, "\(staged)\(unstaged) should be a conflict")
            XCTAssertEqual(item.displayStatus, .unmerged, "\(staged)\(unstaged) should display as a conflict")
        }
    }

    func testAddedThenModifiedIsNotAConflict() {
        // "AM" (staged add + unstaged modify) is a normal state, not a conflict.
        let item = GitFileItem(path: "f", stagedChar: "A", unstagedChar: "M")
        XCTAssertFalse(item.isConflicted)
        XCTAssertTrue(item.isStaged)
        XCTAssertEqual(item.displayStatus, .added, "staged status wins over unstaged in displayStatus")
    }

    func testUntrackedDirectoryTrailingSlash() {
        let item = GitFileItem(path: "build/", stagedChar: "?", unstagedChar: "?")
        XCTAssertTrue(item.isDirectory, "porcelain marks an untracked dir with a trailing slash")
        XCTAssertEqual(item.filename, "build")
    }

    func testNestedPathFilename() {
        let item = GitFileItem(path: "a/b/c/deep.md", stagedChar: "M", unstagedChar: " ")
        XCTAssertEqual(item.filename, "deep.md")
    }

    func testUnknownStatusCharFallsBackToUnmodified() {
        let item = GitFileItem(path: "f", stagedChar: "X", unstagedChar: " ")
        XCTAssertEqual(item.stagedStatus, .unmodified, "unknown porcelain char decodes to .unmodified")
        // X != " " and X != "?", so the isStaged heuristic still treats it as staged.
        XCTAssertTrue(item.isStaged)
    }

    func testDisplayNameMapping() {
        XCTAssertEqual(GitFileStatus.unmerged.displayName, "Conflict")
        XCTAssertEqual(GitFileStatus.modified.displayName, "Modified")
        XCTAssertEqual(GitFileStatus.untracked.displayName, "Untracked")
        XCTAssertEqual(GitFileStatus.unmodified.displayName, "")
    }
}
