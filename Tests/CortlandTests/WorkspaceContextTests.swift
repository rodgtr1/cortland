import XCTest
@testable import Cortland

final class WorkspaceContextTests: XCTestCase {
    func testRelativePathUsesRepositoryRootWhenAvailable() {
        let context = WorkspaceContext(
            workingDirectory: "/tmp/project/content/18.x",
            repositoryRoot: "/tmp/project"
        )

        XCTAssertEqual(
            context.relativePath(for: "/tmp/project/content/18.x/docs/page.mdx"),
            "content/18.x/docs/page.mdx"
        )
    }

    func testAbsolutePathUsesRepositoryRootForRepoPaths() {
        let context = WorkspaceContext(
            workingDirectory: "/tmp/project/content/18.x",
            repositoryRoot: "/tmp/project"
        )

        XCTAssertEqual(
            context.absolutePath(forRepoPath: "content/18.x/docs/page.mdx"),
            "/tmp/project/content/18.x/docs/page.mdx"
        )
    }

    func testRelativePathFallsBackToAbsolutePathOutsideWorkspace() {
        let context = WorkspaceContext(workingDirectory: "/tmp/project")

        XCTAssertEqual(
            context.relativePath(for: "/tmp/other/file.swift"),
            "/tmp/other/file.swift"
        )
    }
}
