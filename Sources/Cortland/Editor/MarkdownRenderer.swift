import Cocoa

/// Turns Markdown source into the styled attributed string the editor's read
/// mode shows. Parsing is Foundation's own (`AttributedString(markdown:)` with
/// full block syntax), which hands back one run per styled span tagged with
/// the block it sits in (heading, paragraph, list item, code block, quote,
/// table cell) but with no paragraph breaks and no visual styling at all.
/// This walks those runs, reinserts the breaks, and maps each block and inline
/// intent onto fonts, colors, indents, and spacing. No web view, no new
/// dependency, and the result is a plain NSTextView document, so selection,
/// find, and copy all work the way they do in the editor.
///
/// Scope is deliberately a reader, not a Markdown engine: tables render as
/// monospaced rows rather than laid-out grids, raw HTML shows as code, and
/// task-list boxes stay as their `[ ]` text.
nonisolated struct MarkdownRenderer {
    /// The fonts and colors a render uses. Built from the live theme by
    /// `Style.current`, but passed in explicitly so tests can render without
    /// a theme and the controller can re-render on a theme change.
    struct Style {
        var bodyFont: NSFont
        var codeFont: NSFont
        var textColor: NSColor
        var secondaryColor: NSColor
        var mutedColor: NSColor
        var linkColor: NSColor
        var codeBackground: NSColor

        /// A style on the current theme. `bodySize` is the reading size; code
        /// uses `codeFont` (the editor's monospaced font) a point smaller so it
        /// sits inside prose without jumping out.
        @MainActor
        static func current(bodySize: CGFloat, codeFont: NSFont) -> Style {
            Style(
                bodyFont: NSFont.systemFont(ofSize: bodySize),
                codeFont: NSFont(descriptor: codeFont.fontDescriptor, size: max(bodySize - 1, 9)) ?? codeFont,
                textColor: AppTheme.primaryText,
                secondaryColor: AppTheme.secondaryText,
                mutedColor: AppTheme.mutedText,
                linkColor: AppTheme.accent,
                codeBackground: AppTheme.buttonBackground.withAlphaComponent(0.6)
            )
        }
    }

    /// Attribute carrying the full-width fill behind code blocks. Same key the
    /// diff views use, so `DiffLineBackgroundLayoutManager` draws it unchanged.
    static var lineFillColor: NSAttributedString.Key { InlineDiffRenderer.lineFillColor }

    /// Heading scale per level, applied to the body size.
    private static let headingScale: [Int: CGFloat] = [1: 1.9, 2: 1.5, 3: 1.25, 4: 1.1, 5: 1.0, 6: 1.0]

    /// Renders `markdown` for reading. `baseURL` is the directory the file
    /// lives in: relative links and image paths resolve against it, so a click
    /// on `[notes](daily/today.md)` can open the neighbouring file and
    /// `![](img/a.png)` shows the picture.
    static func render(_ markdown: String, baseURL: URL?, style: Style) -> NSAttributedString {
        let (frontMatter, body) = splitFrontMatter(markdown)
        let source = expandWikilinks(body)
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        options.failurePolicy = .returnPartiallyParsedIfPossible
        let parsed: AttributedString
        do {
            parsed = try AttributedString(markdown: source, options: options, baseURL: baseURL)
        } catch {
            // The partial-parse policy means this is a genuinely broken
            // document; show the raw text rather than nothing.
            return NSAttributedString(string: markdown, attributes: [
                .font: style.bodyFont, .foregroundColor: style.textColor
            ])
        }

        var builder = Builder(style: style, baseURL: baseURL)
        if let frontMatter {
            builder.appendFrontMatter(frontMatter)
        }
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            builder.append(
                text: text,
                block: run.presentationIntent,
                inline: run.inlinePresentationIntent ?? [],
                link: run.link,
                image: run.imageURL
            )
        }
        return builder.finish()
    }

    /// Splits a leading YAML front matter block (`---` fences on their own
    /// lines, `...` accepted as the closer) off the document. Without this the
    /// closing `---` reads as a setext underline and the whole block becomes
    /// one giant heading. Returns the block's inner lines and the rest.
    static func splitFrontMatter(_ markdown: String) -> (frontMatter: String?, body: String) {
        let lines = markdown.components(separatedBy: "\n")
        guard lines.count >= 2, lines[0].trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            return (nil, markdown)
        }
        for index in 1..<lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if line == "---" || line == "..." {
                let inner = lines[1..<index].joined(separator: "\n")
                let rest = lines[(index + 1)...].joined(separator: "\n")
                return (inner.isEmpty ? nil : inner, rest)
            }
        }
        return (nil, markdown)
    }

    /// Rewrites `[[Note Name]]` and `[[Note Name|label]]` into ordinary links
    /// to `Note Name.md`, so a vault that cross-links the Obsidian way reads
    /// and clicks through here. Only outside fenced code blocks: a wikilink
    /// quoted in a code sample stays as typed. A `#heading` suffix is dropped
    /// (there is nothing to scroll to yet) and a target that already names an
    /// extension keeps it.
    static func expandWikilinks(_ markdown: String) -> String {
        guard markdown.contains("[[") else { return markdown }
        let pattern = #"\[\[([^\]\|#]+)(?:#[^\]\|]*)?(?:\|([^\]]+))?\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return markdown }

        var output: [String] = []
        var inFence = false
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                output.append(line)
                continue
            }
            guard !inFence else {
                output.append(line)
                continue
            }
            let ns = line as NSString
            var rewritten = ""
            var cursor = 0
            for match in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                rewritten += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                let target = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let label = match.range(at: 2).location == NSNotFound
                    ? target
                    : ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
                let file = (target as NSString).pathExtension.isEmpty ? target + ".md" : target
                let encoded = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file
                rewritten += "[\(label)](\(encoded))"
                cursor = NSMaxRange(match.range)
            }
            rewritten += ns.substring(from: cursor)
            output.append(rewritten)
        }
        return output.joined(separator: "\n")
    }

    // MARK: - Builder

    /// Accumulates runs into the output, inserting a paragraph break whenever
    /// the run belongs to a different leaf block than the one before it, and
    /// prefixing list items and table cells. Leaf blocks are the innermost
    /// block intents (paragraph, header, code block, table cell, rule); the
    /// enclosing list / quote / table intents only shape the paragraph style.
    private struct Builder {
        let style: Style
        let baseURL: URL?
        private let output = NSMutableAttributedString()
        private var lastLeafIdentity: Int?
        private var lastRowIdentity: Int?
        private var lastRowWasHeader = false
        private var seenListItems = Set<Int>()
        /// Paragraph style of the block being written; the break that ends it
        /// takes this style so spacing attaches to the right paragraph.
        private var currentParagraph = NSParagraphStyle.default

        init(style: Style, baseURL: URL?) {
            self.style = style
            self.baseURL = baseURL
        }

        /// Front matter as a dimmed, small monospaced block at the top: the
        /// metadata is there if you look, and out of the way if you don't.
        mutating func appendFrontMatter(_ text: String) {
            let size = max(style.codeFont.pointSize - 2, 9)
            let font = NSFont(descriptor: style.codeFont.fontDescriptor, size: size) ?? style.codeFont
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 2
            paragraph.paragraphSpacing = (style.bodyFont.pointSize * 0.8).rounded()
            paragraph.firstLineHeadIndent = 10
            paragraph.headIndent = 10
            output.append(NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: style.mutedColor,
                .paragraphStyle: paragraph,
                MarkdownRenderer.lineFillColor: style.codeBackground
            ]))
            currentParagraph = paragraph
            // A fresh leaf identity so the first body block starts a new paragraph.
            lastLeafIdentity = -1
        }

        mutating func append(text: String, block: PresentationIntent?, inline: InlinePresentationIntent, link: URL?, image: URL?) {
            // HTML comments are notes to tools and editors, not to readers.
            // (The parser may have smartened the dashes, so match on `<!`.)
            if inline.contains(.blockHTML) || inline.contains(.inlineHTML) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("<!") && trimmed.hasSuffix(">") { return }
            }

            let shape = BlockShape(block)

            if shape.leafIdentity != lastLeafIdentity {
                beginBlock(shape)
            }

            if shape.isThematicBreak {
                // The rule has no text of its own; draw one and ignore the run.
                return
            }

            var attributes = baseAttributes(for: shape)
            var content = text

            if inline.contains(.softBreak) {
                content = " "
            } else if inline.contains(.lineBreak) {
                content = "\n"
            }

            if shape.isCodeBlock {
                // The parser keeps the fence's trailing newline; the paragraph
                // break we add already separates the block from what follows.
                if content.hasSuffix("\n") { content.removeLast() }
            } else {
                let bold = inline.contains(.stronglyEmphasized)
                let italic = inline.contains(.emphasized)
                if inline.contains(.code) || inline.contains(.inlineHTML) || inline.contains(.blockHTML) {
                    attributes[.font] = MarkdownRenderer.font(style.codeFont, bold: bold, italic: italic)
                    attributes[.backgroundColor] = style.codeBackground
                } else if bold || italic {
                    attributes[.font] = MarkdownRenderer.font(attributes[.font] as? NSFont ?? style.bodyFont, bold: bold, italic: italic)
                }
                if inline.contains(.strikethrough) {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
            }

            if let link {
                attributes[.link] = link
                attributes[.foregroundColor] = style.linkColor
            }

            if let image, let attachment = MarkdownRenderer.attachment(for: image) {
                output.append(NSAttributedString(attachment: attachment))
                return
            } else if image != nil {
                // Image missing or unreadable: the alt text stands in, dimmed.
                attributes[.foregroundColor] = style.mutedColor
                attributes[.font] = MarkdownRenderer.font(style.bodyFont, bold: false, italic: true)
            }

            output.append(NSAttributedString(string: content, attributes: attributes))
        }

        func finish() -> NSAttributedString {
            output
        }

        /// Starts a new leaf block: a paragraph break after the previous one
        /// (or a cell separator inside a table row), then any list marker.
        private mutating func beginBlock(_ shape: BlockShape) {
            if let row = shape.tableRowIdentity, row == lastRowIdentity {
                output.append(NSAttributedString(string: "  │  ", attributes: [
                    .font: style.codeFont, .foregroundColor: style.mutedColor, .paragraphStyle: currentParagraph
                ]))
            } else if output.length > 0 {
                output.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: currentParagraph]))
                if shape.tableRowIdentity != nil, lastRowWasHeader {
                    output.append(NSAttributedString(string: String(repeating: "─", count: 40) + "\n", attributes: [
                        .font: style.codeFont, .foregroundColor: style.mutedColor, .paragraphStyle: tableParagraph()
                    ]))
                }
            }

            lastLeafIdentity = shape.leafIdentity
            if let row = shape.tableRowIdentity {
                lastRowWasHeader = shape.isTableHeaderRow
                lastRowIdentity = row
            } else {
                lastRowIdentity = nil
                lastRowWasHeader = false
            }
            currentParagraph = paragraphStyle(for: shape)

            if shape.isThematicBreak {
                output.append(NSAttributedString(string: String(repeating: "─", count: 24), attributes: [
                    .font: style.bodyFont, .foregroundColor: style.mutedColor, .paragraphStyle: currentParagraph
                ]))
                return
            }

            if let item = shape.listItem, !seenListItems.contains(item.identity) {
                seenListItems.insert(item.identity)
                let marker = shape.listIsOrdered ? "\(item.ordinal)." : "•"
                output.append(NSAttributedString(string: marker + "\t", attributes: [
                    .font: style.bodyFont, .foregroundColor: style.secondaryColor, .paragraphStyle: currentParagraph
                ]))
            }
        }

        private func baseAttributes(for shape: BlockShape) -> [NSAttributedString.Key: Any] {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: style.bodyFont,
                .foregroundColor: style.textColor,
                .paragraphStyle: currentParagraph
            ]
            if let level = shape.headerLevel {
                let scale = MarkdownRenderer.headingScale[level] ?? 1.0
                let size = (style.bodyFont.pointSize * scale).rounded()
                attributes[.font] = MarkdownRenderer.font(NSFont.systemFont(ofSize: size), bold: true, italic: false)
                if level >= 6 { attributes[.foregroundColor] = style.secondaryColor }
            } else if shape.isCodeBlock {
                attributes[.font] = style.codeFont
                attributes[MarkdownRenderer.lineFillColor] = style.codeBackground
            } else if shape.tableRowIdentity != nil {
                attributes[.font] = MarkdownRenderer.font(style.codeFont, bold: shape.isTableHeaderRow, italic: false)
            } else if shape.quoteDepth > 0 {
                attributes[.foregroundColor] = style.secondaryColor
            }
            return attributes
        }

        private func paragraphStyle(for shape: BlockShape) -> NSParagraphStyle {
            let size = style.bodyFont.pointSize
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = (size * 0.3).rounded()
            paragraph.paragraphSpacing = (size * 0.8).rounded()

            if let level = shape.headerLevel {
                paragraph.paragraphSpacingBefore = (size * (level == 1 ? 1.2 : 0.9)).rounded()
                paragraph.paragraphSpacing = (size * 0.4).rounded()
                paragraph.lineSpacing = (size * 0.15).rounded()
            }

            var indent: CGFloat = 0
            if shape.quoteDepth > 0 {
                indent += CGFloat(shape.quoteDepth) * (size * 1.4).rounded()
            }
            if shape.listDepth > 0 {
                let markerWidth = (size * 1.6).rounded()
                indent += CGFloat(shape.listDepth - 1) * markerWidth
                paragraph.firstLineHeadIndent = indent
                paragraph.headIndent = indent + markerWidth
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent + markerWidth)]
                paragraph.paragraphSpacing = (size * 0.3).rounded()
            } else {
                paragraph.firstLineHeadIndent = indent
                paragraph.headIndent = indent
            }

            if shape.isCodeBlock {
                paragraph.lineSpacing = (size * 0.15).rounded()
                paragraph.paragraphSpacingBefore = (size * 0.4).rounded()
                paragraph.firstLineHeadIndent = indent + 10
                paragraph.headIndent = indent + 10
            }
            if shape.tableRowIdentity != nil {
                return tableParagraph()
            }
            return paragraph
        }

        private func tableParagraph() -> NSParagraphStyle {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = (style.bodyFont.pointSize * 0.15).rounded()
            paragraph.paragraphSpacing = 2
            paragraph.lineBreakMode = .byTruncatingTail
            return paragraph
        }
    }

    /// What a run's block intent says about where it sits: the leaf block it
    /// belongs to and the lists, quotes, and table that enclose it.
    private struct BlockShape {
        var leafIdentity: Int?
        var headerLevel: Int?
        var isCodeBlock = false
        var isThematicBreak = false
        var listDepth = 0
        var listIsOrdered = false
        var listItem: (identity: Int, ordinal: Int)?
        var quoteDepth = 0
        var tableRowIdentity: Int?
        var isTableHeaderRow = false

        init(_ intent: PresentationIntent?) {
            guard let intent else { return }
            // Identities grow as the parser descends, so among nested lists or
            // items the largest identity is the innermost one.
            var innermostList: (identity: Int, ordered: Bool)?
            var innermostItem: (identity: Int, ordinal: Int)?
            for component in intent.components {
                switch component.kind {
                case .paragraph, .codeBlock, .header, .thematicBreak, .tableCell:
                    leafIdentity = component.identity
                default:
                    break
                }
                switch component.kind {
                case .header(let level):
                    headerLevel = level
                case .codeBlock:
                    isCodeBlock = true
                case .thematicBreak:
                    isThematicBreak = true
                case .orderedList:
                    listDepth += 1
                    if innermostList == nil || component.identity > innermostList!.identity {
                        innermostList = (component.identity, true)
                    }
                case .unorderedList:
                    listDepth += 1
                    if innermostList == nil || component.identity > innermostList!.identity {
                        innermostList = (component.identity, false)
                    }
                case .listItem(let ordinal):
                    if innermostItem == nil || component.identity > innermostItem!.identity {
                        innermostItem = (component.identity, ordinal)
                    }
                case .blockQuote:
                    quoteDepth += 1
                case .tableHeaderRow:
                    tableRowIdentity = component.identity
                    isTableHeaderRow = true
                case .tableRow:
                    tableRowIdentity = component.identity
                default:
                    break
                }
            }
            listIsOrdered = innermostList?.ordered ?? false
            listItem = innermostItem
        }
    }

    // MARK: - Helpers

    /// `base` with bold and/or italic added, falling back to `base` when the
    /// face has no such variant.
    static func font(_ base: NSFont, bold: Bool, italic: Bool) -> NSFont {
        var traits = base.fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        guard traits != base.fontDescriptor.symbolicTraits else { return base }
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
    }

    /// Largest an inline image is drawn, in points; bigger images scale down
    /// to fit the reading column.
    static let maxImageSize = NSSize(width: 640, height: 480)

    /// An attachment showing the image at `url`, scaled to `maxImageSize`, or
    /// nil when it is not a readable local image.
    static func attachment(for url: URL) -> NSTextAttachment? {
        guard url.isFileURL, let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else {
            return nil
        }
        let scale = min(1, maxImageSize.width / image.size.width, maxImageSize.height / image.size.height)
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
        return attachment
    }

    /// File extensions read mode applies to.
    static func isMarkdown(extension ext: String) -> Bool {
        ["md", "markdown", "mdx"].contains(ext.lowercased())
    }
}
