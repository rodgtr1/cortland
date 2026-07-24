import Cocoa

/// What Two Lines remembers between opens: the prompt on screen, recently
/// shown prompts (so check-ins don't repeat), and any half-typed draft.
/// The journal itself lives in a markdown file the user owns — see
/// TwoLinesJournal — never in this blob.
nonisolated private struct TwoLinesState: Codable, Equatable, Sendable {
    var currentPromptIndex: Int?
    var recentPromptIndices: [Int]
    var draft: String
}

/// The palate-cleanser: a gentle prompt, a small text box, and a quiet trace
/// that grows one bend at a time. No scores, streaks, goals, or fail state.
/// Writing something appends to the journal; writing nothing costs nothing.
final class TwoLinesView: NSView, ArcadeGame, NSTextViewDelegate {
    static let gameID = "two-lines"
    static let title = "Two Lines"
    static let howToPlay = """
    Read the prompt and write a line or two. Each saved entry adds a small bend to the trace above the prompt. It has no finish, score, streak, or penalty. Saved entries go to your two-lines.md journal, and unfinished drafts survive closing the arcade.

    Return  Save the entry and get a new prompt
    Option-Return  Insert a line break
    ⌘R  Skip to another prompt
    ⌘J  Show or hide the journal
    Esc  Close the arcade
    """

    private static let contentSize = BlocksGameView.contentSize

    private var currentPromptIndex: Int?
    private var recentPromptIndices: [Int]

    private let captionLabel = NSTextField(labelWithString: "TWO LINES")
    private let traceView = TwoLinesTraceView()
    private let promptLabel = NSTextField(wrappingLabelWithString: "")
    private let entryScroll = NSScrollView()
    private let entryText = TwoLinesTextView()
    private let hintLabel = NSTextField(labelWithString: "return keeps it · esc closes")
    private let keptLabel = NSTextField(labelWithString: "kept ✓")
    private let anotherButton = NSButton(title: "Another prompt  ⌘R", target: nil, action: nil)
    private let journalButton = NSButton(title: "Journal  ⌘J", target: nil, action: nil)

    private let journalScroll = NSScrollView()
    private let journalText = NSTextView()
    private let openFileButton = NSButton(title: "Open two-lines.md", target: nil, action: nil)

    private var showingJournal = false
    private var keptFadeTimer: Timer?

    var onCloseRequested: (() -> Void)?

    // MARK: - ArcadeGame

    init(savedState: Data?) {
        let saved = savedState.flatMap { try? JSONDecoder().decode(TwoLinesState.self, from: $0) }
        currentPromptIndex = saved?.currentPromptIndex
        recentPromptIndices = saved?.recentPromptIndices ?? []
        super.init(frame: NSRect(origin: .zero, size: Self.contentSize))
        buildUI(draft: saved?.draft ?? "")
        if currentPromptIndex == nil || !TwoLinesPrompts.all.indices.contains(currentPromptIndex!) {
            advancePrompt()
        } else {
            showPrompt()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    var view: NSView { self }

    func pause() {
        // Nothing runs; the draft is captured by encodeState.
    }

    func resume() {
        needsDisplay = true
    }

    func encodeState() -> Data? {
        try? JSONEncoder().encode(TwoLinesState(
            currentPromptIndex: currentPromptIndex,
            recentPromptIndices: recentPromptIndices,
            draft: entryText.string
        ))
    }

    // MARK: - UI

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        // The panel hands focus to the game view; pass it on to the text box
        // (next runloop turn — reentrant makeFirstResponder misbehaves).
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.showingJournal else { return }
            self.window?.makeFirstResponder(self.entryText)
        }
        return true
    }

