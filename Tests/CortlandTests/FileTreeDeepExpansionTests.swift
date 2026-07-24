import XCTest
@testable import Cortland

/// Reproduces the reported "folders a few levels deep render as files / stop
/// expanding" bug by driving the real FileTreeViewController + NSOutlineView
/// through a deep directory chain, expanding one level at a time the way a
/// user does.
@MainActor
final class FileTreeDeepExpansionTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("filetree-deep-\(UUID().uuidString)")
        var dir = tempRoot!
        for level in 1...8 {
            dir = dir.appendingPathComponent("level\(level)")
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A file at every level so no directory is genuinely empty.
        var parent = tempRoot!
        for level in 1...8 {
            parent = parent.appendingPathComponent("level\(level)")
            FileManager.default.createFile(
                atPath: parent.appendingPathComponent("file\(level).txt").path,
                contents: Data("x".utf8)
            )
        }
    }

    override func tearDownWithError() throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    private func pump(until condition: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
    }

    private func outlineView(in controller: FileTreeViewController) -> NSOutlineView? {
        func find(_ view: NSView) -> NSOutlineView? {
            if let outline = view as? NSOutlineView { return outline }
            for sub in view.subviews {
                if let found = find(sub) { return found }
            }
            return nil
        }
        return find(controller.view)
    }

    func testExpandingEightLevelsDeepKeepsFoldersExpandable() throws {
        let controller = FileTreeViewController()
        controller.loadFileTree(for: tempRoot.path)
        _ = controller.view // triggers viewDidLoad + initial load

        guard let outline = outlineView(in: controller) else {
            XCTFail("no outline view"); return
        }

        // Wait for the async root build to land.
        pump(until: { outline.numberOfRows > 0 })
        guard let root = outline.item(atRow: 0) as? FileTreeNode else {
            XCTFail("root row missing (rows: \(outline.numberOfRows))"); return
        }
        outline.expandItem(root)
        pump(until: { outline.row(forItem: root) >= 0 && root.isLoaded })

        var current: FileTreeNode = root
        for level in 1...8 {
            pump(until: { current.isLoaded }, timeout: 5)
            XCTAssertTrue(current.isLoaded, "level\(level - 1) never loaded")

            guard let next = current.children.first(where: { $0.name == "level\(level)" }) else {
                XCTFail("level\(level) missing from children of \(current.name): \(current.children.map(\.name))")
                return
            }

            XCTAssertTrue(next.isDirectory, "level\(level) is not a directory node — renders with a file icon")
            XCTAssertTrue(
                outline.isExpandable(next),
                "level\(level) not expandable in outline view (isLoaded=\(next.isLoaded), children=\(next.children.count))"
            )

            outline.expandItem(next)
            pump(until: { next.isLoaded }, timeout: 5)
            XCTAssertTrue(next.isLoaded, "level\(level) never loaded after expandItem")
            XCTAssertTrue(outline.isItemExpanded(next), "level\(level) did not stay expanded")
            XCTAssertEqual(
                next.children.count, level == 8 ? 1 : 2,
                "level\(level) children wrong: \(next.children.map(\.name))"
            )
            current = next
        }
    }

    /// A symlink that points at a directory must render and behave as a
    /// directory (folder icon, disclosure triangle, expandable) — pnpm-style
    /// node_modules and build trees are full of these, and they used to render
    /// as plain files that could never be expanded.
    func testSymlinkedDirectoryIsExpandable() throws {
        let realDir = tempRoot.appendingPathComponent("real-target")
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: realDir.appendingPathComponent("inside.txt").path,
            contents: Data("x".utf8)
        )
        let link = tempRoot.appendingPathComponent("linked-folder")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realDir)

        let controller = FileTreeViewController()
        controller.loadFileTree(for: tempRoot.path)
        _ = controller.view

        guard let outline = outlineView(in: controller) else { XCTFail("no outline"); return }
        pump(until: { outline.numberOfRows > 0 })
        guard let root = outline.item(atRow: 0) as? FileTreeNode else { XCTFail("no root"); return }
        outline.expandItem(root)
        pump(until: { root.isLoaded })

        guard let linked = root.children.first(where: { $0.name == "linked-folder" }) else {
            XCTFail("linked-folder missing: \(root.children.map(\.name))"); return
        }
        XCTAssertTrue(linked.isDirectory, "symlinked directory renders as a file")
        XCTAssertTrue(outline.isExpandable(linked), "symlinked directory is not expandable")

        outline.expandItem(linked)
        pump(until: { linked.isLoaded })
        XCTAssertEqual(linked.children.map(\.name), ["inside.txt"])
    }

    /// Expanded folders must still have an icon: "folder.open" is not a real
    /// SF Symbol, and a nil icon leaves expanded folder rows glyph-less so they
    /// stop reading as folders.
    func testFolderIconsExistForBothStates() {
        let node = FileTreeNode(url: tempRoot, isDirectory: true)
        XCTAssertNotNil(node.icon, "collapsed folder icon missing")
        node.isExpanded = true
        XCTAssertNotNil(node.icon, "expanded folder icon missing")
    }
}
