import Cocoa

protocol ActivityBarDelegate: AnyObject {
    func activityBar(_ activityBar: ActivityBarView, didSelectPanel panel: SidebarPanel)
    func activityBarDidToggleSidebar(_ activityBar: ActivityBarView)
}

enum SidebarPanel: String, CaseIterable {
    case files = "Files"
    case agents = "Agents"
    case search = "Search"
    case git = "Git"
    case worktrees = "Worktrees"
    case hosts = "Hosts"

    var icon: String {
        switch self {
        case .files: return "folder"
        case .git: return "arrow.branch"
        case .worktrees: return "arrow.triangle.branch"
        case .search: return "magnifyingglass"
        case .agents: return "sparkles"
        case .hosts: return "server.rack"
        }
    }

    /// Tooltip shortcut hint, or "" when the panel has no key binding yet.
    var shortcut: String {
        switch self {
        case .files: return "⌘⇧E"
        case .git: return "⌘⇧G"
        case .search: return "⌘⇧F"
        case .agents: return "⌘⇧A"
        case .hosts: return "⌘⇧H"
        case .worktrees: return ""
        }
    }

    /// The Codicon (VS Code icon font) name backing this panel's icon. Using
    /// one icon family keeps every activity-bar icon visually consistent.
    var codiconName: String {
        switch self {
        case .files: return "folder"
        case .search: return "search"
        case .git: return "source-control"
        case .agents: return "sparkle"
        case .hosts: return "server"
        case .worktrees: return "source-control"   // unused: falls back to SF Symbol
        }
    }

    /// This panel's icon as a tinted template image. Returns nil to fall back
    /// to `icon` (an SF Symbol) — used for Agents and Worktrees, which keep
    /// their SF Symbol rather than a Codicon.
    func customImage(pointSize: CGFloat) -> NSImage? {
        if self == .agents || self == .worktrees { return nil }
        return SidebarIcons.codicon(codiconName, pointSize: pointSize)
    }
}

class ActivityBarView: NSView {
    weak var delegate: ActivityBarDelegate?

