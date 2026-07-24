import Cocoa

/// Night Sky: one invented sky per evening, and a way to notice a shape in it.
/// Connect a few stars however you like, give the shape a name, and it goes
/// into an almanac you own. Nothing is solved here and nothing is scored: there
/// is no right constellation, only the one you saw. Watching the sky and
/// linking nothing is a whole way to play, and a night nobody looked at is a
/// night the sky had anyway.
final class NightSkyView: NSView, ArcadeGame, NSTextViewDelegate {
    static let gameID = "night-sky"
    static let title = "Night Sky"
    static let howToPlay = """
    Tonight's sky is invented and it is yours until tomorrow. Click a star, then click others to run a line from one to the next, and stop wherever the shape looks like something. Press Return to give it a name and it settles onto the sky, written into your almanac. Several a night is fine, and so is none: watching is a whole way to do this.

    There is nothing to solve. No constellation here is the right one, nothing is scored or timed, and a night you never opened is not a night you missed.

    Click a star  Start a shape, or add the next star to it
    Arrows  Move the highlight to the nearest star that way
    Space  Link the highlighted star
    Backspace  Take back the last link
    Return  Name the shape
    Esc while naming  Leave the shape as it is
    Esc  Close the arcade

    Named shapes land in ~/.config/cortland/star-almanac.md, a plain markdown file you own.
    """

    private static let contentSize = BlocksGameView.contentSize
    private static let margin: CGFloat = 18
    private static let skyTop: CGFloat = 42
    private static let skyBottom: CGFloat = 34

    /// Quiet enough to be a window rather than a screensaver.
    private static let tickInterval: TimeInterval = 1.0 / 15
    /// A roll every few seconds, so a streak turns up about once a minute of
    /// watching and never when it is owed.
    private static let streakRollInterval: Double = 3
    private static let streakDuration: Double = 0.75

    private static let starWhite = NSColor(calibratedRed: 0.88, green: 0.91, blue: 1, alpha: 1)
    private static let drawingLine = NSColor(calibratedRed: 0.62, green: 0.70, blue: 0.92, alpha: 1)
    private static let settledLine = NSColor(calibratedRed: 0.78, green: 0.84, blue: 1, alpha: 1)
    private static let radii: [CGFloat] = [1.05, 1.6, 2.35]
    private static let baseAlphas: [Double] = [0.42, 0.62, 0.9]

    private let model: NightSkyModel

    /// How each star breathes. Cosmetic and derived, never state: a sky is the
    /// same sky whether it was watched for an hour or opened once.
    private var twinkles: [(offset: Double, rate: Double)] = []
    private var clock: Double = 0
    private var tickTimer: Timer?
    private var isAwake = false

    private var streakRng: SplitMix64
    private var sinceStreakRoll: Double = 0
    private var streak: (path: NightSkyStreak, elapsed: Double)?

    /// The keyboard's soft highlight, and the mouse's preview line. Both are
    /// where the eye is, not what has been drawn, so neither is persisted.
    private var highlighted: Int?
    private var cursor: NSPoint?

    private var naming = false
    private let nameField = NightSkyNameView()
    private let nameScroll = NSScrollView()
    private let almanacButton = NSButton(title: "star-almanac.md", target: nil, action: nil)

    var onCloseRequested: (() -> Void)?

    // MARK: - ArcadeGame

