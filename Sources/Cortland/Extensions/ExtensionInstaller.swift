import Foundation
import TOMLKit

/// What installing an extension from a repository produced. Printed by
/// `cortland-ctl extension install`.
nonisolated struct ExtensionInstallResult: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let version: String
    /// Always false: a new extension starts disabled.
    let enabled: Bool
}

/// What updating an installed extension did. Printed by
/// `cortland-ctl extension update`.
nonisolated struct ExtensionUpdateResult: Codable, Equatable, Sendable {
    let id: String
    /// True when the checkout's HEAD moved.
    let updated: Bool
    /// The manifest's `version` before and after, nil when it did not validate.
    let versionBefore: String?
    let versionAfter: String?
    /// The validation message when the manifest no longer validates after the
    /// update. The extension is still updated; the registry lists it as invalid.
    let invalid: String?
    /// True when an update requested over IPC brought new code to an enabled
    /// extension, which was disabled so the new code doesn't run unreviewed.
    var disabled: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case id, updated, invalid, disabled
        case versionBefore = "version_before"
        case versionAfter = "version_after"
    }
}

nonisolated enum ExtensionInstallError: Error, Equatable, Sendable, LocalizedError {
    case emptyLocation
    case locationStartsWithDash
    case locationHasControlCharacter
    case gitNotFound
    case gitFailed(String)
    case manifestMissing
    case invalidManifest(ExtensionManifestError)
    case alreadyInstalled(String)
    case unknownExtension(String)
    case notUpdatable(String)
    case fileSystem(String)

    var errorDescription: String? {
        switch self {
        case .emptyLocation:
            return "Enter the URL of the extension's git repository."
        case .locationStartsWithDash:
            return "The repository URL must not start with \"-\"."
        case .locationHasControlCharacter:
            return "The repository URL contains a control character."
        case .gitNotFound:
            return "git is not installed. Install it (for example with xcode-select --install) and try again."
        case .gitFailed(let message):
            return message
        case .manifestMissing:
            return "The repository has no \(ExtensionManifest.fileName) at its root."
        case .invalidManifest(let error):
            return error.localizedDescription
        case .alreadyInstalled(let id):
            return "\"\(id)\" is already installed. Use Update, or Remove it first."
        case .unknownExtension(let id):
            return "No installed extension \"\(id)\"."
        case .notUpdatable(let id):
            return "\"\(id)\" is not a git checkout Cortland installed, so Cortland cannot update it."
        case .fileSystem(let message):
            return message
        }
    }
}

