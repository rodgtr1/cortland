import XCTest
@testable import Cortland

/// Covers `FileTreeNode.isStructurallyIdentical(to:)`, which decides whether a
/// freshly scanned tree describes exactly what the sidebar already shows — the
/// test for dropping the every-2s FSEvents rebuild. Pure: nodes are built with
/// an explicit `isDirectory` so nothing touches the filesystem or AppKit.
final class FileTreeStructuralEqualityTests: XCTestCase {
    private func file(_ path: String, gitIgnored: Bool = false) -> FileTreeNode {
        let node = FileTreeNode(url: URL(fileURLWithPath: path), isDirectory: false)
        node.isGitIgnored = gitIgnored
        return node
    }

    private func directory(
        _ path: String,
        loaded: Bool = true,
        expanded: Bool = false,
        gitIgnored: Bool = false,
        children: [FileTreeNode] = []
    ) -> FileTreeNode {
        let node = FileTreeNode(url: URL(fileURLWithPath: path), isDirectory: true)
        node.isLoaded = loaded
        node.isExpanded = expanded
        node.isGitIgnored = gitIgnored
        node.children = children
        for child in children {
            child.parent = node
        }
        return node
    }

    /// The shape the sidebar holds most of the time: a loaded root, one expanded
    /// subdirectory, one collapsed-and-unloaded subdirectory.
    private func sampleTree() -> FileTreeNode {
        return directory("/repo", loaded: true, expanded: true, children: [
            directory("/repo/Sources", loaded: true, expanded: true, children: [
                file("/repo/Sources/App.swift"),
                file("/repo/Sources/Util.swift")
            ]),
            directory("/repo/Tests", loaded: false),
            file("/repo/README.md")
        ])
    }

    func testIdenticalTreesMatch() {
        XCTAssertTrue(sampleTree().isStructurallyIdentical(to: sampleTree()))
    }

    func testNodeMatchesItself() {
        let tree = sampleTree()
        XCTAssertTrue(tree.isStructurallyIdentical(to: tree))
    }

    func testAddedFileDoesNotMatch() {
        let fresh = directory("/repo", loaded: true, expanded: true, children: [
            directory("/repo/Sources", loaded: true, expanded: true, children: [
                file("/repo/Sources/App.swift"),
                file("/repo/Sources/New.swift"),
                file("/repo/Sources/Util.swift")
            ]),
            directory("/repo/Tests", loaded: false),
            file("/repo/README.md")
        ])

        XCTAssertFalse(sampleTree().isStructurallyIdentical(to: fresh))
    }

    func testRemovedFileDoesNotMatch() {
        let fresh = directory("/repo", loaded: true, expanded: true, children: [
            directory("/repo/Sources", loaded: true, expanded: true, children: [
                file("/repo/Sources/App.swift")
            ]),
            directory("/repo/Tests", loaded: false),
            file("/repo/README.md")
        ])

        XCTAssertFalse(sampleTree().isStructurallyIdentical(to: fresh))
    }

    func testReorderedChildrenDoNotMatch() {
        let fresh = directory("/repo", loaded: true, expanded: true, children: [
            directory("/repo/Sources", loaded: true, expanded: true, children: [
                file("/repo/Sources/Util.swift"),
                file("/repo/Sources/App.swift")
            ]),
            directory("/repo/Tests", loaded: false),
            file("/repo/README.md")
        ])

        XCTAssertFalse(sampleTree().isStructurallyIdentical(to: fresh))
    }

    func testRenamedNodeDoesNotMatch() {
        let live = directory("/repo", children: [file("/repo/a.txt")])
        let fresh = directory("/repo", children: [file("/repo/b.txt")])

        XCTAssertFalse(live.isStructurallyIdentical(to: fresh))
    }

    func testDifferentRootDoesNotMatch() {
        let live = directory("/repo", children: [file("/repo/a.txt")])
        let fresh = directory("/other", children: [file("/other/a.txt")])

        XCTAssertFalse(live.isStructurallyIdentical(to: fresh), "a tab switch retargets the tree to a new root")
    }

    func testFileReplacedByDirectoryDoesNotMatch() {
        let live = directory("/repo", children: [file("/repo/build")])
        let fresh = directory("/repo", children: [directory("/repo/build", loaded: false)])

        XCTAssertFalse(live.isStructurallyIdentical(to: fresh))
    }

    func testGitIgnoreFlagChangeDoesNotMatch() {
        let live = directory("/repo", children: [file("/repo/out.log", gitIgnored: false)])
        let fresh = directory("/repo", children: [file("/repo/out.log", gitIgnored: true)])

        XCTAssertFalse(live.isStructurallyIdentical(to: fresh), "isGitIgnored drives dimming, so the rows differ")
    }

    func testHiddenFlagFollowsNameAndDoesNotMatch() {
        let live = directory("/repo", children: [file("/repo/env")])
        let fresh = directory("/repo", children: [file("/repo/.env")])

        XCTAssertTrue(fresh.children[0].isHidden)
        XCTAssertFalse(live.children[0].isHidden)
        XCTAssertFalse(live.isStructurallyIdentical(to: fresh))
    }

    func testExpansionChangeDoesNotMatch() {
        let live = directory("/repo", expanded: true, children: [
            directory("/repo/Sources", loaded: true, expanded: true, children: [file("/repo/Sources/App.swift")])
        ])
        let fresh = directory("/repo", expanded: true, children: [
            directory("/repo/Sources", loaded: true, expanded: false, children: [file("/repo/Sources/App.swift")])
        ])

        XCTAssertFalse(live.isStructurallyIdentical(to: fresh))
    }

    func testLoadedDirectoryDoesNotMatchUnloadedOne() {
        // A folder the user collapsed stays loaded in the live tree while a fresh
        // scan leaves it unloaded. Its cached children may be stale, so it must
        // not survive the skip.
        let live = directory("/repo", children: [
            directory("/repo/Sources", loaded: true, children: [file("/repo/Sources/Stale.swift")])
        ])
        let fresh = directory("/repo", children: [directory("/repo/Sources", loaded: false)])

        XCTAssertFalse(live.isStructurallyIdentical(to: fresh))
    }

    func testUnloadedDirectoriesMatchWithoutDescending() {
        let live = directory("/repo", children: [directory("/repo/Sources", loaded: false)])
        let fresh = directory("/repo", children: [directory("/repo/Sources", loaded: false)])

        XCTAssertTrue(live.isStructurallyIdentical(to: fresh), "an unloaded directory shows no rows")
    }

    func testDifferenceDeepInLoadedSubtreeDoesNotMatch() {
        let live = directory("/repo", expanded: true, children: [
            directory("/repo/a", loaded: true, expanded: true, children: [
                directory("/repo/a/b", loaded: true, expanded: true, children: [file("/repo/a/b/one.txt")])
            ])
        ])
        let fresh = directory("/repo", expanded: true, children: [
            directory("/repo/a", loaded: true, expanded: true, children: [
                directory("/repo/a/b", loaded: true, expanded: true, children: [
                    file("/repo/a/b/one.txt"),
                    file("/repo/a/b/two.txt")
                ])
            ])
        ])

        XCTAssertFalse(live.isStructurallyIdentical(to: fresh))
    }
}
