import Cocoa

/// Slow Cartography: mapping a coastline by hand, a few pen strokes per visit.
/// Drag to trace a bit of shore; the generated world is invisible until drawn,
/// so the map is only ever what you have surveyed. Name a bay whatever you
/// like. The pen holds a little ink per visit and refills on open; nothing is
/// lost and nothing counts down. The accumulating chart is the keepsake.
final class CartographyView: NSView, ArcadeGame, NSTextFieldDelegate {
    static let gameID = "cartography"
    static let title = "Slow Cartography"
    static let howToPlay = """
    Survey a hidden coastline a few pen strokes at a time. Drag across the sheet to reveal the world. Your limited ink refills whenever you reopen the arcade, and the chart stays with you.

    Drag  Survey the map
    N or the Name button  Start naming, then click a revealed place or the title
    Return  Save a name
    ⌘E or the Export button  Add the sheet to atlas.md
    Esc  Cancel naming, or close the arcade
    """

    private static let contentSize = BlocksGameView.contentSize
    private static let margin: CGFloat = 14
    private static let headerHeight: CGFloat = 46
    private static let footerHeight: CGFloat = 40

    private let model: CartographyModel

    /// What an open naming field is attached to: a cell on the sheet, or the
    /// sheet's own title.
    private enum EditTarget: Equatable {
        case cell(Int)
        case title
    }

    /// Naming has two moments: armed (waiting for a click) and editing (a field
    /// is open). Esc backs out of either without closing the panel.
    private var namingArmed = false
    private var editTarget: EditTarget?
    private var nameField: NSTextField?

    private var editingCell: Int? {
        if case .cell(let cell) = editTarget { return cell }
        return nil
    }

    private var lastDragCell: (x: Int, y: Int)?

    private let nameButton = NSButton(title: "name", target: nil, action: nil)
    private let exportButton = NSButton(title: "export", target: nil, action: nil)

    var onCloseRequested: (() -> Void)?

    // MARK: - Ink-on-paper palette (muted; dark background)

    private static let seaColor = NSColor(calibratedRed: 0.34, green: 0.44, blue: 0.55, alpha: 0.72)
    private static let lowlandColor = NSColor(calibratedRed: 0.60, green: 0.54, blue: 0.42, alpha: 1)
    private static let uplandColor = NSColor(calibratedRed: 0.66, green: 0.58, blue: 0.44, alpha: 1)
    private static let hillColor = NSColor(calibratedRed: 0.72, green: 0.62, blue: 0.45, alpha: 1)
    private static let coastColor = NSColor(calibratedRed: 0.87, green: 0.81, blue: 0.66, alpha: 1)
    private static let inkColor = NSColor(calibratedRed: 0.78, green: 0.72, blue: 0.58, alpha: 1)

    // MARK: - ArcadeGame

    init(savedState: Data?) {
        let state = savedState.flatMap { try? JSONDecoder().decode(CartographyState.self, from: $0) }
        model = CartographyModel(state: state ?? CartographyModel.freshState(seed: UInt64.random(in: UInt64.min...UInt64.max)))
        super.init(frame: NSRect(origin: .zero, size: Self.contentSize))
        model.refillInk() // opening the sheet refills the pen
        buildButtons()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    var view: NSView { self }

    func pause() {
        // Untimed; nothing runs while hidden. The sheet is captured by encodeState.
    }

    func resume() {
        model.refillInk()
        needsDisplay = true
    }

    func encodeState() -> Data? {
        try? JSONEncoder().encode(model.snapshot())
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The pen refills whenever the hosting panel becomes key: summoning
        // the arcade or clicking back into it is a fresh visit. This cannot
        // ride on first-responder handoff — the game view stays first
        // responder while the panel is hidden, so makeFirstResponder on
        // reopen is a no-op and a dry pen would stay dry forever.
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didBecomeKeyNotification, object: nil
        )
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hostWindowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
    }

    @objc private func hostWindowDidBecomeKey() {
        model.refillInk()
        needsDisplay = true
    }

    // MARK: - Buttons

    private func buildButtons() {
        for button in [nameButton, exportButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.target = self
            addSubview(button)
        }
        nameButton.action = #selector(nameButtonClicked)
        exportButton.action = #selector(exportButtonClicked)
        nameButton.frame = NSRect(x: bounds.width - 150, y: 12, width: 66, height: 22)
        exportButton.frame = NSRect(x: bounds.width - 78, y: 12, width: 66, height: 22)
    }

    @objc private func nameButtonClicked() {
        enterNamingMode()
        window?.makeFirstResponder(self)
    }

    @objc private func exportButtonClicked() {
        exportSheet()
    }

