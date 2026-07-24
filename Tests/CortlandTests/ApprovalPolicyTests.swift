import XCTest
@testable import Cortland

final class ApprovalPolicyTests: XCTestCase {
    // MARK: - Glob matching

    func testStarStaysWithinSegment() {
        XCTAssertTrue(ApprovalPolicy.glob("*.swift", matches: "/repo/Sources/Foo.swift"))
        XCTAssertFalse(ApprovalPolicy.glob("Sources/*.swift", matches: "/repo/Sources/Nested/Foo.swift"))
    }

    func testDoubleStarSpansSeparators() {
        XCTAssertTrue(ApprovalPolicy.glob("Sources/**", matches: "/repo/Sources/A/B/Foo.swift"))
        XCTAssertTrue(ApprovalPolicy.glob("**/secrets/**", matches: "/repo/app/secrets/key.pem"))
    }

    func testUnanchoredMatchesAnywhereOnBoundary() {
        XCTAssertTrue(ApprovalPolicy.glob(".env", matches: "/repo/.env"))
        // Must match on a path boundary, not a substring.
        XCTAssertFalse(ApprovalPolicy.glob(".env", matches: "/repo/.envrc"))
        XCTAssertFalse(ApprovalPolicy.glob("env", matches: "/repo/preventer"))
    }

    func testAnchoredPatternRequiresFullPath() {
        XCTAssertTrue(ApprovalPolicy.glob("/repo/Sources/**", matches: "/repo/Sources/Foo.swift"))
        XCTAssertFalse(ApprovalPolicy.glob("/other/**", matches: "/repo/Sources/Foo.swift"))
    }

    func testMatchingIsCaseInsensitive() {
        // The default macOS filesystem is case-insensitive, so a rule for
        // `.env` must also cover `.ENV` / `.Env` — same file on disk.
        XCTAssertTrue(ApprovalPolicy.glob(".env", matches: "/repo/.ENV"))
        XCTAssertTrue(ApprovalPolicy.glob("Secrets/**", matches: "/repo/secrets/key.pem"))
    }

    // MARK: - Over-broad auto_allow guard

    func testOverBroadPatternsRejected() {
        for pattern in ["", "   ", "*", "**", "/**", "**/*", "*/**", "?*"] {
            XCTAssertTrue(ApprovalPolicy.isOverBroad(pattern), "expected over-broad: \(pattern)")
        }
    }

    func testSelectivePatternsNotOverBroad() {
        for pattern in ["*.swift", "Sources/**", ".env", "/repo/**", "**/*.env", "src/*.ts"] {
            XCTAssertFalse(ApprovalPolicy.isOverBroad(pattern), "expected selective: \(pattern)")
        }
    }

    func testOverBroadAutoAllowIgnored() {
        // A bare `*` typo must not silently auto-approve every edit in ask mode.
        XCTAssertEqual(decide("/repo/.env", autoAllow: ["*"]), .ask)
        XCTAssertEqual(decide("/repo/Sources/Foo.swift", autoAllow: ["/**"]), .ask)
    }

    // MARK: - Decision precedence

    private func decide(
        _ path: String,
        globalAuto: Bool = false,
        autoAllow: [String] = [],
        alwaysAsk: [String] = [],
        session: SessionApprovals = SessionApprovals(),
        workingRoot: String? = nil,
        worktreeAutoApprove: Bool = false
    ) -> ApprovalPolicy.Decision {
        ApprovalPolicy.decide(
            path: path,
            globalAuto: globalAuto,
            autoAllow: autoAllow,
            alwaysAsk: alwaysAsk,
            session: session,
            workingRoot: workingRoot,
            worktreeAutoApprove: worktreeAutoApprove
        )
    }

    func testDefaultAsks() {
        XCTAssertEqual(decide("/repo/Sources/Foo.swift"), .ask)
    }

    func testGlobalAutoAllows() {
        XCTAssertEqual(decide("/repo/Sources/Foo.swift", globalAuto: true), .allow)
    }

    func testAutoAllowOverridesAskMode() {
        XCTAssertEqual(decide("/repo/Sources/Foo.swift", autoAllow: ["Sources/**"]), .allow)
    }

    func testAlwaysAskWinsOverGlobalAuto() {
        XCTAssertEqual(decide("/repo/.env", globalAuto: true, alwaysAsk: [".env"]), .ask)
    }

    func testAlwaysAskWinsOverAutoAllow() {
        XCTAssertEqual(
            decide("/repo/.env", autoAllow: ["**"], alwaysAsk: [".env"]),
            .ask
        )
    }

    func testAlwaysAskWinsOverRememberedFolder() {
        var session = SessionApprovals()
        session.record(.folder, path: "/repo/.env")  // remembers /repo
        XCTAssertEqual(decide("/repo/.env", alwaysAsk: [".env"], session: session), .ask)
    }

    // MARK: - Session "approve & remember"

    func testRememberFileAllowsOnlyThatFile() {
        var session = SessionApprovals()
        session.record(.file, path: "/repo/a.txt")
        XCTAssertEqual(decide("/repo/a.txt", session: session), .allow)
        XCTAssertEqual(decide("/repo/b.txt", session: session), .ask)
    }

