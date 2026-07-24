import Cocoa

protocol HostsPanelDelegate: AnyObject {
    func hostsPanel(_ panel: HostsPanelViewController, didRequestConnectCommand command: String)
}

/// Sidebar panel listing connectable hosts from ~/.ssh/config. Clicking a
/// host opens a new tab running the matching ssh command.
final class HostsPanelViewController: NSViewController {
    weak var delegate: HostsPanelDelegate?

    private enum Item {
        case header(String)
        case host(name: String, detail: String?, command: String)
        case message(String)
    }

    private var items: [Item] = []
    private var sshHosts: [String] = []

    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var refreshButton: NSButton!

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = AppTheme.sidebarBackground.cgColor
    }

    private var themeObserver: ThemeObserver?

    override func viewDidLoad() {
        super.viewDidLoad()
        setupViews()
        refresh()
        themeObserver = ThemeObserver { [weak self] in self?.applyThemeColors() }
    }

    private func applyThemeColors() {
        view.layer?.backgroundColor = AppTheme.sidebarBackground.cgColor
        refreshButton?.contentTintColor = AppTheme.primaryText
        scrollView?.backgroundColor = AppTheme.sidebarBackground
        tableView?.backgroundColor = AppTheme.sidebarBackground
        tableView?.reloadData()
    }

    private func setupViews() {
        refreshButton = NSButton(
            image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh") ?? NSImage(),
            target: self,
            action: #selector(refreshClicked)
        )
        refreshButton.isBordered = false
        refreshButton.contentTintColor = AppTheme.primaryText
        refreshButton.toolTip = "Refresh hosts"
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = AppTheme.sidebarBackground

        tableView = NSTableView()
        tableView.headerView = nil
        tableView.backgroundColor = AppTheme.sidebarBackground
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.usesAlternatingRowBackgroundColors = false
        if #available(macOS 12.0, *) {
            tableView.style = .plain
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("HostColumn"))
        column.isEditable = false
        tableView.addTableColumn(column)
        scrollView.documentView = tableView

        view.addSubview(refreshButton)
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            refreshButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            refreshButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            refreshButton.widthAnchor.constraint(equalToConstant: 22),
            refreshButton.heightAnchor.constraint(equalToConstant: 22),

            scrollView.topAnchor.constraint(equalTo: refreshButton.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    @objc private func refreshClicked() {
        refresh()
    }

    func refresh() {
        sshHosts = Self.parseSSHConfigHosts()
        rebuildItems()
    }

    private func rebuildItems() {
        var newItems: [Item] = []

        newItems.append(.header("SSH CONFIG"))
        let connectable = sshHosts.compactMap { host in
            Self.connectCommand(forHost: host).map { (name: host, command: $0) }
        }
        if connectable.isEmpty {
            newItems.append(.message("No hosts in ~/.ssh/config"))
        } else {
            for entry in connectable {
                newItems.append(.host(name: entry.name, detail: nil, command: entry.command))
            }
        }

        items = newItems
        tableView.reloadData()
    }

    // MARK: - SSH config parsing

    /// The command a double-click types into the terminal, or nil when the alias
    /// isn't a plausible ssh host token.
    ///
    /// The alias goes straight into a shell, so an ssh_config `Host` holding
    /// shell syntax (`;`, `$(…)`, backticks) would run as shell code, and one
    /// starting with `-` would be read by ssh as an option rather than a
    /// destination. The charset below admits no metacharacter, so the alias needs
    /// no quoting once it passes; anything that fails isn't a host we could
    /// connect to anyway, so it is dropped from the list rather than quoted into
    /// a command that would only fail later. (Wildcard `Host *` patterns never
    /// reach here — parseSSHConfigHosts already drops them.)
    static func connectCommand(forHost host: String) -> String? {
        guard isPlausibleHostToken(host) else { return nil }
        return "ssh \(host)"
    }

    private static func isPlausibleHostToken(_ host: String) -> Bool {
        guard !host.isEmpty, !host.hasPrefix("-") else { return false }
        return host.allSatisfy { char in
            char.isASCII && (char.isLetter || char.isNumber || char == "." || char == "-" || char == "_")
        }
    }

    static func parseSSHConfigHosts() -> [String] {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
        guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else { return [] }
        return parseSSHConfigHosts(from: contents)
    }

    static func parseSSHConfigHosts(from contents: String) -> [String] {
        var hosts: [String] = []
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("host "), !trimmed.hasPrefix("#") else { continue }

            let patterns = trimmed.dropFirst("host ".count)
                .split(separator: " ")
                .map(String.init)
            for pattern in patterns where !pattern.contains("*") && !pattern.contains("?") && !pattern.hasPrefix("!") {
                hosts.append(pattern)
            }
        }
        return hosts
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0 && row < items.count,
              case .host(_, _, let command) = items[row] else { return }
        delegate?.hostsPanel(self, didRequestConnectCommand: command)
    }
}

extension HostsPanelViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }
}

extension HostsPanelViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count else { return nil }
        let cell = NSTableCellView()

        switch items[row] {
        case .header(let title):
            let label = NSTextField(labelWithString: title)
            label.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
            label.textColor = AppTheme.mutedText
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -3)
            ])
        case .message(let text):
            let label = NSTextField(labelWithString: text)
            label.font = NSFont.systemFont(ofSize: 12)
            label.textColor = AppTheme.mutedText
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        case .host(let name, let detail, _):
            let icon = NSImageView(image: NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = AppTheme.accent
            icon.translatesAutoresizingMaskIntoConstraints = false

            let nameLabel = NSTextField(labelWithString: name)
            nameLabel.font = NSFont.systemFont(ofSize: 13)
            nameLabel.textColor = AppTheme.primaryText
            nameLabel.lineBreakMode = .byTruncatingTail
            nameLabel.translatesAutoresizingMaskIntoConstraints = false
            nameLabel.toolTip = detail.map { "\(name)\n\($0)" } ?? "Double-click to connect to \(name)"

            cell.addSubview(icon)
            cell.addSubview(nameLabel)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 14),
                icon.heightAnchor.constraint(equalToConstant: 14),

                nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
                nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
                nameLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = items[row] { return 26 }
        return 24
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .host = items[row] { return true }
        return false
    }
}
