import Foundation

/// How a constellation reduces to a small character map of its own corner of
/// the sky: its stars as `*`, its links drawn between them, and a few of the
/// night's other stars left faint for context. Not the whole sky, and not a
/// chart of anything real: a sketch of what someone noticed.
nonisolated enum NightSkySketch {
    static let star: Character = "*"
    static let neighbor: Character = "·"
    static let blank: Character = " "

    /// Four glyphs, chosen per step rather than per link: a step sideways is a
    /// `─`, a step down is a `│`, and a step that moves both at once is the
    /// diagonal it actually took. Stepping the glyph means a shallow link reads
    /// as a run of `─` that drops now and then, which looks like a line, where
    /// picking one glyph per link would stair a diagonal out of `─`.
    static let horizontal: Character = "─"
    static let vertical: Character = "│"
    static let fallingRight: Character = "╲"
    static let fallingLeft: Character = "╱"

    /// A few, not all: context, not a second sky.
    static let neighborLimit = 6

    /// Canvases in growing resolution. The sketch takes the first one that puts
    /// every one of the constellation's stars on a cell of its own; the last is
    /// fine enough that the field's minimum spacing makes a collision
    /// impossible, so the walk always ends somewhere.
    static let resolutions: [(cols: Int, rows: Int)] = [
        (24, 10), (30, 13), (36, 15), (42, 17), (48, 20), (54, 22)
    ]

    /// A little air around the shape.
    private static let margin = 1.16

    struct Cell: Equatable, Hashable {
        var col: Int
        var row: Int
    }

    /// The sketch, one string per row, ready to sit inside a fence.
    static func rows(path: [Int], sky: [NightSkyStar]) -> [String] {
        let members = orderedMembers(of: path, in: sky)
        guard !members.isEmpty else { return [] }

        let resolution = self.resolution(for: members, in: sky)
        let frame = self.frame(for: members, in: sky, resolution: resolution)
        var grid = Array(
            repeating: Array(repeating: blank, count: resolution.cols),
            count: resolution.rows
        )

        func place(_ character: Character, at cell: Cell, overwriting: Bool) {
            guard (0..<resolution.rows).contains(cell.row), (0..<resolution.cols).contains(cell.col) else { return }
            guard overwriting || grid[cell.row][cell.col] == blank else { return }
            grid[cell.row][cell.col] = character
        }

        // Links first, so a neighbor never sits where a line wants to run.
        for segment in NightSkyModel.segments(of: path) {
            let from = cell(for: sky[segment.from], frame: frame, resolution: resolution)
            let to = cell(for: sky[segment.to], frame: frame, resolution: resolution)
            for (cell, glyph) in walk(from: from, to: to) {
                place(glyph, at: cell, overwriting: false)
            }
        }

        for index in contextStars(around: members, in: sky, frame: frame, resolution: resolution) {
            place(neighbor, at: cell(for: sky[index], frame: frame, resolution: resolution), overwriting: false)
        }

        // Stars last and unconditionally: the shape's own stars always show.
        for index in members {
            place(star, at: cell(for: sky[index], frame: frame, resolution: resolution), overwriting: true)
        }

        return trimmed(grid)
    }

    /// The stars of the shape, each once, in the order they were first linked.
    static func orderedMembers(of path: [Int], in sky: [NightSkyStar]) -> [Int] {
        var seen = Set<Int>()
        return path.filter { sky.indices.contains($0) && seen.insert($0).inserted }
    }

    // MARK: - Fitting the shape to a canvas

    /// The patch of sky the canvas covers. A character cell is about twice as
    /// tall as it is wide, so the canvas has to cover proportionally less
    /// ground vertically or every shape comes out squashed.
    struct Frame: Equatable {
        var originX: Double
        var originY: Double
        var spanX: Double
        var spanY: Double
    }

    static func frame(for members: [Int], in sky: [NightSkyStar], resolution: (cols: Int, rows: Int)) -> Frame {
        let xs = members.map { sky[$0].x }
        let ys = members.map { sky[$0].y }
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 0

        let aspect = self.aspect(of: resolution)
        // A floor for the degenerate case of stars in a near-perfect line.
        var spanX = max(maxX - minX, (maxY - minY) / aspect, 0.02)
        spanX *= margin
        let spanY = spanX * aspect

        return Frame(
            originX: (minX + maxX) / 2 - spanX / 2,
            originY: (minY + maxY) / 2 - spanY / 2,
            spanX: spanX,
            spanY: spanY
        )
    }

    /// How much sky one row covers against one column, in the units the cells
    /// are drawn in.
    static func aspect(of resolution: (cols: Int, rows: Int)) -> Double {
        2 * Double(resolution.rows - 1) / Double(resolution.cols - 1)
    }

    static func cell(for star: NightSkyStar, frame: Frame, resolution: (cols: Int, rows: Int)) -> Cell {
        let col = ((star.x - frame.originX) / frame.spanX * Double(resolution.cols - 1)).rounded()
        let row = ((star.y - frame.originY) / frame.spanY * Double(resolution.rows - 1)).rounded()
        return Cell(
            col: min(max(0, Int(col)), resolution.cols - 1),
            row: min(max(0, Int(row)), resolution.rows - 1)
        )
    }

    /// The coarsest canvas that keeps the shape's stars on separate cells, so
    /// the sketch never quietly loses one to a neighbor.
    static func resolution(for members: [Int], in sky: [NightSkyStar]) -> (cols: Int, rows: Int) {
        for resolution in resolutions {
            let frame = self.frame(for: members, in: sky, resolution: resolution)
            let cells = members.map { cell(for: sky[$0], frame: frame, resolution: resolution) }
            if Set(cells).count == members.count { return resolution }
        }
        return resolutions[resolutions.count - 1]
    }

    /// A handful of the night's unlinked stars that fall inside the sketch,
    /// nearest the shape first.
    static func contextStars(
        around members: [Int],
        in sky: [NightSkyStar],
        frame: Frame,
        resolution: (cols: Int, rows: Int)
    ) -> [Int] {
        let drawn = Set(members)
        let centerX = frame.originX + frame.spanX / 2
        let centerY = frame.originY + frame.spanY / 2

        return sky.indices
            .filter { index in
                guard !drawn.contains(index) else { return false }
                let star = sky[index]
                return star.x >= frame.originX && star.x <= frame.originX + frame.spanX
                    && star.y >= frame.originY && star.y <= frame.originY + frame.spanY
            }
            .sorted { first, second in
                let a = hypot(sky[first].x - centerX, sky[first].y - centerY)
                let b = hypot(sky[second].x - centerX, sky[second].y - centerY)
                // Index breaks a tie, so the sketch is the same every time.
                return a == b ? first < second : a < b
            }
            .prefix(neighborLimit)
            .map { $0 }
    }

    // MARK: - Drawing a link

    /// Bresenham that is allowed to step diagonally, handing back the cells
    /// between two stars with the glyph each step earned. Endpoints are left
    /// out: the stars themselves go there.
    static func walk(from: Cell, to: Cell) -> [(cell: Cell, glyph: Character)] {
        guard from != to else { return [] }

        let dx = abs(to.col - from.col)
        let dy = abs(to.row - from.row)
        let stepX = to.col > from.col ? 1 : -1
        let stepY = to.row > from.row ? 1 : -1

        var col = from.col
        var row = from.row
        var error = dx - dy
        var steps: [(cell: Cell, glyph: Character)] = []

        while true {
            let doubled = 2 * error
            var movedX = 0
            var movedY = 0
            if doubled > -dy {
                error -= dy
                movedX = stepX
            }
            if doubled < dx {
                error += dx
                movedY = stepY
            }
            col += movedX
            row += movedY
            if col == to.col && row == to.row { break }
            steps.append((Cell(col: col, row: row), glyph(movedX: movedX, movedY: movedY)))
        }
        return steps
    }

    static func glyph(movedX: Int, movedY: Int) -> Character {
        switch (movedX, movedY) {
        case (0, _): return vertical
        case (_, 0): return horizontal
        case (1, 1), (-1, -1): return fallingRight
        default: return fallingLeft
        }
    }

    // MARK: - Tidying up

    /// Trailing blanks and empty bands of sky above and below the shape are not
    /// part of the sketch. Nothing that carries a glyph is ever trimmed.
    private static func trimmed(_ grid: [[Character]]) -> [String] {
        var lines = grid.map { row -> String in
            var line = String(row)
            while line.hasSuffix(String(blank)) { line.removeLast() }
            return line
        }
        while let first = lines.first, first.isEmpty { lines.removeFirst() }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines
    }
}

