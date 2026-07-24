import Foundation

/// What a single character cell in the grove is: the glyph to draw, what kind
/// of thing it belongs to (so the view can color it), a small shade index for
/// muted within-kind variety, and whether it is part of the selected branch.
nonisolated struct GroveCell: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case trunk
        case branch
        case foliage
        case blossom
        case ground
        case pot
    }
    var char: Character
    var kind: Kind
    var shade: Int
    var highlighted: Bool
}

/// A rendered grove: a fixed grid of optional cells plus a count of anything a
/// tip tried to place off-grid (always zero for a well-behaved tree; the
/// bounds test asserts on it).
nonisolated struct GroveGrid: Sendable {
    let cols: Int
    let rows: Int
    private(set) var cells: [GroveCell?]
    private(set) var droppedOutOfBounds: Int = 0

    init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        cells = Array(repeating: nil, count: cols * rows)
    }

    subscript(col: Int, row: Int) -> GroveCell? {
        get {
            guard col >= 0, col < cols, row >= 0, row < rows else { return nil }
            return cells[row * cols + col]
        }
    }

    /// Places a cell, counting (and discarding) anything out of bounds instead
    /// of trapping, so a stray glyph can never crash the panel.
    mutating func place(col: Int, row: Int, cell: GroveCell) {
        guard col >= 0, col < cols, row >= 0, row < rows else {
            droppedOutOfBounds += 1
            return
        }
        cells[row * cols + col] = cell
    }

    /// Human-readable dump, used by the test helper to eyeball the silhouette.
    func text() -> String {
        var lines: [String] = []
        for row in 0..<rows {
            var line = ""
            for col in 0..<cols {
                line.append(self[col, row]?.char ?? " ")
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

/// Rasterizes a branch graph into character cells. This is the taste-critical
/// step: segments become short runs of line glyphs (heavier near the trunk),
/// tips wear small foliage clusters shaped by species, and the earth and pot
/// anchor it. Pure and `nonisolated` so the bounds behavior is testable.
nonisolated enum GroveRasterizer {
    static func rasterize(_ tree: GroveTree, highlightedID: Int? = nil) -> GroveGrid {
        var grid = GroveGrid(cols: GroveGeometry.cols, rows: GroveGeometry.rows)
        drawEarth(into: &grid)
        guard let species = tree.species else { return grid }

        let layout = tree.layout()
        // Trunk and thicker wood first, thin twigs last, so joints read cleanly.
        for seg in layout.sorted(by: { $0.depth < $1.depth }) {
            drawSegment(seg, highlightedID: highlightedID, into: &grid)
        }
        for seg in layout where seg.isTip {
            drawFoliage(seg, species: species, highlightedID: highlightedID, into: &grid)
        }
        return grid
    }

    // MARK: - Wood

    private static func drawSegment(_ seg: GroveSegmentLayout, highlightedID: Int?, into grid: inout GroveGrid) {
        let dCol = seg.end.col - seg.start.col
        let dRow = seg.end.row - seg.start.row
        let steps = max(1, Int(ceil(max(abs(dCol), abs(dRow)))))
        let thick = seg.depth <= 1
        let kind: GroveCell.Kind = thick ? .trunk : .branch
        let char = woodGlyph(dCol: dCol, dRow: dRow, thick: thick)
        let highlighted = seg.id == highlightedID

        for step in 0...steps {
            let t = Double(step) / Double(steps)
            let col = Int((seg.start.col + dCol * t).rounded())
            let row = Int((seg.start.row + dRow * t).rounded())
            grid.place(col: col, row: row, cell: GroveCell(
                char: char, kind: kind, shade: seg.depth % 3, highlighted: highlighted
            ))
        }
    }

    private static func woodGlyph(dCol: Double, dRow: Double, thick: Bool) -> Character {
        if abs(dRow) < 0.45 * abs(dCol) {
            return thick ? "━" : "─"
        }
        if abs(dCol) < 0.45 * abs(dRow) {
            return thick ? "┃" : "│"
        }
        // Up-right (row decreasing as col increases) reads as a forward slash.
        return (dCol * dRow < 0) ? "╱" : "╲"
    }

    // MARK: - Foliage

    private static func drawFoliage(_ seg: GroveSegmentLayout, species: GroveSpecies, highlightedID: Int?, into grid: inout GroveGrid) {
        let col = Int(seg.end.col.rounded())
        let row = Int(seg.end.row.rounded())
        let highlighted = seg.id == highlightedID
        let offsets = foliageOffsets(for: species)

        for (index, offset) in offsets.enumerated() {
            let c = col + offset.0
            let r = row + offset.1
            // The center overwrites the twig tip; the outer leaves only settle
            // onto empty air or existing foliage, never over wood.
            if index != 0 {
                switch grid[c, r]?.kind {
                case .none, .foliage, .blossom:
                    break
                default:
                    continue
                }
            }
            let isBlossom = seg.hasBlossom && index == 0
            grid.place(col: c, row: r, cell: GroveCell(
                char: isBlossom ? "✿" : glyph(for: species, col: c, row: r),
                kind: isBlossom ? .blossom : .foliage,
                shade: abs(c &* 31 &+ r &* 17) % 3,
                highlighted: highlighted
            ))
        }
    }

    /// Cluster shapes: the first offset is always the center (the tip itself).
    /// Pine keeps a tight upward tuft, maple a rounded crown, willow hangs.
    private static func foliageOffsets(for species: GroveSpecies) -> [(Int, Int)] {
        switch species {
        case .pine:
            return [(0, 0), (0, -1), (-1, 0), (1, 0)]
        case .maple:
            return [(0, 0), (0, -1), (-1, 0), (1, 0), (-1, -1), (1, -1)]
        case .willow:
            return [(0, 0), (-1, 0), (1, 0), (0, 1), (-1, 1), (1, 1)]
        }
    }

    private static func glyph(for species: GroveSpecies, col: Int, row: Int) -> Character {
        let set: [Character]
        switch species {
        case .pine: set = ["♠", "▴", "❈"]
        case .maple: set = ["●", "◍", "❀"]
        case .willow: set = ["❦", "ˎ", "·"]
        }
        return set[abs(col &* 13 &+ row &* 7) % set.count]
    }

    // MARK: - Earth

    private static func drawEarth(into grid: inout GroveGrid) {
        let groundRow = Int(GroveGeometry.groundRow.rounded())
        for col in 3..<(GroveGeometry.cols - 3) {
            grid.place(col: col, row: groundRow, cell: GroveCell(
                char: "▁", kind: .ground, shade: col % 2, highlighted: false
            ))
        }
        // A small pot cradling the trunk, two rows under the earth line.
        let base = Int(GroveGeometry.baseCol.rounded())
        let rim: [(Int, Character)] = [(-4, "╲"), (-3, "▁"), (-2, "▁"), (-1, "▁"),
                                       (0, "▁"), (1, "▁"), (2, "▁"), (3, "▁"), (4, "╱")]
        for (dx, ch) in rim {
            grid.place(col: base + dx, row: groundRow + 1, cell: GroveCell(
                char: ch, kind: .pot, shade: 0, highlighted: false
            ))
        }
        let floor: [(Int, Character)] = [(-3, "▔"), (-2, "▔"), (-1, "▔"),
                                         (0, "▔"), (1, "▔"), (2, "▔"), (3, "▔")]
        for (dx, ch) in floor {
            grid.place(col: base + dx, row: groundRow + 2, cell: GroveCell(
                char: ch, kind: .pot, shade: 1, highlighted: false
            ))
        }
    }
}
