import Cocoa

/// The Grove playfield: a bonsai in text that grows very slowly in real time.
/// Opening it never asks for anything. You might prune a branch, bend one a
/// few degrees, plant a seed, or just look. It cannot die and there is no
/// right shape; over weeks it becomes a thing you quietly shaped by taking
/// breaks. Untimed, so like the other calm games there is nothing to pause.
final class GroveView: NSView, ArcadeGame {
    static let gameID = "grove"
    static let title = "The Grove"
    static let howToPlay = """
    Shape a bonsai that grows slowly while you are away. There is no score and the tree cannot die. If the grove is bare, press 1 for pine, 2 for maple, or 3 for willow.

    ← →  Select a branch
    [ ]  Bend the selected branch
    X twice  Prune the selected branch
    ⌘N twice  Clear it and start a new grove
    Esc  Close the arcade
    """

    private static let contentSize = BlocksGameView.contentSize
    private static let margin: CGFloat = 16
    private static let headerHeight: CGFloat = 44
    private static let hintHeight: CGFloat = 24

    private let tree: GroveTree
    /// Set to the selected branch when X has been pressed once; a second X on
    /// the same branch prunes. Any other action disarms it.
    private var pruneArmedID: Int?
    /// True once ⌘N has been pressed once; a second ⌘N starts a new grove.
    private var newGroveArmed = false

    var onCloseRequested: (() -> Void)?

    // MARK: - Bark, leaf, earth palette (muted; nothing neon)

    private static let barkDark = NSColor(calibratedRed: 0.34, green: 0.26, blue: 0.19, alpha: 1)
    private static let barkMid = NSColor(calibratedRed: 0.46, green: 0.35, blue: 0.25, alpha: 1)
    private static let barkLight = NSColor(calibratedRed: 0.55, green: 0.43, blue: 0.31, alpha: 1)
    private static let blossomColor = NSColor(calibratedRed: 0.90, green: 0.70, blue: 0.80, alpha: 1)
    private static let earthColor = NSColor(calibratedRed: 0.40, green: 0.31, blue: 0.23, alpha: 1)
    private static let potColor = NSColor(calibratedRed: 0.52, green: 0.38, blue: 0.28, alpha: 1)

    private static func greens(for species: GroveSpecies) -> [NSColor] {
        switch species {
        case .pine:
            return [NSColor(calibratedRed: 0.20, green: 0.40, blue: 0.28, alpha: 1),
                    NSColor(calibratedRed: 0.28, green: 0.50, blue: 0.34, alpha: 1),
                    NSColor(calibratedRed: 0.24, green: 0.45, blue: 0.30, alpha: 1)]
        case .maple:
            return [NSColor(calibratedRed: 0.34, green: 0.52, blue: 0.26, alpha: 1),
                    NSColor(calibratedRed: 0.45, green: 0.60, blue: 0.28, alpha: 1),
                    NSColor(calibratedRed: 0.40, green: 0.56, blue: 0.27, alpha: 1)]
        case .willow:
            return [NSColor(calibratedRed: 0.42, green: 0.54, blue: 0.32, alpha: 1),
                    NSColor(calibratedRed: 0.52, green: 0.63, blue: 0.38, alpha: 1),
                    NSColor(calibratedRed: 0.47, green: 0.58, blue: 0.35, alpha: 1)]
        }
    }

    // MARK: - ArcadeGame

