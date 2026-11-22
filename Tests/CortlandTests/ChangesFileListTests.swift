import AppKit
import XCTest
@testable import Cortland

/// The changes pane's file list above the first section and its Collapse All
/// / Expand All button: the pure decisions, then the real pane hosted
/// offscreen.
@MainActor
final class ChangesFileListTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        // Not a repository, so the pane's own load fails and leaves the
        // sections the test displays in place.
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChangesFileListTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    private func section(_ path: String, added: Int = 1, removed: Int = 0, conflicted: Bool = false) -> ChangeSection {
        let lines = (0..<removed).map { "-old \($0)" } + (0..<added).map { "+line \($0)" }
        return ChangeSection(
            relativePath: path,
            diff: "@@ -1,\(removed) +1,\(added) @@\n" + lines.joined(separator: "\n"),
            isConflicted: conflicted,
            status: .modified
        )
    }

    private func row(_ path: String, _ added: Int, _ removed: Int) -> ChangesFileList.Row {
        ChangesFileList.Row(path: path, status: .modified, counts: .init(added: added, removed: removed))
    }

    private func makePane(source: ChangesSource = .uncommitted) -> UncommittedChangesViewController {
        let pane = UncommittedChangesViewController(repositoryPath: directory.path, source: source)
        pane.view.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        pane.view.layoutSubtreeIfNeeded()
        return pane
    }

    private func settle(_ pane: UncommittedChangesViewController) {
        pane.view.layoutSubtreeIfNeeded()
        pane.view.layoutSubtreeIfNeeded()
    }

    private func descendants<T: NSView>(of view: NSView, _ type: T.Type) -> [T] {
        view.subviews.flatMap { subview -> [T] in
            ((subview as? T).map { [$0] } ?? []) + descendants(of: subview, type)
        }
    }

    private func scrollView(_ pane: UncommittedChangesViewController) -> NSScrollView {
        descendants(of: pane.view, NSScrollView.self).first!
    }

    private func stack(_ pane: UncommittedChangesViewController) -> NSStackView {
        scrollView(pane).documentView!.subviews.compactMap { $0 as? NSStackView }.first!
    }

    private func rows(_ pane: UncommittedChangesViewController) -> [ChangesFileListRowView] {
        descendants(of: stack(pane), ChangesFileListRowView.self)
    }

    private func sectionView(_ path: String, in pane: UncommittedChangesViewController) -> NSView {
        let id = section(path).absolutePath(repositoryPath: directory.path)
        return stack(pane).arrangedSubviews.first { $0.identifier?.rawValue == id }!
    }

    private func viewedBox(_ path: String, in pane: UncommittedChangesViewController) -> NSButton {
        descendants(of: sectionView(path, in: pane), NSButton.self).first { $0.title == "Viewed" }!
    }

    private func collapseAllButton(_ pane: UncommittedChangesViewController) -> NSButton? {
        descendants(of: pane.view, NSButton.self).first { $0.title == "Collapse All" || $0.title == "Expand All" }
    }

    private func isCollapsed(_ path: String, in pane: UncommittedChangesViewController) -> Bool {
        sectionView(path, in: pane).frame.height < 29
    }

    private func visibleTop(_ pane: UncommittedChangesViewController) -> CGFloat {
        scrollView(pane).contentView.bounds.minY
    }

    private func offsetFromVisibleTop(_ view: NSView, in pane: UncommittedChangesViewController) -> CGFloat {
        let clipView = scrollView(pane).contentView
        let frame = view.convert(view.bounds, to: clipView)
        return clipView.isFlipped ? frame.minY - clipView.bounds.minY : clipView.bounds.maxY - frame.maxY
    }

    private func scroll(_ pane: UncommittedChangesViewController, toDocumentY y: CGFloat) {
        let scroll = scrollView(pane)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func documentTop(_ view: NSView, in pane: UncommittedChangesViewController) -> CGFloat {
        view.convert(view.bounds, to: scrollView(pane).documentView!).minY
    }

    private func click(_ row: ChangesFileListRowView, in pane: UncommittedChangesViewController) {
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
        row.mouseDown(with: event)
        // The reveal scroll waits for the next runloop pass.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        settle(pane)
    }

    private func press(_ characters: String, in pane: UncommittedChangesViewController) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: 0
        )!
        pane.view.keyDown(with: event)
        settle(pane)
    }

    private func nameColor(_ row: ChangesFileListRowView) -> NSColor? {
        let text = row.pathLabel.attributedStringValue
        return text.attribute(.foregroundColor, at: text.length - 1, effectiveRange: nil) as? NSColor
    }

    private func containsDash(_ text: String) -> Bool {
        text.contains("\u{2014}") || text.contains("\u{2013}")
    }

    // MARK: - 1. Summary model

    func testTotalsSumEveryFile() {
        let summary = ChangesFileList.summary([row("a.swift", 100, 30), row("b.swift", 20, 4)])
        XCTAssertEqual(summary?.total, "2 files, +120 -34")
    }

    func testTotalWordingIsSingularForOneFile() {
        XCTAssertEqual(ChangesFileList.totalText(fileCount: 1, added: 3, removed: 2), "1 file, +3 -2")
        XCTAssertEqual(ChangesFileList.totalText(fileCount: 7, added: 120, removed: 34), "7 files, +120 -34")
    }

    func testRowsKeepSectionOrderAndPerFileCounts() {
        let sections = [section("z.swift", added: 3, removed: 1), section("a/b.swift", added: 0, removed: 2), section("m.swift")]
        let rows = sections.map {
            ChangesFileList.Row(path: $0.relativePath, status: $0.status, counts: ChangesFileList.counts(for: $0, showsImagePreview: false))
        }
        let summary = ChangesFileList.summary(rows)
        XCTAssertEqual(summary?.rows.map(\.path), ["z.swift", "a/b.swift", "m.swift"])
        XCTAssertEqual(summary?.rows.map(\.counts), [.init(added: 3, removed: 1), .init(added: 0, removed: 2), .init(added: 1, removed: 0)])
        XCTAssertEqual(summary?.total, "3 files, +4 -3")
    }

    func testImageAndConflictedFilesHaveNoCounts() {
        XCTAssertNil(ChangesFileList.counts(for: section("logo.png"), showsImagePreview: true))
        XCTAssertNil(ChangesFileList.counts(for: section("a.swift", conflicted: true), showsImagePreview: false))
        let summary = ChangesFileList.summary([
            ChangesFileList.Row(path: "logo.png", status: .added, counts: nil),
            row("a.swift", 5, 1)
        ])
        XCTAssertNil(summary?.rows[0].counts)
        XCTAssertEqual(summary?.total, "2 files, +5 -1")
    }

    func testAbsentForZeroAndOneFile() {
        XCTAssertNil(ChangesFileList.summary([]))
        XCTAssertNil(ChangesFileList.summary([row("a.swift", 1, 1)]))
    }

    func testGeneratedTextHasNoEmOrEnDash() {
        let summary = ChangesFileList.summary([row("a.swift", 1, 2), row("b.swift", 0, 0)])!
        XCTAssertFalse(containsDash(summary.total))
        let counts = ChangesFileList.countsText(.init(added: 4, removed: 9))
        XCTAssertEqual(counts.added + counts.removed, "+4  -9")
        XCTAssertFalse(containsDash(counts.added + counts.removed))
        XCTAssertFalse(containsDash(ChangesFileList.totalText(fileCount: 1, added: 0, removed: 0)))
        for decision in [ChangesCollapseAll.button(collapsed: [false]), ChangesCollapseAll.button(collapsed: [true])] {
            XCTAssertFalse(containsDash(decision.title))
        }
    }

    // MARK: - 5. Collapse All decision

    func testCollapseAllDecision() {
        XCTAssertEqual(ChangesCollapseAll.button(collapsed: [false, false]), .init(title: "Collapse All", isEnabled: true))
        XCTAssertEqual(ChangesCollapseAll.button(collapsed: [true, false]), .init(title: "Collapse All", isEnabled: true))
        XCTAssertEqual(ChangesCollapseAll.button(collapsed: [true, true]), .init(title: "Expand All", isEnabled: true))
        XCTAssertFalse(ChangesCollapseAll.button(collapsed: []).isEnabled)
        XCTAssertTrue(ChangesCollapseAll.collapses(collapsed: [true, false]))
        XCTAssertFalse(ChangesCollapseAll.collapses(collapsed: [true, true]))
    }

    // MARK: - 2. Hosted: rows and clicks

    func testThreeFilesShowThreeRowsAboveTheFirstSection() {
        let pane = makePane()
        pane.display([section("a.swift"), section("src/b.swift", added: 2, removed: 1), section("c.swift")])
        settle(pane)

        let rows = rows(pane)
        XCTAssertEqual(rows.map(\.path), ["a.swift", "src/b.swift", "c.swift"])
        let listBottom = rows.map { documentTop($0, in: pane) + $0.frame.height }.max()!
        XCTAssertLessThanOrEqual(listBottom, documentTop(sectionView("a.swift", in: pane), in: pane))
        XCTAssertEqual(rows[1].pathLabel.stringValue, "src/b.swift")
    }

    func testOneFileShowsNoList() {
        let pane = makePane()
        pane.display([section("a.swift")])
        settle(pane)
        XCTAssertTrue(rows(pane).isEmpty)
    }

    func testClickingARowScrollsItsHeaderToTheTopAndExpandsItKeepingViewed() {
        let pane = makePane()
        pane.display([section("a.swift", added: 40), section("b.swift", added: 40), section("c.swift", added: 40)])
        settle(pane)
        // Viewed collapses c.
        viewedBox("c.swift", in: pane).performClick(nil)
        settle(pane)
        XCTAssertTrue(isCollapsed("c.swift", in: pane))

        click(rows(pane)[2], in: pane)

        XCTAssertFalse(isCollapsed("c.swift", in: pane))
        XCTAssertGreaterThan(visibleTop(pane), 0)
        XCTAssertEqual(offsetFromVisibleTop(sectionView("c.swift", in: pane), in: pane), 10, accuracy: 1)
        XCTAssertEqual(viewedBox("c.swift", in: pane).state, .on)
        XCTAssertTrue(rows(pane)[2].isViewed)

        // c is now the current file, so x collapses it.
        press("x", in: pane)
        XCTAssertTrue(isCollapsed("c.swift", in: pane))
    }

    // MARK: - 3. Hosted: Viewed dims the row

    func testMarkingViewedDimsTheRowAndUnmarkingRestoresIt() {
        let pane = makePane()
        pane.display([section("a.swift"), section("b.swift")])
        settle(pane)
        let row = rows(pane)[1]
        XCTAssertFalse(row.isViewed)
        XCTAssertEqual(nameColor(row), AppTheme.primaryText)

        viewedBox("b.swift", in: pane).performClick(nil)
        XCTAssertTrue(row.isViewed)
        XCTAssertEqual(nameColor(row), AppTheme.mutedText)

        viewedBox("b.swift", in: pane).performClick(nil)
        XCTAssertFalse(row.isViewed)
        XCTAssertEqual(nameColor(row), AppTheme.primaryText)
    }

    // MARK: - 4. Hosted: refresh

    func testRefreshAddsARowInPlaceAndKeepsTheReadersPlace() {
        let pane = makePane()
        let a = section("a.swift", added: 30), c = section("c.swift", added: 30), e = section("e.swift", added: 30)
        pane.display([a, c, e])
        settle(pane)
        let kept = sectionView("a.swift", in: pane)

        let target = sectionView("e.swift", in: pane)
        scroll(pane, toDocumentY: documentTop(target, in: pane) + 40)
        let before = offsetFromVisibleTop(target, in: pane)

        pane.display([a, section("b.swift", added: 3), c, e])
        settle(pane)

        XCTAssertEqual(rows(pane).map(\.path), ["a.swift", "b.swift", "c.swift", "e.swift"])
        XCTAssertTrue(sectionView("a.swift", in: pane) === kept)
        XCTAssertEqual(offsetFromVisibleTop(sectionView("e.swift", in: pane), in: pane), before, accuracy: 1)
    }

    func testRefreshDownToOneFileRemovesTheList() {
        let pane = makePane()
        pane.display([section("a.swift"), section("b.swift")])
        settle(pane)
        pane.display([section("a.swift")])
        settle(pane)
        XCTAssertTrue(rows(pane).isEmpty)
        XCTAssertEqual(stack(pane).arrangedSubviews.count, 1)
    }

    // MARK: - 6. Hosted: Collapse All and Expand All

    func testCollapseAllThenExpandAll() throws {
        let pane = makePane()
        let paths = (0..<30).map { String(format: "file%02d.swift", $0) }
        var sections = paths.map { section($0, added: 5) }
        pane.display(sections)
        settle(pane)
        viewedBox("file03.swift", in: pane).performClick(nil)
        settle(pane)
        let button = try XCTUnwrap(collapseAllButton(pane))
        XCTAssertEqual(button.title, "Collapse All")
        XCTAssertTrue(button.isEnabled)
        scroll(pane, toDocumentY: 400)

        button.performClick(nil)
        settle(pane)
        XCTAssertTrue(paths.allSatisfy { isCollapsed($0, in: pane) })
        XCTAssertEqual(visibleTop(pane), 0, accuracy: 0.5)
        XCTAssertEqual(button.title, "Expand All")
        XCTAssertEqual(viewedBox("file03.swift", in: pane).state, .on)
        XCTAssertEqual(viewedBox("file04.swift", in: pane).state, .off)

        // A refresh keeps what the user set.
        sections.append(section("zz.swift"))
        pane.display(sections)
        settle(pane)
        XCTAssertTrue(paths.allSatisfy { isCollapsed($0, in: pane) })
        XCTAssertFalse(isCollapsed("zz.swift", in: pane))
        XCTAssertEqual(button.title, "Collapse All")
        button.performClick(nil)
        settle(pane)
        XCTAssertEqual(button.title, "Expand All")

        // Expand All holds the file at the top of the visible area.
        let anchor = sectionView("file15.swift", in: pane)
        scroll(pane, toDocumentY: documentTop(anchor, in: pane))
        let before = offsetFromVisibleTop(anchor, in: pane)
        button.performClick(nil)
        settle(pane)
        XCTAssertTrue(paths.allSatisfy { !isCollapsed($0, in: pane) })
        XCTAssertEqual(button.title, "Collapse All")
        XCTAssertEqual(offsetFromVisibleTop(anchor, in: pane), before, accuracy: 1)
        XCTAssertEqual(viewedBox("file03.swift", in: pane).state, .on)
        XCTAssertEqual(viewedBox("file04.swift", in: pane).state, .off)
    }

    func testCollapseAllIsDisabledWithNoSections() throws {
        let pane = makePane()
        pane.display([])
        settle(pane)
        XCTAssertFalse(try XCTUnwrap(collapseAllButton(pane)).isEnabled)
    }

    func testBranchPaneHasTheButtonAndTheList() throws {
        let pane = makePane(source: .branch(defaultBranch: "main"))
        pane.display([section("a.swift"), section("b.swift")])
        settle(pane)
        XCTAssertNil(descendants(of: pane.view, NSSegmentedControl.self).first)
        XCTAssertTrue(try XCTUnwrap(collapseAllButton(pane)).isEnabled)
        XCTAssertEqual(rows(pane).count, 2)
    }
}
