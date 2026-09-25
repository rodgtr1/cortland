import XCTest
@testable import Cortland

/// With word wrap on, the editor's text must fit the visible width: the text
/// view is never wider than the clip view and never scrolled sideways, so the
/// ruler doesn't hide the start of each line and the right edge doesn't clip
/// the end.
@MainActor
final class EditorWrapLayoutTests: XCTestCase {
    private var window: NSWindow!
    private var container: NSView!
    private var editor: EditorViewController!
    private var tempFile: URL!

    override func setUp() async throws {
        try await MainActor.run { try self.makeEditor() }
    }

    private func makeEditor() throws {
        tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("wrap-\(UUID()).md")
        let line = String(repeating: "word ", count: 80)
        try (1...40).map { _ in line }.joined(separator: "\n").write(to: tempFile, atomically: true, encoding: .utf8)

        editor = EditorViewController()
        _ = editor.view
        // The editor reads the real user config on load; these tests are about
        // word-wrap mode, so force it regardless of what that file says.
        var config = Config.load()
        var editorConfig = config.editor ?? EditorConfig()
        editorConfig.wordWrap = true
        config.editor = editorConfig
        editor.applyConfig(config)
        editor.openFile(tempFile)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                          styleMask: [.titled], backing: .buffered, defer: false)
        container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = container
        editor.view.frame = container.bounds
        editor.view.autoresizingMask = [.width, .height]
        container.addSubview(editor.view)
        settle()
    }

    override func tearDown() async throws {
        await MainActor.run { try? FileManager.default.removeItem(at: self.tempFile) }
    }

    private func settle() {
        container.layoutSubtreeIfNeeded()
        editor._textView!.enclosingScrollView!.tile()
        window.displayIfNeeded()
        editor._textView!.layoutManager!.ensureLayout(for: editor._textView!.textContainer!)
    }

    private func assertTextFitsVisibleWidth(file: StaticString = #filePath, line: UInt = #line) {
        let textView = editor._textView!
        let scrollView = textView.enclosingScrollView!
        let clip = scrollView.contentView
        let container = textView.textContainer!
        let usedWidth = textView.layoutManager!.usedRect(for: container).width

        XCTAssertEqual(clip.bounds.origin.x, 0, "editor scrolled sideways", file: file, line: line)
        XCTAssertEqual(textView.frame.width, clip.bounds.width, "text view wider than the visible area", file: file, line: line)
        XCTAssertEqual(container.containerSize.width,
                       clip.bounds.width - 2 * textView.textContainerInset.width,
                       "wrap width doesn't leave the configured padding", file: file, line: line)
        XCTAssertLessThanOrEqual(usedWidth + 2 * textView.textContainerInset.width, clip.bounds.width,
                                 "laid-out text is wider than the visible area", file: file, line: line)
        XCTAssertFalse(scrollView.hasHorizontalScroller, file: file, line: line)
    }

    func testTextFitsAfterFirstLayout() {
        assertTextFitsVisibleWidth()
    }

    /// The gutter must not cover the text. On macOS 26 an NSScrollView ruler is
    /// drawn over the clip view instead of beside it, so the gutter is laid out
    /// as a sibling and the scroll view starts where it ends.
    func testGutterSitsBesideTheTextNotOverIt() {
        let scrollView = editor._textView!.enclosingScrollView!
        let gutter = editor.view.subviews.first { $0 is LineNumberRulerView }!
        XCTAssertEqual(gutter.frame.minX, 0)
        XCTAssertEqual(gutter.frame.width, 50)
        XCTAssertEqual(scrollView.frame.minX, gutter.frame.maxX)
        XCTAssertEqual(scrollView.frame.maxX, editor.view.bounds.maxX)
        XCTAssertFalse(scrollView.frame.intersects(gutter.frame))
        XCTAssertNil(scrollView.verticalRulerView)

        // The first glyph is drawn right of the gutter, inset by the padding.
        let textView = editor._textView!
        let firstGlyph = textView.layoutManager!.boundingRect(forGlyphRange: NSRange(location: 0, length: 1),
                                                              in: textView.textContainer!)
        let inWindow = textView.convert(firstGlyph.offsetBy(dx: textView.textContainerOrigin.x,
                                                             dy: textView.textContainerOrigin.y), to: nil)
        XCTAssertGreaterThanOrEqual(inWindow.minX, gutter.frame.maxX + textView.textContainerInset.width)
    }

    func testTextFitsAfterShrinkingLikeAPaneSplit() {
        container.setFrameSize(NSSize(width: 500, height: 600))
        settle()
        assertTextFitsVisibleWidth()

        container.setFrameSize(NSSize(width: 1100, height: 600))
        settle()
        assertTextFitsVisibleWidth()
    }

    func testTextFitsAfterRefreshLayoutOnTabShow() {
        container.setFrameSize(NSSize(width: 640, height: 600))
        editor.refreshLayout()
        settle()
        assertTextFitsVisibleWidth()
    }

    func testSidewaysScrollIsPinnedToZero() {
        let clip = editor._textView!.enclosingScrollView!.contentView
        clip.scroll(to: NSPoint(x: 50, y: clip.bounds.origin.y))
        XCTAssertEqual(clip.bounds.origin.x, 0)
        clip.scroll(to: NSPoint(x: -35, y: clip.bounds.origin.y))
        XCTAssertEqual(clip.bounds.origin.x, 0)
        assertTextFitsVisibleWidth()
    }

    func testFontChangeKeepsTextFitting() {
        var config = Config.load()
        var editorConfig = config.editor ?? EditorConfig()
        editorConfig.fontSize = editorConfig.fontSize + 6
        config.editor = editorConfig
        editor.applyConfig(config)
        settle()
        assertTextFitsVisibleWidth()
    }
}
