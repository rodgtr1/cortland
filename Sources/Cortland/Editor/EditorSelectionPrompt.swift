import Cocoa

/// Send Selection to Agent: the editor's selected lines, with an instruction
/// the user types, go to the agent working in the file's repository as one
/// prompt. The decisions are plain values and pure functions so they are
/// testable without a window.
nonisolated enum EditorSelectionPrompt {
    /// 1-based, inclusive line numbers.
    struct LineRange: Equatable {
        let first: Int
        let last: Int
    }

    static let maxQuotedLines = 40
    static let unsavedNote = "The quoted code is from the unsaved editor buffer and may differ from the file on disk."

    /// The command applies to an editor pane showing the editor, not the
    /// Markdown reader.
    static func applies(isEditorPane: Bool, isReadMode: Bool) -> Bool {
        isEditorPane && !isReadMode
    }

    // MARK: - Lines

    /// The whole lines a selection touches. A selection that ends at column 0
    /// of a line leaves that line out; an empty selection is the caret's line.
    static func lineRange(in text: String, selection: NSRange) -> LineRange {
        let string = text as NSString
        let start = min(max(selection.location, 0), string.length)
        let first = lineNumber(at: start, in: string)
        guard selection.length > 0 else { return LineRange(first: first, last: first) }
        let end = min(NSMaxRange(selection), string.length)
        guard end > start else { return LineRange(first: first, last: first) }
        // The last selected character: a line break belongs to the line it ends.
        return LineRange(first: first, last: max(first, lineNumber(at: end - 1, in: string)))
    }

    /// The 1-based line holding the character at `index`. At the end of the
    /// text that is the last line, or the empty line after a final line break.
    static func lineNumber(at index: Int, in string: NSString) -> Int {
        var line = 1
        var location = 0
        while location < string.length {
            var lineEnd = 0
            var contentsEnd = 0
            string.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            if index < lineEnd || (lineEnd == string.length && contentsEnd == lineEnd) {
                return line
            }
            location = lineEnd
            line += 1
        }
        return line
    }

    /// The text of lines `range.first...range.last`, without line breaks.
    /// A line past the end of the text is empty.
    static func lines(in text: String, range: LineRange) -> [String] {
        let string = text as NSString
        var result: [String] = []
        var line = 1
        var location = 0
        while location < string.length, line <= range.last {
            var lineEnd = 0
            var contentsEnd = 0
            string.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            if line >= range.first {
                result.append(string.substring(with: NSRange(location: location, length: contentsEnd - location)))
            }
            location = lineEnd
            line += 1
        }
        while line <= range.last {
            if line >= range.first { result.append("") }
            line += 1
        }
        return result
    }

    // MARK: - Reference

    /// The path relative to the repository root when the file is inside it,
    /// otherwise the absolute path, then `:line` or `:first-last`.
    static func reference(filePath: String, repositoryRoot: String?, lines: LineRange) -> String {
        let path = displayPath(filePath: filePath, repositoryRoot: repositoryRoot)
        if lines.first == lines.last {
            return "\(path):\(lines.first)"
        }
        return "\(path):\(lines.first)-\(lines.last)"
    }

    private static func displayPath(filePath: String, repositoryRoot: String?) -> String {
        let file = (filePath as NSString).standardizingPath
        guard let repositoryRoot else { return file }
        // git reports the root with symlinks resolved; the editor may hold
        // the file by a symlinked path.
        let candidates = [file, (file as NSString).resolvingSymlinksInPath]
        let roots = [(repositoryRoot as NSString).standardizingPath, (repositoryRoot as NSString).resolvingSymlinksInPath]
        for candidate in candidates {
            for root in roots where candidate != root && ChangesComments.isWithin(candidate, root: root) {
                let prefix = root.hasSuffix("/") ? root : root + "/"
                return String(candidate.dropFirst(prefix.count))
            }
        }
        return file
    }

    // MARK: - Message

    /// The prompt: the instruction, the reference, the quoted lines (capped),
    /// and a note when the buffer has unsaved changes.
    static func message(instruction: String, reference: String, lines: [String], isDirty: Bool) -> String {
        let quoted = Array(lines.prefix(maxQuotedLines))
        let fence = self.fence(for: quoted)
        var blocks = [
            instruction.trimmingCharacters(in: .whitespacesAndNewlines),
            reference,
            ([fence] + quoted + [fence]).joined(separator: "\n")
        ]
        let remaining = lines.count - quoted.count
        if remaining > 0 {
            let count = remaining == 1 ? "1 more line" : "\(remaining) more lines"
            blocks.append("(The range has \(count) not quoted here. Read the file for the rest.)")
        }
        if isDirty {
            blocks.append(unsavedNote)
        }
        return blocks.joined(separator: "\n\n")
    }

    /// A backtick fence longer than any backtick run in the code, so a fence
    /// inside the selection cannot close the block.
    static func fence(for lines: [String]) -> String {
        var longest = 0
        for line in lines {
            var run = 0
            for character in line {
                if character == "`" {
                    run += 1
                    longest = max(longest, run)
                } else {
                    run = 0
                }
            }
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }

    // MARK: - Primary button

    struct PrimaryButton: Equatable {
        enum Action: Equatable {
            case send(ChangesComments.Agent)
            case chooseFromMenu([ChangesComments.Agent])
            case copy
        }

        let title: String
        let isEnabled: Bool
        let action: Action
    }

    /// The popover's primary button, by the changes pane's three-way rule.
    /// Disabled while the instruction is empty.
    static func primaryButton(for mode: ChangesComments.SendMode, instruction: String) -> PrimaryButton {
        let isEnabled = !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch mode {
        case .copy:
            return PrimaryButton(title: "Copy", isEnabled: isEnabled, action: .copy)
        case .send(let agent):
            return PrimaryButton(title: "Send to \(agent.label)", isEnabled: isEnabled, action: .send(agent))
        case .choose(let agents):
            return PrimaryButton(title: "Send to Agent", isEnabled: isEnabled, action: .chooseFromMenu(agents))
        }
    }
}

// MARK: - Popover

/// The popover content: the reference that will be sent and a field for the
/// instruction. Styled like the changes pane's comment editor.
final class EditorSelectionPromptEditor: NSViewController, NSTextFieldDelegate {
    /// Called with the chosen agent, or nil to copy. Returns whether it went.
    var onDeliver: ((ChangesComments.Agent?, String) -> Bool)?
    var onCancel: (() -> Void)?

    private let reference: String
    private let agents: () -> [ChangesComments.Agent]
    private var displayedMode: ChangesComments.SendMode
    private var field: NSTextField!
    private var primary: NSButton!

    init(reference: String, agents: @escaping () -> [ChangesComments.Agent]) {
        self.reference = reference
        self.agents = agents
        self.displayedMode = ChangesComments.SendMode(agents: agents())
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 100))

        let label = NSTextField(labelWithString: reference)
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = AppTheme.mutedText
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false

        let field = NSTextField()
        field.placeholderString = "Instruction for the agent"
        field.font = NSFont.systemFont(ofSize: 13)
        field.textColor = AppTheme.primaryText
        field.backgroundColor = AppTheme.windowBackground
        field.drawsBackground = true
        field.bezelStyle = .squareBezel
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        self.field = field

        let primary = NSButton(title: "", target: self, action: #selector(primaryClicked))
        primary.bezelStyle = .rounded
        primary.controlSize = .small
        self.primary = primary

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        cancel.controlSize = .small
        cancel.keyEquivalent = "\u{1b}"

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttons.addArrangedSubview(spacer)
        buttons.addArrangedSubview(cancel)
        buttons.addArrangedSubview(primary)

        container.addSubview(label)
        container.addSubview(field)
        container.addSubview(buttons)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),

            field.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 6),
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),

            buttons.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            buttons.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            buttons.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            buttons.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10)
        ])
        view = container
        updatePrimary()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
    }

    private var button: EditorSelectionPrompt.PrimaryButton {
        EditorSelectionPrompt.primaryButton(for: displayedMode, instruction: field?.stringValue ?? "")
    }

    private func updatePrimary() {
        let button = self.button
        primary.title = button.title
        primary.isEnabled = button.isEnabled
    }

    func controlTextDidChange(_ obj: Notification) {
        updatePrimary()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            performPrimary()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default:
            return false
        }
    }

    @objc private func primaryClicked() {
        performPrimary()
    }

    @objc private func cancelClicked() {
        onCancel?()
    }

    /// Agents are asked again; a single agent or the clipboard is used only
    /// if it is what the button showed, otherwise the button is brought up
    /// to date for the user to press again.
    private func performPrimary() {
        guard button.isEnabled else { return }
        let mode = ChangesComments.SendMode(agents: agents())
        let changed = mode != displayedMode
        if changed {
            displayedMode = mode
            updatePrimary()
        }
        switch button.action {
        case .chooseFromMenu(let agents):
            showAgentMenu(agents)
        case .send(let agent):
            guard !changed else { return }
            deliver(to: agent)
        case .copy:
            guard !changed else { return }
            deliver(to: nil)
        }
    }

    private func showAgentMenu(_ agents: [ChangesComments.Agent]) {
        let menu = NSMenu()
        for agent in agents {
            let item = NSMenuItem(title: agent.label, action: #selector(agentChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = agent.id
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: primary.bounds.height + 4), in: primary)
    }

    @objc private func agentChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let agent = agents().first(where: { $0.id == id }) else {
            displayedMode = ChangesComments.SendMode(agents: agents())
            updatePrimary()
            return
        }
        deliver(to: agent)
    }

    private func deliver(to agent: ChangesComments.Agent?) {
        guard onDeliver?(agent, field.stringValue) == true else {
            NSSound.beep()
            displayedMode = ChangesComments.SendMode(agents: agents())
            updatePrimary()
            return
        }
    }
}
