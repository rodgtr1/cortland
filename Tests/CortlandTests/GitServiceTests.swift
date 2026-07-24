import XCTest
@testable import Cortland

final class GitServiceTests: XCTestCase {
    func testParsesUnstagedModifiedStatusWithoutLosingLeadingSpace() {
        let entries = GitService.parseStatusOutput(" M docs/pages/agentic-identity-framework.mdx\n")

        XCTAssertEqual(entries, [
            GitStatusEntry(
                path: "docs/pages/agentic-identity-framework.mdx",
                stagedStatus: " ",
                unstagedStatus: "M"
            )
        ])
        XCTAssertFalse(entries[0].hasStagedChanges)
        XCTAssertTrue(entries[0].hasUnstagedChanges)
    }

    func testParsesStagedModifiedStatus() {
        let entry = GitService.parseStatusLine("M  README.md")

        XCTAssertEqual(entry?.path, "README.md")
        XCTAssertEqual(entry?.stagedStatus, "M")
        XCTAssertEqual(entry?.unstagedStatus, " ")
        XCTAssertEqual(entry?.hasStagedChanges, true)
        XCTAssertEqual(entry?.hasUnstagedChanges, false)
    }

    func testParsesUntrackedStatus() {
        let entry = GitService.parseStatusLine("?? Sources/NewFile.swift")

        XCTAssertEqual(entry?.path, "Sources/NewFile.swift")
        XCTAssertEqual(entry?.isUntracked, true)
    }

    func testParsesRenamedPathAsDestination() {
        let entry = GitService.parseStatusLine("R  old/path.swift -> new/path.swift")

        XCTAssertEqual(entry?.path, "new/path.swift")
        XCTAssertEqual(entry?.stagedStatus, "R")
    }

    func testParsesPathWithSpaces() {
        let entry = GitService.parseStatusLine(" M docs/my notes.md")

        XCTAssertEqual(entry?.path, "docs/my notes.md")
    }

    func testUnquotesQuotedPathWithEscapedQuote() {
        let entry = GitService.parseStatusLine("?? \"weird \\\"name\\\".txt\"")

        XCTAssertEqual(entry?.path, "weird \"name\".txt")
    }

    func testUnquotesOctalEscapedUnicodePath() {
        // git renders "é" (UTF-8 0xC3 0xA9) as \303\251 in quoted paths
        let entry = GitService.parseStatusLine("?? \"caf\\303\\251.txt\"")

        XCTAssertEqual(entry?.path, "café.txt")
    }

    func testParsesQuotedRenameDestination() {
        let entry = GitService.parseStatusLine("R  \"old name.txt\" -> \"new name.txt\"")

        XCTAssertEqual(entry?.path, "new name.txt")
    }

    // MARK: - filenames containing " -> "
    //
    // git quotes any path that could be confused with its own framing (a space
    // is enough), so a name holding " -> " always arrives quoted. Splitting on
    // the arrow before unquoting truncated such a name; the lines below are
    // verbatim `git status --porcelain` output for those files.

    func testUntrackedFileNamedWithAnArrowKeepsItsWholeName() {
        let entry = GitService.parseStatusLine("?? \"untracked -> arrow.txt\"")

        XCTAssertEqual(entry?.path, "untracked -> arrow.txt")
        XCTAssertEqual(entry?.isUntracked, true)
    }

    func testModifiedFileNamedWithAnArrowKeepsItsWholeName() {
        let entry = GitService.parseStatusLine(" M \"docs/a -> b.md\"")

        XCTAssertEqual(entry?.path, "docs/a -> b.md")
    }

    func testRenameBetweenTwoArrowNamedFilesTakesTheDestination() {
        // Both halves contain the separator; only the arrow *outside* the quoted
        // source is the real one.
        let entry = GitService.parseStatusLine("R  \"a -> b.txt\" -> \"dest -> arrow.txt\"")

        XCTAssertEqual(entry?.path, "dest -> arrow.txt")
        XCTAssertEqual(entry?.stagedStatus, "R")
    }