/// Installs an extension by cloning its git repository into the extensions
/// directory, and updates one installed that way. Nothing here runs the
/// extension's command: installing downloads and checks files only.
/// Blocking; call it off the main thread.
nonisolated struct ExtensionInstaller: Sendable {
    /// Added to every git run so an SSH clone that needs a passphrase or a
    /// host-key answer fails at once instead of waiting for input.
    static let gitSSHCommand = "ssh -o BatchMode=yes"

    let extensionsDirectory: URL
    let runner: ProcessRunning
    /// The PATH git is found on and run with. Nil asks the user's shell, on
    /// first use, so it is never computed on the main thread.
    let searchPath: String?

    init(
        extensionsDirectory: URL,
        runner: ProcessRunning = ProcessRunner.shared,
        searchPath: String? = nil
    ) {
        self.extensionsDirectory = extensionsDirectory
        self.runner = runner
        self.searchPath = searchPath
    }

    // MARK: - Install

    /// The location trimmed, or the reason it is rejected before git runs.
    static func validatedLocation(_ raw: String) -> Result<String, ExtensionInstallError> {
        let location = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !location.isEmpty else { return .failure(.emptyLocation) }
        guard !location.hasPrefix("-") else { return .failure(.locationStartsWithDash) }
        let hasControl = location.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
        guard !hasControl else { return .failure(.locationHasControlCharacter) }
        return .success(location)
    }

    /// Clones `location` and installs it at `<extensions>/<id>`, disabled.
    func install(from rawLocation: String) throws(ExtensionInstallError) -> ExtensionInstallResult {
        let location = try Self.validatedLocation(rawLocation).get()
        let path = resolvedSearchPath
        guard let git = Self.gitURL(searchPath: path) else { throw .gitNotFound }

        let fileManager = FileManager.default
        let staging = extensionsDirectory.appendingPathComponent(".install-\(UUID().uuidString)")
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            throw .fileSystem("Could not create \(staging.path): \(error.localizedDescription)")
        }
        defer { try? fileManager.removeItem(at: staging) }

        let clone = staging.appendingPathComponent("repo")
        let result = try runGit(git, ["clone", "--depth", "1", "--", location, clone.path], searchPath: path)
        guard result.succeeded else {
            let message = result.stderr
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && !$0.hasPrefix("Cloning into") }
            throw .gitFailed(message ?? "git clone failed (exit status \(result.terminationStatus)).")
        }

        let id = try Self.manifestID(in: clone)
        let destination = extensionsDirectory.appendingPathComponent(id)
        // attributesOfItem does not follow symlinks, so a broken link counts.
        if (try? fileManager.attributesOfItem(atPath: destination.path)) != nil {
            throw .alreadyInstalled(id)
        }

        let named = staging.appendingPathComponent(id)
        do {
            try fileManager.moveItem(at: clone, to: named)
        } catch {
            throw .fileSystem("Could not prepare the extension: \(error.localizedDescription)")
        }
        let manifest: ExtensionManifest
        do {
            manifest = try ExtensionManifest.load(from: named, fileManager: fileManager)
        } catch {
            throw .invalidManifest(error)
        }
        do {
            try fileManager.moveItem(at: named, to: destination)
        } catch {
            throw .fileSystem("Could not move the extension into place: \(error.localizedDescription)")
        }
        return ExtensionInstallResult(id: manifest.id, name: manifest.name, version: manifest.version, enabled: false)
    }

    /// The `id` from `<folder>/extension.toml`, checked only for its form.
    private static func manifestID(in folder: URL) throws(ExtensionInstallError) -> String {
        let manifestURL = folder.appendingPathComponent(ExtensionManifest.fileName)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { throw .manifestMissing }
        let contents: String
        do {
            contents = try String(contentsOf: manifestURL, encoding: .utf8)
        } catch {
            throw .invalidManifest(.manifestUnreadable(error.localizedDescription))
        }
        let table: TOMLTable
        do {
            table = try TOMLTable(string: contents)
        } catch {
            throw .invalidManifest(.invalidTOML(String(describing: error)))
        }
        guard let value = table["id"] else { throw .invalidManifest(.missingField("id")) }
        guard let id = value.string else { throw .invalidManifest(.wrongType(field: "id", expected: "a string")) }
        guard ExtensionManifest.isValidID(id) else { throw .invalidManifest(.invalidID(id)) }
        return id
    }

    // MARK: - Update

    /// True when `folder` is a real directory (not a symlink) holding `.git`:
    /// a checkout Cortland can pull. A symlinked folder is a developer's
    /// working copy and is never updated by Cortland.
    static func isUpdatable(folder: URL) -> Bool {
        let fileManager = FileManager.default
        guard let type = (try? fileManager.attributesOfItem(atPath: folder.path))?[.type] as? FileAttributeType,
              type == .typeDirectory else { return false }
        return fileManager.fileExists(atPath: folder.appendingPathComponent(".git").path)
    }

    /// Fast-forwards the checkout at `<extensions>/<id>`. `id` may also be the
    /// folder name of an invalid extension.
    func update(_ id: String) throws(ExtensionInstallError) -> ExtensionUpdateResult {
        guard !id.isEmpty, !id.contains("/"), !id.hasPrefix(".") else { throw .unknownExtension(id) }
        let folder = extensionsDirectory.appendingPathComponent(id)
        guard (try? FileManager.default.attributesOfItem(atPath: folder.path)) != nil else {
            throw .unknownExtension(id)
        }
        guard Self.isUpdatable(folder: folder) else { throw .notUpdatable(id) }

        let path = resolvedSearchPath
        guard let git = Self.gitURL(searchPath: path) else { throw .gitNotFound }

        let versionBefore = try? ExtensionManifest.load(from: folder).version
        let headBefore = try head(git, folder: folder, searchPath: path)
        let pull = try runGit(git, ["-C", folder.path, "pull", "--ff-only"], searchPath: path)
        guard pull.succeeded else {
            let message = ExtensionPanelCommand.firstLine(of: pull.stderr)
            throw .gitFailed(message.isEmpty ? "git pull failed (exit status \(pull.terminationStatus))." : message)
        }
        let headAfter = try head(git, folder: folder, searchPath: path)

        var versionAfter: String?
        var invalid: String?
        do {
            versionAfter = try ExtensionManifest.load(from: folder).version
        } catch {
            invalid = error.localizedDescription
        }
        return ExtensionUpdateResult(
            id: id,
            updated: headBefore != headAfter,
            versionBefore: versionBefore,
            versionAfter: versionAfter,
            invalid: invalid
        )
    }

    private func head(_ git: URL, folder: URL, searchPath: String) throws(ExtensionInstallError) -> String {
        let result = try runGit(git, ["-C", folder.path, "rev-parse", "HEAD"], searchPath: searchPath)
        guard result.succeeded else {
            let message = ExtensionPanelCommand.firstLine(of: result.stderr)
            throw .gitFailed(message.isEmpty ? "git rev-parse failed (exit status \(result.terminationStatus))." : message)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Running git

    private var resolvedSearchPath: String {
        searchPath ?? DocumentFormatter.shellSearchPath
    }

    /// `git` on `searchPath`, or nil when it is not installed.
    static func gitURL(searchPath: String) -> URL? {
        for entry in searchPath.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(entry)).appendingPathComponent("git")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private func runGit(_ git: URL, _ arguments: [String], searchPath: String) throws(ExtensionInstallError) -> ProcessResult {
        do {
            return try runner.run(
                executableURL: git,
                arguments: arguments,
                currentDirectoryURL: nil,
                environment: ["PATH": searchPath, "GIT_SSH_COMMAND": Self.gitSSHCommand]
            )
        } catch {
            throw .gitFailed("Could not run git: \(error.localizedDescription)")
        }
    }
}
