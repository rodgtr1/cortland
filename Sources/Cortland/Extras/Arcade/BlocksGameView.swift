import Cocoa

/// What Blocks persists between launches: the best score always, plus the
/// in-progress stack when the panel was hidden mid-game.
nonisolated private struct BlocksSave: Codable {
    var highScore: Int
    var game: BlocksGameState?
}

/// The falling-blocks playfield: rendering, keyboard input, and the gravity
/// timer around a `BlocksGame`. Opens paused; any key starts/resumes, so
/// summoning the panel never costs a piece.
final class BlocksGameView: NSView, ArcadeGame {
    static let gameID = "blocks"
    static let title = "Blocks"
    static let howToPlay = """
    Complete horizontal rows with the falling pieces. Completed rows disappear; the game ends when the stack reaches the top.

    ← →  Move
    ↓  Soft drop
    Space  Hard drop
    ↑ or X  Rotate clockwise
    Z  Rotate counterclockwise
    C  Hold or swap a piece
    P  Pause
    N  Start a new game
    Esc  Close the arcade
    """

    private static let cellSize: CGFloat = 24
    private static let margin: CGFloat = 16
    private static let sidebarWidth: CGFloat = 132
    private static let boardFrame = NSRect(
        x: margin,
        y: margin,
        width: cellSize * CGFloat(BlocksGame.columns),
        height: cellSize * CGFloat(BlocksGame.rows)
    )
    static let contentSize = NSSize(
        width: boardFrame.maxX + margin + sidebarWidth + margin,
        height: boardFrame.maxY + 44
    )

