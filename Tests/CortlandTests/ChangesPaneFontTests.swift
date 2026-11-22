import AppKit
import XCTest
@testable import Cortland

/// The changes pane draws its diff text in the built-in editor's font, sizes
/// lines from it, and follows a config change without losing the reader's
/// place or the rows comments hang on.
@MainActor
final class ChangesPaneFontTests: XCTestCase {
    private var directory: URL!

    private let sampleDiff = """
    @@ -1,3 +1,3 @@ func sample()
     let a = 1
    -let b = 2
    +let b = 3
     let c = 4
    """

    override func setUpWithError() throws {
        // Not a repository, so the pane's own load fails and leaves the
        // sections the test displays in place.
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChangesPaneFontTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    private func config(family: String = "", size: Int = 13) -> Config {
        var config = Config()
        config.editor?.fontFamily = family
        config.editor?.fontSize = size
        return config
    }

    private func makePane() -> UncommittedChangesViewController {
        let pane = UncommittedChangesViewController(repositoryPath: directory.path)
        pane.view.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        pane.view.layoutSubtreeIfNeeded()
        return pane
    }

    private func settle(_ pane: UncommittedChangesViewController) {
        pane.view.layoutSubtreeIfNeeded()
        pane.view.layoutSubtreeIfNeeded()
    }

    private func section(_ path: String, lines: Int) -> ChangeSection {
        let body = (0..<lines).map { "+line \($0)" }.joined(separator: "\n")
        return ChangeSection(relativePath: path, diff: "@@ -0,0 +1,\(lines) @@\n\(body)", isConflicted: false, status: .modified)
    }

    private func scrollView(_ pane: UncommittedChangesViewController) -> NSScrollView {
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap(find).first
        }
        return find(pane.view)!
    }

    private func sectionView(_ path: String, in pane: UncommittedChangesViewController) -> NSView {
        let id = section(path, lines: 1).absolutePath(repositoryPath: directory.path)
        let stack = scrollView(pane).documentView!.subviews.compactMap { $0 as? NSStackView }.first!
        return stack.arrangedSubviews.first { $0.identifier?.rawValue == id }!
    }

    private func diffTextView(_ path: String, in pane: UncommittedChangesViewController) -> NSTextView {
        func find(_ view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap(find).first
        }
        return find(sectionView(path, in: pane))!
    }

    private func heightConstraint(of view: NSView) -> NSLayoutConstraint {
        view.constraints.first { $0.firstAttribute == .height && $0.secondItem == nil }!
    }

    private func offsetFromVisibleTop(_ view: NSView, in pane: UncommittedChangesViewController) -> CGFloat {
        let clipView = scrollView(pane).contentView
        let frame = view.convert(view.bounds, to: clipView)
        return clipView.isFlipped ? frame.minY - clipView.bounds.minY : clipView.bounds.maxY - frame.maxY
    }

    private func codeFont(_ text: NSAttributedString, line lineIndex: Int) -> NSFont? {
        let lines = text.string.components(separatedBy: "\n")
        let location = lines.prefix(lineIndex).reduce(0) { $0 + ($1 as NSString).length + 1 }
        return text.attribute(.font, at: location, effectiveRange: nil) as? NSFont
    }

    private func gutterIndent(_ text: NSAttributedString, line lineIndex: Int) -> CGFloat? {
        let lines = text.string.components(separatedBy: "\n")
        let location = lines.prefix(lineIndex).reduce(0) { $0 + ($1 as NSString).length + 1 }
        return (text.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)?.firstLineHeadIndent
    }

    // MARK: - 1. Renderer

    func testRenderPutsTheGivenFontOnEveryLineAndSizesTheGutterFromIt() throws {
        let font = try XCTUnwrap(NSFont(name: "Menlo", size: 18))
        let rendered = InlineDiffRenderer.render(sampleDiff, fileExtension: "swift", font: font)
        let width = DiffLineBackgroundLayoutManager.gutterMetrics(for: font).width
        // Hunk header, context, removed, added, context.
        for line in 0..<5 {
            XCTAssertEqual(codeFont(rendered, line: line), font, "line \(line)")
            XCTAssertEqual(gutterIndent(rendered, line: line) ?? 0, width, accuracy: 0.01, "line \(line)")
        }
        XCTAssertGreaterThan(width, DiffLineBackgroundLayoutManager.gutterMetrics(for: InlineDiffRenderer.font).width)
    }

    func testRenderWithoutAFontKeepsTodaysFont() {
        let rendered = InlineDiffRenderer.render(sampleDiff, fileExtension: "swift")
        let today = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        XCTAssertEqual(InlineDiffRenderer.font, today)
        XCTAssertEqual(codeFont(rendered, line: 2), today)
        XCTAssertEqual(
            gutterIndent(rendered, line: 2) ?? 0,
            DiffLineBackgroundLayoutManager.gutterMetrics(for: today).width,
            accuracy: 0.01
        )
    }

    func testDefaultEditorFontIsTodaysDiffFont() {
        XCTAssertEqual(EditorViewController.editorFont(for: EditorConfig()), InlineDiffRenderer.font)
    }

    // MARK: - 2. Hosted pane

