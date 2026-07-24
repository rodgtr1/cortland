import Cocoa

/// A floating, read-only view of a past session's transcript — the "read it
/// without resuming it" half of Session Recall. Opened with ⌘↩ from the
/// `SessionsPanel`; renders the ordered `SessionTranscript` turns as selectable
/// attributed text so you can see what was said, copy from it, then close.
///
/// Modeled on `KeyboardShortcutsPanel`: a titled/closable/resizable `NSPanel`
/// that is *not* released when closed (its owner — `SessionsPanel` — retains and
/// reuses one instance, so releasing it would crash the next preview).
final class SessionPreviewPanel: NSPanel {
    private let textView = PreviewTextView()

    /// Bumped on every `show(record:)`. A background parse captures the value at
    /// dispatch and only installs its result if it still matches on completion —
    /// so previewing a second record before the first finishes parsing can't let
    /// the stale (slower) parse overwrite the newer preview.
    private var generation = 0

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        setupPanel()
        setupUI()
    }

    private func setupPanel() {
        level = .floating
        isFloatingPanel = true
        // The owner keeps a strong reference and reuses this instance, so closing
        // must order it out rather than release it.
        isReleasedWhenClosed = false
        center()
    }

    private func setupUI() {
        guard let contentView = contentView else { return }

        let containerView = NSView()
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = AppTheme.windowBackground.cgColor
        containerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(containerView)

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.onEscape = { [weak self] in self?.close() }

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            containerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            scrollView.topAnchor.constraint(equalTo: containerView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])
    }

    // MARK: - Presentation

    /// Present the panel immediately (with a "Loading…" placeholder) for the
    /// given session, then parse its transcript OFF the main thread and swap in
    /// the rendered turns — mirroring how `SessionsPanel.loadSessions` drains work
    /// off-main and applies on main. The window title shows the session's display
    /// title.
    func show(record: SessionRecord) {
        title = record.aiTitle ?? record.title
        generation += 1
        let requestGeneration = generation
        setPlaceholder("Loading…")
        makeKeyAndOrderFront(nil)

        let url = URL(fileURLWithPath: record.logPath)
        let agent = record.agent
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let turns = SessionTranscript.turns(at: url)
            DispatchQueue.main.async {
                guard let self, requestGeneration == self.generation else { return }
                self.render(turns: turns, agent: agent)
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            close()
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Rendering

    private func render(turns: [SessionTranscript.Turn], agent: SessionAgent) {
        guard !turns.isEmpty else {
            setPlaceholder("No transcript to preview.")
            return
        }
        textView.textStorage?.setAttributedString(attributedTranscript(turns, agent: agent))
        textView.scrollToBeginningOfDocument(nil)
    }

    /// A single "Loading…" / empty-state line in muted text.
    private func setPlaceholder(_ message: String) {
        textView.textStorage?.setAttributedString(NSAttributedString(string: message, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: AppTheme.mutedText
        ]))
    }

    /// Render the turns as attributed text: a bold, colored header per turn — "You"
    /// / "Claude" / "Codex" / "› tool" — with the body below in primary text and a
    /// blank line between turns.
    private func attributedTranscript(_ turns: [SessionTranscript.Turn], agent: SessionAgent) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, turn) in turns.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n\n")) }
            result.append(NSAttributedString(string: header(for: turn.role, agent: agent) + "\n", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 13),
                .foregroundColor: headerColor(for: turn.role)
            ]))
            result.append(NSAttributedString(string: turn.text, attributes: [
                .font: bodyFont(for: turn.role),
                .foregroundColor: AppTheme.primaryText
            ]))
        }
        return result
    }

    private func header(for role: SessionTranscript.Role, agent: SessionAgent) -> String {
        switch role {
        case .user: return "You"
        case .assistant: return agent == .claude ? "Claude" : "Codex"
        case .tool: return "› tool"
        }
    }

    private func headerColor(for role: SessionTranscript.Role) -> NSColor {
        switch role {
        case .user: return AppTheme.primaryText
        case .assistant: return AppTheme.accent
        case .tool: return AppTheme.mutedText
        }
    }

    /// Tool turns are commands, so render them monospaced; prose stays in the
    /// system font.
    private func bodyFont(for role: SessionTranscript.Role) -> NSFont {
        switch role {
        case .tool: return NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        default: return NSFont.systemFont(ofSize: 13)
        }
    }
}

/// An `NSTextView` that closes its panel on Escape. The text view is the panel's
/// first responder (so selection/copy work), which would otherwise swallow
/// Escape before the panel's `keyDown` sees it.
private final class PreviewTextView: NSTextView {
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}
