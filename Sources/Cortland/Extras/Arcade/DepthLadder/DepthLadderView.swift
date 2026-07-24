import Cocoa

/// The Depth Ladder playfield: an endless descent of picross-style deduction
/// floors. Untimed — there is nothing to pause — so unlike Blocks it opens
/// straight into the puzzle.
final class DepthLadderView: NSView, ArcadeGame {
    static let gameID = "depth-ladder"
    static let title = "Depth Ladder"
    static let howToPlay = """
    Solve each picture-logic grid by filling the cells described by the row and column clues. Each clue is the length of one consecutive run of filled cells; separate runs have at least one empty cell between them.

    A wrong fill counts as a mistake and is crossed automatically. Three mistakes fail the floor and burn one lantern. Your three lanterns refill at midnight. Filling a crossed cell clears the cross first; fill again to commit.

    Arrow keys  Move
    Space or Return  Fill a cell
    X  Mark or unmark an empty cell
    Click  Fill a cell
    Right-click  Mark an empty cell
    Esc  Close the arcade
    """

    /// What the board is showing between floors.
    private enum Overlay {
        case cleared(floor: Int)
        case failed(lanternsLeft: Int)
    }

    private let game: DepthLadderGame
    private var cursor = (row: 0, col: 0)
    private var overlay: Overlay?
    private var mistakeFlashIndex: Int?
    private var mistakeFlashTimer: Timer?

    var onCloseRequested: (() -> Void)?

    // Same footprint as BlocksGameView so switching games never resizes the panel.
    private static let contentSize = BlocksGameView.contentSize
    private static let margin: CGFloat = 16
    private static let boardTop: CGFloat = 64
    private static let boardBottom: CGFloat = 500

    private static let fillColor = NSColor(calibratedRed: 0.30, green: 0.62, blue: 0.88, alpha: 1)
    private static let lanternColor = NSColor(calibratedRed: 0.95, green: 0.66, blue: 0.25, alpha: 1)

    // MARK: - ArcadeGame

