import Cocoa

// MARK: - Entries

/// One `[[palette]]` entry of an enabled extension, as the command palette
/// lists it.
nonisolated struct ExtensionPaletteCommand: Equatable, Sendable {
    let installed: InstalledExtension
    let entry: ExtensionPaletteEntry

    /// `<panel title>: <entry title>`, for example "Widgets: New Widget".
    var title: String {
        "\(installed.manifest.panel?.title ?? installed.manifest.name): \(entry.title)"
    }

    /// The panel's icon when it is an SF Symbol name; a generic extension
    /// symbol when the panel draws an image file.
    var symbolName: String {
        guard let panel = installed.manifest.panel, panel.iconURL == nil else { return "puzzlepiece.extension" }
        return panel.icon
    }

    /// Every enabled extension's entries: extensions in sidebar order (by
    /// name), each extension's entries in manifest order.
    static func commands(for extensions: [InstalledExtension]) -> [ExtensionPaletteCommand] {
        InstalledExtension.panelExtensions(extensions).flatMap { installed in
            installed.manifest.palette.map { ExtensionPaletteCommand(installed: installed, entry: $0) }
        }
    }
}

// MARK: - Choosing an entry

/// Carries out a chosen palette entry: runs the extension's `panel` command
/// fresh, finds the action (on the panel, or on a row the user picks), and
/// hands it to `performAction`, which goes through the extension's shared
/// action runner like a click in the sidebar panel.
final class ExtensionPaletteCommandRunner {
    /// Runs `<command> panel` for the extension and calls the completion on
    /// the main actor. The default runs it on a background queue.
    typealias PanelLoader = (
        _ installed: InstalledExtension,
        _ completion: @escaping @MainActor (Result<ExtensionPanelContent, ExtensionPanelError>) -> Void
    ) -> Void

    /// Offers `rows` to pick from under `title`. Calls the completion with
    /// the chosen row, or never when the user cancels.
    typealias RowPicker = (
        _ title: String,
        _ rows: [ExtensionPanelContent.Row],
        _ completion: @escaping (ExtensionPanelContent.Row) -> Void
    ) -> Void

    static let notAvailableMessage = "This command is not available right now."

    var loadPanel: PanelLoader = { installed, completion in
        let command = ExtensionPanelCommand(extension: installed)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = command.run()
            DispatchQueue.main.async { completion(result) }
        }
    }
    var pickRow: RowPicker
    /// Shows an alert with a title and body. Injected for tests.
    var showAlert: @MainActor (_ title: String, _ body: String) -> Void = ExtensionPanelActionRunner.showFailureAlert
    /// Runs an action of the extension, with a row id or (nil) for the panel.
    var performAction: (_ installed: InstalledExtension, _ action: ExtensionPanelAction, _ rowID: String?) -> Void

    init(
        pickRow: @escaping RowPicker,
        performAction: @escaping (_ installed: InstalledExtension, _ action: ExtensionPanelAction, _ rowID: String?) -> Void
    ) {
        self.pickRow = pickRow
        self.performAction = performAction
    }

    func run(_ command: ExtensionPaletteCommand) {
        let title = command.title
        loadPanel(command.installed) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.showAlert(title, error.localizedDescription)
            case .success(let content):
                self.choose(command, in: content)
            }
        }
    }

    private func choose(_ command: ExtensionPaletteCommand, in content: ExtensionPanelContent) {
        let actionID = command.entry.action
        let unavailable = content.message.flatMap { $0.isEmpty ? nil : $0 } ?? Self.notAvailableMessage

        guard command.entry.pick else {
            guard let action = content.actions.first(where: { $0.id == actionID }) else {
                showAlert(command.title, unavailable)
                return
            }
            performAction(command.installed, action, nil)
            return
        }

        let rows = content.sections.flatMap(\.rows).filter { row in
            row.actions.contains { $0.id == actionID }
        }
        guard !rows.isEmpty else {
            showAlert(command.title, unavailable)
            return
        }
        pickRow(command.title, rows) { [weak self] row in
            guard let action = row.actions.first(where: { $0.id == actionID }) else { return }
            self?.performAction(command.installed, action, row.id)
        }
    }
}

// MARK: - Row picker

/// Lists panel rows to pick one for a palette command: title, with the
/// detail as the secondary line, filtered by typing. Escape closes it and
/// picks nothing.
final class ExtensionRowPickerPanel: FilterableListPanel {
    private var allRows: [ExtensionPanelContent.Row] = []
    private var filteredRows: [ExtensionPanelContent.Row] = []
    private var onPick: ((ExtensionPanelContent.Row) -> Void)?

    init() {
        super.init(chrome: Chrome(
            title: "Pick",
            placeholder: "Type to filter…",
            size: NSSize(width: 560, height: 380),
            columnIdentifier: "ExtensionRow",
            hidesOnDeactivate: true,
            rowHeight: 40
        ))
    }

    override var itemCount: Int { filteredRows.count }

    override func cellView(forRow row: Int) -> NSView? {
        let cell = ExtensionRowCellView()
        cell.configure(with: filteredRows[row])
        return cell
    }

    override func queryChanged(_ query: String) {
        if query.isEmpty {
            filteredRows = allRows
        } else {
            filteredRows = allRows
                .compactMap { row -> (ExtensionPanelContent.Row, Int)? in
                    guard let score = FuzzyScorer.score(candidate: row.title, query: query) else { return nil }
                    return (row, score)
                }
                .sorted { $0.1 > $1.1 }
                .map { $0.0 }
        }
        reloadAndSelectFirst()
    }

    override func activateRow(_ row: Int) {
        let chosen = filteredRows[row]
        let onPick = onPick
        close()
        onPick?(chosen)
    }

    func show(relativeTo parentWindow: NSWindow, title: String, rows: [ExtensionPanelContent.Row], onPick: @escaping (ExtensionPanelContent.Row) -> Void) {
        self.title = title
        allRows = rows
        filteredRows = rows
        self.onPick = onPick

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

private final class ExtensionRowCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = AppTheme.primaryText
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = NSFont.systemFont(ofSize: 11)
        detailLabel.textColor = AppTheme.mutedText
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(detailLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 3),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1)
        ])
    }

    func configure(with row: ExtensionPanelContent.Row) {
        titleLabel.stringValue = row.title
        detailLabel.stringValue = row.detail ?? ""
    }
}
