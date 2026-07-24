import Cocoa

/// One executable action in the command palette.
struct PaletteAction {
    let title: String
    let subtitle: String?
    let symbolName: String
    let handler: () -> Void

    init(title: String, subtitle: String? = nil, symbolName: String = "command", handler: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.handler = handler
    }
}

/// Cmd+Shift+P palette: fuzzy-filters app actions and runs the selected one.
/// The panel chrome (search field, table, key handling) lives in
/// `FilterableListPanel`; this subclass supplies the action list and cells.
class CommandPalettePanel: FilterableListPanel {
    private var allActions: [PaletteAction] = []
    private var filteredActions: [PaletteAction] = []

    init() {
        super.init(chrome: Chrome(
            title: "Commands",
            placeholder: "Type a command…",
            size: NSSize(width: 560, height: 380),
            columnIdentifier: "PaletteAction",
            hidesOnDeactivate: true
        ))
    }

    // MARK: - FilterableListPanel hooks

    override var itemCount: Int { filteredActions.count }

    override func cellView(forRow row: Int) -> NSView? {
        let cell = PaletteActionCellView()
        cell.configure(with: filteredActions[row])
        return cell
    }

    override func queryChanged(_ query: String) {
        if query.isEmpty {
            filteredActions = allActions
        } else {
            filteredActions = allActions
                .compactMap { action -> (PaletteAction, Int)? in
                    guard let score = FuzzyScorer.score(candidate: action.title, query: query) else { return nil }
                    return (action, score)
                }
                .sorted { $0.1 > $1.1 }
                .map { $0.0 }
        }
        reloadAndSelectFirst()
    }

    override func activateRow(_ row: Int) {
        let action = filteredActions[row]
        close()
        action.handler()
    }

    func show(relativeTo parentWindow: NSWindow, actions: [PaletteAction]) {
        allActions = actions
        filteredActions = actions

        let parentFrame = parentWindow.frame
        setFrameOrigin(NSPoint(
            x: parentFrame.midX - frame.width / 2,
            y: parentFrame.midY + 80
        ))

        searchField.stringValue = ""
        reloadAndSelectFirst()

        makeKeyAndOrderFront(nil)
        searchField.becomeFirstResponder()
    }
}

private final class PaletteActionCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentTintColor = AppTheme.accent

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = AppTheme.primaryText
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        subtitleLabel.textColor = AppTheme.mutedText
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 10),
            subtitleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)
        ])
    }

    func configure(with action: PaletteAction) {
        iconView.image = NSImage(systemSymbolName: action.symbolName, accessibilityDescription: action.title)
        titleLabel.stringValue = action.title
        subtitleLabel.stringValue = action.subtitle ?? ""
    }
}
