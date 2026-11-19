import Foundation
import TOMLKit

/// A validated `extension.toml`.
///
/// An extension is one folder under `~/.config/cortland/extensions/<id>/`
/// holding this manifest, for example:
///
///     api_version = 1
///     id = "acme.widgets"
///     name = "Widgets"
///     version = "0.1.0"
///     description = "Browse and launch Widgets."   # optional
///     command = "bin/widgets"
///
///     [panel]                       # optional: adds a sidebar panel
///     title = "Widgets"
///     icon = "bolt.horizontal"      # an SF Symbol name, or an .svg/.pdf/.png file in the folder
///     refresh_seconds = 10          # optional, default 10, minimum 2
///
///     [[palette]]                   # optional, repeatable; needs [panel]
///     title = "SSH into Widget"       # shown as "<panel title>: <title>"
///     action = "ssh"                # an action id from the panel output
///     pick = true                   # optional, default false: pick a row first
///
/// Only `load(from:)` builds one, so every instance has passed validation.
/// Unknown keys are ignored.
nonisolated struct ExtensionManifest: Equatable, Sendable {
    /// The extension API version this build of Cortland understands. A manifest
    /// that asks for more needs a newer app.
    static let supportedAPIVersion = 1
    static let fileName = "extension.toml"

    let apiVersion: Int
    let id: String
    let name: String
    /// Free-form; deliberately not parsed as semver.
    let version: String
    let description: String?
    /// The `command` value as written in the manifest (relative to the folder).
    let command: String
    /// `command` resolved to a real path inside the extension folder. Validated
    /// to exist and be executable; never run in this step.
    let commandURL: URL
    /// The sidebar panel this extension contributes, or nil for none.
    let panel: ExtensionPanelSpec?
    /// Command palette entries, in manifest order. Empty for none.
    let palette: [ExtensionPaletteEntry]

    /// Reads and validates `<folder>/extension.toml`. The folder's name must
    /// equal the manifest's `id`.
    static func load(from folder: URL, fileManager: FileManager = .default) throws(ExtensionManifestError) -> ExtensionManifest {
        let manifestURL = folder.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw .manifestMissing
        }
        let contents: String
        do {
            contents = try String(contentsOf: manifestURL, encoding: .utf8)
        } catch {
            throw .manifestUnreadable(error.localizedDescription)
        }
        return try parse(contents, folder: folder, fileManager: fileManager)
    }

    /// Validates manifest text against the extension folder it came from.
    static func parse(_ contents: String, folder: URL, fileManager: FileManager = .default) throws(ExtensionManifestError) -> ExtensionManifest {
        let table: TOMLTable
        do {
            table = try TOMLTable(string: contents)
        } catch {
            throw .invalidTOML(String(describing: error))
        }

        // api_version
        guard let apiValue = table["api_version"] else { throw .missingField("api_version") }
        guard let apiVersion = apiValue.int else { throw .wrongType(field: "api_version", expected: "an integer") }
        guard apiVersion >= 1 else { throw .apiVersionTooLow(apiVersion) }
        guard apiVersion <= supportedAPIVersion else {
            throw .apiVersionTooNew(apiVersion, supported: supportedAPIVersion)
        }

        // id
        let id = try requiredString("id", in: table)
        guard isValidID(id) else { throw .invalidID(id) }
        let folderName = folder.lastPathComponent
        guard id == folderName else { throw .idMismatch(id: id, folder: folderName) }

        // name
        let name = try requiredString("name", in: table).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw .emptyField("name") }

        // version
        let version = try requiredString("version", in: table)
        guard !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .emptyField("version") }

        // description (optional)
        var description: String?
        if let value = table["description"] {
            guard let string = value.string else { throw .wrongType(field: "description", expected: "a string") }
            description = string
        }

        // command
        let command = try requiredString("command", in: table)
        let commandURL = try resolveCommand(command, in: folder, fileManager: fileManager)

        // [panel] (optional)
        var panel: ExtensionPanelSpec?
        if let value = table["panel"] {
            guard let panelTable = value.table else { throw .wrongType(field: "panel", expected: "a table") }
            panel = try parsePanel(panelTable, folder: folder, fileManager: fileManager)
        }

        // [[palette]] (optional)
        var palette: [ExtensionPaletteEntry] = []
        if let value = table["palette"] {
            palette = try parsePalette(value)
            guard palette.isEmpty || panel != nil else { throw .paletteWithoutPanel }
        }

        return ExtensionManifest(
            apiVersion: apiVersion,
            id: id,
            name: name,
            version: version,
            description: description,
            command: command,
            commandURL: commandURL,
            panel: panel,
            palette: palette
        )
    }

    private static func parsePalette(_ value: TOMLValueConvertible) throws(ExtensionManifestError) -> [ExtensionPaletteEntry] {
        guard let array = value.array else { throw .wrongType(field: "palette", expected: "an array of tables") }
        var entries: [ExtensionPaletteEntry] = []
        for (index, element) in array.enumerated() {
            let prefix = "palette[\(index)]"
            guard let entry = element.table else { throw .wrongType(field: prefix, expected: "a table") }

            guard let titleValue = entry["title"] else { throw .missingField("\(prefix).title") }
            guard let rawTitle = titleValue.string else { throw .wrongType(field: "\(prefix).title", expected: "a string") }
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw .emptyField("\(prefix).title") }

            guard let actionValue = entry["action"] else { throw .missingField("\(prefix).action") }
            guard let action = actionValue.string else { throw .wrongType(field: "\(prefix).action", expected: "a string") }
            guard !action.isEmpty else { throw .emptyField("\(prefix).action") }

            var pick = false
            if let pickValue = entry["pick"] {
                guard let flag = pickValue.bool else { throw .wrongType(field: "\(prefix).pick", expected: "a boolean") }
                pick = flag
            }

            guard !entries.contains(where: { $0.action == action && $0.pick == pick }) else {
                throw .duplicatePaletteEntry(action: action, pick: pick)
            }
            entries.append(ExtensionPaletteEntry(title: title, action: action, pick: pick))
        }
        return entries
    }

    private static func parsePanel(_ table: TOMLTable, folder: URL, fileManager: FileManager) throws(ExtensionManifestError) -> ExtensionPanelSpec {
        guard let titleValue = table["title"] else { throw .missingField("panel.title") }
        guard let rawTitle = titleValue.string else { throw .wrongType(field: "panel.title", expected: "a string") }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw .emptyField("panel.title") }

        guard let iconValue = table["icon"] else { throw .missingField("panel.icon") }
        guard let icon = iconValue.string else { throw .wrongType(field: "panel.icon", expected: "a string") }
        guard !icon.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .emptyField("panel.icon") }

        var refreshSeconds = ExtensionPanelSpec.defaultRefreshSeconds
        if let value = table["refresh_seconds"] {
            guard let seconds = value.int else { throw .wrongType(field: "panel.refresh_seconds", expected: "an integer") }
            guard seconds >= ExtensionPanelSpec.minimumRefreshSeconds else { throw .refreshTooShort(seconds) }
            refreshSeconds = seconds
        }
        let iconURL = try resolveIconFile(icon, in: folder, fileManager: fileManager)
        return ExtensionPanelSpec(title: title, icon: icon, refreshSeconds: refreshSeconds, iconURL: iconURL)
    }

    /// `panel.icon` names an image file when it ends in one of
    /// `ExtensionPanelSpec.iconFileExtensions`; anything else is an SF Symbol
    /// name and returns nil. A file must exist inside the extension folder,
    /// both lexically (`..`) and after resolving symlinks.
    private static func resolveIconFile(_ icon: String, in folder: URL, fileManager: FileManager) throws(ExtensionManifestError) -> URL? {
        let pathExtension = (icon as NSString).pathExtension.lowercased()
        guard ExtensionPanelSpec.iconFileExtensions.contains(pathExtension) else { return nil }
        guard !icon.hasPrefix("/") else { throw .iconOutsideFolder(icon) }

        let folderPath = folder.standardizedFileURL.path
        let candidate = folder.appendingPathComponent(icon).standardizedFileURL
        guard candidate.path.hasPrefix(folderPath + "/") else { throw .iconOutsideFolder(icon) }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw .iconMissing(icon)
        }
        guard let realFolder = realPath(folderPath), let realIcon = realPath(candidate.path),
              realIcon.hasPrefix(realFolder + "/") else {
            throw .iconOutsideFolder(icon)
        }
        return URL(fileURLWithPath: realIcon)
    }

    /// Two or more dot-separated segments; each segment is lowercase letters,
    /// digits, and single interior hyphens (`acme.widgets`, `acme.widget-stats`).
    static func isValidID(_ id: String) -> Bool {
        let segments = id.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return false }
        return segments.allSatisfy { segment in
            guard let first = segment.first, let last = segment.last,
                  first != "-", last != "-", !segment.contains("--") else { return false }
            return segment.allSatisfy { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "-" }
        }
    }

    private static func requiredString(_ field: String, in table: TOMLTable) throws(ExtensionManifestError) -> String {
        guard let value = table[field] else { throw .missingField(field) }
        guard let string = value.string else { throw .wrongType(field: field, expected: "a string") }
        return string
    }

    /// Resolves `command` against the folder and checks it is an executable file
    /// that stays inside the folder, both lexically (`..`) and after resolving
    /// symlinks.
    private static func resolveCommand(_ command: String, in folder: URL, fileManager: FileManager) throws(ExtensionManifestError) -> URL {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .emptyField("command")
        }
        guard !command.hasPrefix("/") else { throw .commandAbsolute(command) }

        let folderPath = folder.standardizedFileURL.path
        let candidate = folder.appendingPathComponent(command).standardizedFileURL
        guard candidate.path.hasPrefix(folderPath + "/") else {
            throw .commandOutsideFolder(command)
        }

        // fileExists follows symlinks, so a dangling link reads as missing.
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
            throw .commandMissing(command)
        }

        guard let realFolder = realPath(folderPath), let realCommand = realPath(candidate.path),
              realCommand.hasPrefix(realFolder + "/") else {
            throw .commandOutsideFolder(command)
        }
        guard !isDirectory.boolValue else { throw .commandNotFile(command) }
        guard fileManager.isExecutableFile(atPath: realCommand) else {
            throw .commandNotExecutable(command)
        }
        return URL(fileURLWithPath: realCommand)
    }

    /// realpath(3): resolves every symlink in the path. Used instead of
    /// `URL.resolvingSymlinksInPath`, which special-cases `/private` and would
    /// compare the folder and command inconsistently.
    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// The `[panel]` table: a sidebar panel the extension fills by running
