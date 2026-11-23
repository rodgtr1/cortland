import Cocoa

/// Paints a full-width background behind any line carrying the
/// `InlineDiffRenderer.lineFillColor` attribute, so added/removed lines read as
/// solid Zed-style bars even when the line is empty (a blank-line deletion).
/// `NSAttributedString`'s own `.backgroundColor` only paints behind glyphs, so
/// an empty removed line would otherwise be invisible.
///
/// Lines carrying `InlineDiffRenderer.gutterLine` also get a drawn gutter in
/// their paragraph indent: a coloured bar at the left edge for added/removed
/// lines, the new-file line number, and a `+`/`-` marker. The gutter is never
/// part of the text, so selecting and copying yields only code.
// NSLayoutManager is nonisolated in the SDK, so this subclass opts out of the
// module's default main-actor isolation to match its overridden declarations.
// Layout/drawing is still driven on the main thread by the text system.
nonisolated final class DiffLineBackgroundLayoutManager: NSLayoutManager {
    /// Horizontal positions inside the gutter, measured from the start of the
    /// line's text area (after the container's line fragment padding).
    struct GutterMetrics {
        let barWidth: CGFloat
        /// Right edge of the right-aligned line number.
        let numberRight: CGFloat
        let markerX: CGFloat
        /// Total indent the code text starts after.
        let width: CGFloat
    }

    static func gutterMetrics(for font: NSFont) -> GutterMetrics {
        let charWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        let numberRight = 4 + charWidth * 5
        let markerX = numberRight + charWidth * 0.75
        return GutterMetrics(
            barWidth: 3,
            numberRight: numberRight,
            markerX: markerX,
            width: markerX + charWidth * 2
        )
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let storage = textStorage {
            let text = storage.string as NSString
            enumerateLineFragments(forGlyphRange: glyphsToShow) { [weak self] rect, _, container, glyphRange, _ in
                guard let self = self else { return }
                let charRange = self.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
                guard charRange.length > 0, charRange.location < storage.length else { return }

                if let color = storage.attribute(
                    InlineDiffRenderer.lineFillColor,
                    at: charRange.location,
                    effectiveRange: nil
                ) as? NSColor {
                    color.setFill()
                    let fillRect = NSRect(
                        x: origin.x,
                        y: origin.y + rect.minY,
                        width: container.size.width,
                        height: rect.height
                    )
                    NSBezierPath(rect: fillRect).fill()
                }

                if let line = storage.attribute(
                    InlineDiffRenderer.gutterLine,
                    at: charRange.location,
                    effectiveRange: nil
                ) as? DiffGutterLine {
                    // Number and marker only on a line's first fragment; a
                    // soft-wrapped continuation shows just the bar.
                    let isFirstFragment = charRange.location == 0
                        || text.character(at: charRange.location - 1) == 0x0A
                    self.drawGutter(
                        line,
                        font: storage.attribute(.font, at: charRange.location, effectiveRange: nil) as? NSFont,
                        lineRect: rect,
                        firstGlyph: glyphRange.location,
                        drawLabels: isFirstFragment,
                        padding: container.lineFragmentPadding,
                        origin: origin
                    )
                }
            }
        }
        // Draw glyph-level backgrounds (intraline emphasis) on top of the fill.
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    private func drawGutter(
        _ line: DiffGutterLine,
        font: NSFont?,
        lineRect rect: NSRect,
        firstGlyph: Int,
        drawLabels: Bool,
        padding: CGFloat,
        origin: NSPoint
    ) {
        guard let font else { return }
        let metrics = Self.gutterMetrics(for: font)

        if let markColor = line.markColor {
            markColor.setFill()
            NSBezierPath(rect: NSRect(
                x: origin.x + rect.minX,
                y: origin.y + rect.minY,
                width: metrics.barWidth,
                height: rect.height
            )).fill()
        }

        guard drawLabels else { return }
        let textX = origin.x + rect.minX + padding
        // Align the labels with the line's code baseline.
        let baseline = location(forGlyphAt: firstGlyph).y
        let top = origin.y + rect.minY + baseline - font.ascender

        if let number = line.number {
            let label = "\(number)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: line.numberColor]
            let width = label.size(withAttributes: attributes).width
            label.draw(at: NSPoint(x: textX + metrics.numberRight - width, y: top), withAttributes: attributes)
        }

        let marker: NSString?
        switch line.kind {
        case .added: marker = "+"
        case .removed: marker = "-"
        case .context: marker = nil
        }
        if let marker, let markColor = line.markColor {
            marker.draw(
                at: NSPoint(x: textX + metrics.markerX, y: top),
                withAttributes: [.font: font, .foregroundColor: markColor]
            )
        }
    }
}

/// Per-line gutter metadata attached to each rendered diff line under
/// `InlineDiffRenderer.gutterLine`. Colours are resolved at render time from
/// the theme, the same way `lineFillColor` is.
nonisolated final class DiffGutterLine: NSObject {
    enum Kind: String {
        case context, added, removed
    }

    /// New-file line number; nil for removed lines.
    let number: Int?
    let kind: Kind
    /// Bar and marker colour; nil for context lines.
    let markColor: NSColor?
    let numberColor: NSColor

    init(number: Int?, kind: Kind, markColor: NSColor?, numberColor: NSColor) {
        self.number = number
        self.kind = kind
        self.markColor = markColor
        self.numberColor = numberColor
    }
}

/// Renders unified git diff text as a Zed-style inline diff:
/// - file metadata (diff --git, index, ---, +++) is hidden
/// - each hunk boundary shows git's enclosing function/section text, or a
///   quiet separator between hunks when there is none
/// - the string holds only code; line numbers, `+`/`-` markers and the
///   added/removed bar are drawn in the paragraph indent by
///   `DiffLineBackgroundLayoutManager` from the `gutterLine` attribute
/// - removed lines sit directly above their replacements with a light red
///   background and no line number
/// - added lines carry the new file's line number on a light green background
/// - for paired removed/added lines, the changed character range is
///   emphasized with a stronger red/green
enum InlineDiffRenderer {
    /// The default code font, for callers that do not pass their own.
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    /// Whole-line background, painted full-width by
    /// `DiffLineBackgroundLayoutManager` (use this for added/removed/conflict
    /// lines; reserve `.backgroundColor` for intraline emphasis only).
    nonisolated static let lineFillColor = NSAttributedString.Key("InlineDiffLineFillColor")

    /// Per-line `DiffGutterLine` (number, kind, colours) the layout manager
    /// draws the gutter from.
    nonisolated static let gutterLine = NSAttributedString.Key("InlineDiffGutterLine")

    private static var textColor: NSColor { AppTheme.primaryText }
    private static var gutterColor: NSColor { AppTheme.mutedText }
    private static var separatorColor: NSColor { Theme.shared.palette.surface1 }
    private static var removedLineBG: NSColor { AppTheme.error.withAlphaComponent(0.12) }
    private static var removedEmphasisBG: NSColor { AppTheme.error.withAlphaComponent(0.30) }
    private static var addedLineBG: NSColor { AppTheme.success.withAlphaComponent(0.12) }
    private static var addedEmphasisBG: NSColor { AppTheme.success.withAlphaComponent(0.30) }
    private static var conflictMarkerText: NSColor { AppTheme.warning }
    private static var conflictMarkerBG: NSColor { AppTheme.warning.withAlphaComponent(0.15) }
    private static var conflictOursBG: NSColor { Theme.shared.palette.teal.withAlphaComponent(0.12) }
    private static var conflictBaseBG: NSColor { AppTheme.mutedText.withAlphaComponent(0.12) }
    private static var conflictTheirsBG: NSColor { AppTheme.accent.withAlphaComponent(0.12) }

    private enum ConflictSection {
        case none, ours, base, theirs
    }

    /// The code font and the hanging indent the gutter is drawn in, sized
    /// from that font; wrapped lines continue at the same indent, clear of
    /// the numbers.
    private struct LineStyle {
        let font: NSFont
        let paragraph: NSParagraphStyle

        init(font: NSFont) {
            self.font = font
            let style = NSMutableParagraphStyle()
            let width = DiffLineBackgroundLayoutManager.gutterMetrics(for: font).width
            style.firstLineHeadIndent = width
            style.headIndent = width
            paragraph = style
        }
    }

    /// `fileExtension` (lowercased, no dot) drives syntax highlighting of the
    /// diff content; pass "" to render plain (e.g. when the language is
    /// unknown). `font` is the code font; the gutter is sized from it.
    static func render(_ diff: String, fileExtension: String = "", font: NSFont = InlineDiffRenderer.font) -> NSAttributedString {
        render(diff, fileExtension: fileExtension, font: font, lineLimit: nil).text
    }

    /// Renders only the first `lineLimit` rows (all of them when nil) and
    /// reports how many rows the whole diff has. Rows past the limit are
    /// counted, never built, so a huge diff costs a line walk, not a render.
    /// The rows that are built match the first rows of a full render.
    static func render(_ diff: String, fileExtension: String, font: NSFont, lineLimit: Int?) -> (text: NSAttributedString, lineCount: Int) {
        let style = LineStyle(font: font)
        let result = NSMutableAttributedString()
        var lines = diff.components(separatedBy: "\n")
        if lines.last == "" {
            lines.removeLast()
        }

        var newLineNumber = 0
        var insideHunk = false
        var renderedAnyHunk = false
        var conflictMode = false
        var conflictSection = ConflictSection.none
        var index = 0
        var lineCount = 0
        func fits() -> Bool { lineLimit.map { lineCount < $0 } ?? true }

        while index < lines.count {
            let line = lines[index]

            if line.hasPrefix("diff --git") {
                insideHunk = false
                conflictMode = false
                conflictSection = .none
                index += 1
                continue
            }

            if line.hasPrefix("@@") {
                newLineNumber = parseNewStart(line) ?? newLineNumber
                let headerText = hunkHeaderText(line)
                if !headerText.isEmpty {
                    if fits() { appendHunkHeader(headerText, style: style, to: result) }
                    lineCount += 1
                } else if renderedAnyHunk {
                    if fits() { appendSeparator(style: style, to: result) }
                    lineCount += 1
                }
                insideHunk = true
                renderedAnyHunk = true
                index += 1
                continue
            }

            if !insideHunk {
                // Everything between "diff --git" and the first @@ is
                // metadata; a bare "conflict" line (emitted by
                // GitService.conflictMarkerDiff) flags the file as unmerged.
                if line == "conflict" {
                    conflictMode = true
                }
                index += 1
                continue
            }

            if line.hasPrefix("-") {
                var removed: [String] = []
                while index < lines.count, lines[index].hasPrefix("-") {
                    removed.append(String(lines[index].dropFirst()))
                    index += 1
                }
                var added: [String] = []
                while index < lines.count, lines[index].hasPrefix("+") {
                    added.append(String(lines[index].dropFirst()))
                    index += 1
                }
                appendChangeBlock(removed: removed, added: added, newLineNumber: &newLineNumber, ext: fileExtension, style: style,
                                  rowLimit: lineLimit.map { max(0, $0 - lineCount) }, to: result)
                lineCount += removed.count + added.count
                continue
            }

            if line.hasPrefix("+") {
                var added: [String] = []
                while index < lines.count, lines[index].hasPrefix("+") {
                    added.append(String(lines[index].dropFirst()))
                    index += 1
                }
                appendChangeBlock(removed: [], added: added, newLineNumber: &newLineNumber, ext: fileExtension, style: style,
                                  rowLimit: lineLimit.map { max(0, $0 - lineCount) }, to: result)
                lineCount += added.count
                continue
            }

            if line.hasPrefix("\\") {
                // "\ No newline at end of file"
                index += 1
                continue
            }

            // Context line (leading space in unified format).
            if fits() {
                let content = line.hasPrefix(" ") ? String(line.dropFirst()) : line
                if conflictMode {
                    appendConflictLine(content, number: newLineNumber, section: &conflictSection, ext: fileExtension, style: style, to: result)
                } else {
                    appendLine(content, number: newLineNumber, kind: .context, lineBG: nil, emphasis: nil, emphasisBG: nil, ext: fileExtension, style: style, to: result)
                }
            }
            lineCount += 1
            newLineNumber += 1
            index += 1
        }

        if result.length == 0 {
            result.append(NSAttributedString(string: "No changes", attributes: [
                .font: font,
                .foregroundColor: gutterColor
            ]))
        }
        return (result, lineCount)
    }

    // MARK: - Blocks

    private static func appendChangeBlock(
        removed: [String],
        added: [String],
        newLineNumber: inout Int,
        ext: String,
        style: LineStyle,
        rowLimit: Int? = nil,
        to result: NSMutableAttributedString
    ) {
        let pairCount = min(removed.count, added.count)
        // Rows at or past `rowLimit` are skipped; line numbers still advance.
        func fits(_ row: Int) -> Bool { rowLimit.map { row < $0 } ?? true }

        // Removed lines first (the "before" block), with emphasis computed
        // against the paired replacement line.
        for (offset, removedLine) in removed.enumerated() where fits(offset) {
            var emphasis: NSRange?
            if offset < pairCount {
                emphasis = intralineDifference(removedLine, added[offset]).old
            }
            appendLine(removedLine, number: nil, kind: .removed, lineBG: removedLineBG, emphasis: emphasis, emphasisBG: removedEmphasisBG, ext: ext, style: style, to: result)
        }

        for (offset, addedLine) in added.enumerated() {
            guard fits(removed.count + offset) else {
                newLineNumber += 1
                continue
            }
            var emphasis: NSRange?
            if offset < pairCount {
                emphasis = intralineDifference(removed[offset], addedLine).new
            }
            appendLine(addedLine, number: newLineNumber, kind: .added, lineBG: addedLineBG, emphasis: emphasis, emphasisBG: addedEmphasisBG, ext: ext, style: style, to: result)
            newLineNumber += 1
        }
    }

    /// Renders one line of a conflicted file, highlighting the
    /// <<<<<<< / ||||||| / ======= / >>>>>>> markers and tinting the
    /// ours/base/theirs sections so the conflict reads at a glance.
    private static func appendConflictLine(
        _ content: String,
        number: Int,
        section: inout ConflictSection,
        ext: String,
        style: LineStyle,
        to result: NSMutableAttributedString
    ) {
        let isMarker: Bool
        if content.hasPrefix("<<<<<<<") {
            section = .ours
            isMarker = true
        } else if content.hasPrefix("|||||||"), section == .ours {
            section = .base
            isMarker = true
        } else if content.hasPrefix("======="), section == .ours || section == .base {
            section = .theirs
            isMarker = true
        } else if content.hasPrefix(">>>>>>>"), section == .theirs {
            section = .none
            isMarker = true
        } else {
            isMarker = false
        }

        if isMarker {
            appendLine(content, number: number, kind: .context, lineBG: conflictMarkerBG, emphasis: nil, emphasisBG: nil, ext: ext, style: style, to: result, foreground: conflictMarkerText)
            return
        }

        let sectionBG: NSColor?
        switch section {
        case .none: sectionBG = nil
        case .ours: sectionBG = conflictOursBG
        case .base: sectionBG = conflictBaseBG
        case .theirs: sectionBG = conflictTheirsBG
        }
        appendLine(content, number: number, kind: .context, lineBG: sectionBG, emphasis: nil, emphasisBG: nil, ext: ext, style: style, to: result)
    }

    /// Common-prefix/suffix character diff between a removed and added line,
    /// in UTF-16 units. Returns nil ranges when the lines are too different
    /// for an emphasized middle to be meaningful.
    static func intralineDifference(_ old: String, _ new: String) -> (old: NSRange?, new: NSRange?) {
        let oldChars = Array(old.utf16)
        let newChars = Array(new.utf16)
        guard !oldChars.isEmpty, !newChars.isEmpty else { return (nil, nil) }

        var prefix = 0
        let minCount = min(oldChars.count, newChars.count)
        while prefix < minCount && oldChars[prefix] == newChars[prefix] {
            prefix += 1
        }

        var suffix = 0
        while suffix < minCount - prefix
                && oldChars[oldChars.count - 1 - suffix] == newChars[newChars.count - 1 - suffix] {
            suffix += 1
        }

        let oldRange = NSRange(location: prefix, length: oldChars.count - prefix - suffix)
        let newRange = NSRange(location: prefix, length: newChars.count - prefix - suffix)

        // If most of the line changed, whole-line tinting reads better than
        // a giant emphasis blob.
        let longest = max(oldChars.count, newChars.count)
        if max(oldRange.length, newRange.length) > Int(Double(longest) * 0.7) {
            return (nil, nil)
        }

        return (
            oldRange.length > 0 ? oldRange : nil,
            newRange.length > 0 ? newRange : nil
        )
    }

    // MARK: - Line rendering

    private static func appendLine(
        _ content: String,
        number: Int?,
        kind: DiffGutterLine.Kind,
        lineBG: NSColor?,
        emphasis: NSRange?,
        emphasisBG: NSColor?,
        ext: String,
        style: LineStyle,
        to result: NSMutableAttributedString,
        foreground: NSColor? = nil
    ) {
        let markColor: NSColor?
        switch kind {
        case .added: markColor = AppTheme.success
        case .removed: markColor = AppTheme.error
        case .context: markColor = nil
        }

        let lineStart = result.length
        var attributes: [NSAttributedString.Key: Any] = [
            .font: style.font,
            .foregroundColor: foreground ?? textColor,
            .paragraphStyle: style.paragraph,
            InlineDiffRenderer.gutterLine: DiffGutterLine(
                number: number,
                kind: kind,
                markColor: markColor,
                numberColor: gutterColor
            )
        ]
        if let lineBG = lineBG {
            // Full-width fill (incl. empty lines), drawn by the custom layout
            // manager rather than the glyph-bound .backgroundColor.
            attributes[InlineDiffRenderer.lineFillColor] = lineBG
        }

        result.append(NSAttributedString(string: content + "\n", attributes: attributes))

        // Syntax-highlight the content (foreground only) so the add/remove
        // background bars stay intact. Skipped when the caller forces a
        // foreground (conflict markers) or the language is unknown.
        if foreground == nil, !ext.isEmpty {
            for token in SyntaxHighlighter.tokens(for: content, ext: ext) {
                let shifted = NSRange(location: lineStart + token.range.location, length: token.range.length)
                if shifted.location + shifted.length <= result.length {
                    result.addAttribute(.foregroundColor, value: token.color, range: shifted)
                }
            }
        }

        if let emphasis = emphasis, let emphasisBG = emphasisBG {
            let shifted = NSRange(location: lineStart + emphasis.location, length: emphasis.length)
            if shifted.location + shifted.length <= result.length {
                result.addAttribute(.backgroundColor, value: emphasisBG, range: shifted)
            }
        }
    }

    /// A muted, unnumbered row with git's enclosing function/section text for
    /// a hunk.
    private static func appendHunkHeader(_ text: String, style: LineStyle, to result: NSMutableAttributedString) {
        result.append(NSAttributedString(string: text + "\n", attributes: [
            .font: style.font,
            .foregroundColor: gutterColor,
            .paragraphStyle: style.paragraph
        ]))
    }

    private static func appendSeparator(style: LineStyle, to result: NSMutableAttributedString) {
        result.append(NSAttributedString(string: "⋯\n", attributes: [
            .font: style.font,
            .foregroundColor: separatorColor,
            .paragraphStyle: style.paragraph
        ]))
    }

    /// The text git puts after a hunk header's closing `@@` (the enclosing
    /// function or section), trimmed; "" when there is none.
    private static func hunkHeaderText(_ header: String) -> String {
        // @@ -oldStart,oldCount +newStart,newCount @@ trailing text
        guard header.count > 2,
              let close = header.range(of: "@@", range: header.index(header.startIndex, offsetBy: 2)..<header.endIndex)
        else { return "" }
        return header[close.upperBound...].trimmingCharacters(in: .whitespaces)
    }

    /// Added and removed line counts inside the diff's hunks. The `---`/`+++`
    /// file header lines sit before the first `@@`, so they are never counted.
    static func changeCounts(_ diff: String) -> (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        var insideHunk = false
        for line in diff.components(separatedBy: "\n") {
            if line.hasPrefix("diff --git") {
                insideHunk = false
            } else if line.hasPrefix("@@") {
                insideHunk = true
            } else if insideHunk, line.hasPrefix("+") {
                added += 1
            } else if insideHunk, line.hasPrefix("-") {
                removed += 1
            }
        }
        return (added, removed)
    }

    private static func parseNewStart(_ hunkHeader: String) -> Int? {
        // @@ -oldStart,oldCount +newStart,newCount @@
        guard let plusIndex = hunkHeader.firstIndex(of: "+") else { return nil }
        let tail = hunkHeader[hunkHeader.index(after: plusIndex)...]
        let digits = tail.prefix(while: { $0.isNumber })
        return Int(digits)
    }
}