    func testRenameFromAnArrowNamedFileToAPlainOne() {
        let entry = GitService.parseStatusLine("R  \"a -> b.txt\" -> renamed.txt")

        XCTAssertEqual(entry?.path, "renamed.txt")
    }

    func testCopyEntryTakesTheDestination() {
        let entry = GitService.parseStatusLine("C  original.txt -> copy.txt")

        XCTAssertEqual(entry?.path, "copy.txt")
        XCTAssertEqual(entry?.stagedStatus, "C")
    }

    func testRenameStagedThenModifiedInTheWorktree() {
        let entry = GitService.parseStatusLine("RM \"old -> name.txt\" -> new.txt")

        XCTAssertEqual(entry?.path, "new.txt")
        XCTAssertEqual(entry?.unstagedStatus, "M")
    }

    func testEscapedQuoteInsideAnArrowNamedSourceDoesNotEndTheQuotedPath() {
        let entry = GitService.parseStatusLine("R  \"we\\\"ird -> a.txt\" -> \"b.txt\"")

        XCTAssertEqual(entry?.path, "b.txt")
    }

    func testRejectsMalformedShortLine() {
        XCTAssertNil(GitService.parseStatusLine("M"))
        XCTAssertNil(GitService.parseStatusLine(""))
    }

    func testParsesUnmergedStatusAsConflicted() {
        let bothModified = GitService.parseStatusLine("UU src/conflicted.swift")

        XCTAssertEqual(bothModified?.path, "src/conflicted.swift")
        XCTAssertEqual(bothModified?.isConflicted, true)

        XCTAssertEqual(GitService.parseStatusLine("AA both-added.txt")?.isConflicted, true)
        XCTAssertEqual(GitService.parseStatusLine("DD both-deleted.txt")?.isConflicted, true)
        XCTAssertEqual(GitService.parseStatusLine("DU deleted-by-us.txt")?.isConflicted, true)
        XCTAssertEqual(GitService.parseStatusLine("UA added-by-them.txt")?.isConflicted, true)

        XCTAssertEqual(GitService.parseStatusLine("M  staged.txt")?.isConflicted, false)
        XCTAssertEqual(GitService.parseStatusLine(" M unstaged.txt")?.isConflicted, false)
        XCTAssertEqual(GitService.parseStatusLine("?? untracked.txt")?.isConflicted, false)
    }

    // MARK: - WorktreeStatusSummary

    func testStatusSummaryCleanWhenNoEntries() {
        let summary = WorktreeStatusSummary(entries: [])
        XCTAssertTrue(summary.clean)
        XCTAssertEqual(summary.changed, 0)
        XCTAssertEqual(summary.conflicted, 0)
    }

    func testStatusSummaryCountsChangedAndConflictedSeparately() {
        let entries = GitService.parseStatusOutput("""
         M edited.swift
        ?? brand-new.txt
        UU conflicted.swift
        M  staged.txt

        """)
        let summary = WorktreeStatusSummary(entries: entries)
        XCTAssertFalse(summary.clean)
        XCTAssertEqual(summary.changed, 3)      // edited, untracked, staged
        XCTAssertEqual(summary.conflicted, 1)   // UU is conflicted, not "changed"
    }

    func testStatusSummaryConflictedOnlyIsNotClean() {
        let entries = GitService.parseStatusOutput("AA both-added.txt\n")
        let summary = WorktreeStatusSummary(entries: entries)
        XCTAssertFalse(summary.clean)
        XCTAssertEqual(summary.changed, 0)
        XCTAssertEqual(summary.conflicted, 1)
    }

    func testConflictMarkerDiffShowsWorkingTreeWithMarkers() {
        let content = """
        one
        <<<<<<< HEAD
        main-change
        =======
        feature-change
        >>>>>>> b81eefa (feat)
        three

        """

        let diff = GitService.conflictMarkerDiff(relativePath: "f.txt", content: content)
        let lines = diff.components(separatedBy: "\n")

        XCTAssertEqual(lines[0], "diff --git a/f.txt b/f.txt")
        XCTAssertEqual(lines[1], "conflict")
        XCTAssertEqual(lines[4], "@@ -1,7 +1,7 @@")
        // Every content line is emitted as context (leading space) so the
        // renderer numbers it; conflict markers survive verbatim.
        XCTAssertEqual(lines[5], " one")
        XCTAssertEqual(lines[6], " <<<<<<< HEAD")
        XCTAssertEqual(lines[8], " =======")
        XCTAssertEqual(lines[10], " >>>>>>> b81eefa (feat)")
    }