    init(savedState: Data?) {
        let saved = savedState.flatMap { try? JSONDecoder().decode(NightSkyState.self, from: $0) }
        let state = saved ?? NightSkyModel.freshState(
            seed: UInt64.random(in: UInt64.min...UInt64.max),
            dateStamp: NightSkyAlmanac.dayStamp(for: Date())
        )
        model = NightSkyModel(state: state)
        streakRng = SplitMix64(seed: state.skySeed)
        super.init(frame: NSRect(origin: .zero, size: Self.contentSize))
        buildControls()
        refreshNight()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    var view: NSView { self }

    func pause() {
        sleepSky()
    }

    func resume() {
        refreshNight()
        wakeSky()
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

    override func becomeFirstResponder() -> Bool {
        // The panel hands the game focus on the way in; that is the sky's cue
        // to check whether the night turned while it was away.
        refreshNight()
        wakeSky()
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        guard let window else {
            sleepSky()
            return
        }
        // Clicking back onto the panel is not a keypress, and the sky should be
        // alive again anyway.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowBecameKey),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        if window.isKeyWindow { wakeSky() }
    }

    @objc private func windowBecameKey() {
        refreshNight()
        wakeSky()
    }

    /// The night turning over: a new sky, and an unfinished shape from a sky
    /// that no longer exists is let go. Never announced, never counted.
    private func refreshNight() {
        guard model.rollOver(to: NightSkyAlmanac.dayStamp(for: Date())) else { return }
        cancelNaming()
        highlighted = nil
        rebuildTwinkles()
        needsDisplay = true
    }

    // MARK: - Controls

    private func buildControls() {
        nameField.font = .systemFont(ofSize: 13)
        nameField.textColor = .labelColor
        nameField.backgroundColor = NSColor(calibratedWhite: 0.5, alpha: 0.1)
        nameField.insertionPointColor = .labelColor
        nameField.isRichText = false
        nameField.textContainerInset = NSSize(width: 8, height: 5)
        nameField.delegate = self
        nameField.onControlBacktick = { [weak self] in self?.onCloseRequested?() }

        nameScroll.documentView = nameField
        nameScroll.hasVerticalScroller = false
        nameScroll.drawsBackground = false
        nameScroll.wantsLayer = true
        nameScroll.layer?.cornerRadius = 6
        nameScroll.layer?.borderWidth = 1
        nameScroll.layer?.borderColor = NSColor(calibratedWhite: 0.6, alpha: 0.3).cgColor
        nameScroll.frame = NSRect(x: bounds.midX - 110, y: bounds.midY - 14, width: 220, height: 28)
        nameField.frame = NSRect(origin: .zero, size: nameScroll.contentSize)
        nameField.autoresizingMask = [.width]
        nameScroll.isHidden = true

        almanacButton.isBordered = false
        almanacButton.controlSize = .small
        almanacButton.attributedTitle = NSAttributedString(
            string: "star-almanac.md",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
        )
        almanacButton.target = self
        almanacButton.action = #selector(almanacClicked)
        almanacButton.refusesFirstResponder = true
        almanacButton.frame = NSRect(x: bounds.width - 130, y: bounds.height - 24, width: 112, height: 16)
        almanacButton.alignment = .right
        almanacButton.toolTip = "Open your almanac"

        addSubview(nameScroll)
        addSubview(almanacButton)
    }

    @objc private func almanacClicked() {
        NSWorkspace.shared.open(NightSkyAlmanac.defaultFileURL)
    }

    // MARK: - The idle sky

    private func rebuildTwinkles() {
        var rng = SplitMix64(seed: model.snapshot().skySeed &+ 0x5EED)
        twinkles = model.stars.indices.map { _ in
            (offset: Double.random(in: 0..<(2 * .pi), using: &rng),
             rate: Double.random(in: 0.25...0.7, using: &rng))
        }
    }

    private func wakeSky() {
        guard !isAwake, window != nil else { return }
        isAwake = true
        if twinkles.count != model.stars.count { rebuildTwinkles() }
        scheduleTick()
    }

    private func sleepSky() {
        isAwake = false
        tickTimer?.invalidate()
        tickTimer = nil
        streak = nil
        needsDisplay = true
    }

    /// A chained single-shot timer, as in the other games, running only while
    /// the panel is up and in front.
    private func scheduleTick() {
        tickTimer?.invalidate()
        guard isAwake else { return }
        tickTimer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tick()
                self.scheduleTick()
            }
        }
    }

    private func tick() {
        clock += Self.tickInterval

        if var falling = streak {
            falling.elapsed += Self.tickInterval
            streak = falling.elapsed >= Self.streakDuration ? nil : falling
        } else {
            sinceStreakRoll += Self.tickInterval
            if sinceStreakRoll >= Self.streakRollInterval {
                sinceStreakRoll = 0
                if NightSkyStreaks.rolls(using: &streakRng) {
                    streak = (NightSkyStreaks.streak(using: &streakRng), 0)
                }
            }
        }
        needsDisplay = true
    }

    // MARK: - Input

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if event.keyCode == 53 || (event.keyCode == 50 && modifiers == .control) {
            onCloseRequested?()
            return
        }

