import Cocoa

/// The editor's read mode for Markdown: a non-editable, selectable text view
/// showing `MarkdownRenderer` output in a centered reading column, with a
/// small Edit control in the corner. It owns no document state; the editor
/// keeps the buffer and hands over a rendered string whenever the file loads,
/// reloads, or the theme changes.
final class MarkdownReaderView: NSView {
    /// Widest the text column gets; past that the margins grow instead, so a
    /// full-width pane reads like a page rather than a wall.
    static let maxColumnWidth: CGFloat = 760
    private static let minInset: CGFloat = 28

    /// A click on a link that resolves to an existing local file. The editor
    /// opens it in this pane; links that are not local go to the browser.
    var onOpenFile: ((URL) -> Void)?
    /// The Edit control asked for the editor.
    var onEditRequested: (() -> Void)?

    private let scrollView = NSScrollView()
    private let textView: NSTextView
    private let editButton = NSButton()

    override init(frame frameRect: NSRect) {
        let textContainer = NSTextContainer()
        textContainer.widthTracksTextView = true
        textContainer.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        // The diff views' layout manager, for the full-width fill behind code
        // blocks (the renderer tags them with the same attribute).
        let layoutManager = DiffLineBackgroundLayoutManager()
        layoutManager.addTextContainer(textContainer)
        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)
        textView = NSTextView(frame: .zero, textContainer: textContainer)

        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: Self.minInset, height: 32)
        textView.delegate = self
        scrollView.documentView = textView
        addSubview(scrollView)

        editButton.title = "Edit"
        editButton.bezelStyle = .inline
        editButton.isBordered = false
        editButton.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        editButton.toolTip = "Switch to the editor (⇧⌘M)"
        editButton.target = self
        editButton.action = #selector(editTapped)
        editButton.translatesAutoresizingMaskIntoConstraints = false
        editButton.alphaValue = 0.7
        addSubview(editButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            editButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            editButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14)
        ])

        applyTheme()
    }

    /// Theme colors, re-applied on a theme change by the editor's applyConfig.
    func applyTheme() {
        scrollView.backgroundColor = AppTheme.windowBackground
        textView.backgroundColor = AppTheme.windowBackground
        textView.insertionPointColor = AppTheme.cursor
        textView.linkTextAttributes = [
            .foregroundColor: AppTheme.accent,
            .cursor: NSCursor.pointingHand
        ]
        editButton.contentTintColor = AppTheme.mutedText
    }

    /// Shows `content`. With `preserveScroll`, the view stays where it was,
    /// and if it was at the bottom it stays at the bottom, so an agent
    /// appending to a note you are reading keeps the new lines in view.
    func setContent(_ content: NSAttributedString, preserveScroll: Bool) {
        let clip = scrollView.contentView
        let previousOrigin = clip.bounds.origin
        let wasAtBottom: Bool = {
            guard let document = scrollView.documentView else { return false }
            let bottomVisible = clip.bounds.maxY
            return document.frame.height - bottomVisible < 4
        }()

        textView.textStorage?.setAttributedString(content)
        layoutColumn()
        if let layoutManager = textView.layoutManager, let container = textView.textContainer {
            layoutManager.ensureLayout(for: container)
        }

        guard preserveScroll else {
            clip.scroll(to: .zero)
            scrollView.reflectScrolledClipView(clip)
            return
        }
        if wasAtBottom {
            textView.scrollToEndOfDocument(nil)
        } else {
            let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
            clip.scroll(to: NSPoint(x: 0, y: min(previousOrigin.y, maxY)))
            scrollView.reflectScrolledClipView(clip)
        }
    }

    /// Whether the view currently shows anything (false before the first
    /// `setContent`).
    var hasContent: Bool { (textView.textStorage?.length ?? 0) > 0 }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    var isFocused: Bool {
        window?.firstResponder === textView
    }

    /// Test hook: the rendered text, for assertions on what the reader shows.
    var _renderedText: NSAttributedString? { textView.textStorage }

    override func layout() {
        super.layout()
        layoutColumn()
    }

    /// Centers the text column: margins grow once the pane is wider than the
    /// column, and shrink to a fixed minimum below that.
    private func layoutColumn() {
        let width = bounds.width
        guard width > 0 else { return }
        let inset = max(Self.minInset, ((width - Self.maxColumnWidth) / 2).rounded(.down))
        if textView.textContainerInset.width != inset {
            textView.textContainerInset = NSSize(width: inset, height: 32)
            textView.needsLayout = true
        }
    }

    @objc private func editTapped() {
        onEditRequested?()
    }
}

extension MarkdownReaderView: NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url: URL?
        if let direct = link as? URL {
            url = direct
        } else if let string = link as? String {
            url = URL(string: string)
        } else {
            url = nil
        }
        guard let url, url.isFileURL else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        onOpenFile?(url)
        return true
    }
}
