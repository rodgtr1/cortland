import Foundation

/// A tile's four edges, clockwise from the top. A stub either reaches an edge
/// or it does not; that is the whole vocabulary.
nonisolated enum LoomEdge: Int, CaseIterable, Sendable {
    case north, east, south, west

    var opposite: LoomEdge { LoomEdge(rawValue: (rawValue + 2) % 4)! }
    var bit: UInt8 { UInt8(1 << rawValue) }

    var delta: (row: Int, col: Int) {
        switch self {
        case .north: return (-1, 0)
        case .east: return (0, 1)
        case .south: return (1, 0)
        case .west: return (0, -1)
        }
    }
}

/// One thread fragment. Its *identity* is the set of edges carrying a stub,
/// fixed the moment it is dealt; its *state* is a rotation. Turning a tile
/// never changes what it is, only which way it faces, which is why no turn can
/// ever be a mistake.
nonisolated struct LoomTile: Codable, Equatable, Sendable {
    /// Stub set in the tile's base orientation.
    let stubs: UInt8
    /// Quarter turns clockwise from that base, 0..3.
    var rotation: Int

    var mask: UInt8 { LoomTile.rotate(stubs, by: rotation) }

    func has(_ edge: LoomEdge) -> Bool { mask & edge.bit != 0 }

    /// Blank and cross read identically at every angle, so a turn spends
    /// nothing on them and the scrambler skips them. Every other stub set is
    /// changed by a single quarter turn: 0b0000 and 0b1111 are the only 4-bit
    /// patterns fixed by a cyclic shift of one.
    var isRotatable: Bool { stubs != 0 && stubs != 0b1111 }

    static func rotate(_ stubs: UInt8, by turns: Int) -> UInt8 {
        let turns = ((turns % 4) + 4) % 4
        var rotated: UInt8 = 0
        for edge in LoomEdge.allCases where stubs & edge.bit != 0 {
            rotated |= UInt8(1 << ((edge.rawValue + turns) % 4))
        }
        return rotated
    }
}

/// One panel: a square grid of fragments and the seed it grew from.
nonisolated struct LoomPanel: Codable, Equatable, Sendable {
    let seed: UInt64
    let side: Int
    var tiles: [LoomTile]

    func contains(row: Int, col: Int) -> Bool {
        (0..<side).contains(row) && (0..<side).contains(col)
    }

    func index(row: Int, col: Int) -> Int { row * side + col }

    func tile(row: Int, col: Int) -> LoomTile { tiles[index(row: row, col: col)] }
}

nonisolated enum LoomBoard {
    /// Settled means edge-consistent everywhere: across every internal edge the
    /// two facing tiles agree, and no stub points off the board. Any
    /// arrangement satisfying that is settled, not only the pattern the panel
    /// was woven from, so a player who finds a different closed weave is just
    /// as done.
    static func isSettled(_ panel: LoomPanel) -> Bool {
        for row in 0..<panel.side {
            for col in 0..<panel.side {
                let tile = panel.tile(row: row, col: col)
                for edge in LoomEdge.allCases {
                    let neighborRow = row + edge.delta.row
                    let neighborCol = col + edge.delta.col
                    guard panel.contains(row: neighborRow, col: neighborCol) else {
                        if tile.has(edge) { return false } // frays into the void
                        continue
                    }
                    let neighbor = panel.tile(row: neighborRow, col: neighborCol)
                    if tile.has(edge) != neighbor.has(edge.opposite) { return false }
                }
            }
        }
        return true
    }
}

nonisolated enum LoomGenerator {
    /// Variety, not progression: no panel is harder than another, they are just
    /// differently sized.
    static let sides = [5, 6, 7, 8]

    static func panel(seed: UInt64) -> LoomPanel {
        var rng = SplitMix64(seed: seed)
        let side = sides[Int.random(in: 0..<sides.count, using: &rng)]
        let settled = settledPattern(side: side, rng: &rng)
        return scramble(side: side, tiles: settled, seed: seed, rng: &rng)
    }

    /// Builds a settled pattern first, so solvability is a property of how the
    /// panel was made rather than something to be checked afterwards: switch
    /// each internal edge on or off, then read every tile's stub set off the
    /// edges incident to it. Boundary edges are never switched on, so no stub
    /// can point into the void. Boards that come out mostly bare are rerolled
    /// at a higher density.
    static func settledPattern(side: Int, rng: inout SplitMix64) -> [LoomTile] {
        for attempt in 0..<40 {
            let density = min(0.72, 0.5 + Double(attempt) * 0.02)
            var stubs = [UInt8](repeating: 0, count: side * side)

            for row in 0..<side {
                for col in 0..<(side - 1) where Double.random(in: 0..<1, using: &rng) < density {
                    stubs[row * side + col] |= LoomEdge.east.bit
                    stubs[row * side + col + 1] |= LoomEdge.west.bit
                }
            }
            for row in 0..<(side - 1) {
                for col in 0..<side where Double.random(in: 0..<1, using: &rng) < density {
                    stubs[row * side + col] |= LoomEdge.south.bit
                    stubs[(row + 1) * side + col] |= LoomEdge.north.bit
                }
            }

            let threaded = stubs.filter { $0 != 0 }.count
            let turnable = stubs.filter { $0 != 0 && $0 != 0b1111 }.count
            if threaded * 2 >= stubs.count, turnable > 0 {
                return stubs.map { LoomTile(stubs: $0, rotation: 0) }
            }
        }
        return corridors(side: side)
    }

    /// The reroll's floor, reached only if forty draws in a row came out bare
    /// (at these densities, never). Every row is one straight run of thread:
    /// plain, settled, and non-degenerate by construction.
    private static func corridors(side: Int) -> [LoomTile] {
        var stubs = [UInt8](repeating: 0, count: side * side)
        for row in 0..<side {
            for col in 0..<(side - 1) {
                stubs[row * side + col] |= LoomEdge.east.bit
                stubs[row * side + col + 1] |= LoomEdge.west.bit
            }
        }
        return stubs.map { LoomTile(stubs: $0, rotation: 0) }
    }

    /// Gives every turnable tile a random angle. A shuffle that happens to land
    /// settled is simply rolled again: a panel dealt already finished is the
    /// one thing this game has nothing to offer.
    static func scramble(side: Int, tiles: [LoomTile], seed: UInt64, rng: inout SplitMix64) -> LoomPanel {
        var panel = LoomPanel(seed: seed, side: side, tiles: tiles)
        for _ in 0..<32 {
            for index in panel.tiles.indices where panel.tiles[index].isRotatable {
                panel.tiles[index].rotation = Int.random(in: 0..<4, using: &rng)
            }
            if !LoomBoard.isSettled(panel) { return panel }
        }
        return nudged(panel)
    }

    /// The reroll's floor again, and one that cannot fail: on a settled board,
    /// turning any single tile to a mask it did not have leaves the edge it
    /// turned away from disagreeing, because nothing else moved. A quarter turn
    /// always changes a rotatable tile's mask, so the first one will do.
    private static func nudged(_ panel: LoomPanel) -> LoomPanel {
        var panel = panel
        if let index = panel.tiles.indices.first(where: { panel.tiles[$0].isRotatable }) {
            panel.tiles[index].rotation = (panel.tiles[index].rotation + 1) % 4
        }
        return panel
    }
}