    func testRememberFolderAllowsSubtree() {
        var session = SessionApprovals()
        session.record(.folder, path: "/repo/src/a.txt")  // remembers /repo/src
        XCTAssertEqual(decide("/repo/src/a.txt", session: session), .allow)
        XCTAssertEqual(decide("/repo/src/deep/b.txt", session: session), .allow)
        XCTAssertEqual(decide("/repo/other/c.txt", session: session), .ask)
    }

    func testRememberSessionAllowsEverything() {
        var session = SessionApprovals()
        session.record(.session, path: "/repo/a.txt")
        XCTAssertEqual(decide("/anywhere/else.txt", session: session), .allow)
    }

    func testRememberNoneGrantsNothing() {
        var session = SessionApprovals()
        session.record(.none, path: "/repo/a.txt")
        XCTAssertEqual(decide("/repo/a.txt", session: session), .ask)
    }

    // MARK: - Worktree-scoped auto-approve

    // Use /private/tmp because /tmp is itself a symlink on macOS; canonical()
    // resolves it, and these string-literal cases stay stable when it does.
    private let worktree = "/private/tmp/repo-worktrees/n3-foo"

    func testWorktreeAutoApproveAllowsPathsInsideRoot() {
        XCTAssertEqual(
            decide("\(worktree)/Sources/App.swift", workingRoot: worktree, worktreeAutoApprove: true),
            .allow
        )
        // The root directory itself counts as inside.
        XCTAssertEqual(
            decide(worktree, workingRoot: worktree, worktreeAutoApprove: true),
            .allow
        )
    }

    func testWorktreeAutoApproveDisabledByDefault() {
        // Same path and working root, but the opt-in is off: still prompts.
        XCTAssertEqual(
            decide("\(worktree)/Sources/App.swift", workingRoot: worktree),
            .ask
        )
    }

    func testWorktreeAutoApproveIgnoredWithoutWorkingRoot() {
        // A pane that isn't in a registered worktree (nil root) keeps prompting
        // even with the feature enabled.
        XCTAssertEqual(
            decide("\(worktree)/Sources/App.swift", worktreeAutoApprove: true),
            .ask
        )
    }

    func testWorktreeAutoApproveDoesNotCoverPathsOutsideRoot() {
        // An agent in the worktree editing via an absolute path into the MAIN
        // checkout must keep prompting — the edit is outside its working root.
        XCTAssertEqual(
            decide("/private/tmp/repo/Sources/App.swift", workingRoot: worktree, worktreeAutoApprove: true),
            .ask
        )
        // ...and a sibling worktree is likewise outside.
        XCTAssertEqual(
            decide("/private/tmp/repo-worktrees/n2-bar/x.swift", workingRoot: worktree, worktreeAutoApprove: true),
            .ask
        )
    }

    func testWorktreeAutoApprovePrefixCollisionStaysOutside() {
        // Component-based containment: /...n3-foobar must NOT be treated as
        // inside /...n3-foo just because the string is a prefix.
        XCTAssertEqual(
            decide("/private/tmp/repo-worktrees/n3-foobar/x.swift", workingRoot: worktree, worktreeAutoApprove: true),
            .ask
        )
    }

    func testAlwaysAskBeatsWorktreeAutoApprove() {
        // A secrets rule keeps prompting even for a path inside the worktree.
        XCTAssertEqual(
            decide("\(worktree)/.env", alwaysAsk: [".env"], workingRoot: worktree, worktreeAutoApprove: true),
            .ask
        )
    }

    func testWorktreeAutoApproveCanonicalizesSymlinksAndDotDot() throws {
        // Real on-disk symlink so canonical() has something to resolve: a link
        // /…/link -> /…/realroot. An edit reported through the link, and one
        // using `..` traversal, must both resolve INSIDE the real root.
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("wt-canon-\(ProcessInfo.processInfo.globallyUniqueString)")
        let realRoot = base.appendingPathComponent("realroot")
        let link = base.appendingPathComponent("link")
        try fm.createDirectory(at: realRoot.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: realRoot)
        defer { try? fm.removeItem(at: base) }

        // Working root given via the symlink; edit given via the real path.
        XCTAssertEqual(
            decide(realRoot.appendingPathComponent("Sources/App.swift").path,
                   workingRoot: link.path,
                   worktreeAutoApprove: true),
            .allow
        )
        // `..` that escapes the root resolves outside and must prompt.
        XCTAssertEqual(
            decide(realRoot.appendingPathComponent("Sources/../../escape.swift").path,
                   workingRoot: realRoot.path,
                   worktreeAutoApprove: true),
            .ask
        )
        // `..` that stays within the root resolves inside and auto-approves.
        XCTAssertEqual(
            decide(realRoot.appendingPathComponent("Sources/../App.swift").path,
                   workingRoot: realRoot.path,
                   worktreeAutoApprove: true),
            .allow
        )
    }
}
