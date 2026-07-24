import Cocoa

/// The Keysmith playfield: a typing trainer of five stop-on-error lines per
/// run. Renders the current line in the app's monospaced style with the typed
/// prefix dimmed, the target character ringed, and a red flash on a miss;
/// between runs a results banner reports the run's WPM and accuracy against the
/// tier best. Like Depth Ladder there is no running clock to pause: each line's
/// timer starts on its first keystroke, so summoning the panel never costs a
/// keystroke.
final class KeysmithView: NSView, ArcadeGame {
    static let gameID = "keysmith"
    static let title = "Keysmith"
    static let howToPlay = """
    Type the displayed line exactly. A wrong key flashes red and does not advance, so correct it by typing the expected character. A five-line run reports your speed and accuracy.

    Type  Enter the highlighted character
    Tab  Cycle difficulty tiers
    1 / 2 / 3  Choose Letters, Words, or Code
    Any key after results  Start another run
    Esc  Close the arcade
    """

    private let game: KeysmithGame
    private var results: KeysmithRunSummary?
    private var showingResults = false
    private var isFlashing = false
    private var flashTimer: Timer?

    var onCloseRequested: (() -> Void)?

    // Same footprint as BlocksGameView so switching games never resizes the panel.
    private static let contentSize = BlocksGameView.contentSize
    private static let margin: CGFloat = 16
    private static let boardTop: CGFloat = 64
    private static let boardBottom: CGFloat = 500

    private static let cursorColor = NSColor(calibratedRed: 0.95, green: 0.79, blue: 0.20, alpha: 1)

    // MARK: - ArcadeGame

    init(savedState: Data?) {
        let saved = savedState.flatMap { try? JSONDecoder().decode(KeysmithState.self, from: $0) }
        game = saved.map(KeysmithGame.init(state:)) ?? KeysmithGame()
        super.init(frame: NSRect(origin: .zero, size: Self.contentSize))
        // Always open onto a line to type: a stale finished run resets, and a
        // run restored mid-flight restarts the line it abandoned on hide.
        if game.isRunComplete {
            game.beginRun(seed: Self.randomSeed())
        } else if !game.hasLineUnderway {
            game.beginLine(seed: Self.randomSeed())
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    var view: NSView { self }

    func pause() {
        flashTimer?.invalidate()
        flashTimer = nil
        isFlashing = false
        // Hiding mid-line abandons it without penalty; it restarts on resume.
        game.abandonLine()
    }

    func resume() {
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
        // Esc and ⌃` close the panel — checked before character handling, since
        // space and letters are gameplay input here.
        if event.keyCode == 53 || (event.keyCode == 50 && modifiers == .control) {
            onCloseRequested?()
            return
        }

        // Tab cycles tiers.
        if event.keyCode == 48 {
            switchTier(to: game.tier.next)
            return
        }

        // Command/control chords are shortcuts, not typing; letting them
        // through would charge phantom misses against the expected key.
        if modifiers.contains(.command) || modifiers.contains(.control) {
            super.keyDown(with: event)
            return
        }

        guard let characters = event.characters, let character = characters.first else {
            super.keyDown(with: event)
            return
        }

        // Between runs any key starts the next run.
        if showingResults {
            showingResults = false
            results = nil
            game.beginRun(seed: Self.randomSeed())
            needsDisplay = true
            return
        }

        // Bare 1/2/3 jump straight to a tier; the corpora carry no bare digits,
        // so this never collides with line input.
        if modifiers.isEmpty, let tier = Self.tier(forDigit: character) {
            switchTier(to: tier)
            return
        }

        // Arrows, F-keys, delete, and return are navigation, not typing;
        // counting them as misses would poison the per-key stats.
        guard let scalar = character.unicodeScalars.first,
              !(0xF700...0xF8FF).contains(scalar.value),
              scalar.value >= 0x20, scalar.value != 0x7F else {
            super.keyDown(with: event)
            return
        }

        handleTyped(character)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    private func switchTier(to tier: KeysmithTier) {
        guard tier != game.tier else { return }
        cancelFlash()
        showingResults = false
        results = nil
        game.selectTier(tier)
        game.beginLine(seed: Self.randomSeed())
        needsDisplay = true
    }

    private func handleTyped(_ character: Character) {
        guard game.hasLineUnderway else { return }
        switch game.type(character, at: Date()) {
        case .advanced:
            cancelFlash()
        case .mistake:
            flashMiss()
        case .lineCompleted:
            cancelFlash()
            game.beginLine(seed: Self.randomSeed())
        case .runCompleted(let summary):
            cancelFlash()
            results = summary
            showingResults = true
        case .ignored:
            break
        }
        needsDisplay = true
    }

    private func flashMiss() {
        isFlashing = true
        flashTimer?.invalidate()
        flashTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isFlashing = false
                self.flashTimer = nil
                self.needsDisplay = true
            }
        }
    }

    private func cancelFlash() {
        isFlashing = false
        flashTimer?.invalidate()
        flashTimer = nil
    }

    private static func tier(forDigit character: Character) -> KeysmithTier? {
        switch character {
        case "1": return .letters
        case "2": return .words
        case "3": return .code
        default: return nil
        }
    }

    private static func randomSeed() -> UInt64 {
        .random(in: UInt64.min...UInt64.max)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        AppTheme.windowBackground.setFill()
        bounds.fill()
        drawHeader()

        if !showingResults {
            drawLine()
        }
        drawResultsIfNeeded()

        drawText(
            "type the line   tab or 1/2/3 switch tier   esc close",
            at: NSPoint(x: Self.margin, y: Self.boardBottom + 14),
            font: .systemFont(ofSize: 10),
            color: .tertiaryLabelColor
        )
    }

    private func drawHeader() {
        // Tier tabs, active one bright and bold.
        var x = Self.margin
        for tier in KeysmithTier.allCases {
            let active = tier == game.tier
            let font = NSFont.systemFont(ofSize: active ? 15 : 13, weight: active ? .bold : .regular)
            let color: NSColor = active ? .labelColor : .tertiaryLabelColor
            drawText(tier.title, at: NSPoint(x: x, y: active ? 12 : 14), font: font, color: color)
            let measured = (tier.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .bold)])
            x += measured.width + 16
        }

