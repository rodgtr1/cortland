import Foundation

/// The seven classic falling-block tetrominoes. Raw values index the color
/// table in BlocksGameView and are what the board stores per locked cell.
nonisolated enum BlockPiece: Int, Codable, CaseIterable, Sendable {
    case i, o, t, s, z, j, l

    /// Cell offsets (x right, y down) per rotation state, relative to the
    /// piece's bounding-box origin. Shapes and spawn orientations follow the
    /// standard rotation system; O and I live in a 4-wide box, the rest in 3x3.
    var cells: [[(x: Int, y: Int)]] {
        switch self {
        case .i:
            return [
                [(0, 1), (1, 1), (2, 1), (3, 1)],
                [(2, 0), (2, 1), (2, 2), (2, 3)],
                [(0, 2), (1, 2), (2, 2), (3, 2)],
                [(1, 0), (1, 1), (1, 2), (1, 3)]
            ]
        case .o:
            let square: [(x: Int, y: Int)] = [(1, 0), (2, 0), (1, 1), (2, 1)]
            return [square, square, square, square]
        case .t:
            return [
                [(1, 0), (0, 1), (1, 1), (2, 1)],
                [(1, 0), (1, 1), (2, 1), (1, 2)],
                [(0, 1), (1, 1), (2, 1), (1, 2)],
                [(1, 0), (0, 1), (1, 1), (1, 2)]
            ]
        case .s:
            return [
                [(1, 0), (2, 0), (0, 1), (1, 1)],
                [(1, 0), (1, 1), (2, 1), (2, 2)],
                [(1, 1), (2, 1), (0, 2), (1, 2)],
                [(0, 0), (0, 1), (1, 1), (1, 2)]
            ]
        case .z:
            return [
                [(0, 0), (1, 0), (1, 1), (2, 1)],
                [(2, 0), (1, 1), (2, 1), (1, 2)],
                [(0, 1), (1, 1), (1, 2), (2, 2)],
                [(1, 0), (0, 1), (1, 1), (0, 2)]
            ]
        case .j:
            return [
                [(0, 0), (0, 1), (1, 1), (2, 1)],
                [(1, 0), (2, 0), (1, 1), (1, 2)],
                [(0, 1), (1, 1), (2, 1), (2, 2)],
                [(1, 0), (1, 1), (0, 2), (1, 2)]
            ]
        case .l:
            return [
                [(2, 0), (0, 1), (1, 1), (2, 1)],
                [(1, 0), (1, 1), (1, 2), (2, 2)],
                [(0, 1), (1, 1), (2, 1), (0, 2)],
                [(0, 0), (1, 0), (1, 1), (1, 2)]
            ]
        }
    }
}

nonisolated struct ActivePieceState: Codable, Equatable, Sendable {
    var piece: BlockPiece
    var rotation: Int
    var x: Int
    var y: Int
}

/// Full game snapshot, Codable so a half-played stack survives hiding the
/// panel and relaunching the app. `board` is rows*columns cells, -1 empty,
/// otherwise a BlockPiece raw value (the locked cell's color).
nonisolated struct BlocksGameState: Codable, Equatable, Sendable {
    var board: [Int]
    var current: ActivePieceState?
    var nextQueue: [BlockPiece]
    var bag: [BlockPiece]
    var held: BlockPiece?
    var canHold: Bool
    var score: Int
    var lines: Int
    var isGameOver: Bool
    /// Rows locked full but not yet collapsed (the view flashes them before
    /// calling `finishClearing`). Optional so blobs saved before this field
    /// existed still decode.
    var pendingClearRows: [Int]?
}

/// Falling-block game logic, kept free of AppKit so it's directly testable.
/// BlocksGameView owns the timer and rendering; this class only answers
/// "what does the board look like now" and mutates on move/rotate/tick.
final class BlocksGame {
    static let columns = 10
    static let rows = 20

    /// Kicks tried in order when a rotated piece collides: stay, nudge one or
    /// two columns either way, then one row up. A rotation that fits none of
    /// these is refused. (Simplified from the full SRS kick tables.)
    private static let rotationKicks = [(0, 0), (-1, 0), (1, 0), (-2, 0), (2, 0), (0, -1)]

    /// Points for clearing 1/2/3/4 lines at once, multiplied by the level.
    private static let clearScores = [0, 100, 300, 500, 800]

    private(set) var board: [Int]
    private(set) var current: ActivePieceState?
    private(set) var nextQueue: [BlockPiece]
    private(set) var held: BlockPiece?
    private(set) var canHold = true
    private(set) var score = 0
    private(set) var lines = 0
    private(set) var isGameOver = false
    /// Non-nil while completed rows await `finishClearing()`. No piece is
    /// active during this phase, so gravity and moves are naturally inert;
    /// the view owns the flash animation and decides when to finish.
    private(set) var pendingClearRows: [Int]?
    private var bag: [BlockPiece]

    var level: Int { lines / 10 + 1 }

    /// Seconds between gravity ticks; shrinks ~18% per level, floored so high
    /// levels stay physically playable.
    var gravityInterval: TimeInterval {
        max(0.06, 0.8 * pow(0.82, Double(level - 1)))
    }

    init() {
        board = Array(repeating: -1, count: Self.columns * Self.rows)
        bag = BlockPiece.allCases.shuffled()
        nextQueue = []
        while nextQueue.count < 3 {
            nextQueue.append(bag.removeFirst())
        }
        spawnNext()
    }