    func testSplitDiffByFileSeparatesFiles() {
        let diff = """
        diff --git a/foo.swift b/foo.swift
        index 111..222 100644
        --- a/foo.swift
        +++ b/foo.swift
        @@ -1 +1 @@
        -old
        +new
        diff --git a/bar.swift b/bar.swift
        @@ -2 +2 @@
        +added
        """

        let byFile = GitService.splitDiffByFile(diff)

        XCTAssertEqual(byFile.count, 2)
        XCTAssertTrue(byFile["foo.swift"]?.contains("+new") ?? false)
        XCTAssertTrue(byFile["bar.swift"]?.contains("+added") ?? false)
        XCTAssertFalse(byFile["foo.swift"]?.contains("+added") ?? true)
    }

    func testConflictMarkerDiffTrimsToConflictRegionInLargeFile() {
        var lines = (1...50).map { "line\($0)" }
        lines.insert(">>>>>>> branch", at: 30)
        lines.insert("incoming", at: 30)
        lines.insert("=======", at: 30)
        lines.insert("current", at: 30)
        lines.insert("<<<<<<< HEAD", at: 30)
        let content = lines.joined(separator: "\n") + "\n"

        let diff = GitService.conflictMarkerDiff(relativePath: "f.txt", content: content)

        // Only the conflict region is emitted, not the whole 55-line file.
        XCTAssertTrue(diff.contains("<<<<<<< HEAD"))
        XCTAssertTrue(diff.contains(">>>>>>> branch"))
        XCTAssertFalse(diff.contains(" line1\n"))
        XCTAssertFalse(diff.contains(" line50\n"))
        XCTAssertTrue(diff.contains(" line28\n")) // within 3 lines of context
    }

    func testSplitDiffByFileIgnoresUnmergedPathLine() {
        let diff = """
        diff --git a/foo.swift b/foo.swift
        @@ -1 +1 @@
        -old
        +new
        * Unmerged path bar.swift
        """

        let byFile = GitService.splitDiffByFile(diff)

        XCTAssertFalse(byFile["foo.swift"]?.contains("Unmerged path") ?? true)
    }

    func testParsePathFromQuotedDiffHeader() {
        let path = GitService.parsePathFromDiffHeader("diff --git \"a/my file.txt\" \"b/my file.txt\"")

        XCTAssertEqual(path, "my file.txt")
    }

    func testParsePathFromQuotedDiffHeaderUnescapesUnicode() {
        // The diff-header key must come back unquoted so it matches the
        // unquoted GitStatusEntry.path used to look it up in diffsByPath.
        let path = GitService.parsePathFromDiffHeader(
            "diff --git \"a/caf\\303\\251.txt\" \"b/caf\\303\\251.txt\""
        )

        XCTAssertEqual(path, "café.txt")
    }

    // MARK: - Changes vs default branch (name-status parsing)

    func testParseNameStatusSimpleEntries() {
        let entries = GitService.parseNameStatusOutput("""
        M\tSources/App.swift
        A\tSources/New.swift
        D\tSources/Gone.swift

        """)

        XCTAssertEqual(entries, [
            GitBranchDiffEntry(path: "Sources/App.swift", status: "M"),
            GitBranchDiffEntry(path: "Sources/New.swift", status: "A"),
            GitBranchDiffEntry(path: "Sources/Gone.swift", status: "D")
        ])
    }