/// `command panel`.
nonisolated struct ExtensionPanelSpec: Equatable, Sendable {
    static let defaultRefreshSeconds = 10
    static let minimumRefreshSeconds = 2

    /// A `panel.icon` ending in one of these is an image file in the
    /// extension folder, not an SF Symbol name.
    static let iconFileExtensions: Set<String> = ["svg", "pdf", "png"]

    let title: String
    /// An SF Symbol name (not checked here; the activity bar falls back to a
    /// generic symbol when it does not exist), or the path of an image file
    /// in the extension folder, as written in the manifest.
    let icon: String
    let refreshSeconds: Int
    /// The image file `icon` names, resolved inside the extension folder; nil
    /// when `icon` is an SF Symbol name. Drawn as a template image, so it
    /// takes the sidebar's tint like the built-in icons.
    let iconURL: URL?

    init(title: String, icon: String, refreshSeconds: Int, iconURL: URL? = nil) {
        self.title = title
        self.icon = icon
        self.refreshSeconds = refreshSeconds
        self.iconURL = iconURL
    }
}

/// One `[[palette]]` entry: a command palette command that runs the panel
/// action `action`, on a row the user picks first when `pick` is true.
nonisolated struct ExtensionPaletteEntry: Equatable, Sendable {
    let title: String
    let action: String
    let pick: Bool

    init(title: String, action: String, pick: Bool = false) {
        self.title = title
        self.action = action
        self.pick = pick
    }
}