    init(state: BlocksGameState) {
        board = state.board
        current = state.current
        nextQueue = state.nextQueue
        bag = state.bag
        held = state.held
        canHold = state.canHold
        score = state.score
        lines = state.lines
        isGameOver = state.isGameOver
        pendingClearRows = state.pendingClearRows
    }

    func snapshot() -> BlocksGameState {
        BlocksGameState(
            board: board,
            current: current,
            nextQueue: nextQueue,
            bag: bag,
            held: held,
            canHold: canHold,
            score: score,
            lines: lines,
            isGameOver: isGameOver,
            pendingClearRows: pendingClearRows
        )
    }

    // MARK: - Player moves

    @discardableResult
    func moveLeft() -> Bool { shift(dx: -1) }

    @discardableResult
    func moveRight() -> Bool { shift(dx: 1) }

    /// One row down for a point; locks instead when the piece is resting.
    func softDrop() {
        guard !isGameOver, current != nil else { return }
        if shift(dy: 1) {
            score += 1
        } else {
            lockCurrent()
        }
    }

    /// Straight to the ghost position and lock, two points per row fallen.
    func hardDrop() {
        guard !isGameOver, var piece = current else { return }
        let restY = ghostY()
        score += 2 * (restY - piece.y)
        piece.y = restY
        current = piece
        lockCurrent()
    }

    func rotate(clockwise: Bool) {
        guard !isGameOver, var piece = current else { return }
        piece.rotation = (piece.rotation + (clockwise ? 1 : 3)) % 4
        for (dx, dy) in Self.rotationKicks {
            var kicked = piece
            kicked.x += dx
            kicked.y += dy
            if fits(kicked) {
                current = kicked
                return
            }
        }
    }

    /// Stash the falling piece and spawn the previously held one (or the next
    /// piece the first time). Once per lock, per the usual rule.
    func hold() {
        guard !isGameOver, canHold, let piece = current else { return }
        canHold = false
        let stashed = piece.piece
        if let swapped = held {
            held = stashed
            spawn(swapped)
        } else {
            held = stashed
            spawnNext()
        }
        // spawn/spawnNext reset canHold for the next piece; re-clear it so the
        // swapped-in piece can't be immediately re-held.
        canHold = false
    }

    /// Gravity: down one row, or lock when resting. Called by the view's timer.
    func tick() {
        guard !isGameOver, current != nil else { return }
        if !shift(dy: 1) {
            lockCurrent()
        }
    }

    /// The row the current piece would rest on if dropped straight down.
    func ghostY() -> Int {
        guard var piece = current else { return 0 }
        while true {
            var lowered = piece
            lowered.y += 1
            if fits(lowered) {
                piece = lowered
            } else {
                return piece.y
            }
        }
    }

    func cellsOf(_ piece: ActivePieceState) -> [(x: Int, y: Int)] {
        piece.piece.cells[piece.rotation].map { (piece.x + $0.x, piece.y + $0.y) }
    }

    // MARK: - Internals

    private func shift(dx: Int = 0, dy: Int = 0) -> Bool {
        guard !isGameOver, var piece = current else { return false }
        piece.x += dx
        piece.y += dy
        guard fits(piece) else { return false }
        current = piece
        return true
    }

    private func fits(_ piece: ActivePieceState) -> Bool {
        for (x, y) in cellsOf(piece) {
            if x < 0 || x >= Self.columns || y < 0 || y >= Self.rows {
                return false
            }
            if board[y * Self.columns + x] >= 0 {
                return false
            }
        }
        return true
    }

    private func lockCurrent() {
        guard let piece = current else { return }
        for (x, y) in cellsOf(piece) {
            board[y * Self.columns + x] = piece.piece.rawValue
        }
        canHold = true

        let fullRows = (0..<Self.rows).filter { row in
            !board[(row * Self.columns)..<((row + 1) * Self.columns)].contains(-1)
        }
        guard fullRows.isEmpty else {
            // Clearing phase: hold the full rows on the board (no active
            // piece, so ticks/moves are no-ops) until the view's flash
            // animation calls finishClearing().
            current = nil
            pendingClearRows = fullRows
            return
        }
        spawnNext()
    }

    /// Collapses the pending full rows, scores them, and spawns the next
    /// piece. The view calls this when its clear animation ends.
    func finishClearing() {
        guard let fullRows = pendingClearRows else { return }
        pendingClearRows = nil

        // Score before advancing `lines` so a level-up applies from the next
        // clear, matching the classic rules.
        score += Self.clearScores[fullRows.count] * level
        lines += fullRows.count

        var kept: [[Int]] = []
        for row in 0..<Self.rows where !fullRows.contains(row) {
            kept.append(Array(board[(row * Self.columns)..<((row + 1) * Self.columns)]))
        }
        let empty = Array(repeating: -1, count: Self.columns)
        board = Array(Array(repeating: empty, count: fullRows.count).joined()) + Array(kept.joined())
        spawnNext()
    }

    private func spawnNext() {
        let piece = nextQueue.removeFirst()
        if bag.isEmpty {
            bag = BlockPiece.allCases.shuffled()
        }
        nextQueue.append(bag.removeFirst())
        spawn(piece)
    }

    private func spawn(_ piece: BlockPiece) {
        let spawned = ActivePieceState(piece: piece, rotation: 0, x: 3, y: 0)
        current = spawned
        if !fits(spawned) {
            isGameOver = true
        }
    }
}