    private func buildUI(draft: String) {
        wantsLayer = true
        layer?.backgroundColor = AppTheme.windowBackground.cgColor

        captionLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        captionLabel.textColor = .tertiaryLabelColor
        captionLabel.alignment = .center
        captionLabel.frame = NSRect(x: 0, y: 24, width: bounds.width, height: 14)

        traceView.frame = NSRect(x: 74, y: 52, width: bounds.width - 148, height: 52)
        traceView.seeds = TwoLinesJournal.traceSeeds()

        promptLabel.font = Self.serifFont(size: 19, weight: .medium)
        promptLabel.textColor = .labelColor
        promptLabel.alignment = .center
        promptLabel.frame = NSRect(x: 46, y: 130, width: bounds.width - 92, height: 110)

        entryText.font = .systemFont(ofSize: 14)
        entryText.textColor = .labelColor
        entryText.backgroundColor = NSColor(calibratedWhite: 0.5, alpha: 0.08)
        entryText.insertionPointColor = .labelColor
        entryText.isRichText = false
        entryText.allowsUndo = true
        entryText.textContainerInset = NSSize(width: 10, height: 10)
        entryText.delegate = self
        entryText.string = draft
        entryText.onControlBacktick = { [weak self] in self?.onCloseRequested?() }

        entryScroll.documentView = entryText
        entryScroll.hasVerticalScroller = false
        entryScroll.drawsBackground = false
        entryScroll.wantsLayer = true
        entryScroll.layer?.cornerRadius = 8
        entryScroll.layer?.borderWidth = 1
        entryScroll.layer?.borderColor = NSColor(calibratedWhite: 0.5, alpha: 0.25).cgColor
        entryScroll.frame = NSRect(x: 46, y: 264, width: bounds.width - 92, height: 88)
        entryText.frame = NSRect(origin: .zero, size: entryScroll.contentSize)
        entryText.autoresizingMask = [.width]

        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.alignment = .center
        hintLabel.frame = NSRect(x: 0, y: 362, width: bounds.width, height: 14)

        keptLabel.font = .systemFont(ofSize: 12, weight: .medium)
        keptLabel.textColor = .systemGreen
        keptLabel.alignment = .center
        keptLabel.frame = NSRect(x: 0, y: 388, width: bounds.width, height: 16)
        keptLabel.isHidden = true

        anotherButton.bezelStyle = .rounded
        anotherButton.controlSize = .small
        anotherButton.font = .systemFont(ofSize: 11)
        anotherButton.target = self
        anotherButton.action = #selector(anotherPromptClicked)
        anotherButton.frame = NSRect(x: bounds.midX - 150, y: 424, width: 140, height: 26)

        journalButton.bezelStyle = .rounded
        journalButton.controlSize = .small
        journalButton.font = .systemFont(ofSize: 11)
        journalButton.target = self
        journalButton.action = #selector(journalClicked)
        journalButton.frame = NSRect(x: bounds.midX + 10, y: 424, width: 140, height: 26)

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
        journalScroll.frame = NSRect(x: 24, y: 52, width: bounds.width - 48, height: 420)
        journalText.frame = NSRect(origin: .zero, size: journalScroll.contentSize)
        journalText.autoresizingMask = [.width]
        journalScroll.isHidden = true

        openFileButton.bezelStyle = .rounded
        openFileButton.controlSize = .small
        openFileButton.font = .systemFont(ofSize: 11)
        openFileButton.target = self
        openFileButton.action = #selector(openFileClicked)
        openFileButton.frame = NSRect(x: bounds.midX - 75, y: 484, width: 150, height: 26)
        openFileButton.isHidden = true

        [captionLabel, traceView, promptLabel, entryScroll, hintLabel, keptLabel,
         anotherButton, journalButton, journalScroll, openFileButton].forEach(addSubview)
    }

    private static func serifFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.serif),
              let serif = NSFont(descriptor: descriptor, size: size) else {
            return base
        }
        return serif
    }

    // MARK: - Prompt flow

    private var currentPrompt: String {
        guard let index = currentPromptIndex, TwoLinesPrompts.all.indices.contains(index) else { return "" }
        return TwoLinesPrompts.all[index]
    }

    private func showPrompt() {
        promptLabel.stringValue = "“\(currentPrompt)”"
    }

    private func advancePrompt() {
        if let previous = currentPromptIndex {
            recentPromptIndices.append(previous)
            let capacity = TwoLinesPromptPicker.recentCapacity(promptCount: TwoLinesPrompts.all.count)
            if recentPromptIndices.count > capacity {
                recentPromptIndices.removeFirst(recentPromptIndices.count - capacity)
            }
        }
        var rng = SystemRandomNumberGenerator()
        currentPromptIndex = TwoLinesPromptPicker.pick(
            promptCount: TwoLinesPrompts.all.count,
            avoiding: recentPromptIndices,
            using: &rng
        )
        showPrompt()
    }

    private func keepEntry() {
        let entry = entryText.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.isEmpty else { return }
        TwoLinesJournal.append(prompt: currentPrompt, entry: entry, date: Date())
        entryText.string = ""
        traceView.seeds = TwoLinesJournal.traceSeeds()
        traceView.highlightsNewestBend = true
        advancePrompt()
        flashKept()
    }

    private func flashKept() {
        keptLabel.stringValue = "kept ✓"
        keptLabel.isHidden = false
        keptFadeTimer?.invalidate()
        keptFadeTimer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.keptLabel.isHidden = true
                self?.traceView.highlightsNewestBend = false
                self?.keptFadeTimer = nil
            }
        }
    }

    private func setJournalVisible(_ visible: Bool) {
        showingJournal = visible
        [traceView, promptLabel, entryScroll, hintLabel, anotherButton, journalButton]
            .forEach { $0.isHidden = visible }
        keptLabel.isHidden = true
        journalScroll.isHidden = !visible
        openFileButton.isHidden = !visible
        captionLabel.stringValue = visible ? "TWO LINES — JOURNAL" : "TWO LINES"
        journalButton.title = "Journal  ⌘J"
        if visible {
            let entries = TwoLinesJournal.recentEntries(limit: 100)
            journalText.string = entries.isEmpty
                ? "Nothing yet. Entries land in ~/.config/cortland/two-lines.md as you write them."
                : entries.joined(separator: "\n")
            journalText.scrollToEndOfDocument(nil)
            window?.makeFirstResponder(self)
        } else {
            traceView.seeds = TwoLinesJournal.traceSeeds()
            window?.makeFirstResponder(entryText)
        }
    }

    // MARK: - Actions and keys

    @objc private func anotherPromptClicked() {
        advancePrompt()
    }

    @objc private func journalClicked() {
        setJournalVisible(!showingJournal)
    }

    @objc private func openFileClicked() {
        NSWorkspace.shared.open(TwoLinesJournal.defaultFileURL)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        guard modifiers == .command else { return super.performKeyEquivalent(with: event) }
        switch event.keyCode {
        case 15: // R
            if !showingJournal {
                advancePrompt()
            }
            return true
        case 38: // J
            setJournalVisible(!showingJournal)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if event.keyCode == 53 || (event.keyCode == 50 && modifiers == .control) {
            onCloseRequested?()
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - NSTextViewDelegate

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            keepEntry()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCloseRequested?()
            return true
        default:
            return false
        }
    }
}