    func testParseNameStatusRenameUsesDestinationPath() {
        // Rename/copy entries carry a similarity score and old+new paths; the
        // destination (last field) is what the panel lists.
        let entries = GitService.parseNameStatusOutput("R100\told/path.swift\tnew/path.swift\n")

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].path, "new/path.swift")
        XCTAssertEqual(entries[0].status, "R")
    }

    func testParseNameStatusUnquotesUnicodePath() {
        let entries = GitService.parseNameStatusOutput("A\t\"caf\\303\\251.txt\"\n")

        XCTAssertEqual(entries.first?.path, "café.txt")
    }

    func testParseNameStatusRejectsBlankLines() {
        XCTAssertTrue(GitService.parseNameStatusOutput("\n\n").isEmpty)
    }

    // MARK: - Default branch + branch diff (real git)

    /// Builds a throwaway repo in a temp dir and returns a `git` runner bound to
    /// it plus the repo URL; the caller registers cleanup.
    private func makeTempRepo(cleanup: inout [URL]) throws -> (git: ([String]) throws -> Void, repo: URL) {
        let fm = FileManager.default
        let repo = fm.temporaryDirectory.appendingPathComponent("sk-git-\(UUID().uuidString)")
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        cleanup.append(repo)

        @discardableResult
        func git(_ args: [String]) throws -> Void {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            p.currentDirectoryURL = repo
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run()
            p.waitUntilExit()
        }
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.email", "t@example.com"])
        try git(["config", "user.name", "Test"])
        return (git, repo)
    }

    func testDefaultBranchFallsBackToLocalMain() throws {
        var cleanup: [URL] = []
        defer { cleanup.forEach { try? FileManager.default.removeItem(at: $0) } }
        let (git, repo) = try makeTempRepo(cleanup: &cleanup)
        try "hi".write(to: repo.appendingPathComponent("README"), atomically: true, encoding: .utf8)
        try git(["add", "."])
        try git(["commit", "-qm", "init"])

        // No origin/HEAD; a local `main` exists, so detection falls back to it.
        XCTAssertEqual(try GitService().defaultBranch(repositoryRoot: repo.path), "main")
    }

    func testDefaultBranchFallsBackToMasterWhenNoMain() throws {
        var cleanup: [URL] = []
        defer { cleanup.forEach { try? FileManager.default.removeItem(at: $0) } }
        let (git, repo) = try makeTempRepo(cleanup: &cleanup)
        try "hi".write(to: repo.appendingPathComponent("README"), atomically: true, encoding: .utf8)
        try git(["add", "."])
        try git(["commit", "-qm", "init"])
        // Rename the only branch to `master`; `main` no longer exists.
        try git(["branch", "-m", "master"])

        XCTAssertEqual(try GitService().defaultBranch(repositoryRoot: repo.path), "master")
    }

    func testChangedFilesAgainstDefaultBranchListsCommittedWork() throws {
        var cleanup: [URL] = []
        defer { cleanup.forEach { try? FileManager.default.removeItem(at: $0) } }
        let (git, repo) = try makeTempRepo(cleanup: &cleanup)
        try "base".write(to: repo.appendingPathComponent("README"), atomically: true, encoding: .utf8)
        try git(["add", "."])
        try git(["commit", "-qm", "init"])

        // Commit new work on a feature branch; plain `git status` wouldn't see it.
        try git(["checkout", "-q", "-b", "feature"])
        try "hello".write(to: repo.appendingPathComponent("feature.txt"), atomically: true, encoding: .utf8)
        try "base\nmore".write(to: repo.appendingPathComponent("README"), atomically: true, encoding: .utf8)
        try git(["add", "."])
        try git(["commit", "-qm", "work"])

        let service = GitService()
        let entries = try service.changedFilesAgainstDefaultBranch(repositoryRoot: repo.path, defaultBranch: "main")
        let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0.status) })
        XCTAssertEqual(byPath["feature.txt"], "A")
        XCTAssertEqual(byPath["README"], "M")

        // A single-file three-dot diff renders that file's committed changes.
        let diff = try service.diffAgainstDefaultBranch(relativePath: "feature.txt", repositoryRoot: repo.path, defaultBranch: "main")
        XCTAssertTrue(diff.contains("+hello"))

        // On the default branch itself there is nothing to compare.
        try git(["checkout", "-q", "main"])
        XCTAssertTrue(try service.changedFilesAgainstDefaultBranch(repositoryRoot: repo.path, defaultBranch: "main").isEmpty)
    }
}
