import Foundation

/// An extension folder whose manifest validated.
nonisolated struct InstalledExtension: Equatable, Sendable {
    let manifest: ExtensionManifest
    let folder: URL
    let isEnabled: Bool

    var id: String { manifest.id }

    /// True when Cortland can update this extension with `git pull`.
    var isUpdatable: Bool { ExtensionInstaller.isUpdatable(folder: folder) }
}

/// An extension folder whose manifest did not validate. It is listed so the
/// user can see what to fix, or remove it.
nonisolated struct InvalidExtension: Equatable, Sendable {
    let folderName: String
    let folder: URL
    let error: ExtensionManifestError

    /// True when Cortland can update this extension with `git pull`.
    var isUpdatable: Bool { ExtensionInstaller.isUpdatable(folder: folder) }
}

/// One pass over the extensions directory, each list sorted by name.
nonisolated struct ExtensionScan: Equatable, Sendable {
    var valid: [InstalledExtension] = []
    var invalid: [InvalidExtension] = []

    /// Every folder name present, valid or not. State-file ids outside this set
    /// are stale.
    var folderNames: Set<String> {
        Set(valid.map(\.id)).union(invalid.map(\.folderName))
    }
}

/// The on-disk enabled list, `~/.config/cortland/extensions.json`. Kept
/// outside the extension folders so updating or replacing an extension's
/// files never changes whether it is enabled.
nonisolated struct ExtensionState: Codable, Equatable, Sendable {
    var enabled: [String]
}

nonisolated enum ExtensionRegistryError: Error, Equatable, LocalizedError {
    case unknownExtension(String)

    var errorDescription: String? {
        switch self {
        case .unknownExtension(let id):
            return "No installed extension \"\(id)\"."
        }
    }
}

nonisolated extension Notification.Name {
    /// The installed or enabled extensions changed. `object` is the
    /// `ExtensionRegistry`; read its `extensions` and `invalidExtensions`.
    static let extensionsDidChange = Notification.Name("ExtensionsDidChange")
}

/// Owns the list of installed extensions and which of them are enabled.
///
/// Nothing here runs an extension's command; it only finds, validates, and
/// tracks extensions. Observe `.extensionsDidChange` to follow changes.
final class ExtensionRegistry {
    static let shared = ExtensionRegistry()