        let best = "BEST \(Self.wpmText(game.tierBestWPM)) · \(Self.accuracyText(game.tierBestAccuracy))"
        drawText(best, at: NSPoint(x: 0, y: 14), font: .systemFont(ofSize: 11, weight: .medium), color: .secondaryLabelColor, rightAlignedTo: bounds.width - Self.margin)

        let live = "\(Self.wpmText(game.liveWPM(at: Date()))) · \(Self.accuracyText(game.liveAccuracy))"
        drawText(live, at: NSPoint(x: Self.margin, y: 40), font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor)

        let progress = "LINE \(min(game.lineNumber, KeysmithGame.linesPerRun))/\(KeysmithGame.linesPerRun)"
        drawText(progress, at: NSPoint(x: 0, y: 42), font: .systemFont(ofSize: 11, weight: .medium), color: .secondaryLabelColor, rightAlignedTo: bounds.width - Self.margin)
    }

    private func drawLine() {
        let chars = game.line
        guard !chars.isEmpty else { return }

        let font = NSFont.monospacedSystemFont(ofSize: 20, weight: .medium)
        let advance = ArcadeTypography.monospacedAdvance(ofSize: 20, weight: .medium)
        let lineHeight: CGFloat = 34
        let maxWidth = bounds.width - Self.margin * 2
        let perRow = max(1, Int(maxWidth / advance))
        let rows = max(1, Int((Double(chars.count) / Double(perRow)).rounded(.up)))

        let boardMidY = Self.boardTop + (Self.boardBottom - Self.boardTop) / 2
        let startY = boardMidY - CGFloat(rows) * lineHeight / 2
        let startX = bounds.midX - CGFloat(perRow) * advance / 2

        for (index, character) in chars.enumerated() {
            let row = index / perRow
            let col = index % perRow
            let cell = NSRect(
                x: startX + CGFloat(col) * advance,
                y: startY + CGFloat(row) * lineHeight,
                width: advance,
                height: lineHeight
            )
            let isCursor = index == game.cursor

            if isCursor {
                let box = cell.insetBy(dx: 1, dy: 3)
                if isFlashing {
                    NSColor.systemRed.setFill()
                    NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
                } else {
                    Self.cursorColor.setStroke()
                    let ring = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
                    ring.lineWidth = 2
                    ring.stroke()
                }
            }

            let color: NSColor
            if index < game.cursor {
                color = .tertiaryLabelColor
            } else if isCursor {
                color = isFlashing ? .white : .labelColor
            } else {
                color = .secondaryLabelColor
            }
            drawGlyph(character, in: cell, font: font, color: color)
        }
    }

    private func drawResultsIfNeeded() {
        guard showingResults, let results else { return }

        NSColor(calibratedWhite: 0, alpha: 0.55).setFill()
        NSRect(x: Self.margin, y: Self.boardTop, width: bounds.width - Self.margin * 2, height: Self.boardBottom - Self.boardTop).fill()

        drawCenteredText("RUN COMPLETE", font: .systemFont(ofSize: 20, weight: .bold), color: .white, dy: -44)
        drawCenteredText(
            "\(Self.wpmText(results.wpm)) · \(Self.accuracyText(results.accuracy))",
            font: .monospacedSystemFont(ofSize: 22, weight: .medium),
            color: .white,
            dy: -8
        )

        let record: String
        let beatSomething = results.setWPMRecord || results.setAccuracyRecord
        if results.setWPMRecord && results.setAccuracyRecord {
            record = "new best speed and accuracy"
        } else if results.setWPMRecord {
            record = "new best speed"
        } else if results.setAccuracyRecord {
            record = "new best accuracy"
        } else {
            record = "best \(Self.wpmText(results.bestWPM)) · \(Self.accuracyText(results.bestAccuracy))"
        }
        drawCenteredText(
            record,
            font: .systemFont(ofSize: 12, weight: beatSomething ? .semibold : .regular),
            color: beatSomething ? Self.cursorColor : NSColor(calibratedWhite: 1, alpha: 0.7),
            dy: 24
        )
        drawCenteredText("press any key for another run", font: .systemFont(ofSize: 12), color: NSColor(calibratedWhite: 1, alpha: 0.7), dy: 48)
    }

    // MARK: - Drawing helpers

    private static func wpmText(_ value: Double) -> String {
        "\(Int(value.rounded())) wpm"
    }

    private static func accuracyText(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func drawGlyph(_ character: Character, in rect: NSRect, font: NSFont, color: NSColor) {
        let string = String(character) as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = string.size(withAttributes: attributes)
        let origin = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        string.draw(at: origin, withAttributes: attributes)
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
