import XCTest
@testable import Cortland

/// The read-mode renderer: block structure comes back as paragraphs with the
/// right fonts and markers, inline spans keep their traits, links resolve
/// against the file's directory, and wikilinks become ordinary links.
final class MarkdownRendererTests: XCTestCase {
    private let style = MarkdownRenderer.Style(
        bodyFont: NSFont.systemFont(ofSize: 15),
        codeFont: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
        textColor: .black,
        secondaryColor: .darkGray,
        mutedColor: .gray,
        linkColor: .blue,
        codeBackground: .lightGray
    )

    private func render(_ markdown: String, baseURL: URL? = nil) -> NSAttributedString {
        MarkdownRenderer.render(markdown, baseURL: baseURL, style: style)
    }

    private func font(at offset: Int, in rendered: NSAttributedString) -> NSFont? {
        rendered.attribute(.font, at: offset, effectiveRange: nil) as? NSFont
    }

    // MARK: - Blocks

    func testHeadingIsLargerAndBoldAndParagraphsAreSeparated() throws {
        let rendered = render("# Title\n\nFirst paragraph.\n\nSecond paragraph.")
        let text = rendered.string
        XCTAssertEqual(text, "Title\nFirst paragraph.\nSecond paragraph.")

        let heading = try XCTUnwrap(font(at: 0, in: rendered))
        let body = try XCTUnwrap(font(at: text.distance(from: text.startIndex, to: text.range(of: "First")!.lowerBound), in: rendered))
        XCTAssertGreaterThan(heading.pointSize, body.pointSize)
        XCTAssertTrue(heading.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertFalse(body.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testListItemsGetMarkersAndOrderedListsCount() {
        let unordered = render("- apple\n- pear").string
        XCTAssertEqual(unordered, "•\tapple\n•\tpear")

        let ordered = render("1. one\n2. two").string
        XCTAssertEqual(ordered, "1.\tone\n2.\ttwo")
    }

    func testCodeBlockUsesCodeFontAndFullWidthFill() throws {
        let rendered = render("Before\n\n```swift\nlet x = 1\n```\n\nAfter")
        let text = rendered.string
        XCTAssertEqual(text, "Before\nlet x = 1\nAfter")
        let codeOffset = (text as NSString).range(of: "let x").location
        let codeFont = try XCTUnwrap(font(at: codeOffset, in: rendered))
        XCTAssertEqual(codeFont.fontName, style.codeFont.fontName)
        XCTAssertNotNil(rendered.attribute(MarkdownRenderer.lineFillColor, at: codeOffset, effectiveRange: nil))
        // The prose around it carries no fill.
        XCTAssertNil(rendered.attribute(MarkdownRenderer.lineFillColor, at: 0, effectiveRange: nil))
    }

    func testBlockQuoteIsIndentedAndDimmed() throws {
        let rendered = render("> quoted words")
        let paragraph = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertGreaterThan(paragraph.headIndent, 0)
        let color = rendered.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, style.secondaryColor)
    }

    func testTableRowsRenderAsSeparatedCells() {
        let rendered = render("| a | b |\n|---|---|\n| 1 | 2 |").string
        XCTAssertTrue(rendered.contains("a  │  b"), rendered)
        XCTAssertTrue(rendered.contains("1  │  2"), rendered)
    }

    // MARK: - Inline

    func testBoldItalicAndInlineCodeKeepTheirTraits() throws {
        let rendered = render("plain **bold** *italic* `code`")
        let text = rendered.string as NSString
        XCTAssertEqual(text as String, "plain bold italic code")

        let bold = try XCTUnwrap(font(at: text.range(of: "bold").location, in: rendered))
        XCTAssertTrue(bold.fontDescriptor.symbolicTraits.contains(.bold))
        let italic = try XCTUnwrap(font(at: text.range(of: "italic").location, in: rendered))
        XCTAssertTrue(italic.fontDescriptor.symbolicTraits.contains(.italic))
        let code = try XCTUnwrap(font(at: text.range(of: "code").location, in: rendered))
        XCTAssertEqual(code.fontName, style.codeFont.fontName)
        XCTAssertNotNil(rendered.attribute(.backgroundColor, at: text.range(of: "code").location, effectiveRange: nil))
    }

    func testRelativeLinkResolvesAgainstBaseURL() {
        let base = URL(fileURLWithPath: "/tmp/vault/", isDirectory: true)
        let rendered = render("see [notes](daily/today.md)", baseURL: base)
        let text = rendered.string as NSString
        let link = rendered.attribute(.link, at: text.range(of: "notes").location, effectiveRange: nil) as? URL
        XCTAssertEqual(link?.path, "/tmp/vault/daily/today.md")
    }

    func testMissingImageFallsBackToAltText() {
        let rendered = render("![a diagram](nope.png)", baseURL: URL(fileURLWithPath: "/tmp/", isDirectory: true))
        XCTAssertEqual(rendered.string, "a diagram")
    }

    // MARK: - Front matter and comments

    func testFrontMatterIsSplitOffAndShownSmall() throws {
        let source = "---\ntitle: \"Book\"\nsynced: 2026-11-03\n---\n\n# Book\n\nText."
        let split = MarkdownRenderer.splitFrontMatter(source)
        XCTAssertEqual(split.frontMatter, "title: \"Book\"\nsynced: 2026-11-03")
        XCTAssertEqual(split.body, "\n# Book\n\nText.")

        let rendered = render(source)
        let text = rendered.string
        XCTAssertEqual(text, "title: \"Book\"\nsynced: 2026-11-03\nBook\nText.")
        // The metadata is small and dimmed; the real heading is still the big one.
        let meta = try XCTUnwrap(font(at: 0, in: rendered))
        let heading = try XCTUnwrap(font(at: (text as NSString).range(of: "Book\nText").location, in: rendered))
        XCTAssertLessThan(meta.pointSize, style.bodyFont.pointSize)
        XCTAssertGreaterThan(heading.pointSize, style.bodyFont.pointSize)
        XCTAssertEqual(rendered.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, style.mutedColor)
    }

    func testNoFrontMatterWithoutAClosingFence() {
        XCTAssertNil(MarkdownRenderer.splitFrontMatter("---\nnot closed\n\n# Heading").frontMatter)
        XCTAssertNil(MarkdownRenderer.splitFrontMatter("# Heading\n\n---\n").frontMatter)
    }

    func testHTMLCommentsAreHidden() {
        let rendered = render("## My notes\n\n<!-- sync never touches this -->\n\n<!-- rw-id:1 -->\n\n> A highlight\n\nAfter")
        XCTAssertEqual(rendered.string, "My notes\nA highlight\nAfter")
    }

    // MARK: - Wikilinks

    func testWikilinksBecomeMarkdownLinks() {
        XCTAssertEqual(MarkdownRenderer.expandWikilinks("see [[Daily Note]]"), "see [Daily Note](Daily%20Note.md)")
        XCTAssertEqual(MarkdownRenderer.expandWikilinks("[[Note|the label]]"), "[the label](Note.md)")
        XCTAssertEqual(MarkdownRenderer.expandWikilinks("[[Note#Heading]]"), "[Note](Note.md)")
        XCTAssertEqual(MarkdownRenderer.expandWikilinks("[[img.png]]"), "[img.png](img.png)")
    }

    func testWikilinksInsideFencesAreLeftAlone() {
        let source = "```\n[[not a link]]\n```\n[[real]]"
        XCTAssertEqual(MarkdownRenderer.expandWikilinks(source), "```\n[[not a link]]\n```\n[real](real.md)")
    }

    func testWikilinkRendersAsClickableLink() {
        let base = URL(fileURLWithPath: "/tmp/vault/", isDirectory: true)
        let rendered = render("[[Daily Note]]", baseURL: base)
        XCTAssertEqual(rendered.string, "Daily Note")
        let link = rendered.attribute(.link, at: 0, effectiveRange: nil) as? URL
        XCTAssertEqual(link?.path, "/tmp/vault/Daily Note.md")
    }

    func testMarkdownExtensions() {
        XCTAssertTrue(MarkdownRenderer.isMarkdown(extension: "md"))
        XCTAssertTrue(MarkdownRenderer.isMarkdown(extension: "Markdown"))
        XCTAssertFalse(MarkdownRenderer.isMarkdown(extension: "swift"))
    }
}