        switch event.keyCode {
        case 36: beginNaming()                              // return
        case 51: model.unlink()                             // backspace
        case 49: linkHighlighted()                          // space
        case 48: stepHighlight()                            // tab
        case 123: moveHighlight(dx: -1, dy: 0)              // left
        case 124: moveHighlight(dx: 1, dy: 0)               // right
        case 126: moveHighlight(dx: 0, dy: -1)              // up
        case 125: moveHighlight(dx: 0, dy: 1)               // down
        default:
            super.keyDown(with: event)
            return
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard !naming else { return }
        window?.makeFirstResponder(self)

        let point = convert(event.locationInWindow, from: nil)
        guard let index = star(at: point) else { return }
        model.link(index)
        highlighted = index
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil)
        if !model.path.isEmpty { needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        cursor = nil
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    private func star(at point: NSPoint) -> Int? {
        let sky = skyRect
        guard sky.width > 0, sky.height > 0 else { return nil }
        return model.star(
            nearX: Double((point.x - sky.minX) / sky.width),
            y: Double((point.y - sky.minY) / sky.height),
            within: 0.04
        )
    }

    private func linkHighlighted() {
        guard let highlighted else {
            self.highlighted = model.centermostStar
            return
        }
        model.link(highlighted)
    }

    private func stepHighlight() {
        guard !model.stars.isEmpty else { return }
        guard let current = highlighted else {
            highlighted = model.centermostStar
            return
        }
        highlighted = (current + 1) % model.stars.count
    }

    /// The first arrow only shows the highlight, at the shape's end if there is
    /// one; after that an arrow moves it. Nothing here wraps or hunts: if there
    /// is no star that way, the highlight stays where it is.
    private func moveHighlight(dx: Double, dy: Double) {
        guard let origin = highlighted ?? model.lastLinked ?? model.centermostStar else { return }
        guard highlighted != nil else {
            highlighted = origin
            return
        }
        highlighted = model.star(from: origin, towardX: dx, y: dy) ?? origin
    }

    // MARK: - Naming

    private func beginNaming() {
        guard !naming, model.canName else { return }
        naming = true
        nameField.string = ""
        nameScroll.isHidden = false
        window?.makeFirstResponder(nameField)
        needsDisplay = true
    }

    /// Esc in the field, or a name that was never typed: the shape stays
    /// exactly as it is, unnamed, and can be added to or left alone.
    private func cancelNaming() {
        guard naming else { return }
        naming = false
        nameField.string = ""
        nameScroll.isHidden = true
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func commitName() {
        let typed = nameField.string
        guard let constellation = model.name(typed) else {
            cancelNaming()
            return
        }
        NightSkyAlmanac.record(
            constellation,
            sky: model.stars,
            dateStamp: model.dateStamp
        )
        highlighted = nil
        cancelNaming()
    }

    // MARK: - NSTextViewDelegate

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            commitName()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelNaming()
            return true
        default:
            return false
        }
    }

    // MARK: - Drawing

    private var skyRect: NSRect {
        NSRect(
            x: Self.margin,
            y: Self.skyTop,
            width: bounds.width - Self.margin * 2,
            height: bounds.height - Self.skyTop - Self.skyBottom
        )
    }

    private func point(for star: NightSkyStar) -> NSPoint {
        let sky = skyRect
        return NSPoint(x: sky.minX + CGFloat(star.x) * sky.width, y: sky.minY + CGFloat(star.y) * sky.height)
    }

    private func point(unitX x: Double, y: Double) -> NSPoint {
        let sky = skyRect
        return NSPoint(x: sky.minX + CGFloat(x) * sky.width, y: sky.minY + CGFloat(y) * sky.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        AppTheme.windowBackground.setFill()
        bounds.fill()

        drawSky()
        drawStreak()
        for constellation in model.named {
            drawPath(constellation.path, color: Self.settledLine, alpha: 0.5, width: 1.2)
            drawName(constellation)
        }
        drawPath(model.path, color: Self.drawingLine, alpha: 0.32, width: 1)
        drawPreview()
        drawStars()
        drawHighlight()
        drawHeader()
        drawHint()
    }

    private func drawSky() {
        let sky = skyRect
        let path = NSBezierPath(roundedRect: sky, xRadius: 8, yRadius: 8)
        // A near-black wash that lifts a little toward the horizon, the way a
        // sky never quite reaches black at the bottom.
        NSGradient(
            starting: NSColor(calibratedRed: 0.03, green: 0.035, blue: 0.06, alpha: 1),
            ending: NSColor(calibratedRed: 0.07, green: 0.075, blue: 0.11, alpha: 1)
        )?.draw(in: path, angle: 90)
    }

    private func drawStreak() {
        guard let falling = streak else { return }
        let progress = falling.elapsed / Self.streakDuration
        let path = falling.path

        // A short head with a tail behind it, fading as it goes.
        let head = min(1, progress * 1.25)
        let tail = max(0, head - 0.28)
        let from = point(
            unitX: path.startX + (path.endX - path.startX) * tail,
            y: path.startY + (path.endY - path.startY) * tail
        )
        let to = point(
            unitX: path.startX + (path.endX - path.startX) * head,
            y: path.startY + (path.endY - path.startY) * head
        )

        let line = NSBezierPath()
        line.move(to: from)
        line.line(to: to)
        line.lineWidth = 1.1
        line.lineCapStyle = .round
        Self.starWhite.withAlphaComponent(CGFloat(sin(progress * .pi)) * 0.75).setStroke()
        line.stroke()
    }

    private func drawPath(_ path: [Int], color: NSColor, alpha: Double, width: CGFloat) {
        let segments = NightSkyModel.segments(of: path)
        guard !segments.isEmpty else { return }

        let line = NSBezierPath()
        for segment in segments {
            guard model.stars.indices.contains(segment.from), model.stars.indices.contains(segment.to) else { continue }
            line.move(to: point(for: model.stars[segment.from]))
            line.line(to: point(for: model.stars[segment.to]))
        }
        line.lineWidth = width
        line.lineCapStyle = .round
        color.withAlphaComponent(CGFloat(alpha)).setStroke()
        line.stroke()
    }

    private func drawName(_ constellation: NightSkyConstellation) {
        let members = NightSkySketch.orderedMembers(of: constellation.path, in: model.stars)
        guard let lowest = members.max(by: { model.stars[$0].y < model.stars[$1].y }) else { return }
        let anchor = point(for: model.stars[lowest])

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: Self.settledLine.withAlphaComponent(0.45)
        ]
        let text = constellation.name as NSString
        let size = text.size(withAttributes: attributes)
        let x = min(max(skyRect.minX + 4, anchor.x - size.width / 2), skyRect.maxX - size.width - 4)
        let y = min(anchor.y + 7, skyRect.maxY - size.height - 2)
        text.draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
    }

