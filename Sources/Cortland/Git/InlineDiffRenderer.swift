import Cocoa

/// Paints a full-width background behind any line carrying the
/// `InlineDiffRenderer.lineFillColor` attribute, so added/removed lines read as
/// solid Zed-style bars even when the line is empty (a blank-line deletion).
/// `NSAttributedString`'s own `.backgroundColor` only paints behind glyphs, so
/// an empty removed line would otherwise be invisible.
// NSLayoutManager is nonisolated in the SDK, so this subclass opts out of the
// module's default main-actor isolation to match its overridden declarations.
// Layout/drawing is still driven on the main thread by the text system.
nonisolated final class DiffLineBackgroundLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let storage = textStorage {
            enumerateLineFragments(forGlyphRange: glyphsToShow) { [weak self] rect, _, container, glyphRange, _ in
                guard let self = self else { return }
                let charRange = self.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
                guard charRange.length > 0,
                      charRange.location < storage.length,
                      let color = storage.attribute(
                          InlineDiffRenderer.lineFillColor,
                          at: charRange.location,
                          effectiveRange: nil
                      ) as? NSColor else { return }
                color.setFill()
                let fillRect = NSRect(
                    x: origin.x,
                    y: origin.y + rect.minY,
                    width: container.size.width,
                    height: rect.height
                )
                NSBezierPath(rect: fillRect).fill()
            }
        }
        // Draw glyph-level backgrounds (intraline emphasis) on top of the fill.
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

/// Renders unified git diff text as a Zed-style inline diff:
/// - file metadata (diff --git, index, ---, +++) is hidden
/// - removed lines sit directly above their replacements with a light red
///   background and no line number
/// - added lines carry the new file's line number on a light green background
/// - for paired removed/added lines, the changed character range is
///   emphasized with a stronger red/green
enum InlineDiffRenderer {
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    /// Whole-line background, painted full-width by
    /// `DiffLineBackgroundLayoutManager` (use this for added/removed/conflict
    /// lines; reserve `.backgroundColor` for intraline emphasis only).
    nonisolated static let lineFillColor = NSAttributedString.Key("InlineDiffLineFillColor")

    private static var textColor: NSColor { AppTheme.primaryText }
    private static var gutterColor: NSColor { AppTheme.mutedText }
    private static var separatorColor: NSColor { Theme.shared.palette.surface1 }
    private static var removedLineBG: NSColor { AppTheme.error.withAlphaComponent(0.25) }
    private static var removedEmphasisBG: NSColor { AppTheme.error.withAlphaComponent(0.42) }
    private static var addedLineBG: NSColor { AppTheme.success.withAlphaComponent(0.22) }
    private static var addedEmphasisBG: NSColor { AppTheme.success.withAlphaComponent(0.38) }
    private static var conflictMarkerText: NSColor { AppTheme.warning }
    private static var conflictMarkerBG: NSColor { AppTheme.warning.withAlphaComponent(0.15) }
    private static var conflictOursBG: NSColor { Theme.shared.palette.teal.withAlphaComponent(0.12) }
    private static var conflictBaseBG: NSColor { AppTheme.mutedText.withAlphaComponent(0.12) }
    private static var conflictTheirsBG: NSColor { AppTheme.accent.withAlphaComponent(0.12) }

    private enum ConflictSection {
        case none, ours, base, theirs
    }

    private static let gutterWidth = 5
    private static var blankGutter: String { String(repeating: " ", count: gutterWidth) + "  " }

    /// `fileExtension` (lowercased, no dot) drives syntax highlighting of the
    /// diff content; pass "" to render plain (e.g. when the language is
    /// unknown).
    static func render(_ diff: String, fileExtension: String = "") -> NSAttributedString {
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
                if renderedAnyHunk {
                    appendSeparator(to: result)
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
                appendChangeBlock(removed: removed, added: added, newLineNumber: &newLineNumber, ext: fileExtension, to: result)
                continue
            }

            if line.hasPrefix("+") {
                var added: [String] = []
                while index < lines.count, lines[index].hasPrefix("+") {
                    added.append(String(lines[index].dropFirst()))
                    index += 1
                }
                appendChangeBlock(removed: [], added: added, newLineNumber: &newLineNumber, ext: fileExtension, to: result)
                continue
            }

            if line.hasPrefix("\\") {
                // "\ No newline at end of file"
                index += 1
                continue
            }

            // Context line (leading space in unified format).
            let content = line.hasPrefix(" ") ? String(line.dropFirst()) : line
            if conflictMode {
                appendConflictLine(content, number: newLineNumber, section: &conflictSection, ext: fileExtension, to: result)
            } else {
                appendLine(content, number: newLineNumber, lineBG: nil, emphasis: nil, emphasisBG: nil, ext: fileExtension, to: result)
            }
            newLineNumber += 1
            index += 1
        }

