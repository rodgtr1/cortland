import Cocoa

/// The Pond: a line goes out, you go back to work, and you reel in whenever
/// you wander back. The waiting you were already doing is the only resource.
/// Nothing is decided while the line sits there, so nothing can be missed:
/// the catch is rolled at reel-in, and every reel-in lands something. Watching
/// the water is a full way to play; so is never casting.
final class PondView: NSView, ArcadeGame {
    static let gameID = "pond"
    static let title = "The Pond"
    static let howToPlay = """
    Cast a line, go back to work, and reel in whenever you come back. The longer a line has been out, the stranger the pool of things that may be on it, but nothing is ever lost by waiting or by reeling in early. There is no score, no timer, and nothing to miss. Every catch is released; the record is your pond-almanac.md.

    Space  Cast, or reel in a line that is out
    Space on a card  Release and return to the water
    A  Show or hide the almanac
    Esc  Close the arcade
    """

    private static let contentSize = BlocksGameView.contentSize
    private static let margin: CGFloat = 22
    private static let horizon: CGFloat = 132
    private static let tickInterval: TimeInterval = 0.25

    private let model: PondModel

    /// The catch currently on the card, if one is being looked at. Card state
    /// is deliberately not persisted: the fish is already released and logged.
    private var shownCatch: PondCatch?
    private var showingAlmanac = false
    private var almanacEntries: [String] = []

    private let openFileButton = NSButton(title: "Open pond-almanac.md", target: nil, action: nil)

    // Ambient motion. None of it is state; it exists only while the panel is
    // on screen, and the pond looks the same whether or not you watched it.
    private var idleTimer: Timer?
    private var phase: Double = 0
    private var ripples: [Ripple] = []
    private var dragonfly: Drifter?
    private var fishShadow: Drifter?
    private var ambientRNG: SplitMix64
    private let shoreline: [ShoreProp]

    var onCloseRequested: (() -> Void)?

    private struct Ripple {
        let center: NSPoint
        let born: Double
        let span: Double
    }

    private struct Drifter {
        var x: CGFloat
        let y: CGFloat
        let speed: CGFloat
        let born: Double
    }

    private enum ShoreKind {
        case reed, stump, stone
    }

    private struct ShoreProp {
        let kind: ShoreKind
        let x: CGFloat
        let size: CGFloat
    }

    // MARK: - ArcadeGame

