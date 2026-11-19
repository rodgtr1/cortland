import XCTest
@testable import Cortland

/// Extension manifests, the enabled-state file, and uninstall, all against
/// temp directories (never the real ~/.config/cortland).
@MainActor
final class ExtensionRegistryTests: XCTestCase {
    private var base: URL!
    private var extensionsDirectory: URL!
    private var stateFile: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("ExtensionRegistryTests-\(UUID().uuidString)")
        extensionsDirectory = base.appendingPathComponent("extensions")
        stateFile = base.appendingPathComponent("extensions.json")
        try fm.createDirectory(at: extensionsDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    // MARK: - Fixtures

    private func manifest(
        id: String = "acme.widgets",
        apiVersion: String = "1",
        name: String = "\"Widgets\"",
        version: String = "\"0.1.0\"",
        command: String = "\"bin/widgets\"",
        extra: String = ""
    ) -> String {
        """
        api_version = \(apiVersion)
        id = "\(id)"
        name = \(name)
        version = \(version)
        description = "Browse and launch Widgets."
        command = \(command)
        \(extra)
        """
    }

    /// Creates `<extensions>/<folder>/` with the given manifest and, unless
    /// told otherwise, an executable `bin/widgets`.
    @discardableResult
    private func install(
        folder: String = "acme.widgets",
        manifest text: String? = nil,
        executable: Bool = true,
        createCommand: Bool = true
    ) throws -> URL {
        let dir = extensionsDirectory.appendingPathComponent(folder)
        try fm.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try (text ?? manifest(id: folder)).write(
            to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        if createCommand {
            let command = dir.appendingPathComponent("bin/widgets")
            try "#!/bin/sh\n".write(to: command, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: command.path)
        }
        return dir
    }

    private func loadError(_ folder: URL) -> ExtensionManifestError? {
        do {
            _ = try ExtensionManifest.load(from: folder)
            return nil
        } catch {
            return error
        }
    }

    private func makeRegistry() -> ExtensionRegistry {
        ExtensionRegistry(
            extensionsDirectory: extensionsDirectory,
            stateFileURL: stateFile,
            removeFolder: { [fm] url in try fm.removeItem(at: url) }
        )
    }

    private func stateOnDisk() throws -> [String] {
        try JSONDecoder().decode(ExtensionState.self, from: Data(contentsOf: stateFile)).enabled
    }

    // MARK: - Manifest

    func testValidManifestParses() throws {
        let dir = try install()
        let m = try ExtensionManifest.load(from: dir)
        XCTAssertEqual(m.apiVersion, 1)
        XCTAssertEqual(m.id, "acme.widgets")
        XCTAssertEqual(m.name, "Widgets")
        XCTAssertEqual(m.version, "0.1.0")
        XCTAssertEqual(m.description, "Browse and launch Widgets.")
        XCTAssertEqual(m.command, "bin/widgets")
        XCTAssertEqual(m.commandURL.lastPathComponent, "widgets")
    }

    func testUnknownKeysAndMissingDescriptionAreFine() throws {
        let text = """
        api_version = 1
        id = "acme.widget-stats"
        name = "Git Stats"
        version = "whatever"
        command = "bin/widgets"
        future_key = true
        """
        let dir = try install(folder: "acme.widget-stats", manifest: text)
        let m = try ExtensionManifest.load(from: dir)
        XCTAssertNil(m.description)
        XCTAssertEqual(m.version, "whatever")
    }

    func testMissingManifest() throws {
        let dir = extensionsDirectory.appendingPathComponent("a.b")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertEqual(loadError(dir), .manifestMissing)
    }

    func testInvalidTOML() throws {
        let dir = try install(manifest: "api_version = = 1")
        guard case .invalidTOML = loadError(dir) else { return XCTFail("expected invalidTOML") }
    }

    func testAPIVersionRules() throws {
        let missing = manifest().replacingOccurrences(of: "api_version = 1\n", with: "")
        XCTAssertEqual(loadError(try install(manifest: missing)), .missingField("api_version"))
        XCTAssertEqual(loadError(try install(manifest: manifest(apiVersion: "\"1\""))),
                       .wrongType(field: "api_version", expected: "an integer"))
        XCTAssertEqual(loadError(try install(manifest: manifest(apiVersion: "0"))), .apiVersionTooLow(0))
        let tooNew = loadError(try install(manifest: manifest(apiVersion: "2")))
        XCTAssertEqual(tooNew, .apiVersionTooNew(2, supported: ExtensionManifest.supportedAPIVersion))
        XCTAssertTrue(tooNew?.localizedDescription.contains("newer Cortland") == true)
    }

    func testIDRules() throws {
        let missing = manifest().replacingOccurrences(of: "id = \"acme.widgets\"\n", with: "")
        XCTAssertEqual(loadError(try install(manifest: missing)), .missingField("id"))

        for bad in ["widgets", "Acme.widgets", "acme..widgets", "acme.-widgets", "acme.widgets-",
                    "acme.wid--gets", "acme.wid_gets", ".acme.widgets", "acme.widgets."] {
            XCTAssertFalse(ExtensionManifest.isValidID(bad), bad)
        }
        for good in ["acme.widgets", "acme.widget-stats", "a.b.c", "x1.y2-z3"] {
            XCTAssertTrue(ExtensionManifest.isValidID(good), good)
        }
        XCTAssertEqual(loadError(try install(folder: "widgets", manifest: manifest(id: "widgets"))), .invalidID("widgets"))
    }

    func testIDMustMatchFolderName() throws {
        let dir = try install(folder: "other.name", manifest: manifest(id: "acme.widgets"))
        XCTAssertEqual(loadError(dir), .idMismatch(id: "acme.widgets", folder: "other.name"))
    }

    func testNameRules() throws {
        let missing = manifest().replacingOccurrences(of: "name = \"Widgets\"\n", with: "")
        XCTAssertEqual(loadError(try install(manifest: missing)), .missingField("name"))
        XCTAssertEqual(loadError(try install(manifest: manifest(name: "\"   \""))), .emptyField("name"))
    }

    func testVersionRules() throws {
        let missing = manifest().replacingOccurrences(of: "version = \"0.1.0\"\n", with: "")
        XCTAssertEqual(loadError(try install(manifest: missing)), .missingField("version"))
        XCTAssertEqual(loadError(try install(manifest: manifest(version: "\"\""))), .emptyField("version"))
        XCTAssertEqual(loadError(try install(manifest: manifest(version: "1"))),
                       .wrongType(field: "version", expected: "a string"))
    }

    func testDescriptionMustBeString() throws {
        let text = manifest().replacingOccurrences(of: "description = \"Browse and launch Widgets.\"", with: "description = 3")
        XCTAssertEqual(loadError(try install(manifest: text)), .wrongType(field: "description", expected: "a string"))
    }

    func testCommandMissingField() throws {
        let missing = manifest().replacingOccurrences(of: "command = \"bin/widgets\"\n", with: "")
        XCTAssertEqual(loadError(try install(manifest: missing)), .missingField("command"))
    }

    func testCommandAbsolute() throws {
        XCTAssertEqual(loadError(try install(manifest: manifest(command: "\"/bin/sh\""))), .commandAbsolute("/bin/sh"))
    }

    func testCommandEscapesThroughDotDot() throws {
        // A real executable sits outside the folder, so only containment fails.
        let outside = extensionsDirectory.appendingPathComponent("outside.sh")
        try "#!/bin/sh\n".write(to: outside, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outside.path)
        let dir = try install(manifest: manifest(command: "\"bin/../../outside.sh\""))
        XCTAssertEqual(loadError(dir), .commandOutsideFolder("bin/../../outside.sh"))
    }

    func testCommandEscapesThroughSymlink() throws {
        let outside = base.appendingPathComponent("outside.sh")
        try "#!/bin/sh\n".write(to: outside, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outside.path)
        let dir = try install(manifest: manifest(command: "\"bin/link\""))
        try fm.createSymbolicLink(at: dir.appendingPathComponent("bin/link"), withDestinationURL: outside)
        XCTAssertEqual(loadError(dir), .commandOutsideFolder("bin/link"))
    }

    func testSymlinkInsideFolderIsAllowed() throws {
        let dir = try install(manifest: manifest(command: "\"bin/link\""))
        try fm.createSymbolicLink(atPath: dir.appendingPathComponent("bin/link").path, withDestinationPath: "widgets")
        XCTAssertNoThrow(try ExtensionManifest.load(from: dir))
    }

    func testCommandFileMissing() throws {
        let dir = try install(createCommand: false)
        XCTAssertEqual(loadError(dir), .commandMissing("bin/widgets"))
    }

    func testCommandNotExecutable() throws {
        let dir = try install(executable: false)
        XCTAssertEqual(loadError(dir), .commandNotExecutable("bin/widgets"))
    }

    func testCommandIsDirectory() throws {
        let dir = try install(manifest: manifest(command: "\"bin\""))
        XCTAssertEqual(loadError(dir), .commandNotFile("bin"))
    }

    // MARK: - Registry

    func testScanIgnoresHiddenEntriesAndPlainFiles() throws {
        try install()
        try install(folder: ".hidden.ext")
        try "not an extension".write(to: extensionsDirectory.appendingPathComponent("notes.txt"),
                                     atomically: true, encoding: .utf8)
        let registry = makeRegistry()
        registry.reload()
        XCTAssertEqual(registry.extensions.map(\.id), ["acme.widgets"])
        XCTAssertTrue(registry.invalidExtensions.isEmpty)
    }

    func testScanSortsByNameAndReportsInvalid() throws {
        try install(folder: "z.first", manifest: manifest(id: "z.first", name: "\"Alpha\""))
        try install(folder: "a.second", manifest: manifest(id: "a.second", name: "\"Beta\""))
        try install(folder: "broken.one", manifest: manifest(id: "broken.one", apiVersion: "9"))
        let registry = makeRegistry()
        registry.reload()
        XCTAssertEqual(registry.extensions.map(\.manifest.name), ["Alpha", "Beta"])
        XCTAssertEqual(registry.invalidExtensions.map(\.folderName), ["broken.one"])
        XCTAssertEqual(registry.invalidExtensions.first?.error, .apiVersionTooNew(9, supported: 1))
    }

    func testMissingExtensionsDirectoryScansEmpty() throws {
        try fm.removeItem(at: extensionsDirectory)
        let registry = makeRegistry()
        registry.reload()
        XCTAssertTrue(registry.extensions.isEmpty)
        XCTAssertTrue(registry.invalidExtensions.isEmpty)
    }

    func testNewExtensionsAreDisabledAndEnableRoundTrips() throws {
        try install()
        let registry = makeRegistry()
        registry.reload()
        XCTAssertEqual(registry.extensions.first?.isEnabled, false)

        try registry.setEnabled("acme.widgets", true)
        XCTAssertEqual(try stateOnDisk(), ["acme.widgets"])
        XCTAssertEqual(registry.extensions.first?.isEnabled, true)

        // A fresh registry reads the same state back.
        let second = makeRegistry()
        second.reload()
        XCTAssertEqual(second.extensions.first?.isEnabled, true)

        try registry.setEnabled("acme.widgets", false)
        XCTAssertEqual(try stateOnDisk(), [])
        XCTAssertEqual(registry.extensions.first?.isEnabled, false)
    }

    func testSetEnabledUnknownIDThrows() throws {
        let registry = makeRegistry()
        XCTAssertThrowsError(try registry.setEnabled("nobody.here", true)) { error in
            XCTAssertEqual(error as? ExtensionRegistryError, .unknownExtension("nobody.here"))
        }
    }

    func testCorruptStateFileMeansNothingEnabled() throws {
        try install()
        try "{ not json".write(to: stateFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(ExtensionRegistry.loadEnabled(from: stateFile), [])
        let registry = makeRegistry()
        registry.reload()
        XCTAssertEqual(registry.extensions.first?.isEnabled, false)
        // And the next write replaces it with a valid file.
        try registry.setEnabled("acme.widgets", true)
        XCTAssertEqual(try stateOnDisk(), ["acme.widgets"])
    }

    func testMissingStateFileMeansNothingEnabled() {
        XCTAssertEqual(ExtensionRegistry.loadEnabled(from: stateFile), [])
    }

    func testStaleIDsDroppedOnNextWrite() throws {
        try install()
        let stale = ExtensionState(enabled: ["gone.away", "acme.widgets"])
        try JSONEncoder().encode(stale).write(to: stateFile)
        let registry = makeRegistry()
        registry.reload()
        XCTAssertEqual(registry.extensions.first?.isEnabled, true)

        try install(folder: "acme.widget-stats", manifest: manifest(id: "acme.widget-stats", name: "\"Widget Stats\""))
        try registry.setEnabled("acme.widget-stats", true)
        XCTAssertEqual(try stateOnDisk(), ["acme.widget-stats", "acme.widgets"])
    }

    func testUninstallRemovesStateAndFolder() throws {
        let dir = try install()
        let registry = makeRegistry()
        try registry.setEnabled("acme.widgets", true)

        try registry.uninstall("acme.widgets")
        XCTAssertEqual(try stateOnDisk(), [])
        XCTAssertFalse(fm.fileExists(atPath: dir.path))
        XCTAssertTrue(registry.extensions.isEmpty)
    }

    func testUninstallInvalidExtensionByFolderName() throws {
        let dir = try install(folder: "broken.one", manifest: manifest(id: "broken.one", apiVersion: "9"))
        let registry = makeRegistry()
        registry.reload()
        XCTAssertEqual(registry.invalidExtensions.count, 1)
        try registry.uninstall("broken.one")
        XCTAssertFalse(fm.fileExists(atPath: dir.path))
        XCTAssertTrue(registry.invalidExtensions.isEmpty)
    }

    func testUninstallUnknownIDThrowsAndRemovesNothing() throws {
        let dir = try install()
        let registry = makeRegistry()
        XCTAssertThrowsError(try registry.uninstall("../extensions"))
        XCTAssertTrue(fm.fileExists(atPath: dir.path))
    }

    func testReloadPostsChangeNotificationOnlyWhenListChanges() throws {
        let registry = makeRegistry()
        nonisolated(unsafe) var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: .extensionsDidChange, object: registry, queue: nil
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        try install()
        registry.reload()
        XCTAssertEqual(posts, 1)
        registry.reload()
        XCTAssertEqual(posts, 1)
        try registry.setEnabled("acme.widgets", true)
        XCTAssertEqual(posts, 2)
    }
}
