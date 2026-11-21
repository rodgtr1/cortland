import AppKit
import XCTest
@testable import Cortland

/// Hosts the real changes pane offscreen and checks where its content sits
/// in the scroll view: at the top when it is short, and at the right place
/// on a first display and across a live refresh when it is tall.
final class ChangesPaneLayoutTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        // Not a repository, so the pane's own load fails and leaves the
        // sections the test displays in place.
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChangesPaneLayoutTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makePane(focusedFilePath: String? = nil) -> UncommittedChangesViewController {
        let pane = UncommittedChangesViewController(repositoryPath: directory.path, focusedFilePath: focusedFilePath)
        pane.view.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        pane.view.layoutSubtreeIfNeeded()
        return pane
    }

    private func settle(_ pane: UncommittedChangesViewController) {
        pane.view.layoutSubtreeIfNeeded()
        pane.view.layoutSubtreeIfNeeded()
    }

    private func scrollView(_ pane: UncommittedChangesViewController) -> NSScrollView {
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap(find).first
        }
        return find(pane.view)!
    }

    private func stack(_ pane: UncommittedChangesViewController) -> NSStackView {
        scrollView(pane).documentView!.subviews.compactMap { $0 as? NSStackView }.first!
    }

    /// The top of the visible area, in document coordinates measured down
    /// from the document's top.
    private func visibleTop(_ pane: UncommittedChangesViewController) -> CGFloat {
        let scroll = scrollView(pane)
        let clip = scroll.contentView.bounds
        let document = scroll.documentView!
        return document.isFlipped ? clip.minY : document.bounds.height - clip.maxY
    }

    /// A subview's top edge as a distance below the top of the visible area.
    private func offsetFromVisibleTop(_ view: NSView, in pane: UncommittedChangesViewController) -> CGFloat {
        let scroll = scrollView(pane)
        let clipView = scroll.contentView
        let frame = view.convert(view.bounds, to: clipView)
        let top = clipView.isFlipped ? frame.minY : frame.maxY
        return clipView.isFlipped ? top - clipView.bounds.minY : clipView.bounds.maxY - top
    }

    private func sectionView(_ path: String, in pane: UncommittedChangesViewController) -> NSView {
        let id = section(path).absolutePath(repositoryPath: directory.path)
        return stack(pane).arrangedSubviews.first { $0.identifier?.rawValue == id }!
    }

    private func section(_ path: String, lines: Int = 1) -> ChangeSection {
        let body = (0..<lines).map { "+line \($0)" }.joined(separator: "\n")
        return ChangeSection(
            relativePath: path,
            diff: "@@ -0,0 +1,\(lines) @@\n\(body)",
            isConflicted: false,
            status: .modified
        )
    }

    private func tallSections() -> [ChangeSection] {
        (0..<8).map { section("file\($0).swift", lines: 30) }
    }

    func testShortContentSitsAtTheTop() {
        let pane = makePane()
        pane.display([section("only.swift")])
        settle(pane)

        let inset = stack(pane).edgeInsets.top
        XCTAssertEqual(offsetFromVisibleTop(sectionView("only.swift", in: pane), in: pane), inset, accuracy: 1)
    }

    func testPlaceholderMessageSitsAtTheTop() {
        let pane = makePane()
        settle(pane)

        // The load is still running, so the pane shows its loading message.
        let views = stack(pane).arrangedSubviews
        XCTAssertEqual(views.count, 1)
        let label = try? XCTUnwrap(views.first as? NSTextField)
        XCTAssertEqual(label?.stringValue, "Loading changes...")
        XCTAssertEqual(offsetFromVisibleTop(views[0], in: pane), stack(pane).edgeInsets.top, accuracy: 1)
    }

    func testNoChangesMessageSitsAtTheTop() {
        let pane = makePane()
        pane.display([])
        settle(pane)

        let views = stack(pane).arrangedSubviews
        XCTAssertEqual((views.first as? NSTextField)?.stringValue, "No changes")
        XCTAssertEqual(offsetFromVisibleTop(views[0], in: pane), stack(pane).edgeInsets.top, accuracy: 1)
    }

    func testTallFirstDisplayWithoutFocusStartsAtTheTop() {
        let pane = makePane()
        pane.display(tallSections())
        settle(pane)

        let scroll = scrollView(pane)
        XCTAssertGreaterThan(scroll.documentView!.bounds.height, scroll.contentView.bounds.height * 2)
        XCTAssertEqual(visibleTop(pane), 0, accuracy: 0.5)
    }

    func testTallFirstDisplayScrollsTheFocusedFileToTheTop() {
        let pane = makePane(focusedFilePath: section("file3.swift").absolutePath(repositoryPath: directory.path))
        pane.display(tallSections())
        settle(pane)
        // The focus scroll waits for the next runloop pass.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertGreaterThan(visibleTop(pane), 0)
        let offset = offsetFromVisibleTop(sectionView("file3.swift", in: pane), in: pane)
        XCTAssertEqual(offset, 10, accuracy: 1)
    }

    func testRefreshAboveTheReaderKeepsTheirPlace() {
        let pane = makePane()
        var sections = tallSections()
        pane.display(sections)
        settle(pane)

        let scroll = scrollView(pane)
        let target = sectionView("file4.swift", in: pane)
        let targetTop = target.convert(target.bounds, to: scroll.documentView!).minY
        scroll.contentView.scroll(to: NSPoint(x: 0, y: targetTop + 40))
        scroll.reflectScrolledClipView(scroll.contentView)
        let before = offsetFromVisibleTop(target, in: pane)

        // A file above the reader grows by twenty lines.
        sections[1] = section("file1.swift", lines: 50)
        pane.display(sections)
        settle(pane)

        XCTAssertEqual(offsetFromVisibleTop(sectionView("file4.swift", in: pane), in: pane), before, accuracy: 1)
        XCTAssertGreaterThan(visibleTop(pane), targetTop + 40)
    }
}
