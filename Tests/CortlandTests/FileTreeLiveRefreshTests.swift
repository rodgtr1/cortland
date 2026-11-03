import XCTest
@testable import Cortland

/// The file tree must follow the disk: a file an agent or a sync job creates
/// shows up without the user touching anything. Drives the real controller
/// and its FSEvents stream against a temp folder.
@MainActor
final class FileTreeLiveRefreshTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("filetree-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot.appendingPathComponent("notes"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tempRoot.appendingPathComponent("README.md").path, contents: Data("x".utf8))
        FileManager.default.createFile(atPath: tempRoot.appendingPathComponent("notes/a.md").path, contents: Data("x".utf8))
    }

    override func tearDownWithError() throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    private func pump(until condition: () -> Bool, timeout: TimeInterval = 6) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
    }

    private func outlineView(in controller: FileTreeViewController) -> NSOutlineView? {
        func find(_ view: NSView) -> NSOutlineView? {
            if let outline = view as? NSOutlineView { return outline }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        return find(controller.view)
    }

    private func rowNames(_ outline: NSOutlineView) -> [String] {
        (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? FileTreeNode)?.name }
    }

    private func loadedTree(for path: String) -> (FileTreeViewController, NSOutlineView, FileTreeNode)? {
        let controller = FileTreeViewController()
        controller.loadFileTree(for: path)
        _ = controller.view
        guard let outline = outlineView(in: controller) else { XCTFail("no outline"); return nil }
        pump(until: { outline.numberOfRows > 0 })
        guard let root = outline.item(atRow: 0) as? FileTreeNode else { XCTFail("no root"); return nil }
        outline.expandItem(root)
        pump(until: { root.isLoaded && outline.isItemExpanded(root) })
        return (controller, outline, root)
    }

    func testNewFileAtRootAppearsOnItsOwn() throws {
        guard let (controller, outline, _) = loadedTree(for: tempRoot.path) else { return }
        withExtendedLifetime(controller) {
            XCTAssertEqual(rowNames(outline).filter { $0 != tempRoot.lastPathComponent }, ["notes", "README.md"])

            FileManager.default.createFile(atPath: tempRoot.appendingPathComponent("new.md").path, contents: Data("y".utf8))
            pump(until: { rowNames(outline).contains("new.md") })
            XCTAssertTrue(rowNames(outline).contains("new.md"), "rows: \(rowNames(outline))")
        }
    }

    func testNewFileInExpandedFolderAppearsOnItsOwn() throws {
        guard let (controller, outline, root) = loadedTree(for: tempRoot.path) else { return }
        withExtendedLifetime(controller) {
            guard let notes = root.children.first(where: { $0.name == "notes" }) else { XCTFail("no notes"); return }
            outline.expandItem(notes)
            pump(until: { notes.isLoaded && outline.isItemExpanded(notes) })
            XCTAssertTrue(rowNames(outline).contains("a.md"))

            FileManager.default.createFile(atPath: tempRoot.appendingPathComponent("notes/b.md").path, contents: Data("y".utf8))
            pump(until: { rowNames(outline).contains("b.md") })
            XCTAssertTrue(rowNames(outline).contains("b.md"), "rows: \(rowNames(outline))")
            XCTAssertTrue(outline.isItemExpanded(outline.item(atRow: outline.row(forItem: notes) >= 0 ? outline.row(forItem: notes) : 0)!), "notes collapsed on refresh")
        }
    }

    func testFileCreatedWhileAnotherRootWasShownAppearsOnReturn() throws {
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("filetree-other-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }

        guard let (controller, outline, _) = loadedTree(for: tempRoot.path) else { return }
        withExtendedLifetime(controller) {
            controller.loadFileTree(for: other.path)
            pump(until: { (outline.item(atRow: 0) as? FileTreeNode)?.name == other.lastPathComponent })

            FileManager.default.createFile(atPath: tempRoot.appendingPathComponent("later.md").path, contents: Data("y".utf8))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))

            controller.loadFileTree(for: tempRoot.path)
            pump(until: { rowNames(outline).contains("later.md") })
            XCTAssertTrue(rowNames(outline).contains("later.md"), "rows: \(rowNames(outline))")
        }
    }
}

extension FileTreeLiveRefreshTests {
    /// Re-expanding a folder re-reads it: the rescan lands within a few
    /// milliseconds, well ahead of the watcher's 0.75s leading-edge refresh,
    /// so a row appearing inside the window below is the expand's doing.
    func testReexpandingALoadedFolderRescansIt() throws {
        guard let (controller, outline, root) = loadedTree(for: tempRoot.path) else { return }
        withExtendedLifetime(controller) {
            guard let notes = root.children.first(where: { $0.name == "notes" }) else { XCTFail("no notes"); return }
            outline.expandItem(notes)
            pump(until: { notes.isLoaded && outline.isItemExpanded(notes) })
            outline.collapseItem(notes)
            XCTAssertTrue(notes.isLoaded, "collapsing must keep the cached children for this test to mean anything")

            FileManager.default.createFile(atPath: tempRoot.appendingPathComponent("notes/c.md").path, contents: Data("y".utf8))
            outline.expandItem(notes)
            pump(until: { rowNames(outline).contains("c.md") }, timeout: 0.5)
            XCTAssertTrue(rowNames(outline).contains("c.md"), "rows: \(rowNames(outline))")
        }
    }
}