    init(savedState: Data?) {
        let saved = savedState.flatMap { try? JSONDecoder().decode(DepthLadderState.self, from: $0) }
        game = saved.map(DepthLadderGame.init(state:)) ?? DepthLadderGame()
        super.init(frame: NSRect(origin: .zero, size: Self.contentSize))
        game.refreshDay(now: Date())
        game.beginFloorIfNeeded(seed: .random(in: UInt64.min...UInt64.max))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    var view: NSView { self }

    func pause() {
        // Untimed; nothing runs while the panel is hidden.
    }

    func resume() {
        game.refreshDay(now: Date())
        if overlay == nil {
            game.beginFloorIfNeeded(seed: .random(in: UInt64.min...UInt64.max))
        }
        needsDisplay = true
    }

    func encodeState() -> Data? {
        try? JSONEncoder().encode(game.snapshot())
    }

    // MARK: - Input

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if event.keyCode == 53 || (event.keyCode == 50 && modifiers == .control) {
            onCloseRequested?()
            return
        }

        game.refreshDay(now: Date())

        // Between floors, any key acknowledges the banner and descends.
        if overlay != nil {
            overlay = nil
            game.beginFloorIfNeeded(seed: .random(in: UInt64.min...UInt64.max))
            needsDisplay = true
            return
        }

        guard let puzzle = game.puzzle else {
            needsDisplay = true // dark screen; redraw picks up a midnight refill
            return
        }

        switch event.keyCode {
        case 123: cursor.col = max(0, cursor.col - 1)
        case 124: cursor.col = min(puzzle.size - 1, cursor.col + 1)
        case 126: cursor.row = max(0, cursor.row - 1)
        case 125: cursor.row = min(puzzle.size - 1, cursor.row + 1)
        case 49, 36: apply(.fill, at: cursor.row * puzzle.size + cursor.col) // space, return
        case 7: game.toggleCross(at: cursor.row * puzzle.size + cursor.col)  // X
        default:
            super.keyDown(with: event)
            return
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        handleClick(event, action: .fill)
    }

    override func rightMouseDown(with event: NSEvent) {
        handleClick(event, action: .cross)
    }

    private enum CellAction {
        case fill
        case cross
    }

    private func handleClick(_ event: NSEvent, action: CellAction) {
        game.refreshDay(now: Date())
        if overlay != nil {
            overlay = nil
            game.beginFloorIfNeeded(seed: .random(in: UInt64.min...UInt64.max))
            needsDisplay = true
            return
        }
        guard let puzzle = game.puzzle, let metrics = gridMetrics(for: puzzle) else { return }
        let point = convert(event.locationInWindow, from: nil)
        let col = Int(floor((point.x - metrics.origin.x) / metrics.cell))
        let row = Int(floor((point.y - metrics.origin.y) / metrics.cell))
        guard (0..<puzzle.size).contains(row), (0..<puzzle.size).contains(col) else { return }
        cursor = (row, col)
        switch action {
        case .fill: apply(.fill, at: row * puzzle.size + col)
        case .cross: game.toggleCross(at: row * puzzle.size + col)
        }
        needsDisplay = true
    }

    private func apply(_ action: CellAction, at index: Int) {
        guard action == .fill else { return }
        switch game.fill(at: index) {
        case .floorCleared:
            overlay = .cleared(floor: game.depth)
            cursor = (0, 0)
        case .floorFailed:
            overlay = game.isDark ? nil : .failed(lanternsLeft: game.lanterns)
            cursor = (0, 0)
        case .mistake:
            flashMistake(at: index)
        case .filled, .uncrossed, .ignored:
            break
        }
    }

    private func flashMistake(at index: Int) {
        mistakeFlashIndex = index
        mistakeFlashTimer?.invalidate()
        mistakeFlashTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.mistakeFlashIndex = nil
                self.mistakeFlashTimer = nil
                self.needsDisplay = true
            }
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        AppTheme.windowBackground.setFill()
        bounds.fill()
        drawHeader()

        if let puzzle = game.puzzle {
            drawPuzzle(puzzle)
        }
        drawOverlayIfNeeded()

        drawText(
            "arrows move   space fill   X cross   click fill   right-click cross   esc close",
            at: NSPoint(x: Self.margin, y: Self.boardBottom + 14),
            font: .systemFont(ofSize: 10),
            color: .tertiaryLabelColor
        )
    }

    private func drawHeader() {
        drawText("FLOOR \(game.floor)", at: NSPoint(x: Self.margin, y: 14), font: .systemFont(ofSize: 18, weight: .bold), color: .labelColor)

        let depthText = "DEPTH \(game.depth) · CLEARED \(game.totalCleared)"
        drawText(depthText, at: NSPoint(x: Self.margin, y: 40), font: .systemFont(ofSize: 11, weight: .medium), color: .secondaryLabelColor, rightAlignedTo: bounds.width - Self.margin)

        // Lanterns as filled/hollow flames; mistakes as accumulated crosses.
        var x = bounds.width - Self.margin
        for index in (0..<DepthLadderGame.lanternsPerDay).reversed() {
            let lit = index < game.lanterns
            let symbol = lit ? "●" : "○"
            let color = lit ? Self.lanternColor : NSColor.tertiaryLabelColor
            x -= 16
            drawText(symbol, at: NSPoint(x: x, y: 14), font: .systemFont(ofSize: 14), color: color)
        }
        drawText("LANTERNS", at: NSPoint(x: x - 74, y: 17), font: .systemFont(ofSize: 10, weight: .semibold), color: .secondaryLabelColor)

        if game.puzzle != nil, game.mistakes > 0 {
            let marks = String(repeating: "✕", count: game.mistakes)
                + String(repeating: "·", count: DepthLadderGame.mistakesAllowed - game.mistakes)
            drawText(marks, at: NSPoint(x: Self.margin, y: 40), font: .systemFont(ofSize: 11, weight: .bold), color: .systemRed)
        }
    }

