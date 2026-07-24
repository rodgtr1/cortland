import Cocoa

/// The Walk: an endless landscape strolled a few steps at a time, described in
/// spare text. Space or Return takes a step; the newest line sits at the
/// bottom in full color with the last few receding, dimmed, above it. There is
/// no destination and no counter to fill. Findings and new places accrue in a
/// field journal the user owns. The video-game equivalent of a train window.
final class WalkView: NSView, ArcadeGame {
    static let gameID = "walk"
    static let title = "The Walk"
    static let howToPlay = """
    Take an endless walk through a changing landscape. There is no destination or score. New places and occasional findings are recorded in your the-walk.md journal.

    Space or Return  Take a step
    ⌘J  Show or hide the journal
    Space or Return in the journal  Return to the walk
    Esc  Close the arcade
    """

    private static let contentSize = BlocksGameView.contentSize
    private static let margin: CGFloat = 22
    private static let textTop: CGFloat = 58
    private static let textBottom: CGFloat = 40

    private let model: WalkModel

    // The ⌘J journal overlay, mirroring TwoLinesView.
    private let journalScroll = NSScrollView()
    private let journalText = NSTextView()
    private let openFileButton = NSButton(title: "Open the-walk.md", target: nil, action: nil)
    private var showingJournal = false

    var onCloseRequested: (() -> Void)?

    private static let findingColor = NSColor(calibratedRed: 0.62, green: 0.52, blue: 0.34, alpha: 1)

    // MARK: - ArcadeGame

