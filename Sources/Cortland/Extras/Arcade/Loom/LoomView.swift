import Cocoa

/// Loom: a panel of thread fragments, each turnable in place, until every
/// thread meets its neighbor and nothing frays into the void. There is no
/// clock, no par, and no wrong move: a turn is either settled or not yet, and a
/// half-turned panel left for a week is a perfectly good thing to come back to.
/// Settling one weaves a single row into loom-tapestry.md, which is the only
/// thing here that accumulates.
final class LoomView: NSView, ArcadeGame {
    static let gameID = "loom"
    static let title = "Loom"
    static let howToPlay = """
    Turn the thread fragments until every stub meets a stub on the tile beside it and none point off the edge of the board. When the panel closes into quiet loops it settles, and one row of cloth is woven into your tapestry.

    No turn is ever a mistake, nothing is timed, and nothing is scored. Solving is optional: a half-turned panel keeps exactly as you left it for as long as you like. Any closed arrangement counts, not only the one the panel started from.

    Arrows or hjkl  Move the cursor
    Space or Return  Turn a tile a quarter clockwise
    Click  Turn that tile
    Space on a settled panel  Weave a new one
    T  Show or hide the tapestry
    Esc  Close the arcade
    """

    private static let contentSize = BlocksGameView.contentSize
    private static let margin: CGFloat = 22
    private static let boardTop: CGFloat = 58
    private static let boardBottom: CGFloat = 470
    private static let maxCell: CGFloat = 54

    /// One soft pass across the settled panel, then stillness again.
    private static let shimmerDuration: Double = 0.9
    private static let shimmerInterval: TimeInterval = 1.0 / 30

    private static let unsettledThread = NSColor(calibratedWhite: 0.48, alpha: 1)
    private static let settledThread = NSColor(calibratedRed: 0.76, green: 0.64, blue: 0.42, alpha: 1)

    private let model: LoomModel

    private var showingTapestry = false
    private var tapestryRows: [String] = []
    private var tapestryRowsThisMonth = 0

    /// Elapsed shimmer time, or nil when there is nothing moving. Never state:
    /// a panel settled last week looks the same as one settled a moment ago.
    private var shimmer: Double?
    private var shimmerTimer: Timer?

    private let openFileButton = NSButton(title: "Open loom-tapestry.md", target: nil, action: nil)

    var onCloseRequested: (() -> Void)?

    // MARK: - ArcadeGame

