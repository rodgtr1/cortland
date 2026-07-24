import Cocoa

class LineNumberRulerView: NSRulerView {
    private var textView: NSTextView?

    /// Character indices of every newline in the document, ascending. Counting
    /// the lines above the first visible one is then a binary search instead of
    /// a scan from character 0 — which was ~1M `character(at:)` calls per frame
    /// at the bottom of a large file (visible scroll jank). Rebuilt lazily on
    /// the next draw after a character edit, never per scroll frame.
    private var newlineIndices: [Int]?

    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        setup()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        clientView = scrollView?.documentView
        ruleThickness = 50
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
    }

    func attach(to textView: NSTextView) {
        self.textView = textView
        clientView = textView
        observeTextStorage(of: textView)
    }

    // NSRulerView.awakeFromNib is nonisolated in the SDK; AppKit always invokes
    // it on the main thread, so we assert main-actor isolation to reach the view.
    nonisolated override func awakeFromNib() {
        MainActor.assumeIsolated {
            super.awakeFromNib()
            if let textView = clientView as? NSTextView {
                self.textView = textView
                observeTextStorage(of: textView)
            }
        }
    }

    /// Redraw and drop the cached newline table whenever the document's
    /// characters change. Observing the text storage (rather than
    /// `NSText.didChangeNotification`) also catches programmatic loads
    /// (`textView.string = …` on a reused editor) while ignoring attribute-only
    /// edits such as syntax highlighting, which never move line numbers.
    private func observeTextStorage(of textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTextStorageEditing(_:)),
            name: NSTextStorage.didProcessEditingNotification,
            object: storage
        )
    }

    @objc private func handleTextStorageEditing(_ note: Notification) {
        guard let storage = note.object as? NSTextStorage,
              storage.editedMask.contains(.editedCharacters) else { return }
        newlineIndices = nil
        needsDisplay = true
    }

    /// Ascending indices of every newline, built once per edit and reused
    /// across scroll frames.
    private func newlineTable(for text: NSString) -> [Int] {
        if let cached = newlineIndices { return cached }
        var indices: [Int] = []
        let length = text.length
        var searchStart = 0
        while searchStart < length {
            let found = text.range(
                of: "\n",
                options: [],
                range: NSRange(location: searchStart, length: length - searchStart)
            )
            if found.location == NSNotFound { break }
            indices.append(found.location)
            searchStart = found.location + 1
        }
        newlineIndices = indices
        return indices
    }

    /// Number of newlines strictly before `location` (lower-bound partition of
    /// the sorted table) — i.e. how many lines precede the character at
    /// `location`.
    private func newlineCount(before location: Int, in sorted: [Int]) -> Int {
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < location {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let textView = self.textView,
              let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager else {
            return
        }

        // Clear background
        let backgroundColor = AppTheme.sidebarBackground
        backgroundColor.setFill()
        context.fill(bounds)

        // Draw separator line
        let separatorColor = Theme.shared.palette.surface0
        separatorColor.setStroke()
        let separatorRect = NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height)
        context.stroke(separatorRect)

        let textString = textView.string as NSString
        let glyphRange = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: textContainer)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        // Line number of the first visible line = 1 + (newlines above it).
        // Binary search the cached newline table instead of rescanning the
        // document from character 0 on every draw.
        let newlines = newlineTable(for: textString)
        var lineNumber = 1 + newlineCount(before: characterRange.location, in: newlines)
        var charIndex = characterRange.location

        // Draw line numbers for visible lines
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let textColor = AppTheme.mutedText
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]

        var lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        charIndex = characterRange.location

        while charIndex < NSMaxRange(characterRange) {
            let lineNumberString = "\(lineNumber)" as NSString
            let lineNumberSize = lineNumberString.size(withAttributes: attributes)

            let drawRect = NSRect(
                x: bounds.width - lineNumberSize.width - 8,
                y: lineRect.minY,
                width: lineNumberSize.width,
                height: lineNumberSize.height
            )

            lineNumberString.draw(in: drawRect, withAttributes: attributes)

            // Find next line
            let lineRange = textString.lineRange(for: NSRange(location: charIndex, length: 0))
            charIndex = NSMaxRange(lineRange)
            lineNumber += 1

            if charIndex < textString.length {
                let glyphIndex = layoutManager.glyphIndexForCharacter(at: charIndex)
                lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            }
        }
    }
}