    /// A dim thread from the last star to the cursor: where the next link would
    /// go, not a link.
    private func drawPreview() {
        guard !naming, let last = model.lastLinked, let cursor,
              model.stars.indices.contains(last), skyRect.contains(cursor) else { return }

        let line = NSBezierPath()
        line.move(to: point(for: model.stars[last]))
        line.line(to: cursor)
        line.lineWidth = 0.8
        line.setLineDash([2, 3], count: 2, phase: 0)
        Self.drawingLine.withAlphaComponent(0.22).setStroke()
        line.stroke()
    }

    private func drawStars() {
        for (index, star) in model.stars.enumerated() {
            let center = point(for: star)
            let brightness = min(max(0, star.brightness), Self.radii.count - 1)
            let radius = Self.radii[brightness]
            let alpha = CGFloat(min(1, Self.baseAlphas[brightness] + twinkle(at: index)))

            if brightness == 2 {
                // The brightest few carry a soft halo, which is most of what
                // makes a flat scatter of dots read as a sky.
                Self.starWhite.withAlphaComponent(alpha * 0.14).setFill()
                NSBezierPath(ovalIn: NSRect(
                    x: center.x - radius * 2.6, y: center.y - radius * 2.6,
                    width: radius * 5.2, height: radius * 5.2
                )).fill()
            }

            Self.starWhite.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: NSRect(
                x: center.x - radius, y: center.y - radius,
                width: radius * 2, height: radius * 2
            )).fill()
        }
    }

    /// Most stars sit still most of the time; the exponent is what keeps it to
    /// a few at a time rather than a field of blinking lights.
    private func twinkle(at index: Int) -> Double {
        guard index < twinkles.count else { return 0 }
        let phase = clock * twinkles[index].rate + twinkles[index].offset
        return 0.22 * pow(max(0, sin(phase)), 8)
    }

    private func drawHighlight() {
        guard !naming, let highlighted, model.stars.indices.contains(highlighted) else { return }
        let center = point(for: model.stars[highlighted])
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12))
        ring.lineWidth = 0.8
        Self.starWhite.withAlphaComponent(0.35).setStroke()
        ring.stroke()
    }

    private func drawHeader() {
        drawText("night sky", at: NSPoint(x: Self.margin, y: 16),
                 font: .systemFont(ofSize: 13, weight: .medium), color: .secondaryLabelColor)
        if naming {
            drawCentered("a name for it", font: .systemFont(ofSize: 11),
                         color: .tertiaryLabelColor, atY: bounds.midY - 34)
        }
    }

    private func drawHint() {
        let text: String
        if naming {
            text = "return names it · esc leaves it as it is"
        } else if model.canName {
            text = "click stars to connect · enter name · backspace unlink · esc close"
        } else if model.path.isEmpty {
            text = "click stars to connect · esc close"
        } else {
            text = "click another star · backspace unlink · esc close"
        }
        drawText(text, at: NSPoint(x: Self.margin, y: bounds.height - 18),
                 font: .systemFont(ofSize: 10), color: .tertiaryLabelColor)
    }

    private func drawText(_ string: String, at point: NSPoint, font: NSFont, color: NSColor) {
        (string as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }

    private func drawCentered(_ string: String, font: NSFont, color: NSColor, atY y: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (string as NSString).size(withAttributes: attributes)
        (string as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: y), withAttributes: attributes)
    }
}

/// The naming field, in the Two Lines pattern: it still honors the panel's ⌃`
/// toggle while it has focus, and Return and Esc reach the game through the
/// delegate rather than being swallowed by the field editor.
private final class NightSkyNameView: NSTextView {
    var onControlBacktick: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if event.keyCode == 50 && modifiers == .control {
            onControlBacktick?()
            return
        }
        super.keyDown(with: event)
    }
}
