import Cocoa

protocol TerminalFindBarDelegate: AnyObject {
    func findBar(_ bar: TerminalFindBar, searchChanged term: String)
    func findBar(_ bar: TerminalFindBar, findNext term: String)
    func findBar(_ bar: TerminalFindBar, findPrevious term: String)
    func findBarDidClose(_ bar: TerminalFindBar)
}

/// Cmd+F overlay for searching the terminal scrollback.
final class TerminalFindBar: NSView {
    weak var delegate: TerminalFindBarDelegate?

    private let searchField = NSSearchField()
    private var fieldDelegate: FindFieldDelegate?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = Theme.shared.palette.surface0.cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = Theme.shared.palette.surface1.cgColor

        searchField.placeholderString = "Find in terminal"
        searchField.font = NSFont.systemFont(ofSize: 12)
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.sendsWholeSearchString = false
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let fieldDelegate = FindFieldDelegate()
        fieldDelegate.onEscape = { [weak self] in self?.requestClose() }
        fieldDelegate.onEnter = { [weak self] shiftHeld in
            guard let self = self else { return }
            let term = self.searchField.stringValue
            guard !term.isEmpty else { return }
            if shiftHeld {
                self.delegate?.findBar(self, findPrevious: term)
            } else {
                self.delegate?.findBar(self, findNext: term)
            }
        }
        searchField.delegate = fieldDelegate
        self.fieldDelegate = fieldDelegate

        let previousButton = makeButton(symbol: "chevron.up", action: #selector(previousClicked))
        previousButton.toolTip = "Previous match (⇧↩)"
        let nextButton = makeButton(symbol: "chevron.down", action: #selector(nextClicked))
        nextButton.toolTip = "Next match (↩)"
        let closeButton = makeButton(symbol: "xmark", action: #selector(closeClicked))
        closeButton.toolTip = "Close (esc)"

        addSubview(searchField)
        addSubview(previousButton)
        addSubview(nextButton)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            searchField.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 220),

            previousButton.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 6),
            previousButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            nextButton.leadingAnchor.constraint(equalTo: previousButton.trailingAnchor, constant: 2),
            nextButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            closeButton.leadingAnchor.constraint(equalTo: nextButton.trailingAnchor, constant: 6),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            heightAnchor.constraint(equalToConstant: 34)
        ])
    }

    private func makeButton(symbol: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.target = self
        button.action = action
        button.contentTintColor = AppTheme.primaryText
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    func focusSearchField() {
        window?.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectedRange = NSRange(
            location: 0,
            length: searchField.stringValue.count
        )
    }

    var searchTerm: String { searchField.stringValue }

    @objc private func searchChanged(_ sender: NSSearchField) {
        delegate?.findBar(self, searchChanged: sender.stringValue)
    }

    @objc private func previousClicked() {
        guard !searchField.stringValue.isEmpty else { return }
        delegate?.findBar(self, findPrevious: searchField.stringValue)
    }

    @objc private func nextClicked() {
        guard !searchField.stringValue.isEmpty else { return }
        delegate?.findBar(self, findNext: searchField.stringValue)
    }

    @objc private func closeClicked() {
        requestClose()
    }

    private func requestClose() {
        delegate?.findBarDidClose(self)
    }

    private final class FindFieldDelegate: NSObject, NSSearchFieldDelegate {
        var onEscape: (() -> Void)?
        var onEnter: ((_ shiftHeld: Bool) -> Void)?

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                onEscape?()
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                onEnter?(NSEvent.modifierFlags.contains(.shift))
                return true
            }
            return false
        }
    }
}