    private var selectedPanel: SidebarPanel = .files
    private var buttons: [NSButton] = []
    private var agentsBadge: NSTextField?
    private var themeObserver: ThemeObserver?
    private let buttonSize: CGFloat = 40
    private let buttonSpacing: CGFloat = 4
    var topInset: CGFloat = 8 {
        didSet {
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        wantsLayer = true
        applyBackground(enableBlur: true) // Default to blur enabled
        createActivityButtons()
        themeObserver = ThemeObserver { [weak self] in self?.applyThemeColors() }
    }

    private func applyThemeColors() {
        applyBackground(enableBlur: true)
        updateSelectedButton(panel: selectedPanel)
        agentsBadge?.layer?.backgroundColor = Theme.shared.current.red.cgColor
    }

    func applyBackground(enableBlur: Bool) {
        // Activity bar is always opaque (no blur)
        let bgColor = Theme.shared.current.windowBackground
        layer?.backgroundColor = bgColor.cgColor
        layer?.isOpaque = true
    }

    private func createActivityButtons() {
        let panels = SidebarPanel.allCases

        for (index, panel) in panels.enumerated() {
            let button = createActivityButton(for: panel, at: index)
            buttons.append(button)
            addSubview(button)
        }

        // Select Files panel by default
        updateSelectedButton(panel: .files)
    }

    private func createActivityButton(for panel: SidebarPanel, at index: Int) -> NSButton {
        // Position from top so icons line up with the terminal content below the tabs.
        let offsetFromTop = topInset + CGFloat(index) * (buttonSize + buttonSpacing) + buttonSpacing
        let y = bounds.height - offsetFromTop - buttonSize
        let x = (48 - buttonSize) / 2 // Center in 48px width

        let button = NSButton(frame: NSRect(x: x, y: y, width: buttonSize, height: buttonSize))
        button.bezelStyle = .circular
        button.isBordered = false
        button.wantsLayer = true

        // Prefer a bundled custom icon; otherwise fall back to the SF Symbol.
        // SF Symbols at pointSize 20 render a visibly larger box than a literal
        // 20pt image, so custom icons use a larger size to match their weight.
        if let custom = panel.customImage(pointSize: 24) {
            button.image = custom
        } else if let image = NSImage(systemSymbolName: panel.icon, accessibilityDescription: panel.rawValue) {
            // Tuned to visually match the 24pt Codicons next to it (SF Symbol
            // point size renders a larger box than an equivalent template image).
            let config = NSImage.SymbolConfiguration(pointSize: 22, weight: .medium)
            button.image = image.withSymbolConfiguration(config)
        } else {
            // Fallback to text if SF Symbol not available
            button.title = String(panel.rawValue.first ?? "?")
            button.font = NSFont.systemFont(ofSize: 16, weight: .medium)
        }

        button.target = self
        button.action = #selector(activityButtonClicked(_:))
        button.tag = index

        // Add tooltip (omit the parens when the panel has no shortcut yet)
        button.toolTip = panel.shortcut.isEmpty
            ? panel.rawValue
            : "\(panel.rawValue) (\(panel.shortcut))"

        // Style button
        styleButton(button, isSelected: false)

        return button
    }

    private func styleButton(_ button: NSButton, isSelected: Bool) {
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.layer?.borderWidth = 0
        button.layer?.borderColor = NSColor.clear.cgColor

        if isSelected {
            button.contentTintColor = Theme.shared.current.primaryText
        } else {
            button.contentTintColor = Theme.shared.current.secondaryText
        }

        button.layer?.cornerRadius = 0
    }

    @objc private func activityButtonClicked(_ sender: NSButton) {
        let panel = SidebarPanel.allCases[sender.tag]

        if selectedPanel == panel {
            // Toggle sidebar if same panel clicked
            delegate?.activityBarDidToggleSidebar(self)
        } else {
            // Switch to new panel
            selectedPanel = panel
            updateSelectedButton(panel: panel)
            delegate?.activityBar(self, didSelectPanel: panel)
        }
    }

    private func updateSelectedButton(panel: SidebarPanel) {
        selectedPanel = panel

        for (index, button) in buttons.enumerated() {
            let isSelected = (index == SidebarPanel.allCases.firstIndex(of: panel))
            styleButton(button, isSelected: isSelected)
        }
    }

    func selectPanel(_ panel: SidebarPanel) {
        updateSelectedButton(panel: panel)
    }

    /// Shows a count badge on the Agents icon for agents waiting for input.
    func updateAgentsBadge(count: Int) {
        guard count > 0 else {
            agentsBadge?.removeFromSuperview()
            agentsBadge = nil
            return
        }

        let badge: NSTextField
        if let existing = agentsBadge {
            badge = existing
        } else {
            badge = NSTextField(labelWithString: "")
            badge.font = NSFont.systemFont(ofSize: 9, weight: .bold)
            badge.textColor = .white
            badge.alignment = .center
            badge.wantsLayer = true
            badge.layer?.backgroundColor = Theme.shared.current.red.cgColor
            badge.layer?.cornerRadius = 7
            addSubview(badge)
            agentsBadge = badge
        }

        badge.stringValue = count > 9 ? "9+" : "\(count)"
        positionAgentsBadge()
    }

    private func positionAgentsBadge() {
        guard let badge = agentsBadge,
              let agentsIndex = SidebarPanel.allCases.firstIndex(of: .agents),
              let button = buttons[safe: agentsIndex] else { return }

        let size: CGFloat = 14
        badge.frame = NSRect(
            x: button.frame.maxX - size + 2,
            y: button.frame.maxY - size + 2,
            width: size,
            height: size
        )
    }

    override func layout() {
        super.layout()

        // Reposition buttons if view size changed
        for (index, button) in buttons.enumerated() {
            // Position from top so icons line up with the terminal content below the tabs.
            let offsetFromTop = topInset + CGFloat(index) * (buttonSize + buttonSpacing) + buttonSpacing
            let y = bounds.height - offsetFromTop - buttonSize
            let x = (bounds.width - buttonSize) / 2
            button.frame = NSRect(x: x, y: y, width: buttonSize, height: buttonSize)
        }

        positionAgentsBadge()
    }
}