/// The line under a sketch: what is there and where it sits, and nothing else.
/// Quiet and factual on purpose. There is no adjective here for how good a
/// constellation is, because there is no such thing.
nonisolated enum NightSkyProse {
    static func line(path: [Int], sky: [NightSkyStar]) -> String {
        let members = NightSkySketch.orderedMembers(of: path, in: sky)
        let count = members.count
        return "\(word(for: count)) star\(count == 1 ? "" : "s"), \(placement(of: members, in: sky))"
    }

    /// Bands and quarters as a stargazer facing south would call them: east on
    /// the left, west on the right, due south in between.
    static func placement(of members: [Int], in sky: [NightSkyStar]) -> String {
        guard !members.isEmpty else { return "nowhere in particular" }
        let x = members.map { sky[$0].x }.reduce(0, +) / Double(members.count)
        let y = members.map { sky[$0].y }.reduce(0, +) / Double(members.count)

        let band: String
        switch y {
        case ..<(1.0 / 3): band = "high"
        case ..<(2.0 / 3): band = "midway up"
        default: band = "low"
        }

        let quarter: String
        switch x {
        case ..<(1.0 / 3): quarter = "east"
        case ..<(2.0 / 3): quarter = "south"
        default: quarter = "west"
        }

        return "\(band) in the \(quarter)"
    }

    private static let ones = [
        "no", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
        "seventeen", "eighteen", "nineteen"
    ]

    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    /// Words, not figures: a figure in this line would read as a score.
    static func word(for count: Int) -> String {
        switch count {
        case 0..<20:
            return ones[count]
        case 20..<100:
            let remainder = count % 10
            return remainder == 0 ? tens[count / 10] : tens[count / 10] + "-" + ones[remainder]
        default:
            return String(count)
        }
    }
}