    init(savedState: Data?) {
        let state = savedState.flatMap { try? JSONDecoder().decode(GroveState.self, from: $0) } ?? .empty
        tree = GroveTree(state: state)
        super.init(frame: NSRect(origin: .zero, size: Self.contentSize))
        tree.applyElapsedGrowth(now: Date())
        normalizeSelection()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    var view: NSView { self }

    func pause() {
        // Untimed; growth is derived from wall-clock on open, nothing runs while hidden.
    }

    func resume() {
        tree.applyElapsedGrowth(now: Date())
        normalizeSelection()
        needsDisplay = true
    }

    func encodeState() -> Data? {
        try? JSONEncoder().encode(tree.snapshot())
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func becomeFirstResponder() -> Bool {
        // Growth catches up whenever the panel hands us focus, so simply
        // looking (without pressing a key) still shows the latest tree.
        tree.applyElapsedGrowth(now: Date())
        normalizeSelection()
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    // MARK: - Input

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        // ⌘N: new grove, with a double-press confirm so it can't happen by accident.
        if modifiers == .command, event.keyCode == 45, !tree.isEmpty {
            if newGroveArmed {
                startNewGrove()
            } else {
                newGroveArmed = true
                pruneArmedID = nil
                needsDisplay = true
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if event.keyCode == 53 || (event.keyCode == 50 && modifiers == .control) {
            onCloseRequested?()
            return
        }

        tree.applyElapsedGrowth(now: Date())
        normalizeSelection()
        needsDisplay = true // a keypress may itself have crossed a growth tick

        if tree.isEmpty {
            handlePlantKey(event)
            return
        }
        handleTreeKey(event, modifiers: modifiers)
    }

    private func handlePlantKey(_ event: NSEvent) {
        let species: GroveSpecies?
        switch event.keyCode {
        case 18: species = .pine   // 1
        case 19: species = .maple  // 2
        case 20: species = .willow // 3
        default: species = nil
        }
        guard let species else {
            super.keyDown(with: event)
            return
        }
        tree.plant(species: species, seed: UInt64.random(in: UInt64.min...UInt64.max), now: Date())
        GroveLog.recordPlanting(species: species, date: Date())
        newGroveArmed = false
        pruneArmedID = nil
        needsDisplay = true
    }

    private func handleTreeKey(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) {
        // Any key that isn't a second ⌘N disarms the new-grove confirmation.
        newGroveArmed = false

        switch event.keyCode {
        case 123: // left
            moveSelection(by: -1)
            pruneArmedID = nil
        case 124: // right
            moveSelection(by: 1)
            pruneArmedID = nil
        case 7: // X: prune (double-press on the same branch)
            handlePrune()
        case 33: // [
            trainSelected(by: -1)
            pruneArmedID = nil
        case 30: // ]
            trainSelected(by: 1)
            pruneArmedID = nil
        default:
            super.keyDown(with: event)
            return
        }
        needsDisplay = true
    }

    // MARK: - Actions

    private func moveSelection(by delta: Int) {
        let ids = tree.selectableSegmentIDs()
        guard !ids.isEmpty else { return }
        let current = tree.selectedSegmentID.flatMap { ids.firstIndex(of: $0) } ?? 0
        let next = (current + delta + ids.count) % ids.count
        tree.selectedSegmentID = ids[next]
    }

    private func handlePrune() {
        guard let selected = tree.selectedSegmentID else { return }
        if pruneArmedID == selected {
            tree.prune(segmentID: selected)
            pruneArmedID = nil
            normalizeSelection()
        } else {
            pruneArmedID = selected
        }
    }

    private func trainSelected(by direction: Double) {
        guard let selected = tree.selectedSegmentID else { return }
        tree.train(segmentID: selected, direction: direction)
    }

    private func startNewGrove() {
        GroveLog.recordClearing(species: tree.species, date: Date())
        tree.clear()
        newGroveArmed = false
        pruneArmedID = nil
        needsDisplay = true
    }

    /// Keeps `selectedSegmentID` pointing at something still selectable after
    /// growth or pruning has reshaped the canopy.
    private func normalizeSelection() {
        let ids = tree.selectableSegmentIDs()
        guard !ids.isEmpty else {
            tree.selectedSegmentID = nil
            return
        }
        if let selected = tree.selectedSegmentID, ids.contains(selected) { return }
        tree.selectedSegmentID = ids.first
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        AppTheme.windowBackground.setFill()
        bounds.fill()

        if tree.isEmpty {
            drawPlantScreen()
        } else {
            drawHeader()
            drawGrove()
        }
        drawHint()
    }

    private func drawPlantScreen() {
        drawCentered("your grove is bare", font: .systemFont(ofSize: 20, weight: .medium),
                     color: .labelColor, dy: -18)
        drawCentered("press  1 pine   2 maple   3 willow", font: .systemFont(ofSize: 13),
                     color: .secondaryLabelColor, dy: 14)
        drawCentered("or just close it and come back later",
                     font: .systemFont(ofSize: 11), color: .tertiaryLabelColor, dy: 40)
    }

    private func drawHeader() {
        guard let species = tree.species else { return }
        let days = tree.daysSincePlanting(now: Date())
        let age = days == 0 ? "planted today" : days == 1 ? "planted 1 day ago" : "planted \(days) days ago"
        drawText(species.displayName, at: NSPoint(x: Self.margin, y: 12),
                 font: .systemFont(ofSize: 16, weight: .semibold), color: .labelColor)
        drawText(age, at: NSPoint(x: Self.margin, y: 34),
                 font: .systemFont(ofSize: 11), color: .secondaryLabelColor)

        if newGroveArmed {
            drawText("press ⌘N again to start a new grove", at: NSPoint(x: 0, y: 12),
                     font: .systemFont(ofSize: 11, weight: .medium), color: Self.blossomColor,
                     rightAlignedTo: bounds.width - Self.margin)
        } else if pruneArmedID != nil {
            drawText("press x again to prune", at: NSPoint(x: 0, y: 12),
                     font: .systemFont(ofSize: 11, weight: .medium), color: .secondaryLabelColor,
                     rightAlignedTo: bounds.width - Self.margin)
        }
    }

    private func drawGrove() {
        let grid = GroveRasterizer.rasterize(tree, highlightedID: tree.selectedSegmentID)
        let metrics = gridMetrics()
        let font = NSFont.monospacedSystemFont(ofSize: metrics.fontSize, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let greens = tree.species.map(Self.greens) ?? []

        for row in 0..<grid.rows {
            for col in 0..<grid.cols {
                guard let cell = grid[col, row] else { continue }
                let color = self.color(for: cell, greens: greens)
                let point = NSPoint(
                    x: metrics.origin.x + CGFloat(col) * metrics.cellWidth,
                    y: metrics.origin.y + CGFloat(row) * metrics.cellHeight
                )
                var attrs = attributes
                attrs[.foregroundColor] = color
                (String(cell.char) as NSString).draw(at: point, withAttributes: attrs)
            }
        }
    }

    private func color(for cell: GroveCell, greens: [NSColor]) -> NSColor {
        let base: NSColor
        switch cell.kind {
        case .trunk:
            base = Self.barkDark
        case .branch:
            base = [Self.barkMid, Self.barkLight, Self.barkMid][cell.shade % 3]
        case .foliage:
            base = greens.isEmpty ? Self.barkMid : greens[cell.shade % greens.count]
        case .blossom:
            base = Self.blossomColor
        case .ground:
            base = Self.earthColor
        case .pot:
            base = Self.potColor
        }
        // Selected branch reads brighter, not neon: a gentle lift toward white.
        return cell.highlighted ? base.blended(withFraction: 0.4, of: .white) ?? base : base
    }

    private struct GridMetrics {
        var fontSize: CGFloat
        var cellWidth: CGFloat
        var cellHeight: CGFloat
        var origin: NSPoint
    }

    private func gridMetrics() -> GridMetrics {
        let availWidth = bounds.width - Self.margin * 2
        let availHeight = bounds.height - Self.headerHeight - Self.hintHeight
        let cols = CGFloat(GroveGeometry.cols)
        let rows = CGFloat(GroveGeometry.rows)

        // Largest monospaced size whose advance keeps 52 columns inside the
        // width and whose line height keeps 30 rows inside the height.
        var fontSize: CGFloat = 8
        var advance: CGFloat = 5
        var lineHeight: CGFloat = 10
        for candidate in stride(from: CGFloat(20), through: 8, by: -0.5) {
            let w = ArcadeTypography.monospacedAdvance(ofSize: candidate, weight: .regular)
            let h = candidate * 1.18
            if w * cols <= availWidth && h * rows <= availHeight {
                fontSize = candidate
                advance = w
                lineHeight = h
                break
            }
        }

        let gridWidth = advance * cols
        let gridHeight = lineHeight * rows
        let origin = NSPoint(
            x: Self.margin + (availWidth - gridWidth) / 2,
            y: Self.headerHeight + (availHeight - gridHeight) / 2
        )
        return GridMetrics(fontSize: fontSize, cellWidth: advance, cellHeight: lineHeight, origin: origin)
    }

    private func drawHint() {
        let hint = tree.isEmpty
            ? "1/2/3 plant · esc close"
            : "← → select · x x prune · [ ] bend · ⌘n new grove · esc close"
        drawText(hint, at: NSPoint(x: Self.margin, y: bounds.height - 18),
                 font: .systemFont(ofSize: 10), color: .tertiaryLabelColor)
    }

    // MARK: - Text helpers

    private func drawText(_ string: String, at point: NSPoint, font: NSFont, color: NSColor, rightAlignedTo rightEdge: CGFloat? = nil) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        var origin = point
        if let rightEdge {
            origin.x = rightEdge - (string as NSString).size(withAttributes: attributes).width
        }
        (string as NSString).draw(at: origin, withAttributes: attributes)
    }

    private func drawCentered(_ string: String, font: NSFont, color: NSColor, dy: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (string as NSString).size(withAttributes: attributes)
        let origin = NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2 + dy)
        (string as NSString).draw(at: origin, withAttributes: attributes)
    }
}
