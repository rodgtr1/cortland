import Cocoa

struct KeyboardShortcut {
    let keys: String
    let description: String
    let category: String
}

class KeyboardShortcutsPanel: NSPanel {
    private var tableView: NSTableView!
    private var shortcuts: [KeyboardShortcut] = []

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        setupPanel()
        loadShortcuts()
        setupUI()
    }

    private func setupPanel() {
        title = "Keyboard Shortcuts"
        level = .floating
        isFloatingPanel = true
        // The controller keeps a strong reference and reuses this instance, so
        // closing must order it out rather than release it (a released-then-
        // referenced window would crash on the next ⌘K).
        isReleasedWhenClosed = false
        center()
    }

    /// Which commands to list, and how to describe/categorize them. The key
    /// string itself always comes from `KeyboardCommand.displayShortcut` —
    /// the single source of truth in KeyboardCommandRouter — so this panel
    /// can't drift from the actual bindings the way a hand-copied list did.
    private static let entries: [(command: KeyboardCommand, description: String, category: String)] = [
        // Tabs
        (.newTab, "New terminal tab", "Tabs"),
        (.closeTab, "Close the current tab", "Tabs"),
        (.cycleTabs(forward: true), "Cycle to next tab", "Tabs"),
        (.cycleTabs(forward: false), "Cycle to previous tab", "Tabs"),

        // Panes
        (.closeCurrentPane, "Close the current pane", "Panes"),
        (.splitPane(.horizontal), "Split terminal right", "Panes"),
        (.splitPane(.vertical), "Split terminal down", "Panes"),
        (.focusPane(forward: false), "Focus previous pane", "Panes"),
        (.focusPane(forward: true), "Focus next pane", "Panes"),

        // Sidebar
        (.toggleSidebar, "Toggle sidebar", "Sidebar"),
        (.showPanel(.files), "Show file explorer panel", "Sidebar"),
        (.showPanel(.git), "Show git panel", "Sidebar"),
        (.showPanel(.search), "Show search-in-files panel", "Sidebar"),
        (.showPanel(.agents), "Show agents panel", "Sidebar"),
        (.showPanel(.hosts), "Show SSH hosts panel", "Sidebar"),
        (.toggleHiddenFiles, "Toggle hidden files in the file tree", "Sidebar"),

        // Agents
        (.focusAgentAttention, "Jump to next agent needing attention", "Agents"),

        // Files
        (.quickOpen, "Quick open: search file names", "Files"),
        (.commandPalette, "Open command palette", "Files"),
        (.saveFile, "Save the current editor tab", "Files"),

        // Terminal
        (.findInTerminal, "Find in terminal", "Terminal"),
        (.jumpToPrompt(previous: true), "Jump to previous prompt", "Terminal"),
        (.jumpToPrompt(previous: false), "Jump to next prompt", "Terminal"),
        (.pasteIntoTerminal, "Paste (clipboard images become a temp file path)", "Terminal"),
        (.zoomIn, "Zoom in", "Terminal"),
        (.zoomOut, "Zoom out", "Terminal"),
        (.zoomReset, "Reset zoom", "Terminal"),

        // General
        (.preferences, "Open preferences", "General"),
        (.toggleArcade, "Toggle the arcade panel (enable in Preferences ▸ Extras)", "General"),
    ]

    private func loadShortcuts() {
        shortcuts = Self.entries.compactMap { entry in
            guard let keys = entry.command.displayShortcut else {
                assertionFailure("Missing displayShortcut for \(entry.command)")
                return nil
            }
            return KeyboardShortcut(keys: keys, description: entry.description, category: entry.category)
        }

        // Not single KeyboardCommand cases, so listed directly rather than
        // derived from displayShortcut.
        shortcuts.append(KeyboardShortcut(keys: "⌘1-9", description: "Switch to specific tab by number", category: "Tabs"))
        shortcuts.append(KeyboardShortcut(keys: "⌘K", description: "Show Keyboard Shortcuts", category: "General"))
        shortcuts.append(KeyboardShortcut(keys: "Esc", description: "Close Panel/Dialog", category: "General"))
    }

    private func setupUI() {
        guard let contentView = contentView else { return }

        // Container view with padding
        let containerView = NSView()
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = AppTheme.windowBackground.cgColor
        containerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(containerView)

        // Title label
        let titleLabel = NSTextField(labelWithString: "Keyboard Shortcuts")
        titleLabel.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = AppTheme.primaryText
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        // Subtitle label
        let subtitleLabel = NSTextField(labelWithString: "Press Esc to close this panel")
        subtitleLabel.font = NSFont.systemFont(ofSize: 12)
        subtitleLabel.textColor = AppTheme.mutedText
        subtitleLabel.alignment = .center
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        // Table view
        tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowSizeStyle = .medium
        tableView.backgroundColor = NSColor.clear
        if #available(macOS 12.0, *) {
            tableView.style = .sourceList
        } else {
            tableView.selectionHighlightStyle = .sourceList
        }

        // Columns
        let keysColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Keys"))
        keysColumn.width = 150
        keysColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(keysColumn)

        let descColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Description"))
        descColumn.width = 400
        descColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(descColumn)

        let categoryColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Category"))
        categoryColumn.width = 100
        categoryColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(categoryColumn)

        // Scroll view
        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.backgroundColor = NSColor.clear
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        containerView.addSubview(titleLabel)
        containerView.addSubview(subtitleLabel)
        containerView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            // Container view
            containerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            containerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            // Title
            titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            // Subtitle
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            subtitleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            subtitleLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            // Scroll view
            scrollView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 20),
            scrollView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -20)
        ])

        // Setup table view
        tableView.dataSource = self
        tableView.delegate = self
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            close()
        default:
            super.keyDown(with: event)
        }
    }

    func show(relativeTo parentWindow: NSWindow) {
        // Position relative to parent window
        let parentFrame = parentWindow.frame
        let panelSize = frame.size
        let newOrigin = NSPoint(
            x: parentFrame.midX - panelSize.width / 2,
            y: parentFrame.midY - panelSize.height / 2
        )
        setFrameOrigin(newOrigin)

        // Show
        makeKeyAndOrderFront(nil)
    }
}

// MARK: - NSTableViewDataSource
extension KeyboardShortcutsPanel: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return shortcuts.count
    }
}

// MARK: - NSTableViewDelegate
extension KeyboardShortcutsPanel: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < shortcuts.count else { return nil }

        let shortcut = shortcuts[row]
        let cellView = NSTableCellView()

        let textField = NSTextField(labelWithString: "")
        textField.font = NSFont.systemFont(ofSize: 13)
        textField.textColor = AppTheme.primaryText
        textField.translatesAutoresizingMaskIntoConstraints = false

        if tableColumn?.identifier.rawValue == "Keys" {
            textField.stringValue = shortcut.keys
            textField.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            textField.textColor = AppTheme.accent // Blue
        } else if tableColumn?.identifier.rawValue == "Description" {
            textField.stringValue = shortcut.description
        } else if tableColumn?.identifier.rawValue == "Category" {
            textField.stringValue = shortcut.category
            textField.textColor = AppTheme.mutedText // Dim
            textField.font = NSFont.systemFont(ofSize: 11)
        }

        cellView.addSubview(textField)

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 8),
            textField.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -8),
            textField.centerYAnchor.constraint(equalTo: cellView.centerYAnchor)
        ])

        return cellView
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return 28
    }
}
