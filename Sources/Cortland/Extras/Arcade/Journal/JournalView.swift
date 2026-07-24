import Cocoa

/// Which face of the panel is showing. There is no flow between them that the
/// user did not ask for: nothing advances on its own, and every screen is a
/// fine place to stop.
private enum JournalScreen {
    case picker
    case writing
    case resting
    case browse
}

/// Bounded writing prompts. Agent work is ask, wait, inspect, judge: open
/// loops, machine-paced, evaluative. This inverts it briefly: notice, write,
/// finish. Every prompt carries a size, and the size is a promise of closure,
/// not a quota. The limit measures space used and never time; there is no
/// clock anywhere in here, and a 350-character entry may take four minutes or
/// forty. Typing is never blocked, under is never nagged, and opening the
/// panel and writing nothing is a full, valid way to play.
final class JournalView: NSView, ArcadeGame, NSTextViewDelegate {
    static let gameID = "journal"
    static let title = "Journal"
    static let howToPlay = """
    Pick a door and write one small, complete thing, then get back to work. Each prompt carries a size, which is a promise of closure rather than a target: there is no clock, no minimum, and no penalty for stopping early or running long. Past the limit the meter simply stops filling and your words keep landing.

    Entries append to a plain markdown file per month in ~/.config/cortland/journal, which is yours to read, edit, or delete. Closing mid-thought loses nothing; the draft is waiting when you come back.

    1 / 2 / 3  Clear my head, make something, or reflect
    Return  On the picker, open door 1
    ⌘R  Swap the prompt for another, once per entry
    ⌘↩  Finish the entry and save it
    ⌘⌫  Discard the draft
    B  Browse this month's entries
    Esc  Close the arcade
    """

    private static let contentSize = BlocksGameView.contentSize
    private static let margin: CGFloat = 40

    private let model: JournalModel
    private var screen: JournalScreen = .picker
    private var currentPrompt: JournalPrompt?
    /// A draft the user is being asked about before it is thrown away. The
    /// only confirm in the game, and only because discarding is the one
    /// irreversible thing here.
    private var confirmingDiscard = false
    /// The feel check is showing and will swallow exactly one key.
    private var awaitingFeel = false
    /// Where the entry just written landed, so the feel line can join it.
    private var lastEntryURL: URL?
    /// The resting view's one line. Session-only on purpose: it is a memory of
    /// what just happened, not state, and the markdown is never re-parsed to
    /// reconstruct it.
    private var lastEntryStamp: String?
    private var savedFadeTimer: Timer?

    private let captionLabel = NSTextField(labelWithString: "JOURNAL")
    private let questionLabel = NSTextField(labelWithString: "what do you need right now?")
    private var doorLabels: [NSTextField] = []
    private let promptLabel = NSTextField(wrappingLabelWithString: "")
    private let limitLabel = NSTextField(labelWithString: "")
    private let entryScroll = NSScrollView()
    private let entryText = JournalTextView()
    private let meterView = JournalMeterView()
    private let countLabel = NSTextField(labelWithString: "")
    private let landLabel = NSTextField(labelWithString: "land the thought")
    private let restLabel = NSTextField(labelWithString: "")
    private let savedLabel = NSTextField(labelWithString: "")
    private let feelLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let browseScroll = NSScrollView()
    private let browseText = NSTextView()
    private let openFileButton = NSButton(title: "Open this month", target: nil, action: nil)

    var onCloseRequested: (() -> Void)?

    // MARK: - ArcadeGame