    /// Fill colors indexed by BlockPiece.rawValue (classic piece colors).
    private static let pieceColors: [NSColor] = [
        NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.85, alpha: 1), // I cyan
        NSColor(calibratedRed: 0.95, green: 0.79, blue: 0.20, alpha: 1), // O yellow
        NSColor(calibratedRed: 0.64, green: 0.40, blue: 0.85, alpha: 1), // T purple
        NSColor(calibratedRed: 0.36, green: 0.78, blue: 0.36, alpha: 1), // S green
        NSColor(calibratedRed: 0.88, green: 0.32, blue: 0.32, alpha: 1), // Z red
        NSColor(calibratedRed: 0.30, green: 0.47, blue: 0.88, alpha: 1), // J blue
        NSColor(calibratedRed: 0.92, green: 0.56, blue: 0.22, alpha: 1)  // L orange
    ]

    private var game: BlocksGame
    private var highScore: Int
    private var isPaused = true
    private var gravityTimer: Timer?
    private var clearFlashTimer: Timer?
    private var clearFlashStep = 0
    private var isAnimatingClear: Bool { clearFlashTimer != nil }
    private var wasPausedBeforeHelp: Bool?

    var onCloseRequested: (() -> Void)?

    // MARK: - ArcadeGame

    init(savedState: Data?) {
        let saved = savedState.flatMap { try? JSONDecoder().decode(BlocksSave.self, from: $0) }
        game = saved?.game.map(BlocksGame.init(state:)) ?? BlocksGame()
        highScore = saved?.highScore ?? 0
        super.init(frame: NSRect(origin: .zero, size: Self.contentSize))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    var view: NSView { self }

    func pause() {
        isPaused = true
        gravityTimer?.invalidate()
        gravityTimer = nil
        // Resolve a mid-flash clear instantly so the frozen (and persisted)
        // board is never stuck between locking and collapsing.
        if isAnimatingClear {
            finishClearAnimation()
        }
        needsDisplay = true
    }

    func resume() {
        guard !game.isGameOver else { return }
        isPaused = false
        // A clear pending with no animation running can only come from a
        // state blob saved mid-clear; play the flash it was owed.
        if game.pendingClearRows != nil {
            startClearAnimation()
        } else {
            scheduleTick()
        }
        needsDisplay = true
    }

    func willShowHelp() {
        wasPausedBeforeHelp = isPaused
        pause()
    }

    func didDismissHelp() {
        defer { wasPausedBeforeHelp = nil }
        if wasPausedBeforeHelp == false {
            resume()
        }
    }

    func encodeState() -> Data? {
        // A finished game isn't worth resuming, but the best score always is.
        let save = BlocksSave(highScore: highScore, game: game.isGameOver ? nil : game.snapshot())
        return try? JSONEncoder().encode(save)
    }

    // MARK: - Input

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])

        // Esc and the global toggle chord close the panel from any state.
        if event.keyCode == 53 || (event.keyCode == 50 && modifiers == .control) {
            onCloseRequested?()
            return
        }

        if game.isGameOver {
            if event.keyCode == 45 { startNewGame() } // N
            return
        }

        if isPaused {
            // Any key wakes the game; consume it so the waking press doesn't
            // also move the piece.
            resume()
            return
        }

        // No piece to steer during the ~0.3s clear flash.
        if isAnimatingClear {
            return
        }

        switch event.keyCode {
        case 123: game.moveLeft()
        case 124: game.moveRight()
        case 125: game.softDrop()
        case 126, 7: game.rotate(clockwise: true)  // ↑ or X
        case 6: game.rotate(clockwise: false)      // Z
        case 49: game.hardDrop()                   // space
        case 8: game.hold()                        // C
        case 35: pause(); return                   // P
        case 45: startNewGame(); return            // N
        default:
            super.keyDown(with: event)
            return
        }
        afterAction()
    }

    // MARK: - Game flow

    private func startNewGame() {
        clearFlashTimer?.invalidate()
        clearFlashTimer = nil
        game = BlocksGame()
        isPaused = false
        scheduleTick()
        needsDisplay = true
    }

    private func afterAction() {
        highScore = max(highScore, game.score)
        if game.pendingClearRows != nil && !isAnimatingClear {
            startClearAnimation()
        }
        if game.isGameOver {
            gravityTimer?.invalidate()
            gravityTimer = nil
        }
        needsDisplay = true
    }

    /// Flashes the completed rows (~0.3s) before letting the model collapse
    /// them. Gravity is parked meanwhile; the model has no active piece
    /// during the clearing phase, so nothing else can move anyway.
    private func startClearAnimation() {
        gravityTimer?.invalidate()
        gravityTimer = nil
        clearFlashStep = 0
        clearFlashTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.clearFlashStep += 1
                if self.clearFlashStep >= 6 {
                    self.finishClearAnimation()
                }
                self.needsDisplay = true
            }
        }
        needsDisplay = true
    }

    private func finishClearAnimation() {
        clearFlashTimer?.invalidate()
        clearFlashTimer = nil
        game.finishClearing()
        highScore = max(highScore, game.score)
        if !isPaused {
            scheduleTick()
        }
        needsDisplay = true
    }

    /// Chained single-shot timer instead of a repeating one, so the delay
    /// naturally tracks `gravityInterval` as the level climbs.
    private func scheduleTick() {
        gravityTimer?.invalidate()
        guard !isPaused, !game.isGameOver else { return }
        gravityTimer = Timer.scheduledTimer(withTimeInterval: game.gravityInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.game.tick()
                self.afterAction()
                self.scheduleTick()
            }
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        AppTheme.windowBackground.setFill()
        bounds.fill()
        drawBoard()
        drawSidebar()
        drawStateOverlay()
        drawText(
            "← → move   ↓ soft drop   space drop   Z/X rotate   C hold   P pause   esc close",
            at: NSPoint(x: Self.margin, y: Self.boardFrame.maxY + 10),
            font: .systemFont(ofSize: 10),
            color: .tertiaryLabelColor
        )
    }

    private func drawBoard() {
        let board = Self.boardFrame
        NSColor(calibratedWhite: 0.07, alpha: 1).setFill()
        board.fill()

        NSColor(calibratedWhite: 1, alpha: 0.05).setStroke()
        for column in 1..<BlocksGame.columns {
            let x = board.minX + CGFloat(column) * Self.cellSize
            strokeLine(from: NSPoint(x: x, y: board.minY), to: NSPoint(x: x, y: board.maxY))
        }
        for row in 1..<BlocksGame.rows {
            let y = board.minY + CGFloat(row) * Self.cellSize
            strokeLine(from: NSPoint(x: board.minX, y: y), to: NSPoint(x: board.maxX, y: y))
        }

        // Completed rows blink white on even flash steps until they collapse.
        let flashingRows: Set<Int> =
            (isAnimatingClear && clearFlashStep.isMultiple(of: 2)) ? Set(game.pendingClearRows ?? []) : []

        for row in 0..<BlocksGame.rows {
            for column in 0..<BlocksGame.columns {
                let value = game.board[row * BlocksGame.columns + column]
                if value >= 0 {
                    let color = flashingRows.contains(row)
                        ? NSColor(calibratedWhite: 0.95, alpha: 1)
                        : Self.pieceColors[value]
                    fillCell(column: column, row: row, color: color)
                }
            }
        }

        guard let current = game.current, !game.isGameOver else { return }
        let color = Self.pieceColors[current.piece.rawValue]

        var ghost = current
        ghost.y = game.ghostY()
        if ghost.y != current.y {
            color.withAlphaComponent(0.35).setStroke()
            for (x, y) in game.cellsOf(ghost) {
                let path = NSBezierPath(rect: cellRect(column: x, row: y).insetBy(dx: 1.5, dy: 1.5))
                path.lineWidth = 1.5
                path.stroke()
            }
        }

        for (x, y) in game.cellsOf(current) {
            fillCell(column: x, row: y, color: color)
        }
    }

    private func drawSidebar() {
        let x = Self.boardFrame.maxX + Self.margin
        var y = Self.margin

        y = drawSidebarSection(label: "HOLD", x: x, y: y) {
            drawMiniPiece(game.held, atX: x, y: $0, dimmed: !game.canHold)
            return $0 + 44
        }
        y = drawSidebarSection(label: "NEXT", x: x, y: y) {
            var cursor = $0
            for piece in game.nextQueue.prefix(3) {
                drawMiniPiece(piece, atX: x, y: cursor, dimmed: false)
                cursor += 38
            }
            return cursor + 6
        }
        y = drawStat(label: "SCORE", value: "\(game.score)", x: x, y: y)
        y = drawStat(label: "LINES", value: "\(game.lines)", x: x, y: y)
        y = drawStat(label: "LEVEL", value: "\(game.level)", x: x, y: y)
        _ = drawStat(label: "BEST", value: "\(highScore)", x: x, y: y)
    }

    private func drawSidebarSection(label: String, x: CGFloat, y: CGFloat, body: (CGFloat) -> CGFloat) -> CGFloat {
        drawText(label, at: NSPoint(x: x, y: y), font: .systemFont(ofSize: 10, weight: .semibold), color: .secondaryLabelColor)
        return body(y + 16)
    }

    private func drawStat(label: String, value: String, x: CGFloat, y: CGFloat) -> CGFloat {
        drawText(label, at: NSPoint(x: x, y: y), font: .systemFont(ofSize: 10, weight: .semibold), color: .secondaryLabelColor)
        drawText(value, at: NSPoint(x: x, y: y + 14), font: .monospacedSystemFont(ofSize: 16, weight: .medium), color: .labelColor)
        return y + 44
    }

    private func drawMiniPiece(_ piece: BlockPiece?, atX x: CGFloat, y: CGFloat, dimmed: Bool) {
        guard let piece else { return }
        let mini: CGFloat = 11
        let cells = piece.cells[0]
        let minX = cells.map(\.x).min() ?? 0
        let minY = cells.map(\.y).min() ?? 0
        let color = Self.pieceColors[piece.rawValue].withAlphaComponent(dimmed ? 0.3 : 1)
        color.setFill()
        for (cx, cy) in cells {
            let rect = NSRect(
                x: x + CGFloat(cx - minX) * mini,
                y: y + CGFloat(cy - minY) * mini,
                width: mini,
                height: mini
            ).insetBy(dx: 0.5, dy: 0.5)
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    private func drawStateOverlay() {
        let (title, subtitle): (String, String)
        if game.isGameOver {
            (title, subtitle) = ("Game Over", "press N for a new game")
        } else if isPaused {
            let fresh = game.score == 0 && game.lines == 0 && !game.board.contains(where: { $0 >= 0 })
            (title, subtitle) = (fresh ? "Blocks" : "Paused", fresh ? "press any key to start" : "press any key to resume")
        } else {
            return
        }

        NSColor(calibratedWhite: 0, alpha: 0.55).setFill()
        Self.boardFrame.fill()
        drawCenteredText(title, font: .systemFont(ofSize: 22, weight: .bold), color: .white, dy: -16)
        drawCenteredText(subtitle, font: .systemFont(ofSize: 12), color: NSColor(calibratedWhite: 1, alpha: 0.7), dy: 14)
    }

    // MARK: - Drawing helpers

    private func cellRect(column: Int, row: Int) -> NSRect {
        NSRect(
            x: Self.boardFrame.minX + CGFloat(column) * Self.cellSize,
            y: Self.boardFrame.minY + CGFloat(row) * Self.cellSize,
            width: Self.cellSize,
            height: Self.cellSize
        )
    }

    private func fillCell(column: Int, row: Int, color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: cellRect(column: column, row: row).insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2).fill()
    }

    private func strokeLine(from: NSPoint, to: NSPoint) {
        let path = NSBezierPath()
        path.move(to: from)
        path.line(to: to)
        path.lineWidth = 1
        path.stroke()
    }

    private func drawText(_ string: String, at point: NSPoint, font: NSFont, color: NSColor) {
        (string as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }

    private func drawCenteredText(_ string: String, font: NSFont, color: NSColor, dy: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (string as NSString).size(withAttributes: attributes)
        let origin = NSPoint(
            x: Self.boardFrame.midX - size.width / 2,
            y: Self.boardFrame.midY - size.height / 2 + dy
        )
        (string as NSString).draw(at: origin, withAttributes: attributes)
    }
}