    // MARK: - Input

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        // Control-backtick closes from any state, including while the name
        // field has focus (this fires before the field editor sees the key).
        if event.keyCode == 50, modifiers == .control {
            onCloseRequested?()
            return true
        }
        if modifiers == .command, event.keyCode == 14 { // ⌘E
            exportSheet()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if event.keyCode == 50, modifiers == .control {
            onCloseRequested?()
            return
        }

        // Esc: while naming (armed here; the editing field handles its own Esc)
        // it backs out of naming and must NOT close the panel. Only Esc with no
        // naming underway closes.
        if event.keyCode == 53 {
            if namingArmed {
                cancelNaming()
            } else {
                onCloseRequested?()
            }
            return
        }

        switch event.keyCode {
        case 45: // N
            enterNamingMode()
        default:
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)

        if namingArmed {
            // Clicking the title renames the sheet; clicking a revealed cell
            // names that place. Both are the naming flow.
            if titleRect().contains(point) {
                beginEditing(.title, prefill: model.title, anchor: NSPoint(x: Self.margin, y: 8))
            } else if let cell = cellAt(point) {
                beginEditing(.cell(CartographyWorld.index(cell.x, cell.y)),
                             prefill: model.nameAnchored(at: CartographyWorld.index(cell.x, cell.y))?.text ?? "",
                             anchor: cellAnchorPoint(x: cell.x, y: cell.y))
            }
            return
        }
        guard let cell = cellAt(point) else { return }
        // A plain click or the start of a drag is a pen stroke.
        model.reveal(along: [cell])
        lastDragCell = cell
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !namingArmed else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let cell = cellAt(point) else { return }
        let path = lastDragCell.map { CartographyModel.line(from: $0, to: cell) } ?? [cell]
        model.reveal(along: path)
        lastDragCell = cell
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        lastDragCell = nil
    }

    // MARK: - Naming flow

    private func enterNamingMode() {
        guard nameField == nil else { return }
        namingArmed = true
        needsDisplay = true
    }

    private func cancelNaming() {
        namingArmed = false
        teardownNameField()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func beginEditing(_ target: EditTarget, prefill: String, anchor: NSPoint) {
        namingArmed = false
        teardownNameField()
        editTarget = target

        let width: CGFloat = 130
        let field = NSTextField(frame: NSRect(
            x: min(max(Self.margin, anchor.x), bounds.width - Self.margin - width),
            y: anchor.y, width: width, height: 20
        ))
        field.font = Self.serifFont(size: 13, weight: .regular)
        field.stringValue = prefill
        field.placeholderString = target == .title ? "title" : "name it"
        field.delegate = self
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        addSubview(field)
        nameField = field
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        needsDisplay = true
    }

    private func commitName() {
        if let target = editTarget, let field = nameField {
            switch target {
            case .cell(let cell): model.placeName(cell: cell, text: field.stringValue)
            case .title: model.setTitle(field.stringValue)
            }
        }
        namingArmed = false
        teardownNameField()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func teardownNameField() {
        nameField?.removeFromSuperview()
        nameField = nil
        editTarget = nil
    }

    private func cellAnchorPoint(x: Int, y: Int) -> NSPoint {
        let metrics = gridMetrics()
        return NSPoint(
            x: metrics.origin.x + CGFloat(x) * metrics.cellWidth,
            y: metrics.origin.y + CGFloat(y) * metrics.cellHeight - 10
        )
    }

    /// The clickable bounds of the header title, for the rename-the-sheet path.
    private func titleRect() -> NSRect {
        let font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        let width = (model.title as NSString).size(withAttributes: [.font: font]).width
        return NSRect(x: Self.margin, y: 6, width: max(60, width) + 8, height: 24)
    }

    // MARK: - NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            commitName()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // Esc in the field cancels naming only. It must never close the panel.
            cancelNaming()
            return true
        default:
            return false
        }
    }

    // MARK: - Export

    private func exportSheet() {
        CartographyAtlas.export(
            title: model.title,
            mapRows: model.mapTextRows(),
            names: model.names,
            date: Date()
        )
        needsDisplay = true
    }

    // MARK: - Grid geometry

    private struct GridMetrics {
        var fontSize: CGFloat
        var cellWidth: CGFloat
        var cellHeight: CGFloat
        var origin: NSPoint
    }