    init(savedState: Data?) {
        let saved = savedState.flatMap { try? JSONDecoder().decode(LoomState.self, from: $0) }
        let state = saved ?? LoomModel.freshState(seed: UInt64.random(in: UInt64.min...UInt64.max))
        model = LoomModel(state: state)
        super.init(frame: NSRect(origin: .zero, size: Self.contentSize))
        buildTapestryControls()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    var view: NSView { self }

    func pause() {
        stopShimmer()
    }

    func resume() {
        needsDisplay = true
    }

    func willShowHelp() {
        pause()
    }

    func didDismissHelp() {
        resume()
    }

    func encodeState() -> Data? {
        try? JSONEncoder().encode(model.snapshot())
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    // MARK: - Input

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if event.keyCode == 53 || (event.keyCode == 50 && modifiers == .control) {
            onCloseRequested?()
            return
        }

        if showingTapestry {
            switch event.keyCode {
            case 17, 49: setTapestryVisible(false) // t, space
            default: super.keyDown(with: event)
            }
            return
        }

        switch event.keyCode {
        case 123, 4: model.moveCursor(rowDelta: 0, colDelta: -1)  // left, h
        case 124, 37: model.moveCursor(rowDelta: 0, colDelta: 1)  // right, l
        case 126, 40: model.moveCursor(rowDelta: -1, colDelta: 0) // up, k
        case 125, 38: model.moveCursor(rowDelta: 1, colDelta: 0)  // down, j
        case 49, 36: turnOrWeave()                                // space, return
        case 17: setTapestryVisible(true)                         // t
        default:
            super.keyDown(with: event)
            return
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard !showingTapestry, let metrics = boardMetrics() else { return }

        let point = convert(event.locationInWindow, from: nil)
        let col = Int(floor((point.x - metrics.origin.x) / metrics.cell))
        let row = Int(floor((point.y - metrics.origin.y) / metrics.cell))
        guard model.panel.contains(row: row, col: col) else { return }

        model.setCursor(model.panel.index(row: row, col: col))
        turnOrWeave()
        needsDisplay = true
    }

    /// Space is the only verb that changes meaning, and only once there is
    /// nothing left to turn: on a settled panel it asks for a new one, and it
    /// asks nothing until then.
    private func turnOrWeave() {
        if model.isSettled {
            model.nextPanel()
            stopShimmer()
            return
        }
        guard model.turnAtCursor() == .settled else { return }
        LoomTapestry.record(model.panel, date: Date())
        startShimmer()
    }

    // MARK: - The tapestry view

    private func buildTapestryControls() {
        openFileButton.bezelStyle = .rounded
        openFileButton.controlSize = .small
        openFileButton.font = .systemFont(ofSize: 11)
        openFileButton.target = self
        openFileButton.action = #selector(openFileClicked)
        openFileButton.refusesFirstResponder = true
        openFileButton.frame = NSRect(x: bounds.midX - 85, y: bounds.height - 46, width: 170, height: 26)
        openFileButton.isHidden = true
        addSubview(openFileButton)
    }

    private func setTapestryVisible(_ visible: Bool) {
        showingTapestry = visible
        openFileButton.isHidden = !visible
        if visible {
            tapestryRows = LoomTapestry.recentRows(limit: 18)
            tapestryRowsThisMonth = LoomTapestry.rowCount(forMonth: LoomTapestry.monthStamp(for: Date()))
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    @objc private func openFileClicked() {
        NSWorkspace.shared.open(LoomTapestry.defaultFileURL)
    }

    // MARK: - The shimmer

    /// A chained single-shot timer, as in the other games: it exists only for
    /// the length of one pass and only while the panel is on screen.
    private func startShimmer() {
        shimmer = 0
        scheduleShimmerTick()
    }

    private func scheduleShimmerTick() {
        shimmerTimer?.invalidate()
        shimmerTimer = Timer.scheduledTimer(withTimeInterval: Self.shimmerInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let elapsed = self.shimmer else { return }
                let next = elapsed + Self.shimmerInterval
                if next >= Self.shimmerDuration {
                    self.stopShimmer()
                } else {
                    self.shimmer = next
                    self.scheduleShimmerTick()
                }
                self.needsDisplay = true
            }
        }
    }

    private func stopShimmer() {
        shimmerTimer?.invalidate()
        shimmerTimer = nil
        shimmer = nil
    }

    // MARK: - Drawing

    private struct BoardMetrics {
        var cell: CGFloat
        var origin: NSPoint
    }

    private func boardMetrics() -> BoardMetrics? {
        let side = CGFloat(model.side)
        let availableWidth = bounds.width - Self.margin * 2
        let availableHeight = Self.boardBottom - Self.boardTop
        let cell = min(Self.maxCell, (availableWidth / side).rounded(.down), (availableHeight / side).rounded(.down))
        guard cell > 8 else { return nil }
        return BoardMetrics(
            cell: cell,
            origin: NSPoint(
                x: (bounds.width - side * cell) / 2,
                y: Self.boardTop + (availableHeight - side * cell) / 2
            )
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        AppTheme.windowBackground.setFill()
        bounds.fill()

        if showingTapestry {
            drawTapestry()
            drawHint("t back · space back · esc close")
            return
        }

        drawHeader()
        drawBoard()

        if model.isSettled {
            drawCentered("space for a new panel", font: .systemFont(ofSize: 11),
                         color: .tertiaryLabelColor, atY: Self.boardBottom + 8)
            drawHint("space new panel · t tapestry · esc close")
        } else {
            drawHint("arrows move · space turn · t tapestry · esc close")
        }
    }

    private func drawHeader() {
        drawText("loom", at: NSPoint(x: Self.margin, y: 16),
                 font: .systemFont(ofSize: 13, weight: .medium), color: .secondaryLabelColor)
        drawText("panel \(model.panelOrdinal)", at: NSPoint(x: 0, y: 18),
                 font: .monospacedSystemFont(ofSize: 11, weight: .regular),
                 color: .tertiaryLabelColor, rightAlignedTo: bounds.width - Self.margin)
    }

    private func drawBoard() {
        guard let metrics = boardMetrics() else { return }
        let panel = model.panel
        let span = CGFloat(panel.side) * metrics.cell

        NSColor(calibratedWhite: 0.09, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: metrics.origin.x, y: metrics.origin.y, width: span, height: span)
            .insetBy(dx: -8, dy: -8), xRadius: 6, yRadius: 6).fill()

        // The cursor sits under the thread: a soft place-marker, not a demand.
        if !model.isSettled {
            let row = model.cursor / panel.side
            let col = model.cursor % panel.side
            let rect = cellRect(row: row, col: col, metrics: metrics).insetBy(dx: 1.5, dy: 1.5)
            let marker = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            NSColor(calibratedWhite: 1, alpha: 0.05).setFill()
            marker.fill()
            NSColor(calibratedWhite: 1, alpha: 0.16).setStroke()
            marker.lineWidth = 1
            marker.stroke()
        }

        for row in 0..<panel.side {
            for col in 0..<panel.side {
                drawTile(panel.tile(row: row, col: col),
                         in: cellRect(row: row, col: col, metrics: metrics),
                         color: threadColor(row: row, col: col, side: panel.side),
                         width: max(2, metrics.cell * 0.09))
            }
        }
    }

    private func cellRect(row: Int, col: Int, metrics: BoardMetrics) -> NSRect {
        NSRect(x: metrics.origin.x + CGFloat(col) * metrics.cell,
               y: metrics.origin.y + CGFloat(row) * metrics.cell,
               width: metrics.cell, height: metrics.cell)
    }

    /// Unsettled thread is muted; settled thread warms. The shimmer is one
    /// diagonal wavefront crossing the panel once, and it lightens the warm
    /// tone rather than flashing over it.
    private func threadColor(row: Int, col: Int, side: Int) -> NSColor {
        guard model.isSettled else { return Self.unsettledThread }
        guard let elapsed = shimmer, side > 1 else { return Self.settledThread }

        let progress = elapsed / Self.shimmerDuration
        let position = Double(row + col) / Double(2 * (side - 1))
        let boost = max(0, 1 - abs(position - progress) * 5)
        guard boost > 0 else { return Self.settledThread }
        return Self.settledThread.blended(withFraction: CGFloat(boost) * 0.45, of: .white) ?? Self.settledThread
    }

    /// Thread as Core Graphics strokes rather than box-drawing glyphs: at this
    /// panel size a glyph grid reads as a table of characters, while strokes
    /// with round caps and rounded elbows read as thread that meets.
    private func drawTile(_ tile: LoomTile, in rect: NSRect, color: NSColor, width: CGFloat) {
        let mask = tile.mask
        guard mask != 0 else { return }

        color.setStroke()
        color.setFill()

        let center = NSPoint(x: rect.midX, y: rect.midY)
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        if let (first, second) = elbowEdges(mask) {
            // An elbow is one quarter arc tangent to both stubs, so the thread
            // turns the corner instead of denting into it.
            path.move(to: midpoint(of: first, in: rect))
            path.appendArc(from: corner(between: first, and: second, in: rect),
                           to: midpoint(of: second, in: rect),
                           radius: rect.width / 2)
            path.line(to: midpoint(of: second, in: rect))
        } else {
            for edge in LoomEdge.allCases where mask & edge.bit != 0 {
                path.move(to: center)
                path.line(to: midpoint(of: edge, in: rect))
            }
        }
        path.stroke()

        // An end cap's loose end gets a small knob, so a single stub reads as
        // finished rather than as a thread that was cut.
        if mask.nonzeroBitCount == 1 {
            let radius = width * 0.9
            NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                        width: radius * 2, height: radius * 2)).fill()
        }
    }

    /// The two edges of an elbow, in the order that turns clockwise, or nil for
    /// every other piece.
    private func elbowEdges(_ mask: UInt8) -> (LoomEdge, LoomEdge)? {
        guard mask.nonzeroBitCount == 2 else { return nil }
        for edge in LoomEdge.allCases {
            let next = LoomEdge(rawValue: (edge.rawValue + 1) % 4)!
            if mask == edge.bit | next.bit { return (edge, next) }
        }
        return nil // a straight: opposite stubs, no corner to turn
    }

    private func midpoint(of edge: LoomEdge, in rect: NSRect) -> NSPoint {
        switch edge {
        case .north: return NSPoint(x: rect.midX, y: rect.minY)
        case .east: return NSPoint(x: rect.maxX, y: rect.midY)
        case .south: return NSPoint(x: rect.midX, y: rect.maxY)
        case .west: return NSPoint(x: rect.minX, y: rect.midY)
        }
    }

    private func corner(between first: LoomEdge, and second: LoomEdge, in rect: NSRect) -> NSPoint {
        let edges: Set<LoomEdge> = [first, second]
        let x = edges.contains(.east) ? rect.maxX : rect.minX
        let y = edges.contains(.south) ? rect.maxY : rect.minY
        return NSPoint(x: x, y: y)
    }

    // MARK: - The tapestry

    private func drawTapestry() {
        drawText("loom · tapestry", at: NSPoint(x: Self.margin, y: 16),
                 font: .systemFont(ofSize: 13, weight: .medium), color: .secondaryLabelColor)

        let rows = tapestryRowsThisMonth == 1 ? "1 row this month" : "\(tapestryRowsThisMonth) rows this month"
        drawText("panel \(model.panelOrdinal) · \(rows)", at: NSPoint(x: Self.margin, y: 38),
                 font: .monospacedSystemFont(ofSize: 11, weight: .regular), color: .tertiaryLabelColor)

        guard !tapestryRows.isEmpty else {
            drawCentered("Nothing woven yet. Settled panels land in ~/.config/cortland/loom-tapestry.md.",
                         font: .systemFont(ofSize: 12), color: .tertiaryLabelColor, atY: bounds.midY)
            return
        }

        let font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        let lineHeight: CGFloat = 17
        let visible = tapestryRows.suffix(Int((bounds.height - 140) / lineHeight))
        var y = bounds.height - 54 - CGFloat(visible.count) * lineHeight
        for row in visible {
            drawCentered(row, font: font, color: Self.settledThread.withAlphaComponent(0.85), atY: y)
            y += lineHeight
        }
    }

    // MARK: - Text helpers

    private func drawHint(_ text: String) {
        drawText(text, at: NSPoint(x: Self.margin, y: bounds.height - 18),
                 font: .systemFont(ofSize: 10), color: .tertiaryLabelColor)
    }

    private func drawText(_ string: String, at point: NSPoint, font: NSFont, color: NSColor,
                          rightAlignedTo rightEdge: CGFloat? = nil) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        var origin = point
        if let rightEdge {
            origin.x = rightEdge - (string as NSString).size(withAttributes: attributes).width
        }
        (string as NSString).draw(at: origin, withAttributes: attributes)
    }

    private func drawCentered(_ string: String, font: NSFont, color: NSColor, atY y: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (string as NSString).size(withAttributes: attributes)
        (string as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: y), withAttributes: attributes)
    }
}