    init(savedState: Data?) {
        let saved = savedState.flatMap { try? JSONDecoder().decode(JournalState.self, from: $0) }
        model = JournalModel(state: saved ?? JournalState(feelSeed: UInt64.random(in: 1...UInt64.max)))
        super.init(frame: NSRect(origin: .zero, size: Self.contentSize))
        buildUI()

        // A draft means Esc was pressed mid-thought: land back in exactly the
        // same prompt with exactly the same words. Anything else opens on the
        // picker, which is an offer and never a demand.
        if let draft = model.snapshot().draft, let prompt = JournalModel.prompt(id: draft.promptID) {
            currentPrompt = prompt
            entryText.string = draft.text
            showWriting()
        } else {
            model.discardDraft()
            showPicker()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    var view: NSView { self }

    func pause() {
        // Nothing is running. The draft is captured by encodeState.
    }

    func resume() {
        needsDisplay = true
    }

    func encodeState() -> Data? {
        model.updateDraft(text: entryText.string)
        return try? JSONEncoder().encode(model.snapshot())
    }

    // MARK: - UI

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        // The panel hands focus to the game view; the writing screen passes it
        // on to the text box (next runloop turn, since a reentrant
        // makeFirstResponder misbehaves).
        DispatchQueue.main.async { [weak self] in
            guard let self, self.screen == .writing, !self.confirmingDiscard else { return }
            self.window?.makeFirstResponder(self.entryText)
        }
        return true
    }

    private func buildUI() {
        wantsLayer = true
        layer?.backgroundColor = AppTheme.windowBackground.cgColor

        let width = bounds.width
        let inner = width - Self.margin * 2

        captionLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        captionLabel.textColor = .tertiaryLabelColor
        captionLabel.alignment = .center
        captionLabel.frame = NSRect(x: 0, y: 22, width: width, height: 14)

        questionLabel.font = Self.serifFont(size: 19, weight: .regular)
        questionLabel.textColor = .labelColor
        questionLabel.alignment = .center
        questionLabel.frame = NSRect(x: Self.margin, y: 150, width: inner, height: 26)

        doorLabels = JournalDoor.allCases.enumerated().map { index, door in
            let label = NSTextField(labelWithString: "[\(door.rawValue)]  \(door.label)")
            label.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.frame = NSRect(x: Self.margin, y: 232 + CGFloat(index) * 38, width: inner, height: 20)
            return label
        }

        promptLabel.font = Self.serifFont(size: 17, weight: .regular)
        promptLabel.textColor = .labelColor
        promptLabel.alignment = .center
        promptLabel.frame = NSRect(x: Self.margin, y: 70, width: inner, height: 76)

        limitLabel.font = .systemFont(ofSize: 11)
        limitLabel.textColor = .tertiaryLabelColor
        limitLabel.alignment = .center
        limitLabel.frame = NSRect(x: Self.margin, y: 154, width: inner, height: 14)

        entryText.font = .systemFont(ofSize: 13)
        entryText.textColor = .labelColor
        entryText.backgroundColor = NSColor(calibratedWhite: 0.5, alpha: 0.08)
        entryText.insertionPointColor = .labelColor
        entryText.isRichText = false
        entryText.allowsUndo = true
        entryText.textContainerInset = NSSize(width: 10, height: 10)
        entryText.delegate = self
        entryText.onControlBacktick = { [weak self] in self?.onCloseRequested?() }

        entryScroll.documentView = entryText
        entryScroll.hasVerticalScroller = true
        entryScroll.autohidesScrollers = true
        entryScroll.drawsBackground = false
        entryScroll.wantsLayer = true
        entryScroll.layer?.cornerRadius = 8
        entryScroll.layer?.borderWidth = 1
        entryScroll.layer?.borderColor = NSColor(calibratedWhite: 0.5, alpha: 0.25).cgColor
        entryScroll.frame = NSRect(x: Self.margin, y: 184, width: inner, height: 246)
        entryText.frame = NSRect(origin: .zero, size: entryScroll.contentSize)
        entryText.autoresizingMask = [.width]

        meterView.frame = NSRect(x: Self.margin, y: 448, width: inner, height: 3)

        countLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.alignment = .left
        countLabel.frame = NSRect(x: Self.margin, y: 460, width: inner / 2, height: 14)

        landLabel.font = .systemFont(ofSize: 11)
        landLabel.textColor = .tertiaryLabelColor
        landLabel.alignment = .right
        landLabel.frame = NSRect(x: bounds.midX, y: 460, width: inner / 2, height: 14)
        landLabel.isHidden = true

        restLabel.font = .systemFont(ofSize: 12)
        restLabel.textColor = .tertiaryLabelColor
        restLabel.alignment = .center
        restLabel.frame = NSRect(x: Self.margin, y: 250, width: inner, height: 16)

        savedLabel.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        savedLabel.textColor = .secondaryLabelColor
        savedLabel.alignment = .center
        savedLabel.frame = NSRect(x: Self.margin, y: 210, width: inner, height: 18)

        feelLabel.font = .systemFont(ofSize: 11)
        feelLabel.textColor = .tertiaryLabelColor
        feelLabel.alignment = .center
        feelLabel.frame = NSRect(x: 0, y: 288, width: width, height: 14)

        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.alignment = .center
        hintLabel.frame = NSRect(x: 0, y: 508, width: width, height: 14)

        browseText.isEditable = false
        browseText.isSelectable = true
        browseText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        browseText.textColor = .labelColor
        browseText.backgroundColor = NSColor(calibratedWhite: 0.5, alpha: 0.06)
        browseText.textContainerInset = NSSize(width: 10, height: 10)
        browseScroll.documentView = browseText
        browseScroll.hasVerticalScroller = true
        browseScroll.autohidesScrollers = true
        browseScroll.drawsBackground = false
        browseScroll.wantsLayer = true
        browseScroll.layer?.cornerRadius = 8
        browseScroll.frame = NSRect(x: 20, y: 46, width: width - 40, height: 408)
        browseText.frame = NSRect(origin: .zero, size: browseScroll.contentSize)
        browseText.autoresizingMask = [.width]

        openFileButton.bezelStyle = .rounded
        openFileButton.controlSize = .small
        openFileButton.font = .systemFont(ofSize: 11)
        openFileButton.target = self
        openFileButton.action = #selector(openFileClicked)
        openFileButton.frame = NSRect(x: bounds.midX - 75, y: 466, width: 150, height: 26)

        [captionLabel, questionLabel, promptLabel, limitLabel, entryScroll, meterView,
         countLabel, landLabel, restLabel, savedLabel, feelLabel, hintLabel,
         browseScroll, openFileButton].forEach(addSubview)
        doorLabels.forEach(addSubview)
    }

    private static func serifFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.serif),
              let serif = NSFont(descriptor: descriptor, size: size) else {
            return base
        }
        return serif
    }

    // MARK: - Screens

    private func showPicker() {
        screen = .picker
        currentPrompt = nil
        confirmingDiscard = false
        awaitingFeel = false
        entryText.string = ""
        applyScreen()
        window?.makeFirstResponder(self)
    }

    private func showWriting() {
        screen = .writing
        confirmingDiscard = false
        awaitingFeel = false
        applyScreen()
        refreshMeter()
        window?.makeFirstResponder(entryText)
    }

    private func showResting() {
        screen = .resting
        currentPrompt = nil
        confirmingDiscard = false
        entryText.string = ""
        applyScreen()
        window?.makeFirstResponder(self)
    }

    private func showBrowse() {
        screen = .browse
        awaitingFeel = false
        let url = JournalFile.fileURL(for: Date())
        let blocks = JournalFile.recentBlocks(limit: 40, from: url)
        browseText.string = blocks.isEmpty
            ? "Nothing this month. Entries land in ~/.config/cortland/journal as you write them."
            : blocks.joined(separator: "\n\n")
        browseText.scrollToBeginningOfDocument(nil)
        applyScreen()
        window?.makeFirstResponder(self)
    }

    private func applyScreen() {
        let picking = screen == .picker
        let writing = screen == .writing
        let resting = screen == .resting
        let browsing = screen == .browse

        questionLabel.isHidden = !picking
        doorLabels.forEach { $0.isHidden = !picking }
        [promptLabel, limitLabel, entryScroll, meterView, countLabel].forEach { $0.isHidden = !writing }
        landLabel.isHidden = true
        restLabel.isHidden = !resting
        savedLabel.isHidden = !resting || savedLabel.stringValue.isEmpty
        feelLabel.isHidden = !(resting && awaitingFeel)
        browseScroll.isHidden = !browsing
        openFileButton.isHidden = !browsing

        if let prompt = currentPrompt, writing {
            promptLabel.stringValue = prompt.text
            limitLabel.stringValue = "in \(prompt.limit) \(prompt.unit.label)"
        }
        if resting {
            restLabel.stringValue = lastEntryStamp.map { "last entry \($0)" } ?? ""
        }
        captionLabel.stringValue = browsing ? "JOURNAL · THIS MONTH" : "JOURNAL"
        hintLabel.stringValue = hintText
    }

    private var hintText: String {
        if confirmingDiscard {
            return "discard this draft? y discards · any other key keeps"
        }
        switch screen {
        case .picker, .resting:
            return "1 clear · 2 make · 3 reflect · b browse · esc close"
        case .writing:
            return "⌘↩ finish · ⌘⌫ discard · esc close"
        case .browse:
            return "b back · esc close"
        }
    }

    // MARK: - Writing

    private func enter(door: JournalDoor) {
        let prompt = model.serve(door: door, seed: UInt64.random(in: 0...UInt64.max))
        currentPrompt = prompt
        model.beginDraft(prompt: prompt, startDate: Date())
        entryText.string = ""
        savedLabel.stringValue = ""
        showWriting()
    }

    private func rerollPrompt() {
        guard screen == .writing,
              let prompt = model.reroll(seed: UInt64.random(in: 0...UInt64.max)) else { return }
        currentPrompt = prompt
        applyScreen()
        refreshMeter()
    }

    private func refreshMeter() {
        guard let prompt = currentPrompt else { return }
        let used = JournalModel.count(entryText.string, unit: prompt.unit)
        let band = JournalModel.band(used: used, limit: prompt.limit)
        meterView.set(fill: JournalModel.fill(used: used, limit: prompt.limit), band: band)
        countLabel.stringValue = "\(used)/\(prompt.limit)"
        // Past the limit the meter is full and the words keep landing. This is
        // the only thing said about it, and it is not an instruction to stop.
        landLabel.stringValue = "land the thought"
        landLabel.isHidden = band != .over
    }

    /// ⌘↩. An empty draft is not an entry: nothing is written, and nothing is
    /// said about it.
    private func finishEntry() {
        guard let prompt = currentPrompt else { return }
        let text = entryText.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            model.discardDraft()
            showPicker()
            return
        }

        let now = Date()
        guard let url = JournalFile.append(prompt: prompt, entry: text, date: now) else {
            // The write failed and said so in the log. Keep the draft and stay
            // put: losing what was just written is the one genuinely bad
            // outcome available here, and it is not going to happen quietly.
            landLabel.stringValue = "could not save; your words are still here"
            landLabel.isHidden = false
            return
        }
        lastEntryURL = url
        lastEntryStamp = JournalFile.dayStamp(for: now)
        let used = JournalModel.count(text, unit: prompt.unit)
        awaitingFeel = model.finishEntry()

        // The one glimpse of the count, and the whole reward. It goes away on
        // its own; nothing keeps a history of it.
        savedLabel.stringValue = "\(used)/\(prompt.limit)"
        feelLabel.stringValue = "how do you feel? 1 calmer · 2 same · 3 wired · any other key skips"
        showResting()
        scheduleSavedFade()
    }

    private func scheduleSavedFade() {
        savedFadeTimer?.invalidate()
        savedFadeTimer = Timer.scheduledTimer(withTimeInterval: 2.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.savedLabel.stringValue = ""
                self.savedLabel.isHidden = true
                self.savedFadeTimer = nil
            }
        }
    }

    private func recordFeeling(_ feeling: String) {
        if let url = lastEntryURL {
            JournalFile.appendFeeling(feeling, to: url)
        }
        dismissFeelCheck()
    }

    private func dismissFeelCheck() {
        awaitingFeel = false
        feelLabel.isHidden = true
    }

    private func beginDiscard() {
        confirmingDiscard = true
        hintLabel.stringValue = hintText
        window?.makeFirstResponder(self)
    }

    private func endDiscard(discarding: Bool) {
        confirmingDiscard = false
        if discarding {
            model.discardDraft()
            showPicker()
        } else {
            showWriting()
        }
    }

    @objc private func openFileClicked() {
        let url = JournalFile.fileURL(for: Date())
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Input

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        guard modifiers == .command, screen == .writing, !confirmingDiscard else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.keyCode {
        case 36: // return
            finishEntry()
            return true
        case 51: // delete
            beginDiscard()
            return true
        case 15: // R
            rerollPrompt()
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

        if confirmingDiscard {
            // Return also discards: the question is one line and the answer is
            // already under the finger.
            endDiscard(discarding: event.keyCode == 16 || event.keyCode == 36) // Y, return
            return
        }

        // The feel check swallows exactly one key, whatever it is, and never
        // asks again.
        if awaitingFeel {
            switch event.keyCode {
            case 18: recordFeeling("calmer")
            case 19: recordFeeling("same")
            case 20: recordFeeling("wired")
            default: dismissFeelCheck()
            }
            return
        }

        switch screen {
        case .picker, .resting:
            switch event.keyCode {
            case 18: enter(door: .clear)      // 1
            case 19: enter(door: .make)       // 2
            case 20: enter(door: .reflect)    // 3
            case 36: enter(door: .clear)      // return: zero decisions to start
            case 11: showBrowse()             // B
            default: super.keyDown(with: event)
            }
        case .browse:
            switch event.keyCode {
            case 11, 49: // B, space
                if lastEntryStamp == nil {
                    showPicker()
                } else {
                    showResting()
                }
            default:
                super.keyDown(with: event)
            }
        case .writing:
            super.keyDown(with: event)
        }
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        model.updateDraft(text: entryText.string)
        refreshMeter()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Return inserts a newline here, unlike Two Lines: these entries have
        // paragraphs, and the file preserves them.
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onCloseRequested?()
            return true
        }
        return false
    }
}