    private func gridMetrics() -> GridMetrics {
        let availWidth = bounds.width - Self.margin * 2
        let availHeight = bounds.height - Self.headerHeight - Self.footerHeight
        let cols = CGFloat(CartographyWorld.width)
        let rows = CGFloat(CartographyWorld.height)

        var fontSize: CGFloat = 8
        var advance: CGFloat = 5
        var lineHeight: CGFloat = 10
        for candidate in stride(from: CGFloat(14), through: 6, by: -0.5) {
            let w = ArcadeTypography.monospacedAdvance(ofSize: candidate, weight: .regular)
            let h = candidate * 1.16
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

    private func cellAt(_ point: NSPoint) -> (x: Int, y: Int)? {
        let metrics = gridMetrics()
        let x = Int(floor((point.x - metrics.origin.x) / metrics.cellWidth))
        let y = Int(floor((point.y - metrics.origin.y) / metrics.cellHeight))
        guard CartographyWorld.inBounds(x, y) else { return nil }
        return (x, y)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        AppTheme.windowBackground.setFill()
        bounds.fill()
        drawHeader()
        drawSheet()
        drawNames()
        drawCaption()
        drawHint()
    }

    private func drawHeader() {
        drawText(model.title, at: NSPoint(x: Self.margin, y: 10),
                 font: .systemFont(ofSize: 15, weight: .semibold), color: .labelColor)
        drawText(model.progressDescription, at: NSPoint(x: Self.margin, y: 30),
                 font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
    }

    private func drawSheet() {
        let metrics = gridMetrics()
        let font = NSFont.monospacedSystemFont(ofSize: metrics.fontSize, weight: .regular)
        let coastFont = NSFont.monospacedSystemFont(ofSize: metrics.fontSize, weight: .bold)

        for y in 0..<CartographyWorld.height {
            for x in 0..<CartographyWorld.width {
                guard let glyph = model.glyph(x, y) else { continue }
                let (char, color, isCoast) = style(for: glyph, x: x, y: y)
                let point = NSPoint(
                    x: metrics.origin.x + CGFloat(x) * metrics.cellWidth,
                    y: metrics.origin.y + CGFloat(y) * metrics.cellHeight
                )
                (String(char) as NSString).draw(at: point, withAttributes: [
                    .font: isCoast ? coastFont : font,
                    .foregroundColor: color
                ])
            }
        }
    }

    /// The glyph, ink, and whether to embolden it. Sea is scattered by a
    /// seeded hash so it reads hand-inked rather than tiled; the coastline is
    /// picked out brighter and heavier, the reward of the whole game.
    private func style(for glyph: MapGlyph, x: Int, y: Int) -> (Character, NSColor, Bool) {
        switch glyph {
        case .sea:
            let hash = (x &* 73856093) ^ (y &* 19349663) ^ Int(truncatingIfNeeded: model.world.seed)
            return (hash & 3 == 0 ? "~" : "·", Self.seaColor, false)
        case .lowland: return (".", Self.lowlandColor, false)
        case .upland: return (":", Self.uplandColor, false)
        case .hill: return ("^", Self.hillColor, false)
        case .coast: return ("*", Self.coastColor, true)
        }
    }

    private func drawNames() {
        let metrics = gridMetrics()
        let font = Self.serifFont(size: max(11, metrics.fontSize + 1), weight: .regular)
        let sheetRect = NSRect(
            x: metrics.origin.x, y: metrics.origin.y,
            width: metrics.cellWidth * CGFloat(CartographyWorld.width),
            height: metrics.cellHeight * CGFloat(CartographyWorld.height)
        )

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: sheetRect.insetBy(dx: -2, dy: -2)).addClip()
        for name in model.names where name.cell != editingCell {
            let x = name.cell % CartographyWorld.width
            let y = name.cell / CartographyWorld.width
            let point = NSPoint(
                x: metrics.origin.x + CGFloat(x) * metrics.cellWidth,
                y: metrics.origin.y + CGFloat(y) * metrics.cellHeight - 2
            )
            (name.text as NSString).draw(at: point, withAttributes: [
                .font: font, .foregroundColor: Self.inkColor
            ])
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawCaption() {
        let caption: String?
        if namingArmed {
            caption = "click a cell to name it, or the title to rename the sheet"
        } else if model.isDry {
            caption = "the pen is dry; it refills when you come back"
        } else {
            caption = nil
        }
        guard let caption else { return }
        drawCentered(caption, font: .systemFont(ofSize: 11, weight: .medium),
                     color: Self.inkColor, y: bounds.height - 34)
    }

    private func drawHint() {
        drawText("drag to survey · n name · ⌘e export · esc close",
                 at: NSPoint(x: Self.margin, y: bounds.height - 18),
                 font: .systemFont(ofSize: 10), color: .tertiaryLabelColor)
    }

    // MARK: - Text helpers

    private static func serifFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        let italic = descriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: italic, size: size) ?? NSFont(descriptor: descriptor, size: size) ?? base
    }

    private func drawText(_ string: String, at point: NSPoint, font: NSFont, color: NSColor) {
        (string as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }

    private func drawCentered(_ string: String, font: NSFont, color: NSColor, y: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (string as NSString).size(withAttributes: attributes)
        (string as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: y), withAttributes: attributes)
    }
}