    init(savedState: Data?) {
        let state = savedState.flatMap { try? JSONDecoder().decode(WalkState.self, from: $0) }
        model = WalkModel(state: state ?? WalkModel.freshState(seed: UInt64.random(in: UInt64.min...UInt64.max)))
        super.init(frame: NSRect(origin: .zero, size: Self.contentSize))
        buildJournalOverlay()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    var view: NSView { self }

    func pause() {
        // Untimed; the walk only advances on a keypress. Nothing runs while hidden.
    }

    func resume() {
        needsDisplay = true
    }

    func encodeState() -> Data? {
        try? JSONEncoder().encode(model.snapshot())
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    // MARK: - Input

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if modifiers == .command, event.keyCode == 38 { // ⌘J
            setJournalVisible(!showingJournal)
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

        if showingJournal {
            // While the journal is up, space or return closes it; otherwise wait.
            if event.keyCode == 49 || event.keyCode == 36 {
                setJournalVisible(false)
            }
            return
        }

        switch event.keyCode {
        case 49, 36: // space or return
            takeStep()
        default:
            super.keyDown(with: event)
        }
    }

    private func takeStep() {
        let result = model.step()
        if result.enteredBiome {
            WalkJournal.recordBiomeEntry(step: result.step, biome: result.biome, weather: result.weather)
        }
        if let finding = result.finding {
            WalkJournal.recordFinding(step: result.step, biome: result.biome, finding: finding)
        }
        needsDisplay = true
    }

    // MARK: - Journal overlay

    private func buildJournalOverlay() {
        journalText.isEditable = false
        journalText.isSelectable = true
        journalText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        journalText.textColor = .labelColor
        journalText.backgroundColor = NSColor(calibratedWhite: 0.5, alpha: 0.06)
        journalText.textContainerInset = NSSize(width: 10, height: 10)
        journalScroll.documentView = journalText
        journalScroll.hasVerticalScroller = true
        journalScroll.autohidesScrollers = true
        journalScroll.drawsBackground = false
        journalScroll.wantsLayer = true
        journalScroll.layer?.cornerRadius = 8
        journalScroll.frame = NSRect(x: 24, y: 52, width: bounds.width - 48, height: bounds.height - 108)
        journalText.frame = NSRect(origin: .zero, size: journalScroll.contentSize)
        journalText.autoresizingMask = [.width]
        journalScroll.isHidden = true

        openFileButton.bezelStyle = .rounded
        openFileButton.controlSize = .small
        openFileButton.font = .systemFont(ofSize: 11)
        openFileButton.target = self
        openFileButton.action = #selector(openFileClicked)
        openFileButton.frame = NSRect(x: bounds.midX - 75, y: bounds.height - 44, width: 150, height: 26)
        openFileButton.isHidden = true

        addSubview(journalScroll)
        addSubview(openFileButton)
    }

    private func setJournalVisible(_ visible: Bool) {
        showingJournal = visible
        journalScroll.isHidden = !visible
        openFileButton.isHidden = !visible
        if visible {
            let entries = WalkJournal.recentEntries(limit: 200)
            journalText.string = entries.isEmpty
                ? "Nothing yet. Findings and new places land in ~/.config/cortland/the-walk.md as you walk."
                : entries.joined(separator: "\n")
            journalText.scrollToEndOfDocument(nil)
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    @objc private func openFileClicked() {
        NSWorkspace.shared.open(WalkJournal.defaultFileURL)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        AppTheme.windowBackground.setFill()
        bounds.fill()
        if showingJournal {
            drawText("the walk · journal", at: NSPoint(x: Self.margin, y: 18),
                     font: .systemFont(ofSize: 12, weight: .semibold), color: .secondaryLabelColor)
            return
        }
        drawHeader()
        if model.hasStarted {
            drawWalk()
        } else {
            drawInvitation()
        }
        drawHint()
    }

    private func drawHeader() {
        let place = "\(model.biome.name) · \(model.weather.name)"
        drawText(place, at: NSPoint(x: Self.margin, y: 16),
                 font: .systemFont(ofSize: 13, weight: .medium), color: .secondaryLabelColor)
        if model.hasStarted {
            drawText("step \(model.currentStep)", at: NSPoint(x: 0, y: 18),
                     font: .monospacedSystemFont(ofSize: 10, weight: .regular),
                     color: .tertiaryLabelColor, rightAlignedTo: bounds.width - Self.margin)
        }
    }

    private func drawInvitation() {
        drawCentered("a path, and the time to walk it",
                     font: .systemFont(ofSize: 17, weight: .medium), color: .labelColor, dy: -12)
        drawCentered("press space to take a step",
                     font: .systemFont(ofSize: 12), color: .tertiaryLabelColor, dy: 16)
    }

    /// Newest at the bottom in full color, the previous few receding upward and
    /// dimming, until the top of the text area runs out.
    private func drawWalk() {
        let lines = model.lines
        let x = Self.margin
        let width = bounds.width - Self.margin * 2
        let topY = Self.textTop
        var cursorBottom = bounds.height - Self.textBottom

        let bodyFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let findFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        for (offset, line) in lines.enumerated().reversed() {
            let age = (lines.count - 1) - offset
            let alpha = max(0.12, pow(0.72, Double(age)))

            let descHeight = wrappedHeight(line.text, width: width, font: bodyFont)
            let findHeight = line.finding.map { wrappedHeight($0, width: width - 16, font: findFont) } ?? 0
            let innerGap: CGFloat = line.finding != nil ? 4 : 0
            let groupHeight = descHeight + innerGap + findHeight
            let groupTop = cursorBottom - groupHeight
            if groupTop < topY { break }

            drawWrapped(line.text, in: NSRect(x: x, y: groupTop, width: width, height: descHeight),
                        font: bodyFont, color: NSColor.labelColor.withAlphaComponent(alpha))
            if let finding = line.finding {
                drawWrapped(finding, in: NSRect(x: x + 16, y: groupTop + descHeight + innerGap,
                                                width: width - 16, height: findHeight),
                            font: findFont, color: Self.findingColor.withAlphaComponent(alpha))
            }
            cursorBottom = groupTop - 12
        }
    }

    private func drawHint() {
        drawText("space step · ⌘j journal · esc close",
                 at: NSPoint(x: Self.margin, y: bounds.height - 18),
                 font: .systemFont(ofSize: 10), color: .tertiaryLabelColor)
    }

    // MARK: - Text helpers

    private static let wrapStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = 1
        return style
    }()

    private func wrappedHeight(_ string: String, width: CGFloat, font: NSFont) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: Self.wrapStyle]
        let rect = (string as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        return ceil(rect.height)
    }

    private func drawWrapped(_ string: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .paragraphStyle: Self.wrapStyle, .foregroundColor: color
        ]
        (string as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
    }

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