/// The soft ceiling, drawn as shape rather than pressure. It fills to the
/// limit and then stops: there is no overflow state to be in, no flash, no
/// sound, and nothing animates. The colors are the only thing that move, and
/// they only ever say "getting near", never "hurry up".
private final class JournalMeterView: NSView {
    private var fill: Double = 0
    private var band: JournalMeterBand = .neutral

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    func set(fill: Double, band: JournalMeterBand) {
        guard fill != self.fill || band != self.band else { return }
        self.fill = fill
        self.band = band
        needsDisplay = true
    }

    private var color: NSColor {
        switch band {
        case .neutral: return .tertiaryLabelColor
        case .near: return NSColor.systemOrange.withAlphaComponent(0.65)
        case .close, .over: return NSColor.systemRed.withAlphaComponent(0.55)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let radius = bounds.height / 2

        let track = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSColor(calibratedWhite: 0.5, alpha: 0.18).setFill()
        track.fill()

        guard fill > 0 else { return }
        let width = max(bounds.height, bounds.width * CGFloat(fill))
        let filled = NSBezierPath(
            roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height),
            xRadius: radius,
            yRadius: radius
        )
        color.setFill()
        filled.fill()
    }
}

/// Text view that still honors the panel's ⌃` toggle while focused, so closing
/// mid-thought works from inside the box. Nothing is lost either way: the
/// draft is on its way to encodeState.
private final class JournalTextView: NSTextView {
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