    init(savedState: Data?) {
        let saved = savedState.flatMap { try? JSONDecoder().decode(PondState.self, from: $0) }
        let state = saved ?? PondModel.freshState(seed: UInt64.random(in: UInt64.min...UInt64.max))
        model = PondModel(state: state)
        ambientRNG = SplitMix64(seed: state.pondSeed &+ 0xA5A5)
        shoreline = Self.makeShoreline(seed: state.pondSeed, width: Self.contentSize.width)
        super.init(frame: NSRect(origin: .zero, size: Self.contentSize))
        buildAlmanacControls()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    var view: NSView { self }

    func pause() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    func resume() {
        scheduleTick()
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

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    // MARK: - Input

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if event.keyCode == 53 || (event.keyCode == 50 && modifiers == .control) {
            onCloseRequested?()
            return
        }

        switch event.keyCode {
        case 49: // space
            if shownCatch != nil {
                shownCatch = nil
            } else if showingAlmanac {
                setAlmanacVisible(false)
            } else {
                castOrReel()
            }
            needsDisplay = true
        case 0: // a
            guard shownCatch == nil else { return }
            setAlmanacVisible(!showingAlmanac)
        default:
            super.keyDown(with: event)
        }
    }

    private func castOrReel() {
        let now = Date()
        if model.isLineOut {
            guard let landed = model.reelIn(now: now) else { return }
            PondAlmanac.record(landed, date: now)
            shownCatch = landed
            ripples.append(Ripple(center: bobberPoint(stage: .high), born: phase, span: 5))
        } else {
            model.cast(now: now, seed: UInt64.random(in: UInt64.min...UInt64.max))
            ripples.append(Ripple(center: bobberPoint(stage: .high), born: phase, span: 4))
        }
    }

    // MARK: - Almanac

    private func buildAlmanacControls() {
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

    private func setAlmanacVisible(_ visible: Bool) {
        showingAlmanac = visible
        openFileButton.isHidden = !visible
        if visible {
            almanacEntries = PondAlmanac.recentEntries(limit: 14)
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    @objc private func openFileClicked() {
        NSWorkspace.shared.open(PondAlmanac.defaultFileURL)
    }

    // MARK: - Ambient motion

    /// Chained single-shot timer, mirroring BlocksGameView: it only runs while
    /// the panel is up, and nothing it does touches the model.
    private func scheduleTick() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.advanceAmbient()
                self.needsDisplay = true
                self.scheduleTick()
            }
        }
    }

    private func advanceAmbient() {
        phase += Self.tickInterval
        ripples.removeAll { phase - $0.born > $0.span }

        if Double.random(in: 0..<1, using: &ambientRNG) < 0.02 {
            let x = CGFloat.random(in: Self.margin...(bounds.width - Self.margin), using: &ambientRNG)
            let y = CGFloat.random(in: (Self.horizon + 14)...(bounds.height - 46), using: &ambientRNG)
            ripples.append(Ripple(center: NSPoint(x: x, y: y), born: phase, span: 5))
        }

        if dragonfly == nil, Double.random(in: 0..<1, using: &ambientRNG) < 0.01 {
            dragonfly = Drifter(x: -14, y: Self.horizon - CGFloat.random(in: 6...34, using: &ambientRNG),
                                speed: CGFloat.random(in: 6...13, using: &ambientRNG), born: phase)
        }
        if var fly = dragonfly {
            fly.x += fly.speed * CGFloat(Self.tickInterval) * 4
            dragonfly = fly.x > bounds.width + 20 ? nil : fly
        }

        if fishShadow == nil, Double.random(in: 0..<1, using: &ambientRNG) < 0.004 {
            fishShadow = Drifter(x: bounds.width + 16,
                                 y: CGFloat.random(in: (Self.horizon + 40)...(bounds.height - 60), using: &ambientRNG),
                                 speed: -CGFloat.random(in: 3...7, using: &ambientRNG), born: phase)
        }
        if var fish = fishShadow {
            fish.x += fish.speed * CGFloat(Self.tickInterval) * 4
            fishShadow = fish.x < -24 ? nil : fish
        }
    }

    // MARK: - The scene

    private static func makeShoreline(seed: UInt64, width: CGFloat) -> [ShoreProp] {
        var rng = SplitMix64(seed: seed)
        var props: [ShoreProp] = []
        for _ in 0..<Int.random(in: 9...15, using: &rng) {
            props.append(ShoreProp(kind: .reed,
                                   x: CGFloat.random(in: 8...(width - 8), using: &rng),
                                   size: CGFloat.random(in: 12...34, using: &rng)))
        }
        for _ in 0..<Int.random(in: 2...5, using: &rng) {
            props.append(ShoreProp(kind: .stone,
                                   x: CGFloat.random(in: 8...(width - 8), using: &rng),
                                   size: CGFloat.random(in: 4...10, using: &rng)))
        }
        if Bool.random(using: &rng) {
            props.append(ShoreProp(kind: .stump,
                                   x: CGFloat.random(in: 20...(width * 0.4), using: &rng),
                                   size: CGFloat.random(in: 14...22, using: &rng)))
        }
        return props
    }

    private var timeOfDay: PondTimeOfDay { PondTimeOfDay.at(Date()) }

    private func waterColors(_ time: PondTimeOfDay) -> (top: NSColor, bottom: NSColor) {
        switch time {
        case .morning:
            return (NSColor(calibratedRed: 0.20, green: 0.29, blue: 0.34, alpha: 1),
                    NSColor(calibratedRed: 0.08, green: 0.13, blue: 0.17, alpha: 1))
        case .day:
            return (NSColor(calibratedRed: 0.16, green: 0.30, blue: 0.36, alpha: 1),
                    NSColor(calibratedRed: 0.05, green: 0.12, blue: 0.16, alpha: 1))
        case .evening:
            return (NSColor(calibratedRed: 0.26, green: 0.24, blue: 0.30, alpha: 1),
                    NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.15, alpha: 1))
        case .night:
            return (NSColor(calibratedRed: 0.11, green: 0.14, blue: 0.22, alpha: 1),
                    NSColor(calibratedRed: 0.03, green: 0.05, blue: 0.09, alpha: 1))
        }
    }

    private func bobberPoint(stage: PondBobberStage) -> NSPoint {
        NSPoint(x: bounds.width * 0.63, y: Self.horizon + 14 + CGFloat(stage.rawValue) * 3)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        AppTheme.windowBackground.setFill()
        bounds.fill()

        if showingAlmanac {
            drawAlmanac()
            drawHint("a back · space back · esc close")
            return
        }

        let time = timeOfDay
        drawWater(time)
        drawShoreline()
        drawRipples()
        drawFishShadow()
        drawRod()
        drawBobber()
        drawDragonfly()
        drawHeader(time)

        if let landed = shownCatch {
            drawCard(landed)
            drawHint("space release · esc close")
        } else {
            drawHint(model.isLineOut ? "space reel in · a almanac · esc close" : "space cast · a almanac · esc close")
        }
    }