        if result.length == 0 {
            result.append(NSAttributedString(string: "No changes", attributes: [
                .font: font,
                .foregroundColor: gutterColor
            ]))
        }
        return result
    }

    // MARK: - Blocks

    private static func appendChangeBlock(
        removed: [String],
        added: [String],
        newLineNumber: inout Int,
        ext: String,
        to result: NSMutableAttributedString
    ) {
        let pairCount = min(removed.count, added.count)

        // Removed lines first (the "before" block), with emphasis computed
        // against the paired replacement line.
        for (offset, removedLine) in removed.enumerated() {
            var emphasis: NSRange?
            if offset < pairCount {
                emphasis = intralineDifference(removedLine, added[offset]).old
            }
            appendLine(removedLine, number: nil, lineBG: removedLineBG, emphasis: emphasis, emphasisBG: removedEmphasisBG, ext: ext, to: result)
        }

        for (offset, addedLine) in added.enumerated() {
            var emphasis: NSRange?
            if offset < pairCount {
                emphasis = intralineDifference(removed[offset], addedLine).new
            }
            appendLine(addedLine, number: newLineNumber, lineBG: addedLineBG, emphasis: emphasis, emphasisBG: addedEmphasisBG, ext: ext, to: result)
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
            appendLine(content, number: number, lineBG: conflictMarkerBG, emphasis: nil, emphasisBG: nil, ext: ext, to: result, foreground: conflictMarkerText)
            return
        }

        let sectionBG: NSColor?
        switch section {
        case .none: sectionBG = nil
        case .ours: sectionBG = conflictOursBG
        case .base: sectionBG = conflictBaseBG
        case .theirs: sectionBG = conflictTheirsBG
        }
        appendLine(content, number: number, lineBG: sectionBG, emphasis: nil, emphasisBG: nil, ext: ext, to: result)
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
        lineBG: NSColor?,
        emphasis: NSRange?,
        emphasisBG: NSColor?,
        ext: String,
        to result: NSMutableAttributedString,
        foreground: NSColor? = nil
    ) {
        let gutter: String
        if let number = number {
            gutter = String(repeating: " ", count: max(0, gutterWidth - "\(number)".count)) + "\(number)  "
        } else {
            gutter = blankGutter
        }

        let lineStart = result.length
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: foreground ?? textColor
        ]
        if let lineBG = lineBG {
            // Full-width fill (incl. empty lines), drawn by the custom layout
            // manager rather than the glyph-bound .backgroundColor.
            attributes[InlineDiffRenderer.lineFillColor] = lineBG
        }

        let lineString = NSMutableAttributedString(string: gutter + content + "\n", attributes: attributes)
        lineString.addAttribute(
            .foregroundColor,
            value: gutterColor,
            range: NSRange(location: 0, length: gutter.count)
        )
        result.append(lineString)

        // Syntax-highlight the content (foreground only) so the add/remove
        // background bars stay intact. Skipped when the caller forces a
        // foreground (conflict markers) or the language is unknown. The gutter
        // is excluded by shifting every token range past it, so line numbers
        // never get mistaken for numeric literals.
        if foreground == nil, !ext.isEmpty {
            let contentStart = lineStart + gutter.count
            for token in SyntaxHighlighter.tokens(for: content, ext: ext) {
                let shifted = NSRange(location: contentStart + token.range.location, length: token.range.length)
                if shifted.location + shifted.length <= result.length {
                    result.addAttribute(.foregroundColor, value: token.color, range: shifted)
                }
            }
        }

        if let emphasis = emphasis, let emphasisBG = emphasisBG {
            let shifted = NSRange(location: lineStart + gutter.count + emphasis.location, length: emphasis.length)
            if shifted.location + shifted.length <= result.length {
                result.addAttribute(.backgroundColor, value: emphasisBG, range: shifted)
            }
        }
    }

    private static func appendSeparator(to result: NSMutableAttributedString) {
        result.append(NSAttributedString(string: "\(blankGutter)⋯\n", attributes: [
            .font: font,
            .foregroundColor: separatorColor
        ]))
    }

    private static func parseNewStart(_ hunkHeader: String) -> Int? {
        // @@ -oldStart,oldCount +newStart,newCount @@
        guard let plusIndex = hunkHeader.firstIndex(of: "+") else { return nil }
        let tail = hunkHeader[hunkHeader.index(after: plusIndex)...]
        let digits = tail.prefix(while: { $0.isNumber })
        return Int(digits)
    }
}
