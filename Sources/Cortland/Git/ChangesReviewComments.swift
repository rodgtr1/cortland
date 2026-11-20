import Cocoa

/// Review comments in the changes pane: notes the user attaches to diff
/// lines and sends to an agent as one prompt. Everything here is plain values
/// and pure functions so the decisions are testable without a window.
nonisolated enum ChangesComments {
    /// One rendered diff line as a comment quotes it.
    struct Line: Equatable {
        let kind: DiffGutterLine.Kind
        /// New-file line number; nil for removed lines.
        let number: Int?
        /// The code as rendered, without the line break.
        let text: String
    }

    /// One row of a rendered diff: its character range (line break
    /// included) and, for a diff line, what it shows. Hunk headers,
    /// separators, and the "No changes" placeholder have no line.
    struct Row: Equatable {
        let range: NSRange
        let line: Line?
    }

    /// The new-file line numbers a comment points at.
    struct Location: Equatable {
        let first: Int
        let last: Int
    }

    enum Anchor: Equatable {
        /// Rows of the file's current rendered diff, first to last commented row.
        case attached(Range<Int>)
        /// The section was rebuilt and its body is not built yet.
        case pending
        /// The quoted code is no longer in the diff exactly once.
        case detached
    }

    struct Comment: Equatable {
        let id: UUID
        /// Relative to the repository root.
        let path: String
        var text: String
        /// The quoted diff lines, hunk headers and separators left out.
        var lines: [Line]
        var location: Location?
        var anchor: Anchor
    }

    /// An agent pane the comments can go to.
    struct Agent: Equatable {
        let id: UUID
        let label: String
    }

    /// What the review bar's primary button does.
    enum SendMode: Equatable {
        case copy
        case send(Agent)
        case choose([Agent])

        init(agents: [Agent]) {
            switch agents.count {
            case 0: self = .copy
            case 1: self = .send(agents[0])
            default: self = .choose(agents)
            }
        }
    }

    /// A pane the window knows about, as the candidate filter sees it.
    struct AgentPane: Equatable {
        let id: UUID
        let label: String
        let directory: String?
        let runsAgent: Bool
    }

    static let maxQuotedLines = 8
    static let detachedNote = "(This code has changed since the comment was written.)"

    // MARK: - Rows

    /// Splits a rendered diff into rows, reading each row's gutter attribute.
    static func rows(in text: NSAttributedString) -> [Row] {
        let string = text.string as NSString
        var rows: [Row] = []
        var location = 0
        while location < string.length {
            let newline = string.range(of: "\n", range: NSRange(location: location, length: string.length - location))
            let end = newline.location == NSNotFound ? string.length : NSMaxRange(newline)
            let range = NSRange(location: location, length: end - location)
            let textLength = newline.location == NSNotFound ? range.length : range.length - 1
            let line = (text.attribute(InlineDiffRenderer.gutterLine, at: location, effectiveRange: nil) as? DiffGutterLine).map {
                Line(kind: $0.kind, number: $0.number, text: string.substring(with: NSRange(location: location, length: textLength)))
            }
            rows.append(Row(range: range, line: line))
            location = end
        }
        return rows
    }

    /// The rows a character range touches, trimmed to its first and last
    /// diff line. nil when it touches no diff line or is empty.
    static func rowRange(touching characters: NSRange, rows: [Row]) -> Range<Int>? {
        guard characters.length > 0 else { return nil }
        let touched = rows.indices.filter { index in
            let row = rows[index]
            return row.line != nil
                && row.range.location < NSMaxRange(characters)
                && NSMaxRange(row.range) > characters.location
        }
        guard let first = touched.first, let last = touched.last else { return nil }
        return first..<(last + 1)
    }

    /// The diff row holding a character index, if it is a diff line.
    static func row(atCharacter index: Int, rows: [Row]) -> Int? {
        guard let row = rows.firstIndex(where: { NSLocationInRange(index, $0.range) }),
              rows[row].line != nil else { return nil }
        return row
    }

    /// The quoted lines of a row range.
    static func lines(in range: Range<Int>, rows: [Row]) -> [Line] {
        rows[range].compactMap(\.line)
    }

    // MARK: - Location

    /// The new-file numbers of the commented rows. Rows with no number
    /// (removed lines only) borrow the nearest following numbered row, then
    /// the nearest preceding one; nil when the diff has none.
    static func location(of range: Range<Int>, rows: [Row]) -> Location? {
        let numbers = rows[range].compactMap { $0.line?.number }
        if let first = numbers.first, let last = numbers.last {
            return Location(first: first, last: last)
        }
        if let number = rows[range.upperBound...].lazy.compactMap({ $0.line?.number }).first {
            return Location(first: number, last: number)
        }
        if let number = rows[..<range.lowerBound].reversed().lazy.compactMap({ $0.line?.number }).first {
            return Location(first: number, last: number)
        }
        return nil
    }

    // MARK: - Re-anchoring

    /// Where `lines` sit in a new rendered diff: the rows of the one place
    /// that exact sequence (kinds and text) appears, or nil when it appears
    /// nowhere or more than once.
    static func reanchor(_ lines: [Line], in rows: [Row]) -> Range<Int>? {
        guard !lines.isEmpty else { return nil }
        let diffRows = rows.indices.filter { rows[$0].line != nil }
        guard diffRows.count >= lines.count else { return nil }
        var match: Range<Int>?
        for start in 0...(diffRows.count - lines.count) {
            let candidate = diffRows[start..<(start + lines.count)]
            let same = zip(candidate, lines).allSatisfy { index, line in
                rows[index].line.map { $0.kind == line.kind && $0.text == line.text } ?? false
            }
            guard same else { continue }
            if match != nil { return nil }
            match = candidate.first!..<(candidate.last! + 1)
        }
        return match
    }

    // MARK: - Agents

    /// `directory` is `root` or inside it. A sibling whose name only starts
    /// with the root's name is not inside.
    static func isWithin(_ directory: String, root: String) -> Bool {
        let directory = (directory as NSString).standardizingPath
        let root = (root as NSString).standardizingPath
        if directory == root { return true }
        return directory.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Panes running an agent whose working directory is in the repository.
    static func candidates(_ panes: [AgentPane], repositoryPath: String) -> [Agent] {
        panes.compactMap { pane in
            guard pane.runsAgent, let directory = pane.directory,
                  isWithin(directory, root: repositoryPath) else { return nil }
            return Agent(id: pane.id, label: pane.label)
        }
    }

    // MARK: - Keys

    /// ⌘↩ (Return or keypad Enter, Command only), and only while comments exist.
    static func isSendKey(characters: String?, modifierFlags: NSEvent.ModifierFlags, hasComments: Bool) -> Bool {
        guard hasComments,
              modifierFlags.intersection([.command, .control, .option, .shift]) == .command else { return false }
        return characters == "\r" || characters == "\u{3}"
    }

    // MARK: - Message

    static func countText(_ count: Int) -> String {
        count == 1 ? "1 comment" : "\(count) comments"
    }

    /// The prompt sent to the agent, comments ordered by path then line,
    /// under `intro` (the pane source's first line).
    static func message(for comments: [Comment], intro: String) -> String {
        let ordered = comments.enumerated().sorted { a, b in
            if a.element.path != b.element.path { return a.element.path < b.element.path }
            let lineA = a.element.location?.first ?? Int.max
            let lineB = b.element.location?.first ?? Int.max
            if lineA != lineB { return lineA < lineB }
            return a.offset < b.offset
        }.map(\.element)

        var items: [String] = []
        for (index, comment) in ordered.enumerated() {
            var item = ["\(index + 1). \(locationText(comment))"]
            for line in comment.lines.prefix(maxQuotedLines) {
                item.append("   > \(marker(line.kind))\(line.text)")
            }
            if comment.lines.count > maxQuotedLines {
                item.append("   > ... (\(comment.lines.count - maxQuotedLines) more lines)")
            }
            if comment.anchor == .detached {
                item.append("   \(detachedNote)")
            }
            for textLine in comment.text.components(separatedBy: "\n") {
                item.append("   \(textLine)")
            }
            items.append(item.joined(separator: "\n"))
        }
        return ([intro] + items)
            .joined(separator: "\n\n")
    }

    private static func locationText(_ comment: Comment) -> String {
        guard let location = comment.location else { return comment.path }
        if location.first == location.last {
            return "\(comment.path):\(location.first)"
        }
        return "\(comment.path):\(location.first)-\(location.last)"
    }

    private static func marker(_ kind: DiffGutterLine.Kind) -> String {
        switch kind {
        case .removed: return "-"
        case .added: return "+"
        case .context: return " "
        }
    }
}

// MARK: - Views

/// The popover's text field: Esc cancels instead of NSTextView's completion.
final class ChangesCommentTextView: NSTextView {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// The popover content for writing or editing one comment.
final class ChangesCommentEditor: NSViewController {
    var onSave: ((String) -> Void)?
    var onDelete: (() -> Void)?
    var onCancel: (() -> Void)?

    private let initialText: String
    private let canDelete: Bool
    private var textView: ChangesCommentTextView!

    init(text: String, canDelete: Bool) {
        self.initialText = text
        self.canDelete = canDelete
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 150))

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = ChangesCommentTextView(frame: NSRect(x: 0, y: 0, width: 296, height: 96))
        textView.minSize = NSSize(width: 0, height: 96)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textColor = AppTheme.primaryText
        textView.backgroundColor = AppTheme.windowBackground
        textView.insertionPointColor = AppTheme.primaryText
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.string = initialText
        textView.onCancel = { [weak self] in self?.onCancel?() }
        scrollView.documentView = textView
        self.textView = textView

        let comment = NSButton(title: "Comment", target: self, action: #selector(saveClicked))
        comment.bezelStyle = .rounded
        comment.controlSize = .small
        comment.keyEquivalent = "\r"
        comment.keyEquivalentModifierMask = [.command]
        comment.toolTip = "Comment (⌘↩)"

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        cancel.controlSize = .small
        cancel.keyEquivalent = "\u{1b}"

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        if canDelete {
            let delete = NSButton(title: "Delete", target: self, action: #selector(deleteClicked))
            delete.bezelStyle = .rounded
            delete.controlSize = .small
            buttons.addArrangedSubview(delete)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttons.addArrangedSubview(spacer)
        buttons.addArrangedSubview(cancel)
        buttons.addArrangedSubview(comment)

        container.addSubview(scrollView)
        container.addSubview(buttons)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            scrollView.heightAnchor.constraint(equalToConstant: 96),

            buttons.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            buttons.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            buttons.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            buttons.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10)
        ])
        view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }

    @objc private func saveClicked() {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            onCancel?()
        } else {
            onSave?(text)
        }
    }

    @objc private func cancelClicked() {
        onCancel?()
    }

    @objc private func deleteClicked() {
        onDelete?()
    }
}

/// The gutter icon at a commented range's first line. Several comments can
/// start on the same line; the icon then offers a menu of them.
final class ChangesCommentIcon: NSButton {
    var commentIDs: [UUID] = []
}