    private func drawWater(_ time: PondTimeOfDay) {
        let colors = waterColors(time)
        let water = NSRect(x: 0, y: Self.horizon, width: bounds.width, height: bounds.height - Self.horizon - 30)
        let gradient = NSGradient(starting: colors.top, ending: colors.bottom)
        gradient?.draw(in: water, angle: isFlipped ? 90 : -90)

        // The far bank: a single quiet line where the water starts.
        NSColor(calibratedWhite: 1, alpha: 0.10).setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 0, y: Self.horizon + 0.5))
        line.line(to: NSPoint(x: bounds.width, y: Self.horizon + 0.5))
        line.lineWidth = 1
        line.stroke()
    }

    private func drawShoreline() {
        for prop in shoreline {
            switch prop.kind {
            case .reed:
                NSColor(calibratedWhite: 0.42, alpha: 0.55).setStroke()
                let reed = NSBezierPath()
                reed.move(to: NSPoint(x: prop.x, y: Self.horizon + 2))
                reed.curve(to: NSPoint(x: prop.x + prop.size * 0.28, y: Self.horizon - prop.size),
                           controlPoint1: NSPoint(x: prop.x, y: Self.horizon - prop.size * 0.5),
                           controlPoint2: NSPoint(x: prop.x + prop.size * 0.1, y: Self.horizon - prop.size * 0.8))
                reed.lineWidth = 1.2
                reed.stroke()
            case .stone:
                NSColor(calibratedWhite: 0.34, alpha: 0.7).setFill()
                let stone = NSBezierPath(ovalIn: NSRect(x: prop.x - prop.size / 2, y: Self.horizon - prop.size * 0.45,
                                                        width: prop.size, height: prop.size * 0.62))
                stone.fill()
            case .stump:
                NSColor(calibratedWhite: 0.30, alpha: 0.8).setFill()
                NSRect(x: prop.x, y: Self.horizon - prop.size, width: prop.size * 0.8, height: prop.size + 4).fill()
            }
        }
    }

    private func drawRipples() {
        for ripple in ripples {
            let age = phase - ripple.born
            let progress = age / ripple.span
            guard progress >= 0, progress <= 1 else { continue }
            let radius = 3 + CGFloat(progress) * 26
            let alpha = 0.22 * (1 - progress)
            NSColor(calibratedWhite: 1, alpha: alpha).setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: ripple.center.x - radius, y: ripple.center.y - radius * 0.32,
                                                   width: radius * 2, height: radius * 0.64))
            ring.lineWidth = 1
            ring.stroke()
        }
    }

    private func drawFishShadow() {
        guard let fish = fishShadow else { return }
        NSColor(calibratedWhite: 0, alpha: 0.28).setFill()
        let body = NSBezierPath(ovalIn: NSRect(x: fish.x, y: fish.y, width: 22, height: 6))
        body.fill()
    }

    private func drawDragonfly() {
        guard let fly = dragonfly else { return }
        let bob = sin(phase * 2.2 + Double(fly.born)) * 3
        drawText("~", at: NSPoint(x: fly.x, y: fly.y + CGFloat(bob)),
                 font: .monospacedSystemFont(ofSize: 11, weight: .regular),
                 color: NSColor(calibratedWhite: 0.65, alpha: 0.55))
    }

    private func drawRod() {
        NSColor(calibratedWhite: 0.5, alpha: 0.75).setStroke()
        let rod = NSBezierPath()
        rod.move(to: NSPoint(x: Self.margin, y: Self.horizon + 46))
        rod.curve(to: NSPoint(x: bounds.width * 0.40, y: Self.horizon - 34),
                  controlPoint1: NSPoint(x: bounds.width * 0.14, y: Self.horizon + 20),
                  controlPoint2: NSPoint(x: bounds.width * 0.30, y: Self.horizon - 16))
        rod.lineWidth = 1.6
        rod.stroke()

        guard model.isLineOut, let stage = model.bobberStage(now: Date()) else { return }
        NSColor(calibratedWhite: 0.7, alpha: 0.4).setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: bounds.width * 0.40, y: Self.horizon - 34))
        line.line(to: bobberPoint(stage: stage))
        line.lineWidth = 0.8
        line.stroke()
    }

    /// The one ambient tell that time has passed: the bobber rides lower the
    /// longer the line has been out. Four stages, no numbers, no bar.
    private func drawBobber() {
        guard model.isLineOut, let stage = model.bobberStage(now: Date()) else { return }
        let center = bobberPoint(stage: stage)
        let bob = CGFloat(sin(phase * 1.1) * 0.8)
        let radius: CGFloat = 4.5
        let submerged: [CGFloat] = [0.20, 0.42, 0.64, 0.82]
        let waterline = center.y + bob - radius + radius * 2 * submerged[stage.rawValue]

        // Below the waterline, seen through the water; above it, in the air.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: center.x - radius, y: waterline,
                                  width: radius * 2, height: radius * 2)).setClip()
        NSColor(calibratedRed: 0.62, green: 0.24, blue: 0.22, alpha: 0.35).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y + bob - radius,
                                    width: radius * 2, height: radius * 2)).fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: center.x - radius, y: waterline - radius * 2,
                                  width: radius * 2, height: radius * 2)).setClip()
        NSColor(calibratedRed: 0.82, green: 0.36, blue: 0.30, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y + bob - radius,
                                    width: radius * 2, height: radius * 2)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawHeader(_ time: PondTimeOfDay) {
        drawText("the pond · \(time.name)", at: NSPoint(x: Self.margin, y: 16),
                 font: .systemFont(ofSize: 13, weight: .medium), color: .secondaryLabelColor)
    }

    // MARK: - The card

    private func drawCard(_ landed: PondCatch) {
        let card = NSRect(x: bounds.width / 2 - 165, y: bounds.height / 2 - 74, width: 330, height: 148)
        NSColor(calibratedWhite: 0.08, alpha: 0.92).setFill()
        let panel = NSBezierPath(roundedRect: card, xRadius: 10, yRadius: 10)
        panel.fill()
        NSColor(calibratedWhite: 1, alpha: 0.12).setStroke()
        panel.lineWidth = 1
        panel.stroke()

        var y = card.minY + 20
        drawCentered(landed.name, font: .systemFont(ofSize: 17, weight: .medium),
                     color: NSColor(calibratedWhite: 0.94, alpha: 1), atY: y)
        y += 28
        drawWrapped(landed.flavor, in: NSRect(x: card.minX + 20, y: y, width: card.width - 40, height: 40),
                    font: .systemFont(ofSize: 12.5), color: NSColor(calibratedWhite: 0.72, alpha: 1))
        y += 44
        drawCentered(landed.size, font: .monospacedSystemFont(ofSize: 11, weight: .regular),
                     color: NSColor(calibratedWhite: 0.55, alpha: 1), atY: y)
        if landed.isFirst {
            drawCentered("new to the almanac", font: .systemFont(ofSize: 11),
                         color: NSColor(calibratedRed: 0.62, green: 0.52, blue: 0.34, alpha: 1),
                         atY: card.maxY - 28)
        }
    }

    // MARK: - The almanac view

    private func drawAlmanac() {
        drawText("the pond · almanac", at: NSPoint(x: Self.margin, y: 16),
                 font: .systemFont(ofSize: 13, weight: .medium), color: .secondaryLabelColor)

        let kinds = model.distinctSpecies
        let summary = kinds == 1 ? "1 kind so far" : "\(kinds) kinds so far"
        drawText(summary, at: NSPoint(x: Self.margin, y: 38),
                 font: .monospacedSystemFont(ofSize: 11, weight: .regular), color: .tertiaryLabelColor)

        guard !almanacEntries.isEmpty else {
            drawCentered("Nothing yet. What comes up lands in ~/.config/cortland/pond-almanac.md.",
                         font: .systemFont(ofSize: 12), color: .tertiaryLabelColor, atY: bounds.midY)
            return
        }

        let font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        var y = bounds.height - 60 - CGFloat(almanacEntries.count) * 16
        y = max(y, 62)
        for entry in almanacEntries.suffix(Int((bounds.height - 120) / 16)) {
            drawText(plain(entry), at: NSPoint(x: Self.margin, y: y), font: font, color: .secondaryLabelColor)
            y += 16
        }
    }

    /// The file is markdown; the panel is not. Strip the emphasis and the list
    /// bullet so the in-panel record reads as plain lines.
    private func plain(_ entry: String) -> String {
        var text = entry
        if text.hasPrefix("- ") { text.removeFirst(2) }
        return text.replacingOccurrences(of: "**", with: "")
    }

    private func drawHint(_ text: String) {
        drawText(text, at: NSPoint(x: Self.margin, y: bounds.height - 18),
                 font: .systemFont(ofSize: 10), color: .tertiaryLabelColor)
    }

    // MARK: - Text helpers

    private static let wrapStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.alignment = .center
        style.lineSpacing = 1
        return style
    }()

    private func drawWrapped(_ string: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .paragraphStyle: Self.wrapStyle, .foregroundColor: color
        ]
        (string as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
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