    func testPaneUsesTheDefaultEditorFont() {
        let pane = makePane()
        pane.applyConfig(Config())
        pane.display([section("a.swift", lines: 3)])
        settle(pane)

        let textView = diffTextView("a.swift", in: pane)
        let expected = EditorViewController.editorFont(for: EditorConfig())
        XCTAssertEqual(pane.diffFont, expected)
        XCTAssertEqual(codeFont(textView.textStorage!, line: 0), expected)
    }

    func testPaneUsesAConfiguredFamilyAndSizeOnTextAndGutter() throws {
        let pane = makePane()
        let config = config(family: "Menlo", size: 18)
        pane.applyConfig(config)
        pane.display([section("a.swift", lines: 3)])
        settle(pane)

        let expected = try XCTUnwrap(NSFont(name: "Menlo", size: 18))
        XCTAssertEqual(EditorViewController.editorFont(for: config.editor!), expected)
        let text = diffTextView("a.swift", in: pane).textStorage!
        XCTAssertEqual(codeFont(text, line: 1), expected)
        XCTAssertEqual(
            gutterIndent(text, line: 1) ?? 0,
            DiffLineBackgroundLayoutManager.gutterMetrics(for: expected).width,
            accuracy: 0.01
        )
    }

    // MARK: - 3. Heights

    func testSeedAndSettledHeightsScaleWithTheFont() {
        let lines = 10
        // `+ 1`: the rendered text ends in a newline, so the seed counts one
        // more line than the diff has, as before.
        let small = makePane()
        small.display([section("a.swift", lines: lines)])
        let smallSeed = heightConstraint(of: diffTextView("a.swift", in: small)).constant
        // At the default 13pt font the seed is the old 19pt-per-line formula.
        XCTAssertEqual(smallSeed, CGFloat(lines + 1) * 19 + 14)
        settle(small)
        let smallSettled = heightConstraint(of: diffTextView("a.swift", in: small)).constant
        // Settled height is the laid-out lines (the trailing newline's empty
        // line included) plus the 7pt insets.
        let defaultLine = NSLayoutManager().defaultLineHeight(for: InlineDiffRenderer.font)
        XCTAssertEqual(smallSettled, CGFloat(lines + 1) * defaultLine + 14, accuracy: 1)

        let large = makePane()
        large.applyConfig(config(size: 20))
        large.display([section("a.swift", lines: lines)])
        let largeSeed = heightConstraint(of: diffTextView("a.swift", in: large)).constant
        settle(large)
        let largeSettled = heightConstraint(of: diffTextView("a.swift", in: large)).constant

        XCTAssertGreaterThan(largeSeed, smallSeed)
        XCTAssertGreaterThan(largeSettled, smallSettled)
        XCTAssertGreaterThan(sectionView("a.swift", in: large).frame.height, sectionView("a.swift", in: small).frame.height)
    }

    // MARK: - 4. Live change

    func testApplyingANewFontKeepsTheSameFileAtTheTop() throws {
        let pane = makePane()
        let sections = (0..<8).map { section("file\($0).swift", lines: 30) }
        pane.display(sections)
        settle(pane)

        let scroll = scrollView(pane)
        let target = sectionView("file4.swift", in: pane)
        let targetTop = target.convert(target.bounds, to: scroll.documentView!).minY
        scroll.contentView.scroll(to: NSPoint(x: 0, y: targetTop + 40))
        scroll.reflectScrolledClipView(scroll.contentView)
        let before = offsetFromVisibleTop(target, in: pane)
        let heightBefore = target.frame.height

        pane.applyConfig(config(family: "Menlo", size: 20))
        settle(pane)

        let expected = try XCTUnwrap(NSFont(name: "Menlo", size: 20))
        XCTAssertEqual(codeFont(diffTextView("file4.swift", in: pane).textStorage!, line: 0), expected)
        XCTAssertGreaterThan(target.frame.height, heightBefore)
        XCTAssertTrue(sectionView("file4.swift", in: pane) === target)
        XCTAssertEqual(offsetFromVisibleTop(target, in: pane), before, accuracy: 1)
    }

    // MARK: - 5. Comment rows

    func testCommentRowsAreUnchangedByAFontChange() {
        let pane = makePane()
        let diffSection = ChangeSection(relativePath: "a.swift", diff: sampleDiff, isConflicted: false, status: .modified)
        pane.display([diffSection])
        settle(pane)
        let textView = diffTextView("a.swift", in: pane)
        let rowsBefore = ChangesComments.rows(in: textView.textStorage!)
        XCTAssertFalse(rowsBefore.isEmpty)

        pane.applyConfig(config(size: 20))
        settle(pane)

        XCTAssertTrue(diffTextView("a.swift", in: pane) === textView)
        XCTAssertEqual(ChangesComments.rows(in: textView.textStorage!), rowsBefore)
        // The same rows the renderer gives at the new font, so a gutter click
        // and a comment anchor still land on the same diff line.
        let rerendered = InlineDiffRenderer.render(sampleDiff, fileExtension: "swift", font: pane.diffFont)
        XCTAssertEqual(ChangesComments.rows(in: rerendered), rowsBefore)
    }
}
