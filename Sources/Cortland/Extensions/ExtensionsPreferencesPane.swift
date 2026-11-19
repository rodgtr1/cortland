import Cocoa

/// The Preferences > Extensions pane. Installs an extension from its git
/// repository's URL, lists installed extensions with an enable checkbox, a
/// Remove button, and (for a git checkout Cortland owns) an Update button,
/// lists invalid ones with their validation error, and rescans every time the
/// pane is shown.
///
/// `PreferencesWindowController` sets the view to the scroll view from
/// `makeScrollingPane`; rows are laid out into its document view (`content`)
/// with `PreferencesFormBuilder` and rebuilt on each rescan.
final class ExtensionsPreferencesPane: NSViewController {
    private let content: NSView
    private let registry: ExtensionRegistry
    /// An install or update is running. Only one runs at a time.
    private var isBusy = false
    /// The running job is an install, so the install button reads "Installing…".
    private var isInstalling = false

    init(content: NSView, registry: ExtensionRegistry = .shared) {
        self.content = content
        self.registry = registry
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reloadList()
    }

    private func reloadList() {
        registry.reload()
        render()
    }

    private func render() {
        content.subviews.forEach { $0.removeFromSuperview() }
        let form = PreferencesFormBuilder(container: content)

        form.fullWidth(Self.wrappingLabel(
            "Install an extension from its git repository's URL. Extensions live in folders under \(Self.displayPath(registry.extensionsDirectory)). New extensions start disabled.",
            fontSize: 12
        ), gapAbove: 20)

        let installButton = NSButton(
            title: isInstalling ? "Installing…" : "Install from URL…",
            target: self,
            action: #selector(installClicked(_:))
        )
        installButton.bezelStyle = .rounded
        installButton.isEnabled = !isBusy
        let openButton = NSButton(title: "Open Extensions Folder", target: self, action: #selector(openFolderClicked(_:)))
        openButton.bezelStyle = .rounded
        let reloadButton = NSButton(title: "Reload", target: self, action: #selector(reloadClicked(_:)))
        reloadButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [installButton, openButton, reloadButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        form.leadingControl(buttons, gapAbove: 12)

        if registry.extensions.isEmpty && registry.invalidExtensions.isEmpty {
            form.fullWidth(Self.wrappingLabel("No extensions installed.", fontSize: 12), gapAbove: 24)
        }

        for item in registry.extensions {
            let manifest = item.manifest
            var details = manifest.id
            if let description = manifest.description, !description.isEmpty {
                details += "\n" + description
            }
            form.agentRow(
                name: "\(manifest.name) \(manifest.version)",
                statusLabel: Self.wrappingLabel(details, fontSize: 12),
                button: rowButtons(for: manifest.id, updatable: item.isUpdatable),
                gapAbove: 22
            )
            let checkbox = NSButton(checkboxWithTitle: "Enabled", target: self, action: #selector(enabledChanged(_:)))
            checkbox.font = NSFont.systemFont(ofSize: 13)
            checkbox.state = item.isEnabled ? .on : .off
            checkbox.identifier = NSUserInterfaceItemIdentifier(manifest.id)
            form.checkbox(checkbox, gapAbove: 6)
        }

        for item in registry.invalidExtensions {
            let error = Self.wrappingLabel(item.error.localizedDescription, fontSize: 12)
            error.textColor = .systemRed
            form.agentRow(
                name: item.folderName,
                statusLabel: error,
                button: rowButtons(for: item.folderName, updatable: item.isUpdatable),
                gapAbove: 22
            )
        }

        form.finish()
    }

    /// Remove, preceded by Update when Cortland can update the extension.
    private func rowButtons(for id: String, updatable: Bool) -> NSView {
        let remove = removeButton(for: id)
        guard updatable else { return remove }
        let update = NSButton(title: "Update", target: self, action: #selector(updateClicked(_:)))
        update.bezelStyle = .rounded
        update.identifier = NSUserInterfaceItemIdentifier(id)
        update.isEnabled = !isBusy
        let stack = NSStackView(views: [update, remove])
        stack.orientation = .horizontal
        stack.spacing = 8
        return stack
    }

    private func removeButton(for id: String) -> NSButton {
        let button = NSButton(title: "Remove", target: self, action: #selector(removeClicked(_:)))
        button.bezelStyle = .rounded
        button.identifier = NSUserInterfaceItemIdentifier(id)
        return button
    }

    // MARK: - Actions

    @objc private func enabledChanged(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        do {
            try registry.setEnabled(id, sender.state == .on)
        } catch {
            showError("Could Not Update Extension", error)
        }
        render()
    }

    @objc private func removeClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let name = registry.extensions.first(where: { $0.id == id })?.manifest.name ?? id

        let alert = NSAlert()
        alert.messageText = "Remove \(name)?"
        alert.informativeText = "The extension's folder moves to the Trash, so you can recover it from there."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try registry.uninstall(id)
        } catch {
            showError("Could Not Remove Extension", error)
        }
        render()
    }

    @objc private func installClicked(_ sender: NSButton) {
        guard !isBusy else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "https://github.com/owner/repo.git"

        let alert = NSAlert()
        alert.messageText = "Install Extension from URL"
        alert.informativeText = "Enter the URL of the extension's git repository. Cortland downloads it and checks its manifest, but does not run it. The extension starts disabled."
        alert.accessoryView = field
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let location = field.stringValue
        isBusy = true
        isInstalling = true
        render()
        Task {
            defer {
                isBusy = false
                isInstalling = false
                render()
            }
            do {
                _ = try await registry.install(from: location)
            } catch {
                showError("Could Not Install Extension", error)
            }
        }
    }

    @objc private func updateClicked(_ sender: NSButton) {
        guard !isBusy, let id = sender.identifier?.rawValue else { return }
        let name = registry.extensions.first(where: { $0.id == id })?.manifest.name ?? id
        isBusy = true
        render()
        Task {
            defer {
                isBusy = false
                render()
            }
            do {
                let result = try await registry.update(id)
                showUpdateResult(result, name: name)
            } catch {
                showError("Could Not Update \(name)", error)
            }
        }
    }

    private func showUpdateResult(_ result: ExtensionUpdateResult, name: String) {
        let alert = NSAlert()
        if !result.updated {
            alert.messageText = "\(name) is up to date."
        } else if let before = result.versionBefore, let after = result.versionAfter, before != after {
            alert.messageText = "Updated \(name) from \(before) to \(after)."
        } else {
            alert.messageText = "Updated \(name)."
        }
        if let invalid = result.invalid {
            alert.informativeText = "The updated manifest is not valid, so the extension does not run: \(invalid)"
            alert.alertStyle = .warning
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func openFolderClicked(_ sender: NSButton) {
        let directory = registry.extensionsDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            showError("Could Not Create Extensions Folder", error)
            return
        }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory.path)
    }

    @objc private func reloadClicked(_ sender: NSButton) {
        reloadList()
    }

    private func showError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Helpers

    private static func wrappingLabel(_ text: String, fontSize: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: fontSize)
        label.textColor = AppTheme.secondaryText
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 420
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// `~/.config/cortland/extensions` rather than the full home path.
    private static func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