/// An open-ended drawing made from the journal itself. Every entry contributes
/// one turn to two neighboring strokes. There is deliberately no axis, total,
/// or destination: it is a trace of having written, not a meter to fill.
private final class TwoLinesTraceView: NSView {
    var seeds: [UInt64] = [] {
        didSet { needsDisplay = true }
    }

    var highlightsNewestBend = false {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !seeds.isEmpty, bounds.width > 16, bounds.height > 16 else { return }

        let points = tracePoints()
        let firstVisible = max(0, points.count - 65)
        let visible = Array(points[firstVisible...])
        guard visible.count >= 2 else { return }

        for side: CGFloat in [-1, 1] {
            let path = path(for: visible, side: side)
            path.lineWidth = 1.15
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.tertiaryLabelColor.withAlphaComponent(0.62).setStroke()
            path.stroke()

            if highlightsNewestBend, let previous = visible.dropLast().last, let newest = visible.last {
                let glow = NSBezierPath()
                glow.move(to: offset(previous, side: side))
                glow.line(to: offset(newest, side: side))
                glow.lineWidth = 1.7
                glow.lineCapStyle = .round
                NSColor.controlAccentColor.withAlphaComponent(0.75).setStroke()
                glow.stroke()
            }
        }
    }

    private struct TracePoint {
        let point: NSPoint
        let heading: CGFloat
    }

    private func tracePoints() -> [TracePoint] {
        let inset: CGFloat = 5
        var point = NSPoint(x: bounds.midX, y: bounds.midY)
        var heading: CGFloat = -.pi / 2
        var result = [TracePoint(point: point, heading: heading)]

        for seed in seeds {
            let turn = CGFloat(seed & 0xffff) / CGFloat(UInt16.max)
            heading += (turn - 0.5) * 1.35
            let distance = 6.5 + CGFloat((seed >> 16) & 0x7) * 0.55

            var next = NSPoint(
                x: point.x + cos(heading) * distance,
                y: point.y + sin(heading) * distance
            )
            if next.x < inset || next.x > bounds.width - inset {
                heading = .pi - heading
                next.x = point.x + cos(heading) * distance
                next.y = point.y + sin(heading) * distance
            }
            if next.y < inset || next.y > bounds.height - inset {
                heading = -heading
                next.x = point.x + cos(heading) * distance
                next.y = point.y + sin(heading) * distance
            }
            next.x = min(max(next.x, inset), bounds.width - inset)
            next.y = min(max(next.y, inset), bounds.height - inset)
            point = next
            result.append(TracePoint(point: point, heading: heading))
        }
        return result
    }

    private func path(for points: [TracePoint], side: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: offset(points[0], side: side))
        for point in points.dropFirst() {
            path.line(to: offset(point, side: side))
        }
        return path
    }

    private func offset(_ point: TracePoint, side: CGFloat) -> NSPoint {
        let separation: CGFloat = 2.2
        return NSPoint(
            x: point.point.x - sin(point.heading) * separation * side,
            y: point.point.y + cos(point.heading) * separation * side
        )
    }
}

/// Text view that still honors the panel's ⌃` toggle while focused; ⌥return
/// inserts a literal newline for the rare two-line entry.
private final class TwoLinesTextView: NSTextView {
    var onControlBacktick: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if event.keyCode == 50 && modifiers == .control {
            onControlBacktick?()
            return
        }
        if event.keyCode == 36 && modifiers == .option {
            insertNewlineIgnoringFieldEditor(nil)
            return
        }
        super.keyDown(with: event)
    }
}
