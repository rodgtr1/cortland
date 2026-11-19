import AppKit

/// What `cortland-ctl extension validate <folder>` prints: errors stop an
/// extension from working, warnings flag something that probably does not
/// do what its author meant.
nonisolated struct ExtensionValidationReport: Codable, Equatable, Sendable {
    /// The parts of a manifest that parsed.
    nonisolated struct Manifest: Codable, Equatable, Sendable {
        let id: String
        let name: String
        let version: String
        let apiVersion: Int
        /// The `[panel]` title, or nil for no panel.
        let panelTitle: String?
        /// The `[[palette]]` entry titles, in manifest order.
        let palette: [String]

        enum CodingKeys: String, CodingKey {
            case id, name, version, palette
            case apiVersion = "api_version"
            case panelTitle = "panel_title"
        }
    }

    /// Counts from one `<command> panel` run that decoded.
    nonisolated struct Panel: Codable, Equatable, Sendable {
        let sections: Int
        let rows: Int
        /// Panel actions only, not row actions.
        let actions: Int
        let message: String?
    }

    /// True when `errors` is empty.
    let valid: Bool
    let errors: [String]
    let warnings: [String]
    let manifest: Manifest?
    let panel: Panel?

    init(errors: [String], warnings: [String], manifest: Manifest?, panel: Panel?) {
        self.valid = errors.isEmpty
        self.errors = errors
        self.warnings = warnings
        self.manifest = manifest
        self.panel = panel
    }
}

/// Checks an extension folder the way Cortland would use it: the real
/// manifest validator, then (with a `[panel]`) one real `<command> panel`
/// run through `ExtensionPanelCommand`, then cross-checks between the two.
/// Blocking when there is a panel; call it off the main thread.
nonisolated enum ExtensionValidator {
    static func validate(
        folder: URL,
        runner: ProcessRunning = ProcessRunner.shared,
        searchPath: String = DocumentFormatter.shellSearchPath,
        symbolExists: (String) -> Bool = ExtensionValidator.systemSymbolExists
    ) -> ExtensionValidationReport {
        let manifest: ExtensionManifest
        do {
            manifest = try ExtensionManifest.load(from: folder)
        } catch {
            return ExtensionValidationReport(errors: [error.localizedDescription], warnings: [], manifest: nil, panel: nil)
        }

        let summary = ExtensionValidationReport.Manifest(
            id: manifest.id,
            name: manifest.name,
            version: manifest.version,
            apiVersion: manifest.apiVersion,
            panelTitle: manifest.panel?.title,
            palette: manifest.palette.map(\.title)
        )
        guard let spec = manifest.panel else {
            return ExtensionValidationReport(errors: [], warnings: [], manifest: summary, panel: nil)
        }

        var warnings: [String] = []
        if spec.iconURL == nil, !symbolExists(spec.icon) {
            warnings.append("\"panel.icon\" \"\(spec.icon)\" is not an SF Symbol on this Mac; the activity bar shows a generic icon instead.")
        }

        let command = ExtensionPanelCommand(executableURL: manifest.commandURL, folder: folder, runner: runner)
        let invocation = "\"\(manifest.command) panel\""
        let content: ExtensionPanelContent
        switch command.run(searchPath: searchPath) {
        case .success(let decoded):
            content = decoded
        case .failure(.invalidOutput(let detail)):
            return ExtensionValidationReport(
                errors: ["\(invocation) printed invalid output: \(detail)"],
                warnings: warnings, manifest: summary, panel: nil)
        case .failure(let error):
            return ExtensionValidationReport(
                errors: ["\(invocation) failed: \(error.localizedDescription)"],
                warnings: warnings, manifest: summary, panel: nil)
        }

        warnings += iconWarnings(content, symbolExists: symbolExists)
        warnings += paletteWarnings(manifest.palette, content: content)

        let rows = content.sections.flatMap(\.rows)
        let panel = ExtensionValidationReport.Panel(
            sections: content.sections.count,
            rows: rows.count,
            actions: content.actions.count,
            message: content.message
        )
        return ExtensionValidationReport(errors: [], warnings: warnings, manifest: summary, panel: panel)
    }

    /// Row and action `icon` values that name no SF Symbol.
    private static func iconWarnings(_ content: ExtensionPanelContent, symbolExists: (String) -> Bool) -> [String] {
        var warnings: [String] = []
        for action in content.actions {
            if let icon = action.icon, !symbolExists(icon) {
                warnings.append("Panel action \"\(action.id)\" has icon \"\(icon)\", which is not an SF Symbol on this Mac; it goes in the Actions menu instead of the top bar.")
            }
        }
        for row in content.sections.flatMap(\.rows) {
            if let icon = row.icon, !symbolExists(icon) {
                warnings.append("Row \"\(row.id)\" has icon \"\(icon)\", which is not an SF Symbol on this Mac; the row shows no icon.")
            }
            for action in row.actions {
                if let icon = action.icon, !symbolExists(icon) {
                    warnings.append("Action \"\(action.id)\" on row \"\(row.id)\" has icon \"\(icon)\", which is not an SF Symbol on this Mac.")
                }
            }
        }
        return warnings
    }

    /// Palette entries whose action this panel output does not offer.
    private static func paletteWarnings(_ entries: [ExtensionPaletteEntry], content: ExtensionPanelContent) -> [String] {
        let panelActionIDs = Set(content.actions.map(\.id))
        let rowActionIDs = Set(content.sections.flatMap(\.rows).flatMap(\.actions).map(\.id))
        return entries.compactMap { entry in
            if entry.pick {
                guard !rowActionIDs.contains(entry.action) else { return nil }
                return "Palette entry \"\(entry.title)\" (pick = true) runs row action \"\(entry.action)\", but no row in the panel output has it."
            }
            guard !panelActionIDs.contains(entry.action) else { return nil }
            return "Palette entry \"\(entry.title)\" runs panel action \"\(entry.action)\", but the panel output has no panel action with that id."
        }
    }

    /// True when `name` is an SF Symbol this Mac can draw.
    static func systemSymbolExists(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }
}
