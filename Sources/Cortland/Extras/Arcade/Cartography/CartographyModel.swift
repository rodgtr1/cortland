import Foundation

/// A name the cartographer has written on the sheet: an anchor cell and
/// whatever they chose to call it. Names are theirs entirely.
nonisolated struct CartographyName: Codable, Equatable, Sendable {
    var cell: Int
    var text: String
}

/// Everything one sheet is: which world (seed), which cells have been drawn,
/// the names placed, the sheet's title, and the ink left this visit. Codable
/// so the whole sheet survives hide and relaunch.
nonisolated struct CartographyState: Codable, Equatable, Sendable {
    var seed: UInt64
    var revealed: Set<Int>
    var names: [CartographyName]
    var title: String
    var ink: Int
}

/// What a revealed cell looks like once drawn. `coast` is special: it is a
/// land cell that touches *revealed* sea, and it only exists once both sides
/// have been surveyed.
nonisolated enum MapGlyph: Equatable, Sendable {
    case sea, lowland, upland, hill, coast
}

/// The sheet in play: the hidden world plus the pen. Pure and `nonisolated`;
/// the view owns rendering, input, and the atlas file. Revealing is the only
/// thing that spends ink, and only newly-uncovered cells cost anything, so
/// going back over old ground is free.
nonisolated final class CartographyModel {
    /// Enough ink for a few strokes a visit. A soft session boundary, not a
    /// resource to manage: it refills in full every time the sheet is opened.
    static let inkCapacity = 130
    static let defaultTitle = "Sheet I"

    private(set) var state: CartographyState
    let world: CartographyWorld

    init(state: CartographyState) {
        self.state = state
        self.world = CartographyWorld(seed: state.seed)
    }

    convenience init(seed: UInt64) {
        self.init(state: CartographyModel.freshState(seed: seed))
    }

    static func freshState(seed: UInt64) -> CartographyState {
        CartographyState(seed: seed, revealed: [], names: [], title: defaultTitle, ink: inkCapacity)
    }

    func snapshot() -> CartographyState { state }

    // MARK: - The pen

    var ink: Int { state.ink }
    var isDry: Bool { state.ink <= 0 }

    /// Refills the pen. Called whenever the sheet is opened; that is the whole
    /// of the "per visit" rule.
    func refillInk() {
        state.ink = Self.inkCapacity
    }

    /// Reveals a radius-1 corridor along a path of cells (a stroke about three
    /// cells wide). Only previously-hidden cells cost ink; when the pen runs
    /// dry, further new cells are simply not drawn. Returns how many cells were
    /// newly uncovered.
    @discardableResult
    func reveal(along path: [(x: Int, y: Int)]) -> Int {
        var newly = 0
        for point in path {
            for dy in -1...1 {
                for dx in -1...1 {
                    let x = point.x + dx
                    let y = point.y + dy
                    guard CartographyWorld.inBounds(x, y) else { continue }
                    let index = CartographyWorld.index(x, y)
                    guard !state.revealed.contains(index) else { continue }
                    guard state.ink > 0 else { continue }
                    state.revealed.insert(index)
                    state.ink -= 1
                    newly += 1
                }
            }
        }
        return newly
    }

    /// The cells a straight pen stroke passes through, so a quick drag still
    /// leaves an unbroken corridor. Bresenham between the two endpoints.
    static func line(from a: (x: Int, y: Int), to b: (x: Int, y: Int)) -> [(x: Int, y: Int)] {
        var points: [(x: Int, y: Int)] = []
        var x = a.x, y = a.y
        let dx = abs(b.x - a.x), dy = abs(b.y - a.y)
        let sx = a.x < b.x ? 1 : -1
        let sy = a.y < b.y ? 1 : -1
        var err = dx - dy
        while true {
            points.append((x, y))
            if x == b.x && y == b.y { break }
            let e2 = 2 * err
            if e2 > -dy { err -= dy; x += sx }
            if e2 < dx { err += dx; y += sy }
        }
        return points
    }

    // MARK: - Reading the sheet

    func isRevealed(_ x: Int, _ y: Int) -> Bool {
        CartographyWorld.inBounds(x, y) && state.revealed.contains(CartographyWorld.index(x, y))
    }

    /// What is drawn at a cell, or nil if it has not been surveyed. A land cell
    /// is `coast` only when one of its four neighbors is *revealed* sea: the
    /// coastline exists solely where both sides have been drawn.
    func glyph(_ x: Int, _ y: Int) -> MapGlyph? {
        guard isRevealed(x, y) else { return nil }
        guard world.isLand(x, y) else { return .sea }
        for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
            if isRevealed(nx, ny) && !world.isLand(nx, ny) {
                return .coast
            }
        }
        switch world.groundAt(x, y) {
        case .hill: return .hill
        case .upland: return .upland
        default: return .lowland
        }
    }

    var revealedCount: Int { state.revealed.count }

    /// Survey progress in words only, never a percentage.
    var progressDescription: String {
        let fraction = Double(state.revealed.count) / Double(CartographyWorld.cellCount)
        if fraction < 0.12 { return "mostly uncharted" }
        if fraction < 0.40 { return "roughly sketched" }
        return "well charted"
    }

    // MARK: - Names

    var names: [CartographyName] { state.names }
    var title: String { state.title }

    func nameAnchored(at cell: Int) -> CartographyName? {
        state.names.first { $0.cell == cell }
    }

    /// Places a name at a cell, or renames the one already anchored there. An
    /// empty name is ignored; nothing else is validated. Names are the user's.
    func placeName(cell: Int, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let index = state.names.firstIndex(where: { $0.cell == cell }) {
            state.names[index].text = trimmed
        } else {
            state.names.append(CartographyName(cell: cell, text: trimmed))
        }
    }

    func setTitle(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        state.title = trimmed
    }

    // MARK: - Export

    /// The revealed sheet as rows of characters, unrevealed cells left blank.
    /// Sea is `~`, land is stippled by elevation, and the coastline is picked
    /// out with `*` so the shore reads even in plain text.
    func mapTextRows() -> [String] {
        (0..<CartographyWorld.height).map { y in
            String((0..<CartographyWorld.width).map { x -> Character in
                switch glyph(x, y) {
                case .none: return " "
                case .sea: return "~"
                case .lowland: return "."
                case .upland: return ":"
                case .hill: return "^"
                case .coast: return "*"
                }
            })
        }
    }
}