/// Why an extension folder failed validation. Each case names the field at
/// fault so the Preferences pane can show the user what to fix.
nonisolated enum ExtensionManifestError: Error, Equatable, Sendable, LocalizedError {
    case manifestMissing
    case manifestUnreadable(String)
    case invalidTOML(String)
    case missingField(String)
    case wrongType(field: String, expected: String)
    case emptyField(String)
    case apiVersionTooLow(Int)
    case apiVersionTooNew(Int, supported: Int)
    case invalidID(String)
    case idMismatch(id: String, folder: String)
    case commandAbsolute(String)
    case commandOutsideFolder(String)
    case commandMissing(String)
    case commandNotFile(String)
    case commandNotExecutable(String)
    case refreshTooShort(Int)
    case iconOutsideFolder(String)
    case iconMissing(String)
    case paletteWithoutPanel
    case duplicatePaletteEntry(action: String, pick: Bool)

    var errorDescription: String? {
        switch self {
        case .manifestMissing:
            return "No \(ExtensionManifest.fileName) in this folder."
        case .manifestUnreadable(let detail):
            return "Could not read \(ExtensionManifest.fileName): \(detail)"
        case .invalidTOML(let detail):
            return "\(ExtensionManifest.fileName) is not valid TOML: \(detail)"
        case .missingField(let field):
            return "Missing required field \"\(field)\"."
        case .wrongType(let field, let expected):
            return "\"\(field)\" must be \(expected)."
        case .emptyField(let field):
            return "\"\(field)\" must not be empty."
        case .apiVersionTooLow(let version):
            return "\"api_version\" must be 1 or higher (found \(version))."
        case .apiVersionTooNew(let version, let supported):
            return "\"api_version\" is \(version), but this Cortland supports API version \(supported). This extension needs a newer Cortland."
        case .invalidID(let id):
            return "\"id\" \"\(id)\" is invalid: use two or more dot-separated segments of lowercase letters, digits, and single hyphens (for example \"author.tool\")."
        case .idMismatch(let id, let folder):
            return "\"id\" \"\(id)\" does not match the folder name \"\(folder)\"."
        case .commandAbsolute(let command):
            return "\"command\" \"\(command)\" must be a path relative to the extension folder."
        case .commandOutsideFolder(let command):
            return "\"command\" \"\(command)\" points outside the extension folder."
        case .commandMissing(let command):
            return "\"command\" \"\(command)\" does not exist."
        case .commandNotFile(let command):
            return "\"command\" \"\(command)\" is not a file."
        case .commandNotExecutable(let command):
            return "\"command\" \"\(command)\" is not executable."
        case .iconOutsideFolder(let icon):
            return "\"panel.icon\" \"\(icon)\" points outside the extension folder."
        case .iconMissing(let icon):
            return "\"panel.icon\" \"\(icon)\" does not exist."
        case .paletteWithoutPanel:
            return "\"palette\" entries need a [panel] table."
        case .duplicatePaletteEntry(let action, let pick):
            return "Two \"palette\" entries have \"action\" \"\(action)\" and \"pick\" \(pick)."
        case .refreshTooShort(let seconds):
            return "\"panel.refresh_seconds\" must be \(ExtensionPanelSpec.minimumRefreshSeconds) or more (found \(seconds))."
        }
    }
}