    private struct GridMetrics {
        var cell: CGFloat
        var origin: NSPoint
        var clueBandWidth: CGFloat
        var clueBandHeight: CGFloat
    }

    private func gridMetrics(for puzzle: NonogramPuzzle) -> GridMetrics? {
        let n = CGFloat(puzzle.size)
        let maxRowClues = CGFloat(puzzle.rowClues.map(\.count).max() ?? 1)
        let maxColClues = CGFloat(puzzle.colClues.map(\.count).max() ?? 1)
        let clueW = maxRowClues * 15 + 8
        let clueH = maxColClues * 13 + 8

        let availWidth = bounds.width - Self.margin * 2
        let availHeight = Self.boardBottom - Self.boardTop
        let cell = min(26, ((availWidth - clueW) / n).rounded(.down), ((availHeight - clueH) / n).rounded(.down))
        guard cell > 4 else { return nil }

        let origin = NSPoint(
            x: Self.margin + clueW + (availWidth - clueW - n * cell) / 2,
            y: Self.boardTop + clueH + (availHeight - clueH - n * cell) / 2
        )
        return GridMetrics(cell: cell, origin: origin, clueBandWidth: clueW, clueBandHeight: clueH)
    }

    private func drawPuzzle(_ puzzle: NonogramPuzzle) {
        guard let metrics = gridMetrics(for: puzzle) else { return }
        let n = puzzle.size
        let cell = metrics.cell
        let origin = metrics.origin
        let gridSize = CGFloat(n) * cell

        NSColor(calibratedWhite: 0.07, alpha: 1).setFill()
        NSRect(x: origin.x, y: origin.y, width: gridSize, height: gridSize).fill()

        // Cells first, lines on top.
        for row in 0..<n {
            for col in 0..<n {
                let index = row * n + col
                let rect = NSRect(
                    x: origin.x + CGFloat(col) * cell,
                    y: origin.y + CGFloat(row) * cell,
                    width: cell,
                    height: cell
                )
                if index == mistakeFlashIndex {
                    NSColor.systemRed.setFill()
                    NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2).fill()
                } else if game.marks[index] == 1 {
                    Self.fillColor.setFill()
                    NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2).fill()
                } else if game.marks[index] == 0 {
                    drawCrossMark(in: rect)
                }
            }
        }

        // Grid lines; picross-style heavier line every 5 cells.
        for line in 0...n {
            let heavy = line % 5 == 0
            NSColor(calibratedWhite: 1, alpha: heavy ? 0.25 : 0.08).setStroke()
            let offset = CGFloat(line) * cell
            strokeLine(
                from: NSPoint(x: origin.x + offset, y: origin.y),
                to: NSPoint(x: origin.x + offset, y: origin.y + gridSize),
                width: heavy ? 1.5 : 1
            )
            strokeLine(
                from: NSPoint(x: origin.x, y: origin.y + offset),
                to: NSPoint(x: origin.x + gridSize, y: origin.y + offset),
                width: heavy ? 1.5 : 1
            )
        }

        drawClues(puzzle, metrics: metrics)

        // Cursor ring.
        NSColor(calibratedRed: 0.95, green: 0.79, blue: 0.20, alpha: 1).setStroke()
        let cursorRect = NSRect(
            x: origin.x + CGFloat(cursor.col) * cell,
            y: origin.y + CGFloat(cursor.row) * cell,
            width: cell,
            height: cell
        ).insetBy(dx: 1, dy: 1)
        let ring = NSBezierPath(roundedRect: cursorRect, xRadius: 2, yRadius: 2)
        ring.lineWidth = 2
        ring.stroke()
    }

    private func drawClues(_ puzzle: NonogramPuzzle, metrics: GridMetrics) {
        let n = puzzle.size
        let clueFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)

        for row in 0..<n {
            let clues = puzzle.rowClues[row]
            let done = lineSatisfied(puzzle.rowClues[row], marks: (0..<n).map { game.marks[row * n + $0] })
            let color: NSColor = done ? .tertiaryLabelColor : .secondaryLabelColor
            let text = clues.isEmpty ? "0" : clues.map(String.init).joined(separator: " ")
            let y = metrics.origin.y + CGFloat(row) * metrics.cell + (metrics.cell - 12) / 2
            drawText(text, at: NSPoint(x: 0, y: y), font: clueFont, color: color, rightAlignedTo: metrics.origin.x - 6)
        }

        for col in 0..<n {
            let clues = puzzle.colClues[col]
            let done = lineSatisfied(puzzle.colClues[col], marks: (0..<n).map { game.marks[$0 * n + col] })
            let color: NSColor = done ? .tertiaryLabelColor : .secondaryLabelColor
            let numbers = clues.isEmpty ? ["0"] : clues.map(String.init)
            let x = metrics.origin.x + CGFloat(col) * metrics.cell
            var y = metrics.origin.y - 14
            for number in numbers.reversed() {
                drawText(number, at: NSPoint(x: 0, y: y), font: clueFont, color: color, rightAlignedTo: x + metrics.cell - (metrics.cell - 12) / 2)
                y -= 13
            }
        }
    }

    /// A line's clues grey out once its filled runs match them exactly.
    private func lineSatisfied(_ clues: [Int], marks: [Int]) -> Bool {
        NonogramGenerator.clues(for: marks.map { $0 == 1 }) == clues
    }

    private func drawOverlayIfNeeded() {
        let title: String
        let subtitle: String

        if let overlay {
            switch overlay {
            case .cleared(let floor):
                title = "FLOOR \(floor) CLEARED"
                subtitle = "press any key to descend"
            case .failed(let lanternsLeft):
                title = "Floor failed"
                subtitle = "a lantern burned out — \(lanternsLeft) left · any key to retry"
            }
        } else if game.isDark {
            title = "The tower is dark"
            subtitle = "your lanterns refill at midnight"
        } else if game.puzzle == nil {
            return
        } else {
            return
        }

        NSColor(calibratedWhite: 0, alpha: 0.55).setFill()
        NSRect(x: Self.margin, y: Self.boardTop, width: bounds.width - Self.margin * 2, height: Self.boardBottom - Self.boardTop).fill()
        drawCenteredText(title, font: .systemFont(ofSize: 20, weight: .bold), color: .white, dy: -14)
        drawCenteredText(subtitle, font: .systemFont(ofSize: 12), color: NSColor(calibratedWhite: 1, alpha: 0.7), dy: 14)
    }

    // MARK: - Drawing helpers

    private func drawCrossMark(in rect: NSRect) {
        NSColor(calibratedWhite: 0.55, alpha: 1).setStroke()
        let inset = rect.insetBy(dx: rect.width * 0.3, dy: rect.height * 0.3)
        strokeLine(from: NSPoint(x: inset.minX, y: inset.minY), to: NSPoint(x: inset.maxX, y: inset.maxY), width: 1.5)
        strokeLine(from: NSPoint(x: inset.minX, y: inset.maxY), to: NSPoint(x: inset.maxX, y: inset.minY), width: 1.5)
    }

    private func strokeLine(from: NSPoint, to: NSPoint, width: CGFloat) {
        let path = NSBezierPath()
        path.move(to: from)
        path.line(to: to)
        path.lineWidth = width
        path.stroke()
    }

    private func drawText(_ string: String, at point: NSPoint, font: NSFont, color: NSColor, rightAlignedTo rightEdge: CGFloat? = nil) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        var origin = point
        if let rightEdge {
            let width = (string as NSString).size(withAttributes: attributes).width
            origin.x = rightEdge - width
        }
        (string as NSString).draw(at: origin, withAttributes: attributes)
    }

    private func drawCenteredText(_ string: String, font: NSFont, color: NSColor, dy: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (string as NSString).size(withAttributes: attributes)
        let boardMidY = Self.boardTop + (Self.boardBottom - Self.boardTop) / 2
        let origin = NSPoint(
            x: bounds.midX - size.width / 2,
            y: boardMidY - size.height / 2 + dy
        )
        (string as NSString).draw(at: origin, withAttributes: attributes)
    }
}
