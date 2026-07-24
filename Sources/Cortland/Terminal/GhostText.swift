import Foundation
import SwiftTerm

/// Detects "ghost" suggestion text on the cursor row of a visible-screen read
/// and wraps it in an explicit marker. Claude Code's autosuggest (and its
/// empty-input placeholder, fish/zsh autosuggestions, etc.) render a dim or
/// gray completion starting exactly at the cursor; once `translateToString`
/// flattens the styling, a monitoring agent reading the pane can't tell that
/// text from input the user actually typed. Marking it at read time keeps the
/// screen text honest: the suggestion is visible (an agent may still choose to
/// accept it with right-arrow) but can't be mistaken for typed input.
nonisolated enum GhostText {
    static let markerPrefix = "⟦suggested, not typed: "
    static let markerSuffix = "⟧"

    /// How a cell participates in a ghost run. Only written cells count:
    /// erased/never-written cells (code 0) end the run because their fill
    /// attribute says nothing about what a program drew there.
    enum CellKind {
        /// Written, ghost-styled, and visible content (not a space).
        case ghost
        /// Written space carrying the ghost style — joins two ghost words but
        /// is trimmed from the ends of a run.
        case ghostSpace
        /// Anything else: unwritten, differently styled, or frame drawing.
        case other
    }

    /// Ghost styling is dim, or a mid-gray foreground, on the default
    /// background. Inverse or explicitly colored backgrounds are status bars
    /// and selections, never suggestions.
    static func isGhostStyled(fg: Attribute.Color, bg: Attribute.Color, style: CharacterStyle) -> Bool {
        if style.contains(.inverse) || style.contains(.invisible) { return false }
        switch bg {
        case .defaultColor, .defaultInvertedColor: break
        default: return false
        }
        if style.contains(.dim) { return true }
        switch fg {
        case .ansi256(let code):
            // 8 is bright black; 232–250 is the dark-to-mid stretch of the
            // grayscale ramp. Above 250 sits near-white gray that themes use
            // for ordinary text, and 7/15 (white) stay excluded for the same
            // reason.
            return code == 8 || (232...250).contains(code)
        case .trueColor(let r, let g, let b):
            // Near-neutral (r≈g≈b) and mid-brightness: dark enough not to be
            // a dark theme's normal text, light enough not to be a light
            // theme's.
            let hi = Int(max(r, max(g, b)))
            let lo = Int(min(r, min(g, b)))
            return hi - lo <= 16 && (0x40...0xC0).contains(hi)
        case .defaultColor, .defaultInvertedColor:
            return false
        }
    }

    /// Classifies one cell for run scanning. Unwritten/erased cells read as
    /// NUL through `getCharacter()`. Box/block-drawing characters are `other`
    /// even when ghost-styled: TUI frames (Claude Code's input-box border) are
    /// drawn dim too, and a suggestion never contains them.
    static func kind(character: Character, ghostStyled: Bool) -> CellKind {
        guard character != "\0", ghostStyled else { return .other }
        if character == " " { return .ghostSpace }
        if let scalar = character.unicodeScalars.first,
           (0x2500...0x259F).contains(scalar.value) { return .other }
        return .ghost
    }

    /// The half-open column range of the ghost run anchored at `cursorCol`:
    /// contiguous ghost cells starting at the cursor, trimmed of trailing
    /// spaces. Nil when the run holds no visible character — a suggestion
    /// always begins at the cursor, so dim content elsewhere on the row is
    /// left alone.
    static func ghostRun(kinds: [CellKind], cursorCol: Int) -> Range<Int>? {
        guard cursorCol >= 0, cursorCol < kinds.count else { return nil }
        var lastVisible: Int?
        var col = cursorCol
        scan: while col < kinds.count {
            switch kinds[col] {
            case .ghost: lastVisible = col
            case .ghostSpace: break
            case .other: break scan
            }
            col += 1
        }
        guard let end = lastVisible else { return nil }
        return cursorCol..<(end + 1)
    }

    /// Renders the cursor row with any ghost run wrapped in the marker, or nil
    /// when the row has no ghost run (caller falls back to the plain read).
    static func markedLine(_ line: BufferLine, cursorCol: Int) -> String? {
        let cells = line.getData()
        let kinds = cells.map { cell in
            let attr = cell.attribute
            return kind(character: cell.getCharacter(),
                        ghostStyled: isGhostStyled(fg: attr.fg, bg: attr.bg, style: attr.style))
        }
        guard let run = ghostRun(kinds: kinds, cursorCol: cursorCol) else { return nil }
        let prefix = line.translateToString(trimRight: false, startCol: 0, endCol: run.lowerBound)
        let ghost = line.translateToString(trimRight: false, startCol: run.lowerBound, endCol: run.upperBound)
        let suffix = line.translateToString(trimRight: true, startCol: run.upperBound)
        return prefix + markerPrefix + ghost + markerSuffix + suffix
    }
}