    static var defaultExtensionsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cortland/extensions")
    }

    static var defaultStateFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cortland/extensions.json")
    }

    let extensionsDirectory: URL
    let stateFileURL: URL
    /// Moves an uninstalled extension's folder out of the way. The Trash by
    /// default, so the user can recover it; tests inject a plain removal.
    private let removeFolder: (URL) throws -> Void
    /// Clones and updates extensions from git repositories.
    let installer: ExtensionInstaller

    private(set) var extensions: [InstalledExtension] = []
    private(set) var invalidExtensions: [InvalidExtension] = []

    init(
        extensionsDirectory: URL = ExtensionRegistry.defaultExtensionsDirectory,
        stateFileURL: URL = ExtensionRegistry.defaultStateFileURL,
        removeFolder: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
        installer: ExtensionInstaller? = nil
    ) {
        self.extensionsDirectory = extensionsDirectory
        self.stateFileURL = stateFileURL
        self.removeFolder = removeFolder
        self.installer = installer ?? ExtensionInstaller(extensionsDirectory: extensionsDirectory)
    }

    /// Rescans the extensions directory and posts `.extensionsDidChange` when
    /// the result differs from the last scan.
    func reload() {
        let scan = Self.scan(directory: extensionsDirectory, enabled: Self.loadEnabled(from: stateFileURL))
        guard scan.valid != extensions || scan.invalid != invalidExtensions else { return }
        extensions = scan.valid
        invalidExtensions = scan.invalid
        NotificationCenter.default.post(name: .extensionsDidChange, object: self)
    }

    func setEnabled(_ id: String, _ enabled: Bool) throws {
        let scan = Self.scan(directory: extensionsDirectory, enabled: [])
        guard scan.valid.contains(where: { $0.id == id }) else {
            throw ExtensionRegistryError.unknownExtension(id)
        }
        var ids = Self.loadEnabled(from: stateFileURL)
        if enabled {
            ids.insert(id)
        } else {
            ids.remove(id)
        }
        try writeState(ids, known: scan.folderNames)
        reload()
    }

    /// Disables the extension, drops it from the state file, then moves its
    /// folder to the Trash. Works for invalid extensions too, by folder name.
    func uninstall(_ id: String) throws {
        let scan = Self.scan(directory: extensionsDirectory, enabled: [])
        let folder = scan.valid.first(where: { $0.id == id })?.folder
            ?? scan.invalid.first(where: { $0.folderName == id })?.folder
        guard let folder else { throw ExtensionRegistryError.unknownExtension(id) }

        defer { reload() }
        var ids = Self.loadEnabled(from: stateFileURL)
        ids.remove(id)
        try writeState(ids, known: scan.folderNames.subtracting([id]))
        try removeFolder(folder)
    }

    /// Clones the repository at `location` into the extensions directory, off
    /// the main thread, then rescans. The new extension starts disabled.
    func install(from location: String) async throws(ExtensionInstallError) -> ExtensionInstallResult {
        let installer = installer
        let result = await Task.detached {
            Result { () throws(ExtensionInstallError) in try installer.install(from: location) }
        }.value
        if case .success = result { reload() }
        return try result.get()
    }

    /// Pulls the extension's checkout, off the main thread, then rescans.
    /// Its enabled state does not change.
    func update(_ id: String) async throws(ExtensionInstallError) -> ExtensionUpdateResult {
        let installer = installer
        let result = await Task.detached {
            Result { () throws(ExtensionInstallError) in try installer.update(id) }
        }.value
        reload()
        return try result.get()
    }

    /// Writes the enabled list, keeping only ids that match an installed folder.
    private func writeState(_ ids: Set<String>, known: Set<String>) throws {
        let state = ExtensionState(enabled: ids.intersection(known).sorted())
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try FileManager.default.createDirectory(
                at: stateFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: stateFileURL, options: .atomic)
        } catch {
            Log.error("failed to save extension state: \(error)", category: "extensions")
            throw error
        }
    }

    // MARK: - Pure helpers

    /// The enabled ids from the state file. A missing or unreadable file means
    /// nothing is enabled; it is logged, never thrown.
    nonisolated static func loadEnabled(from fileURL: URL) -> Set<String> {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                Log.error("failed to read extension state: \(error)", category: "extensions")
            } else {
                Log.debug("no extension state file; nothing enabled", category: "extensions")
            }
            return []
        }
        do {
            return Set(try JSONDecoder().decode(ExtensionState.self, from: data).enabled)
        } catch {
            Log.error("failed to decode extension state, treating all extensions as disabled: \(error)", category: "extensions")
            return []
        }
    }

    /// Validates every visible folder in `directory`. Hidden entries and plain
    /// files are skipped; a missing directory yields an empty scan.
    nonisolated static func scan(
        directory: URL,
        enabled: Set<String>,
        fileManager: FileManager = .default
    ) -> ExtensionScan {
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var result = ExtensionScan()
        for entry in entries {
            // fileExists follows symlinks, so a linked extension folder counts.
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            do {
                let manifest = try ExtensionManifest.load(from: entry, fileManager: fileManager)
                result.valid.append(InstalledExtension(
                    manifest: manifest,
                    folder: entry,
                    isEnabled: enabled.contains(manifest.id)
                ))
            } catch {
                result.invalid.append(InvalidExtension(
                    folderName: entry.lastPathComponent,
                    folder: entry,
                    error: error
                ))
            }
        }
        result.valid.sort { $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending }
        result.invalid.sort { $0.folderName.localizedStandardCompare($1.folderName) == .orderedAscending }
        return result
    }
}
